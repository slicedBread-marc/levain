#!/usr/bin/env bash
# lv-docker-cleanup.sh
# Removes orphaned Docker containers, and native app runs, from completed plans.
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

# keep_state <compose-name> — is the plan behind {{project_slug}}-plnNNN still
# in a state that may be using its app? Sets $state; returns 0 to keep.
keep_state() {
  local num="${1#$prefix}" padded
  # Zero-pad to 3 digits for registry lookup. `10#` first: the name carries
  # the number already padded, and printf reads a leading zero as octal — so
  # pln008/pln009 were skipped forever ("invalid number") and pln010 was looked
  # up as PLN-008, tearing down a plan still in testing whenever PLN-008 was done.
  state=""
  case "$num" in ''|*[!0-9]*) return 0 ;; esac
  padded=$(printf "%03d" "$((10#$num))")
  state=$(wf_state_of "$LV_PLN-${padded}" "$REGISTRY")   # found under any plan prefix
  case "$state" in accept|testing|verify|active) return 0 ;; esac
  return 1
}

cleaned=0

# Native runs first. A project with no compose file has no `docker compose ls`
# entry, so its finished plans' servers were never reaped by anything (the
# coordinator's LVI-039: 19 of them, 11-35 days old).
for pidf in "$(wf_app_run_dir)/lv-app-$prefix"*.pid "${TMPDIR:-/tmp}/lv-app-$prefix"*.pid; do
  [ -f "$pidf" ] || continue
  name=$(basename "$pidf" .pid); name="${name#lv-app-}"
  keep_state "$name" && continue
  if out=$(wf_stop_native "$name" 2>&1); then
    echo "Cleaned up native $name (plan state: ${state:-not found})"
    cleaned=$((cleaned + 1))
  else
    printf '%s\n' "$out" >&2
  fi
done

# Get list of {{project_slug}}-pln* compose projects
projects=$(docker compose ls --format json 2>/dev/null \
  | PREFIX="$prefix" python3 -c "import os,sys,json; p=os.environ['PREFIX']; [print(x['Name']) for x in json.load(sys.stdin) if x['Name'].startswith(p)]" 2>/dev/null) || true

if [ -z "$projects" ]; then
  [ "$cleaned" -gt 0 ] && echo "Removed $cleaned orphaned app(s)" >&2
  exit 0
fi

while IFS= read -r proj; do
  keep_state "$proj" && continue

  # Plan is complete/draft/missing — tear down
  docker compose -p "$proj" down --remove-orphans -v 2>/dev/null || true
  echo "Cleaned up $proj (plan state: ${state:-not found})"
  cleaned=$((cleaned + 1))
done <<< "$projects"

[ "$cleaned" -gt 0 ] && echo "Removed $cleaned orphaned container(s)/app(s)" >&2
exit 0
