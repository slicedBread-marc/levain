#!/usr/bin/env bash
# lv-derived-refresh.sh [--hook <post-merge|post-checkout>]
#
# Regenerates the git-ignored files the develop checkout serves, by running
# levain.yml's `derivedCommand:` there.
#
# WHY THIS EXISTS (LVI-032)
#
# Some projects serve build output that git does not carry: an index, a nav
# file, a catalogue, generated from tracked sources and ignored because every
# plan would regenerate it and conflict on every merge. A plan builds and tests
# those files in its own feature worktree. When it merges to develop, nothing
# rebuilds the develop checkout's copy, so what the operator opens there is the
# tree from before the merge.
#
# A client, 2026-09-30. PLN-055 merged to develop and passed its human test in
# the worktree. In the develop checkout, brainstorm/nav.js (git-ignored) still
# predated the merge and did not list the new section, so all 55 pages opened
# with no version bar, no nav and no ratings. The worktree had been removed by
# then. `node brainstorm.ts` fixed it in 0.6s, run by hand.
#
# WHO CALLS IT
#
# The harness's git hooks, post-merge and post-checkout, so a plan landing on
# develop, a back-merge from main, a `git pull` and a branch switch all rebuild.
# Hooks fire in every worktree because they live in the shared git dir. This
# runs only in the MAIN worktree, which is the develop checkout. A feature
# worktree builds its own copy as part of its build.
#
# Rules:
#   · No `derivedCommand:` set: exit 0 and do nothing. That is the default.
#   · A post-checkout that is a file checkout (flag 0), or one that did not
#     move HEAD, changed nothing to rebuild from.
#   · Mid-rebase, mid-cherry-pick or mid-bisect: skip. Each step checks out a
#     commit, and the rebuild belongs to where the operation ends.
#   · LV_DERIVED_SKIP=1 suppresses it, for a script that switches branches
#     several times and refreshes once at the end.
#   · One refresh at a time. A second call while one runs asks the running one
#     to go again when it finishes, so the last checkout always gets a rebuild.
#
# The command runs with the develop root as its working directory, through
# `bash -c`. Its output goes to .claude/orchestrator/logs/derived.log.
#
# Exit 0 rebuilt, or nothing to do. 1 the command failed; the tail of its log is
# printed. A hook ignores the exit code, because a post-* hook cannot undo the
# merge or checkout that fired it, and a failed rebuild must not read as a
# failed merge.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

hook=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hook) hook="${2:?--hook requires a name}"; shift 2 ;;
    -h|--help) sed -n '2,47p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) break ;;
  esac
done

[ "${LV_DERIVED_SKIP:-0}" = "1" ] && exit 0

cmd=$(wf_cfg derivedCommand)
[ -n "$cmd" ] || exit 0

root=$(wf_develop_root)

if [ -n "$hook" ]; then
  # Only the develop checkout. git -C "$PWD" because a hook runs at the
  # worktree's toplevel, and wf_develop_root answers for the repository.
  here=$(git rev-parse --show-toplevel 2>/dev/null || printf '%s' "$PWD")
  here=$(cd "$here" 2>/dev/null && pwd -P) || exit 0
  [ "$here" = "$(cd "$root" 2>/dev/null && pwd -P)" ] || exit 0

  case "$hook" in
    post-checkout)
      # git passes: <prev HEAD> <new HEAD> <1 branch checkout | 0 file checkout>
      [ "${3:-0}" = "1" ] || exit 0
      [ "${1:-}" != "${2:-}" ] || exit 0
      ;;
    post-merge) ;;
    *) echo "lv-derived-refresh: unknown hook '$hook'" >&2; exit 0 ;;
  esac

  gd=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
  for _op in rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
    [ -e "$gd/$_op" ] && exit 0
  done
fi

orch=$(wf_orch_dir)
lock="$orch/derived.lock"
again="$orch/derived.again"
log="$orch/logs/derived.log"
mkdir -p "$orch/logs"

if ! mkdir "$lock" 2>/dev/null; then
  # A holder whose process is gone left the lock behind. Anything else is a
  # live refresh: ask it to run once more and leave.
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
    rm -rf "$lock"
    mkdir "$lock" 2>/dev/null || { : > "$again"; exit 0; }
  else
    : > "$again"
    echo "lv-derived-refresh: a refresh is already running; it will go again when it finishes."
    exit 0
  fi
fi
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

rc=0
while :; do
  rm -f "$again"
  {
    echo "── $(wf_now) ${hook:-manual} — $cmd"
  } > "$log"
  ( cd "$root" && bash -c "$cmd" ) >> "$log" 2>&1
  rc=$?
  echo "── exit $rc" >> "$log"
  [ -e "$again" ] || break
done

if [ "$rc" -ne 0 ]; then
  echo "lv-derived-refresh: derivedCommand failed (exit $rc) in $root — the develop checkout's derived files are stale." >&2
  echo "  Log: $log" >&2
  tail -n 15 "$log" | sed 's/^/  | /' >&2
  exit 1
fi
echo "lv-derived-refresh: derived files rebuilt ($cmd)"
exit 0
