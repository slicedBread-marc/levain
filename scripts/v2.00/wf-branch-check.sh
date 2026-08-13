#!/usr/bin/env bash
# wf-branch-check.sh <expected-branch> [auto-switch]
# Checks current branch matches expected. If auto-switch is "true" and on
# wrong branch, switches automatically.
#
# Examples:
#   wf-branch-check.sh develop true    → switches to develop if not on it
#   wf-branch-check.sh release         → prints error if not on release
#   wf-branch-check.sh feature         → checks if on any feature/* branch
#
# Output: CURRENT_BRANCH=<branch-name>
# Exit 0 if on correct branch (or switched), 1 if wrong branch,
#        2 refused to auto-switch a shared checkout somebody else parked.
#
# WHY EXIT 2 EXISTS
#
# `auto-switch` moves the branch of whatever worktree the caller is standing
# in, and for every develop-side role that worktree is the SHARED main one. A
# human working interactively parks it wherever they like. client-a's
# WFI-123: the daemon's workers found the main worktree on
# `fix/BUG-039-ci-test-portability`, committed four PLN-038 commits on top of a
# hand-made commit there, and then switched the shared working directory to
# develop mid-session — from under the human using it. `git checkout -b` offers
# no protection against this, because the branch was never the thing being
# guarded; the worktree was.
#
# So: an auto-switch away from a branch that is not one of the pipeline's own
# (develop / release / main / feature/*) is refused unattended, and warned
# about interactively — where the human whose branch it is can see it.

set -euo pipefail

expected="${1:-}"
auto_switch="${2:-false}"

if [ -z "$expected" ]; then
  echo "Usage: $0 <expected-branch> [auto-switch]" >&2
  exit 1
fi

current=$(git branch --show-current)

# Special case: "feature" matches any feature/* branch
if [ "$expected" = "feature" ]; then
  if echo "$current" | grep -q "^feature/"; then
    echo "CURRENT_BRANCH=$current"
    exit 0
  else
    echo "Error: expected a feature/* branch, on '$current'" >&2
    exit 1
  fi
fi

if [ "$current" = "$expected" ]; then
  echo "CURRENT_BRANCH=$current"
  exit 0
fi

if [ "$auto_switch" = "true" ]; then
  # A branch this pipeline did not create is somebody's working session.
  case "$current" in
    develop|release|main|feature/*) ;;
    *)
      if [ "${WF_UNATTENDED:-0}" = "1" ]; then
        echo "Error: refusing to switch '$current' → '$expected'." >&2
        echo "       '$current' is not a pipeline branch, so another session owns this" >&2
        echo "       checkout. Switching it would move a ref out from under them (WFI-123)." >&2
        echo "CURRENT_BRANCH=$current"
        echo "REFUSED_SWITCH=$expected"
        exit 2
      fi
      echo "Warning: '$current' is not a pipeline branch — switching it to '$expected'." >&2
      echo "         If another session is using this checkout, stop and let it finish." >&2
      ;;
  esac

  # Reset infra files before switching — prevents unmerged/dirty conflicts.
  #
  # This was an inline `git checkout HEAD -- <both paths>`, which is atomic
  # across its pathspecs: once .claude/workflow.md became gitignored (v5.0.0)
  # the whole command failed "did not match any file(s) known to git" and reset
  # NOTHING, silently, because stderr was dropped and the failure swallowed
  # (WFI-118). wf-infra-reset.sh does it one tracked path at a time.
  "$(dirname "$0")/wf-infra-reset.sh" --dirty || true

  # A missing target branch used to be indistinguishable from any other
  # failure: `git checkout 2>/dev/null` swallowed "pathspec did not match",
  # and `set -e` aborted before the echo — so the caller got exit 1 with
  # completely empty stdout AND stderr. Greenfield repos hit this every time,
  # because develop does not exist yet.
  if ! git rev-parse --verify --quiet "refs/heads/$expected" >/dev/null; then
    # Track an existing remote branch if there is one, otherwise create it.
    if git rev-parse --verify --quiet "refs/remotes/origin/$expected" >/dev/null; then
      git checkout -b "$expected" --track "origin/$expected" || {
        echo "Error: branch '$expected' exists on origin but could not be checked out" >&2
        exit 1
      }
      echo "CREATED_BRANCH=$expected (tracking origin/$expected)"
    else
      git checkout -b "$expected" || {
        echo "Error: branch '$expected' does not exist and could not be created from '$current'" >&2
        exit 1
      }
      echo "CREATED_BRANCH=$expected (from $current)"
    fi
    echo "CURRENT_BRANCH=$expected"
    echo "SWITCHED_FROM=$current"
    exit 0
  fi

  # Real git errors surface — no 2>/dev/null. A dirty tree that blocks the
  # switch is something the caller has to see.
  if ! git checkout "$expected"; then
    echo "Error: could not switch from '$current' to '$expected'" >&2
    exit 1
  fi
  echo "CURRENT_BRANCH=$expected"
  echo "SWITCHED_FROM=$current"
  exit 0
fi

echo "Error: expected branch '$expected', on '$current'" >&2
exit 1
