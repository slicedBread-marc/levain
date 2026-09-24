#!/usr/bin/env bash
# lv-worktree-pin.sh <branch> <path>
#
# Ensures a PERSISTENT linked worktree for <branch> exists at <path> (given
# relative to CWD, which must be the develop root — the only place
# scripts/lv-exec.sh and this script's siblings are the live, versioned
# copies) and leaves the harness refreshed inside it.
#
# Unlike feature-branches/PLN-NNN/ — created fresh per plan and discarded
# after merge — release-branches/release and release-branches/main are
# meant to live forever. /lv-release and /lv-deploy pin `release` and `main`
# here instead of borrowing the shared develop worktree the way they used to.
#
# WHY THIS EXISTS
#
# The shared main worktree — the one every terminal, the orchestrator, and
# wf_develop_root() all read plans/REGISTRY.md from — used to be checked out
# to `release` or `main` for the duration of a release or a deploy, then
# handed back. Any session standing in that directory during the window
# found itself on the wrong branch, and the registry it read was a stale
# snapshot rather than develop's own copy — the orchestrator had to pause
# dispatch entirely rather than trust it (WFI-135, WFI-157, WFI-156,
# WFI-123, WFI-124). WFI-213 is a client that had already worked around
# this by keeping `release` in its own worktree by hand; this script makes
# that the default shape instead of a special case lv-deploy had to detect.
#
# Giving `release` and `main` their own worktrees removes the borrowing
# entirely: the develop worktree never leaves develop, so there is nothing
# left to hand back and nothing for a parallel session to catch mid-move.
#
# Output: WORKTREE_PATH=<absolute path>  (eval-contract, same as
# lv-branch-check.sh — only that KEY=value line goes to stdout, everything
# else goes to stderr).
#
# Exit 0 on success. Exit 1 if the branch is already checked out somewhere
# else (most likely a stale pre-migration checkout, or a worktree at <path>
# that a human parked on the wrong branch by hand) or another git failure —
# this script never moves or deletes a checkout it did not create itself.

set -euo pipefail

branch="${1:-}"
path="${2:-}"

if [ -z "$branch" ] || [ -z "$path" ]; then
  echo "Usage: $0 <branch> <path>" >&2
  exit 1
fi

mkdir -p "$(dirname "$path")"

if git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
  # Already a worktree. Confirm it is actually on the branch it was pinned
  # to — nothing in this pipeline switches it once created, so a mismatch
  # means a human (or a stale pre-migration script) touched it by hand.
  current=$(git -C "$path" branch --show-current 2>/dev/null || true)
  if [ "$current" != "$branch" ]; then
    echo "Error: $path exists but is on '$current', not '$branch'." >&2
    echo "       This worktree is meant to stay pinned to '$branch' — fix it" >&2
    echo "       by hand (git -C $path checkout $branch) rather than let this" >&2
    echo "       script guess what belongs where." >&2
    exit 1
  fi
else
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git worktree add "$path" "$branch" >&2 || {
      echo "Error: '$branch' could not be attached at $path — it is most" >&2
      echo "       likely already checked out somewhere else (a leftover from" >&2
      echo "       before this pin existed). Run 'git worktree list', finish" >&2
      echo "       or remove whatever holds it, and re-run this step." >&2
      exit 1
    }
  elif git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
    git worktree add --track -b "$branch" "$path" "origin/$branch" >&2 || {
      echo "Error: could not create '$branch' tracking origin/$branch at $path" >&2
      exit 1
    }
  else
    # Greenfield: neither a local nor a remote copy exists yet. Branch off
    # develop, the same base a fresh feature worktree would use.
    git worktree add -b "$branch" "$path" develop >&2 || {
      echo "Error: could not create '$branch' from develop at $path" >&2
      exit 1
    }
  fi
fi

# Deliberately not sparse — release and main need the real plans/**,
# REGISTRY.md and templates/** content; that is the entire point of merging
# into them. Only feature worktrees exclude those paths
# (lv-worktree-sparse.sh, docs/worktrees.md).
"$(dirname "$0")/lv-worktree-harness.sh" "$path" >&2 || true

abs=$(cd "$path" && pwd -P)
echo "WORKTREE_PATH=$abs"
