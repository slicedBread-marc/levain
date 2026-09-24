#!/usr/bin/env bash
# lv-rack-actions.test.sh — the board's action keys, at every level.
#
#   tests/rack/actions.test.sh
#
# d (toggle this project's daemon), a (its action menu) and the portfolio-wide
# s/R pair used to live only on the grid, so the levels below it were the one
# place you could not act on what they were about: the daemon row's own drill
# listed the daemon's logs with no way to stop it. They now route through
# board_action_key, and this checks that the routing reaches a drill level, a
# log pager and the action menu — not just that the function exists.
#
# Same technique as the drill and menu tests: the tool is SOURCED with
# LV_RACK_LIB=1, which loads every function and stops before drawing
# anything, and the levels are called directly with a keystroke script on
# stdin.
#
# DEPLOYMENTS and LV_SUSPEND_STATE are BOTH pointed at the fixture, so a run
# of this never stops the operator's real daemons.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/wf-actions-test.XXXXXX")"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
says() { if grep -qF "$3" "$2"; then ok "$1"; else bad "$1 — expected: $3"; fi; }
nsays(){ if grep -qF "$3" "$2"; then bad "$1 — did not expect: $3"; else ok "$1"; fi; }

# ── Fixture: one client that answers drill calls and records every call ──
CLIENT="$FIX/alpha"
mkdir -p "$CLIENT/scripts" "$CLIENT/.claude/orchestrator/logs"
LOGFILE="$CLIENT/.claude/orchestrator/logs/PLN-001-implement-20260917-120000.log"
printf 'worker line one\nTHE-LAST-LINE\n' > "$LOGFILE"

cat > "$CLIENT/scripts/wf-exec.sh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$WF_ACT_CALLS"
[ "\$1" = "wf-board-drill.sh" ] || exit 0
shift
case "\$1 \${2:-}" in
  "row daemon")
    printf 'daemon log\tlog\t$LOGFILE\n' ;;
  *) echo "stub: no such node \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$CLIENT/scripts/wf-exec.sh"

export WF_ACT_CALLS="$FIX/calls.log"
export LV_SUSPEND_STATE="$FIX/daemons-suspended"
LV_RACK_LIB=1
LV_BOARD_CACHE="$FIX/cache"
export LV_RACK_LIB LV_BOARD_CACHE
# shellcheck source=../bin/lv-rack
source "$BOARD"

DEPLOYMENTS="$FIX/deployments.txt"
printf '%s\n' "$CLIENT" > "$DEPLOYMENTS"

# The real one shells into the client for fresh numbers; the dispatch is what
# is under test, not the re-fetch.
refresh_one() { :; }

seed() {
  names=("alpha"); paths=("$CLIENT"); statuses=("ok")
  f_daemon=("${1:-off}"); f_running=("1")
  f_gates=("0"); f_gates_stuck=("0"); f_gates_blocked=("0")
  f_draft=("0"); f_ready=("0"); f_active=("1"); f_verify=("0"); f_testing=("0")
  f_complete=("7"); f_abandoned=("0")
  f_registry=("clean"); f_attn=(""); f_release=("-"); f_deploy=("-")
  f_ideas=("0"); f_ideas_drift=("0"); f_ts=("$(date +%s)")
  rm -rf "$LV_BOARD_CACHE"
  : > "$WF_ACT_CALLS"
}

echo "lv-rack action keys"

# ── 1. d inside a drill level ───────────────────────────────────────────
# Keys: d (toggle), space (dismiss "press any key"), esc (leave the level the
# action sent us back to).
seed off
printf 'd \x1b' | drill_browse 0 "daemon" "row daemon" > "$FIX/drill-d.txt" 2>&1
says "d in a drill level starts the daemon" "$WF_ACT_CALLS" "wf-orchestrate.sh --daemon"
says "and names the project it acted on"    "$FIX/drill-d.txt" "starting daemon for alpha"
says "the level advertises the key"         "$FIX/drill-d.txt" "d daemon"

seed running
printf 'd \x1b' | drill_browse 0 "daemon" "row daemon" > "$FIX/drill-dstop.txt" 2>&1
says "d stops a running one, same as on the grid" "$WF_ACT_CALLS" "wf-orchestrate.sh --stop"

# A level whose contents the action just changed must be re-read, not
# repainted from the answer it gave before.
says "the level is re-fetched after an action" "$WF_ACT_CALLS" "wf-board-drill.sh row daemon"
if [ "$(grep -c 'wf-board-drill.sh row daemon' "$WF_ACT_CALLS")" -ge 2 ]; then
  ok "and re-fetched from the client, not from its cache"
else
  bad "the level was not re-fetched after the action"
fi

# ── 2. d inside the log pager ───────────────────────────────────────────
# Reading a worker's log is the commonest place to decide the daemon should
# be off, and it is three levels down from the grid.
seed off
printf 'd \x1b' | view_file "alpha — log" "$LOGFILE" yes "$CLIENT" > "$FIX/pager.txt" 2>&1
says "d in the pager toggles the daemon" "$WF_ACT_CALLS" "wf-orchestrate.sh --daemon"
says "the pager advertises the key"      "$FIX/pager.txt"  "d daemon"
says "and still shows the file"          "$FIX/pager.txt"  "THE-LAST-LINE"

# ── 3. The letters work in the action menu too, beside the digits ───────
seed off
printf 'd b' | project_menu 0 > "$FIX/menu-d.txt" 2>&1
says "d in the action menu is action 1"  "$WF_ACT_CALLS" "wf-orchestrate.sh --daemon"
says "the menu advertises the letters"   "$FIX/menu-d.txt" "d daemon, s stop all, R resume"

seed off
printf 's b' | project_menu 0 > "$FIX/menu-s.txt" 2>&1
says "s stops every daemon in the portfolio" "$FIX/menu-s.txt" "no daemons were running"

seed off
printf 'R b' | project_menu 0 > "$FIX/menu-R.txt" 2>&1
says "R resumes the ones that were stopped" "$FIX/menu-R.txt" "no daemons to resume"

# ── 4. A key that is not one of these is left to the caller ─────────────
seed off
if board_action_key "x" "$CLIENT" >/dev/null 2>&1; then
  bad "an unrelated key was swallowed by board_action_key"
else
  ok "an unrelated key falls through to the level's own handling"
fi

# ── 5. A project the refresh dropped ────────────────────────────────────
# The levels hold a PATH for the life of a visit because a background refresh
# re-sorts the arrays underneath them. A path that is no longer there must say
# so rather than act on whatever now sits at that index.
seed off
printf ' ' | board_action_key "d" "$FIX/gone" > "$FIX/gone.txt" 2>&1
says "a dropped project is named, not acted on" "$FIX/gone.txt" "no longer in the project registry"
nsays "and nothing was started for it"          "$WF_ACT_CALLS" "wf-orchestrate.sh --daemon"

echo
if [ "$fails" -eq 0 ]; then
  echo "all assertions passed"; exit 0
else
  echo "$fails assertion(s) failed"; exit 1
fi
