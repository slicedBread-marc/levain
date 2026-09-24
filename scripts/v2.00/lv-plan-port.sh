#!/usr/bin/env bash
# lv-plan-port.sh <plan-folder-name>
# Given a plan folder like PLN-004-deployment-date-footer, outputs:
#   export PLAN_ID=4
#   export FEATURE_PORT=8104
#   export COMPOSE_PROJECT_NAME={{project_slug}}-pln004
# Source this or eval its output to set variables in the calling shell.
#
# The `export` is load-bearing, not decoration. The primary consumer of these
# variables is the post-commit hook `.claude/on-implement-commit.sh`, which git
# runs as a CHILD PROCESS of `git commit` — and a child inherits the
# environment, not the caller's plain shell variables. Emitted bare, the eval
# appeared to work and the hook silently fell through to docker-compose.yml's
# literal defaults, deploying every plan under the FIRST plan's project name
# and port. client-a built PLN-003 and PLN-004 as `pln001` on 8101 four
# separate times before the cause was found (WFI-039/041/043).
#
# {{project_slug}} is baked in by install.sh at deploy time from
# claude-workflow.yml. No runtime resolution.

set -euo pipefail

plan_folder="${1:-}"
if [ -z "$plan_folder" ]; then
  echo "Usage: $0 <plan-folder-name>" >&2
  exit 1
fi

plan_id_raw=$(echo "$plan_folder" | grep -oE '[A-Z]{1,5}-[0-9]+' | head -1 | sed 's/.*-//')
plan_id=$((10#$plan_id_raw))  # strip leading zeros for arithmetic
plan_id_padded=$(printf '%03d' "$plan_id")

echo "export PLAN_ID=$plan_id"
echo "export FEATURE_PORT=$((8100 + plan_id))"
echo "export COMPOSE_PROJECT_NAME={{project_slug}}-pln${plan_id_padded}"
