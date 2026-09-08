#!/usr/bin/env bash
# wf-plan-info.sh <plan-id-or-name>
# Looks up a plan in REGISTRY.md and outputs key=value pairs.
# Output (eval-friendly — every value is single-quoted):
#   PLAN_ID='PLN-004'
#   PLAN_SLUG='deployment-date-footer'
#   PLAN_STATE='testing'
#   PLAN_PRIORITY='—'
#   PLAN_BRANCH='feature/PLN-004-deployment-date-footer'
#   PLAN_UPDATED='2026-04-12'
#   PLAN_WF='2.00'
#   PLAN_DIR='plans/PLN-004-deployment-date-footer'
#   PLAN_NAME='PLN-004-deployment-date-footer'
#   PLAN_GOAL='Add deployment date to footer'
#
# Registry row format (9 data columns, leading pipe makes awk field 1 empty):
#   | ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
#      $2   $3     $4       $5       $6       $7      $8   $9     $10
# PLAN_WF empty means "no version stamped" — dispatcher routes to v1.x baseline.
# PLAN_TAGS: comma-separated category tags (or — if none).
# PLAN_DEPS: comma-separated plan IDs that must be complete (or — if none).
# PLAN_BLOCKED: true if any dep is not in complete state.
# PLAN_DEPS_DEAD: subset of PLAN_BLOCKING that is abandoned — never arriving.
#
# Accepts either a plan ID (PLN-004) or full plan name (PLN-004-deployment-date-footer).
# Usage: eval "$(scripts/wf-plan-info.sh PLN-004)"
# Exit 0 if found, 1 if not.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
input="${1:-}"

if [ -z "$input" ]; then
  echo "Usage: $0 <plan-id-or-name>" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Extract plan ID (PLN-NNN) from full name if needed
plan_id=$(echo "$input" | grep -oE 'PLN-[0-9]+')
if [ -z "$plan_id" ]; then
  echo "Error: could not extract plan ID from '$input'" >&2
  exit 1
fi

# Find the row
row=$(grep "^| $plan_id |" "$REGISTRY" | head -1)
if [ -z "$row" ]; then
  echo "Error: $plan_id not found in $REGISTRY" >&2
  exit 1
fi

# Parse columns (see header for layout). One pass over the row, not nine:
# `echo | awk | xargs` per column is 27 subprocesses to read one line, and most
# skills call this script several times.
# 0x1f, not tab: tab is IFS whitespace, so a run of them collapses and an
# empty column shifts every field after it (a legacy 7-column row does exactly
# that — PLAN_WF came back holding the Tags value).
IFS=$'\037' read -r id slug state priority branch updated wf tags deps <<< "$(
  printf '%s\n' "$row" | awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { US = sprintf("%c", 31) }
    { printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s",
        trim($2), US, trim($3), US, trim($4), US, trim($5), US, trim($6), US,
        trim($7), US, trim($8), US, trim($9), US, trim($10) }
  '
)"
[ -z "$tags" ] && tags="—"
[ -z "$deps" ] && deps="—"

plan_dir="plans/${id}-${slug}"
plan_name="${id}-${slug}"

# Extract goal from plan.md if it exists: the first non-blank line under
# `## Goal`, stopping at the next heading — the same rule wf_goal_line() in
# wf-orch-lib.sh uses.
#
# Not "the line after the heading". `grep -A 1 | tail -1` captured the blank
# line every markdown convention leaves under a heading, so a well-formed plan
# reported PLAN_GOAL='' and PLAN_GOAL_MISSING=true. client-a's WFI-125 and
# WFI-128: PLN-041 had a fully written goal and the orchestrator opened a
# goal-missing gate on it, handing a human a question with no real answer.
goal=""
if [ -f "$plan_dir/plan.md" ]; then
  goal=$(wf_goal_text "$plan_dir/plan.md")
fi

# Check if any dep is not complete.
#
# An abandoned dep also blocks — you cannot build against something that will
# never exist — but it is reported separately, because waiting fixes the one
# and never fixes the other (WFI-008).
blocked=false
blocking=""
dead=""
if [ "$deps" != "—" ] && [ -n "$deps" ]; then
  IFS=',' read -ra dep_list <<< "$deps"
  for dep_id in "${dep_list[@]}"; do
    dep_id=$(echo "$dep_id" | xargs)
    dep_state=$(wf_registry_field "$dep_id" state "$REGISTRY")
    if [ "$dep_state" != "complete" ]; then
      blocked=true
      [ -n "$blocking" ] && blocking="$blocking,$dep_id" || blocking="$dep_id"
      if [ "$dep_state" = "abandoned" ]; then
        [ -n "$dead" ] && dead="$dead,$dep_id" || dead="$dep_id"
      fi
    fi
  done
fi

# Every value is single-quoted so eval survives spaces, semicolons, backticks, etc.
# (a Tags value like "infra, hosting" word-splits under eval when emitted bare).
# wf_emit (wf-orch-lib.sh) does exactly this — no local redefinition needed.

wf_emit PLAN_ID "$id"
wf_emit PLAN_SLUG "$slug"
wf_emit PLAN_STATE "$state"
wf_emit PLAN_PRIORITY "$priority"
wf_emit PLAN_BRANCH "$branch"
wf_emit PLAN_UPDATED "$updated"
wf_emit PLAN_WF "$wf"
wf_emit PLAN_TAGS "$tags"
wf_emit PLAN_DEPS "$deps"
wf_emit PLAN_BLOCKED "$blocked"
wf_emit PLAN_BLOCKING "$blocking"
wf_emit PLAN_DEPS_DEAD "$dead"
wf_emit PLAN_DIR "$plan_dir"
wf_emit PLAN_NAME "$plan_name"
wf_emit PLAN_GOAL "$goal"
if [ -z "$goal" ]; then
  echo "PLAN_GOAL_MISSING=true"
else
  echo "PLAN_GOAL_MISSING=false"
fi
