#!/usr/bin/env bash
# wf-registry-update.sh <plan-id> <from-state> <to-state> [branch] [--commit "msg" [--add file ...]]
# Updates a plan's state in REGISTRY.md and sets the date to today.
# If branch is provided, updates the Branch column too.
# If branch is "-", clears the Branch column to "—".
#
# --note "text"    Record WHY this transition happened, atomically with it.
#
#                  The note goes to the plan's progress.md, under `## Notes`,
#                  dated and stamped with the transition — not to REGISTRY.md,
#                  which has no Notes column (ID, Slug, State, Priority,
#                  Branch, Updated, WF, Tags, Deps and nothing else). A note
#                  with nowhere to go gets stuffed into whichever cell is
#                  nearest, and the audit keeps finding prose in the Branch
#                  column as a result: `BUG-234-235 shipped alongside`, or the
#                  literal word `complete` (WFI-242).
#
#                  It is written under the same lock and lands in the same
#                  commit as the transition, which is the point: a note that
#                  explains the state a plan is LEAVING cannot survive into the
#                  next state contradicting it. PLN-259 reached `ready` still
#                  carrying "scope needs re-check before build" — an
#                  instruction to stop, on a row that says go — and the only
#                  way to correct it was a hand edit of REGISTRY.md, which the
#                  workflow forbids (WFI-235).
#
# --commit "msg"   Atomically: update → git add → git commit, all under the lock.
# --add file ...   Extra files to stage (in addition to REGISTRY.md). Only with --commit.
# --no-commit      Leave the transition staged but uncommitted (rarely correct).
#
# WITHOUT --commit the transition is STILL committed, under an auto-generated
# message. It used to be left dirty for the caller's own later commit, and a
# dirty REGISTRY.md on the develop root does not survive concurrency: another
# worker's `git stash push --include-untracked` takes it, another's pathspec
# commit carries it under the wrong message. client-a lost a whole
# ready→active transition that way (WFI-065) — 20 minutes into an
# implementation the registry read `ready` with no branch, as if Phase 1 had
# never run, which is exactly the state a second dispatch reads as free work.
# WFI-061 is the same file from the other side: one worker's uncommitted Tags
# edit shipped inside another worker's commit. A row written and committed in
# one locked step can be taken by neither.
#
# The `registry` lock is held for the whole run, not just for --commit — any
# read-modify-write of REGISTRY.md races once more than one worker is live.
#
# Examples:
#   wf-registry-update.sh PLN-004 ready active feature/PLN-004-slug
#   wf-registry-update.sh PLN-004 active verify
#   wf-registry-update.sh PLN-004 testing complete -
#   wf-registry-update.sh PLN-004 verify testing --commit "verify(PLN-004): clean"
#   wf-registry-update.sh PLN-004 draft ready --note "scope settled against publish-guard"
#   wf-registry-update.sh PLN-004 verify active --commit "verify(PLN-004): findings" --add plans/PLN-004-slug/findings.md
#
# GUARDS. Four transitions verify the claim they make rather than take the
# caller's word for it. Each has its own override, and each override is a
# sentence a human has to type:
#
#   draft -> ready      WF_ALLOW_UNREVIEWED=1   no review of record (WFI-164)
#   draft -> ready      WF_ALLOW_UNGATED=1      spec-approval open, unanswered
#                                               (client-b WFI-012)
#   testing -> complete WF_ALLOW_UNTESTED=1     an eyes:blocking criterion with
#                                               no tick, no record, no gate
#                                               (client-d WFI-009)
#   * -> complete       WF_ALLOW_UNMERGED=1     branch merged nowhere (WFI-165)
#
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"
# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"
# shellcheck source=wf-states.sh
source "$(dirname "$0")/wf-states.sh"

# Resolved BEFORE the cd: `$0` may be relative, and `dirname "$0"` after moving
# to the develop root then names a directory that does not exist.
SELF_DIR=$(cd "$(dirname "$0")" && pwd)

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

# --- Parse arguments ---
raw_id="${1:-}"
from_state="${2:-}"
to_state="${3:-}"
shift 3 2>/dev/null || true

branch=""
commit_msg=""
note=""
no_commit=false
add_files=()

# Fourth positional arg is branch if it doesn't start with --
if [ "${1:-}" != "" ] && [[ "${1:-}" != --* ]]; then
  branch="$1"
  shift
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --commit)
      commit_msg="${2:?--commit requires a message}"
      shift 2
      ;;
    --note)
      note="${2:?--note requires text}"
      shift 2
      ;;
    --no-commit)
      no_commit=true
      shift
      ;;
    --add)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        add_files+=("$1")
        shift
      done
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Normalize: accept both "PLN-NNN" and "PLN-NNN-slug" formats
plan_id=$(echo "$raw_id" | grep -oE '^PLN-[0-9]+' || echo "$raw_id")

if [ -z "$plan_id" ] || [ -z "$from_state" ] || [ -z "$to_state" ]; then
  echo "Usage: $0 <plan-id> <from-state> <to-state> [branch] [--note \"text\"] [--commit \"msg\" [--add file ...]]" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# --- Validate the destination state ---
#
# This script writes whatever string it is handed into the State column, and
# for a long time it validated none of it. app dropped six plans and wrote them
# as `abandoned` — a state that did not exist. It was accepted silently, and
# the consequences landed elsewhere: the orchestrator hard-fails on an unknown
# state, and four dependency checks read "not complete" as "not satisfied yet",
# so an abandoned plan named in a Deps column would have blocked its dependents
# forever with no way to clear it (WFI-008).
#
# The state set is small, closed, and documented. Any typo in a caller — or any
# state someone invents under deadline — becomes a live value in the pipeline's
# single source of truth, so it is rejected here rather than discovered later.
#
# `from_state` is deliberately NOT validated: it has to match the row anyway,
# and a client whose registry already holds a nonstandard value must still be
# able to transition out of it.
if ! wf_state_is_valid "$to_state"; then
  echo "Error: '$to_state' is not a workflow state." >&2
  echo "       Valid: $WF_STATES" >&2
  echo "       To drop a plan, use wf-abandon.sh — it records the reason." >&2
  exit 1
fi

# `abandoned` is terminal. Revival is deliberate and goes back to planning: the
# branch may be months stale, so resuming mid-pipeline is not safe.
if [ "$from_state" = "abandoned" ] && [ "$to_state" != "draft" ]; then
  echo "Error: $plan_id is abandoned. Revive it to 'draft' first, then replan." >&2
  exit 1
fi

# ── A finished plan does not walk backwards ───────────────────────────────
#
# `complete`, `rolled-back` and `abandoned` are terminal: the work shipped, was
# reverted, or was dropped. No worker acts on them and no wf-list-* offers them
# — but nothing stopped a worker that had reached one anyway from writing a
# live state over it.
#
# client-a's PLN-111 (WFI-172): complete, its PR merged, its worktree
# removed. An unattended tester ran against it regardless; the runner could not
# write its TOOL file into a deleted working directory, the single writer failure
# was reported as "29 errors", and the tester wrote a finding and moved the plan
# complete -> active. Re-running the suite on develop gave 871 total, 0 failed.
# A shipped plan spent the next hours advertising itself as unfinished work.
#
# Terminal -> terminal is still allowed: /wf-rollback moves a completed plan to
# `rolled-back`, which is a record of what happened to it, not a resumption.
# `abandoned` has its own rule directly above — explicit revival to `draft`, and
# nowhere else (docs/abandoned-plans.md) — so it is not re-judged here.
# WF_ALLOW_REOPEN=1 covers a deliberate revival, and being an environment
# variable it cannot be reached by a worker following its own skill's steps.
if [ "$from_state" != "abandoned" ] \
   && wf_state_is_terminal "$from_state" && ! wf_state_is_terminal "$to_state" \
   && [ "${WF_ALLOW_REOPEN:-}" != "1" ]; then
  echo "Error: $plan_id is '$from_state', which is terminal — refusing to move it to '$to_state'." >&2
  echo "       That plan is finished. If a worker was dispatched at it, the dispatch is the" >&2
  echo "       fault, not the state (WFI-172): check the claim's --state guard rather than" >&2
  echo "       reopening the row. A failure found in shipped work is a new bug, filed with" >&2
  echo "       /wf-bug — not a regression of the plan that shipped it." >&2
  echo "       Nothing was changed. WF_ALLOW_REOPEN=1 overrides a deliberate revival." >&2
  exit 1
fi

today=$(date +%Y-%m-%d)

# --- Everything below mutates the registry: take the lock first ---
wf_lock_acquire registry

# Verify the plan exists in the expected state.
#
# Name the state it IS in. "not found in state 'active'" reads as "no such
# plan" and sent one caller looking for a missing row; the row was there, one
# state below, because a replan had written `ready` where the caller's exit
# contract expected `active`.
if ! grep -q "^| $plan_id |.*| $from_state |" "$REGISTRY"; then
  actual=$(wf_registry_field "$plan_id" state "$REGISTRY")
  if [ -n "$actual" ]; then
    echo "Error: $plan_id is in state '$actual', not '$from_state'" >&2
  else
    echo "Error: $plan_id has no row in $REGISTRY" >&2
  fi
  exit 1
fi

# --- Guard: a plan may only be advertised as `ready` if the review says so ---
#
# `ready` is a promise to a builder: a human or an unattended reviewer read this
# plan and approved it. Every draft→ready caller is wf-spec's review gate, so
# the promise is only ever as good as the review LANDING — and it does not
# always land.
#
# client-a's WFI-164: wf-spec wrote both review rounds into plan.md, stamped
# them, and called this script with `--add plans/PLN-107-…/`. It reported
# "committed 1 path(s)" and committed only REGISTRY.md, because by then the
# review was not in the working tree at all — a concurrent wf-test run's
# `wf-stash.sh push` had swept the whole shared develop checkout seconds
# earlier, plan.md included. The row said `ready`; the committed plan.md said
# "> Filled by the planner's review gate". A plan advertised as reviewed whose
# text records no review is the exact state WFI-122 and WFI-140 exist to
# prevent, reached that time through the transition commit rather than around
# it.
#
# So the row is not written on trust. wf-review-status.sh already answers this
# mechanically, and it knows the difference between a verdict and the
# template's own menu of verdicts. It reads the WORKING TREE, which is what a
# `--commit` here will carry (`git commit -- <paths>` records working-tree
# content), so this refuses precisely when the commit would publish a lie.
#
# A missing plan folder lands here too, and refusing is right: WFI-053 left a
# registry reading `ready` for a plan git had never seen, and a builder moved
# it to `active` against a folder that did not exist.
#
# WF_ALLOW_UNREVIEWED=1 is the escape hatch — a migration, a client importing
# plans that predate the review gate, or the test suite's registry-only
# fixtures. It is never the answer to a plan the reviewer has not seen.
if [ "$from_state" = "draft" ] && [ "$to_state" = "ready" ] && [ "${WF_ALLOW_UNREVIEWED:-}" != "1" ]; then
  REVIEW_LOCATION=none
  REVIEW_STALE=false
  eval "$("$SELF_DIR/wf-review-status.sh" "$plan_id" 2>/dev/null || true)"
  if [ "${REVIEW_LOCATION:-none}" = "none" ]; then
    echo "Error: $plan_id has no review of record — refusing to mark it 'ready'." >&2
    echo "       'ready' tells a builder this plan was reviewed and approved. Its" >&2
    echo "       plan.md carries no verdict, only the template placeholder (WFI-164)." >&2
    echo "       If you just wrote one, it is not on disk where this can see it:" >&2
    echo "       re-write the '## Review' section, re-run wf-review-stamp.sh, and" >&2
    echo "       verify with: wf-review-status.sh $plan_id" >&2
    echo "       Nothing was changed. WF_ALLOW_UNREVIEWED=1 overrides (migrations only)." >&2
    exit 1
  fi
  if [ "${REVIEW_STALE:-false}" = "true" ]; then
    echo "wf-registry-update: warning — $plan_id's review is STALE (the plan changed after the verdict)." >&2
    echo "                    Marking it ready anyway; re-review before a builder acts on it." >&2
  fi
fi

# --- Guard: the gate that gates this transition is still open ------------
#
# An open `spec-approval` gate asks one question and only one: may a builder
# start on this plan. `draft -> ready` IS that answer. So a transition written
# while the gate is open and unanswered does not bypass a check somewhere else
# in the pipeline — it answers the human's question on their behalf, in a
# commit, and leaves the gate standing as the only thing still holding the
# dispatch back.
#
# client-b WFI-012: PLN-011 went draft -> ready at 512143e on the strength of
# an unattended architecture review reaching "Approved" at round 3 — its
# spec-approval gate had been open and unanswered since 14:30Z. The subject
# said as much: "spec approved round 3, transition was never applied". A daemon
# was live (pid 84870) and the open gate was the single remaining reason
# /wf-implement was not dispatched on a plan no human had approved.
# wf-list-gates.sh reported fit=mismatch, correctly — but the state it named as
# a mismatch was one the transition should not have been able to produce.
#
# The reviewer's verdict and the gate answer different questions, and the
# transition here is the place that conflates them: the review asks "is this
# plan sound", the gate asks "do you, the human, accept what it commits us to".
# wf-replan-target.sh already refuses this for a REPLAN, but only by
# re-deriving the need from gating tags. This asks nothing and derives nothing:
# a gate is open, or it is not. Self-clearing, so the fix is always the same —
# answer it, with the question it actually asked:
#
#   wf-gate-list.sh / wf-attend        the queue it is sitting in
#   wf-gate-close.sh <id> spec-approval "<resolution>" --decision approve
#
# WF_ALLOW_UNGATED=1 for the reconcile case, which is real: wf-attend's own
# rules cover a row whose gate has been settled in substance elsewhere and
# needs closing rather than asking. That is a human's call, and typing the
# override is how it is recorded as one.
if [ "$from_state" = "draft" ] && [ "$to_state" = "ready" ] && [ "${WF_ALLOW_UNGATED:-}" != "1" ]; then
  GATE_OPEN=false
  GATE_ANSWERED=false
  eval "$("$SELF_DIR/wf-gate-status.sh" "$plan_id" spec-approval 2>/dev/null || true)"
  if [ "${GATE_OPEN:-false}" = "true" ] && [ "${GATE_ANSWERED:-false}" != "true" ]; then
    echo "Error: $plan_id has an OPEN, unanswered spec-approval gate — refusing 'draft' -> 'ready'." >&2
    echo "       That transition is the gate's own question. Writing it here answers for the" >&2
    echo "       human and leaves their gate standing as the last thing holding dispatch back" >&2
    echo "       (client-b WFI-012). A passing review is not an approval; they ask different" >&2
    echo "       questions." >&2
    # wf-gate-status.sh reads GATE_QUESTION off the RESOLVED record, and this
    # gate has none by definition. The open file is where the question still
    # lives, and replaying it verbatim is the whole point (WFI-180/181/182).
    open_q=$(wf_gate_field "$(wf_gate_file "$plan_id" || true)" GATE_QUESTION 2>/dev/null || true)
    [ -n "$open_q" ] && echo "       Asked: $open_q" >&2
    echo "       Answer it, then run this again:" >&2
    echo "         wf-gate-close.sh $plan_id spec-approval \"<resolution>\" --decision approve" >&2
    echo "       Nothing was changed. WF_ALLOW_UNGATED=1 overrides (reconcile only)." >&2
    exit 1
  fi
fi

# --- Guard: a human test that nobody performed ---------------------------
#
# `testing -> complete` is the transition that asserts the human criteria were
# satisfied. client-d's WFI-009: PLN-004, PLN-005 and PLN-006 all reached
# `complete` unattended within minutes of their spec-approval gates closing. No
# manual-test gate was ever opened for any of them — GATE_OPEN=false,
# GATE_ANSWERED=false, basis none, for all three. All 9 human test criteria
# were still unchecked, including PLN-006s (eyes:blocking) "the parked report
# makes it obvious what diverged". Two of the completing commits say so in
# their subjects: "human test passed — complete", changing only REGISTRY.md and
# ticking no criterion. A human was at an attended terminal throughout and
# performed no acceptance testing.
#
# Nothing reached production — origin/main had not moved in four days — but the
# plans were `complete` on develop and origin/release, and each plan own verify
# record had explicitly left those criteria open "for /wf-test".
#
# So the assertion is checked where it is made. An unresolved eyes:blocking
# criterion is the one kind nothing may dismiss: somebody judged it as needing
# eyes AND as blocking release without them (WFI-129). Three things can settle
# it, and one of them must have happened:
#
#   the checkbox    ticked in plan.md — passed, deferred, or filed as cosmetic
#   the record      a PASS in test-progress.md, by any run on any build. The
#                   question here is weaker than the gate question: not "is
#                   this build judged" but "did anyone ever execute this",
#                   which is what these three plans could not answer.
#   the gate        an answered manual-test gate. A human was asked and replied.
#
# Deliberately NOT wf-manual-gate.sh, though that script answers a neighbouring
# question well: it gates when it cannot read the plan diff, and by the time a
# plan completes its worktree is usually gone — so every honest completion
# would refuse. This reads plan.md and test-progress.md, both of which are on
# develop and outlive the branch.
#
# WF_ALLOW_UNTESTED=1 for a plan whose criteria were satisfied somewhere this
# cannot see. Like every other override here it is for the exception, and it
# leaves a record: the caller had to type it.
if [ "$from_state" = "testing" ] && [ "$to_state" = "complete" ] \
   && [ "${WF_ALLOW_UNTESTED:-}" != "1" ]; then
  mt_slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
  mt_dir="plans/${plan_id}-${mt_slug}"
  if [ -f "$mt_dir/plan.md" ]; then
    mt_resolved=$(mktemp "${TMPDIR:-/tmp}/wf-complete-guard.XXXXXX")
    wf_test_progress_passes "$mt_dir/test-progress.md" > "$mt_resolved"
    MANUAL_OPEN_BLOCKING=0
    eval "$("$SELF_DIR/wf-manual-lint.sh" "$plan_id" --counts --resolved "$mt_resolved" 2>/dev/null || true)"
    rm -f "$mt_resolved"
    if [ "${MANUAL_OPEN_BLOCKING:-0}" -gt 0 ]; then
      GATE_ANSWERED=false
      eval "$("$SELF_DIR/wf-gate-status.sh" "$plan_id" manual-test 2>/dev/null || true)"
      if [ "${GATE_ANSWERED:-false}" != "true" ]; then
        echo "Error: refusing $plan_id 'testing' -> 'complete' — ${MANUAL_OPEN_BLOCKING} eyes:blocking" >&2
        echo "       criterion(s) are unchecked in plan.md, no PASS for them in test-progress.md," >&2
        echo "       and no answered manual-test gate. Nothing says a human ever saw them." >&2
        echo "       An eyes:blocking criterion blocks release without eyes by definition; a" >&2
        echo "       commit saying 'human test passed' does not make one true (client-d WFI-009)." >&2
        echo "       Run /wf-test, or record the result where it can be read:" >&2
        # --open, not the bare lint. The default mode grades WORDING and is
        # silent about open criteria, so the diagnostic this refusal named
        # exited 0 while the refusal stood — client-b WFI-033 lost a
        # diagnosis to that, on a test-progress.md row holding a paraphrase
        # of the criterion rather than plan.md wording. --open shares this
        # guard parser, this normalizer and this --resolved set, and reports
        # a near-miss as a near-miss.
        echo "         wf-manual-lint.sh $plan_id --open      # which criteria are open, and why" >&2
        echo "         wf-defer-criterion.sh $plan_id …      # if it cannot be tested yet" >&2
        echo "       Nothing was changed. WF_ALLOW_UNTESTED=1 overrides." >&2
        exit 1
      fi
    fi
  fi
fi

# --- Guard: `complete` means the work is actually on an integration branch ---
#
# client-a's WFI-165: PLN-103 reached `complete` and its bug was closed with
# feature/PLN-103-… merged nowhere. develop, release and main all lacked the
# fix outright; a full release/deploy cycle ran green on 1490 tests and shipped
# to production without the change the plan and the closed bug both claimed.
# It surfaced only because a human spot-checked main against the outbound
# message.
#
# Two routes reach it. wf-test's PR step compared `release..$BRANCH` against a
# ref that did not resolve, read the empty output as "already merged", and
# skipped the PR (fixed there too). wf-deploy step 8 then says "for each plan
# that was on the release branch, verify state is complete. If not: …" and a
# plan that was never on it takes the same line.
#
# The registry is where both routes meet, so the check lives here: a plan whose
# branch still exists and is an ancestor of nothing does not become `complete`.
# A branch that is GONE is accepted — `git branch -d` refuses to delete an
# unmerged branch, so its absence is evidence, and wf-deploy legitimately runs
# long after wf-test removed it.
#
# WF_ALLOW_UNMERGED=1 for the genuine exceptions: work that landed under
# another branch name, or a plan completed by hand. To drop a plan whose work
# will never land, use wf-abandon.sh — that is what `abandoned` is for.
#
# The branch check above only fires when the row HAS a branch. It skipped one
# entirely for client-d's WFI-003: an unattended deploy worker ran this on a
# PLN-001 whose branch column read `—` because it was a never-implemented
# `draft` — plan.md had reached the release branch on its own through a
# planning-only commit (WFI-001), and step 9's "for each plan that was on the
# release branch, verify state is complete" caught it. There is no branch to
# check for merge-ancestry on a plan nothing ever built, so the fix is
# upstream of that check: every documented caller reaches `complete` from
# `testing`, and no other transition legitimately does, so require it here
# too — an empty branch column can no longer read as "already merged
# elsewhere" for a plan that was never on a branch at all.
if [ "$to_state" = "complete" ] && [ "$from_state" != "testing" ] && [ "${WF_ALLOW_UNMERGED:-}" != "1" ]; then
  echo "Error: refusing $plan_id '$from_state' -> 'complete' — complete is only ever reached" >&2
  echo "       from 'testing' (WFI-003). A draft/ready/active plan has no shipped work to" >&2
  echo "       close over." >&2
  echo "       Nothing was changed. WF_ALLOW_UNMERGED=1 overrides for a plan completed by hand." >&2
  exit 1
fi

if [ "$to_state" = "complete" ] && [ "${WF_ALLOW_UNMERGED:-}" != "1" ]; then
  row_branch=$(wf_registry_field "$plan_id" branch "$REGISTRY")
  case "$row_branch" in ""|"—"|"-"|"–") row_branch="" ;; esac
  if [ -n "$row_branch" ] && git rev-parse --verify --quiet "$row_branch" >/dev/null 2>&1; then
    merged=false
    checked=""
    for _t in release origin/release main origin/main develop origin/develop; do
      git rev-parse --verify --quiet "$_t" >/dev/null 2>&1 || continue
      checked="$checked $_t"
      if git merge-base --is-ancestor "$row_branch" "$_t" 2>/dev/null; then merged=true; break; fi
    done
    if [ -n "$checked" ] && [ "$merged" = false ]; then
      echo "Error: $plan_id's branch '$row_branch' is merged into none of:$checked" >&2
      echo "       Refusing to mark it 'complete' — that would close the plan, close its" >&2
      echo "       bug, and ship a release claiming work no branch carries (WFI-165)." >&2
      echo "       Merge it first (wf-test's PR to release, or the develop merge), then" >&2
      echo "       re-run this transition. Nothing was changed." >&2
      echo "       WF_ALLOW_UNMERGED=1 overrides; wf-abandon.sh is for work that never lands." >&2
      exit 1
    fi
  fi
fi

# Rewrite the row by column index rather than by regex surgery.
#   | ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
#     $2    $3     $4       $5        $6       $7      $8    $9    $10
# awk into a tempfile — `sed -i ''` is macOS-only and breaks anywhere else.
awk -F'|' -v OFS='|' \
    -v id="$plan_id" -v to="$to_state" -v br="$branch" -v today="$today" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) == id {
    $4 = " " to " "
    if (br == "-")      $6 = " — "
    else if (br != "")  $6 = " " br " "
    $7 = " " today " "
  }
  { print }
' "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

# Verify the update worked
if grep -q "^| $plan_id |.*| $to_state |" "$REGISTRY"; then
  echo "$plan_id: $from_state → $to_state"
else
  echo "Error: update failed for $plan_id" >&2
  exit 1
fi

# Slug doesn't change in a transition, and both the auto-claim below and the
# --note handling further down need it — read the just-rewritten row once
# and reuse it, rather than two separate greps of the same line.
slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")

# Auto-claim when entering active state
if [ "$to_state" = "active" ]; then
  claim_dir="plans/${plan_id}-${slug}"
  if [ -d "$claim_dir" ]; then
    wf_claim_write "$claim_dir"
  fi
fi

# --- The note, written under the same lock as the row it explains ---
#
# Before the staging below, so the note and the transition are one commit. A
# note committed afterwards is a second commit that a concurrent worker can
# interleave with, which is the whole class of problem this script's lock
# exists to close.
if [ -n "$note" ]; then
  note_dir="plans/${plan_id}-${slug}"
  if [ -n "$slug" ] && [ -d "$note_dir" ]; then
    note_file="$note_dir/progress.md"
    [ -f "$note_file" ] || printf '# Progress — %s\n' "$plan_id" > "$note_file"
    grep -q '^## Notes' "$note_file" 2>/dev/null || printf '\n## Notes\n' >> "$note_file"
    printf -- '- **%s — %s → %s:** %s\n' "$today" "$from_state" "$to_state" \
      "$(printf '%s' "$note" | tr '\n' ' ')" >> "$note_file"
    add_files+=("$note_file")
    git add "$note_file" 2>/dev/null || true
  else
    echo "wf-registry-update: --note given but $plan_id has no plan directory — the note was not recorded" >&2
    echo "  The note: $note" >&2
  fi
fi

# --- Stage the transition, always ---
#
# REGISTRY.md is staged here, not by the caller, and whether or not --commit
# was passed. It is tracked as of v3.2.0; before that it was gitignored, so
# every skill's post-transition `git add <plan files> && git commit` names only
# plan files and none of them names the registry.
#
# This used to add: "`git commit -m` commits the whole index, so any later
# commit in the same flow carries the transition." That was true, and it was
# the wrong thing to rely on. On develop the index is SHARED — spec,
# consistency and test workers run concurrently in one working directory — so
# "any later commit" means any worker's commit. client-a's PLN-020 had its
# draft→ready transition carried off inside a commit about filing an unrelated
# workflow issue, leaving `git log --grep PLN-020` empty for a plan that had
# been reviewed and approved (WFI-049).
#
# So the transition is staged for the CALLER to name in its own pathspec, and
# no longer travels on whatever commit happens next. Skills commit through
# wf-commit.sh and list `plans/REGISTRY.md` among their paths.
git add "$REGISTRY" 2>/dev/null || true

# --- Atomic commit (still under the lock) ---
#
# Pathspec-scoped via wf-commit.sh: this commit carries the transition and the
# findings that justify it, and nothing a concurrent worker left staged.
if [ -n "$commit_msg" ]; then
  "$SELF_DIR/wf-commit.sh" "$commit_msg" --allow-empty \
    --add "$REGISTRY" "${add_files[@]+"${add_files[@]}"}"
elif ! $no_commit; then
  # No message from the caller: commit the row on its own anyway. A failure
  # here is worth saying out loud but is not the caller's fault — the write it
  # asked for landed, and it is staged for whatever commits next.
  if ! "$SELF_DIR/wf-commit.sh" "registry($plan_id): $from_state → $to_state" \
        --add "$REGISTRY" "${add_files[@]+"${add_files[@]}"}"; then
    echo "wf-registry-update: the transition is staged but could not be committed — commit plans/REGISTRY.md before another worker does" >&2
  fi
fi
