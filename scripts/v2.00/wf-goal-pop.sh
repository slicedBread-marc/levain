#!/usr/bin/env bash
# wf-goal-pop.sh <plan-id-or-name>
# Restores the most recent unresolved goal from ### Goal History.
# Marks the history row as resolved with today's date.
#
# Example:
#   wf-goal-pop.sh PLN-074
#
# Exit 0 on success, 1 if no unresolved goal found.

set -euo pipefail

# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"
# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

# Registry work is develop-root work. Sourced/derived paths below are relative
# ("plans/REGISTRY.md", "plans/PLN-NNN-slug/..."), and verify and implement
# workers run with their CWD inside a feature worktree — where those resolve to
# that worktree's own stale copy. The write then "succeeds", the verification
# grep passes against the copy it just wrote, and the real registry never moves.
# The main worktree is always the first one git lists.
_wf_root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || true
[ -n "$_wf_root" ] || _wf_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
cd "$_wf_root"

raw_id="${1:-}"

plan_id=$(echo "$raw_id" | grep -oE 'PLN-[0-9]+')
if [ -z "$plan_id" ]; then
  echo "Usage: $0 <plan-id-or-name>" >&2
  exit 1
fi

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Resolve plan dir
row=$(grep "^| $plan_id |" "$REGISTRY" | head -1)
[ -n "$row" ] || { echo "Error: $plan_id not found in registry" >&2; exit 1; }
slug=$(echo "$row" | awk -F'|' '{print $3}' | xargs)
plan_dir="plans/${plan_id}-${slug}"
plan_file="$plan_dir/plan.md"
[ -f "$plan_file" ] || { echo "Error: $plan_file not found" >&2; exit 1; }

# Plan-scoped, not the global registry lock — this only rewrites plan.md, so
# two workers on different plans need not wait on each other.
wf_lock_acquire "plan-$plan_id"

# Find the most recent unresolved row (Resolution = —) INSIDE ### Goal History.
# Goal History rows: | Date | Previous Goal | Trigger | — |
#
# Scoped to the section, because a plan.md is full of four-column tables and
# any of them may end a row in an em dash. client-e's PLN-100 had a withdrawn
# Tests row — `| ~~T14~~ | ~~E2E~~ | Withdrawn by A3 | — |` — further down the
# file; the unscoped search latched onto it, wrote `~~E2E~~` into `## Goal`,
# stamped it Resolved, and reported success (WFI-013).
line_num=$(wf_goal_history_row "$plan_file")
if [ -z "$line_num" ]; then
  echo "No unresolved goal in ### Goal History — nothing to pop" >&2
  exit 1
fi

line_content=$(sed -n "${line_num}p" "$plan_file")

# Extract the previous goal from the row (field 3, pipe-delimited)
previous_goal=$(echo "$line_content" | awk -F'|' '{print $3}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
if [ -z "$previous_goal" ]; then
  echo "Error: could not extract previous goal from history row" >&2
  exit 1
fi

today=$(date +%Y-%m-%d)

# Mark the history row as resolved (awk into a tempfile — `sed -i ''` is macOS-only)
awk -v n="$line_num" -v today="$today" '
  NR == n { sub(/\|[ \t]*—[ \t]*\|[ \t]*$/, "| Resolved " today " |"); }
  { print }
' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

# Replace the current goal line with the restored goal
content_line=$(wf_goal_line "$plan_file")
if [ -z "$content_line" ]; then
  echo "Error: no goal one-liner under '## Goal' in $plan_file" >&2
  exit 1
fi
awk -v n="$content_line" -v goal="$previous_goal" '
  NR == n { print goal; next }
  { print }
' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

echo "Goal restored: '$previous_goal' (resolved $(date +%Y-%m-%d))"
