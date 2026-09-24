#!/usr/bin/env bash
# lv-list-rollbacks.sh — plans in rolled-back state from REGISTRY.md
# Format: <plan-name>\t<reason>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state _rest; do
  [ "$state" = "rolled-back" ] || continue

  plan_dir="plans/${id}-${slug}"
  reason=""
  if [ -f "$plan_dir/plan.md" ]; then
    reason=$(grep -i "Rolled back\|Reason:" "$plan_dir/plan.md" 2>/dev/null | tail -1 | sed 's/^[[:space:]]*//' || true)
  fi

  printf "%s\t%s\n" "${id}-${slug}" "$reason"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
