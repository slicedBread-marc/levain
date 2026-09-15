#!/usr/bin/env bash
# wf-list-verify.sh — plans in verify state from REGISTRY.md
# Format: <plan-name>\t<unchecked>\t<escalated>\t<goal>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state _rest; do
  [ "$state" = "verify" ] || continue

  plan_dir="plans/${id}-${slug}"
  plan_name="${id}-${slug}"

  unchecked=0; escalated=0
  findings="$plan_dir/findings.md"
  if [ -f "$findings" ]; then
    unchecked=$(grep -c '^\- \[ \]' "$findings" 2>/dev/null || true)
    escalated=$(wf_escalated_count "$findings")
  fi

  goal=$(wf_goal_text "$plan_dir/plan.md")

  printf "%s\t%s\t%s\t%s\n" "$plan_name" "$unchecked" "$escalated" "$goal"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
