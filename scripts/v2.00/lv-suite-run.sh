#!/usr/bin/env bash
# lv-suite-run.sh [--label <name>] [--build]
#
# Runs the project's CONFIGURED test command, verbatim, and issues a receipt
# that names what it ran.
#
# WHY THIS EXISTS
#
# /lv-release step 7 and /lv-deploy step 8 are the release aggregation
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
# E2E assembly the run claimed had passed. /lv-deploy caught it at its own full
# run and reset `main`; nothing reached production, and nothing except that
# second full run would have.
#
# So the harness runs it. The command comes from levain.yml and is not
# the caller's to choose, narrow or re-type, and the receipt below is what the
# skill quotes — a caller cannot report a pass this script did not print.
#
#   --label <name>   tag for the log file name (default: suite)
#   --build          run build_command first; a failure there is exit 1 too
#   --detach         start the run in a process that outlives this call and
#                    return immediately; wait for it with lv-suite-wait.sh
#
# Output, on stdout, as the last lines:
#   SUITE_CMD=<the command that ran, verbatim>
#   SUITE_LOG=<absolute path to the full output>
#   SUITE_RESULT=pass|fail (exit <code of the command>)
#
# Exit 0 the suite passed, 1 it failed (or the build did), 2 no test_command is
# configured for this project — which is a fact to report, never a pass.
#
# THIS IS A LONG-RUNNING COMMAND, AND WAITING FOR IT IS THE HARD PART.
#
# A foreground call is capped at 10 minutes; client-a's suite takes about
# 13. An UNATTENDED worker cannot solve that by backgrounding, because a
# headless run ends the moment it stops producing output and takes every
# background job with it. client-a's WFI-255: a DEPLOY worker merged
# `release` into `main`, wrote "Full test suite running (expected ~13 min)"
# and "Awaiting test results", and exited rc=0 sixty seconds later. It never
# awaited them. The suite was red.
#
# `--detach` is the way to wait. The run is handed to a process that outlives
# this call and writes its verdict to <log>.status; lv-suite-wait.sh then
# blocks for a bounded slice and reports "still running" rather than lying.
# A worker loops on that, so every individual call stays under the cap while
# the session keeps producing output and therefore stays alive.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

label="suite"
do_build=false
detach=false
# Set by the re-exec below so the detached child runs the suite for real.
child="${LV_SUITE_CHILD_LOG:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="${2:-suite}"; shift 2 ;;
    --build) do_build=true; shift ;;
    --detach) detach=true; shift ;;
    -h|--help) sed -n '2,55p' "$0"; exit 0 ;;
    *) echo "lv-suite-run.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

TEST_CMD=$(wf_cfg test_command)
if [ -z "$TEST_CMD" ]; then
  echo "Error: no test_command in levain.yml — this project has no configured suite." >&2
  echo "       That is a gap to report, not a suite that passed." >&2
  echo "SUITE_RESULT=unconfigured"
  exit 2
fi

DEVELOP_ROOT="$(wf_develop_root)"
LOG_DIR="$DEVELOP_ROOT/.claude/orchestrator/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
LOG="${child:-$LOG_DIR/suite-$label-$(date +%Y%m%d-%H%M%S).log}"

# ── --detach: hand the run to a process that outlives this call ───────────
#
# `setsid` where it exists, `nohup` otherwise: the child must survive the
# session that started it, because the whole point is that the session cannot
# hold a 13-minute foreground call. The status file is written by the child
# when it finishes and is the only thing lv-suite-wait.sh trusts — a running
# child has none, which is exactly how "still running" is told apart from
# "finished and passed".
if $detach && [ -z "$child" ]; then
  rm -f "$LOG.status" "$LOG.status.read"
  # Create the handle here, not in the child: lv-suite-wait.sh tells "bad
  # handle" from "not finished yet" by whether the log exists, and a child that
  # has not been scheduled yet would otherwise look like a typo.
  : > "$LOG"
  # What was under test, recorded before the run rather than reconstructed
  # after it. A verdict nobody collected is only useful if the tree it measured
  # can still be named — see lv-suite-receipts.sh (client-a WFI-266).
  printf 'SUITE_LABEL=%s\nSUITE_DIR=%s\nSUITE_BRANCH=%s\nSUITE_TIP=%s\nSUITE_STARTED=%s\n' \
    "$label" "$(pwd -P)" \
    "$(git branch --show-current 2>/dev/null || echo '(detached)')" \
    "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOG.meta"
  args=(--label "$label")
  $do_build && args+=(--build)
  launcher=(nohup)
  command -v setsid >/dev/null 2>&1 && launcher=(setsid nohup)
  LV_SUITE_CHILD_LOG="$LOG" "${launcher[@]}" "$0" "${args[@]}" >/dev/null 2>&1 &
  echo "SUITE_LOG=$LOG"
  echo "SUITE_HANDLE=$LOG"
  echo "SUITE_RESULT=running (detached pid $!)"
  echo "Wait for it: lv-suite-wait.sh $LOG"
  exit 0
fi

# The child records its verdict where lv-suite-wait.sh will look for it. A
# `trap` rather than a line at the bottom: a child killed mid-suite must leave
# a verdict that says so, not an absent file that reads as "still running"
# forever.
if [ -n "$child" ]; then
  trap 'printf "SUITE_LOG=%s\nSUITE_RESULT=fail (the suite process died before it finished — see the log)\n" "$LOG" > "$LOG.status"' EXIT INT TERM
fi

# Runs where the caller is standing, on purpose: /lv-release tests the local
# merge inside release-branches/release, /lv-deploy tests merged `main` inside
# release-branches/main. Running either from the develop root would test
# develop — the wrong-tree-reported-as-success class (WFI-105, WFI-225).
echo "Running the configured suite in $(pwd)" | tee "$LOG"
echo "  branch: $(git branch --show-current 2>/dev/null || echo '(detached)')" | tee -a "$LOG"
echo "  head:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"

rc=0

# The receipt, in one place. A detached child's stdout goes nowhere, so its
# copy has to land in the status file — same three lines, so a caller reads an
# identical receipt whether it ran the suite inline or waited for one.
finish() {
  local result="$1" cmd="$2"
  printf 'SUITE_CMD=%s\nSUITE_LOG=%s\nSUITE_RESULT=%s\n' "$cmd" "$LOG" "$result"
  if [ -n "$child" ]; then
    trap - EXIT
    # The tip is stamped into the verdict, not left to be inferred from the
    # log's first lines. A green run whose caller vanished is re-usable only by
    # someone who can prove it measured the tree in front of them (WFI-266).
    {
      printf 'SUITE_CMD=%s\nSUITE_LOG=%s\nSUITE_RESULT=%s\n' "$cmd" "$LOG" "$result"
      printf 'SUITE_BRANCH=%s\nSUITE_TIP=%s\nSUITE_ENDED=%s\n' \
        "$(git branch --show-current 2>/dev/null || echo '(detached)')" \
        "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$LOG.status"
  fi
}

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
      finish "fail (build exit $rc — the suite never ran)" "$BUILD_CMD"
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
if [ "$rc" -eq 0 ]; then
  finish "pass (exit 0)" "$TEST_CMD"
  exit 0
fi
finish "fail (exit $rc)" "$TEST_CMD"
exit 1
