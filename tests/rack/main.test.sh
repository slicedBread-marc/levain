#!/usr/bin/env bash
# lv-rack-main.test.sh — `m` goes straight back to the main screen.
#
#   tests/rack/main.test.sh
#
# Every screen below the board lists `m main`, and m returns from any depth
# in one key; Esc still goes up one level. q is no longer a sub-screen key: it
# used to mean "back to the board" one level down and "quit" on the board.
# The board's legend also lists z, which worked but was never advertised.
# Same sourcing technique as the other board tests.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wf-main-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
says() { if grep -qF "$3" "$2"; then ok "$1"; else bad "$1 — expected: $3"; fi; }
nsays(){ if grep -qF "$3" "$2"; then bad "$1 — did not expect: $3"; else ok "$1"; fi; }
flag() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected $3, got $2"; fi; }

CLIENT="$FIX/alpha"
mkdir -p "$CLIENT/scripts"
cat > "$CLIENT/scripts/wf-exec.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "wf-board-drill.sh" ] || exit 0
shift
case "$1 ${2:-}" in
  "row gates")        printf 'PLN-042 spec-approval\tlist\tgate PLN-042\n' ;;
  "gate PLN-042")     printf 'gate file\tnone\t-\n' ;;
  *) echo "stub: no such node $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$CLIENT/scripts/wf-exec.sh"

LV_RACK_LIB=1
LV_BOARD_CACHE="$FIX/cache"
LV_SUSPEND_STATE="$FIX/suspended"
export LV_RACK_LIB LV_BOARD_CACHE LV_SUSPEND_STATE
# shellcheck source=../bin/lv-rack
source "$BOARD"
DEPLOYMENTS="$FIX/deployments.txt"
printf '%s\n' "$CLIENT" > "$DEPLOYMENTS"
refresh_one() { :; }

seed() {
  names=("alpha"); paths=("$CLIENT"); statuses=("ok")
  f_daemon=("off"); f_running=("0")
  f_gates=("1"); f_gates_stuck=("0"); f_gates_blocked=("0")
  f_draft=("1"); f_ready=("0"); f_active=("0"); f_verify=("0"); f_testing=("0")
  f_complete=("0"); f_abandoned=("0")
  f_registry=("clean"); f_attn=(""); f_release=("-"); f_deploy=("-")
  f_ideas=("0"); f_ideas_drift=("0"); f_ts=("$(date +%s)")
  rm -rf "$LV_BOARD_CACHE"
  to_main=false; back_to_board=false
}

echo "lv-rack m returns to main"

# 1. Two levels down a drill, m leaves both. Redirected, not piped, so the
# flag drill_browse leaves is visible here.
seed
printf '\nm' > "$FIX/keys"
drill_browse 0 "gates" "row gates" < "$FIX/keys" > "$FIX/drill.txt" 2>&1
flag "m in a drill level returns to main" "$to_main" true
says "the drill level advertises m main" "$FIX/drill.txt" "m main"
nsays "and no longer q board"            "$FIX/drill.txt" "q board"
# After the second level is drawn, the first must not be drawn again.
after() { awk '/gate file/ { seen = 1; buf = ""; next } seen { buf = buf $0 "\n" } END { printf "%s", buf }' "$1"; }
if after "$FIX/drill.txt" | grep -q "PLN-042 spec-approval"; then bad "and does not stop at the level above"
else ok "and does not stop at the level above"; fi

# 2. Esc still goes up one level, not to main.
seed
printf '\n\x1b' > "$FIX/keys"
drill_browse 0 "gates" "row gates" < "$FIX/keys" > "$FIX/esc.txt" 2>&1
flag "esc does not go to main" "$to_main" false
if after "$FIX/esc.txt" | grep -q "PLN-042 spec-approval"; then ok "esc repaints the level above"
else bad "esc repaints the level above"; fi

# 3. q in a drill level does nothing now.
seed
printf 'q' > "$FIX/keys"
drill_browse 0 "gates" "row gates" < "$FIX/keys" > /dev/null 2>&1
flag "q in a drill level is not main" "$to_main" false

# 4. The pager.
seed
printf 'line\n' > "$FIX/log.txt"
printf 'm' > "$FIX/keys"
view_file "alpha — log" "$FIX/log.txt" no "$CLIENT" < "$FIX/keys" > "$FIX/view.txt" 2>&1
flag "m in a log returns to main" "$to_main" true
says "the log advertises m main" "$FIX/view.txt" "m main"

# 5. The project menu, and a drill opened from it (action 6): m in the drill
# does not land back on the menu.
seed
printf 'm' > "$FIX/keys"
project_menu 0 < "$FIX/keys" > "$FIX/pm.txt" 2>&1
flag "m in the project menu returns to main" "$to_main" true
says "the project menu advertises m) main" "$FIX/pm.txt" "m) main"

seed
printf '6m' > "$FIX/keys"
project_menu 0 < "$FIX/keys" > "$FIX/pm-drill.txt" 2>&1
flag "m in a drill opened from the menu returns to main" "$to_main" true
n=$(grep -c "b) back" "$FIX/pm-drill.txt")
flag "and the menu is not repainted" "$n" 1

# 6. The on/dormant list.
seed
printf 'm' > "$FIX/keys"
dormant_screen < "$FIX/keys" > "$FIX/dormant.txt" 2>&1
flag "m in the on/dormant list returns to main" "$to_main" true
says "the list advertises m main" "$FIX/dormant.txt" "m main"
nsays "and no longer q back"     "$FIX/dormant.txt" "q back"

# 7. The picker under --watch is a sub-screen: m leaves it, q does not.
seed; watch_mode=true
render() { :; }
printf 'm\nnever\n' > "$FIX/keys"
menu_loop < "$FIX/keys" > "$FIX/picker.txt" 2>&1
nsays "m in the picker under --watch leaves it" "$FIX/picker.txt" "not a valid choice"
says "the picker advertises m main"             "$FIX/picker.txt" "m main"
printf 'q\n' > "$FIX/keys"
menu_loop < "$FIX/keys" > "$FIX/picker-q.txt" 2>&1
says "q in the picker under --watch is not a key" "$FIX/picker-q.txt" "not a valid choice"

# Without --watch the picker is the main screen, and q quits it.
watch_mode=false
printf 'q\nnever\n' > "$FIX/keys"
menu_loop < "$FIX/keys" > "$FIX/picker-plain.txt" 2>&1
says  "without --watch the picker advertises q quit" "$FIX/picker-plain.txt" "q quit"
nsays "and q quits"                                  "$FIX/picker-plain.txt" "not a valid choice"

# 8. The board clears the flag when it comes back.
seed; to_main=true
compute_shown() { :; }; render_frame() { :; }
resume_board > /dev/null
flag "the board clears the flag" "$to_main" false

# 9. The board's legend lists z and v.
grep -q "z on/dormant, v services, q quit" "$BOARD" && ok "the board legend lists z and v" \
  || bad "the board legend lists z and v"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
