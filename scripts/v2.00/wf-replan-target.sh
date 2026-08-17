#!/usr/bin/env bash
# wf-replan-target.sh <plan-id> [--apply]
#
# Resolves the state a replanned plan should return to, and optionally writes
# it.
#
#   no worktree   → ready    the builder runs Phase 1 and builds it fresh
#   live worktree → active   the builder resumes its FIX CYCLE
#   …and nothing  → testing  the bounce is answered; hand it back to the tester
#
# WHY THIS IS NOT ALWAYS `ready`
#
# wf-implement's exit runs `wf-registry-update.sh <id> active verify`. That
# from_state guard is deliberate — it is what stops two workers racing the same
# row — but it means the state a replan lands in has to match the exit contract
# of the path the builder will actually take.
#
# A plan sent back to `draft` for a replan keeps its branch and worktree. The
# dispatcher already knows this: wf-list-implementable.sh reports ready+worktree
# as `resume`, not `new`. Writing `ready` anyway put the plan one state below
# where its own builder's exit expected it, so the exit silently no-opped: the
# work was done and committed, the registry still said `ready`, and wf-verify
# then refused to run because it could not match `verify` either. Nothing
# errored loudly; the plan simply stopped moving with completed work on the
# branch.
#
# THE THIRD ANSWER: A BOUNCE WITH NOTHING TO BUILD
#
# A human test files a behavior finding, the plan goes back to `draft`, and the
# replan concludes the finding does not reproduce — the tester was standing in
# the wrong worktree, the criterion was misread, the bug was somebody else's.
# There is now no builder work outstanding, and neither of the two answers
# above fits: `active` dispatches a builder onto an empty work list and re-runs
# a full scoped verify against a tip that already passed it clean. client-a's
# WFI-096 parked at a `needs-input` gate rather than guess, and that gate then
# blocked eight dependent plans until a human authorised `draft → testing` by
# hand — an edge the state machine did not define.
#
# It is defined here, and narrowly. All four must hold:
#   - a live worktree (there is something built to hand back);
#   - the newest findings section is a `## Human Test` one (the bounce came
#     from the tester, not from verify — a verify bounce has code to answer);
#   - every finding in the file is checked off (nothing is outstanding);
#   - progress.md's `## Steps` checklist is complete, or absent.
# Anything less falls through to the ready/active rules, unchanged.
#
# stdout: the target state.  With --apply, also performs the transition.
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
apply=false
[ "${2:-}" = "--apply" ] && apply=true

plan_id=$(printf '%s' "$raw_id" | grep -oE '^PLN-[0-9]+' || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <PLN-NNN> [--apply]" >&2; exit 1; }
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

row=$(grep "^| $plan_id |" "$REGISTRY" | head -1 || true)
[ -n "$row" ] || { echo "Error: $plan_id has no registry row" >&2; exit 1; }

state=$(printf '%s' "$row" | awk -F'|' '{print $4}' | xargs)
slug=$(printf '%s' "$row" | awk -F'|' '{print $3}' | xargs)
branch=$(printf '%s' "$row" | awk -F'|' '{print $6}' | xargs)

target="ready"
if [ -n "$branch" ] && [ "$branch" != "—" ]; then
  if git worktree list --porcelain 2>/dev/null \
     | awk '/^branch /{ sub(/^branch refs\/heads\//, ""); print }' \
     | grep -qx "$branch"; then
    target="active"
  fi
fi

# The bounce-with-nothing-to-build case. Only ever narrows `active` — a plan
# with no worktree has a whole build ahead of it whatever its findings say.
if [ "$target" = "active" ]; then
  plan_dir="plans/${plan_id}-${slug}"
  findings="$plan_dir/findings.md"
  progress="$plan_dir/progress.md"
  if [ -f "$findings" ] \
     && ! grep -q '^- \[ \]' "$findings" \
     && [ "$(grep -E '^## (Human Test|Verify|Implement|Consistency)' "$findings" \
             | tail -1 | grep -c '^## Human Test')" = "1" ]; then
    steps_open=0
    if [ -f "$progress" ]; then
      steps_open=$(awk '
        /^## Steps/ { inside = 1; next }
        /^## /      { inside = 0 }
        inside && /^- \[ \]/ { n++ }
        END { print n + 0 }
      ' "$progress")
    fi
    [ "$steps_open" = "0" ] && target="testing"
  fi
fi

printf '%s\n' "$target"

if $apply; then
  if [ "$state" = "$target" ]; then
    echo "$plan_id is already $target — nothing to do" >&2
    exit 0
  fi

  # ── A gate-tagged plan does not leave draft on a stale approval ─────────
  #
  # wf-spec's new-plan exit states the rule plainly: "GATE_STALE=true -> the
  # plan changed after the approval. Gate again." The Replanning path had no
  # such check anywhere — its only gate is wf-goal-delta.sh, which asks whether
  # scope SHRANK — and this script is what it calls to move the plan.
  #
  # client-a's PLN-110 (WFI-178): tagged `contract`, the project's sole
  # gateTag. A replan widened Step 10 from 2 documents to 10 and added a test,
  # then reached here and was transitioned draft -> ready and committed.
  # Immediately afterwards wf-gate-status.sh reported GATE_ANSWERED=false,
  # GATE_STALE=true — so a plan whose approved scope had materially widened sat
  # `ready` and dispatchable, and the correction meant reverting a transition a
  # script had already committed, which is exactly the judgement call the
  # unattended rules exist to avoid.
  #
  # wf-registry-update.sh's own guard could not catch it: it refuses
  # draft -> ready without a review OF RECORD, and a fresh review of record
  # existed. The review says the plan is sound. The gate asks whether a human
  # accepts what it now promises. They are different questions.
  #
  # Refusal rather than silent gating: this script does not know the question
  # text, and a gate opened with a machine-written one is how a human ends up
  # answering something they were never asked (WFI-182). The caller opens it.
  # Self-clearing — once the human's answer is recorded the check passes.
  if [ "$target" = "ready" ] || [ "$target" = "active" ]; then
    tags=$(printf '%s' "$row" | awk -F'|' '{print $9}' | xargs || true)
    gating=$("$SELF_DIR/wf-list-tags.sh" --gating 2>/dev/null || true)
    hit=""
    if [ -n "$gating" ] && [ -n "$tags" ] && [ "$tags" != "—" ]; then
      for t in $(printf '%s' "$tags" | tr ',' ' '); do
        printf '%s\n' "$gating" | grep -qx "$t" && { hit="$t"; break; }
      done
    fi
    if [ -n "$hit" ]; then
      eval "$("$SELF_DIR/wf-gate-status.sh" "$plan_id" spec-approval 2>/dev/null || true)"
      if [ "${GATE_ANSWERED:-false}" != "true" ] || [ "${GATE_STALE:-false}" = "true" ]; then
        why="unanswered"
        [ "${GATE_STALE:-false}" = "true" ] && why="stale — the plan changed after it"
        echo "Error: $plan_id carries the gating tag '$hit' and its spec-approval is $why." >&2
        echo "  Not transitioning $state -> $target. The plan changed after the approval, so the" >&2
        echo "  approval is for a document that no longer says what it said (WFI-178)." >&2
        echo "  Open spec-approval with the amended scope in the question, then run this again:" >&2
        echo "    wf-gate-open.sh $plan_id spec-approval \"<what changed> — approve?\" --skill wf-spec" >&2
        exit 2
      fi
    fi
  fi

  "$SELF_DIR/wf-registry-update.sh" "$plan_id" "$state" "$target"
fi
