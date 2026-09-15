#!/usr/bin/env bash
# wf-list-deploy.sh — eligibility check for the `deploy` role (docs/eligibility.md).
#
# Prints DEPLOY (and exits 0) iff the local `main` branch exists and `release`
# has at least one commit it doesn't. Prints nothing (exits 1) otherwise.
#
# Why this alone is a safe signal: /wf-release only pushes the `release`
# branch AFTER its local E2E run passes (the push-after-test ordering fixed
# alongside this feature — see skills/wf-release/SKILL.md). So "release is
# ahead of main" already means "these commits passed E2E", for both attended
# and unattended runs, with no separate marker file needed.
#
# Local-ref only, deliberately cheap — this is a candidacy check for the
# dispatcher, not a source of truth. /wf-deploy itself re-verifies before
# doing anything.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

cd "$(wf_develop_root)"

git rev-parse --verify --quiet main >/dev/null 2>&1 || exit 1

if [ -n "$(git rev-list main..release -1 2>/dev/null)" ]; then
  echo "DEPLOY"
  exit 0
fi
exit 1
