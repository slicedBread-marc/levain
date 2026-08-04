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
# not to an ID: if plan.md has changed since, the approval no longer covers what
# is now in front of the human, and the gate genuinely should re-open.
#
# Output (eval-friendly):
#   GATE_OPEN=true|false         a gate of this name is open right now
#   GATE_ANSWERED=true|false     it was closed, and for THIS revision of plan.md
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
resolution=""
resolved_at=""

if [ -f "$resolved_file" ]; then
  # shellcheck disable=SC1090
  resolution=$(grep -m1 "^GATE_RESOLUTION=" "$resolved_file" | sed "s/^GATE_RESOLUTION='//; s/'$//" || true)
  resolved_at=$(grep -m1 "^GATE_RESOLVED=" "$resolved_file" | sed "s/^GATE_RESOLVED='//; s/'$//" || true)
  was_fp=$(grep -m1 "^GATE_PLAN_FP=" "$resolved_file" | sed "s/^GATE_PLAN_FP='//; s/'$//" || true)

  slug=$(grep "^| $id |" "$(wf_develop_root)/plans/REGISTRY.md" 2>/dev/null \
         | head -1 | awk -F'|' '{print $3}' | xargs || true)
  plan_md="$(wf_develop_root)/plans/${id}-${slug}/plan.md"
  now_fp=""
  [ -n "$slug" ] && [ -f "$plan_md" ] && now_fp=$(shasum "$plan_md" 2>/dev/null | awk '{print $1}' || true)

  if [ -z "$was_fp" ] || [ -z "$now_fp" ]; then
    # No fingerprint on either side — an older record, or a plan whose file is
    # gone. Treat the answer as still standing: re-gating a plan a human has
    # already approved is the failure this exists to stop, and the operator can
    # always re-open one deliberately.
    answered=true
  elif [ "$was_fp" = "$now_fp" ]; then
    answered=true
  else
    stale=true
  fi
fi

wf_emit GATE_OPEN        "$open"
wf_emit GATE_ANSWERED    "$answered"
wf_emit GATE_RESOLUTION  "$resolution"
wf_emit GATE_RESOLVED_AT "$resolved_at"
wf_emit GATE_STALE       "$stale"
