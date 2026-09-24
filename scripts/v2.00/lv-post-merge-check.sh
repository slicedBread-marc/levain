#!/usr/bin/env bash
# lv-post-merge-check.sh [--label <name>] [--detach]
#
# Validates the tree produced by merging `release` into a feature branch, at the
# one moment where the plan that caused a break is still in hand.
#
# WHY THIS EXISTS
#
# /lv-test merges release into the feature branch (lv-merge-release.sh) and then
# pushes the result to release. Between those two things it used to run
# lv-build-check.sh — build_command only. A merge that COMPILES and breaks tests
# therefore reached `release` with nothing having run a suite on it, and the
# first thing that did was /lv-deploy, hours later, after a human had already
# been asked to approve the promotion.
#
# client-a, 2026-09-18. PLN-284 merged to release at 15:04, PLN-283's PR at
# 16:15, each green in its own worktree. The last suite on release itself had
# run at 14:04, before both. Merged, they break an August-old CLI test
# (CaptureTimingTests.SendNote_WithATicket… — the ticket folder no longer holds
# the conversation.md it asserts). Three deploys found that out, one 20-minute
# suite at a time, and DEPLOY parked `stuck` with 15 completed plans behind it.
# The branch that caused it was long gone, its worktree destroyed, its plan
# complete.
#
# A semantic merge break is exactly what the merging side is best placed to fix
# and worst placed to notice. So this runs the real suite there, by default.
#
# WHAT IT RUNS — levain.yml, `postMergeCheck:`
#
#   full   (default)  build_command, then test_command, whole and unfiltered —
#                     the same lv-suite-run.sh every other gate uses.
#   build             build_command only: the pre-9.8 behavior. For a project
#                     whose suite is too slow to run at every plan exit and
#                     which accepts finding merge breaks at deploy instead.
#                     Name the reason in a comment beside the key.
#
# `full` costs one suite run per plan exit. That is the price of the failure
# above, and it is paid by the plan that caused it rather than by the release.
#
#   --label <name>  tag for the log file (default: post-merge)
#   --detach        hand the run to a process that outlives this call and print
#                   SUITE_HANDLE=; wait for it with lv-suite-wait.sh. Required
#                   under LV_UNATTENDED=1 for any suite that may outlast the
#                   10-minute foreground cap — see lv-suite-run.sh's header for
#                   why backgrounding is not the same thing.
#
# Exit 0 the merged tree is good, 1 it is not (build or suite), 2 nothing is
# configured to check it with — a gap to report, never a pass. With --detach,
# exit 0 means the run STARTED; the verdict comes from lv-suite-wait.sh.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

label="post-merge"
detach=false
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="${2:?--label requires a name}"; shift 2 ;;
    --detach) detach=true; shift ;;
    -h|--help) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "lv-post-merge-check.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

mode=$(wf_cfg postMergeCheck)
mode="${mode:-full}"

case "$mode" in
  build)
    echo "postMergeCheck: build — build only, no suite (levain.yml)"
    exec "$SELF_DIR/lv-build-check.sh"
    ;;
  full) ;;
  *)
    # Not defaulted-past. An unrecognized value is somebody's intent, and
    # guessing which of the two they meant is how a project silently stops
    # running its suite.
    echo "lv-post-merge-check: postMergeCheck: '$mode' is not 'full' or 'build'." >&2
    echo "  Fix levain.yml; this check will not guess which you meant." >&2
    exit 2 ;;
esac

set -- --label "$label" --build
$detach && set -- "$@" --detach
"$SELF_DIR/lv-suite-run.sh" "$@"
rc=$?

case "$rc" in
  0) ;;
  1) echo "Post-merge check FAILED — the merge of release into this branch does not pass the suite." >&2 ;;
  2) echo "lv-post-merge-check: no test_command configured — nothing validated the merged tree." >&2 ;;
esac
exit $rc
