#!/usr/bin/env bash
# lv-list-consistency.sh [plan-id]
#
# Plans that are `ready`, declare Deps, and have not had a cross-plan
# consistency pass yet — and plans WAITING AT SPEC-APPROVAL (draft, the gate
# open) whose Deps are not all complete (LVI-033).
#
# The second set is new. A pass that runs only at `ready` runs after a human
# has approved the plan, so the approval was given without anyone having
# checked the plan against what it consumes. A client's PLN-028 sat at
# spec-approval specced on an allow-list its upstream had just been told to
# drop; a pass at `ready` would have found it only after a human approved it.
# The goal column starts `at spec-approval —` for these, which is how
# lv-consistency knows to route a finding against the plan itself as a
# withdrawal of the question rather than an amendment.
#
# Format: <plan-name>\t<deps>\t<goal>
# Exit 0 if any found, 1 if none.
#
# Why this role exists: no role owns the contract BETWEEN plans. Every review
# is scoped to one plan, so two plans can each be correct alone and contradict
# each other — one program specified a forward-paging list API in PLN-003 while
# PLN-007 needed to page backward, and both reviews passed on the point. It was
# caught only because one attending agent happened to hold both plans in
# context, and the fix was possible only because the dependency was still
# unbuilt. Two plans faster and it would have been a shipped API and a
# migration.
#
# The done-marker is a `## Consistency` section in plan.md carrying a
# `> **Checked:** <ISO date>` line — committed with the plan, so it survives a
# restart and never re-runs on work that has not changed. Work that HAS
# changed — this plan or any plan in its closure, since the commit that wrote
# the entry — makes it outstanding again, and the goal column says so.
#
# The DATE is load-bearing, not decoration. The marker used to be any line
# beginning `> **Checked:**`, and the plan template ships that section
# pre-filled with the placeholder `> **Checked:** YYYY-MM-DD`. So every plan
# created from the template was born already-checked and this script never
# returned a single candidate: client-a's PLN-010 declared five Deps and
# went draft → ready → active → verify without a consistency pass ever being
# dispatched, and no commit mentioning one exists anywhere in its history
# (WFI-108). A placeholder cannot satisfy the marker any more.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "lv-list-consistency: $REGISTRY not found" >&2; exit 1; }

want="${1:-}"
want=$(printf '%s' "$want" | grep -oE "($LV_PLN_RE)-[0-9]+" || true)

found=0

# closure_moved <id> <plan.md> <checked-line> — prints the plans (this one and
# its closure) whose body changed since the commit that wrote <checked-line>,
# space-separated; nothing when the check still describes the closure.
#
# A `## Consistency` entry is a verdict on the closure as it stood when it was
# written. A client's LVI-028: PLN-043 gained an amendment changing two files
# both PLN-044 and PLN-045 consume, and both still listed as done — the pass
# they carried was against plans that no longer existed, and the operator had
# to ask for the re-run by hand. So compare each plan's body fingerprint (the
# one spec-approval staleness uses: Review, Consistency and ticks excluded) at
# that commit against now. An entry git never saw committed cannot be dated,
# and is taken at its word — the skill commits it before it unclaims.
# A deferral ticks a criterion and appends its DC id. The tick is already
# ignored by the fingerprint; the suffix is not, and a dependency deferring a
# criterion at test time has not changed a contract anyone consumes.
body_of() { sed -E 's/ — deferred as [A-Za-z]+-[0-9]+//' | wf_plan_body_hash; }

closure_moved() {
  local id="$1" file="$2" line="$3" at moved="" cid cslug cfile then now
  at=$(git log -1 --format=%H -S"$line" -- "$file" 2>/dev/null || true)
  [ -n "$at" ] || return 0
  while IFS=$'\t' read -r cid cslug _; do
    [ -n "$cid" ] || continue
    cfile="plans/${cid}-${cslug}/plan.md"
    [ -f "$cfile" ] || continue
    then=$(git show "$at:$cfile" 2>/dev/null | body_of || true)
    now=$(body_of < "$cfile")
    [ "$then" = "$now" ] || moved="$moved${moved:+ }$cid"
  done < <("$(dirname "$0")/lv-list-closure.sh" "$id" --include-self 2>/dev/null || true)
  printf '%s' "$moved"
}

while IFS=$'\037' read -r id slug state _priority _branch _updated _wf _tags deps; do
  [ -n "$want" ] && [ "$id" != "$want" ] && continue

  # No declared dependencies → nothing between-plan to check.
  case "$deps" in ""|"—"|"-") continue ;; esac

  at_approval=""
  case "$state" in
    ready) ;;
    draft)
      # Only while its approval is being asked, and only while something it
      # depends on is still a document: against complete Deps the check at
      # `ready` (and the build) is soon enough.
      gf=$(wf_gate_file "$id" || true)
      [ -f "$gf" ] && [ "$(wf_gate_field "$gf" GATE_NAME)" = "spec-approval" ] || continue
      wf_blocking_deps "$deps" "$REGISTRY" >/dev/null || continue
      at_approval="at spec-approval — "
      ;;
    *) continue ;;
  esac

  plan_file="plans/${id}-${slug}/plan.md"
  [ -f "$plan_file" ] || continue

  # Already checked at its current revision. A real ISO date only — the
  # template's `YYYY-MM-DD` placeholder is not a pass that ran.
  checked=$(grep -E '^> \*\*Checked:\*\* *[0-9]{4}-[0-9]{2}-[0-9]{2}' "$plan_file" 2>/dev/null | tail -1 || true)
  if [ -n "$checked" ]; then
    stale=$(closure_moved "$id" "$plan_file" "$checked")
    [ -n "$stale" ] || continue
    reason="re-check: amended since the last pass — $stale"
  else
    reason=""
  fi

  goal=$(wf_goal_text "$plan_file")
  printf "%s\t%s\t%s\n" "${id}-${slug}" "$deps" "${at_approval}${reason:+$reason — }$goal"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
