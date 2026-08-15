#!/usr/bin/env bash
# wf-list-findings.sh — lists unchecked findings across active/verify plans
# Uses REGISTRY.md to find plans, reads findings.md for unchecked items.
set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

while IFS=$'\037' read -r id slug state _rest; do
  [ "$state" = "active" ] || [ "$state" = "verify" ] || continue

  plan_dir="plans/${id}-${slug}"
  [ -f "$plan_dir/findings.md" ] || continue

  unchecked=$(grep -c '^\- \[ \]' "$plan_dir/findings.md" 2>/dev/null || true)
  [ "$unchecked" -gt 0 ] || continue

  echo "=== ${id}-${slug} ==="
  grep '^\- \[ \]' "$plan_dir/findings.md" | head -5
done < <(wf_registry_rows "$REGISTRY")
