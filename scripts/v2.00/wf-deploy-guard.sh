#!/usr/bin/env bash
# wf-deploy-guard.sh --arm | --disarm | --status | --recover
#
# Makes a merge into `main` that has not passed its suite impossible to leave
# behind.
#
# WHY THIS EXISTS
#
# /wf-deploy merges `release` into `main` at step 7 and only finds out at step 8
# whether the result passes. Between those two steps, local `main` claims a
# promotion nothing has verified — and a run that stops in that window leaves
# the claim standing. client-a's WFI-255: an unattended DEPLOY worker merged
# 164 commits into `main`, wrote "Full test suite running (expected ~13 min)"
# and "Awaiting test results", and exited rc=0 sixty seconds later. It never
# awaited them; the suite was red (121 E2E errors). Nothing reached production
# — origin/main never moved — but the repository read as deployed, and it took
# a human noticing to put it back.
#
# So the merge arms a marker naming the commit `main` was on before it. While
# that marker exists, the merge is provisional: `--recover` puts `main` back,
# and every entry into /wf-deploy runs it. Only a passing suite disarms it.
#
# This is deliberately not a lock. A lock asks a worker to release it; this
# survives a worker that never gets the chance, which is the failure it exists
# for.
#
#   --arm       record the current `main` tip as the pre-merge state
#   --disarm    the suite passed — the merge stands
#   --status    print the marker (exit 0 armed, 1 not armed)
#   --recover   if armed, reset `main` to the recorded commit and disarm
#
# Run it from the worktree holding `main` (release-branches/main). It refuses
# to reset anything that is not `main`, and it never touches `origin/main`.
#
# Exit 0 the action succeeded (or, for --status, a marker exists), 1 no marker,
# 2 it refused: wrong branch, or a recovery that would discard a commit
# origin/main already has.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

action="${1:---status}"

DEVELOP_ROOT="$(wf_develop_root)"
MARKER="$DEVELOP_ROOT/.claude/orchestrator/deploy-unverified"

# The marker lives on the develop root, not in the main worktree, for the same
# reason the registry does: it must be readable from whichever worktree the
# next session happens to be standing in.
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || true

case "$action" in
  --arm)
    branch=$(git branch --show-current 2>/dev/null || true)
    if [ "$branch" != "main" ]; then
      echo "Error: --arm must run in the worktree checked out to main (found '${branch:-detached}')." >&2
      exit 2
    fi
    printf 'pre_merge_sha=%s\nworktree=%s\narmed_at=%s\n' \
      "$(git rev-parse HEAD)" "$(pwd -P)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
    echo "Armed: main is provisional until its suite passes (pre-merge $(git rev-parse --short HEAD))"
    ;;

  --disarm)
    if [ ! -f "$MARKER" ]; then echo "Nothing armed."; exit 1; fi
    rm -f "$MARKER"
    echo "Disarmed: the merge into main stands on a suite that passed"
    ;;

  --status)
    if [ ! -f "$MARKER" ]; then echo "No unverified merge recorded."; exit 1; fi
    echo "UNVERIFIED MERGE ON main:"
    sed 's/^/  /' "$MARKER"
    echo "  Run wf-deploy-guard.sh --recover to put main back, or let the suite pass and --disarm."
    ;;

  --recover)
    if [ ! -f "$MARKER" ]; then echo "Nothing to recover."; exit 1; fi
    sha=$(sed -n 's/^pre_merge_sha=//p' "$MARKER" | head -1)
    wt=$(sed -n 's/^worktree=//p' "$MARKER" | head -1)
    if [ -z "$sha" ] || [ -z "$wt" ] || [ ! -d "$wt" ]; then
      echo "Error: the marker at $MARKER is unusable (sha='$sha', worktree='$wt')." >&2
      echo "       Reset main by hand and delete it." >&2
      exit 2
    fi
    branch=$(git -C "$wt" branch --show-current 2>/dev/null || true)
    if [ "$branch" != "main" ]; then
      echo "Error: $wt is on '${branch:-detached}', not main — refusing to reset it." >&2
      exit 2
    fi
    # The one thing a recovery must never undo is a promotion that actually
    # happened. If the push went through, the merge is not provisional at all
    # and the marker is stale — say so and clear it rather than rewriting a
    # branch the remote already has.
    if git -C "$wt" rev-parse --verify --quiet origin/main >/dev/null 2>&1 \
       && git -C "$wt" merge-base --is-ancestor "$(git -C "$wt" rev-parse HEAD)" origin/main 2>/dev/null; then
      rm -f "$MARKER"
      echo "origin/main already carries this commit — the promotion completed. Marker cleared, main untouched."
      exit 0
    fi
    if [ "$(git -C "$wt" rev-parse HEAD)" = "$sha" ]; then
      rm -f "$MARKER"
      echo "main is already at the pre-merge commit ${sha:0:8} — nothing to undo. Marker cleared."
      exit 0
    fi
    git -C "$wt" reset --hard "$sha" >/dev/null 2>&1 || {
      echo "Error: could not reset main to $sha in $wt." >&2
      exit 2
    }
    rm -f "$MARKER"
    echo "Recovered: main reset to ${sha:0:8}, the commit it was on before an unverified merge."
    echo "           A previous /wf-deploy merged and stopped without a suite verdict (WFI-255)."
    ;;

  -h|--help)
    sed -n '2,37p' "$0"
    ;;

  *)
    echo "Usage: wf-deploy-guard.sh --arm | --disarm | --status | --recover" >&2
    exit 2
    ;;
esac
