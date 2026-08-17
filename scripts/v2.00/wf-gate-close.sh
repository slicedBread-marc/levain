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
# Closing a gate also clears that plan's orchestrator attempt budget: a worker
# that parked on a gate did not stall, and the answer is what unblocks it
# (WFI-185).
#
# Three things are written: `gates/resolved/<id>.<gate>` (the slot readers look
# up, always the latest), `gates/resolved/<id>.<gate>.log` (append-only, one
# tab-separated line per close: when, gate, registry state, resolution), and a
# `## Decisions` entry in the plan's own findings.md — the ledger is the record,
# but findings.md is where a dispatched worker actually looks (WFI-181).
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

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

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

gate_question=""
if [ -f "$gate_file" ]; then
  gate_name=$(grep -m1 "^GATE_NAME=" "$gate_file" | sed "s/^GATE_NAME='//; s/'$//")
  # The question AS ASKED, kept with the answer.
  #
  # A resolution without its question is half a record, and the missing half is
  # the one that drifts. client-a's PLN-135 had the same gate re-derived five
  # times, and each regeneration introduced new errors of fact: three
  # consecutive re-openings described a Dictionary as a HashSet, and the fifth
  # asserted a file was untouched by a commit that changes it +22/-8 (WFI-184).
  # The conclusion survived by luck. Keeping the original text means a reader
  # can replay what was asked instead of writing it again from what they happen
  # to see now.
  gate_question=$(grep -m1 "^GATE_QUESTION=" "$gate_file" | sed "s/^GATE_QUESTION='//; s/'$//" || true)
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
  wf_emit GATE_QUESTION     "$gate_question"
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

# ── The decision goes where the next worker will read it ──────────────────
#
# The ledger above is the record; it is not the place anybody looks. A
# dispatched worker reads the plan artifacts — plan.md, findings.md — and
# nothing in them said a decision had been made. So a `prior-work` gate on
# client-a's PLN-135 was answered, closed, and re-opened by the next worker
# on the same durable evidence, three times, each worker correctly concluding
# from what it could see that an unexplained commit sat on develop (WFI-181).
#
# wf-gate-open.sh now REFUSES that re-opening, which is what stops the loop.
# This is the other half and the reason it is still worth writing: a worker told
# "already answered" needs to know WHAT was answered in the same place it reads
# everything else about the plan, or it is merely blocked rather than informed.
#
# findings.md, not plan.md: this is a record of something that happened, and the
# plan is a specification. Deliberately no `- [ ]` items — an unchecked box in
# findings.md is what wf-list-specable.sh reads as "this plan needs replanning".
transcribe_resolution() {
  local root plan_dir findings
  root="$(wf_develop_root)"
  plan_dir=$(ls -d "$root"/plans/"${id}"-* 2>/dev/null | head -1 || true)
  [ -n "$plan_dir" ] && [ -d "$plan_dir" ] || return 0
  findings="$plan_dir/findings.md"

  [ -f "$findings" ] || printf '# Findings — %s\n' "$id" > "$findings"
  grep -q '^## Decisions' "$findings" 2>/dev/null || printf '\n## Decisions\n' >> "$findings"

  {
    printf '\n### %s — %s\n' "$gate_name" "$(wf_now)"
    [ -n "$gate_question" ] && printf '> **Asked:** %s\n' "$(printf '%s' "$gate_question" | tr '\n' ' ')"
    printf '> **Resolution:** %s\n' "$(printf '%s' "$resolution" | tr '\n' ' ')"
    printf '> **State at close:** %s\n' "${gate_state:-—}"
    printf '> Recorded by wf-gate-close.sh. This is the decision of record — act on it rather than re-deriving the question (WFI-181).\n'
  } >> "$findings"

  # Committed here for the same reason wf_registry_commit commits: a decision
  # left dirty on the shared develop root belongs to whoever commits next.
  ( cd "$root" && "$SELF_DIR/wf-commit.sh" \
      "gate($id): $gate_name resolved — recorded in findings" \
      --add "plans/$(basename "$plan_dir")/findings.md" >/dev/null 2>&1 ) \
    || echo "wf-gate-close: the resolution is written to $findings but could not be committed" >&2
}
transcribe_resolution || true

# ── Answering a gate is forward progress ──────────────────────────────────
#
# The orchestrator's attempt budget counts worker LAUNCHES that produced no
# forward progress, and parks the plan as `stuck` at the cap. A worker that
# opens a mandatory gate and stops has done exactly what its skill prescribes —
# but it moves neither the registry state nor the step checklist, so it looks
# identical to a stall.
#
# client-a's PLN-135 (WFI-185) accrued three implement attempts that way,
# every one of them a worker correctly parking on the prior-work gate and
# saying so in its log. When the gate was finally answered at 11:36, the
# dispatcher read the stale counter and opened a `stuck` gate at 11:37 —
# answering a gate produced another gate instead of forward progress, and a
# human had to delete the counter file by hand. It compounded with the
# re-gating loop: each re-opening cost another attempt.
#
# The answer resets it, because an answer is precisely the event that
# invalidates every no-progress run before it: those workers were waiting for
# this, and now they are not.
attempts_dir="$(wf_orch_dir)/attempts"
if ls "$attempts_dir/$id".* >/dev/null 2>&1; then
  rm -f "$attempts_dir/$id".*
  wf_event attempts-reset "$id" "gate '$gate_name' answered — attempt budget cleared (WFI-185)"
fi

wf_event gate-close "$id" "$gate_name: $resolution"
if [ -n "$forced_gate" ] && [ ! -f "$gate_file" ]; then
  echo "$id: recorded '$gate_name' as answered — $resolution"
else
  echo "$id: gate '$gate_name' closed — $resolution"
fi
