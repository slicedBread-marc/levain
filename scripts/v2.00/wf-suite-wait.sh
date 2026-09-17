#!/usr/bin/env bash
# wf-suite-wait.sh <handle> [--timeout <seconds>]
#
# Waits for a suite started by `wf-suite-run.sh --detach` and reports its
# verdict — or says, truthfully, that it is still running.
#
# WHY THIS EXISTS
#
# A foreground call is capped at 10 minutes and a real suite can take longer,
# so an unattended promotion worker has no single call it can wait in. Left to
# improvise, one backgrounded the suite and ended: client-a's WFI-255, a
# DEPLOY worker that merged `release` into `main`, wrote "Full test suite
# running (expected ~13 min)" and "Awaiting test results", then exited rc=0
# sixty seconds later, leaving local `main` merged on a suite that was red.
#
# This is the shape that works. Each call blocks for a BOUNDED slice — well
# under the cap — and exits 3 if the suite has not finished. The caller loops
# on 3. Every iteration is a tool call, so the session keeps producing output
# and stays alive, and no verdict is ever asserted that no one waited for.
#
#   <handle>              the SUITE_LOG / SUITE_HANDLE path --detach printed
#   --timeout <seconds>   how long THIS call waits (default 540 = 9 minutes)
#
# Exit 0 the suite passed, 1 it failed, 2 the handle names nothing, 3 it is
# still running — CALL AGAIN. 3 is not a failure and not a pass; a caller that
# treats it as either is the bug this script exists to make impossible.

set -uo pipefail

handle="${1:-}"
[ -n "$handle" ] && shift
timeout=540

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) timeout="${2:-540}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "wf-suite-wait.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

if [ -z "$handle" ]; then
  echo "Usage: wf-suite-wait.sh <handle> [--timeout <seconds>]" >&2
  exit 2
fi

status="$handle.status"

# The log itself is written the moment the child starts, so an absent log means
# the handle is wrong — a different mistake from "not finished yet", and worth
# separating: waiting 9 minutes on a typo is 9 minutes of nothing.
if [ ! -f "$handle" ] && [ ! -f "$status" ]; then
  echo "Error: no suite run at '$handle' — neither the log nor its status file exists." >&2
  echo "       The handle is the SUITE_LOG path that 'wf-suite-run.sh --detach' printed." >&2
  exit 2
fi

waited=0
while [ ! -f "$status" ] && [ "$waited" -lt "$timeout" ]; do
  sleep 5
  waited=$((waited + 5))
done

if [ ! -f "$status" ]; then
  echo "SUITE_LOG=$handle"
  echo "SUITE_RESULT=running (${waited}s waited in this call, no verdict yet)"
  echo "Still running. Call wf-suite-wait.sh $handle again — do not report a result."
  # Last few lines, so a caller can see it is alive rather than wedged.
  tail -3 "$handle" 2>/dev/null | sed 's/^/  | /'
  exit 3
fi

cat "$status"
grep -q '^SUITE_RESULT=pass' "$status" && exit 0
exit 1
