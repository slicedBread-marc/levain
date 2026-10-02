#!/usr/bin/env bash
# sweep.test.sh — LVI-031: the blind library sweep behind the board's `W`.
#
#   tests/rack/sweep.test.sh
#
# The library, its sweep-issues.sh and deploy-all.sh are fixtures, and
# LV_SWEEP_CLAUDE is a stand-in that commits a fix and reports it: no real
# session is ever started, and nothing here reads the operator's portfolio.
# lock.sh is the real one, copied into the fixture library.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
SWEEP="$SCRIPTS/lv-library-sweep.sh"
BOARD="$SCRIPTS/lv-rack.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-sweep.XXXXXX")" && pwd -P)"
LIVE=""
cleanup() { [ -n "$LIVE" ] && { kill "$LIVE"; wait "$LIVE"; } 2>/dev/null; rm -rf "$FIX"; return 0; }
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }

LIB="$FIX/lib"; STATE="$FIX/state"
export CALLS="$FIX/calls.log"

# ── Fixture library ─────────────────────────────────────────────────────
new_lib() {
  rm -rf "$LIB" "$STATE"; : > "$CALLS"
  mkdir -p "$LIB/tests" "$STATE"
  printf '1.0.0\n' > "$LIB/VERSION"
  cp "$REPO_ROOT/lock.sh" "$LIB/lock.sh"
  cat > "$LIB/sweep-issues.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --count) printf 'alpha: %s\nbeta: 0\n' "${STUB_COUNT:-2}" ;;
  --resolve) echo "resolve $2 $4 $5" >> "$CALLS" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho deployed >> "$CALLS"\n' > "$LIB/deploy-all.sh"
  chmod +x "$LIB"/*.sh
  git -C "$LIB" init -q
  printf 'LIBRARY-LOCK.md\n' > "$LIB/.git/info/exclude"
  git -C "$LIB" add -A && git -C "$LIB" -c user.name=t -c user.email=t@t commit -qm init
}

# The stand-in session: records how it was started, checks the lock is its
# own, commits a change to $STUB_TOUCH, and reports it the way the prompt asks.
cat > "$FIX/claude" <<'STUB'
#!/usr/bin/env bash
{ echo "claude unattended=${LV_UNATTENDED:-} $*" | head -c 200; echo; } >> "$CALLS"
./lock.sh status >/dev/null 2>&1; echo "lock-status $?" >> "$CALLS"
for a in "$@"; do case "$a" in *--upstream*NEVER*|*NEVER\ pass\ --upstream*) echo "told-no-upstream" >> "$CALLS" ;; esac; done
[ -n "${STUB_TOUCH:-}" ] || { echo "nothing to do"; exit 0; }
mkdir -p "$(dirname "$STUB_TOUCH")"; echo fix >> "$STUB_TOUCH"
git add -A && git -c user.name=t -c user.email=t@t commit -qm "fix(x): LVI-001"
echo "SWEEP_FIXED LVI-001 alpha $(git rev-parse --short HEAD)"
echo "SWEEP_FIXED LVI-009 alpha $(git rev-parse --short HEAD~1)"
STUB
chmod +x "$FIX/claude"
export LV_SWEEP_CLAUDE="$FIX/claude" LV_RACK_SUITE="exit 0"

echo "── count ──"
new_lib
ck "the open issues of every client, summed" "$("$SWEEP" count "$LIB")" "2"

echo "── a sweep that fixes, deploys and resolves ──"
STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "it exits 0" "$rc" "0"
has "the session runs unattended, unprompted, under the baseline settings" \
  "$(grep '^claude' "$CALLS")" "unattended=1 -p --dangerously-skip-permissions --settings $STATE/settings.json"
ck "the lock is the session's own while it runs" "$(grep '^lock-status' "$CALLS")" "lock-status 2"
ck "it is told never to read the upstream list" "$(grep -c told-no-upstream "$CALLS")" "1"
ck "the settings name the baseline guard, failing closed" \
  "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]; print(c["matcher"], "lv-guard-baseline.sh" in c["hooks"][0]["command"], c["hooks"][0]["command"].endswith("exit 2"))' "$STATE/settings.json")" \
  "* True True"
ck "a green suite deploys" "$(grep -c '^deployed' "$CALLS")" "1"
has "the fix is resolved against its commit" "$(grep '^resolve' "$CALLS")" "resolve LVI-001 alpha fixed in v1.0.0"
ck "a fix citing a commit from before the sweep is not resolved" "$(grep -c 'resolve LVI-009' "$CALLS")" "0"
has "the result line" "$(cat "$STATE/result")" "fixed 1 · left 2 · deployed v1.0.0"
ck "the lock is released" "$([ -f "$LIB/LIBRARY-LOCK.md" ] && echo held || echo free)" "free"
ck "no pid is left behind" "$([ -f "$STATE/pid" ] && echo yes || echo no)" "no"
ck "nothing is left pending" "$([ -f "$STATE/pending" ] && echo yes || echo no)" "no"

echo "── a fix to a guard file is committed, never deployed ──"
new_lib
STUB_TOUCH=deploy-all.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "no deploy" "$(grep -c '^deployed' "$CALLS")" "0"
ck "no resolve" "$(grep -c '^resolve' "$CALLS")" "0"
has "the board is told to hold it for review" "$(cat "$STATE/result")" "held for review — guard files changed: deploy-all.sh"
ck "the fix waits in pending" "$(cut -f1,2 "$STATE/pending")" "LVI-001	alpha"
"$SWEEP" resolve-pending "$LIB" "$STATE" >/dev/null 2>&1
has "the operator's deploy resolves it" "$(grep '^resolve' "$CALLS")" "resolve LVI-001 alpha"
ck "and empties pending" "$([ -f "$STATE/pending" ] && echo yes || echo no)" "no"

echo "── a red suite holds ──"
new_lib
LV_RACK_SUITE="exit 1" STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "no deploy" "$(grep -c '^deployed' "$CALLS")" "0"
has "held for review" "$(cat "$STATE/result")" "held for review — the suite is red"

echo "── refusals ──"
new_lib
STUB_COUNT=0 "$SWEEP" start "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "no open issues: refused" "$rc" "3"
echo dirty >> "$LIB/VERSION"
out=$("$SWEEP" start "$LIB" "$STATE" 2>&1); rc=$?
ck "a dirty library: refused" "$rc" "3"
has "and says why" "$out" "uncommitted changes"
git -C "$LIB" checkout -q VERSION
sleep 600 & LIVE=$!
(cd "$LIB" && LV_SESSION_PID="$LIVE" ./lock.sh take other "mid-edit" >/dev/null 2>&1)
out=$("$SWEEP" start "$LIB" "$STATE" 2>&1); rc=$?
ck "a held lock: refused" "$rc" "3"
has "and says why" "$out" "LIBRARY-LOCK.md is held"
ck "no session was started" "$(grep -c '^claude' "$CALLS")" "0"
rm -f "$LIB/LIBRARY-LOCK.md"
LV_SWEEP_CLAUDE="$FIX/no-such-claude" "$SWEEP" start "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "no claude on PATH: refused" "$rc" "3"
printf '%s\n' "$LIVE" > "$STATE/pid"
out=$("$SWEEP" start "$LIB" "$STATE" 2>&1); rc=$?
ck "one sweep at a time" "$rc:$(printf '%s' "$out" | grep -c 'already running')" "3:1"
rm -f "$STATE/pid"

echo "── start detaches, and the board reads it ──"
new_lib
STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" start "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "start returns at once" "$rc" "0"
for _ in $(seq 1 50); do [ -f "$STATE/result" ] && break; sleep 0.2; done
has "the detached run finishes on its own" "$(cat "$STATE/result" 2>/dev/null)" "deployed v1.0.0"
has "and its log is where latest says" "$(cat "$(cat "$STATE/latest")")" "== result: fixed 1"

export LV_SWEEP_STATE="$STATE" LV_LIBRARY_DIR="$LIB" LV_RACK_LIB=1
export LV_DEPLOYMENTS="$FIX/deployments.txt" LV_BOARD_CACHE="$FIX/cache"
: > "$LV_DEPLOYMENTS"
# shellcheck disable=SC1090
source "$BOARD"
refresh_library_count
has "the library line carries the count" "$(library_sweep_line)" " · 2 open issues"
has "and the last result" "$(library_sweep_line)" "sweep: fixed 1 · left 2 · deployed v1.0.0"
printf '%s\n' "$LIVE" > "$STATE/pid"
has "a live sweep reads as sweeping" "$(library_sweep_line)" "sweeping…"
rm -f "$STATE/pid"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
