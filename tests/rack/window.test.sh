#!/usr/bin/env bash
# window.test.sh — a grid scrolled right draws each visible project's OWN
# values (LVI-029). row() used to copy its array with "${arr[@]}", which
# renumbers a sparse array from 0: the daemon row, filled only at the window's
# absolute positions, showed another column's value or aborted under set -u
# once win_start was past 0.
#
#   tests/rack/window.test.sh
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-window.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

fails=0
ck() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s — want [%s], got [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }

export LV_DEPLOYMENTS="$FIX/deployments.txt"; : > "$LV_DEPLOYMENTS"
export LV_BOARD_CACHE="$FIX/cache" LV_LIBRARY_DIR="$FIX/nolib" LV_RACK_LIB=1
# shellcheck disable=SC1090
source "$BOARD"

# Four projects, each with a daemon state and running count of its own.
names=(p0 p1 p2 p3); paths=("$FIX/p0" "$FIX/p1" "$FIX/p2" "$FIX/p3")
statuses=(ok ok ok ok)
f_daemon=(off running off running); f_running=(0 0 0 2)
for a in f_gates f_gates_stuck f_gates_blocked f_draft f_ready f_active f_verify \
         f_testing f_complete f_abandoned f_ideas f_ideas_drift; do
  eval "$a=(0 0 0 0)"
done
f_draft=(10 11 12 13)
f_registry=(clean clean clean clean); f_attn=(- - - -); f_release=(- - - -); f_deploy=(- - - -)
f_ts=(0 0 0 0)

# Two columns fit; scroll the window to start at the third project.
MAX_COLS=2; fit_cols() { MAX_COLS=2; }
win_start=2; compute_shown
out=$(render_text 2>&1); rc=$?
ck "a scrolled grid renders" "$rc" "0"
ck "without an unbound-variable abort" "$(printf '%s\n' "$out" | grep -c 'unbound variable')" "0"
ck "the header is the window's projects" "$(printf '%s\n' "$out" | sed -n 2p | tr -s ' ' | sed 's/ $//')" " p2 p3"
ck "the daemon row is theirs, not the first two's" "$(printf '%s\n' "$out" | grep '^  daemon' | tr -s ' ' | sed 's/ $//')" " daemon off cooking"
ck "a dense row stays aligned too" "$(printf '%s\n' "$out" | grep '^  draft' | tr -s ' ' | sed 's/ $//')" " draft 12 13"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
