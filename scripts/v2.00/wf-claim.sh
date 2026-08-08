#!/usr/bin/env bash
# wf-claim.sh <artifact> [--pid N] [--if-free]
# Marks an artifact as actively being worked on by writing a timestamp + PID.
# Claim file: .claude/orchestrator/claims/<NNN>/.wf-claim
#             (line 1: timestamp, line 2: PID)
# Other terminals see this as "processing" in list scripts.
#
# <artifact> is any of PLN-NNN, PLN-NNN-slug, BUG-NNN, BRF-NNN. The claim keys
# on the NUMBER, so a brief and the plan it becomes share one claim and a spec
# worker can claim before the plan folder exists (WFI-004).
# Claims expire when the owning process dies or after 2 hours (7200 seconds).
#
#   --pid N     record N as the owner instead of this session (wf-spawn.sh
#               claims on behalf of the worker it is about to launch)
#   --if-free   do not steal a live claim — exit 2 and print who holds it.
#               A claim written by this caller's own dispatcher (see
#               wf_claim_mine) is not somebody else's: it is refreshed and
#               exits 0, so a dispatched worker never stands down against the
#               claim taken out for it.
#
# Exit 0 claimed, 1 error, 2 already claimed by ANOTHER live session (--if-free).

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

plan_name=""
pid=""
if_free=false

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)     pid="${2:?--pid requires a number}"; shift 2 ;;
    --if-free) if_free=true; shift ;;
    -*)        echo "Unknown option: $1" >&2; exit 1 ;;
    *)         plan_name="$1"; shift ;;
  esac
done

[ -n "$plan_name" ] || { echo "Usage: $0 <artifact> [--pid N] [--if-free]" >&2; exit 1; }

# Always resolve to the develop root (first worktree) so the claim is visible
# to list scripts regardless of whether this runs from develop or a feature worktree.
if ! plan_dir=$(wf_claim_dir "$plan_name"); then
  echo "Error: '$plan_name' carries no PLN/BUG/BRF id" >&2
  exit 1
fi

# A pre-v5.6 claim still in the plan folder belongs to a live worker that has
# not been restarted yet. Honour it, and adopt it into the canonical location
# so one release cycle is enough to retire the old path.
legacy_dir="$(wf_develop_root)/plans/${plan_name}"
if [ -d "$legacy_dir" ] && [ -f "$legacy_dir/.wf-claim" ] && [ ! -f "$plan_dir/.wf-claim" ]; then
  mv "$legacy_dir/.wf-claim" "$plan_dir/.wf-claim" 2>/dev/null || true
fi

if $if_free && wf_claim_live "$plan_dir"; then
  # A claim this caller's own dispatch wrote is not a competing session — it is
  # this session, held in advance. Refresh it and carry on (WFI-073/075).
  if wf_claim_mine "$plan_dir"; then
    wf_claim_write "$plan_dir" "$pid"
    echo "Claimed $plan_name (already held on your behalf by the dispatcher)"
    exit 0
  fi
  holder=$(sed -n '2p' "$plan_dir/.wf-claim" 2>/dev/null || true)
  echo "$plan_name is claimed by a live session (PID ${holder:-?}, $((WF_CLAIM_AGE / 60))m ago)" >&2
  exit 2
fi

wf_claim_write "$plan_dir" "$pid"
echo "Claimed $plan_name"
