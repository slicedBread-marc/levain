#!/usr/bin/env bash
# lv-rack-menu.test.sh — the project action menu: that every action is
# reachable by its digit, and that the two portfolio-wide ones act on the
# whole deployments list rather than the highlighted project.
#
#   tests/rack/menu.test.sh
#
# Same technique as the drill test: the tool is SOURCED with
# LV_RACK_LIB=1, which loads every function and stops before drawing
# anything, and project_menu is then called directly with a keystroke script
# on stdin.
#
# The menu's digits used to be a hand-written 1-6 beside an arrow-driven
# dispatch table — two copies of the same mapping, and the digits would not
# have grown when the list did. They now share pm_action, so the digits are
# what this checks.
#
# DEPLOYMENTS and LV_SUSPEND_STATE are BOTH pointed at the fixture. Without
# that, "stop ALL daemons" run from a test stops the operator's real ones.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/wf-menu-test.XXXXXX")"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
says() { if grep -qF "$3" "$2"; then ok "$1"; else bad "$1 — expected: $3"; fi; }
nsays(){ if grep -qF "$3" "$2"; then bad "$1 — did not expect: $3"; else ok "$1"; fi; }

# ── Fixture: one client whose harness only records what it was asked ────
CLIENT="$FIX/alpha"
mkdir -p "$CLIENT/scripts" "$CLIENT/.claude/orchestrator/logs"
cat > "$CLIENT/scripts/wf-exec.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WF_MENU_CALLS"
exit 0
STUB
chmod +x "$CLIENT/scripts/wf-exec.sh"

export WF_MENU_CALLS="$FIX/calls.log"
export LV_SUSPEND_STATE="$FIX/daemons-suspended"
export LV_RACK_LIB=1
# shellcheck disable=SC1090
source "$BOARD"

# The fixture stands in for the whole portfolio, for suspend_all/each_project.
DEPLOYMENTS="$FIX/deployments.txt"
printf '%s\n' "$CLIENT" > "$DEPLOYMENTS"

# One project, arrays shaped the way collect() leaves them.
seed() {
  names=(alpha); paths=("$CLIENT"); statuses=(ok)
  f_daemon=("${1:-off}"); f_running=(0); f_gates=(0)
  : > "$WF_MENU_CALLS"
}
# The real one shells into the client; the menu's dispatch is what's under
# test, not the re-fetch.
refresh_one() { :; }

run_menu() { # run_menu <keys> <outfile>
  printf '%s' "$1" | project_menu 0 > "$2" 2>&1
}

# ── 1 toggles the daemon, both ways ─────────────────────────────────────
seed off
run_menu '1 b' "$FIX/t1.out"
says "digit 1 starts a stopped daemon" "$WF_MENU_CALLS" "wf-orchestrate.sh --daemon"
says "and says which project"          "$FIX/t1.out"    "starting daemon for alpha"

seed running
run_menu '1 b' "$FIX/t2.out"
says "digit 1 stops a running daemon" "$WF_MENU_CALLS" "wf-orchestrate.sh --stop"
says "and labels the action for it"   "$FIX/t2.out"    "1) stop daemon"

# ── 2 sweeps ────────────────────────────────────────────────────────────
seed off
run_menu '2 b' "$FIX/t3.out"
says "digit 2 runs one sweep" "$WF_MENU_CALLS" "wf-orchestrate.sh --sweep"

# ── 7 and 8: the portfolio-wide pair, reachable by digit ────────────────
# 7 with nothing alive must record nothing, so 8 has nothing to resume —
# the same contract --stop-all/--resume have.
seed off
run_menu '7 b' "$FIX/t4.out"
says  "digit 7 stops every daemon"        "$FIX/t4.out" "no daemons were running"
nsays "and writes no record when none were" "$FIX/t4.out" "recorded for --resume"
if [ -e "$LV_SUSPEND_STATE" ]; then bad "no suspend file when nothing stopped"
else ok "no suspend file when nothing stopped"; fi

seed off
run_menu '8 b' "$FIX/t5.out"
says "digit 8 resumes, and says when there is nothing to" \
  "$FIX/t5.out" "nothing recorded"

# ── A digit past the end of the list does nothing ───────────────────────
seed off
run_menu '9 b' "$FIX/t6.out"
if [ -s "$WF_MENU_CALLS" ]; then bad "digit 9 is not an action"
else ok "digit 9 is not an action"; fi

# ── Every action has a line, and the menu still exits on b ──────────────
says "the portfolio actions are listed" "$FIX/t6.out" "stop ALL daemons"
says "so is the resume half"            "$FIX/t6.out" "resume the daemons that were stopped"

printf '\n'
if [ "$fails" -eq 0 ]; then printf 'all assertions passed\n'; exit 0; fi
printf '%d assertion(s) failed\n' "$fails"; exit 1
