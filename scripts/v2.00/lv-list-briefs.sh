#!/usr/bin/env bash
# lv-list-briefs.sh
# Lists briefs from plans/briefs/INDEX.md grouped by status section.
#
# Output: section headers prefixed with '#', entries as <name>\t<description>
# Sections: # Decided, # Exploring, # Idea, # Planned
# Exit 0 if INDEX.md exists and has entries, exit 1 otherwise.

set -euo pipefail

[ -f "plans/briefs/INDEX.md" ] || exit 1

found=0
current_section=""
last_printed_section=""

while IFS= read -r line; do
  # Detect section headers (## Decided, ## Exploring, etc.)
  if echo "$line" | grep -qE '^## '; then
    current_section=$(echo "$line" | sed 's/^## //' | sed 's/[[:space:]]*$//')
    continue
  fi

  # Parse brief entries: "- [Name](file.md) — Description"
  if [ -n "$current_section" ] && echo "$line" | grep -qE '^\- \['; then
    name=$(echo "$line" | sed 's/^\- \[//' | sed 's/\].*//')
    # The description is what follows the link. Cutting at the first em dash
    # instead broke on any title that has one ("X — Y"), leaving half the
    # title and the file name as the description.
    desc=$(echo "$line" | sed -n 's/^- \[[^]]*\]([^)]*)[[:space:]]*—[[:space:]]*//p')
    if [ "$current_section" != "$last_printed_section" ]; then
      echo "# $current_section"
      last_printed_section="$current_section"
    fi
    printf "%s\t%s\n" "$name" "$desc"
    found=1
  fi
done < "plans/briefs/INDEX.md"

exit $((1 - (found > 0 ? 1 : 0)))
