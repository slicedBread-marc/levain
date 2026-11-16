#!/usr/bin/env bash
# intake.test.sh — filed bugs and the work in hand show on the board (the
# coordinator's LVI-050). A coordinator filed eight bugs into a client as one
# sealed intake group and could not find them on the rack: every row was a
# plan state, and `running 2` named nothing. lv-tray.sh --fields now reports
# intake=, intake_group=, intake_groups= and running_ids=; the board draws an
# `intake` row after `attn` (`6 prep-surface`) whose cell opens `row intake`,
# and the running cell names the IDs it counts.
#
#   tests/rack/intake.test.sh
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-intake.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

fails=0
ck() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s — want [%s], got [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }
grid_row() { printf '%s\n' "$1" | grep "^  $2 " | tr -s ' ' | sed 's/ $//'; }

export LV_DEPLOYMENTS="$FIX/deployments.txt"; : > "$LV_DEPLOYMENTS"
export LV_BOARD_CACHE="$FIX/cache" LV_LIBRARY_DIR="$FIX/nolib" LV_RACK_LIB=1
# shellcheck disable=SC1090
source "$BOARD"

# ── the row is in the vocabulary, after attn ─────────────────────────
ck "intake is a row right after attn" "$(printf '%s ' "${ROW_LABELS[@]}" | grep -o 'attn intake ideas')" "attn intake ideas"

# ── fetch_one reads the new keys, a client's tray stubbed ────────────
mkdir -p "$FIX/p"
has_harness() { return 0; }
hx() {
  printf 'daemon=running\tenabled=true\tspawns=1/20\trunning=2\tgates=0\tgates_stuck=0\tgates_blocked=0\tdraft=0\tready=0\tactive=1\tverify=0\ttesting=0\tcomplete=3\trolled_back=0\tabandoned=0\tregistry=clean\tattn=\trelease_pending=0\tdeploy_pending=0\tbrainstorms=0\tbrainstorms_drift=0\taccept=0\tclaims=\trunning_ids=PLN-121,BUG-122\tintake=6\tintake_group=prep-surface\tintake_groups=%s\n' "${GROUPS_N:-1}"
}
names=(p); paths=("$FIX/p")
statuses=(); f_daemon=(); f_running=(); f_gates=(); f_gates_stuck=(); f_gates_blocked=()
f_draft=(); f_ready=(); f_active=(); f_verify=(); f_testing=(); f_complete=(); f_abandoned=()
f_registry=(); f_attn=(); f_release=(); f_deploy=(); f_ideas=(); f_ideas_drift=(); f_accept=(); f_ts=(); f_claims=()
f_running_ids=(); f_intake=(); f_intake_group=()
apply_record "$(fetch_one "$FIX/p")" append
ck "the running IDs come through"    "${f_running_ids[0]}" "PLN-121,BUG-122"
ck "the open bug count comes through" "${f_intake[0]}" "6"
ck "one live group is named alone"    "${f_intake_group[0]}" "prep-surface"
GROUPS_N=3 apply_record "$(GROUPS_N=3 fetch_one "$FIX/p")" 0
ck "more live groups add +N"          "${f_intake_group[0]}" "prep-surface+2"
rec=$(project_record 0)
apply_record "$rec" 0
ck "project_record round-trips them"  "$(project_record 0)" "$rec"

# An older record — written before these fields — reads as nothing known.
old=$(printf '%s' "$rec" | cut -d$'\x1f' -f1-22)
apply_record "$old" 0
ck "an older record has no running IDs" "${f_running_ids[0]}" ""
ck "and no intake"                      "${f_intake[0]}" ""

# ── the grid ─────────────────────────────────────────────────────────
apply_record "$rec" 0
MAX_COLS=2; fit_cols() { MAX_COLS=2; }
win_start=0; compute_shown
out=$(render_text 2>&1)
ck "two held IDs are bare numbers after the count" "$(grid_row "$out" running)" " running 2 121 122"
ck "the intake cell names the group"               "$(grid_row "$out" intake)" " intake 6 prep-surface+2"
# Intake sits between attn and ideas, with the section break after it.
ck "intake is drawn right after attn" \
  "$(printf '%s\n' "$out" | grep -A1 '^  attn ' | tail -1 | awk '{print $1}')" "intake"

f_running[0]=1; f_running_ids[0]="PLN-121"; f_claims[0]="RELEASE"
out=$(render_text 2>&1)
ck "one held ID is spelled out, claims after it"   "$(grid_row "$out" running)" " running 1 PLN-121 +RELEASE"

f_running[0]=4; f_running_ids[0]="PLN-121,BUG-122,PLN-130,PLN-131"; f_claims[0]=""
out=$(render_text 2>&1)
ck "more than two IDs: two, then +N"               "$(grid_row "$out" running)" " running 4 121 122 +2"

f_intake[0]=0; f_intake_group[0]=""
out=$(render_text 2>&1)
ck "nothing filed reads 0"                         "$(grid_row "$out" intake)" " intake 0"
f_intake[0]=""
out=$(render_text 2>&1)
ck "an older client reads -"                       "$(grid_row "$out" intake)" " intake -"

# ── Enter on the cell opens the project's intake list ────────────────
f_intake[0]=6; f_intake_group[0]="prep-surface"
line=$(drill_rows_lines 0 | grep '^intake ')
ck "the rows menu shows the intake cell" "$(printf '%s' "$line" | cut -f1 | tr -s ' ')" "intake 6 prep-surface"
ck "and opens row intake"                "$(printf '%s' "$line" | cut -f2-)" "$(printf 'list\trow intake')"

# ── the snapshot keeps them ──────────────────────────────────────────
if $HAVE_JQ; then
  snapshot_save
  names=(); paths=()
  snapshot_load
  ck "the snapshot keeps the running IDs" "${f_running_ids[0]:-}" "PLN-121,BUG-122,PLN-130,PLN-131"
  ck "and the intake"                     "${f_intake[0]:-} ${f_intake_group[0]:-}" "6 prep-surface"
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
