#!/usr/bin/env bash
# lv-set-priority.sh <plan-id> [priority]
# Sets the Priority column for a plan in REGISTRY.md.
# priority: "urgent" (default) or "—" to clear (normal)
#
# Examples:
#   lv-set-priority.sh PLN-004 urgent
#   lv-set-priority.sh PLN-004 —
#   lv-set-priority.sh PLN-004-some-slug urgent

set -euo pipefail

# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
priority="${2:-urgent}"

# Normalize: accept both "PLN-NNN" and "PLN-NNN-slug" formats
plan_id=$(echo "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || echo "$raw_id")

if [ -z "$plan_id" ]; then
  echo "Usage: $0 <plan-id> [priority]" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

wf_lock_acquire registry

if ! grep -q "^| $plan_id |" "$REGISTRY"; then
  echo "Error: $plan_id not found in registry" >&2
  exit 1
fi

# Replace the Priority column.
wf_registry_set_field "$plan_id" priority "$priority" "$REGISTRY"

if grep -q "^| $plan_id |.*| $priority |" "$REGISTRY"; then
  wf_registry_commit "registry($plan_id): priority → $priority"
  echo "$plan_id: priority → $priority"
else
  echo "Error: update failed for $plan_id" >&2
  exit 1
fi
