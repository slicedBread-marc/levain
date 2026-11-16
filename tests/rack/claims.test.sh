#!/usr/bin/env bash
# claims.test.sh — work an attended session holds shows on the board. A client
# board read "DEPLOY" waiting on a human, `running 0`, while a human session
# was mid-/lv-release answering exactly that gate: `running` counted only daemon
# workers, and nothing read the session's live claim. lv-tray.sh --fields now
# reports `claims=`; the running cell names them and a gate they answer is
# marked `*` and drawn cyan instead of yellow.
#
#   tests/rack/claims.test.sh
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"
FIX="$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-claims.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT

fails=0
ck() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s — want [%s], got [%s]\n' "$1" "$3" "$2"; fails=$((fails + 1)); fi; }

export LV_DEPLOYMENTS="$FIX/deployments.txt"; : > "$LV_DEPLOYMENTS"
export LV_BOARD_CACHE="$FIX/cache" LV_LIBRARY_DIR="$FIX/nolib" LV_RACK_LIB=1
# shellcheck disable=SC1090
source "$BOARD"

# ── gate_in_hand ──────────────────────────────────────────────────────
gate_in_hand DEPLOY "RELEASE";      ck "a release in hand answers a deploy gate" "$?" "0"
gate_in_hand RELEASE "DEPLOY";      ck "and the other way round" "$?" "0"
gate_in_hand 'DEPLOY!' "DEPLOY";    ck "a stuck marker does not hide the id" "$?" "0"
gate_in_hand 004 "4";               ck "a plan's number matches across padding" "$?" "0"
gate_in_hand '012~' "12,RELEASE";   ck "a collision marker does not hide the id" "$?" "0"
gate_in_hand 004 "RELEASE";         ck "a release claim does not cover a plan gate" "$?" "1"
gate_in_hand DEPLOY "";             ck "no claims, nothing in hand" "$?" "1"

# ── a record carries claims after the timestamp ──────────────────────
rec=$(printf 'ok\x1frunning\x1f0\x1f1\x1f0\x1f0\x1f0\x1f0\x1f0\x1f0\x1f0\x1f5\x1f0\x1fclean\x1fDEPLOY\x1f0\x1f4\x1f0\x1f0\x1f0\x1f1700000000\x1fRELEASE')
names=(gt); paths=("$FIX/gt")
statuses=(); f_daemon=(); f_running=(); f_gates=(); f_gates_stuck=(); f_gates_blocked=()
f_draft=(); f_ready=(); f_active=(); f_verify=(); f_testing=(); f_complete=(); f_abandoned=()
f_registry=(); f_attn=(); f_release=(); f_deploy=(); f_ideas=(); f_ideas_drift=(); f_accept=(); f_ts=(); f_claims=()
apply_record "$rec" append
ck "the timestamp stays where older readers look" "${f_ts[0]}" "1700000000"
ck "the claims follow it" "${f_claims[0]}" "RELEASE"
# Three empty fields after them: running_ids, intake, intake_group (LVI-050).
ck "project_record round-trips them" "$(project_record 0)" "$rec"$'\x1f\x1f\x1f'

# An older record — no claims field — reads as no work in hand.
apply_record "$(printf '%s' "$rec" | sed $'s/\x1fRELEASE$//')" 0
ck "an older record has no claims" "${f_claims[0]}" ""

# ── the grid ─────────────────────────────────────────────────────────
apply_record "$rec" 0
MAX_COLS=2; fit_cols() { MAX_COLS=2; }
win_start=0; compute_shown
out=$(render_text 2>&1)
ck "the running cell names the attended work" "$(printf '%s\n' "$out" | grep '^  running' | tr -s ' ' | sed 's/ $//')" " running 0 +RELEASE"
ck "the gate it answers is marked in hand" "$(printf '%s\n' "$out" | grep '^  attn' | tr -s ' ' | sed 's/ $//')" " attn DEPLOY*"

f_claims[0]=""
out=$(render_text 2>&1)
ck "with no claim the running cell is the bare count" "$(printf '%s\n' "$out" | grep '^  running' | tr -s ' ' | sed 's/ $//')" " running 0"
ck "and the gate is unmarked" "$(printf '%s\n' "$out" | grep '^  attn' | tr -s ' ' | sed 's/ $//')" " attn DEPLOY"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
