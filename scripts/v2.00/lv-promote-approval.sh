#!/usr/bin/env bash
# lv-promote-approval.sh <release|deploy|deferred|push>
#
# Did a human already approve THIS promotion at a gate?
#
#   release   develop -> release, at `release-approval`
#   deploy    release -> main, at `deploy-approval`
#   deferred  release -> main WITH open deferred criteria, at
#             `deploy-deferred-criteria` — /lv-deploy step 4a. Without it that
#             step had no way to read its own answer: every unattended dispatch
#             re-ran lv-deferred-check.sh, got the same exit 1, and re-opened
#             the gate a human had already answered. That is client-b WFI-005's
#             loop in a second place, found by client-a WFI-260.
#   push      local main -> origin/main, at `production-push` — /lv-deploy
#             step 14, when no standing `production-push` grant exists. Scoped
#             to local main's tip: the approval covers exactly the commit the
#             push would send (coordinator WFI-008).
#
#             Also authorized, when nothing above is: an approve of
#             `deploy-deferred-criteria` or `deploy-approval` opened with
#             --covers-push, while main contains that approval's release tip
#             and main's code (plans/ and bugs/ aside — the deploy's own
#             bookkeeping) is exactly that tip's, and main fast-forwards
#             origin/main. The human approved shipping that code, and was told
#             in the question that approving pushes it. A later batch changes
#             main's code and lapses it; a rejected production-push for this
#             tip still wins. A client's LVI-041: every deploy asked promote
#             and push as two gates, and re-asked both each time a ref moved.
#
# WHY THIS EXISTS
#
# `lv-autonomy.sh` answers a different question: has this project written down a
# STANDING grant that lets the harness promote unattended? A one-off "yes, ship
# this batch" given at a `release-approval` gate is not that, and until this
# script existed it had nowhere to go. client-b WFI-005: a human answered the
# release gate through /lv-attend at 19:25:49Z, the daemon dispatched
# /lv-release a minute later, that run asked lv-autonomy.sh, was told no, and
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
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

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
  push)     id=DEPLOY;  gate=production-push ;;
  *)
    echo "Usage: $0 <release|deploy|deferred|push> [--quiet]" >&2
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

# ── push: an approved promotion that said it covered the push ─────────────
covered_push() {
  local root main origin_main g rec tip rej_rec
  root="$(wf_develop_root)"
  main=$(wf_promote_tip production-push || true)
  [ -n "$main" ] || return 1
  rej_rec=$(wf_gate_resolved_file DEPLOY production-push || true)
  if [ -n "$rej_rec" ] && [ -f "$rej_rec" ] \
     && [ "$(wf_gate_field "$rej_rec" GATE_PROMOTE_TIP)" = "$main" ] \
     && [ "$(wf_gate_field "$rej_rec" GATE_DECISION)" != "approve" ]; then
    return 1
  fi
  origin_main=$(git -C "$root" rev-parse --verify -q refs/remotes/origin/main 2>/dev/null || true)
  if [ -n "$origin_main" ]; then
    git -C "$root" merge-base --is-ancestor "$origin_main" "$main" 2>/dev/null || return 1
  fi
  for g in deploy-deferred-criteria deploy-approval; do
    rec=$(wf_gate_resolved_file DEPLOY "$g" || true)
    [ -n "$rec" ] && [ -f "$rec" ] || continue
    [ "$(wf_gate_field "$rec" GATE_DECISION)" = "approve" ] || continue
    [ "$(wf_gate_field "$rec" GATE_COVERS_PUSH)" = "true" ] || continue
    tip=$(wf_gate_field "$rec" GATE_PROMOTE_TIP)
    [ -n "$tip" ] || continue
    git -C "$root" merge-base --is-ancestor "$tip" "$main" 2>/dev/null || continue
    git -C "$root" diff --quiet "$tip" "$main" -- . ':(exclude)plans' ':(exclude)bugs' 2>/dev/null || continue
    say "DEPLOY: '$g' approved$(r=$(wf_gate_field "$rec" GATE_RESOLVED); [ -n "$r" ] && printf ' at %s' "$r") for release ${tip:0:9} with --covers-push,"
    say "  and main ${main:0:9} carries exactly that code — push authorized."
    return 0
  done
  return 1
}
deny() {
  if [ "$action" = push ] && covered_push; then exit 0; fi
  exit "$1"
}

record=$(wf_gate_resolved_file "$id" "$gate" || true)
if [ -z "$record" ] || [ ! -f "$record" ]; then
  say "$id: no '$gate' answer of record — not authorized."
  deny 1
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
  deny 1
fi

if [ -z "$approved_tip" ]; then
  # Approved, but against nothing identifiable. Refusing here rather than
  # assuming is the whole point: the alternative is promoting an unknown batch
  # on the strength of an approval given for some other one.
  say "$id: '$gate' was approved${resolved_at:+ at $resolved_at}, but the record names no commit set."
  say "  Nothing can say whether that approval covers what is staged now — not authorized."
  deny 1
fi

now_tip=$(wf_promote_tip "$gate" || true)
if [ -z "$now_tip" ]; then
  say "$id: cannot resolve the current $(wf_promote_tip_ref "$gate") tip — not authorized."
  deny 1
fi

if [ "$now_tip" != "$approved_tip" ]; then
  say "$id: '$gate' was approved${resolved_at:+ at $resolved_at} for $(wf_promote_tip_ref "$gate") at ${approved_tip:0:9},"
  say "  which is now at ${now_tip:0:9}. The batch has changed since the answer — ask again."
  deny 2
fi

say "$id: '$gate' approved${resolved_at:+ at $resolved_at} by ${resolved_basis:-—} for $(wf_promote_tip_ref "$gate") ${approved_tip:0:9} — authorized."
say "  resolution: ${resolution:-—}"
exit 0
