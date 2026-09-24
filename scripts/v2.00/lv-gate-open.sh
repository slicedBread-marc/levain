#!/usr/bin/env bash
# lv-gate-open.sh <artifact-id> <gate-name> <question> [--context <path>] [--skill <name>]
#                 [--requestion] [--force] [--unclaim | --hold-claim]
#
# --unclaim     Release this artifact's claim once the gate is up. THE DEFAULT
#               for a plan-scoped gate; see "Claim disposition" below.
# --hold-claim  Keep the claim. For a caller that is going to keep working the
#               artifact after the gate is open — /lv-attend answering in place,
#               an attended skill mid-procedure.
#
# --requestion  Replace the question on a gate that is ALREADY OPEN and still
#               unanswered, keeping its opened-at timestamp and queue position.
#               For a verdict that legitimately changed while the gate was
#               parked — a new review round, an amended source artifact. NOT for
#               rephrasing: see the comment at the already-open branch.
#
# Parks an artifact on a human decision. An unattended worker calls this INSTEAD
# of asking a question, then exits 0. The dispatcher skips any artifact with an
# open gate, so nothing spins; /lv-attend drains the queue later.
#
# Gate file: <develop-root>/.claude/orchestrator/gates/<ID>.gate
# One file per artifact — concurrent workers would race on appends to a shared
# file, and per-artifact files make "is this one parked?" a single test -f.
#
# Gate names in use. (R) marks the revision-scoped ones — see
# wf_gate_revision_scoped in lv-orch-lib.sh. Their answer holds until the plan's
# specification changes, and re-opening one is refused:
#   spec-approval   (R) spec is drafted AND reviewed, and needs sign-off before
#                   code is written (the review always runs first — see lv-spec)
#   spec-stuck      (R) the review blocked the plan for maxReviewRounds rounds
#   scope-reduction (R) a replan narrows a capability the plan's Goal promises
#   prior-work      (R) code for this plan is already on develop, outside the
#                   pipeline — accept it, or revert it and build per plan.md
#   goal-missing    (R) plan has no concrete goal line
#   migration       (R) plan has pending MIGRATION-NOTES actions
#   consistency-migration (R) lv-consistency found a cross-plan contradiction
#   branch-exists   (R) the feature branch is already there and is not this
#                   plan's to take
#   manual-test     a `#### Manual` acceptance criterion needs human eyes —
#                   asked once per test CYCLE, so never revision-scoped
#   merge-failed    PR could not be merged (conflicts, checks, protection)
#   stuck           plan exceeded its attempt budget
#   needs-input     anything else a worker cannot decide
#   release-approval  an unattended /lv-release found no standing grant for the
#                     develop -> release promotion (lv-autonomy.sh release)
#   deploy-approval   an unattended /lv-deploy found no standing grant for the
#                     release -> main promotion (lv-autonomy.sh deploy)
#   deploy-deferred-criteria  an unattended /lv-deploy step 4a found criteria
#                     the plans in this batch shipped without. Scoped to the
#                     release tip like deploy-approval, so the answer lapses
#                     when the batch changes (client-a WFI-260). Use this
#                     name — a worker that invents its own gets no scoping.
#   production-push   an unattended /lv-deploy finished the promotion but found
#                     no standing grant for `git push origin main` (step 14).
#                     Scoped to LOCAL main's tip — the commit the push would
#                     send (coordinator WFI-008).
#   deploy-suite-red  /lv-deploy step 2b found that this exact release tip has
#                     already merged and failed the full suite
#                     (lv-deploy-suite-memo.sh). Not an approval question: no
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
# an answer of record already covers this revision of the plan, and 5 when a
# DIFFERENT gate is already open on the artifact — which this refuses rather
# than overwrites, because one file holds one artifact's gate (WFI-025).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Claim disposition ─────────────────────────────────────────────────────
#
# Parking an artifact and releasing its claim are one action. Asking twenty exit
# paths across six skills to remember the second half is how the library ended up
# with gate exits that say "park and exit" and nothing about the claim — a review
# of every skill against docs/prompt-contract.md found the omission in lv-spec
# (every gate exit), lv-test, lv-deploy, lv-attend and lv-consistency. lv-spec:913
# shows the shape: the lesson was learned once, written down as WFI-012, fixed on
# the one path it bit on, and never propagated to the five gate exits in the same
# file. So the script does it.
#
# ORDER IS docs/guard-ordering.md's contract at park time instead of exit time:
# the gate goes UP before the claim comes DOWN, so the artifact is never both
# unguarded and parked. Reverse it and there is a window with no gate and no
# claim while the worker walks away — the two seconds WFI-079 dispatched into.
#
# CALLED ON EVERY PATH THAT LEAVES A GATE UP, which includes the three that find
# one already open and exit 0. Those are the ones that matter most: a worker
# that parks onto somebody else's gate and walks away still holding its claim is
# precisely the stranding this exists to prevent, and it was the path the first
# implementation of this missed.
#
# RELEASE and DEPLOY hold across a gate on purpose: their skills resume in place
# after an answer, and the claim keeps a second promotion out while a human is
# deciding on the first.
release_claim_if_parked() {
  local disposition="$claim_disposition"
  if [ "$disposition" = "default" ]; then
    case "$id" in
      RELEASE|DEPLOY) disposition=hold ;;
      *)              disposition=release ;;
    esac
  fi
  [ "$disposition" = "release" ] || return 0
  # Idempotent, so a skill that also unclaims on its own exit path is not an
  # error — the second call is a no-op and that prose stays true.
  "$SELF_DIR/lv-unclaim.sh" "$id" >&2 || true
}
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

artifact="${1:-}"
gate_name="${2:-}"
question="${3:-}"
shift 3 2>/dev/null || true

context=""
skill=""
force=false
requestion=false
claim_disposition=default
while [ $# -gt 0 ]; do
  case "$1" in
    --context)    context="${2:?--context requires a path}"; shift 2 ;;
    --skill)      skill="${2:?--skill requires a name}"; shift 2 ;;
    --force)      force=true; shift ;;
    --requestion) requestion=true; shift ;;
    --unclaim) claim_disposition=release; shift ;;
    --hold-claim) claim_disposition=hold; shift ;;
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
    echo "  VALUE (e.g. from lv-docker-up.sh's own output) and write it as a literal number here," >&2
    echo "  not as \$FEATURE_PORT in a call made after the one that set it." >&2
    exit 1
  fi
done

# Accept PLN-004 or PLN-004-slug, or the fixed pipeline-stage literals
# RELEASE / DEPLOY (release and deploy are batches across plans, not one
# artifact, so they gate under a fixed name rather than a counter-allocated
# number — see wf_claim_dir in lv-orch-lib.sh for the same distinction).
case "$artifact" in
  RELEASE|DEPLOY) id="$artifact" ;;
  *) id=$(printf '%s' "$artifact" | grep -oE "^($LV_WORK_RE)-[0-9]+" || true) ;;
esac
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a $LV_PLN/$LV_BUG/$LV_BRF id, or RELEASE/DEPLOY" >&2
  exit 1
fi

# One artifact, one gate — resolved by NUMBER, so opening under BRF-161 finds
# the gate lv-spec opened under PLN-161 rather than writing a second file for
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
        release_claim_if_parked
        exit 0
      fi
      opened_at=$(wf_gate_field "$gate_file" GATE_OPENED)
      prev_prev=$(wf_gate_field "$gate_file" GATE_QUESTION_PREV)
      # The revision this question is asked ABOUT, refreshed rather than copied
      # forward. `--requestion` means the question now reports the plan as it
      # NOW stands — the guard above has already refused the case where the
      # wording did not change — and WFI-198's rule is that an approval is
      # scoped to the text the human saw. They will be shown the new question.
      #
      # Copying the old fingerprint forward also left the gate reading
      # `stale` in <qfit> for the rest of its life, even after the very repair
      # the flag exists to prompt (client-b WFI-018). Falls back to the
      # recorded value when there is no fingerprint to take — a bug, a brief,
      # RELEASE/DEPLOY — so a refresh can never ERASE the scoping.
      open_fp=$(wf_gate_field "$gate_file" GATE_PLAN_BODY_FP_AT_OPEN)
      requestion_fp=$(wf_plan_body_fingerprint "$id" || true)
      if [ -n "$requestion_fp" ]; then
        open_fp="$requestion_fp"
      fi
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
      release_claim_if_parked
      exit 0
    fi
    echo "$id: gate '$gate_name' already open — left as is"
    echo "  If the fact behind the question has changed on the record, refresh it with --requestion." >&2
    release_claim_if_parked
    exit 0
  fi

  # ── A DIFFERENT gate is open on this artifact ───────────────────────────
  #
  # Gates are stored one file per ARTIFACT, not one per gate name, so writing
  # here would not add a second gate — it would silently destroy the first.
  # This used to fall straight through and do exactly that, exit 0, no output.
  #
  # client-b WFI-025 is the whole sequence, and every step of it exited 0:
  # a `needs-input` gate was open and listed; lv-spec's replan step 6d opened
  # `spec-approval` on the same plan, overwriting it; and the attendant then
  # closed `needs-input` by name, which resolved the file that by then held the
  # spec-approval question. The ledger recorded a `needs-input` resolution
  # paired with a question it was never given, findings.md published it as "the
  # decision of record — act on it rather than re-deriving the question", and
  # the spec-approval gate a human owed an answer to simply did not exist:
  # lv-list-gates.sh reported GATES: 0 over a plan with two unanswered
  # questions. That is the fabricated record WFI-100 warns about, manufactured
  # by the harness rather than by a worker.
  #
  # So this refuses. One artifact parks on one question at a time — that is the
  # model the dispatcher reads (`gate_open <id>` is a boolean per artifact) and
  # it is not this script's to widen. Answer the open one, or if the new
  # question supersedes it, close it on its own terms first and say so.
  echo "Error: $id already has a DIFFERENT gate open — '$existing', not '$gate_name'." >&2
  echo "       Gates are one per artifact, so opening this one would destroy that" >&2
  echo "       question without recording it, and closing it later by name would file" >&2
  echo "       its resolution against the wrong question (client-b WFI-025)." >&2
  open_q=$(wf_gate_field "$gate_file" GATE_QUESTION 2>/dev/null || true)
  [ -n "$open_q" ] && echo "       Still unanswered: $open_q" >&2
  echo "       Answer it first:" >&2
  echo "         lv-gate-close.sh $id \"<resolution>\" --only $existing" >&2
  echo "       Or, if this new question supersedes it, close it saying so, then re-run this." >&2
  echo "       Nothing was changed." >&2
  exit 5
fi

# ── An answered question is not asked again ───────────────────────────────
#
# Every skill's gating rule is re-evaluated from scratch on every dispatch, and
# the conditions that justify a gate are usually durable facts: the plan carries
# a gateTag, a commit sits on develop touching this plan's files. So the rule
# reads the same the second time, and the worker opens the gate a human just
# closed. lv-gate-status.sh exists to answer this and the skills were told to
# consult it — but a rule the caller must remember is a rule that gets forgotten
# at exactly the moment it matters.
#
# client-a's PLN-135 (WFI-180, WFI-181, WFI-182): a `prior-work` gate
# answered and closed at 11:43:42Z, re-opened at 12:01:45Z with identical
# wording while lv-gate-status.sh still reported GATE_ANSWERED=true and
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
  eval "$("$SELF_DIR/lv-gate-status.sh" "$id" "$gate_name" 2>/dev/null || true)"

  # ── The answer covers the text the human SAW, not the text at close ──────
  #
  # The exit contract is commit the transition, close the gate, unclaim — close
  # last, always (docs/guard-ordering.md). The resolved record's fingerprint is
  # taken at close, so anything committed between the human answering and the
  # close is fingerprinted INTO the approval. The two rules interact badly:
  # client-a's PLN-192 is contract-tagged, so lv-spec step 6d requires a
  # re-gate after an amendment changes the document — and closing the gate after
  # committing Amendment A2 stamped the resolution against the post-amendment
  # revision, so this refusal fired and the re-gate could not happen. The
  # suppression was an artifact of the mandated ordering, not of what the human
  # approved: close the gate BEFORE committing the same amendment and it
  # re-gates normally (WFI-198). A contract-tagged plan could therefore reach
  # `ready` on an approval given before the amendment existed — WFI-178 exactly.
  #
  # lv-gate-open.sh records the plan's fingerprint when the question is ASKED,
  # and lv-gate-close.sh carries it into the resolved record. That is the
  # revision the human was shown, so it is the one staleness is judged against
  # here. Records written before this existed have no at-open fingerprint, and
  # fall back to the close-time comparison lv-gate-status.sh already did.
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

# A promotion question has to say which tip it is about — the approval is
# scoped to that tip, and a human cannot scope an answer to a commit they were
# not shown. coordinator WFI-037: a production-push gate asked "Push main  to
# origin?", its sha substituted to nothing, and the operator approved blind.
# The tip is stamped below either way; when the question does not already name
# it, it is appended so the reader sees the same commit the answer binds to.
promote_tip=""
if [ -n "$(wf_promote_tip_ref "$gate_name")" ]; then
  wf_promote_fetch "$gate_name"
  promote_tip=$(wf_promote_tip "$gate_name" || true)
  if [ -n "$promote_tip" ]; then
    case "$question" in
      *"${promote_tip:0:7}"*) ;;
      *) question="$question [$(wf_promote_tip_ref "$gate_name") at ${promote_tip:0:7}]" ;;
    esac
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
  # Recording it here is what lets lv-promote-approval.sh tell an answer that
  # still covers the promotion in front of it from one given about an older
  # batch (client-b WFI-005).
  #
  # Fetched first. A tip this checkout has not heard about yet is not the batch
  # in front of anyone, and an approval recorded against it is discarded the
  # moment something else fetches — client-a WFI-264, where that gap was four
  # hours wide and cost the human the same answer twice. See wf_promote_fetch.
  if [ -n "$(wf_promote_tip_ref "$gate_name")" ]; then
    wf_emit GATE_PROMOTE_TIP "$promote_tip"
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

release_claim_if_parked
