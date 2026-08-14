#!/usr/bin/env bash
# wf-list-bugs.sh
# Lists bugs from bugs/open/ and bugs/triaged/.
#
# Output: section headers prefixed with '#', entries as <bug-id>\t<severity>\t<title>\t<linked-plan>
# Sections: # open, # triaged
# Exit 0 if any found, exit 1 if none.

set -euo pipefail

found=0

for stage in open triaged; do
  stage_found=0
  for bug_md in "bugs/$stage"/*/bug.md; do
    [ -f "$bug_md" ] || continue

    bug_id=$(grep -oE 'BUG-[0-9]+' "$bug_md" 2>/dev/null | head -1 || true)
    severity=$(grep -E '^\*\*Severity:\*\*|^> \*\*Severity:\*\*' "$bug_md" 2>/dev/null | head -1 | sed 's/.*Severity:\*\*[[:space:]]*//' | sed 's/^> //' || true)
    title=$(head -1 "$bug_md" | sed 's/^# //')
    linked_plan=$(grep -E '^\*\*Plan:\*\*|^> \*\*Plan:\*\*' "$bug_md" 2>/dev/null | head -1 | sed 's/.*Plan:\*\*[[:space:]]*//' | sed 's/^> //' || true)

    [ -n "$bug_id" ] || continue

    # A bug tracked at two paths at once is corruption, and `closed` is the
    # authoritative side of it — reporting the stale `triaged` copy sends a
    # human to re-fix a bug that shipped. Six of these existed on client-a
    # before wf-bug-close.sh started committing its own rename (WFI-136); the
    # skip keeps the older ones from misreporting while they are cleaned up.
    if [ "$stage" != "open" ] && [ -f "bugs/closed/$(basename "$(dirname "$bug_md")")/bug.md" ]; then
      echo "wf-list-bugs: $bug_id exists in both bugs/$stage/ and bugs/closed/ — reporting it closed; delete the $stage copy" >&2
      continue
    fi

    if [ $stage_found -eq 0 ]; then
      echo "# $stage"
      stage_found=1
    fi
    printf "%s\t%s\t%s\t%s\n" "$bug_id" "$severity" "$title" "$linked_plan"
    found=1
  done
done

exit $((1 - (found > 0 ? 1 : 0)))
