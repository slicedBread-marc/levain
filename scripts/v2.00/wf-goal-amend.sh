#!/usr/bin/env bash
# wf-goal-amend.sh <plan-id-or-name> "<amended goal>" [--reason "<why>"] [--active]
#
# Corrects the goal a plan promises, WITHOUT pushing or popping anything.
#
# By default it amends the goal that is currently archived and pending restore —
# the most recent unresolved `### Goal History` row — because that is the text
# `wf-goal-pop.sh` will put back, verbatim, at the end of the fix cycle. With
# `--active` (or when no row is pending) it amends the live `## Goal` one-liner.
#
# WHY THIS EXISTS
#
# The scope-reduction gate's accept path says to "amend the ## Goal one-liner so
# it describes what will be built". On a plan mid-fix-cycle the live one-liner
# is the fix-cycle sub-goal; the promise the reduction actually contradicts is
# the ORIGINAL, sitting archived in Goal History under a block stamped "Managed
# by wf-spec … Do not edit manually". Nothing could edit it: push only stacks a
# new goal, pop restores the old text unchanged. So accepting a reduction by
# amending the live line left the unreduced promise to return word for word on
# the next pop, silently undoing the human's decision (client-a WFI-084).
#
# The amendment is deliberately NOT re-stamped as reviewed. A changed promise is
# a changed specification; the next pop rewrites `## Goal` with this text, and
# wf-spec's replan stamps after that pop.
#
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"
# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

raw_id="${1:-}"
new_goal="${2:-}"
shift 2 2>/dev/null || true

reason=""
force_active=false
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) reason="${2:?--reason requires a value}"; shift 2 ;;
    --active) force_active=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

plan_id=$(echo "$raw_id" | grep -oE 'PLN-[0-9]+' || true)
if [ -z "$plan_id" ] || [ -z "$new_goal" ]; then
  echo "Usage: $0 <plan-id-or-name> \"<amended goal>\" [--reason \"<why>\"] [--active]" >&2
  exit 1
fi

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

row=$(grep "^| $plan_id |" "$REGISTRY" | head -1)
[ -n "$row" ] || { echo "Error: $plan_id not found in registry" >&2; exit 1; }
slug=$(echo "$row" | awk -F'|' '{print $3}' | xargs)
plan_file="plans/${plan_id}-${slug}/plan.md"
[ -f "$plan_file" ] || { echo "Error: $plan_file not found" >&2; exit 1; }

wf_lock_acquire "plan-$plan_id"

# A bare pipe would split the history row into new columns. Escape rather than
# refuse: goals legitimately read "X | Y" and the writer should not have to know
# which of the two targets their text is about to land in.
cell_goal=${new_goal//|/\\|}

# The row a pop would restore: the last one inside ### Goal History whose
# Resolution is still an em dash. Scoped to the section for the same reason the
# pop is — any four-column table in the plan can end a row in an em dash, and
# amending the wrong one rewrites a Tests row with the plan's goal (WFI-013).
line_num=""
if ! $force_active; then
  line_num=$(wf_goal_history_row "$plan_file")
fi

today=$(date +%Y-%m-%d)

if [ -n "$line_num" ]; then
  old_goal=$(sed -n "${line_num}p" "$plan_file" | awk -F'|' '{print $3}' \
             | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  awk -v n="$line_num" -v goal="$cell_goal" -v note="$reason" -v today="$today" '
    NR == n {
      # Fields: "" | date | previous goal | trigger | resolution | ""
      split($0, f, "|")
      f[3] = " " goal " "
      if (note != "") {
        gsub(/^[ \t]+|[ \t]+$/, "", f[4])
        f[4] = " " f[4] " · goal amended " today ": " note " "
      }
      out = ""
      for (i = 2; i <= 5; i++) out = out "|" f[i]
      print out "|"
      next
    }
    { print }
  ' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"
  echo "Archived goal amended (restores on the next pop):"
  echo "  was: $old_goal"
  echo "  now: $new_goal"
else
  content_line=$(wf_goal_line "$plan_file")
  [ -n "$content_line" ] || { echo "Error: no goal one-liner under '## Goal' in $plan_file" >&2; exit 1; }
  old_goal=$(sed -n "${content_line}p" "$plan_file")
  awk -v n="$content_line" -v goal="$new_goal" '
    NR == n { print goal; next }
    { print }
  ' "$plan_file" > "$plan_file.tmp" && mv "$plan_file.tmp" "$plan_file"
  echo "Active goal amended:"
  echo "  was: $old_goal"
  echo "  now: $new_goal"
fi

[ -n "$reason" ] && echo "  reason: $reason"
exit 0
