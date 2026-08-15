#!/usr/bin/env bash
# wf-check-deps.sh <plan-id>
# Checks whether all dependencies for a plan are complete.
#
# Reads the Deps column ($10) from REGISTRY.md for the given plan.
# Output:
#   CLEAR                           — no deps or all deps complete
#   BLOCKED <dep1>,<dep2>           — one or more deps not complete
#
# Exit 0 always (caller checks stdout).

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
plan_id=$(echo "$raw_id" | grep -oE '^PLN-[0-9]+' || echo "$raw_id")

if [ -z "$plan_id" ]; then
  echo "Usage: $0 <plan-id>" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "CLEAR"; exit 0; }

row=$(grep "^| $plan_id |" "$REGISTRY" | head -1 || true)
[ -n "$row" ] || { echo "CLEAR"; exit 0; }

deps=$(echo "$row" | awk -F'|' '{print $10}' | xargs)
[ -n "$deps" ] && [ "$deps" != "—" ] || { echo "CLEAR"; exit 0; }

# An incomplete dependency is "not yet"; an abandoned one is "never". Reported
# identically they are not the same situation at all — waiting resolves the
# first and can only stall on the second, which is why an abandoned dep used to
# block its dependents forever with no way to clear it (WFI-008).
blocking=""
dead=""
IFS=',' read -ra dep_list <<< "$deps"
for dep_id in "${dep_list[@]}"; do
  dep_id=$(echo "$dep_id" | xargs)
  dep_state=$(grep "^| $dep_id |" "$REGISTRY" 2>/dev/null | awk -F'|' '{print $4}' | xargs || true)
  case "$dep_state" in
    complete) ;;
    abandoned) [ -n "$dead" ] && dead="$dead,$dep_id" || dead="$dep_id" ;;
    *) [ -n "$blocking" ] && blocking="$blocking,$dep_id" || blocking="$dep_id" ;;
  esac
done

if [ -n "$dead" ]; then
  echo "DEAD $dead"
  echo "wf-check-deps.sh: $dead abandoned — will never complete. Amend or drop the dependency:" >&2
  echo "  scripts/wf-exec.sh wf-set-deps.sh $plan_id <remaining deps or —>" >&2
  exit 0
fi

if [ -n "$blocking" ]; then
  echo "BLOCKED $blocking"
else
  echo "CLEAR"
fi
