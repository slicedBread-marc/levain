#!/usr/bin/env bash
# lv-list-replanning.sh — plans in draft state with ESCALATED findings
# Format: <plan-name>\t<escalated_count>\t<goal>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state _rest; do
  [ "$state" = "draft" ] || continue

  plan_dir="plans/${id}-${slug}"
  findings="$plan_dir/findings.md"

  escalated=$(wf_escalated_count "$findings")
  [ "$escalated" -gt 0 ] || continue

  goal=$(wf_goal_text "$plan_dir/plan.md")
  printf "%s\t%s\t%s\n" "${id}-${slug}" "$escalated" "$goal"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
