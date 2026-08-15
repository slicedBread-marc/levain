#!/usr/bin/env bash
# wf-list-consistency.sh [plan-id]
#
# Plans that are `ready`, declare Deps, and have not had a cross-plan
# consistency pass yet.
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
# restart and never re-runs on work that has not changed.
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

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "wf-list-consistency: $REGISTRY not found" >&2; exit 1; }

want="${1:-}"
want=$(printf '%s' "$want" | grep -oE 'PLN-[0-9]+' || true)

found=0

while IFS=$'\037' read -r id slug state _priority _branch _updated _wf _tags deps; do
  [ "$state" = "ready" ] || continue
  [ -n "$want" ] && [ "$id" != "$want" ] && continue

  # No declared dependencies → nothing between-plan to check.
  case "$deps" in ""|"—"|"-") continue ;; esac

  plan_file="plans/${id}-${slug}/plan.md"
  [ -f "$plan_file" ] || continue

  # Already checked at its current revision. A real ISO date only — the
  # template's `YYYY-MM-DD` placeholder is not a pass that ran.
  grep -qE '^> \*\*Checked:\*\* *[0-9]{4}-[0-9]{2}-[0-9]{2}' "$plan_file" 2>/dev/null && continue

  goal=$(wf_goal_text "$plan_file")
  printf "%s\t%s\t%s\n" "${id}-${slug}" "$deps" "$goal"
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
