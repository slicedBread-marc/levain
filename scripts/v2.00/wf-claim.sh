#!/usr/bin/env bash
# wf-claim.sh <artifact> [--pid N] [--if-free] [--steal]
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
#   --list      report every live claim and stop. Reads nothing else and
#               writes nothing — `/wf-claim` opens with it, and it is the one
#               way to see what the write guard is enforcing.
#   --pid N     record N as the owner instead of this session (wf-spawn.sh
#               claims on behalf of the worker it is about to launch)
#   --if-free   do not steal a live claim — exit 2 and print who holds it.
#               A claim written by this caller's own dispatcher (see
#               wf_claim_mine) is not somebody else's: it is refreshed and
#               exits 0, so a dispatched worker never stands down against the
#               claim taken out for it.
#   --steal     take a live claim held by another session, on purpose. Says
#               whose it was, and records it in the event log.
#
# A LIVE CLAIM IS NEVER TAKEN SILENTLY, --if-free OR NOT
#
# --if-free was the flag that respected a claim, and the bare form was the flag
# that ignored one. The skills present the bare form as the attended default, so
# an attended session claiming PLN-059 overwrote the dispatcher's claim file for
# a test worker that was alive and mid-run, printed "Claimed PLN-059" and exited
# 0. Nothing said a claim had been taken from anyone (client-a WFI-146).
#
# That default is backwards: the attended caller is the one who can read a
# message and decide, and the one whose sessions the unattended workers are
# meant to stay out of. So refusing is now the behavior of BOTH forms, and
# taking a live claim requires saying so with --steal. Nothing legitimate is
# blocked — a session's own claim, and a claim its dispatcher wrote on its
# behalf, are recognised as the caller's own by wf_claim_mine and refreshed.
#
# Exit 0 claimed, 1 error, 2 already claimed by ANOTHER live session.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

plan_name=""
pid=""
if_free=false
steal=false
list=false

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)     pid="${2:?--pid requires a number}"; shift 2 ;;
    --if-free) if_free=true; shift ;;
    --steal)   steal=true; shift ;;
    --list)    list=true; shift ;;
    -*)        echo "Unknown option: $1" >&2; exit 1 ;;
    *)         plan_name="$1"; shift ;;
  esac
done

# ── --list ────────────────────────────────────────────────────────────────
#
# Claims are keyed on the artifact NUMBER and live in their own directory, so
# nothing about a claim says which artifact it belongs to — the registry does.
# Resolving the number back to a row is what makes the output readable, and an
# unresolvable number is still reported: a claim on an artifact the registry
# has never heard of is exactly the kind of thing worth seeing.
#
# Liveness is decided by wf_claim_live, which reaps as it reads, so a stale
# claim disappears from this listing and from the write guard together.
if $list; then
  claims_root="$(wf_orch_dir)/claims"
  registry="$(wf_develop_root)/plans/REGISTRY.md"
  found=0
  shopt -s nullglob
  for d in "$claims_root"/*/; do
    wf_claim_live "${d%/}" || continue
    num=$(basename "${d%/}")
    holder=$(sed -n '2p' "${d%/}/.wf-claim" 2>/dev/null | tr -cd '0-9')
    # `|| true` on both halves: this script runs under `set -euo pipefail`, and
    # a grep that matches nothing exits 1 — which pipefail promotes to the
    # pipeline's status and `set -e` turns into a silent exit mid-listing. The
    # no-match case is the one this branch exists to report.
    row=$({ grep -iE "^\| (PLN|BUG|BRF)-0*${num} \|" "$registry" 2>/dev/null || true; } | head -1) || true
    if [ -n "$row" ]; then
      id=$(printf '%s' "$row" | awk -F'|' '{print $2}' | xargs)
      slug=$(printf '%s' "$row" | awk -F'|' '{print $3}' | xargs)
      state=$(printf '%s' "$row" | awk -F'|' '{print $4}' | xargs)
      label="$id-$slug ($state)"
    else
      label="artifact $num (no registry row)"
    fi
    # `if`, not `wf_claim_mine … && mine=…`: under `set -e` a bare `a && b`
    # whose `a` fails carries that failure out as the statement's status.
    mine=""
    if wf_claim_mine "${d%/}"; then mine="  ← yours"; fi
    printf '%-46s PID %-8s %sm%s\n' "$label" "${holder:-?}" "$((WF_CLAIM_AGE / 60))" "$mine"
    found=1
  done
  [ "$found" = "1" ] || echo "No live claims."
  exit 0
fi

[ -n "$plan_name" ] || { echo "Usage: $0 <artifact> [--pid N] [--if-free] [--steal]" >&2; exit 1; }

if $steal && $if_free; then
  echo "Error: --if-free stands down from a live claim and --steal takes one — pick one." >&2
  exit 1
fi

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

if wf_claim_live "$plan_dir"; then
  # A claim this caller's own dispatch wrote is not a competing session — it is
  # this session, held in advance. Refresh it and carry on (WFI-073/075).
  if wf_claim_mine "$plan_dir"; then
    wf_claim_write "$plan_dir" "$pid"
    echo "Claimed $plan_name (already held on your behalf by the dispatcher)"
    exit 0
  fi

  holder=$(sed -n '2p' "$plan_dir/.wf-claim" 2>/dev/null || true)
  held="PID ${holder:-?}, $((WF_CLAIM_AGE / 60))m ago"

  if ! $steal; then
    echo "$plan_name is claimed by a live session ($held)" >&2
    $if_free || {
      echo "Not claiming it. That session is still running: taking the claim would let two workers write one plan." >&2
      echo "If you know it is finished or wedged, take it deliberately: $(basename "$0") $plan_name --steal" >&2
    }
    exit 2
  fi

  wf_event claim-steal "$plan_name" "claim taken from $held"
  echo "Taking $plan_name from a live session ($held) — --steal" >&2
fi

wf_claim_write "$plan_dir" "$pid"
echo "Claimed $plan_name"
