#!/usr/bin/env bash
# wf-list-implementable.sh
# Outputs plans available for /wf-implement by reading REGISTRY.md.
#
# Format per line: <type>\t<plan-name>\t<goal>\t<priority>
#   type = "new"        — state: ready, no existing worktree
#   type = "resume"     — has a worktree (state active, or ready after a
#                         replan), no unchecked findings
#   type = "fix"        — has a worktree, has unchecked findings
#   type = "processing" — state: active, claimed by another session (< 2h old claim file)
#   type = "blocked"    — deps not all complete (appends blocking plan IDs)
#   type = "gated"      — a gate is open on it; a human owes an answer first
#   priority = "urgent" or "—" (normal)
#
# Urgent items are output first. Exit 0 if any found, exit 1 if none.
#
# `gated` exists because eligibility was only half-computed here. The
# dispatcher checked gates itself before spawning, so this script — documented
# as the single source of implementable truth — happily listed a plan with an
# unanswered gate as an available `new`. client-a's WFI-063: an implementer
# landed on PLN-019 while an ESCALATED consistency gate on it was open, found
# nothing in the worklist saying so, and had to discover the gate by reading
# .claude/orchestrator/gates/ by hand. Whoever asks "what can I build?" — human,
# skill or daemon — gets the same answer now.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

# The registry, read ONCE. Everything below that used to re-grep it per row or
# per dependency reads these instead: on a 70-plan project the old shape cost a
# full file scan per plan plus one per declared dep, on a script that runs on
# every /wf-status, every board render and every daemon tick.
rows=$(wf_registry_rows "$REGISTRY")
# Dep states come from wf_state_of, which builds the same "<id>=<state>" map
# once per process and memoizes it — plus the PLN-alias fallback the local copy
# that used to live here did not have.

# Branches that already have a worktree checked out. Read once — `git worktree
# list` is cheap but this loop runs per plan.
existing_worktrees=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^branch /{ sub(/^branch refs\/heads\//, ""); print }' || true)

# has_worktree <registry-branch> <plan-name>
#
# THE REGISTRY'S BRANCH COLUMN IS NOT THE ONLY EVIDENCE, AND IT IS THE LEAST
# RELIABLE
#
# This asked the Branch column and nothing else, so `—` meant "no worktree" —
# and a `—` in that column is a bookkeeping fact, not a statement about the
# filesystem. client-a reported it four times in one day (WFI-219, WFI-220,
# WFI-221, WFI-224): PLN-224 with 7 implementation commits on a live branch,
# PLN-191 with all 11 steps done, PLN-248 with 5 — every one of them classified
# `new`, because a trip through `verify → draft → ready` for a replan had left
# the column empty. The implementer then ran Phase 1 and `git worktree add`
# failed with "already exists", which opened a gate a human had to answer to
# say "yes, the work you can see is the work you should use".
#
# The comment this function serves says it plainly — "anything with a live
# worktree is a resume or a fix, whatever the registry says" — so ask the
# worktrees. The branch a plan's worktree is on is `feature/<plan-name>` by
# construction: wf-implement's Phase 1 creates it that way and nothing renames
# it. That name is derivable from the row's own ID and slug, so it holds when
# the column is empty, and it is checked ALONGSIDE the column rather than
# instead of it — a plan whose column names some other live branch is still a
# resume.
has_worktree() {
  local col="$1" plan_name="${2:-}"
  if [ -n "$col" ] && [ "$col" != "—" ]; then
    printf '%s\n' "$existing_worktrees" | grep -qx "$col" && return 0
  fi
  [ -n "$plan_name" ] || return 1
  printf '%s\n' "$existing_worktrees" | grep -qx "feature/$plan_name"
}

urgent_lines=()
normal_lines=()
processing_lines=()
blocked_lines=()
gated_lines=()

# Open gates, read once: "<id>\t<gate>\t..." per record.
open_gates=$("$SELF_DIR/wf-list-gates.sh" 2>/dev/null || true)
gate_on() {
  printf '%s\n' "$open_gates" | awk -F'\t' -v id="$1" '$1 == id { print $2; exit }'
}

while IFS=$'\037' read -r id slug state priority branch _updated _wf _tags deps; do
  # Skip malformed or blank lines
  [ -n "$id" ] && [ -n "$state" ] || continue
  plan_dir="plans/${id}-${slug}"

  [ "$state" = "ready" ] || [ "$state" = "active" ] || continue
  [ -d "$plan_dir" ] || continue

  goal=$(wf_goal_text "$plan_dir/plan.md")
  plan_name="${id}-${slug}"

  # A gate outranks every other reason: nothing about this plan is settled
  # until a human answers, so it is not implementable in any of the shapes below.
  gate_name=$(gate_on "$id")
  if [ -n "$gate_name" ]; then
    gated_lines+=("$(printf "gated\t%s\t%s\t%s\t%s" "$plan_name" "$goal" "$priority" "$gate_name")")
    found=1
    continue
  fi

  # Deps came off this row's own Deps column, above.
  blocking=$(wf_blocking_deps "$deps" "$REGISTRY" 2>/dev/null) && {
    blocked_lines+=("$(printf "blocked\t%s\t%s\t%s\t%s" "$plan_name" "$goal" "$priority" "$blocking")")
    found=1
    continue
  }

  # `new` is defined as "ready AND no existing worktree", but the type used to
  # be read off the state alone. A plan sent back to `ready` for a replan keeps
  # its branch and worktree, so it came back as `new` — and the implementer,
  # following the type, would try to create a branch and worktree that already
  # exist. Anything with a live worktree is a resume or a fix, whatever the
  # registry says.
  effective_state="$state"
  if [ "$state" = "ready" ] && has_worktree "$branch" "$plan_name"; then
    effective_state="active"
    # Say so, once, on stderr. A row whose Branch column is empty while a
    # worktree is live is a registry that disagrees with the filesystem, and
    # the four reports behind has_worktree all began with somebody unable to
    # see that. This is the classifier, not a repair tool — wf-registry-audit.sh
    # is where a fix belongs — so it names the drift and carries on.
    if [ -z "$branch" ] || [ "$branch" = "—" ]; then
      echo "note: $plan_name is 'ready' with a live worktree on feature/$plan_name," >&2
      echo "      but its REGISTRY Branch column is empty. Classified as a resume/fix" >&2
      echo "      from the worktree (WFI-219/224). The column wants backfilling." >&2
    fi
  fi

  if [ "$effective_state" = "ready" ]; then
    line=$(printf "new\t%s\t%s\t%s" "$plan_name" "$goal" "$priority")
    if [ "$priority" = "urgent" ]; then urgent_lines+=("$line"); else normal_lines+=("$line"); fi
    found=1
  elif [ "$effective_state" = "active" ]; then
    # A claim held by this caller's own dispatch describes the asker, not a
    # rival. Classifying it as "processing" told an explicitly dispatched
    # implementer to exit 0 and stranded a plan mid-implementation (WFI-076).
    if wf_claim_held "$plan_name" && ! wf_claim_mine "$WF_CLAIM_HELD_DIR"; then
      claim_age_min=$(( WF_CLAIM_AGE / 60 ))
      processing_lines+=("$(printf "processing\t%s\t%s\t%s\t%s" "$plan_name" "$goal" "$priority" "${claim_age_min}m ago")")
      found=1
      continue
    fi
    findings="$plan_dir/findings.md"
    if [ -f "$findings" ] && grep -q "^\- \[ \]" "$findings" 2>/dev/null; then
      line=$(printf "fix\t%s\t%s\t%s" "$plan_name" "$goal" "$priority")
    else
      line=$(printf "resume\t%s\t%s\t%s" "$plan_name" "$goal" "$priority")
    fi
    if [ "$priority" = "urgent" ]; then urgent_lines+=("$line"); else normal_lines+=("$line"); fi
    found=1
  fi
done <<< "$rows"

# Output urgent items first, then normal, then processing, then blocked
for line in "${urgent_lines[@]+"${urgent_lines[@]}"}"; do printf "%s\n" "$line"; done
for line in "${normal_lines[@]+"${normal_lines[@]}"}"; do printf "%s\n" "$line"; done
for line in "${processing_lines[@]+"${processing_lines[@]}"}"; do printf "%s\n" "$line"; done
for line in "${blocked_lines[@]+"${blocked_lines[@]}"}"; do printf "%s\n" "$line"; done
for line in "${gated_lines[@]+"${gated_lines[@]}"}"; do printf "%s\n" "$line"; done

exit $((1 - found))
