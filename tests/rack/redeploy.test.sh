#!/usr/bin/env bash
# redeploy.test.sh — lv-services.sh redeploy (the coordinator's LVI-057): a service running
# from main is restarted once a release moves main past the commit its container was built
# from, status shows how far behind it is, --auto stays quiet where it must, and a failed
# start is not retried for the same main commit.
#
#   tests/rack/redeploy.test.sh
#
# docker is a stub on PATH; the "container" is a file holding its image revision label.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
SVC="$SCRIPTS/lv-services.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-redeploy.XXXXXX")" && pwd -P)"
SLEEPER=""
cleanup() { [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$FIX"; return 0; }
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }

unset CLAUDECODE
export LV_SERVICES_DIR="$FIX/state" LV_SERVICES_STOP_WAIT=3
export LV_SERVICES_OPENER="$FIX/opener"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/opened"\n' "$FIX" > "$LV_SERVICES_OPENER"
chmod +x "$LV_SERVICES_OPENER"

mkdir -p "$FIX/bin"
cat > "$FIX/bin/docker" <<SH
#!/usr/bin/env bash
case "\$1" in
  ps) [ -f "$FIX/docker-up" ] && echo c1 ;;
  inspect) if [ -s "$FIX/docker-rev" ]; then cat "$FIX/docker-rev"; else echo '<no value>'; fi ;;
esac
exit 0
SH
chmod +x "$FIX/bin/docker"
export PATH="$FIX/bin:$PATH"

P="$FIX/beta"
git init -q -b develop "$P"
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
git -C "$P" branch main
git -C "$P" worktree add -q "$P/release-branches/main" main
MAIN="$P/release-branches/main"
cat > "$P/levain.yml" <<'YML'
project_slug: "beta"
services:
  hh:
    label: "Household"
    start: "tools/hh.sh up"
    stop: "tools/hh.sh down"
    compose: "beta-hh"
    redeploy: auto
YML
mkdir -p "$MAIN/tools"
cat > "$MAIN/tools/hh.sh" <<SH
#!/usr/bin/env bash
echo "\$1" >> "$FIX/hh.calls"
case "\$1" in
  up) [ -f "$FIX/hh-fail" ] && { echo "no key" >&2; exit 3; }
      git rev-parse HEAD > "$FIX/docker-rev"; touch "$FIX/docker-up" ;;
  down) rm -f "$FIX/docker-up" ;;
esac
SH
chmod +x "$MAIN/tools/hh.sh"
svc() { (cd "$P" && "$SVC" "$@"); }
advance() { git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "$1"; }
calls() { cat "$FIX/hh.calls" 2>/dev/null | tr '\n' ' '; }

echo "── status reads the running container's revision ──"
svc start hh >/dev/null 2>&1
ck "the start ran" "$(calls)" "up "
OLD=$(git -C "$P" rev-parse main)
row=$(svc status | awk -F'\t' '$1=="hh"')
ck "a beacon-less compose service shows the commit it was built from" "$(cut -f6 <<< "$row")" "${OLD:0:7}"
ck "at main: no flags" "$(cut -f9 <<< "$row")" "-"
ck "start recorded the deployed commit" "$(sed -n 's/^commit=//p' "$LV_SERVICES_DIR/beta/hh.deployed")" "$OLD"
advance two
NEW=$(git -C "$P" rev-parse main)
ck "a release on main shows it behind" "$(svc status | awk -F'\t' '$1=="hh"{print $9}')" "behind=1"

echo "── redeploy ──"
: > "$FIX/hh.calls"
out=$(svc redeploy --dry-run 2>&1)
ck "--dry-run says what it would do" "$out" "WOULD hh ${OLD:0:7} -> ${NEW:0:7}"
ck "…and does nothing" "$(calls)" ""
out=$(CLAUDECODE=1 svc redeploy 2>&1); ck "refused under an agent" "$?" "2"
out=$(CLAUDECODE=1 svc redeploy --auto 2>&1); rc=$?
ck "--auto under an agent is silent" "$rc:$out" "0:"
ck "…and does nothing" "$(calls)" ""
out=$(svc redeploy --auto 2>&1); rc=$?
ck "--auto restarts a service main moved past" "$rc:$out" "0:REDEPLOYED hh ${OLD:0:7} -> ${NEW:0:7}"
ck "…stop, then start" "$(calls)" "down up "
ck "the container now runs main" "$(cat "$FIX/docker-rev")" "$NEW"
ck "status: no longer behind" "$(svc status | awk -F'\t' '$1=="hh"{print $9}')" "-"
: > "$FIX/hh.calls"
out=$(svc redeploy --auto 2>&1)
ck "at main: nothing to do, nothing said" "$out$(calls)" ""

echo "── the label wins; .deployed is the fallback ──"
: > "$FIX/docker-rev"
ck "no label: the start's record" "$(svc status | awk -F'\t' '$1=="hh"{print $6}')" "${NEW:0:7}"
echo "$OLD" > "$FIX/docker-rev"
ck "a label overrides it" "$(svc status | awk -F'\t' '$1=="hh"{print $6}')" "${OLD:0:7}"
echo "$NEW" > "$FIX/docker-rev"

echo "── a failed start is recorded, and --auto does not retry it ──"
advance three
TIP=$(git -C "$P" rev-parse main)
touch "$FIX/hh-fail"; : > "$FIX/hh.calls"
out=$(svc redeploy --auto 2>&1); rc=$?
ck "a start that fails exits 1" "$rc" "1"
has "…and says FAILED" "$out" "FAILED hh ${NEW:0:7} -> ${TIP:0:7}"
ck "…recording main's commit" "$(sed -n 's/^failed=//p' "$LV_SERVICES_DIR/beta/hh.redeploy")" "$TIP"
touch "$FIX/docker-up"; : > "$FIX/hh.calls"     # brought back by hand, on the old build
out=$(svc redeploy --auto 2>&1)
ck "--auto leaves the same main commit alone" "$out$(calls)" ""
rm -f "$FIX/hh-fail"
out=$(svc redeploy 2>&1)
ck "an explicit redeploy tries again" "$out" "REDEPLOYED hh ${NEW:0:7} -> ${TIP:0:7}"
[ -f "$LV_SERVICES_DIR/beta/hh.redeploy" ] && bad "a success clears the failure" || ok "a success clears the failure"

echo "── one redeploy per project ──"
advance four
sleep 600 & SLEEPER=$!
mkdir -p "$LV_SERVICES_DIR/beta/redeploy.lock"; echo "$SLEEPER" > "$LV_SERVICES_DIR/beta/redeploy.lock/pid"
: > "$FIX/hh.calls"
out=$(svc redeploy --auto 2>&1); rc=$?
ck "--auto with the lock held is silent" "$rc:$out$(calls)" "0:"
out=$(svc redeploy 2>&1); ck "an explicit one says so (exit 6)" "$?" "6"
kill "$SLEEPER" 2>/dev/null; wait "$SLEEPER" 2>/dev/null; SLEEPER=""
out=$(svc redeploy --auto 2>&1)
has "a dead holder's lock is taken over" "$out" "REDEPLOYED hh"
[ -d "$LV_SERVICES_DIR/beta/redeploy.lock" ] && bad "the lock is released" || ok "the lock is released"

echo "── the rack collector runs it after a full collect ──"
advance collector; : > "$FIX/hh.calls"
TIP=$(git -C "$P" rev-parse main)
collect_redeploy() {
  ( LV_RACK_LIB=1 LV_BOARD_CACHE="$FIX/cache"; export LV_RACK_LIB LV_BOARD_CACHE
    # shellcheck source=../../scripts/v2.00/lv-rack.sh
    source "$SCRIPTS/lv-rack.sh"
    COLLECTOR_LOG="$FIX/collector.log"
    has_harness() { return 0; }
    hx() { local s="$1"; shift; "$SCRIPTS/$s" "$@"; }
    paths=("$P" "$FIX/no-such-project")
    collector_redeploy; wait )
}
CLAUDECODE=1 collect_redeploy
ck "a collector under an agent does nothing" "$(calls)$(cat "$FIX/collector.log" 2>/dev/null)" ""
LV_RACK_REDEPLOY=off collect_redeploy
ck "LV_RACK_REDEPLOY=off does nothing" "$(calls)" ""
collect_redeploy
has "the collector log carries the REDEPLOYED line" "$(cat "$FIX/collector.log" 2>/dev/null)" "redeploy beta: REDEPLOYED hh"
ck "…and main now runs" "$(cat "$FIX/docker-rev")" "$TIP"

echo "── a service not on main is never redeployed ──"
printf '    checkout: any\n' >> "$P/levain.yml"
advance five; : > "$FIX/hh.calls"
out=$(svc redeploy --auto 2>&1)
ck "checkout: any is left alone" "$out$(calls)" ""

echo ""
[ "$fails" -eq 0 ] && echo "redeploy: all passed" || echo "redeploy: $fails failed"
[ "$fails" -eq 0 ]
