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
  "$SELF_DIR/wf-registry-update.sh" "$plan_id" "$state" "$target"
fi
