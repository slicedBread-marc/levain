#!/usr/bin/env bash
# dormant.test.sh — LVI-027 and LVI-026 on the board: dormant projects are not
# scanned, a live daemon keeps a project on, the daemon checks ignore the hide;
# the harness row compares versions, and `U` deploys only past the lock, a
# clean tree and a green suite.
#
#   tests/rack/dormant.test.sh
#
# Sourced with LV_RACK_LIB=1, like the other rack suites. Every state file and
# the library are fixtures: nothing here reads the operator's real portfolio.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
# No real pack: a hook here must never reach the operator's publisher.
export LV_PACKS=

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-dormant.XXXXXX")" && pwd -P)"
LIVE=""
cleanup() { [ -n "$LIVE" ] && { kill "$LIVE"; wait "$LIVE"; } 2>/dev/null; rm -rf "$FIX"; return 0; }
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }

# ── Fixture: three clients, one with a live stand-in daemon ─────────────
for c in alpha beta gamma; do
  mkdir -p "$FIX/$c/scripts" "$FIX/$c/.claude/orchestrator"
  cat > "$FIX/$c/scripts/lv-exec.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$PWD") $*" >> "$RACK_CALLS"
[ "$1" = lv-tray.sh ] && printf 'daemon=off\trunning=0\tregistry=clean\n'
exit 0
STUB
  chmod +x "$FIX/$c/scripts/lv-exec.sh"
done
sleep 600 & LIVE=$!
echo "$LIVE" > "$FIX/gamma/.claude/orchestrator/daemon.pid"
printf '14.0.0\n' > "$FIX/alpha/.claude/workflow-version"
printf '14.1.0\n' > "$FIX/beta/.claude/workflow-version"

export RACK_CALLS="$FIX/calls.log"
export LV_DEPLOYMENTS="$FIX/deployments.txt"
export LV_DORMANT_STATE="$FIX/coord/dormant"
export LV_BOARD_CACHE="$FIX/coord/cache"
export LV_LIBRARY_DIR="$FIX/lib"
export LV_RACK_LIB=1
printf '%s\n' "$FIX/alpha" "$FIX/beta" "$FIX/gamma" > "$LV_DEPLOYMENTS"
# shellcheck disable=SC1090
source "$BOARD"

scanned() { scan_projects | xargs -n1 basename | tr '\n' ' '; }

echo "── dormant (LVI-027) ──"
ck "everything is scanned with nothing dormant" "$(scanned)" "alpha beta gamma "
set_dormant "$FIX/beta" on >/dev/null
ck "a dormant project is not scanned" "$(scanned)" "alpha gamma "
: > "$RACK_CALLS"; collect_all
ck "collect never shells into a dormant project" "$(grep -c '^beta' "$RACK_CALLS")" "0"
ck "and it takes no column" "${names[*]}" "$(printf '%s\n' "${names[@]}" | grep -vx beta | tr '\n' ' ' | sed 's/ $//')"
set_dormant "$FIX/gamma" on >/dev/null; rc=$?
ck "sleeping a project with a live daemon is refused" "$rc" "3"
ck "and records nothing" "$(grep -c gamma "$LV_DORMANT_STATE")" "0"
printf '%s\n' "$FIX/gamma" >> "$LV_DORMANT_STATE"
ck "a live daemon keeps a dormant project on the board" "$(scanned)" "alpha gamma "
ck "the list says so" "$(dormant_state "$FIX/gamma")" "always on"
show_all=true
ck "--all alone still hides them" "$(scanned)" "alpha gamma "
show_all=false; include_dormant=true
ck "--include-dormant scans them too" "$(scanned)" "alpha beta gamma "
include_dormant=false
ck "the daemon checks ignore the hide" "$(each_project | xargs -n1 basename | tr '\n' ' ')" "alpha beta gamma "
set_dormant "$FIX/beta" off >/dev/null
ck "waking puts it back" "$(scanned)" "alpha beta gamma "
ck "--sleep resolves a name" "$(resolve_project beta)" "$FIX/beta"
resolve_project nosuch >/dev/null; ck "--sleep refuses a name not in the registry" "$?" "1"
cli() { env -u LV_RACK_LIB bash "$BOARD" "$@"; }
cli --sleep alpha >/dev/null
ck "--sleep from the command line" "$(cli --dormant | awk '$1=="alpha"{print $2}')" "dormant"
cli --wake alpha >/dev/null
ck "--wake from the command line" "$(cli --dormant | awk '$1=="alpha"{print $2}')" "on"

echo "── harness row and U (LVI-026) ──"
mkdir -p "$FIX/lib/tests"
printf '14.1.0\n' > "$FIX/lib/VERSION"
cat > "$FIX/lib/deploy-all.sh" <<'STUB'
#!/usr/bin/env bash
echo deployed >> "$RACK_CALLS"
STUB
chmod +x "$FIX/lib/deploy-all.sh"
git -C "$FIX/lib" init -q && git -C "$FIX/lib" add -A && git -C "$FIX/lib" -c user.name=t -c user.email=t@t commit -qm init
names=(alpha beta); paths=("$FIX/alpha" "$FIX/beta"); statuses=(ok ok)
compute_shown
grid=$(render_text)
ck "the harness row shows each client's stamp" "$(printf '%s\n' "$grid" | grep '^  harness' | tr -s ' ')" " harness 14.0.0 14.1.0"
ck "and the library's version" "$(printf '%s\n' "$grid" | grep -c 'library 14.1.0')" "1"

export LV_DEPLOY_LOGS="$FIX/deploy-logs"; DEPLOY_LOGS="$LV_DEPLOY_LOGS"
export LV_RACK_SUITE="exit 1"
: > "$RACK_CALLS"; deploy_library >/dev/null 2>&1; rc=$?
ck "a red suite refuses the deploy" "$rc:$(grep -c deployed "$RACK_CALLS")" "3:0"
export LV_RACK_SUITE="exit 0"
echo x >> "$FIX/lib/VERSION"
: > "$RACK_CALLS"; deploy_library >/dev/null 2>&1; rc=$?
ck "a dirty library refuses the deploy" "$rc:$(grep -c deployed "$RACK_CALLS")" "3:0"
git -C "$FIX/lib" checkout -q VERSION
printf '#!/usr/bin/env bash\nexit 1\n' > "$FIX/lib/lock.sh"; chmod +x "$FIX/lib/lock.sh"
echo lock.sh > "$FIX/lib/.git/info/exclude"
: > "$RACK_CALLS"; deploy_library >/dev/null 2>&1; rc=$?
ck "a held lock refuses the deploy" "$rc:$(grep -c deployed "$RACK_CALLS")" "3:0"
rm -f "$FIX/lib/lock.sh"
: > "$RACK_CALLS"; deploy_library >/dev/null 2>&1; rc=$?
ck "lock free, tree clean, suite green: it deploys, unprompted" "$rc:$(grep -c deployed "$RACK_CALLS")" "0:1"
# LVI-062: every U run leaves a log, and the suite prints a line per test.
export LV_DEPLOY_LOGS="$FIX/deploy-logs"; DEPLOY_LOGS="$LV_DEPLOY_LOGS"
export LV_RACK_SUITE="exit 1"
deploy_library >/dev/null 2>&1
ck "a refused deploy leaves a log naming why" "$(grep -c 'suite is red' "$DEPLOY_LOGS/latest.log")" "1"
ck "the log ends with the exit code" "$(tail -1 "$DEPLOY_LOGS/latest.log" | cut -d' ' -f1-2)" "exit 3"
ck "the log holds no colour codes" "$(grep -c $'\033' "$DEPLOY_LOGS/latest.log")" "0"
unset LV_RACK_SUITE
mkdir -p "$FIX/suite/tests"
printf 'echo fine\n' > "$FIX/suite/tests/a.sh"
printf 'echo "  ✗ the thing broke"; exit 1\n' > "$FIX/suite/tests/b.sh"
out=$(LIB_DIR="$FIX/suite" SUITE_LOG_DIR="$FIX/suite-logs" run_library_suite 2>&1); rc=$?
ck "the suite names each test with a counter" "$(printf '%s\n' "$out" | grep -c '\[[12]/2\]')" "2"
ck "a failing test shows its ✗ line" "$rc:$(printf '%s\n' "$out" | grep -c 'the thing broke')" "1:1"
ck "and keeps its full output" "$(cat "$FIX/suite-logs/b.log" 2>/dev/null | grep -c broke)" "1"
export LV_RACK_SUITE="exit 0"
LIB_DIR=""
deploy_library >/dev/null 2>&1; ck "no library, no deploy" "$?" "3"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
