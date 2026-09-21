#!/usr/bin/env bash
# wf-claim.sh <artifact> [--pid N] [--if-free] [--steal] [--state s[,s...]]
# Marks an artifact as actively being worked on by writing a timestamp + PID.
# Claim file: .claude/orchestrator/claims/<NNN>/.wf-claim
#             (line 1: timestamp, line 2: PID, line 3: the artifact as named)
# Other terminals see this as "processing" in list scripts.
#
# <artifact> is any of PLN-NNN, PLN-NNN-slug, BUG-NNN, BRF-NNN. The claim keys
# on the NUMBER, so a brief and the plan it becomes share one claim and a spec
# worker can claim before the plan folder exists (WFI-004).
# Claims expire when the owning process dies, or after 2 hours (7200 seconds)
# if the harness cannot prove the owner is still running. An owner that IS
# provably still running — same PID, same start time — keeps its claim past
# the TTL and is reported as `overdue` by --list, because reaping the claim of
# a session that is sitting there working is how a deliberate park evaporates
# (client-b WFI-015). See wf_claim_live in wf-orch-lib.sh.
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
#   --state s[,s...]
#               claim only if this artifact's plan is in one of these registry
#               states. Exit 3 otherwise, having claimed nothing.
#
# WHY --state EXISTS
#
# A dispatch is a statement about the registry at the moment it was read, and a
# worker acts on it some time later. client-a's WFI-153: a wf-verify worker
# was handed PLN-078 whose state was already `complete` — verify, human test,
# PR merge and the bug close were all committed before it started. It claimed
# the plan, saw the state, and stood down by judgement. The next one might not:
# a verify that runs to completion routes on its findings, and routing a
# `complete` plan sends it back to `testing`.
#
# So the precondition belongs at the claim, which every role already calls
# before it touches anything, and which is the last point where standing down
# is free. Nothing is claimed on a refusal.
#
# The check is only made when a PLN row for that NUMBER exists. A spec worker
# legitimately claims BUG-096 or BRF-041 before any plan does, and a claim keys
# on the number precisely so that it covers the brief and the plan it becomes.
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
# Exit 0 claimed, 1 error, 2 already claimed by ANOTHER live session,
#        3 the plan is not in a state this caller asked for (--state).

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

plan_name=""
pid=""
if_free=false
steal=false
list=false
want_states=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pid)     pid="${2:?--pid requires a number}"; shift 2 ;;
    --if-free) if_free=true; shift ;;
    --steal)   steal=true; shift ;;
    --list)    list=true; shift ;;
    --state)   want_states="${2:?--state requires a comma-separated state list}"; shift 2 ;;
    -*) wf_bad_option "$1" ;;
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
    # Line 3 is the artifact AS THE HOLDER NAMED IT (wf_claim_write). Absent on
    # a claim written by an older client, which is why everything below still
    # resolves the number independently.
    asked=$(sed -n '3p' "${d%/}/.wf-claim" 2>/dev/null | tr -d '\r' || true)
    # `|| true` on both halves: this script runs under `set -euo pipefail`, and
    # a grep that matches nothing exits 1 — which pipefail promotes to the
    # pipeline's status and `set -e` turns into a silent exit mid-listing. The
    # no-match case is the one this branch exists to report.
    # EVERY row for this number, not the first.
    #
    # A claim keys on the number because a brief and the plan it becomes are
    # one piece of work (WFI-004), and that holds only while the number is
    # unique across types — which CLAUDE.md says it is and a client's registry
    # is not obliged to be. client-a had BRF-210 (an ergonomics spec, held
    # at Exploring) and PLN-210 (publish-path-reports-elision, complete and
    # closed in August) as unrelated artifacts sharing one number. Claiming the
    # brief printed the listing as "PLN-210-publish-path-reports-elision
    # (complete)" — a `grep | head -1` resolving to whichever row came first —
    # so the claim reported work it had nothing to do with, and a worker
    # claiming the plan would have blocked the brief with no message naming it
    # (WFI-215).
    #
    # Nothing here can decide which one the holder meant. What it can do is
    # stop presenting a guess as the answer.
    rows=$({ grep -iE "^\| (PLN|BUG|BRF)-0*${num} \|" "$registry" 2>/dev/null || true; }) || true
    n_rows=$(printf '%s' "$rows" | grep -c . || true)
    if [ "${n_rows:-0}" -gt 1 ]; then
      label=$(printf '%s\n' "$rows" | awk -F'|' '{
        gsub(/^[ \t]+|[ \t]+$/, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $4)
        printf "%s%s (%s)", (NR > 1 ? " + " : ""), $2, $4
      }')
      label="artifact $num — AMBIGUOUS: $label"
    elif [ -n "$rows" ]; then
      row=$(printf '%s\n' "$rows" | head -1)
      id=$(printf '%s' "$row" | awk -F'|' '{print $2}' | xargs)
      slug=$(printf '%s' "$row" | awk -F'|' '{print $3}' | xargs)
      state=$(printf '%s' "$row" | awk -F'|' '{print $4}' | xargs)
      label="$id-$slug ($state)"
    else
      label="artifact $num (no registry row)"
    fi

    # What was CLAIMED, next to what the number resolves to. The reporter's own
    # ask, and the cheap half of the fix: the collision was visible at all only
    # because --list happened to print the resolved name, and the two disagreed
    # in a way nobody could see side by side (WFI-215).
    if [ -n "$asked" ] && [ "$asked" != "${label%% *}" ]; then
      label="$asked → $label"
    fi

    # `if`, not `wf_claim_mine … && mine=…`: under `set -e` a bare `a && b`
    # whose `a` fails carries that failure out as the statement's status.
    mine=""
    if wf_claim_mine "${d%/}"; then mine="  ← yours"; fi
    # An overdue claim is a live one the TTL would once have reaped out from
    # under its owner. It is legitimate — the owner is provably the process
    # that took it — but a claim held this long is worth a human deciding
    # whether the work is still happening, so it is never merely silent.
    overdue=""
    if [ "${WF_CLAIM_OVERDUE:-0}" = "1" ]; then overdue="  ⚠ overdue (owner alive)"; fi
    printf '%-56s PID %-8s %sm%s%s\n' "$label" "${holder:-?}" "$((WF_CLAIM_AGE / 60))" "$overdue" "$mine"
    found=1
  done
  [ "$found" = "1" ] || echo "No live claims."
  exit 0
fi

[ -n "$plan_name" ] || { echo "Usage: $0 <artifact> [--pid N] [--if-free] [--steal] [--state s[,s...]]" >&2; exit 1; }

if $steal && $if_free; then
  echo "Error: --if-free stands down from a live claim and --steal takes one — pick one." >&2
  exit 1
fi

# ── --state: the precondition, checked before anything is claimed ─────────
#
# Matched on the artifact NUMBER, like the claim itself, so `PLN-078`,
# `PLN-078-login-secret-entry` and `78` all find the same row.
if [ -n "$want_states" ]; then
  num=$(printf '%s' "$plan_name" | grep -oE '[0-9]+' | head -1 || true)
  if [ -n "$num" ]; then
    registry="$(wf_develop_root)/plans/REGISTRY.md"
    row=$({ grep -iE "^\| PLN-0*${num} \|" "$registry" 2>/dev/null || true; } | head -1)
    if [ -n "$row" ]; then
      cur_state=$(printf '%s' "$row" | awk -F'|' '{print $4}' | xargs)
      cur_id=$(printf '%s' "$row" | awk -F'|' '{print $2}' | xargs)
      match=false
      # Commas to spaces, then a whole-word test — so `--state ready` does not
      # match `already` and `--state verify` does not match a caller's typo.
      for s in ${want_states//,/ }; do
        [ "$s" = "$cur_state" ] && { match=true; break; }
      done
      if ! $match; then
        echo "$cur_id is '$cur_state', not ${want_states//,/ or } — nothing claimed." >&2
        echo "The work this run was dispatched for has already been done or moved on (WFI-153)." >&2
        echo "Stop here. Do not act on the plan; the dispatcher offers it again if it comes back." >&2
        exit 3
      fi
    fi
  fi
fi

# ── Is this number one artifact, or two? ──────────────────────────────────
#
# The claim keys on the NUMBER so that a brief and the plan it becomes share
# one lock (WFI-004), and that is right exactly while a number names one piece
# of work. client-a had BRF-210 and PLN-210 as unrelated artifacts: claiming
# the brief silently locked a completed plan, and a worker claiming the plan
# would have blocked the brief with nothing in the message naming it (WFI-215).
#
# Not a refusal — the shared key is the design, and no artifact is ever safer
# for being unclaimable. But the holder is entitled to know that the lock they
# just took covers something else as well, at the moment they take it.
_claim_num=$(printf '%s' "$plan_name" | grep -oE '[0-9]+' | head -1 || true)
if [ -n "$_claim_num" ]; then
  # `|| true` on the whole pipeline: under `set -o pipefail` the sort finding
  # nothing to read — an unused number — would fail it, and `set -e` turns that
  # into a claim that silently never happens.
  _kinds=$({ wf_artifacts_with_number "$_claim_num" \
             | awk '{print $1}' | sort -u | tr '\n' ' '; } || true)
  if [ "$(printf '%s' "$_kinds" | wc -w | xargs)" -gt 1 ]; then
    # Is this INHERITANCE or a collision?
    #
    # A plan inherits its number from the bug or brief it consumed — BUG-043
    # becomes PLN-043 — and wf-spec mandates it. So a number naming a BUG and a
    # PLN is the ordinary designed case, and telling its holder that numbers
    # "are meant to be globally unique across types" reported the design as a
    # violation and sent them to an audit tool over a non-problem (WFI-234).
    # WFI-215's real fault was different: BRF-210 and PLN-210 were UNRELATED,
    # so one lock covered two separate pieces of work with nothing to say so.
    #
    # The plan's own Goal is what separates them. A plan that inherited says so
    # — `**Bug:** BUG-NNN` / `**Brief:** BRF-NNN` — and a plan that merely
    # collided does not. The first two lines are true either way and stay.
    _claim_inherited=false
    for _p in "$(wf_develop_root)"/plans/PLN-*"${_claim_num}"*/plan.md; do
      [ -f "$_p" ] || continue
      case "$(basename "$(dirname "$_p")")" in
        PLN-"$_claim_num"-*|PLN-"$_claim_num") ;;
        *) continue ;;
      esac
      # Real plan.md writes this as a blockquote ('> **Brief:** ...'), and the
      # Brief value is a file path ('briefs/BRF-NNN-slug.md'), not a bare
      # token — so the id can appear anywhere after the label, not only right
      # after the colon (WFI-248, WFI-246, WFI-009, WFI-007).
      if grep -qE "^>?[[:space:]]*\*\*(Bug|Brief):\*\*.*\b(BUG|BRF)-0*${_claim_num#0}\b" "$_p" 2>/dev/null; then
        _claim_inherited=true
      fi
      break
    done
    echo "Note: artifact number $_claim_num names more than one thing here — ${_kinds% }." >&2
    echo "      Claims key on the number, so this one lock covers all of them (WFI-215)." >&2
    if $_claim_inherited; then
      echo "      That is the designed case: the plan inherited this number from the artifact it" >&2
      echo "      consumed, and one lock covering both is the point. Nothing to do." >&2
    else
      echo "      These do not appear to be the same work — no plan here names the other as its" >&2
      echo "      source. Numbers are meant to be globally unique; run wf-registry-audit.sh." >&2
    fi
    unset _claim_inherited _p
  fi
fi
unset _claim_num _kinds

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
    wf_claim_write "$plan_dir" "$pid" "$plan_name"
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

wf_claim_write "$plan_dir" "$pid" "$plan_name"
echo "Claimed $plan_name"
