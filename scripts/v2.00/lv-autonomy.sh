#!/usr/bin/env bash
# lv-autonomy.sh <action> [--artifact <ID>] [--quiet] [--check]
# lv-autonomy.sh --show
# lv-autonomy.sh --list
#
# Answers ONE question: has a human recorded standing authorization for <action>
# in this project, and is that authorization still good right now?
#
# It never performs the action. It never writes to the pipeline. It reads
# levain.yml, checks the grant, records that the question was asked,
# and exits. The caller does the work — or doesn't.
#
#   0  authorized      the caller may proceed unattended
#   1  not authorized  the caller must park a gate and stop (reason on stderr)
#   2  usage / the grant is malformed
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
#
# client-a's WFI-159. A user granted standing merge and deploy authorization
# in conversation and asked how to record it. There was nowhere: merges,
# /lv-release, /lv-deploy and the production push sit outside every config
# surface in the harness, because the orchestrator never dispatches them by
# design. The authorization survived only as an instruction to whichever agent
# happened to hear it, and died at the next session boundary.
#
# The reporter also named the failure mode to avoid, and it is the whole reason
# this file is a script and not a key:
#
#   "Adding an unread key to levain.yml would be worse than nothing:
#    it would look load-bearing and be honoured by no script."
#
# So the vocabulary below is CLOSED and validated. `--show` names every entry
# in a project's `standing_for` that nothing reads, rather than ignoring it, and
# exits non-zero — a grant that does not do what its author thinks it does is a
# defect, not a preference.
#
# ── WHAT MAY BE GRANTED, AND WHAT MAY NOT ──────────────────────────────────
#
# Grantable: the three actions with no other config surface, in pipeline order.
# Each is a PROMOTION of work that already passed its gates — not a judgment
# about whether the work is good.
#
#   release           promote develop -> release and run the E2E suite
#   deploy            promote release -> main, locally
#   production-push   push main to the production remote
#
# NOT grantable because it is ALREADY unattended — `merge`. WFI-159 lists
# merges among the decisions the orchestrator refuses to make, and that part of
# the report is wrong: /lv-test's unattended exit path already runs
# `git push -u`, `gh pr create` and `gh pr merge --merge` with no human in the
# loop, and routes a failed merge back to the builder on its own. A `merge` key
# would therefore have been the precise defect the report warns against — one
# that "would look load-bearing and be honoured by no script" — so asking for
# it is exit 2 with that explanation, not a silent no.
#
# Never grantable, hardcoded, not configurable:
#
#   spec-approval     `specApproval.mode: verdict` already automates this, with
#                     maxReviewRounds and gateTags to bound it. Two surfaces for
#                     one decision is how they end up disagreeing.
#   manual-test       `manualTestGate` already governs it, on the surface the
#                     diff touches. Same reason.
#   force-push        the reporter's own line: a user saying "I authorize merges
#   history-rewrite   and deployments" almost certainly does not mean these.
#   claim-steal       taking a live claim is a judgment about another session.
#
# A grant is scoped, dated, attributed and EXPIRING. All four are required
# while `mode: standing`, and a missing one is exit 2, not a default. An
# authorization with no end date is a permission; this is not a permissions
# system, it is a record of something a person said on a particular day.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

GRANTABLE="release deploy production-push"
NEVER="spec-approval manual-test force-push history-rewrite claim-steal"
ALREADY="merge"

# Injectable so expiry is testable without waiting a month.
today="${LV_AUTONOMY_TODAY:-$(date -u +%Y-%m-%d)}"

action=""
artifact=""
quiet=false
record=true
mode="ask"

while [ $# -gt 0 ]; do
  case "$1" in
    --show)     mode="show"; shift ;;
    --list)     mode="list"; shift ;;
    --artifact) artifact="${2:?--artifact requires an ID}"; shift 2 ;;
    --quiet)    quiet=true; shift ;;
    # --check: the same answer, recorded nowhere. Exit codes are identical; the
    # difference is that neither `autonomy-use` nor `autonomy-refuse` is
    # appended, and — because the ceiling counts `autonomy-use` lines — a check
    # therefore does not spend the budget it is asking about.
    #
    # For a caller that wants to know the answer BEFORE committing to the work,
    # which is the dispatcher's case: lv-orchestrate.sh asks this before
    # spawning a release/deploy worker, so a promotion nothing can authorize is
    # never dispatched at all. Asking with the recording form would have been
    # worse than not asking — the dispatcher's probe would consume a grant the
    # worker then needs, and stamp the log with a decision no skill ever acted
    # on. The worker still asks for real when it runs; this is a pre-flight.
    --check)    record=false; shift ;;
    -h|--help)  mode="list"; shift ;;
    -*)         echo "Unknown option: $1" >&2; exit 2 ;;
    *)          if [ -z "$action" ]; then action="$1"; else echo "Unexpected argument: $1" >&2; exit 2; fi; shift ;;
  esac
done

say() { $quiet || printf '%s\n' "$*" >&2; }

in_list() {
  local needle="$1"; shift
  local item
  for item in $*; do [ "$item" = "$needle" ] && return 0; done
  return 1
}

# ── The grant, as recorded ─────────────────────────────────────────────────
cfg_mode=$(wf_cfg orchestrator.autonomy.mode attended)
cfg_by=$(wf_cfg orchestrator.autonomy.granted_by "")
cfg_on=$(wf_cfg orchestrator.autonomy.granted_on "")
cfg_exp=$(wf_cfg orchestrator.autonomy.expires_on "")
cfg_max=$(wf_cfg orchestrator.autonomy.max_per_day 4)
cfg_for=$(wf_cfg_list orchestrator.autonomy.standing_for | tr '\n' ' ')

# ── Unattended by default (coordinator WFI-006) ────────────────────────────────────
#
# `release` (develop → release plus the E2E suite) and `deploy` (release →
# main, LOCALLY) need no grant any more. Neither leaves the machine: a wrong
# local main is undone with `git reset`, and a red suite routes back to the
# builder as it always did. The pipeline is meant to stop for a person only
# when security needs one, and since the permission baseline (WFI-005) that
# security lives in code. `production-push` is the step that reaches users,
# so it still needs a standing grant or a human at its gate.
#
# A project that wants either gate back lists it, with a reason in a comment:
#
#   orchestrator:
#     autonomy:
#       attended_for:
#         - release     # e.g. "E2E suite is slow and shared; batch releases by hand"
#
# The per-action daily ceiling still applies, so a role dispatching in a loop
# is still stopped. It is max_unattended_per_day (default 12), separate from a
# standing grant's max_per_day.
DEFAULT_UNATTENDED="release deploy"
cfg_attended_for=$(wf_cfg_list orchestrator.autonomy.attended_for | tr '\n' ' ')
cfg_max_unattended=$(wf_cfg orchestrator.autonomy.max_unattended_per_day 12)

# ── --list ─────────────────────────────────────────────────────────────────
if [ "$mode" = "list" ]; then
  cat <<EOF
lv-autonomy.sh <action> [--artifact ID]   0 = authorized, 1 = not, 2 = malformed
lv-autonomy.sh <action> --check           same answer, recorded nowhere, spends nothing
lv-autonomy.sh --show                     audit this project's grant

Grantable actions (orchestrator.autonomy.standing_for):
  release           promote develop -> release and run the E2E suite
  deploy            promote release -> main, locally
  production-push   push main to the production remote

Already unattended — granting it would change nothing:
  merge             /lv-test's exit path already pushes, opens the PR and merges it

Never grantable here (each already has its own surface, or is not a promotion):
  spec-approval     use specApproval.mode: verdict
  manual-test       use manualTestGate
  force-push        —
  history-rewrite   —
  claim-steal       —
EOF
  exit 0
fi

# ── Coherence, checked the same way for --show and for a real question ─────
#
# Reported as a list rather than on the first fault: someone fixing a grant
# should need one round trip, not four.
problems=""
note() { problems="${problems:+$problems
}  - $1"; }

for a in $cfg_for; do
  if in_list "$a" "$NEVER"; then
    note "standing_for lists '$a', which is never grantable here — see --list"
  elif in_list "$a" "$ALREADY"; then
    note "standing_for lists '$a', which already runs unattended — the grant changes nothing"
  elif ! in_list "$a" "$GRANTABLE"; then
    note "standing_for lists '$a', which no script reads — it is honoured by nothing"
  fi
done

for a in $cfg_attended_for; do
  in_list "$a" "$DEFAULT_UNATTENDED" \
    || note "attended_for lists '$a' — only '$DEFAULT_UNATTENDED' run unattended by default, so it changes nothing"
done

if [ "$cfg_mode" = "standing" ]; then
  [ -n "$cfg_by" ]  || note "mode is 'standing' but granted_by is empty — a grant needs an author"
  [ -n "$cfg_on" ]  || note "mode is 'standing' but granted_on is empty"
  [ -n "$cfg_exp" ] || note "mode is 'standing' but expires_on is empty — a standing grant must end"
  [ -n "$cfg_for" ] || note "mode is 'standing' but standing_for is empty — it authorizes nothing"
  for d in "$cfg_on:granted_on" "$cfg_exp:expires_on"; do
    v="${d%%:*}"; n="${d##*:}"
    [ -n "$v" ] || continue
    printf '%s' "$v" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
      || note "$n is '$v' — it must be YYYY-MM-DD"
  done
  if [ -n "$cfg_on" ] && [ "$cfg_on" \> "$today" ]; then
    note "granted_on is $cfg_on, which is in the future (today is $today)"
  fi
elif [ "$cfg_mode" != "attended" ]; then
  note "mode is '$cfg_mode' — it must be 'attended' or 'standing'"
fi

# ── --show ─────────────────────────────────────────────────────────────────
if [ "$mode" = "show" ]; then
  echo "autonomy mode:  $cfg_mode"
  if [ "$cfg_mode" = "standing" ]; then
    echo "granted by:     ${cfg_by:-—}"
    echo "granted on:     ${cfg_on:-—}"
    echo "expires on:     ${cfg_exp:-—}$([ -n "$cfg_exp" ] && [ "$cfg_exp" \< "$today" ] && echo '   ← EXPIRED' || true)"
    echo "covers:         ${cfg_for:-—}"
    echo "ceiling:        $cfg_max/day for EACH action above, counted separately"
  fi
  echo "never grantable: $NEVER"
  if [ -n "$problems" ]; then
    echo
    echo "PROBLEMS:"
    printf '%s\n' "$problems"
    exit 2
  fi
  echo
  if [ "$cfg_mode" = "standing" ]; then
    echo "Coherent. Every action above is read by a script."
  else
    echo "Attended: production-push stops for a human. release and deploy run unattended by default (WFI-006)."
  fi
  exit 0
fi

# ── The real question ──────────────────────────────────────────────────────
[ -n "$action" ] || { echo "Usage: $0 <action> [--artifact ID] | --show | --list" >&2; exit 2; }

# An action outside the vocabulary is exit 2, never exit 1. A caller asking
# about something this script has never heard of has a typo or a stale
# instruction, and answering "not authorized" would let that read as a
# deliberate refusal and get worked around.
if ! in_list "$action" "$GRANTABLE"; then
  if in_list "$action" "$NEVER"; then
    say "'$action' is never grantable through autonomy — see lv-autonomy.sh --list"
  elif in_list "$action" "$ALREADY"; then
    say "'$action' already runs unattended — /lv-test's exit path pushes, opens the PR and merges it."
    say "Nothing here gates it, so there is nothing to authorize. Proceed as you already would."
  else
    say "'$action' is not an autonomy action — see lv-autonomy.sh --list"
  fi
  exit 2
fi

if [ -n "$problems" ]; then
  say "The autonomy grant in levain.yml is malformed, so nothing is authorized:"
  $quiet || printf '%s\n' "$problems" >&2
  exit 2
fi

refuse() {
  say "$1"
  # Written as an `if`, not `$record && wf_event`: under `set -e` the latter
  # exits on the false branch, which happens to be right here and would be
  # silently wrong anywhere else.
  if $record; then wf_event autonomy-refuse "${artifact:-—}" "$action: $2"; fi
  exit 1
}

by_default=false
if in_list "$action" "$DEFAULT_UNATTENDED" && ! in_list "$action" "$cfg_attended_for"; then
  by_default=true
fi

if ! $by_default; then
  [ "$cfg_mode" = "standing" ] || \
    refuse "autonomy is 'attended' — $action needs a human. Park a gate and stop." "mode is attended"

  in_list "$action" "$cfg_for" || \
    refuse "the standing grant covers '${cfg_for% }' — not $action. Park a gate and stop." "not in standing_for"

  [ "$cfg_exp" \< "$today" ] && \
    refuse "the standing grant expired on $cfg_exp (today is $today). Ask for a fresh one." "grant expired $cfg_exp"
fi

# ── Ceiling ────────────────────────────────────────────────────────────────
#
# Counted from the event log, per day, PER ACTION. A pipeline that has gone
# wrong can otherwise spend a grant on forty artifacts before anyone looks at
# the board; the ceiling is what keeps the blast radius of a bad grant bounded.
#
# WHY PER ACTION AND NOT ONE SHARED COUNTER
#
# It used to be one counter across all three actions, and that made the
# documented default — 4, described as "a normal day's promotions" — smaller
# than a single day's work. Shipping ONE batch costs three actions: `release`,
# then `deploy`, then `production-push`. So a project with a full standing
# grant got one shipment per day and then jammed, with every subsequent
# promotion parking a gate for a human.
#
# client-c on 2026-09-15 is the whole failure in one log: four
# `autonomy-use` lines ending at 13:37 — one complete shipment plus one
# release — then twelve consecutive `daily ceiling 4 reached` refusals through
# 16:56. Every one of those parked a gate, and each refused worker is the one
# most likely to go off-script and promote anyway (WFI-004, WFI-005, WFI-007,
# WFI-032, WFI-034 were all refused workers). client-d hit the same wall and
# the operator worked around it by raising max_per_day to 20 by hand mid-day,
# which is the tell that the knob was measuring the wrong thing.
#
# Per action, the same default 4 means four shipments a day and still refuses
# the runaway case the ceiling exists for — a role dispatching in a loop burns
# only its own budget, and burning it no longer disarms the other two.
#
# The count matches on the message this script itself writes below, anchored at
# position 1 so `release` never matches a `production-push` line. Historical
# lines carry the same wording, so an existing log counts correctly.
log="$(wf_orch_dir)/events.log"
used=0
if [ -f "$log" ]; then
  used=$(awk -F'\t' -v d="$today" -v a="$action" '
    $1 ~ "^" d "T" && $2 == "autonomy-use" && index($4, a " authorized") == 1 { n++ }
    END { print n + 0 }' "$log" 2>/dev/null || true)
  used=${used:-0}
fi
if $by_default; then
  if [ "$used" -ge "$cfg_max_unattended" ]; then
    refuse "the unattended ceiling of $cfg_max_unattended $action(s)/day is spent ($used used today). Park a gate and stop." \
           "daily $action ceiling $cfg_max_unattended reached"
  fi
  if $record; then
    wf_event autonomy-use "${artifact:-—}" \
      "$action authorized by default (unattended since WFI-006) — $((used + 1))/$cfg_max_unattended $action today"
  fi
  say "$action authorized — unattended by default ($((used + 1))/$cfg_max_unattended $action today)."
  exit 0
fi

if [ "$used" -ge "$cfg_max" ]; then
  refuse "the standing grant's ceiling of $cfg_max $action(s)/day is spent ($used used today). Park a gate and stop." \
         "daily $action ceiling $cfg_max reached"
fi

if $record; then
  wf_event autonomy-use "${artifact:-—}" \
    "$action authorized by standing grant from ${cfg_by:-unknown} ($cfg_on, expires $cfg_exp) — $((used + 1))/$cfg_max $action today"
fi
say "$action authorized — standing grant from ${cfg_by:-unknown}, expires $cfg_exp ($((used + 1))/$cfg_max $action today)."
exit 0
