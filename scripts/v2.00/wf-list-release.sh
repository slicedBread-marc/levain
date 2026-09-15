#!/usr/bin/env bash
# wf-list-release.sh — eligibility check for the `release` role (docs/eligibility.md).
#
# Prints RELEASE (and exits 0) iff the local `release` branch exists and
# develop has at least one commit it doesn't. Prints nothing (exits 1)
# otherwise — including when `release` doesn't exist yet, which is left to a
# human's first manual /wf-release: bootstrapping a branch that doesn't exist
# is not a promotion, and is rare enough not to be worth automating.
#
# Local-ref only, deliberately cheap — this is a candidacy check for the
# dispatcher, not a source of truth. /wf-release itself fetches and
# re-verifies before doing anything (WFI-024, WFI-027).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

cd "$(wf_develop_root)"

git rev-parse --verify --quiet release >/dev/null 2>&1 || exit 1

if [ -n "$(git rev-list release..develop -1 2>/dev/null)" ]; then
  echo "RELEASE"
  exit 0
fi
exit 1
