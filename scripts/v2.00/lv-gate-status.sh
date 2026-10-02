#!/usr/bin/env bash
# lv-gate-status.sh <artifact-id> <gate-name>
#
# Has this gate already been answered for the plan as it stands now?
#
# WHY THIS EXISTS
#
# `lv-list-gates.sh` answers "is a gate open?", which is what the dispatcher
# needs. A skill needs a different question. Its gating rule is evaluated fresh
# on every dispatch, and the absence of an open gate is indistinguishable from
# an answer already given — so a skill that re-derives "this plan needs a gate"
# re-opens the gate a human just closed, and the next dispatch does it again.
#
# client-a's PLN-018 (WFI-047): tagged `contract`, the project's sole
# gateTag. It gated, the user approved in writing, lv-gate-close.sh removed the
# gate file, the orchestrator re-dispatched lv-spec to action the resolution —
# and lv-spec's step 6 saw the same tag on the same Approved verdict it had seen
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
#   GATE_PLAN_BODY_FP_AT_OPEN='…'  the plan fingerprint as of when the question
#                                was ASKED, when the record carries one. A gate
#                                closes AFTER the exit contract's commit, so
#                                the close-time fingerprint can include work the
#                                human never saw; lv-gate-open.sh judges a
#                                re-open against this instead (WFI-198). Empty
#                                for records written before it existed, and for
#                                gates on artifacts with no plan.md.
#   GATE_RESOLUTION='approved'   the recorded resolution (empty if never closed)
#   GATE_QUESTION='…'            the question AS ASKED when it was answered, so
#                                a caller can replay it instead of writing it
#                                again from what it happens to see now — five
#                                regenerations of one question accumulated three
#                                errors of fact on client-a (WFI-184)
#   GATE_RESOLVED_AT=<iso8601>   when (empty if never closed)
#   GATE_QUESTION_STALE=true|false
#                                OPEN, but plan.md has changed since the
#                                question was asked — so the claim of fact the
#                                question carries (a verdict, a round count, a
#                                test tally) describes an earlier revision.
#                                Always false for a gate that is not open, and
#                                for one whose record predates the at-open
#                                fingerprint. Refresh with
#                                `lv-gate-open.sh … --requestion`, and only
#                                when the recorded fact really changed.
#   GATE_STALE=true|false        closed, but plan.md has changed since — or
#                                what it was decided against has (below)
#   GATE_PLAN_CONTEXT_STALE=true|false
#                                the plan's CONTEXT moved since the question
#                                was asked: a plan in its dependency closure
#                                (its text, its directives, an answer given on
#                                it) or this plan's own directives (LVI-033).
#                                Folded into GATE_STALE for an answered gate
#                                and GATE_QUESTION_STALE for an open one, and
#                                reported on its own so a caller can say WHY.
#   GATE_PLAN_CONTEXT_CHANGED='PLN-026 directives'
#                                what moved, by name. Empty when nothing did.
#   GATE_WITHDRAWN=true|false    the last close was a WITHDRAWAL — the question
#                                went moot and nothing was answered
#                                (lv-gate-close.sh --withdraw). GATE_ANSWERED
#                                is false for it; GATE_RESOLUTION carries why,
#                                and that reason is input to the next worker.
#   GATE_DECISION=approve|reject the answer to a `release-approval` /
#                                `deploy-approval` gate as a value. Empty on
#                                every other gate, and on a promotion gate
#                                closed without `--decision`.
#   GATE_PROMOTE_TIP='<sha>'     the source-branch tip that approval was given
#                                for. Empty likewise. lv-promote-approval.sh is
#                                what compares it; this only reports it.
#
# GATE_ANSWERED=true is the "do not re-open" signal. GATE_STALE=true means the
# plan moved after approval, so asking again is correct.
#
# Exit 0 always.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

artifact="${1:?Usage: $0 <artifact-id> <gate-name>}"
gate_name="${2:?Usage: $0 <artifact-id> <gate-name>}"

# RELEASE and DEPLOY are ids here too, as they are everywhere else gates are
# handled (lv-gate-open.sh, lv-gate-close.sh, wf_gate_resolved_file). They carry
# no plan.md, so the fingerprints below find nothing and the answer reads
# `assumed` — GATE_PROMOTE_TIP is what scopes those two, and
# lv-promote-approval.sh is what reads it.
case "$artifact" in
  RELEASE|DEPLOY) id="$artifact" ;;
  *) id=$(printf '%s' "$artifact" | grep -oE "^($LV_WORK_RE)-[0-9]+" || true) ;;
esac
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a $LV_PLN/$LV_BUG/$LV_BRF id, or RELEASE/DEPLOY" >&2
  exit 1
fi

ORCH="$(wf_orch_dir)"
# Both lookups resolve by artifact NUMBER — a gate opened on PLN-161 is the
# same artifact's gate as one asked about under BRF-161 (WFI-187).
gate_file=$(wf_gate_file "$id" || true)
resolved_file=$(wf_gate_resolved_file "$id" "$gate_name" || true)

open=false
open_fp=""
if [ -f "$gate_file" ]; then
  existing=$(wf_gate_field "$gate_file" GATE_NAME)
  [ "$existing" = "$gate_name" ] && open=true
  # The revision the OPEN question was asked about. See GATE_QUESTION_STALE
  # below — until now this was read only off a resolved record, so a question
  # could go stale while parked and nothing said so.
  # An `if`, not `&&`: a false test as the last command of this block makes
  # the block exit 1 and `set -e` kills the script (lv-gate-open.sh says the
  # same thing about the same trap).
  if [ "$open" = "true" ]; then
    open_fp=$(wf_gate_field "$gate_file" GATE_PLAN_BODY_FP_AT_OPEN)
  fi
  # The plan the gate is actually about — see lv-gate-close.sh. The
  # fingerprints below are a question about a plan.md, and a brief has none.
  gate_owner=$(wf_gate_field "$gate_file" GATE_ID)
  [ -n "$gate_owner" ] && id="$gate_owner"
fi

answered=false
stale=false
basis=none
resolution=""
question=""
resolved_at=""
fp_at_open=""
decision=""
promote_tip=""
withdrawn=false
ctx_at_open=""
ctx_stale=false
ctx_changed=""

if [ -f "$resolved_file" ]; then
  resolution=$(wf_gate_field "$resolved_file" GATE_RESOLUTION)
  question=$(wf_gate_field "$resolved_file" GATE_QUESTION)
  # Same normalisation as the open-gate branch: the record names the plan it
  # was an answer about, and that is what the fingerprints below are for.
  record_owner=$(wf_gate_field "$resolved_file" GATE_ID)
  [ -n "$record_owner" ] && id="$record_owner"
  resolved_at=$(wf_gate_field "$resolved_file" GATE_RESOLVED)
  # The revision the question was ASKED about, when the record has it. Reported
  # rather than acted on here — lv-gate-open.sh is what decides a re-open, and
  # this is the evidence it needs: a close happens after the exit contract's
  # commit, so the close-time fingerprint below can include work the human
  # never saw (WFI-198).
  fp_at_open=$(wf_gate_field "$resolved_file" GATE_PLAN_BODY_FP_AT_OPEN)
  # The promotion gates' answer: a value, and the commit set it was given for.
  # Empty on every other gate. Reported only — lv-promote-approval.sh is what
  # decides whether a promotion is authorized by them.
  decision=$(wf_gate_field "$resolved_file" GATE_DECISION)
  promote_tip=$(wf_gate_field "$resolved_file" GATE_PROMOTE_TIP)
  [ "$(wf_gate_field "$resolved_file" GATE_WITHDRAWN)" = "true" ] && withdrawn=true
  ctx_at_open=$(wf_gate_field "$resolved_file" GATE_PLAN_CONTEXT_AT_OPEN)
  # The body fingerprint decides when the record carries one: it normalises the
  # regions that move under machine control while the specification stands still
  # — ticked checkboxes above all. A tester ticking a deferred criterion, as
  # lv-defer-criterion.sh tells them to, is recording a disposition, not
  # revising the spec, and used to make every answered gate on that plan read
  # stale (client-c WFI-005). Records written before v5.6 have only the raw
  # hash; fall back to it so an upgrade does not invalidate them wholesale.
  was_fp=$(wf_gate_field "$resolved_file" GATE_PLAN_BODY_FP)
  if [ -n "$was_fp" ]; then
    now_fp=$(wf_plan_body_fingerprint "$id")
  else
    was_fp=$(wf_gate_field "$resolved_file" GATE_PLAN_FP)
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
    # about to REFUSE a gate on the strength of it (lv-gate-open.sh) needs the
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

  # ── Decided against something that has since moved (LVI-033) ─────────────
  #
  # The fingerprint above is the plan's own text. An approval is also an
  # approval of the plan AS IT FITS the plans it depends on and the direction
  # it was given: when one of those moves, the text can stand still while what
  # it means changes underneath it. A client's PLN-028 was approved-in-waiting
  # on an allow-list its upstream PLN-026 had just been told to drop.
  if [ -n "$ctx_at_open" ] && ! $withdrawn; then
    ctx_changed=$(wf_context_changed "$ctx_at_open" "$(wf_plan_context "$id")")
    if [ -n "$ctx_changed" ]; then
      ctx_stale=true
      if $answered; then answered=false; basis=none; stale=true; fi
    fi
  fi

  # A withdrawal is a record that a question went moot. It answered nothing,
  # so it can never read as an answer — least of all as an approval, which is
  # what lv-spec's step 6 takes GATE_ANSWERED=true to mean.
  if $withdrawn; then
    answered=false; basis=none; stale=false
  fi
fi

# ── A parked question can go stale where it stands ────────────────────────
#
# GATE_STALE is about an ANSWER: the plan moved after a human decided, so the
# decision no longer covers it. This is the other half, and nothing reported it.
#
# The question a gate carries is a claim of fact — a verdict, a round count, a
# test tally — composed when the gate opened. lv-spec's spec-approval question
# leads with the review result, so the human draining the queue reads
# "Approved with notes" and decides on that. Then the plan is amended: a
# re-review, a consistency pass, a source artifact changed under it. The gate
# file is untouched, because re-running lv-gate-open.sh on an open gate prints
# "already open — left as is" by design. The question now describes a document
# that no longer exists, and the queue presents it as ordinary work.
#
# client-b WFI-018 is the sharp version: round 1 opened the gate carrying
# "Approved with notes (0 Critical)", round 2 then rewrote the plan around a
# Critical an independent review had found — a rehearsal step that would have
# replicated a scratch database into the live production replica path. The
# parked question still said "Approved with notes". client-a's PLN-202 is
# the same shape benignly: a source bug amended mid-run, the verdict improved,
# the superseded wording left standing (WFI-200).
#
# `--requestion` is the repair and has existed since; what was missing is
# anything that tells a reader the repair is DUE. So: reported, never enforced.
# The remedy is a worker's judgement about whether the recorded fact changed,
# and re-deriving a question from a codebase that has moved is its own defect
# (WFI-180/181/182). This says only that the text and the plan have parted.
question_stale=false
if [ "$open" = "true" ] && [ -n "$open_fp" ]; then
  now_fp=$(wf_plan_body_fingerprint "$id" || true)
  if [ -n "$now_fp" ] && [ "$now_fp" != "$open_fp" ]; then
    question_stale=true
  fi
fi
# And the context, for an open question: the same comparison as above, against
# what the question was asked in. The dispatcher withdraws a spec-approval
# whose context moved (lv-orchestrate.sh); this is what it reads.
if [ "$open" = "true" ]; then
  open_ctx=$(wf_gate_field "$gate_file" GATE_PLAN_CONTEXT_AT_OPEN)
  if [ -n "$open_ctx" ]; then
    ctx_changed=$(wf_context_changed "$open_ctx" "$(wf_plan_context "$id")")
    if [ -n "$ctx_changed" ]; then
      ctx_stale=true
      question_stale=true
    else
      ctx_stale=false
    fi
  else
    ctx_stale=false; ctx_changed=""
  fi
fi
# An open gate reports the revision it was asked about too, not just a closed
# one — that is what the check above compares, and a caller may want it.
if [ "$open" = "true" ] && [ -z "$fp_at_open" ]; then
  fp_at_open="$open_fp"
fi

# ── An open question is not an answered one ───────────────────────────────
#
# `open` and `answered` are read from two different places — the live gate file
# and the resolved ledger — and nothing made them agree. A record from an
# earlier round that still matches the current revision, next to a gate that is
# live and unanswered right now, produced GATE_OPEN=true AND GATE_ANSWERED=true
# together: a contradiction, and callers key on the second one.
#
# That is not academic. lv-spec's unattended exit step 6 reads
# `GATE_ANSWERED=true -> do not gate, transition draft -> ready`, so the pair
# transitions a plan over a question a human is still being asked — WFI-047's
# rule arriving from the other direction (client-b WFI-026). Whatever produced
# the state, the resolution of the contradiction is never in doubt: the ledger
# describes a round that finished, the open file describes one that has not.
if [ "$open" = "true" ] && [ "$answered" = "true" ]; then
  answered=false
  basis=none
  stale=false
fi

wf_emit GATE_OPEN        "$open"
wf_emit GATE_QUESTION_STALE "$question_stale"
wf_emit GATE_ANSWERED    "$answered"
wf_emit GATE_ANSWERED_BASIS "$basis"
wf_emit GATE_RESOLUTION  "$resolution"
wf_emit GATE_QUESTION    "$question"
wf_emit GATE_RESOLVED_AT "$resolved_at"
wf_emit GATE_STALE       "$stale"
wf_emit GATE_PLAN_CONTEXT_STALE   "$ctx_stale"
wf_emit GATE_PLAN_CONTEXT_CHANGED "$ctx_changed"
wf_emit GATE_WITHDRAWN   "$withdrawn"
wf_emit GATE_PLAN_BODY_FP_AT_OPEN "$fp_at_open"
wf_emit GATE_DECISION    "$decision"
wf_emit GATE_PROMOTE_TIP "$promote_tip"
