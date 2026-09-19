#!/usr/bin/env bash
# wf-gate-open.sh <artifact-id> <gate-name> <question> [--context <path>] [--skill <name>]
#                 [--requestion] [--force]
#
# --requestion  Replace the question on a gate that is ALREADY OPEN and still
#               unanswered, keeping its opened-at timestamp and queue position.
#               For a verdict that legitimately changed while the gate was
#               parked — a new review round, an amended source artifact. NOT for
#               rephrasing: see the comment at the already-open branch.
#
# Parks an artifact on a human decision. An unattended worker calls this INSTEAD
# of asking a question, then exits 0. The dispatcher skips any artifact with an
# open gate, so nothing spins; /wf-attend drains the queue later.
#
# Gate file: <develop-root>/.claude/orchestrator/gates/<ID>.gate
# One file per artifact — concurrent workers would race on appends to a shared
# file, and per-artifact files make "is this one parked?" a single test -f.
#
# Gate names in use. (R) marks the revision-scoped ones — see
# wf_gate_revision_scoped in wf-orch-lib.sh. Their answer holds until the plan's
# specification changes, and re-opening one is refused:
#   spec-approval   (R) spec is drafted AND reviewed, and needs sign-off before
#                   code is written (the review always runs first — see wf-spec)
#   spec-stuck      (R) the review blocked the plan for maxReviewRounds rounds
#   scope-reduction (R) a replan narrows a capability the plan's Goal promises
#   prior-work      (R) code for this plan is already on develop, outside the
#                   pipeline — accept it, or revert it and build per plan.md
#   goal-missing    (R) plan has no concrete goal line
#   migration       (R) plan has pending MIGRATION-NOTES actions
#   consistency-migration (R) wf-consistency found a cross-plan contradiction
#   branch-exists   (R) the feature branch is already there and is not this
#                   plan's to take
#   manual-test     a `#### Manual` acceptance criterion needs human eyes —
#                   asked once per test CYCLE, so never revision-scoped
#   merge-failed    PR could not be merged (conflicts, checks, protection)
#   stuck           plan exceeded its attempt budget
#   needs-input     anything else a worker cannot decide
#   release-approval  an unattended /wf-release found no standing grant for the
#                     develop -> release promotion (wf-autonomy.sh release)
#   deploy-approval   an unattended /wf-deploy found no standing grant for the
#                     release -> main promotion (wf-autonomy.sh deploy)
#   deploy-deferred-criteria  an unattended /wf-deploy step 4a found criteria
#                     the plans in this batch shipped without. Scoped to the
#                     release tip like deploy-approval, so the answer lapses
#                     when the batch changes (client-a WFI-260). Use this
#                     name — a worker that invents its own gets no scoping.
#   deploy-suite-red  /wf-deploy step 2b found that this exact release tip has
#                     already merged and failed the full suite
#                     (wf-deploy-suite-memo.sh). Not an approval question: no
#                     answer promotes it, the fix has to land on `release`, and
#                     doing so moves the tip and clears the memo. Parked so a
#                     human sees the failing test instead of three more suites.
#
# Re-opening an existing gate is a no-op (keeps the original timestamp), so a
# retried worker doesn't reset the queue position.
#
# A gate that has already been ANSWERED is refused outright — see below.
#
# Exit 0 when a gate is open, 1 on error, 3 when the gate was refused because
# an answer of record already covers this revision of the plan.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

artifact="${1:-}"
gate_name="${2:-}"
question="${3:-}"
shift 3 2>/dev/null || true

context=""
skill=""
force=false
requestion=false
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    context="${2:?--context requires a path}"; shift 2 ;;
    --skill)      skill="${2:?--skill requires a name}"; shift 2 ;;
    --force)      force=true; shift ;;
    --requestion) requestion=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$artifact" ] || [ -z "$gate_name" ] || [ -z "$question" ]; then
  echo "Usage: $0 <artifact-id> <gate-name> <question> [--context path] [--skill name]" >&2
  exit 1
fi

# ── A URL with an empty port is not a question, it's a bash-substitution bug ──
#
# A caller composes `http://localhost:$FEATURE_PORT` in one Bash tool call and
# the gate-open call in a LATER one — the Bash tool's shell state does not
# persist between calls, so `$FEATURE_PORT` is unset there and expands to
# nothing before this script ever sees the argument. client-c's WFI-020:
# PLN-020's manual-test gate read "App is running on http://localhost:. Ready
# for manual verification." — the port silently dropped, and a human handed
# only this cannot reach the app without going and reading the plan. Nothing
# catches this class of bug at the point it is written, only at the point a
# human is confused by it, unless it is caught here.
#
# Written to catch host:PORT generally, not just localhost — a bash-side
# empty-var artifact leaves the same trailing colon whatever the host is.
for text in "$question" "$context"; do
  if printf '%s' "$text" | grep -qE '://[A-Za-z0-9.-]+:([[:space:].,;)]|$)'; then
    echo "Error: gate question/context names a URL with an empty port — a variable substitution likely landed empty:" >&2
    echo "  $text" >&2
    echo "  The Bash tool does not carry shell variables between calls. Capture the port's actual" >&2
    echo "  VALUE (e.g. from wf-docker-up.sh's own output) and write it as a literal number here," >&2
    echo "  not as \$FEATURE_PORT in a call made after the one that set it." >&2
    exit 1
  fi
done

# Accept PLN-004 or PLN-004-slug, or the fixed pipeline-stage literals
# RELEASE / DEPLOY (release and deploy are batches across plans, not one
# artifact, so they gate under a fixed name rather than a counter-allocated
# number — see wf_claim_dir in wf-orch-lib.sh for the same distinction).
case "$artifact" in
  RELEASE|DEPLOY) id="$artifact" ;;
  *) id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true) ;;
esac
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a PLN/BUG/BRF id, or RELEASE/DEPLOY" >&2
  exit 1
fi

# One artifact, one gate — resolved by NUMBER, so opening under BRF-161 finds
# the gate wf-spec opened under PLN-161 rather than writing a second file for
# the same piece of work (WFI-187). When none is open this is the exact name,
# which is where a new one belongs.
gate_file=$(wf_gate_file "$id" || true)

if [ -f "$gate_file" ]; then
  existing=$(wf_gate_field "$gate_file" GATE_NAME)
  if [ "$existing" = "$gate_name" ]; then
    # ── The parked question can go out of date while it is parked ─────────
    #
    # A gate is opened carrying a verdict, and the verdict can legitimately
    # change afterwards. client-a's PLN-202: a human amended the source bug
    # mid-run (70d24890), so the plan was corrected and re-reviewed from
    # "Approved with notes" to "Approved" — with the spec-approval gate already
    # open and unanswered, carrying the superseded round-2 wording. Re-running
    # this printed "already open — left as is" and exited 0. There was no
    # documented way to refresh it, and close-then-reopen is the re-derived-
    # question anti-pattern WFI-180/181/182 exist to forbid (WFI-200).
    #
    # `--requestion` is the narrow path between those. It rewrites the question
    # in place, KEEPS the original GATE_OPENED so the queue position does not
    # reset, and keeps the superseded wording in GATE_QUESTION_PREV so the
    # change is auditable rather than silent.
    #
    # THIS IS NOT A LICENCE TO RE-DERIVE. The anti-pattern is a later worker
    # composing a fresh question from a codebase that has moved — that is how
    # PLN-135's question came to describe a HashSet that had been a Dictionary
    # for two plans. Use this only when the FACT the question reports has
    # changed on the record: a new review round, an amended source artifact, a
    # commit that resolves the thing being asked about. Not because you have
    # re-read the code and would phrase it better.
    if $requestion; then
      prev_q=$(wf_gate_field "$gate_file" GATE_QUESTION)
      if [ "$prev_q" = "$question" ]; then
        echo "$id: gate '$gate_name' already open — question unchanged, left as is"
        exit 0
      fi
      opened_at=$(wf_gate_field "$gate_file" GATE_OPENED)
      prev_prev=$(wf_gate_field "$gate_file" GATE_QUESTION_PREV)
      open_fp=$(wf_gate_field "$gate_file" GATE_PLAN_BODY_FP_AT_OPEN)
      {
        wf_emit GATE_ID       "$id"
        wf_emit GATE_ARTIFACT "$artifact"
        wf_emit GATE_NAME     "$gate_name"
        wf_emit GATE_QUESTION "$question"
        wf_emit GATE_CONTEXT  "$context"
        wf_emit GATE_SKILL    "$skill"
        wf_emit GATE_OPENED   "$opened_at"
        wf_emit GATE_REQUESTIONED "$(wf_now)"
        wf_emit GATE_QUESTION_PREV "${prev_prev:+$prev_prev
}$prev_q"
        # An `if`, not `[ … ] && …`: as the last command in this group a false
        # test makes the group exit 1 and `set -e` kills the script.
        if [ -n "$open_fp" ]; then
          wf_emit GATE_PLAN_BODY_FP_AT_OPEN "$open_fp"
        fi
      } > "$gate_file"
      wf_event gate-requestion "$id" "$gate_name: $question"
      echo "$id: gate '$gate_name' question updated (opened $opened_at, still unanswered) — $question"
      exit 0
    fi
    echo "$id: gate '$gate_name' already open — left as is"
    echo "  If the fact behind the question has changed on the record, refresh it with --requestion." >&2
    exit 0
  fi
fi

# ── An answered question is not asked again ───────────────────────────────
#
# Every skill's gating rule is re-evaluated from scratch on every dispatch, and
# the conditions that justify a gate are usually durable facts: the plan carries
# a gateTag, a commit sits on develop touching this plan's files. So the rule
# reads the same the second time, and the worker opens the gate a human just
# closed. wf-gate-status.sh exists to answer this and the skills were told to
# consult it — but a rule the caller must remember is a rule that gets forgotten
# at exactly the moment it matters.
#
# client-a's PLN-135 (WFI-180, WFI-181, WFI-182): a `prior-work` gate
# answered and closed at 11:43:42Z, re-opened at 12:01:45Z with identical
# wording while wf-gate-status.sh still reported GATE_ANSWERED=true and
# GATE_STALE=false. Then a third time, one minute after a close returned 0.
# Then a fourth, thirty minutes after the decision was committed to findings.md,
# by which point the worker had RE-DERIVED the question rather than replaying
# it — offering an option the human had never authorized and describing a
# HashSet that had been a Dictionary since a merge two plans earlier.
#
# That is the cost that makes this a refusal rather than a warning: a re-asked
# question does not come back the same. It comes back re-derived from whatever
# the next worker happens to read, and a human answering it is answering
# something else.
#
# The refusal is scoped to gates whose answer is about the plan as it stands
# (wf_gate_revision_scoped) and lapses the moment the specification changes —
# GATE_STALE=true is a genuinely new question and opens normally. --force is
# for an operator who means it.
if ! $force && wf_gate_revision_scoped "$gate_name"; then
#
# `GATE_ANSWERED_BASIS=revision` is required, not just GATE_ANSWERED: the
# answer must have been checked against a fingerprint that was actually
# compared. `assumed` means one side had none — an old record, a missing file, a
# plan with no REGISTRY row to find it by — and refusing to ask a human on the
# strength of a file that is not there is how a real question goes unasked.
  eval "$("$SELF_DIR/wf-gate-status.sh" "$id" "$gate_name" 2>/dev/null || true)"

  # ── The answer covers the text the human SAW, not the text at close ──────
  #
  # The exit contract is commit the transition, close the gate, unclaim — close
  # last, always (docs/guard-ordering.md). The resolved record's fingerprint is
  # taken at close, so anything committed between the human answering and the
  # close is fingerprinted INTO the approval. The two rules interact badly:
  # client-a's PLN-192 is contract-tagged, so wf-spec step 6d requires a
  # re-gate after an amendment changes the document — and closing the gate after
  # committing Amendment A2 stamped the resolution against the post-amendment
  # revision, so this refusal fired and the re-gate could not happen. The
  # suppression was an artifact of the mandated ordering, not of what the human
  # approved: close the gate BEFORE committing the same amendment and it
  # re-gates normally (WFI-198). A contract-tagged plan could therefore reach
  # `ready` on an approval given before the amendment existed — WFI-178 exactly.
  #
  # wf-gate-open.sh records the plan's fingerprint when the question is ASKED,
  # and wf-gate-close.sh carries it into the resolved record. That is the
  # revision the human was shown, so it is the one staleness is judged against
  # here. Records written before this existed have no at-open fingerprint, and
  # fall back to the close-time comparison wf-gate-status.sh already did.
  if [ -n "${GATE_PLAN_BODY_FP_AT_OPEN:-}" ]; then
    now_fp=$(wf_plan_body_fingerprint "$id" || true)
    if [ -n "$now_fp" ] && [ "$now_fp" != "$GATE_PLAN_BODY_FP_AT_OPEN" ]; then
      echo "$id: '$gate_name' was answered, but the plan has changed since the question was ASKED." >&2
      echo "  The answer of record is about the earlier text; opening a fresh gate on the plan as it now stands." >&2
      GATE_STALE=true
    fi
  fi

  if [ "${GATE_ANSWERED:-false}" = "true" ] && [ "${GATE_STALE:-false}" != "true" ] \
     && [ "${GATE_ANSWERED_BASIS:-none}" = "revision" ]; then
    wf_event gate-refused "$id" "$gate_name: already answered ${GATE_RESOLVED_AT:-} — $question"
    echo "$id: gate '$gate_name' NOT opened — it was answered${GATE_RESOLVED_AT:+ at $GATE_RESOLVED_AT} and the plan has not changed since." >&2
    [ -n "${GATE_QUESTION:-}" ] && echo "  asked:      $GATE_QUESTION" >&2
    echo "  resolution: ${GATE_RESOLUTION:-—}" >&2
    echo "  Act on that answer and carry on. It is the decision of record; do not re-derive the question." >&2
    echo "  If the plan really has moved on, amend it — a changed specification re-opens this gate by itself." >&2
    exit 3
  fi
fi

# ── A cycle-scoped gate that keeps coming back ────────────────────────────
#
# The refusal above only covers revision-scoped gates. `needs-input` and
# `manual-test` are asked once per CYCLE by design, so they must be allowed to
# re-open — and that is exactly how a loop hides. client-a's PLN-204 opened
# the same needs-input question on three consecutive verify cycles (WFI-203,
# WFI-204, WFI-205). Dedup could not catch it: each cycle's wording differs in
# its specifics — a new worktree sha, the same 2300/2300 restated — so a literal
# match sees three different questions where a reader sees one.
#
# Semantic matching is not the answer; guessing that two questions "mean the
# same" is how a genuinely new question gets swallowed. What IS certain is that
# a gate of this name on this artifact has been answered before, and that the
# human draining the queue cannot see it. So the prior answer is carried onto
# the new gate. The question still gets asked — the reader just gets told they
# have answered one like it, and what they said, which is what turns "another
# question" into "this is the third time".
prior_q=""; prior_res=""; prior_at=""
if ! wf_gate_revision_scoped "$gate_name"; then
  prior_file=$(wf_gate_resolved_file "$id" "$gate_name" || true)
  if [ -n "$prior_file" ] && [ -f "$prior_file" ]; then
    prior_q=$(wf_gate_field "$prior_file" GATE_QUESTION)
    prior_res=$(wf_gate_field "$prior_file" GATE_RESOLUTION)
    prior_at=$(wf_gate_field "$prior_file" GATE_RESOLVED)
  fi
fi

{
  wf_emit GATE_ID       "$id"
  wf_emit GATE_ARTIFACT "$artifact"
  wf_emit GATE_NAME     "$gate_name"
  wf_emit GATE_QUESTION "$question"
  wf_emit GATE_CONTEXT  "$context"
  wf_emit GATE_SKILL    "$skill"
  wf_emit GATE_OPENED   "$(wf_now)"
  # The revision the question is being asked ABOUT — see the refusal above.
  # Empty for a bug or brief with no plan folder yet, which is fine: those
  # gates fall back to the close-time comparison.
  wf_emit GATE_PLAN_BODY_FP_AT_OPEN "$(wf_plan_body_fingerprint "$id" || true)"
  # ── What a promotion approval is an approval OF ────────────────────────
  #
  # RELEASE and DEPLOY have no plan.md, so the fingerprint above is empty and
  # nothing scopes their answer to anything. The commit set is their revision:
  # "promote these commits" is a question about a source branch at one tip.
  # Recording it here is what lets wf-promote-approval.sh tell an answer that
  # still covers the promotion in front of it from one given about an older
  # batch (client-b WFI-005).
  #
  # Fetched first. A tip this checkout has not heard about yet is not the batch
  # in front of anyone, and an approval recorded against it is discarded the
  # moment something else fetches — client-a WFI-264, where that gap was four
  # hours wide and cost the human the same answer twice. See wf_promote_fetch.
  if [ -n "$(wf_promote_tip_ref "$gate_name")" ]; then
    wf_promote_fetch "$gate_name"
    wf_emit GATE_PROMOTE_TIP "$(wf_promote_tip "$gate_name" || true)"
  fi
  if [ -n "$prior_res" ]; then
    wf_emit GATE_PRIOR_QUESTION   "$prior_q"
    wf_emit GATE_PRIOR_RESOLUTION "$prior_res"
    wf_emit GATE_PRIOR_AT         "$prior_at"
  fi
} > "$gate_file"

if [ -n "$prior_res" ]; then
  echo "$id: NOTE — a '$gate_name' gate on this artifact was already answered${prior_at:+ at $prior_at}." >&2
  echo "  asked before: ${prior_q:-—}" >&2
  echo "  answered:     $prior_res" >&2
  echo "  If this is the same question in different words, the answer did not stick — say so when you answer, and fix what re-asks it." >&2
fi

wf_event gate-open "$id" "$gate_name: $question"
echo "$id: gate '$gate_name' opened — $question"
