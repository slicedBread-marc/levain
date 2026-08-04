#!/usr/bin/env bash
# wf-gate-close.sh <artifact-id> [resolution]
#
# Releases a parked artifact. The next dispatcher sweep picks it up again.
# Safe to call when no gate is open.
#
# resolution is free text recorded in events.log (e.g. "approved", "rejected",
# "criteria passed") — it is the audit trail for why work resumed.
#
# Exit 0 always (idempotent).

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

artifact="${1:?Usage: $0 <artifact-id> [resolution]}"
resolution="${2:-resolved}"

id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a PLN/BUG/BRF id" >&2
  exit 1
fi

gate_file="$(wf_orch_dir)/gates/${id}.gate"

if [ ! -f "$gate_file" ]; then
  echo "$id: no open gate"
  exit 0
fi

gate_name=$(grep -m1 "^GATE_NAME=" "$gate_file" | sed "s/^GATE_NAME='//; s/'$//")
rm -f "$gate_file"

# ── Remember that it was answered ─────────────────────────────────────────
#
# Deleting the gate file leaves "answered" and "never asked" looking identical:
# both are simply the absence of a gate. That is fine for the dispatcher, which
# only wants to know whether to skip the plan — and wrong for a skill, which
# reaches its gating rule again on the very next dispatch.
#
# client-a hit the loop (WFI-047): a human granted spec-approval in writing,
# the gate closed, the orchestrator re-dispatched wf-spec to action that
# resolution, and step 6's rule ("a plan carrying a gateTag parks on an Approved
# verdict") read exactly the same as it had the first time. Each re-dispatch
# reproduces the condition, so the loop has no end. The only record of the
# approval was prose in findings.md, which nothing reads.
#
# The record is fingerprinted with the plan text that was approved. An approval
# is for a REVISION, not for a plan forever — edit the plan afterwards and the
# fingerprint stops matching, which is what should re-open the question.
resolved_dir="$(wf_orch_dir)/gates/resolved"
mkdir -p "$resolved_dir"

plan_fp=$(wf_plan_fingerprint "$id")

{
  wf_emit GATE_ID         "$id"
  wf_emit GATE_NAME       "$gate_name"
  wf_emit GATE_RESOLUTION "$resolution"
  wf_emit GATE_RESOLVED   "$(wf_now)"
  wf_emit GATE_PLAN_FP    "$plan_fp"
} > "$resolved_dir/${id}.${gate_name}"

wf_event gate-close "$id" "$gate_name: $resolution"
echo "$id: gate '$gate_name' closed — $resolution"
