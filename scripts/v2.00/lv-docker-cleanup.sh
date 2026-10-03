#!/usr/bin/env bash
# lv-docker-cleanup.sh
# Removes orphaned Docker containers from completed plans.
# Scans for {{project_slug}}-pln* compose projects and tears down any whose
# plan is no longer in testing/verify/active state.
#
# {{project_slug}} is baked in by install.sh at deploy time.
#
# Safe to run anytime — only removes containers for finished plans.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || exit 0

prefix="{{project_slug}}-pln"

# Get list of {{project_slug}}-pln* compose projects
projects=$(docker compose ls --format json 2>/dev/null \
  | PREFIX="$prefix" python3 -c "import os,sys,json; p=os.environ['PREFIX']; [print(x['Name']) for x in json.load(sys.stdin) if x['Name'].startswith(p)]" 2>/dev/null) || true

[ -z "$projects" ] && exit 0

cleaned=0
while IFS= read -r proj; do
  # Extract plan number from project name ({{project_slug}}-pln004 → 004)
  num="${proj#$prefix}"
  # Zero-pad to 3 digits for registry lookup. `10#` first: the name carries
  # the number already padded, and printf reads a leading zero as octal — so
  # pln008/pln009 were skipped forever ("invalid number") and pln010 was looked
  # up as PLN-008, tearing down a plan still in testing whenever PLN-008 was done.
  case "$num" in ''|*[!0-9]*) continue ;; esac
  padded=$(printf "%03d" "$((10#$num))")
  plan_id="$LV_PLN-${padded}"   # wf_state_of finds it under any plan prefix

  # Check registry state
  state=$(wf_state_of "$plan_id" "$REGISTRY")

  # Keep containers for plans still in progress
  case "$state" in
    accept|testing|verify|active) continue ;;
  esac

  # Plan is complete/draft/missing — tear down
  docker compose -p "$proj" down --remove-orphans -v 2>/dev/null || true
  echo "Cleaned up $proj (plan state: ${state:-not found})"
  cleaned=$((cleaned + 1))
done <<< "$projects"

[ "$cleaned" -gt 0 ] && echo "Removed $cleaned orphaned container(s)" >&2
exit 0
