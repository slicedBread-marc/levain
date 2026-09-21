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

# ── An unfinished release is still a release ─────────────────────────────
#
# Commits on local `release` that origin/release has never seen mean a
# /wf-release run merged and then did not push. That is not a finished state in
# either direction: the suite may have passed and nobody acted on it, or it
# failed and nobody rolled the merge back.
#
# Nothing offered to fix it. RELEASE candidacy needed develop to be AHEAD of
# release, which after the merge it is not, and wf-list-deploy.sh refuses an
# unpushed release outright — correctly, since it cannot tell a green batch
# nobody pushed from a red one. So the pipeline had no candidate at all.
#
# client-a WFI-266: two RELEASE workers in one morning ran the 22-minute
# suite, announced a wait, and exited without pushing. The second one's suite
# PASSED, 3341 of 3342 with 0 failures, and local release sat 4 commits ahead
# of origin/release with DEPLOY off the candidate list until a human read the
# refs by hand.
#
# Offered FIRST, and before the work filters below: an unpushed merge is
# unfinished business whatever the range now looks like. /wf-release fetches
# and re-verifies on entry (WFI-024, WFI-027, WFI-258) and will either push the
# batch or roll it back, and wf-suite-receipts.sh --for release tells it which
# without spending the suite again.
if git rev-parse --verify --quiet origin/release >/dev/null 2>&1; then
  if [ -n "$(git rev-list origin/release..release -1 2>/dev/null)" ]; then
    echo "RELEASE"
    exit 0
  fi
fi

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
