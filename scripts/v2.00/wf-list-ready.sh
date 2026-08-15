#!/usr/bin/env bash
# wf-list-ready.sh — plans in ready state from REGISTRY.md
# Format: <plan-name>\t<goal>\t<priority>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state priority _rest; do
  [ "$state" = "ready" ] || continue
  plan_dir="plans/${id}-${slug}"
  goal=$(wf_goal_text "$plan_dir/plan.md")
  printf "%s\t%s\t%s\n" "${id}-${slug}" "$goal" "$priority"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
