#!/usr/bin/env bash
# wf-promote-approval.sh <release|deploy|deferred>
#
# Did a human already approve THIS promotion at a gate?
#
#   release   develop -> release, at `release-approval`
#   deploy    release -> main, at `deploy-approval`
#   deferred  release -> main WITH open deferred criteria, at
#             `deploy-deferred-criteria` — /wf-deploy step 4a. Without it that
#             step had no way to read its own answer: every unattended dispatch
#             re-ran wf-deferred-check.sh, got the same exit 1, and re-opened
#             the gate a human had already answered. That is client-b WFI-005's
#             loop in a second place, found by client-a WFI-260.
#
# WHY THIS EXISTS
#
# `wf-autonomy.sh` answers a different question: has this project written down a
# STANDING grant that lets the harness promote unattended? A one-off "yes, ship
# this batch" given at a `release-approval` gate is not that, and until this
# script existed it had nowhere to go. client-b WFI-005: a human answered the
# release gate through /wf-attend at 19:25:49Z, the daemon dispatched
# /wf-release a minute later, that run asked wf-autonomy.sh, was told no, and
# re-opened the gate it had just been let through. Then again at 19:35. Each
# re-opening quoted a longer commit list, so gate dedup saw a new question every
# time and the loop had no end — the answer was in the ledger, and nothing on
# the path from the answer to the merge could read it.
#
# The approval is scoped to the commit set it was given for. `develop` moving on
# means the human approved a batch that is no longer the batch in front of us,
# and the gate should genuinely re-open. That is the same principle as a spec
# approval lapsing when the plan text changes; the source branch's tip is a
# promotion's revision.
#
# This script NEVER promotes anything and never writes. It reads the resolved
# gate ledger and answers.
#
#   Exit 0  approved, and the approval covers the promotion as it stands now
#   Exit 1  no approval of record (never asked, answered without --decision,
#           rejected, or a gate of this name is open right now and unanswered)
#   Exit 2  an approval exists, but the source branch has moved since — the
#           batch it covered is not this batch. Ask again.
#
# Exit 1 and exit 2 are both "not authorized". They are separated because the
# caller can say something useful about 2 in the gate question it goes on to
# open, and because an operator reading a log deserves to know the difference
# between "nobody answered" and "the answer aged out".

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

quiet=false
action=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) quiet=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) action="$1"; shift ;;
  esac
done

say() { $quiet || echo "$@"; }

case "$action" in
  release)  id=RELEASE; gate=release-approval ;;
  deploy)   id=DEPLOY;  gate=deploy-approval ;;
  deferred) id=DEPLOY;  gate=deploy-deferred-criteria ;;
  *)
    echo "Usage: $0 <release|deploy|deferred> [--quiet]" >&2
    exit 1 ;;
esac

# An open gate of this name is an unanswered question, whatever the ledger holds
# from a previous cycle. Checked first, so a stale record can never speak for a
# question still parked in front of a human.
gate_file=$(wf_gate_file "$id" || true)
if [ -f "$gate_file" ] && [ "$(wf_gate_field "$gate_file" GATE_NAME)" = "$gate" ]; then
  say "$id: '$gate' is open and unanswered — not authorized."
  exit 1
fi

record=$(wf_gate_resolved_file "$id" "$gate" || true)
if [ -z "$record" ] || [ ! -f "$record" ]; then
  say "$id: no '$gate' answer of record — not authorized."
  exit 1
fi

decision=$(wf_gate_field "$record" GATE_DECISION)
resolution=$(wf_gate_field "$record" GATE_RESOLUTION --unescape)
resolved_at=$(wf_gate_field "$record" GATE_RESOLVED)
resolved_basis=$(wf_gate_field "$record" GATE_RESOLVED_BASIS)
approved_tip=$(wf_gate_field "$record" GATE_PROMOTE_TIP)

if [ "$decision" != "approve" ]; then
  if [ -n "$decision" ]; then
    say "$id: '$gate' was answered '$decision'${resolved_at:+ at $resolved_at} — not authorized."
  else
    # The common case for a record written before --decision existed, and for a
    # close that forgot it. Both are the same thing to a worker: no answer it
    # can act on. Saying which one it is saves the reader a trip to the ledger.
    say "$id: '$gate' was closed${resolved_at:+ at $resolved_at} with no recorded decision — not authorized."
    say "  resolution: ${resolution:-—}"
    say "  A resolution is prose; the authorization is --decision approve on the close."
  fi
  exit 1
fi

if [ -z "$approved_tip" ]; then
  # Approved, but against nothing identifiable. Refusing here rather than
  # assuming is the whole point: the alternative is promoting an unknown batch
  # on the strength of an approval given for some other one.
  say "$id: '$gate' was approved${resolved_at:+ at $resolved_at}, but the record names no commit set."
  say "  Nothing can say whether that approval covers what is staged now — not authorized."
  exit 1
fi

now_tip=$(wf_promote_tip "$gate" || true)
if [ -z "$now_tip" ]; then
  say "$id: cannot resolve the current $(wf_promote_tip_ref "$gate") tip — not authorized."
  exit 1
fi

if [ "$now_tip" != "$approved_tip" ]; then
  say "$id: '$gate' was approved${resolved_at:+ at $resolved_at} for $(wf_promote_tip_ref "$gate") at ${approved_tip:0:9},"
  say "  which is now at ${now_tip:0:9}. The batch has changed since the answer — ask again."
  exit 2
fi

say "$id: '$gate' approved${resolved_at:+ at $resolved_at} by ${resolved_basis:-—} for $(wf_promote_tip_ref "$gate") ${approved_tip:0:9} — authorized."
say "  resolution: ${resolution:-—}"
exit 0
