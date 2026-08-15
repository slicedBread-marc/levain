#!/usr/bin/env bash
# wf-list-active.sh — plans in active state from REGISTRY.md
# Format: <plan-name>\t<branch>\t<step_progress>\t<goal>\t<priority>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state priority branch _rest; do
  [ "$state" = "active" ] || continue

  plan_dir="plans/${id}-${slug}"
  plan_name="${id}-${slug}"

  # Step counts come from the one definition of them — the `## Steps` list,
  # not every bracketed line in the file (see wf_step_counts).
  step_progress=""
  [ -f "$plan_dir/progress.md" ] && step_progress="Step $(wf_step_counts "$plan_dir/progress.md")"

  goal=$(wf_goal_text "$plan_dir/plan.md")

  printf "%s\t%s\t%s\t%s\t%s\n" "$plan_name" "$branch" "$step_progress" "$goal" "$priority"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
