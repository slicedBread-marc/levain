#!/usr/bin/env bash
# lv-build-check.sh
# Runs the project's build command to verify the code compiles.
# Used after merging release into a feature branch to catch semantically
# broken merges that git auto-resolved without conflict markers.
#
# Exit codes:
#   0 — build succeeded
#   1 — build failed

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

# Find the develop root to read claude-workflow.yml
DEVELOP_ROOT="$(wf_develop_root)"
CFG="$DEVELOP_ROOT/claude-workflow.yml"

if [ ! -f "$CFG" ]; then
  echo "Warning: claude-workflow.yml not found at $CFG — skipping build check" >&2
  exit 0
fi

BUILD_CMD=$(wf_cfg build_command)

if [ -z "$BUILD_CMD" ]; then
  echo "Warning: no build_command in claude-workflow.yml — skipping build check" >&2
  exit 0
fi

echo "Running post-merge build check: $BUILD_CMD"
if eval "$BUILD_CMD"; then
  echo "Build check passed."
  exit 0
else
  echo "Build check FAILED after release merge." >&2
  exit 1
fi
