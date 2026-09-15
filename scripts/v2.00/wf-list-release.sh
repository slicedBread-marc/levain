#!/usr/bin/env bash
# wf-list-release.sh — eligibility check for the `release` role (docs/eligibility.md).
#
# Prints RELEASE (and exits 0) iff the local `release` branch exists and
# develop has at least one commit ahead of it that touches something other
# than plans/ or bugs/. Prints nothing (exits 1) otherwise — including when
# `release` doesn't exist yet, which is left to a human's first manual
# /wf-release: bootstrapping a branch that doesn't exist is not a promotion,
# and is rare enough not to be worth automating.
#
# The plans/bugs exclusion (WFI-001, client-d) exists because T2 commits
# spec drafts and review rounds straight to develop's plans/ tree, outside
# any feature branch. Without it, every one of those planning-only commits
# looked like shippable work: a plan sitting in spec review for 4 minutes
# spawned three release workers, each burning a unit of a standing autonomy
# grant and cascading into a deploy worker + deploy-approval gate over commits
# that never touched product code. Reviewing a spec is not releasing one.
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

[ -n "$(git rev-list release..develop -1 2>/dev/null)" ] || exit 1

CHANGED="$(git diff --name-only release..develop 2>/dev/null)" || exit 1
if ! printf '%s\n' "$CHANGED" | grep -qvE '^(plans|bugs)/'; then
  exit 1
fi

echo "RELEASE"
exit 0
