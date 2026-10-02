#!/usr/bin/env bash
# lv-infra-reset.sh [--dirty]
#
# Resets the two infra files a branch switch or a stash pop can leave in the
# way: .claude/workflow-version and .claude/workflow.md.
#
# WHY THIS EXISTS
#
# Every call site used to be this line, copy-pasted eight times:
#
#   git checkout HEAD -- .claude/workflow-version .claude/workflow.md 2>/dev/null || true
#
# `git checkout -- <paths>` is ATOMIC across its pathspecs. `.claude/workflow.md`
# is gitignored as of v5.0.0, so in any client that has taken that migration the
# path is untracked, git refuses the WHOLE pathspec with "did not match any
# file(s) known to git", and NOTHING is reset. `2>/dev/null` hides the reason
# and `|| true` hides the failure, so the step silently no-ops — client-a's
# WFI-118 watched .claude/workflow-version stay modified through two
# invocations of that line while both reported nothing at all.
#
# Same shape as WFI-053 in lv-commit.sh: one unmatched pathspec in an atomic
# git command silently voids every other path in the list. So: one path at a
# time, tracked paths only, and say what happened.
#
# WHAT GETS RESET, AND WHY IT MATTERS WHICH
#
# Default is UNMERGED ONLY — a path git has left in conflict. That is the job
# at the lv-test call sites: after `lv-stash.sh pop` the infra
# files can come back conflicted, and resolving them to HEAD is right because
# a stash conflict on generated infra carries no information.
#
# A merely-MODIFIED workflow-version is different, and resetting it is how
# WFI-118's second half happened: the file was dirty at session start because
# ANOTHER session had deployed a newer harness (6.2.1 on disk, 6.0.1 at HEAD),
# and a blanket reset would have thrown that away. This skill does not own that
# file; it only needs it out of the way of a checkout.
#
#   --dirty   also reset modified-but-not-conflicted paths. Only for the branch
#             switch in lv-branch-check.sh, where a dirty infra file that
#             differs across branches genuinely blocks the switch. It prints
#             what it reset so the discard is never silent.
#
# Exit 0 always — nothing here is worth failing a caller over. Output names
# every path it touched; silence means there was nothing to do.

set -euo pipefail

mode="conflicted"
[ "${1:-}" = "--dirty" ] && mode="dirty"

INFRA_PATHS=(.claude/workflow-version .claude/workflow.md)

for p in "${INFRA_PATHS[@]}"; do
  # Untracked (the normal state post-v5.0.0 for workflow.md) — not ours to reset,
  # and naming it in a pathspec is what voided the whole command before.
  git ls-files --error-unmatch -- "$p" >/dev/null 2>&1 || continue

  status=$(git status --porcelain -- "$p" 2>/dev/null | head -1)
  [ -n "$status" ] || continue

  code="${status:0:2}"
  case "$code" in
    UU|AA|DD|AU|UA|DU|UD) ;;                       # unmerged — always resolve
    *) [ "$mode" = "dirty" ] || continue ;;        # merely modified
  esac

  if git checkout HEAD -- "$p" 2>/dev/null; then
    echo "lv-infra-reset: reset $p (was '$code')"
  else
    echo "lv-infra-reset: could not reset $p (was '$code')" >&2
  fi
done

exit 0
