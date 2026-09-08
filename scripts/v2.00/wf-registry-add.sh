#!/usr/bin/env bash
# wf-registry-add.sh <plan-id> <slug> [--tags <t1,t2>] [--priority <P>]
#                    [--deps <ID,ID>] [--state <state>] [--no-commit]
#
# Appends a new plan's row to plans/REGISTRY.md and COMMITS it, both under the
# registry lock. The row lands as `draft` unless --state says otherwise.
#
# WHY THIS IS A SCRIPT
#
# Every other write to REGISTRY.md goes through wf-registry-update.sh, whose
# whole argument is that a row written and committed in one locked step can be
# taken by neither a concurrent stash nor a concurrent pathspec commit (WFI-061,
# WFI-065). Creating a row was the one write left outside that rule: /wf-spec
# hand-edited the table and left the row dirty on the shared develop checkout
# until its own exit commit, which sits on the far side of the entire review
# loop.
#
# client-a's WFI-140 is what that costs. PLN-060's new draft row was carried
# off by a concurrent wf-implement worker's correctly-pathspecced commit
# `implement(PLN-055-doctor-trusted-peer-check): verified, moved to verify`.
# Pathspec discipline does not defend against this and cannot: both workers
# legitimately name plans/REGISTRY.md, so whoever commits first takes the
# other's uncommitted rows out of the same file. Nothing was lost — only the
# audit trail, which is the thing the registry is for.
#
# Same shape as WFI-122 one file over: the fix is not a better pathspec, it is
# not being dirty for that long.
#
# The WF column is stamped from .claude/workflow-version so the dispatcher
# routes this plan to the matching script snapshot (scripts/version-map.txt).
#
# Exit 0 on success, 1 on error — including a row that already exists, which is
# never something to write twice.

set -euo pipefail

# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"
# shellcheck source=wf-states.sh
source "$(dirname "$0")/wf-states.sh"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
slug="${2:-}"
shift 2 2>/dev/null || true

tags=""
priority=""
deps=""
state="draft"
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --tags)      tags="${2:?--tags requires a value}"; shift 2 ;;
    --priority)  priority="${2:?--priority requires a value}"; shift 2 ;;
    --deps)      deps="${2:?--deps requires a value}"; shift 2 ;;
    --state)     state="${2:?--state requires a value}"; shift 2 ;;
    --no-commit) do_commit=false; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE '^PLN-[0-9]+' || true)

if [ -z "$plan_id" ] || [ -z "$slug" ]; then
  echo "Usage: $0 <plan-id> <slug> [--tags <t1,t2>] [--priority <P>] [--deps <ID,ID>] [--state <state>] [--no-commit]" >&2
  exit 1
fi

# A PLN-NNN-slug was almost certainly meant as the folder name, not the slug.
slug="${slug#"$plan_id"-}"

if ! wf_state_is_valid "$state"; then
  echo "Error: '$state' is not a workflow state." >&2
  echo "       Valid: $WF_STATES" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Pipes end the cell they are in — every field here is free text from a planner.
sanitize() { printf '%s' "$1" | tr '|' '/' | tr -d '\n'; }
slug=$(sanitize "$slug")
tags=$(sanitize "${tags:-—}")
priority=$(sanitize "${priority:-—}")
deps=$(sanitize "${deps:-—}")
[ -n "$tags" ]     || tags="—"
[ -n "$priority" ] || priority="—"
[ -n "$deps" ]     || deps="—"

wf=$(tr -d '[:space:]' < .claude/workflow-version 2>/dev/null || true)
[ -n "$wf" ] || wf="${WF_VERSION:-—}"

today=$(date +%Y-%m-%d)

wf_lock_acquire registry

# One row per plan, always. A second row is not a duplicate record, it is a
# second state: `grep -q "^| $id |.*| $from |"` in wf-registry-update.sh matches
# whichever row it reaches first, and the dispatcher reads the other one.
#
# Tested by ROW EXISTENCE, not by the state field's emptiness — this is the
# one guard in the registry scripts where that distinction is load-bearing.
# wf_registry_field alone can't tell "no row" from "a row whose state column
# is blank", and this is the single check standing between a malformed row
# and a second, silently duplicate one.
if grep -q "^| $plan_id |" "$REGISTRY"; then
  actual=$(wf_registry_field "$plan_id" state "$REGISTRY")
  echo "Error: $plan_id already has a row in $REGISTRY (state '$actual')." >&2
  echo "       To move it, use wf-registry-update.sh $plan_id $actual <to-state>." >&2
  exit 1
fi

# A row for a plan git has never seen is the WFI-053 shape from the other side:
# the registry offers work whose plan.md does not exist. Not fatal — the folder
# may be written moments later — but it is never silently fine.
[ -d "plans/$plan_id-$slug" ] || \
  echo "wf-registry-add: note — plans/$plan_id-$slug does not exist yet; commit the folder before anything picks the plan up" >&2

row="| $plan_id | $slug | $state | $priority | — | $today | $wf | $tags | $deps |"

# Insert after the last existing plan row, or after the table separator when the
# table is empty. NOT at end of file: `<!-- Counter: N -->` lives below the
# table, and a row appended under it is outside the table and parsed by nothing.
# awk into a tempfile — `sed -i ''` is macOS-only.
awk -v row="$row" '
  { lines[NR] = $0; if ($0 ~ /^\| PLN-/) last_row = NR; else if ($0 ~ /^\|[- ]+\|/ && !last_sep) last_sep = NR }
  END {
    at = (last_row > 0) ? last_row : last_sep
    if (at == 0) { for (i = 1; i <= NR; i++) print lines[i]; print row; exit }
    for (i = 1; i <= NR; i++) { print lines[i]; if (i == at) print row }
  }
' "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

if ! grep -q "^| $plan_id |.*| $state |" "$REGISTRY"; then
  echo "Error: could not add the row for $plan_id to $REGISTRY" >&2
  exit 1
fi

echo "$plan_id: row added — $state"

git add "$REGISTRY" 2>/dev/null || true

# Committed here, still under the lock. See the header: leaving it staged for a
# caller's later commit is the whole bug.
if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "registry($plan_id): drafted — $state" --add "$REGISTRY"; then
    echo "wf-registry-add: the row is staged but could not be committed — commit plans/REGISTRY.md before another worker does" >&2
  fi
fi
