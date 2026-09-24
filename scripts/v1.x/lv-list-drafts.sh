#!/usr/bin/env bash
# lv-list-drafts.sh — plans in draft state from REGISTRY.md
# Format: <plan-name>\t<goal>
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

REGISTRY="plans/REGISTRY.md"
found=0

while IFS='|' read -r _ id slug state _rest; do
  id=$(echo "$id" | xargs); slug=$(echo "$slug" | xargs); state=$(echo "$state" | xargs)
  [ "$state" = "draft" ] || continue

  plan_dir="plans/${id}-${slug}"
  goal=$(awk '/^## Goal([ \t]|$)/{g=1;next} g&&/^#/{exit} g&&NF{sub(/^[[:space:]]+/,"");print;exit}' "$plan_dir/plan.md" 2>/dev/null || true)
  printf "%s\t%s\n" "${id}-${slug}" "$goal"
  found=1
done < <(grep "^|" "$REGISTRY" | tail -n +3)

exit $((1 - found))
