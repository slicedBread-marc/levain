#!/usr/bin/env bash
# services.test.sh — lv-services.sh and the rack's services view: the manifest is read from
# levain.yml, a beacon says what runs and from which checkout, a dead pid's record goes, a
# stale heartbeat shows, start and stop refuse what they should, a worktree a service runs
# from cannot be drained, and `v`'s table shows a worker running off main as its branch.
#
#   tests/rack/services.test.sh
#
# Every repo, record and window is a fixture: nothing here reads the operator's portfolio,
# and LV_SERVICES_OPENER stands in for Terminal.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
BOARD="$SCRIPTS/lv-rack.sh"
SVC="$SCRIPTS/lv-services.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-services.XXXXXX")" && pwd -P)"
PIDS=()
cleanup() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; rm -rf "$FIX"; return 0; }
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }

unset CLAUDECODE
export LV_SERVICES_DIR="$FIX/state"
export LV_SERVICES_OPENER="$FIX/opener"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/opened"\n' "$FIX" > "$LV_SERVICES_OPENER"
chmod +x "$LV_SERVICES_OPENER"

# ── Fixture: a project on develop, with main and a feature worktree ─────
P="$FIX/alpha"
git init -q -b develop "$P"
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git -C "$P" branch main
git -C "$P" worktree add -q "$P/release-branches/main" main
git -C "$P" worktree add -q -b feature/PLN-9-x "$P/feature-branches/PLN-9-x"
MAIN="$P/release-branches/main"; FEAT="$P/feature-branches/PLN-9-x"
cat > "$P/levain.yml" <<'YML'
project_slug: "alpha"
services:
  web:
    label: "Web"
    start: "echo web-up > started.txt"
    stop: "echo web-down > stopped.txt"
    health: "http://127.0.0.1:9/health"
  worker:
    label: "Worker"
    start: "tools/worker.sh"
    stop: signal
    window: true
    checkout: any
    heartbeat: 60
  gated:
    start: "true"
    needs: "web"
  probe:
    label: "Status only"
    compose: "alpha-nothing-runs-here"
services_console: "tools/board.sh"
other: 1
YML
svc() { (cd "$1" && shift && "$SVC" "$@"); }
live() { sleep 600 & PIDS+=($!); LAST=$!; }

echo "── the manifest ──"
ck "services: ids in file order, nothing past the block" "$(svc "$P" list | cut -f1 | tr '\n' ' ')" "web worker gated probe "
ck "a service with no start: is status-only" "$(svc "$P" list | awk -F'\t' '$1=="probe"{print $3}')" "status-only"
ck "checkout defaults to main" "$(svc "$P" list | awk -F'\t' '$1=="web"{print $4}')" "main"
ck "worktrees: main's first" "$(svc "$P" worktrees | head -1)" "$MAIN	main"

echo "── the beacon ──"
live; W=$LAST
(cd "$FEAT" && "$SVC" beacon up worker --pid "$W")
row=$(svc "$P" status | awk -F'\t' '$1=="worker"')
ck "a live beacon is up" "$(cut -f2 <<< "$row")" "up"
ck "it names the checkout it was started from" "$(cut -f4 <<< "$row")" "$FEAT"
ck "and its branch" "$(cut -f5 <<< "$row")" "feature/PLN-9-x"
has "off main is flagged" "$(cut -f9 <<< "$row")" "offmain"
f="$LV_SERVICES_DIR/alpha/worker.$W.rec"
sed -i.bak 's/^heartbeat=.*/heartbeat=1/' "$f"; rm -f "$f.bak"
ck "a heartbeat older than heartbeat: is stale" "$(svc "$P" status | awk -F'\t' '$1=="worker"{print $2}')" "stale"
(cd "$FEAT" && "$SVC" beacon beat worker --pid "$W")
ck "beat refreshes it" "$(svc "$P" status | awk -F'\t' '$1=="worker"{print $2}')" "up"
if grep -qiE 'key|secret|token' "$f"; then bad "a record holds no secret-shaped field"; else ok "a record holds no secret-shaped field"; fi

echo "── the worktree guard ──"
out=$("$SVC" guard "$FEAT" 2>&1); rc=$?
ck "guard refuses a worktree a service runs from" "$rc" "2"
has "and names the service and pid" "$out" "alpha worker, pid $W"
"$SVC" guard "$MAIN" 2>/dev/null; ck "guard passes a worktree nothing runs from" "$?" "0"
(cd "$P" && "$SCRIPTS/lv-worktree-preserve.sh" "$FEAT" >/dev/null 2>&1); rc=$?
ck "lv-worktree-preserve refuses the removal (exit 2)" "$rc" "2"

echo "── start and stop ──"
out=$(svc "$P" start worker 2>&1); rc=$?
ck "a second start is refused while one runs" "$rc" "6"
has "naming where it runs" "$out" "$FEAT"
out=$(CLAUDECODE=1 svc "$P" start web 2>&1); ck "start refuses under an agent" "$?" "2"
out=$(CLAUDECODE=1 svc "$P" stop worker 2>&1); ck "stop refuses under an agent" "$?" "2"
out=$(svc "$P" start web --checkout "$FEAT" 2>&1); ck "a main-only service refuses a feature checkout" "$?" "3"
out=$(svc "$P" start web --checkout "$FIX" 2>&1); ck "a path that is no worktree is refused" "$?" "3"
out=$(svc "$P" start gated 2>&1); ck "an unmet need is refused" "$?" "5"
out=$(svc "$P" start probe 2>&1); ck "a status-only service has nothing to start" "$?" "7"
svc "$P" start web >/dev/null 2>&1
ck "an inline start runs from main's worktree" "$(cat "$MAIN/started.txt" 2>/dev/null)" "web-up"
svc "$P" stop worker >/dev/null 2>&1
sleep 0.3
kill -0 "$W" 2>/dev/null && bad "stop: signal sends TERM" || ok "stop: signal sends TERM"
ck "and its record is gone" "$(ls "$LV_SERVICES_DIR/alpha" | grep -c '^worker\.' )" "0"
svc "$P" start worker --checkout "$FEAT" >/dev/null 2>&1
has "a window start opens the chosen checkout" "$(tail -1 "$FIX/opened" 2>/dev/null)" "cd $FEAT && tools/worker.sh"
svc "$P" console >/dev/null 2>&1
has "console opens the project's own board" "$(tail -1 "$FIX/opened")" "tools/board.sh"

echo "── records that outlive what they name ──"
live; D=$LAST; (cd "$MAIN" && "$SVC" beacon up worker --pid "$D"); kill "$D"; wait "$D" 2>/dev/null
svc "$P" status >/dev/null
ck "a dead pid's record is removed by status" "$(ls "$LV_SERVICES_DIR/alpha" | grep -c "worker.$D.rec")" "0"
(cd "$MAIN" && "$SVC" beacon up web --detached)
ck "a detached record goes once its probe says down" "$(svc "$P" status | awk -F'\t' '$1=="web"{print $2 $4}'; ls "$LV_SERVICES_DIR/alpha" | grep -c '^web\.0')" "down-
0"

echo "── the rack's view ──"
mkdir -p "$P/scripts"
printf '#!/usr/bin/env bash\nn=$1; shift; exec "%s/$n" "$@"\n' "$SCRIPTS" > "$P/scripts/lv-exec.sh"
chmod +x "$P/scripts/lv-exec.sh"
live; W2=$LAST; (cd "$FEAT" && "$SVC" beacon up worker --pid "$W2")
export LV_DEPLOYMENTS="$FIX/deployments.txt" LV_BOARD_CACHE="$FIX/cache" LV_DORMANT_STATE="$FIX/dormant" LV_RACK_LIB=1
printf '%s\n' "$P" "$FIX/no-harness" > "$LV_DEPLOYMENTS"
mkdir -p "$FIX/no-harness"
# shellcheck disable=SC1090
source "$BOARD"
sv_collect
ck "every service of every project with a harness" "${#SV_ID[@]}" "4"
table=$(sv_table)
has "a worker off main shows as its branch, flagged" "$table" "PLN-9-x ⚠"
has "a down service shows down" "$(grep ' web ' <<< "$table")" "down"
ck "the board's services cell: declared, then distinct ids up" "$(sv_counts "$P")" "4 1"
ck "a project with no services: block declares none" "$(sv_counts "$FIX/no-harness")" "0 0"

echo "── z: making a project dormant stops its daemon first ──"
mkdir -p "$P/.claude/orchestrator"
live; DM=$LAST; echo "$DM" > "$P/.claude/orchestrator/daemon.pid"
hx() { kill "$(cat "$P/.claude/orchestrator/daemon.pid")"; }
out=$(stop_and_sleep "$P"); rc=$?; wait "$DM" 2>/dev/null
ck "stop_and_sleep succeeds" "$rc" "0"
kill -0 "$DM" 2>/dev/null && bad "the daemon is stopped" || ok "the daemon is stopped"
ck "and the project is dormant" "$(dormant_state "$P")" "dormant"
set_dormant "$P" off >/dev/null
live; DM=$LAST; echo "$DM" > "$P/.claude/orchestrator/daemon.pid"
hx() { :; }; wait_until_stopped() { return 1; }
out=$(stop_and_sleep "$P"); rc=$?
ck "a daemon that will not stop leaves it on (exit 3)" "$rc" "3"
ck "still not dormant" "$(is_dormant "$P" && echo dormant || echo on)" "on"
rm -f "$P/.claude/orchestrator/daemon.pid"

out=$(LV_RACK_LIB= bash "$BOARD" --services --plain </dev/null 2>&1)
has "--services prints the table" "$out" "PROJECT"
has "--services lists the project" "$out" "alpha"

echo
[ "$fails" -eq 0 ] && { echo "services: all passed"; exit 0; }
echo "services: $fails failed"; exit 1
