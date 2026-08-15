#!/usr/bin/env bash
# wf-list-drafts.sh — plans in draft state from REGISTRY.md
# Format: <plan-name>\t<goal>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state _rest; do
  [ "$state" = "draft" ] || continue

  plan_dir="plans/${id}-${slug}"
  goal=$(wf_goal_text "$plan_dir/plan.md")
  printf "%s\t%s\n" "${id}-${slug}" "$goal"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
