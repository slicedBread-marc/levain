#!/usr/bin/env bash
# wf-gate-status.sh <artifact-id> <gate-name>
#
# Has this gate already been answered for the plan as it stands now?
#
# WHY THIS EXISTS
#
# `wf-list-gates.sh` answers "is a gate open?", which is what the dispatcher
# needs. A skill needs a different question. Its gating rule is evaluated fresh
# on every dispatch, and the absence of an open gate is indistinguishable from
# an answer already given — so a skill that re-derives "this plan needs a gate"
# re-opens the gate a human just closed, and the next dispatch does it again.
#
# client-a's PLN-018 (WFI-047): tagged `contract`, the project's sole
# gateTag. It gated, the user approved in writing, wf-gate-close.sh removed the
# gate file, the orchestrator re-dispatched wf-spec to action the resolution —
# and wf-spec's step 6 saw the same tag on the same Approved verdict it had seen
# before. Nothing in the state said "already answered". Unbounded.
#
# The answer is scoped to a plan REVISION. An approval is given to a document,
# not to an ID: if the plan's SPECIFICATION has changed since, the approval no
# longer covers what is now in front of the human, and the gate genuinely should
# re-open. Bookkeeping that leaves the specification alone — a ticked criterion,
# a review stamp — is not a revision (WFI-005).
#
# Output (eval-friendly):
#   GATE_OPEN=true|false         a gate of this name is open right now
#   GATE_ANSWERED=true|false     it was closed, and for THIS revision of plan.md
#   GATE_ANSWERED_BASIS=revision|assumed|none
#                                how ANSWERED was decided — `revision` means two
#                                fingerprints were compared and matched;
#                                `assumed` means one side had none to compare
#                                (an old record, a plan with no REGISTRY row, a
#                                missing file) and the answer is being taken on
#                                trust. A caller that merely reports may treat
#                                them alike; one that REFUSES to ask a human
#                                must not.
#   GATE_RESOLUTION='approved'   the recorded resolution (empty if never closed)
#   GATE_RESOLVED_AT=<iso8601>   when (empty if never closed)
#   GATE_STALE=true|false        closed, but plan.md has changed since
#
# GATE_ANSWERED=true is the "do not re-open" signal. GATE_STALE=true means the
# plan moved after approval, so asking again is correct.
#
# Exit 0 always.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

artifact="${1:?Usage: $0 <artifact-id> <gate-name>}"
gate_name="${2:?Usage: $0 <artifact-id> <gate-name>}"

id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a PLN/BUG/BRF id" >&2
  exit 1
fi

ORCH="$(wf_orch_dir)"
gate_file="$ORCH/gates/${id}.gate"
resolved_file="$ORCH/gates/resolved/${id}.${gate_name}"

open=false
if [ -f "$gate_file" ]; then
  existing=$(grep -m1 "^GATE_NAME=" "$gate_file" | sed "s/^GATE_NAME='//; s/'$//")
  [ "$existing" = "$gate_name" ] && open=true
fi

answered=false
stale=false
basis=none
resolution=""
resolved_at=""

if [ -f "$resolved_file" ]; then
  resolution=$(grep -m1 "^GATE_RESOLUTION=" "$resolved_file" | sed "s/^GATE_RESOLUTION='//; s/'$//" || true)
  resolved_at=$(grep -m1 "^GATE_RESOLVED=" "$resolved_file" | sed "s/^GATE_RESOLVED='//; s/'$//" || true)
  # The body fingerprint decides when the record carries one: it normalises the
  # regions that move under machine control while the specification stands still
  # — ticked checkboxes above all. A tester ticking a deferred criterion, as
  # wf-defer-criterion.sh tells them to, is recording a disposition, not
  # revising the spec, and used to make every answered gate on that plan read
  # stale (client-c WFI-005). Records written before v5.6 have only the raw
  # hash; fall back to it so an upgrade does not invalidate them wholesale.
  was_fp=$(grep -m1 "^GATE_PLAN_BODY_FP=" "$resolved_file" | sed "s/^GATE_PLAN_BODY_FP='//; s/'$//" || true)
  if [ -n "$was_fp" ]; then
    now_fp=$(wf_plan_body_fingerprint "$id")
  else
    was_fp=$(grep -m1 "^GATE_PLAN_FP=" "$resolved_file" | sed "s/^GATE_PLAN_FP='//; s/'$//" || true)
    now_fp=$(wf_plan_fingerprint "$id")
  fi

  if [ -z "$was_fp" ] || [ -z "$now_fp" ]; then
    # No fingerprint on either side — an older record, or a plan whose file is
    # gone, or one with no REGISTRY row to find it by. Treat the answer as still
    # standing: re-gating a plan a human has already approved is the failure
    # this exists to stop, and the operator can always re-open one deliberately.
    #
    # But say that it is an ASSUMPTION. `answered` here means "nothing shows it
    # changed", which is weaker than "it demonstrably has not" — and a caller
    # about to REFUSE a gate on the strength of it (wf-gate-open.sh) needs the
    # difference. Refusing to ask a human on the basis of a missing file is how
    # a real question goes unasked.
    answered=true
    basis=assumed
  elif [ "$was_fp" = "$now_fp" ]; then
    answered=true
    basis=revision
  else
    stale=true
  fi
fi

wf_emit GATE_OPEN        "$open"
wf_emit GATE_ANSWERED    "$answered"
wf_emit GATE_ANSWERED_BASIS "$basis"
wf_emit GATE_RESOLUTION  "$resolution"
wf_emit GATE_RESOLVED_AT "$resolved_at"
wf_emit GATE_STALE       "$stale"
