#!/usr/bin/env bash
# wf-suite-run.sh [--label <name>] [--build]
#
# Runs the project's CONFIGURED test command, verbatim, and issues a receipt
# that names what it ran.
#
# WHY THIS EXISTS
#
# /wf-release step 7 and /wf-deploy step 8 are the release aggregation
# guarantee: every test a feature branch skipped under tiered gating runs here,
# whole, before anything reaches production. Both skills stated that as a
# comment above a `{{test_command}}` placeholder and left the running of it to
# the model — so the guarantee was a request, and nothing downstream could tell
# a full run from a filtered one.
#
# client-a's WFI-252: a RELEASE worker reported exactly one line of
# evidence, "E2E tests passed: 474 passed, 0 failed", and pushed `release`.
# 474 is the size of one assembly (Tracker.Core.Tests). The configured suite on
# that same content measures 3100 total with 121 failures, all of them in the
# E2E assembly the run claimed had passed. /wf-deploy caught it at its own full
# run and reset `main`; nothing reached production, and nothing except that
# second full run would have.
#
# So the harness runs it. The command comes from claude-workflow.yml and is not
# the caller's to choose, narrow or re-type, and the receipt below is what the
# skill quotes — a caller cannot report a pass this script did not print.
#
#   --label <name>   tag for the log file name (default: suite)
#   --build          run build_command first; a failure there is exit 1 too
#
# Output, on stdout, as the last lines:
#   SUITE_CMD=<the command that ran, verbatim>
#   SUITE_LOG=<absolute path to the full output>
#   SUITE_RESULT=pass|fail (exit <code of the command>)
#
# Exit 0 the suite passed, 1 it failed (or the build did), 2 no test_command is
# configured for this project — which is a fact to report, never a pass.
#
# THIS IS A LONG-RUNNING COMMAND. A foreground Bash call is capped at 10
# minutes and a real suite can exceed that. Everything is teed to SUITE_LOG as
# it runs, so a caller that has to background this reads the verdict out of
# that file rather than re-running.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

label="suite"
do_build=false
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="${2:-suite}"; shift 2 ;;
    --build) do_build=true; shift ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "wf-suite-run.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

TEST_CMD=$(wf_cfg test_command)
if [ -z "$TEST_CMD" ]; then
  echo "Error: no test_command in claude-workflow.yml — this project has no configured suite." >&2
  echo "       That is a gap to report, not a suite that passed." >&2
  echo "SUITE_RESULT=unconfigured"
  exit 2
fi

DEVELOP_ROOT="$(wf_develop_root)"
LOG_DIR="$DEVELOP_ROOT/.claude/orchestrator/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
LOG="$LOG_DIR/suite-$label-$(date +%Y%m%d-%H%M%S).log"

# Runs where the caller is standing, on purpose: /wf-release tests the local
# merge inside release-branches/release, /wf-deploy tests merged `main` inside
# release-branches/main. Running either from the develop root would test
# develop — the wrong-tree-reported-as-success class (WFI-105, WFI-225).
echo "Running the configured suite in $(pwd)" | tee "$LOG"
echo "  branch: $(git branch --show-current 2>/dev/null || echo '(detached)')" | tee -a "$LOG"
echo "  head:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"

rc=0

if $do_build; then
  BUILD_CMD=$(wf_cfg build_command)
  if [ -n "$BUILD_CMD" ]; then
    echo "  build:  $BUILD_CMD" | tee -a "$LOG"
    # `< /dev/null`: a build or test step that reads stdin blocks forever
    # otherwise, with no failure and no output to show for it (WFI-240).
    set -o pipefail
    eval "$BUILD_CMD" < /dev/null 2>&1 | tee -a "$LOG"
    rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
      echo ""
      echo "SUITE_CMD=$BUILD_CMD"
      echo "SUITE_LOG=$LOG"
      echo "SUITE_RESULT=fail (build exit $rc — the suite never ran)"
      exit 1
    fi
  fi
fi

echo "  suite:  $TEST_CMD" | tee -a "$LOG"
echo "" | tee -a "$LOG"

set -o pipefail
eval "$TEST_CMD" < /dev/null 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}

echo ""
echo "SUITE_CMD=$TEST_CMD"
echo "SUITE_LOG=$LOG"
if [ "$rc" -eq 0 ]; then
  echo "SUITE_RESULT=pass (exit 0)"
  exit 0
fi
echo "SUITE_RESULT=fail (exit $rc)"
exit 1
