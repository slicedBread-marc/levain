#!/usr/bin/env bash
# wf-list-testable.sh
# Outputs plans eligible for human testing by reading REGISTRY.md.
# Eligible = state: testing
#
# Format per line (stdout): <plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>
# Blocked plans output with extra field: <plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>\tblocked:<deps>
# Stderr summary: TESTABLE: N, TOTAL: N
#
# Exit 0 if any testable found, exit 1 if none.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

# Read once; look dep states up out of it. See wf-list-implementable.sh.
rows=$(wf_registry_rows "$REGISTRY")
state_map=" $(printf '%s\n' "$rows" | awk -F'\037' 'NF { printf "%s=%s ", $1, $3 }')"
state_of() {
  local rest="${state_map##* $1=}"
  [ "$rest" = "$state_map" ] && return 0
  printf '%s' "${rest%% *}"
}

testable=0
total=0
claimed_plans=()

while IFS=$'\037' read -r id slug state priority branch _updated _wf _tags deps; do
  [ "$state" = "testing" ] || continue
  total=$((total + 1))

  plan_dir="plans/${id}-${slug}"
  [ -d "$plan_dir" ] || continue

  # Claimed by a live session? Report it, don't offer it.
  if wf_claim_held "${id}-${slug}"; then
    claimed_plans+=("${id}-${slug}:${WF_CLAIM_AGE}")
    continue
  fi

  plan_name="${id}-${slug}"
  goal=$(wf_goal_text "$plan_dir/plan.md")

  worktree="feature-branches/${plan_name}"
  [ -d "$worktree" ] || worktree=""

  # Deps came off this row's own Deps column, above.
  blocking=""
  if [ -n "$deps" ] && [ "$deps" != "—" ]; then
    IFS=',' read -ra dep_list <<< "$deps"
    for dep_id in "${dep_list[@]}"; do
      dep_id="${dep_id#"${dep_id%%[![:space:]]*}"}"
      dep_id="${dep_id%"${dep_id##*[![:space:]]}"}"
      dep_state=$(state_of "$dep_id")
      if [ "$dep_state" != "complete" ]; then
        # See wf-list-implementable.sh: abandoned reads differently to late.
        [ "$dep_state" = "abandoned" ] && dep_id="$dep_id (abandoned)"
        [ -n "$blocking" ] && blocking="$blocking,$dep_id" || blocking="$dep_id"
      fi
    done
  fi

  if [ -n "$blocking" ]; then
    printf "%s\t%s\t%s\t%s\t%s\tblocked:%s\n" "$plan_name" "$worktree" "$branch" "$goal" "$priority" "$blocking"
  else
    printf "%s\t%s\t%s\t%s\t%s\n" "$plan_name" "$worktree" "$branch" "$goal" "$priority"
  fi
  testable=$((testable + 1))
done <<< "$rows"

cat >&2 <<EOF
TESTABLE: $testable
TOTAL: $total
EOF

if [ "${#claimed_plans[@]}" -gt 0 ]; then
  echo "CLAIMED:" >&2
  for entry in "${claimed_plans[@]}"; do
    plan="${entry%%:*}"
    age="${entry##*:}"
    mins=$(( age / 60 ))
    echo "  $plan (claimed ${mins}m ago)" >&2
  done
  if [ "$testable" -eq 0 ]; then
    echo "Run: scripts/wf-unclaim.sh <plan-name> to release stale claims" >&2
  fi
fi

exit $((testable > 0 ? 0 : 1))
