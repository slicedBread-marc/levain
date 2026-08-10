#!/usr/bin/env bash
# wf-gate-close.sh <artifact-id> [resolution] [--gate <name>]
#
# Releases a parked artifact. The next dispatcher sweep picks it up again.
# Safe to call when no gate is open.
#
# resolution is free text recorded in events.log (e.g. "approved", "rejected",
# "criteria passed") — it is the audit trail for why work resumed. Describe the
# decision JUST MADE. Restating an earlier cycle's outcome writes a record of a
# run that did not happen (WFI-100).
#
# Two things are written: `gates/resolved/<id>.<gate>` (the slot readers look
# up, always the latest) and `gates/resolved/<id>.<gate>.log` (append-only, one
# tab-separated line per close: when, gate, registry state, resolution).
#
# --gate <name>  Record the resolution under this gate name even when no gate
#                file is open. This is the backfill path: a decision a human
#                demonstrably made — in a commit message, in findings.md —
#                but which the resolved-gate ledger has no record of, because
#                the gate closed before the ledger existed or was cleared by
#                hand. Without it, wf-gate-status.sh reports GATE_ANSWERED=false
#                and the owning skill re-asks a question already answered in
#                writing (client-a WFI-060, PLN-019's spec approval), and
#                the only workarounds are faking an open gate or overriding the
#                skill's own rule.
#
# Exit 0 always (idempotent).

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

artifact=""
resolution=""
forced_gate=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gate) forced_gate="${2:?--gate requires a gate name}"; shift 2 ;;
    -*)     echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$artifact" ]; then artifact="$1"; else resolution="$1"; fi
      shift ;;
  esac
done

[ -n "$artifact" ] || { echo "Usage: $0 <artifact-id> [resolution] [--gate <name>]" >&2; exit 1; }
resolution="${resolution:-resolved}"

id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a PLN/BUG/BRF id" >&2
  exit 1
fi

gate_file="$(wf_orch_dir)/gates/${id}.gate"

if [ ! -f "$gate_file" ] && [ -z "$forced_gate" ]; then
  echo "$id: no open gate"
  exit 0
fi

if [ -f "$gate_file" ]; then
  gate_name=$(grep -m1 "^GATE_NAME=" "$gate_file" | sed "s/^GATE_NAME='//; s/'$//")
  rm -f "$gate_file"
else
  gate_name="$forced_gate"
fi
[ -n "$forced_gate" ] && gate_name="$forced_gate"

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
#
# GATE_PLAN_BODY_FP is the one that decides, because the question is "did the
# SPECIFICATION change since the answer?" and not "did any byte of plan.md
# change?". A raw hash answers the second: ticking a deferred criterion in the
# Human Test Criteria — which wf-defer-criterion.sh explicitly instructs a
# tester to do — flipped an answered spec-approval to stale, and a plan later
# routed back to draft would then re-gate an approval the human had already
# given, which is the WFI-047 loop this ledger exists to prevent (client-c
# WFI-005). GATE_PLAN_FP is still written so a client mid-upgrade reads a
# record it understands.
resolved_dir="$(wf_orch_dir)/gates/resolved"
mkdir -p "$resolved_dir"

plan_fp=$(wf_plan_fingerprint "$id")
plan_body_fp=$(wf_plan_body_fingerprint "$id")

# The registry state AT CLOSE TIME, recorded alongside the outcome.
#
# A resolution and the state it leaves the plan in are one fact, and the slot
# below only held half of it. client-a's WFI-100: a `manual-test` gate was
# resolved carrying "criterion 8 FAIL ← ESCALATED to spec" while the registry
# row read `testing` — an escalation to `draft` recorded against a plan that
# had not gone there, because the text came from the PREVIOUS cycle. Writing
# the state down is what makes that contradiction visible to the next reader
# instead of leaving it to be reconstructed from commit times.
gate_state=$(grep -m1 "^| $id |" "$(wf_develop_root)/plans/REGISTRY.md" 2>/dev/null \
             | awk -F'|' '{print $4}' | xargs || true)

record=$(
  wf_emit GATE_ID           "$id"
  wf_emit GATE_NAME         "$gate_name"
  wf_emit GATE_RESOLUTION   "$resolution"
  wf_emit GATE_RESOLVED     "$(wf_now)"
  wf_emit GATE_RESOLVED_STATE "${gate_state:-—}"
  wf_emit GATE_PLAN_FP      "$plan_fp"
  wf_emit GATE_PLAN_BODY_FP "$plan_body_fp"
)

# The slot is what readers look up; the ledger is what happened.
#
# `resolved/<id>.<gate>` is a single per-plan-per-gate slot, so every later
# cycle overwrote the record of the one before it — and a `manual-test` gate is
# opened and answered once per test cycle. WFI-100 was only diagnosable because
# a human remembered the earlier outcome; the file itself had no memory of it.
# Appending here costs one line per close and makes "who approved what, when,
# and from which state" answerable after the fact.
printf '%s\n' "$record" > "$resolved_dir/${id}.${gate_name}"
printf '%s\t%s\t%s\t%s\n' "$(wf_now)" "$gate_name" "${gate_state:-—}" \
  "$(printf '%s' "$resolution" | tr '\n\t' '  ')" \
  >> "$resolved_dir/${id}.${gate_name}.log"

wf_event gate-close "$id" "$gate_name: $resolution"
if [ -n "$forced_gate" ] && [ ! -f "$gate_file" ]; then
  echo "$id: recorded '$gate_name' as answered — $resolution"
else
  echo "$id: gate '$gate_name' closed — $resolution"
fi
