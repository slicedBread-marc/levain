#!/usr/bin/env bash
# lv-deploy-suite-memo.sh --fail <summary> | --clear | --check | --show
#
# Remembers that the deploy suite went red on a particular `release` tip, so the
# next dispatch does not spend another full suite finding out the same thing.
#
# WHY THIS EXISTS
#
# /lv-deploy merges `release` into `main` and runs the whole suite against the
# result. When that suite fails the run does the right thing — recovers `main`,
# reports, unclaims — and changes nothing. `release` is still the same tip, so
# the daemon's next sweep sees the same eligible batch and dispatches another
# deploy, which merges the same commits and runs the same suite to the same
# verdict.
#
# client-a, 2026-09-18: three deploys at 18:36, 19:03 and 19:25, each one a
# ~20-minute suite, each failing the identical single test
# (CaptureTimingTests.SendNote_WithATicket… — 1 of 3339), each recovering main.
# An hour of compute to learn one fact three times, and the orchestrator's
# stuck-after-3 rule then parked DEPLOY with no more information than the first
# run had produced. Nothing was wrong with any of those runs individually; what
# was missing was a memory between them.
#
# So the verdict is written down against the tip it was reached on. A tip the
# suite has already failed is not re-run: the caller reports the recorded
# failure, parks it for a human, and the fix lands on `release` — which moves
# the tip, which invalidates this memo by construction. There is no stale-memo
# case to manage: a new commit on release is a new question.
#
# This is NOT a substitute for running the suite. It only ever answers "have we
# already run it, on exactly this tree, and seen it fail?". A pass clears it;
# anything that moves `release` makes it irrelevant.
#
#   --fail <summary>   record: this release tip failed the deploy suite.
#                      <summary> is the one-line reason a human will read at the
#                      gate — the failing test, not "tests failed". Optional
#                      --log <path> records where the full output is.
#   --clear            the suite passed (or the batch is being reconsidered).
#   --check            exit 1 if the CURRENT release tip is the recorded failing
#                      one, printing what was recorded. Exit 0 otherwise.
#   --show             print the memo, if any. Exit 0 either way.
#
# Exit 0 nothing recorded for this tip / action done, 1 this tip is a known
# failure (--check only), 2 usage.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

DEVELOP_ROOT="$(wf_develop_root)"
MEMO="$DEVELOP_ROOT/.claude/orchestrator/deploy-suite-failed"
mkdir -p "$(dirname "$MEMO")" 2>/dev/null || true

# The tip as the promotion reads it — origin/release, the only ref that can
# claim a pushed, E2E-validated batch (lv-release-sync.sh's whole subject).
current_tip() {
  git -C "$DEVELOP_ROOT" rev-parse --verify -q refs/remotes/origin/release 2>/dev/null \
    || git -C "$DEVELOP_ROOT" rev-parse --verify -q refs/heads/release 2>/dev/null \
    || true
}

action="${1:---show}"
shift || true

summary=""
log=""
while [ $# -gt 0 ]; do
  case "$1" in
    --log) log="${2:-}"; shift 2 ;;
    *) summary="${summary:+$summary }$1"; shift ;;
  esac
done

case "$action" in
  --fail)
    tip=$(current_tip)
    if [ -z "$tip" ]; then
      echo "lv-deploy-suite-memo: no release ref to record a failure against." >&2
      exit 2
    fi
    if [ -z "$summary" ]; then
      echo "lv-deploy-suite-memo: --fail needs a one-line summary — the failing test," >&2
      echo "  not 'tests failed'. It is what a human reads at the gate." >&2
      exit 2
    fi
    printf 'tip=%s\nat=%s\nsummary=%s\nlog=%s\n' \
      "$tip" "$(wf_now)" "$summary" "$log" > "$MEMO"
    echo "Recorded: origin/release ${tip:0:9} failed the deploy suite — $summary"
    wf_event deploy-suite-failed DEPLOY "${tip:0:9}: $summary"
    ;;

  --clear)
    if [ -f "$MEMO" ]; then
      rm -f "$MEMO"
      echo "Cleared the recorded deploy-suite failure."
    else
      echo "No recorded deploy-suite failure."
    fi
    ;;

  --check|--show)
    if [ ! -f "$MEMO" ]; then
      [ "$action" = "--show" ] && echo "No recorded deploy-suite failure."
      exit 0
    fi
    # shellcheck disable=SC1090
    recorded_tip=$(sed -n 's/^tip=//p' "$MEMO")
    recorded_at=$(sed -n 's/^at=//p' "$MEMO")
    recorded_sum=$(sed -n 's/^summary=//p' "$MEMO")
    recorded_log=$(sed -n 's/^log=//p' "$MEMO")
    tip=$(current_tip)
    if [ "$action" = "--show" ] || [ "$recorded_tip" = "$tip" ]; then
      echo "MEMO_TIP=$recorded_tip"
      echo "MEMO_AT=$recorded_at"
      echo "MEMO_SUMMARY=$recorded_sum"
      echo "MEMO_LOG=$recorded_log"
    fi
    if [ "$action" = "--check" ] && [ -n "$tip" ] && [ "$recorded_tip" = "$tip" ]; then
      echo "origin/release ${tip:0:9} has already failed the deploy suite — do not run it again." >&2
      echo "  The batch cannot pass until something lands on release, which moves this tip." >&2
      exit 1
    fi
    exit 0
    ;;

  *)
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 2 ;;
esac
exit 0
