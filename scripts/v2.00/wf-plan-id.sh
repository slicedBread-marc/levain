#!/usr/bin/env bash
# wf-plan-id.sh <source-id>
#
# Decides the plan ID for the brief or bug being specced, and says why.
#
# THE RULE, AND WHERE IT BREAKS
#
# A plan inherits its number from the source artifact: BRF-041 → PLN-041,
# BUG-043 → PLN-043. The number was allocated when the brief or bug was
# created, so allocating a second one would burn an ID and break the link
# between the two names for one piece of work.
#
# That rule assumes the inherited number is free, and it is not always. In
# client-e, BRF-091 would have inherited PLN-091 — already allocated to an
# unrelated, completed plan with a folder on disk. wf-spec forbids the counter
# and gives no collision procedure, so the only two moves available were
# overwriting a completed plan or departing from the documented rule (WFI-011).
#
# So the rule gets an exception with a defined shape: inherit when free,
# allocate when taken, and say which happened. Both branches are legal; a
# silent overwrite is not.
#
# THE THIRD CASE: THE NUMBER IS HELD BY THIS SAME WORK
#
# "Taken" was read as "taken by SOMEBODY ELSE", and that is not the only way a
# folder gets there. A spec run writes plans/PLN-039-.../plan.md, reviews it,
# and dies before the REGISTRY row or the commit. Redispatched on the same bug,
# the collision check finds the folder its own previous attempt left behind and
# allocates PLN-040 — so following the documented instruction literally creates
# a SECOND plan for one bug and orphans the reviewed one (client-a WFI-121).
#
# A crashed unattended run is routine, so a plan folder derived from the very
# artifact being specced is a RESUME, not a collision. It is recognised by
# plan.md naming that artifact in its header: `> **Bug:** BUG-039` or
# `> **Brief:** ... BRF-041`. Nobody else's plan says that.
#
# THE ANSWER IS ONLY TRUE AT THE MOMENT IT IS GIVEN
#
# Every branch below reads the registry and the plans/ directory as they are
# right now. A spec run asks this question early, then explores the codebase,
# drafts a goal and waits on the user — minutes in which another session can
# create the very folder that would have changed the answer.
#
# client-a watched exactly that on BUG-075: two sessions both got
# `PLAN_ID=PLN-075, COLLISION=, RESUME=false`, seconds apart and both correct,
# and both drafted a plan under that number with different slugs. The duplicate
# reached HEAD, and wf-registry-add.sh's refusal — the last backstop, after the
# folder is written and committed — was the only thing that caught it (WFI-147).
#
# So the answer is not durable and callers must not treat it as one: ask again
# immediately before creating the folder, which is the moment the ID is actually
# taken. The call is cheap and idempotent, and the second answer is the one that
# has seen the other session's work. `/wf-spec` step 5 does this.
#
# Output (eval-friendly):
#   PLAN_ID='PLN-091'          the ID to use
#   PLAN_NUM='091'
#   PLAN_ID_INHERITED=true     false when the number was taken and reallocated
#   PLAN_ID_COLLISION='...'    what held the inherited number (empty if free)
#   PLAN_ID_RESUME=true        the folder is this same artifact's own, from an
#                              earlier attempt — keep the number, keep the work
#   PLAN_ID_DIR='plans/...'    on resume, the folder to continue in. Its slug is
#                              the earlier attempt's, which is rarely the one
#                              this run would have chosen — write there anyway,
#                              it owns the REGISTRY row (empty when not a resume)
#
# Exit 0 on success, 1 on bad usage or an unusable registry.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

src="${1:?Usage: $0 <BRF-NNN|BUG-NNN|PLN-NNN>}"

id=$(printf '%s' "$src" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
[ -n "$id" ] || { echo "Error: '$src' is not a PLN/BUG/BRF id" >&2; exit 1; }

cd "$(wf_develop_root)"
REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

num="${id#*-}"
prefix="${id%%-*}"

# Already a plan: nothing to decide.
if [ "$prefix" = "PLN" ]; then
  wf_emit PLAN_ID           "$id"
  wf_emit PLAN_NUM          "$num"
  wf_emit PLAN_ID_INHERITED "true"
  wf_emit PLAN_ID_COLLISION ""
  wf_emit PLAN_ID_RESUME    "false"
  wf_emit PLAN_ID_DIR       ""
  exit 0
fi

# Taken means either half is taken — a registry row without a folder is a plan
# mid-creation, and a folder without a row is a plan whose row was lost. Either
# one is somebody else's number.
collision=""
if grep -q "^| PLN-${num} |" "$REGISTRY" 2>/dev/null; then
  collision="REGISTRY row PLN-${num}"
fi
existing_dir=$(ls -d "plans/PLN-${num}-"* 2>/dev/null | head -1 || true)
if [ -n "$existing_dir" ]; then
  collision="${collision:+$collision, }folder $existing_dir"
fi

if [ -z "$collision" ]; then
  wf_emit PLAN_ID           "PLN-${num}"
  wf_emit PLAN_NUM          "$num"
  wf_emit PLAN_ID_INHERITED "true"
  wf_emit PLAN_ID_COLLISION ""
  wf_emit PLAN_ID_RESUME    "false"
  wf_emit PLAN_ID_DIR       ""
  exit 0
fi

# Held by this same artifact's own earlier attempt? Then it is not a collision.
#
# The header line is the evidence: TEMPLATE.md writes `> **Bug:** BUG-NNN — …`
# and `> **Brief:** …` for a brief, so the source ID appears in the first few
# quoted lines and nowhere else by accident. Searched in the block before the
# first `##` heading, so a passing mention of the bug in a Step cannot claim it.
if [ -n "$existing_dir" ] && [ -f "$existing_dir/plan.md" ]; then
  header=$(sed -n '1,/^## /p' "$existing_dir/plan.md")
  if printf '%s' "$header" | grep -qE "(^|[^A-Za-z0-9-])${id}([^0-9]|$)"; then
    wf_event id-resume "$id" "PLN-${num} folder $existing_dir is this artifact's own — resuming, not reallocating"
    wf_emit PLAN_ID           "PLN-${num}"
    wf_emit PLAN_NUM          "$num"
    wf_emit PLAN_ID_INHERITED "true"
    wf_emit PLAN_ID_COLLISION ""
    wf_emit PLAN_ID_RESUME    "true"
    wf_emit PLAN_ID_DIR       "$existing_dir"
    exit 0
  fi
fi

# Taken. Allocate a fresh number — wf-counter-next.sh advances past anything
# already in use, so this cannot land on a second collision — and record that
# the link between source number and plan number was broken deliberately.
new_id=$("$SELF_DIR/wf-counter-next.sh" PLN)
new_num="${new_id#*-}"

wf_event id-collision "$id" "PLN-${num} taken ($collision) — allocated $new_id"

wf_emit PLAN_ID           "$new_id"
wf_emit PLAN_NUM          "$new_num"
wf_emit PLAN_ID_INHERITED "false"
wf_emit PLAN_ID_COLLISION "$collision"
wf_emit PLAN_ID_RESUME    "false"
wf_emit PLAN_ID_DIR       ""
