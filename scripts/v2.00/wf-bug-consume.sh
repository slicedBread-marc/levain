#!/usr/bin/env bash
# wf-bug-consume.sh <bug-id> <plan-id>
# Moves a bug from open → triaged and links it to a plan.
# Updates bug.md Status to Triaged and sets Plan field.
#
# Example: wf-bug-consume.sh BUG-003 PLN-005-login-crash
# Exit 0 on success, 1 on error.

set -euo pipefail

bug_id="${1:-}"
plan_id="${2:-}"

if [ -z "$bug_id" ] || [ -z "$plan_id" ]; then
  echo "Usage: $0 <bug-id> <plan-id>" >&2
  exit 1
fi

# Find the bug folder in open
bug_dir=""
for d in bugs/open/${bug_id}*/; do
  if [ -d "$d" ]; then
    bug_dir="${d%/}"
    break
  fi
done

if [ -z "$bug_dir" ]; then
  echo "Error: $bug_id not found in bugs/open/" >&2
  exit 1
fi

bug_slug=$(basename "$bug_dir")

# Update bug.md
#
# The substitutions used to be pure `sub()` calls, which silently do nothing
# when the line they target is absent. A bug filed with a header lacking
# `**Status:**` / `**Plan:**` was therefore "triaged" while recording neither
# its status nor the plan that consumed it — the triage was a rename and
# nothing more (WFI-037). So: rewrite when present, insert when not.
if [ -f "$bug_dir/bug.md" ]; then
  # awk into a tempfile — `sed -i ''` is macOS-only
  awk -v pid="$plan_id" '
    BEGIN { saw_status = 0; saw_plan = 0; body_started = 0; last_quote = 0 }
    {
      if ($0 ~ /Status:\*\*/) { sub(/Status:\*\*.*/, "Status:** Triaged"); saw_status = 1 }
      if ($0 ~ /Plan:\*\*/)   { sub(/Plan:\*\*.*/,   "Plan:** " pid);     saw_plan = 1 }
      lines[NR] = $0
      # The header is the blockquote block above the first `##` section. Track
      # its LAST line, not the first non-quote line — a blank line inside the
      # header would otherwise split the block in two.
      if ($0 ~ /^[ \t]*##[ \t]/) body_started = 1
      if (!body_started && $0 ~ /^[ \t]*>/) last_quote = NR
    }
    END {
      header_end = (last_quote > 0) ? last_quote : ((NR > 0) ? 1 : 0)
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (i == header_end) {
          if (!saw_status) print "> **Status:** Triaged"
          if (!saw_plan)   print "> **Plan:** " pid
        }
      }
    }
  ' "$bug_dir/bug.md" > "$bug_dir/bug.md.tmp" && mv "$bug_dir/bug.md.tmp" "$bug_dir/bug.md"

  # The rename below is the visible half of triage and the record is the half
  # that matters, so prove the record landed rather than assuming it.
  if ! grep -q 'Status:\*\* Triaged' "$bug_dir/bug.md" || ! grep -q "Plan:\*\* $plan_id" "$bug_dir/bug.md"; then
    echo "Error: could not record Status/Plan in $bug_dir/bug.md — not moving the bug" >&2
    exit 1
  fi
fi

# Move to triaged.
#
# `git mv` alone fails with "fatal: source directory is empty" on a bug folder
# git has never seen — which is every freshly filed bug, because wf-bug commits
# only at the end of its own run and a brief consumed in the same session is
# not committed yet. That made the FIRST consumption of any new bug an error
# (WFI-037). Stage what is there, then fall back to a plain move.
mkdir -p bugs/triaged
git add -- "$bug_dir" >/dev/null 2>&1 || true
if ! git mv "$bug_dir" "bugs/triaged/$bug_slug" 2>/dev/null; then
  mv "$bug_dir" "bugs/triaged/$bug_slug"
fi

echo "$bug_id → triaged (linked to $plan_id)"
