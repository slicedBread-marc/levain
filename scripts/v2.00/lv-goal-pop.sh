#!/usr/bin/env bash
# lv-goal-pop.sh <plan-id-or-name>
# Restores the most recent unresolved goal from ### Goal History.
# Marks the history row as resolved with today's date.
#
# Example:
#   lv-goal-pop.sh PLN-074
#
# Exit 0 on success, 1 if no unresolved goal found.

set -euo pipefail

# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"
# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

raw_id="${1:-}"

plan_id=$(echo "$raw_id" | grep -oE "($LV_PLN_RE)-[0-9]+")
if [ -z "$plan_id" ]; then
  echo "Usage: $0 <plan-id-or-name>" >&2
  exit 1
fi

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Resolve plan dir
slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
[ -n "$slug" ] || { echo "Error: $plan_id not found in registry" >&2; exit 1; }
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

# Extract the previous goal from the row: | Date | Previous Goal | Trigger | Res |
#
# Read from the RIGHT, not by field index from the left.
#
# `awk -F'|' '{print $3}'` is correct only while no cell contains a pipe, and a
# goal is prose written by a planner. client-a's PLN-224 promised that
# "`tool change push|apply|status|unapply|return` and `tool commit` stop failing"
# — the history row stored that sentence intact, and the pop restored
# "...so `tool change push" and nothing else, exit 0, "Goal restored" (WFI-218).
# The length and whitespace guard below could not catch it: the truncation left
# a long, spaced, entirely plausible fragment.
#
# Date is the first cell and cannot contain a pipe; Resolution and Trigger are
# the last two. So strip the row's outer delimiters, drop the first cell from
# the left and the last two from the right, and whatever is between them is the
# goal however many pipes it holds. `\|` is unescaped on the way out, for rows
# lv-goal-push.sh wrote after it learned to escape them.
goal_row="${line_content#*|}"                       # drop the leading `| `
goal_row="${goal_row%|*}"                           # drop the trailing ` |`
goal_row="${goal_row#*|}"                           # drop Date
goal_row="${goal_row%|*}"                           # drop Resolution
previous_goal="${goal_row%|*}"                      # drop Trigger
previous_goal=$(printf '%s' "$previous_goal" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//; s/\\|/|/g')
if [ -z "$previous_goal" ]; then
  echo "Error: could not extract previous goal from history row" >&2
  exit 1
fi

# Refuse to write something that cannot be a goal.
#
# The pop's failure mode is not an error — it is a plausible-looking success.
# client-a's PLN-007 printed "Goal restored: '2'" and wrote `2` as the whole
# `## Goal` one-liner, exit 0; the only signal was the `2` in the success
# message, and had nobody read it the plan would have reached the builder with
# no goal at all (WFI-097). `## Goal` feeds lv-plan-info.sh, and from there
# lv-implement, lv-test and every PR description.
#
# A goal is a sentence. One token, or under ten characters, is a table cell
# that got picked up by a column index — so fail loudly and leave plan.md
# untouched, which is recoverable, rather than write it, which is silent.
if [ "${#previous_goal}" -lt 10 ] || ! printf '%s' "$previous_goal" | grep -q '[[:space:]]'; then
  echo "Error: refusing to restore '$previous_goal' — that is not a goal." >&2
  echo "       Row $line_num of $plan_file:" >&2
  echo "       $line_content" >&2
  echo "       Nothing was written. Check the ### Goal History table's columns." >&2
  exit 1
fi

# Locate what is being replaced BEFORE anything is written.
#
# The history row used to be stamped Resolved first, so the refusal below —
# which says "nothing was written" — would already have written half the pop:
# a resolved row and an unrestored goal, which is the one state no later run
# can recover from, because the row it would pop is no longer unresolved.
# Every check that can refuse now runs while plan.md is still untouched.
#
# Replace the current goal with the restored one — the WHOLE goal, not its
# first line.
#
# This replaced exactly one line, on the reasoning that `## Goal` holds exactly
# one. When that reasoning was false the pop still exited 0 and still printed
# "Goal restored", leaving the rest of the old goal orphaned in the file
# underneath the new one (client-a's WFI-154, where the orphan began `## `
# and became a heading). lv-goal-push.sh now refuses to create a multi-line
# goal, so this handles the ones already written.
span=$(wf_goal_span "$plan_file")
if [ -z "$span" ]; then
  echo "Error: no goal one-liner under '## Goal' in $plan_file" >&2
  exit 1
fi
span_start=${span% *}
span_end=${span#* }

# A wider span is a repair, and a repair must not delete something structural.
# Plain continuation lines are absorbed; anything shaped like a heading is
# reported and left alone, because a pop that silently removes a section is a
# worse outcome than one that stops and says what it found.
if [ "$span_end" -gt "$span_start" ]; then
  if sed -n "$((span_start + 1)),${span_end}p" "$plan_file" | grep -q '^#'; then
    echo "Error: '## Goal' in $plan_file spans lines $span_start-$span_end and one of the" >&2
    echo "       extra lines starts with '#', so it may be a real section heading:" >&2
    sed -n "$((span_start + 1)),${span_end}p" "$plan_file" | sed 's/^/         /' >&2
    echo "       Nothing was written. Make '## Goal' a single line by hand, then re-run." >&2
    echo "       (A multi-line goal is WFI-154; push refuses to create one as of v6.12.)" >&2
    exit 1
  fi
  echo "Note: '## Goal' spanned lines $span_start-$span_end — collapsing it back to one." >&2
fi

today=$(date +%Y-%m-%d)

# Mark the history row as resolved (awk into a tempfile — `sed -i ''` is macOS-only)
awk -v n="$line_num" -v today="$today" '
  NR == n { sub(/\|[ \t]*—[ \t]*\|[ \t]*$/, "| Resolved " today " |"); }
  { print }
' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

LV_GOAL="$previous_goal" awk -v s="$span_start" -v e="$span_end" '
  BEGIN { goal = ENVIRON["LV_GOAL"] }   # not -v: -v expands \n and \t (WFI-154)
  NR == s { print goal; next }
  NR > s && NR <= e { next }
  { print }
' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

echo "Goal restored: '$previous_goal' (resolved $(date +%Y-%m-%d))"
