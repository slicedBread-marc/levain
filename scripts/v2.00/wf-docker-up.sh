#!/usr/bin/env bash
# wf-docker-up.sh [plan-folder-name]
# Starts a Docker container for a feature branch plan.
# If no plan folder given, derives from current branch name.
# Sets up port, project name, builds, waits for health, and provisions the
# test account the acceptance criteria will need.
#
# Output: FEATURE_PORT, COMPOSE_PROJECT_NAME, TEST_ACCOUNT (eval-friendly)
# Exit 0 on healthy, 1 on timeout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=wf-orch-lib.sh
source "$SCRIPT_DIR/wf-orch-lib.sh"

plan_folder="${1:-}"
if [ -z "$plan_folder" ]; then
  branch=$(git branch --show-current)
  plan_folder=$(echo "$branch" | sed 's|feature/||')
fi

eval "$("$SCRIPT_DIR/wf-plan-port.sh" "$plan_folder")"

echo "FEATURE_PORT=$FEATURE_PORT"
echo "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME"

# Start the container (stderr so eval callers only get KEY=VALUE on stdout)
FEATURE_PORT=$FEATURE_PORT docker compose \
  -f docker/docker-compose.yml \
  -p "$COMPOSE_PROJECT_NAME" \
  up --build -d >&2

# Wait for health
"$SCRIPT_DIR/wf-wait-healthy.sh" >&2

# ── Test account ──────────────────────────────────────────────────────────
#
# A fresh container is empty by design, and an app worth testing usually
# refuses to invent a default login for one — correctly, since a seeded default
# password on any reachable host is a standing compromise. The consequence
# landed on the tester: client-a's WFI-072 handed a human a URL for a
# container with no account and no way to make one from the UI, and every
# criterion behind the login was unreachable. Nothing in the skill, the plan or
# this script's output mentioned it. The suspicion the reporter raised is the
# expensive part — earlier runs almost certainly recorded criteria as passed or
# skipped that nobody could have executed.
#
# So provisioning is part of bringing the app up, not a thing the tester is
# expected to reverse-engineer from Program.cs. Both keys are optional: a
# project with no login sets neither and nothing changes.
#
#   test_account_command: eval'd here with FEATURE_PORT and
#                         COMPOSE_PROJECT_NAME exported. Must be idempotent —
#                         it runs on every container start.
#   test_account_note:    one line handed to the tester, e.g.
#                         "sign in with dev@example.com / <password>"
account_cmd=$(wf_cfg test_account_command "")
account_note=$(wf_cfg test_account_note "")

if [ -n "$account_cmd" ]; then
  export FEATURE_PORT COMPOSE_PROJECT_NAME
  if eval "$account_cmd" >&2; then
    :
  else
    echo "wf-docker-up: test_account_command failed — the app is up but may have no account to sign in as" >&2
  fi
fi

wf_emit TEST_ACCOUNT "$account_note"

if [ -n "$account_note" ]; then
  echo "wf-docker-up: test account — $account_note" >&2
elif [ -n "$account_cmd" ]; then
  echo "wf-docker-up: test account provisioned (set test_account_note in claude-workflow.yml to print the credentials here)" >&2
fi
