#!/usr/bin/env bash
# lv-plan-port.sh <plan-folder-name>
# Given a plan folder like PLN-004-deployment-date-footer, outputs:
#   export PLAN_ID=4
#   export FEATURE_PORT=8104
#   export COMPOSE_PROJECT_NAME={{project_slug}}-pln004
# Source this or eval its output to set variables in the calling shell.
#
# The `export` matters: the post-commit hook that consumes these runs as a
# child process of `git commit` and inherits the environment, not plain shell
# variables. See the v2.00 copy for the full account (WFI-039/041/043).
#
# {{project_slug}} is baked in by install.sh at deploy time from
# claude-workflow.yml. No runtime resolution.

set -euo pipefail

plan_folder="${1:-}"
if [ -z "$plan_folder" ]; then
  echo "Usage: $0 <plan-folder-name>" >&2
  exit 1
fi

plan_id_raw=$(echo "$plan_folder" | grep -oE 'PLN-[0-9]+' | sed 's/PLN-//')
plan_id=$((10#$plan_id_raw))  # strip leading zeros for arithmetic
plan_id_padded=$(printf '%03d' "$plan_id")

echo "export PLAN_ID=$plan_id"
echo "export FEATURE_PORT=$((8100 + plan_id))"
echo "export COMPOSE_PROJECT_NAME={{project_slug}}-pln${plan_id_padded}"
