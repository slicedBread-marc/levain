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

# Commits in range, but do any of them carry WORK? /wf-deploy's bookkeeping —
# the promote marker, the completion and back-merge commits, registry
# transitions and bug closes — lands on develop as commits `release` has never
# seen, every single deploy. /wf-release itself filters these out by subject at
# its step 3 and correctly reports "nothing to release"; this check did not,
# so the daemon dispatched a worker for that no-op again and again. Three of
# them in three minutes is what tripped client-c's attempt ceiling and
# opened a `stuck` gate asserting "release has run 3 times with no forward
# progress" — over three runs that were each right (WFI-035). Same subject list
# as skills/wf-release/SKILL.md step 3; keep the two in step.
if ! git log release..develop --format=%s 2>/dev/null \
     | grep -qvE '^(release: promote to main$|release: complete |sync: bring completed plans back to develop$|registry\(|bug\()'; then
  exit 1
fi

CHANGED="$(git diff --name-only release..develop 2>/dev/null)" || exit 1
# An EMPTY diff is not "changes outside plans/ and bugs/" — but that is how it
# read: `printf '%s\n' ""` emits one blank line, the blank line does not match
# `^(plans|bugs)/`, `grep -qv` selects it, and a range whose net diff is
# nothing reported as releasable work. An empty-marker commit (wf-commit.sh
# --allow-empty, which is how the promote marker is written) produces exactly
# that range — the other half of WFI-035.
[ -n "$CHANGED" ] || exit 1
if ! printf '%s\n' "$CHANGED" | grep -qvE '^(plans|bugs)/'; then
  exit 1
fi

echo "RELEASE"
exit 0
