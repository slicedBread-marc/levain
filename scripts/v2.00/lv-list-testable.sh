#!/usr/bin/env bash
# lv-list-testable.sh
# Outputs plans eligible for human testing by reading REGISTRY.md.
# Eligible = state: testing
#
# Format per line (stdout): <plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>
# Blocked plans output with extra field: <plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>\tblocked:<deps>
# Stderr summary: TESTABLE: N, TOTAL: N
#
# Exit 0 if any testable found, exit 1 if none.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

# Read once; dep states come from wf_state_of's memoized map. See
# lv-list-implementable.sh.
rows=$(wf_registry_rows "$REGISTRY")

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
    claimed_plans+=("${id}-${slug}:${LV_CLAIM_AGE}")
    continue
  fi

  plan_name="${id}-${slug}"
  goal=$(wf_goal_text "$plan_dir/plan.md")

  worktree="feature-branches/${plan_name}"
  [ -d "$worktree" ] || worktree=""

  # Deps came off this row's own Deps column, above.
  blocking=$(wf_blocking_deps "$deps" "$REGISTRY" 2>/dev/null) || blocking=""

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
    echo "Run: scripts/lv-unclaim.sh <plan-name> to release stale claims" >&2
  fi
fi

exit $((testable > 0 ? 0 : 1))
