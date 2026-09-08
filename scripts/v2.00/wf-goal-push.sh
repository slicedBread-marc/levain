#!/usr/bin/env bash
# wf-goal-push.sh <plan-id-or-name> <new-goal> <trigger>
# Archives the current goal line to ### Goal History and writes a new active goal.
#
# Example:
#   wf-goal-push.sh PLN-074 "Fix flicker on re-render (show-stopper)" "Verify: 2 findings"
#
# The Goal History table is appended to (or created if missing).
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

raw_id="${1:-}"
new_goal="${2:-}"
trigger="${3:-}"

plan_id=$(echo "$raw_id" | grep -oE 'PLN-[0-9]+')
if [ -z "$plan_id" ] || [ -z "$new_goal" ] || [ -z "$trigger" ]; then
  echo "Usage: $0 <plan-id-or-name> <new-goal> <trigger>" >&2
  exit 1
fi

# A goal is ONE line, and so is a trigger — `## Goal` is read a line at a time
# (wf_goal_text) and the trigger is one cell of a four-column table. Anything
# that would end up spanning lines is refused here, at the only point where
# refusing costs nothing.
#
# client-a's WFI-154: the goal text contained the two literal characters
# `\n`, inside the phrase "no forged '\n## ' sequence". It reached awk through
# `-v goal=…`, which expands escape sequences in its assignment, so a real
# newline was written into plan.md and `## Goal` became two lines. The pop that
# followed replaced only the first, leaving `## ' sequence) rather than …` in
# the file as what markdown reads as a heading.
#
# Two independent fixes, because either alone leaves a hole: every value below
# now reaches awk through ENVIRON (which does no expansion at all), and a value
# that already contains a newline is rejected outright.
for _field in "new_goal:$new_goal" "trigger:$trigger"; do
  _name="${_field%%:*}"; _val="${_field#*:}"
  case "$_val" in
    *$'\n'*)
      echo "Error: <$_name> contains a newline. It must be a single line." >&2
      echo "       ## Goal and the Goal History table are both read one line at a time." >&2
      exit 1 ;;
  esac
done
unset _field _name _val

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Resolve plan dir
slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
[ -n "$slug" ] || { echo "Error: $plan_id not found in registry" >&2; exit 1; }
plan_dir="plans/${plan_id}-${slug}"
plan_file="$plan_dir/plan.md"
[ -f "$plan_file" ] || { echo "Error: $plan_file not found" >&2; exit 1; }

# Plan-scoped, not the global registry lock — this only rewrites plan.md.
wf_lock_acquire "plan-$plan_id"

# Read current goal — the WHOLE goal, not just its first physical line.
#
# `wf_goal_text` (and the old `content_line=$(wf_goal_line ...)` below) only
# ever looked at the first non-blank line under `## Goal`. That is right for a
# goal spec-time wrote as one line, but nothing enforces that constraint on
# the way in — a goal sentence long enough to wrap across two physical lines
# in plan.md is ordinary prose, not the WFI-154 injected-`\n` case. Pushing a
# sub-goal against a wrapped original replaced only the first line, leaving
# the wrapped continuation dangling under the new one-liner as orphaned text,
# and truncated the Goal History "Previous Goal" cell to match (WFI-008).
#
# wf_goal_span already exists for exactly this (built for wf-goal-pop.sh's
# side of WFI-154) — read the full span here too, and archive all of it.
goal_span=$(wf_goal_span "$plan_file")
[ -n "$goal_span" ] || { echo "Error: no current goal found in $plan_file" >&2; exit 1; }
goal_span_start=${goal_span% *}
goal_span_end=${goal_span#* }

if [ "$goal_span_end" -gt "$goal_span_start" ] \
   && sed -n "$((goal_span_start + 1)),${goal_span_end}p" "$plan_file" | grep -q '^#'; then
  echo "Error: '## Goal' in $plan_file spans lines $goal_span_start-$goal_span_end and one of the" >&2
  echo "       extra lines starts with '#', so it may be a real section heading:" >&2
  sed -n "$((goal_span_start + 1)),${goal_span_end}p" "$plan_file" | sed 's/^/         /' >&2
  echo "       Nothing was written. Make '## Goal' a single line by hand, then re-run." >&2
  exit 1
fi

current_goal=$(sed -n "${goal_span_start},${goal_span_end}p" "$plan_file" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
[ -n "$current_goal" ] || { echo "Error: no current goal found in $plan_file" >&2; exit 1; }

today=$(date +%Y-%m-%d)

# Ensure ### Goal History section exists
if ! grep -q "^### Goal History" "$plan_file"; then
  # Insert before the next ## section after ## Goal
  goal_line=$(grep -n "^## Goal" "$plan_file" | head -1 | cut -d: -f1)
  next_section=$(awk -v start="$((goal_line + 1))" 'NR > start && /^## / { print NR; exit }' "$plan_file")
  if [ -n "$next_section" ]; then
    insert_at=$((next_section - 1))
  else
    insert_at=$(wc -l < "$plan_file")
  fi
  awk -v n="$insert_at" '
    NR == n { print; print ""; print "### Goal History"; print "| Date | Previous Goal | Trigger | Resolution |"; print "|-|-|-|-|"; next }
    { print }
  ' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"
fi

# Append the history row INSIDE the Goal History section.
#
# This used to match the first `|-|-|-|-|` anywhere in the file. In the shipped
# template Goal History's own header is a comment (the table starts empty), so
# the first LIVE four-column separator belongs to `## Tests` — and every goal
# push silently prepended a row to the Tests table, giving it an ID column
# holding a date and a Command column holding an em-dash.
#
# So: find the section, and only then find its separator. If the header is
# still commented out, uncomment it rather than writing a second one.
# A pipe inside a cell is escaped on the way in.
#
# Markdown says so — an unescaped `|` in a cell splits the row — and so does
# every reader of this table. client-a's PLN-224 archived a goal naming
# `tool change push|apply|status|unapply|return`, which made a four-column row
# into an eight-column one; the pop that followed restored the goal as far as
# the first pipe and reported success (WFI-218). wf-goal-pop.sh now reads the
# row from the right so it survives the rows already written this way, and
# unescapes `\|` for the ones written from here on. Both halves are worth
# having: this one keeps the table valid for anything that renders it.
esc_pipes() { printf '%s' "$1" | sed 's/|/\\|/g'; }
WF_ROW="| $today | $(esc_pipes "$current_goal") | $(esc_pipes "$trigger") | — |" awk '
  BEGIN { row = ENVIRON["WF_ROW"] }   # not -v: -v expands \n, \t, \\ (WFI-154)
  /^### Goal History/ { in_hist = 1; print; next }

  # Any other heading closes the section. If we got here without writing the
  # row, the section had no live table — emit one before leaving.
  in_hist && /^#+[[:space:]]/ {
    if (!done) { print "| Date | Previous Goal | Trigger | Resolution |"; print "|-|-|-|-|"; print row; print ""; done = 1 }
    in_hist = 0; print; next
  }

  # The commented-out placeholder header becomes the real one.
  in_hist && !done && /^<!--[[:space:]]*\|[[:space:]]*Date[[:space:]]*\|/ {
    print "| Date | Previous Goal | Trigger | Resolution |"
    print "|-|-|-|-|"
    print row
    done = 1
    next
  }

  in_hist && !done && /^\|[[:space:]]*-+[[:space:]]*\|/ { print; print row; done = 1; next }

  { print }

  END {
    if (in_hist && !done) {
      print "| Date | Previous Goal | Trigger | Resolution |"
      print "|-|-|-|-|"
      print row
    }
  }
' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

if ! grep -q "^| $today | " "$plan_file"; then
  echo "Error: could not locate '### Goal History' in $plan_file — goal not pushed" >&2
  exit 1
fi

# Replace the current goal span with the new goal — the WHOLE span read
# above, not just its first line (see the WFI-008 note above `goal_span`).
WF_GOAL="$new_goal" awk -v s="$goal_span_start" -v e="$goal_span_end" '
  BEGIN { goal = ENVIRON["WF_GOAL"] }   # not -v: see WFI-154 above
  NR == s { print goal; next }
  NR > s && NR <= e { next }
  { print }
' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"

echo "Goal pushed: '$current_goal' → '$new_goal' (trigger: $trigger)"
