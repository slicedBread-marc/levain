#!/usr/bin/env bash
# lv-rack-cutover.test.sh — the rack drives clients on both sides of 14.0.0.
#
#   tests/rack/cutover.test.sh
#
# During the cutover some clients have lv-exec.sh (14.0.0, which also ships a
# wf-exec.sh shim) and some only wf-exec.sh (13.x). Every call into a client
# goes through hx, which must pick lv-exec.sh when it exists and otherwise
# translate the lv- script name back to its 13.x name — lv-tray was wf-board.
# Stubs record the argv they were called with. Same sourcing technique as the
# other rack tests.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-cutover-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s — expected: %s, got: %s\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "$2" "$3"; fi; }

stub() {   # stub <client> <exec-name>
  mkdir -p "$FIX/$1/scripts"
  printf '#!/usr/bin/env bash\necho "%s $*"\n' "$2" > "$FIX/$1/scripts/$2"
  chmod +x "$FIX/$1/scripts/$2"
}
stub old wf-exec.sh                          # 13.x
stub new lv-exec.sh; stub new wf-exec.sh     # 14.0.0, with its shim
mkdir -p "$FIX/none" "$FIX/new/.claude/skills/lv-attend"

printf '%s\n' "$FIX/old" "$FIX/new" > "$FIX/deployments.txt"
# shellcheck disable=SC1090
LV_RACK_LIB=1 LV_DEPLOYMENTS="$FIX/deployments.txt" LV_BOARD_CACHE="$FIX/cache" \
  LV_SUSPEND_STATE="$FIX/suspended" source "$BOARD" </dev/null

echo "hx picks the harness each client has"
is "a 14.0.0 client runs lv-tray by its own name"   "lv-exec.sh lv-tray.sh --fields" \
   "$(cd "$FIX/new" && hx lv-tray.sh --fields)"
is "a 13.x client gets wf-board for lv-tray"         "wf-exec.sh wf-board.sh --fields" \
   "$(cd "$FIX/old" && hx lv-tray.sh --fields)"
is "and wf-board-drill for lv-tray-drill"            "wf-exec.sh wf-board-drill.sh list" \
   "$(cd "$FIX/old" && hx lv-tray-drill.sh list)"
is "and the plain wf- name for anything else"        "wf-exec.sh wf-orchestrate.sh --stop" \
   "$(cd "$FIX/old" && hx lv-orchestrate.sh --stop)"
is "no harness is a 127, not a guess"                "127" \
   "$(cd "$FIX/none" && hx lv-tray.sh >/dev/null 2>&1; echo $?)"

echo "has_harness"
is "a 13.x client has one"   "0" "$(has_harness "$FIX/old"; echo $?)"
is "a 14.0.0 client has one" "0" "$(has_harness "$FIX/new"; echo $?)"
is "a bare dir has none"     "1" "$(has_harness "$FIX/none"; echo $?)"

echo "attend opens the skill the client has"
printf '#!/usr/bin/env bash\necho "$*" > "%s/attend.out"\n' "$FIX" > "$FIX/claude-stub"; chmod +x "$FIX/claude-stub"
LV_ATTEND_CMD="$FIX/claude-stub" attend_session "$FIX/new" PLN-001 </dev/null >/dev/null 2>&1
is "/lv-attend on a 14.0.0 client" "/lv-attend PLN-001" "$(cat "$FIX/attend.out" 2>/dev/null)"
LV_ATTEND_CMD="$FIX/claude-stub" attend_session "$FIX/old" PLN-002 </dev/null >/dev/null 2>&1
is "/wf-attend on a 13.x client"   "/wf-attend PLN-002" "$(cat "$FIX/attend.out" 2>/dev/null)"

echo
if [ "$fails" -eq 0 ]; then echo "all assertions passed"; exit 0; else echo "$fails failed"; exit 1; fi
