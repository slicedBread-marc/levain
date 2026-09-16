#!/usr/bin/env bash
# wf-release-rollback.sh [--dry-run]
#
# Returns the local `release` branch to `origin/release` after a failed
# release — the undo for step 6 of /wf-release, run when step 7's E2E suite
# fails.
#
# WHY THIS EXISTS
#
# /wf-release merges `develop` into `release` LOCALLY, then runs the full
# suite, and pushes only if it passes. That ordering is what makes
# "release is ahead of main" mean "these commits passed E2E" — the signal
# wf-list-deploy.sh, the daemon and /wf-deploy all read as their eligibility
# to promote to production.
#
# But a failing suite only stopped the PUSH. The local merge stayed. client-b
# WFI-007: `release` was fast-forwarded onto develop, E2E failed 1/117, the run
# exited saying "release branch was NOT advanced" — false for the local ref —
# and 71 seconds later the daemon read `git rev-list --count release --not
# main` = 30 and dispatched a deploy worker, which opened a deploy-approval
# gate quoting all 30 commits as ready to promote. Only wf-guard-promote.sh's
# refusal to push `main` while a gate is open stood between that approval and a
# red production push, and that is a backstop against an approval, not against
# the false signal that manufactured the gate. coordinator WFI-002 is the same finding
# read portfolio-wide: it blocks enabling the daemon on every client holding a
# release/deploy grant.
#
# So the rollback is a script rather than a line in a skill. The skill's steps
# are not guaranteed to share a shell (see /wf-release step 9), so a pre-merge
# SHA captured in a variable at step 6 is not reliably there at step 7 — and
# it does not need to be: `/wf-release` and `/wf-deploy` are the only writers
# of `release` (docs/release-worktrees.md), step 6 pulls `origin/release`
# immediately before merging, and step 8 pushes only on success. So
# `origin/release` IS the pre-merge tip, for exactly as long as the failure
# window lasts.
#
# WHAT IT REFUSES TO DO
#
# · Nothing, if the local ref already equals `origin/release` — that is the
#   post-condition, not an error. Exit 0.
# · Anything, if the two have DIVERGED (origin/release is not an ancestor of
#   the local ref). That is not the failure this undoes, and a --hard reset
#   would discard commits nobody can name. Exit 1, saying so.
# · Anything, if the worktree has modified TRACKED files. `git reset --hard`
#   would destroy them. Untracked files (build output from the failed E2E run)
#   are left alone and do not block. Exit 1.
#
# Output goes to stdout in the shape a skill can quote back to a human:
# the branch, where it was, where it is now. Exit 0 when `release` ends at
# `origin/release`, 1 when it does not.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

dry_run=false
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    -h|--help) sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "wf-release-rollback.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

# Where is `release` checked out? Its own pinned worktree normally
# (release-branches/release), but a client that has not migrated may hold it
# in the shared checkout. Ask git rather than assume a path.
wt=""
_wt=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) _wt="${line#worktree }" ;;
    branch\ refs/heads/release) wt="$_wt" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null || true)

if [ -z "$wt" ]; then
  # Not checked out anywhere. The ref can still be reset — a bare ref update
  # touches no working tree, so there is nothing to lose and nothing to check.
  if ! git rev-parse --verify --quiet release >/dev/null; then
    echo "wf-release-rollback: no local 'release' branch — nothing to roll back"
    exit 0
  fi
  wt=""
fi

git_in() { if [ -n "$wt" ]; then git -C "$wt" "$@"; else git "$@"; fi; }

git_in fetch origin release --quiet 2>/dev/null || \
  echo "wf-release-rollback: could not fetch origin/release — using the ref as it stands locally" >&2

before=$(git_in rev-parse --verify --quiet release 2>/dev/null || true)
target=$(git_in rev-parse --verify --quiet origin/release 2>/dev/null || true)

if [ -z "$before" ]; then
  echo "wf-release-rollback: no local 'release' branch — nothing to roll back"
  exit 0
fi
if [ -z "$target" ]; then
  echo "wf-release-rollback: origin/release does not exist — refusing to guess a pre-merge tip." >&2
  echo "                     local release is at $(git_in rev-parse --short release). Nothing changed." >&2
  exit 1
fi

if [ "$before" = "$target" ]; then
  echo "release is already at origin/release ($(git_in rev-parse --short release)) — nothing to roll back"
  exit 0
fi

if ! git_in merge-base --is-ancestor "$target" "$before"; then
  echo "wf-release-rollback: local release and origin/release have DIVERGED — refusing to reset." >&2
  echo "                     local  $(git_in rev-parse --short release)" >&2
  echo "                     origin $(git_in rev-parse --short origin/release)" >&2
  echo "                     This is not the failed-merge case this undoes. Nothing changed;" >&2
  echo "                     reconcile by hand before releasing again." >&2
  exit 1
fi

if [ -n "$wt" ]; then
  dirty=$(git_in status --porcelain --ignore-submodules=dirty 2>/dev/null | grep -v '^??' || true)
  if [ -n "$dirty" ]; then
    echo "wf-release-rollback: the release worktree has modified tracked files — refusing to reset." >&2
    printf '%s\n' "$dirty" >&2
    echo "                     A --hard reset would destroy them. Nothing changed." >&2
    exit 1
  fi
fi

ahead=$(git_in rev-list --count "$target..$before")

if $dry_run; then
  echo "would reset release $(git_in rev-parse --short release) → $(git_in rev-parse --short origin/release) (dropping $ahead local commit(s))"
  exit 0
fi

if [ -n "$wt" ]; then
  git_in reset --hard --quiet "$target"
else
  git update-ref refs/heads/release "$target"
fi

after=$(git_in rev-parse --short release)
echo "release rolled back to origin/release: ${before:0:7} → $after ($ahead local commit(s) dropped, unpushed)"
wf_event release-rollback RELEASE "local release reset ${before:0:7} → $after after a failed E2E run" 2>/dev/null || true
exit 0
