#!/usr/bin/env bash
# wf-claim.sh <plan-name> [--pid N] [--if-free]
# Marks a plan as actively being worked on by writing a timestamp + PID.
# Claim file: plans/<plan-name>/.wf-claim  (line 1: timestamp, line 2: PID)
# Other terminals see this as "processing" in list scripts.
# Claims expire when the owning process dies or after 2 hours (7200 seconds).
#
#   --pid N     record N as the owner instead of this session (wf-spawn.sh
#               claims on behalf of the worker it is about to launch)
#   --if-free   do not steal a live claim — exit 2 and print who holds it
#
# Exit 0 claimed, 1 error, 2 already claimed by a live session (--if-free only).

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

[ -n "$plan_name" ] || { echo "Usage: $0 <plan-name> [--pid N] [--if-free]" >&2; exit 1; }

# Always resolve to the develop root (first worktree) so the claim is visible
# to list scripts regardless of whether this runs from develop or a feature worktree.
plan_dir="$(wf_develop_root)/plans/${plan_name}"

if [ ! -d "$plan_dir" ]; then
  echo "Error: plan directory not found: $plan_dir" >&2
  exit 1
fi

if $if_free && wf_claim_live "$plan_dir"; then
  holder=$(sed -n '2p' "$plan_dir/.wf-claim" 2>/dev/null || true)
  echo "$plan_name is claimed by a live session (PID ${holder:-?}, $((WF_CLAIM_AGE / 60))m ago)" >&2
  exit 2
fi

wf_claim_write "$plan_dir" "$pid"
echo "Claimed $plan_name"
