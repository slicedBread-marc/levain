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
# "<id>=<state>" pairs, space-delimited and space-terminated, so a lookup is
# parameter expansion rather than a grep. bash 3.2 (what macOS ships) has no
# associative arrays.
state_map=" $(printf '%s\n' "$rows" | awk -F'\037' 'NF { printf "%s=%s ", $1, $3 }')"
state_of() {
  local rest="${state_map##* $1=}"
  [ "$rest" = "$state_map" ] && return 0
  printf '%s' "${rest%% *}"
}

# Branches that already have a worktree checked out. Read once — `git worktree
# list` is cheap but this loop runs per plan.
existing_worktrees=$(git worktree list --porcelain 2>/dev/null \
  | awk '/^branch /{ sub(/^branch refs\/heads\//, ""); print }' || true)

has_worktree() {
  [ -n "$1" ] && [ "$1" != "—" ] || return 1
  printf '%s\n' "$existing_worktrees" | grep -qx "$1"
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

# Helper: check if a plan's deps are all complete
check_deps_blocked() {
  local deps_raw="$1"
  [ -n "$deps_raw" ] && [ "$deps_raw" != "—" ] || return 1
  local blocking=""
  local IFS=','
  for dep_id in $deps_raw; do
    dep_id="${dep_id#"${dep_id%%[![:space:]]*}"}"   # trim, without a subprocess
    dep_id="${dep_id%"${dep_id##*[![:space:]]}"}"
    local dep_state
    dep_state=$(state_of "$dep_id")
    if [ "$dep_state" != "complete" ]; then
      # Mark an abandoned dep in the label itself: it is not late, it is gone,
      # and the plan needs replanning rather than patience (WFI-008).
      [ "$dep_state" = "abandoned" ] && dep_id="$dep_id (abandoned)"
      [ -n "$blocking" ] && blocking="$blocking,$dep_id" || blocking="$dep_id"
    fi
  done
  [ -n "$blocking" ] || return 1
  echo "$blocking"
  return 0
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
  blocking=$(check_deps_blocked "$deps" 2>/dev/null) && {
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
  if [ "$state" = "ready" ] && has_worktree "$branch"; then
    effective_state="active"
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
