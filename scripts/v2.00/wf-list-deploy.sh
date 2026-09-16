#!/usr/bin/env bash
# wf-list-deploy.sh — eligibility check for the `deploy` role (docs/eligibility.md).
#
# Prints DEPLOY (and exits 0) iff the local `main` branch exists and `release`
# has at least one commit it doesn't. Prints nothing (exits 1) otherwise.
#
# Why this is a safe signal: /wf-release only pushes the `release` branch
# AFTER its local E2E run passes (the push-after-test ordering fixed alongside
# this feature — see skills/wf-release/SKILL.md). So "release is ahead of main"
# means "these commits passed E2E", for both attended and unattended runs, with
# no separate marker file needed.
#
# That holds only while the local ref and the pushed one agree, which is why
# the unpushed-commit check below is part of the signal and not a nicety.
# client-b WFI-007: /wf-release fast-forwarded LOCAL release onto develop,
# E2E failed, and the run exited without resetting it. Nothing was pushed — and
# this check read the local ref, counted 30 commits, and dispatched a deploy
# worker that opened a deploy-approval gate over a batch whose suite was red.
# /wf-release now rolls that merge back (wf-release-rollback.sh), but a worker
# killed mid-run, or an older client, still leaves the ref ahead. So: commits
# on local `release` that `origin/release` has never seen are, by construction,
# commits `/wf-release` did not push — i.e. commits that did not pass. They are
# not deployable and this says so, rather than trusting one skill's exit path
# to be the only guard (coordinator WFI-002).
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

# Unpushed local commits on `release` = commits /wf-release did not push =
# commits that did not pass E2E. Only checked when the remote ref exists at
# all; a project with no `origin/release` has nothing to compare against and
# is left to the rest of the pipeline.
if git rev-parse --verify --quiet origin/release >/dev/null 2>&1; then
  [ -z "$(git rev-list origin/release..release -1 2>/dev/null)" ] || exit 1
fi

if [ -n "$(git rev-list main..release -1 2>/dev/null)" ]; then
  echo "DEPLOY"
  exit 0
fi
exit 1
