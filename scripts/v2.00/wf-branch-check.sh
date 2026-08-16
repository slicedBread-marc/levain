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
# STDOUT IS AN EVAL CONTRACT
#
# Callers run `eval "$(wf-branch-check.sh develop true)"`, so every byte this
# script writes to stdout is executed as shell. Only its own KEY='value' lines
# may go there; everything else — git's own chatter, helper progress notes —
# goes to stderr, where a human can still see it.
#
# client-a's WFI-124: switching a dirty checkout let `git checkout`'s
# carried-over "M <file>" list and wf-infra-reset.sh's "reset ... (was 'M')"
# note through, and the caller's eval tried to run them — `no matches found:
# (was  M)`, then `command not found: M` once per modified file. The variables
# happened to survive; arbitrary git output reaching eval is the defect.
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
# So: an auto-switch of the SHARED checkout is refused unattended, and warned
# about interactively — where the human whose branch it is can see it — away
# from any branch the orchestrator would not have left it on:
#
#   · a branch this pipeline never creates (WFI-123 — a human's session)
#   · `release` or `main` (WFI-157 — a /wf-release or /wf-deploy is holding it)
#
# Only `develop` and `feature/*` are switched away from without comment.

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
  # Is this the shared main worktree, or a worktree of the caller's own?
  # The refusals below guard the shared one; a linked worktree belongs to
  # whoever created it and switching its branch races nobody.
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
  main_root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  shared=false
  [ -n "$toplevel" ] && [ "$toplevel" = "$main_root" ] && shared=true

  case "$current" in
    # `release` and `main` are pipeline branches, and for a long time that was
    # the whole test — so an unattended worker would move the shared checkout
    # off either of them without comment.
    #
    # It is never right. The orchestrator dispatches nothing unless the shared
    # checkout is on develop (checkout_available, WFI-135), and it never
    # dispatches wf-release or wf-deploy at all. So an unattended worker that
    # finds the checkout on release or main has found a deploy in progress:
    # the dispatch happened while develop was checked out, and a human's
    # skill parked it here afterwards.
    #
    # client-a's WFI-157 is what switching anyway costs. A wf-deploy had
    # main checked out and was three and a half minutes into the full suite;
    # a spec worker dispatched moments earlier called this script, moved the
    # shared checkout to develop, and the deploy's next seven `wf-bug-close.sh`
    # calls committed to develop instead of main. wf-deploy's own final
    # `git checkout develop` then printed "Already on develop". Nothing in its
    # output said the branch had moved.
    #
    # WFI-156 is the same event from the other side: wf-commit.sh refused
    # outright ("another session moved this checkout mid-run") while this
    # script, run seconds later, silently undid the move and exited 0. Two
    # scripts, one condition, opposite answers. Now both refuse.
    release|main|master)
      if $shared && [ "${WF_UNATTENDED:-0}" = "1" ]; then
        echo "Error: refusing to switch '$current' → '$expected'." >&2
        echo "       This is the shared checkout and it is on '$current', which the" >&2
        echo "       orchestrator never leaves it on — a release or a deploy is holding" >&2
        echo "       it. Switching would move the branch out from under that run and" >&2
        echo "       send its remaining commits to the wrong branch (WFI-157)." >&2
        echo "       Stand down; the next sweep after it finishes dispatches normally." >&2
        echo "CURRENT_BRANCH=$current"
        echo "REFUSED_SWITCH=$expected"
        exit 2
      fi
      # No warning on the attended path, deliberately. The attended caller of
      # exactly this transition is `/wf-release` step 8 and `/wf-deploy` step 11
      # handing the checkout back — the correct, expected end of the very run
      # this rule protects. A warning printed there is a false alarm on the
      # common case, and a false alarm on the common case is how a real one
      # gets ignored.
      ;;
    develop|feature/*) ;;
    # A branch this pipeline did not create is somebody's working session.
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
  "$(dirname "$0")/wf-infra-reset.sh" --dirty >&2 || true

  # A missing target branch used to be indistinguishable from any other
  # failure: `git checkout 2>/dev/null` swallowed "pathspec did not match",
  # and `set -e` aborted before the echo — so the caller got exit 1 with
  # completely empty stdout AND stderr. Greenfield repos hit this every time,
  # because develop does not exist yet.
  if ! git rev-parse --verify --quiet "refs/heads/$expected" >/dev/null; then
    # Track an existing remote branch if there is one, otherwise create it.
    if git rev-parse --verify --quiet "refs/remotes/origin/$expected" >/dev/null; then
      git checkout -b "$expected" --track "origin/$expected" >&2 || {
        echo "Error: branch '$expected' exists on origin but could not be checked out" >&2
        exit 1
      }
      # Quoted: the parenthesised provenance is part of the value, and bare
      # parens in an eval'd line are a syntax error, not a comment.
      echo "CREATED_BRANCH='$expected (tracking origin/$expected)'"
    else
      git checkout -b "$expected" >&2 || {
        echo "Error: branch '$expected' does not exist and could not be created from '$current'" >&2
        exit 1
      }
      echo "CREATED_BRANCH='$expected (from $current)'"
    fi
    echo "CURRENT_BRANCH=$expected"
    echo "SWITCHED_FROM=$current"
    exit 0
  fi

  # Real git errors surface — no 2>/dev/null. A dirty tree that blocks the
  # switch is something the caller has to see. stdout goes to stderr for the
  # eval contract above: git prints the carried-over "M <file>" list there.
  if ! git checkout "$expected" >&2; then
    echo "Error: could not switch from '$current' to '$expected'" >&2
    exit 1
  fi
  echo "CURRENT_BRANCH=$expected"
  echo "SWITCHED_FROM=$current"
  exit 0
fi

echo "Error: expected branch '$expected', on '$current'" >&2
exit 1
