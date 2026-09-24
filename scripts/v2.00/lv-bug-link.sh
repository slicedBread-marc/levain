#!/usr/bin/env bash
# lv-bug-link.sh <bug-id> "<text>" [--no-commit]
#
# Adds a line to an already-filed bug's **Links:** field, wherever that bug
# currently sits (open, triaged or closed), and commits the edit.
#
# WHY THIS EXISTS
#
# `lv-bug-new.sh --links` sets Links at filing time and nothing could change it
# afterwards. But the need to link two artifacts almost always arrives LATER
# than the first one: a correction filed against a request already sent, a
# second report that turns out to describe the same thing, a brief that
# consumes the bug. coordinator filed client-b BUG-008 to correct BUG-007 before
# triage, and the only way to make BUG-007 mention it was to hand-edit a field
# in another project's bugs/open/ — which is exactly what a coordinator is told
# never to do (coordinator WFI-001). Same shape for client-e BUG-125 amending BUG-123
# and BUG-124, which is still unlinked.
#
# Links is append-only here on purpose: it is a record of relationships, and
# the second one does not replace the first. A `_(none)_` placeholder is
# replaced rather than appended to. An identical line already present is a
# no-op, so a re-run after a failed commit does not double it.
#
# Exit 0 on success (including the no-op), 1 if the bug does not exist or the
# commit fails.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

bug_id=""
text=""
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit) do_commit=false; shift ;;
    -h|--help)   wf_usage; exit 0 ;;
    -*)          wf_bad_option "$1" ;;
    *)  if [ -z "$bug_id" ]; then bug_id="$1"
        elif [ -z "$text" ]; then text="$1"
        else echo "Error: unexpected argument '$1' — the link text is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$bug_id" ] || [ -z "$text" ]; then
  echo "Usage: $0 <bug-id> \"<text>\" [--no-commit]" >&2
  exit 1
fi

# Bug paths are develop-root-relative, and a caller may be standing anywhere.
cd "$(wf_develop_root)"

bug_dir=""
for stage in open triaged closed; do
  for d in bugs/$stage/${bug_id}*/; do
    if [ -d "$d" ]; then bug_dir="${d%/}"; break 2; fi
  done
done

if [ -z "$bug_dir" ] || [ ! -f "$bug_dir/bug.md" ]; then
  echo "Error: $bug_id not found in bugs/open/, bugs/triaged/ or bugs/closed/" >&2
  exit 1
fi

if grep -qF "$text" "$bug_dir/bug.md"; then
  echo "$bug_id already links: $text — nothing to do"
  exit 0
fi

# ENVIRON, not -v: awk expands escape sequences in a -v assignment, and this
# text is written by a human (same reasoning as lv-bug-close.sh).
LV_LINK_TEXT="$text" awk '
  BEGIN { added = 0; link = ENVIRON["LV_LINK_TEXT"]; saw_header = 0; last_quote = 0; body = 0 }
  {
    lines[NR] = $0
    if ($0 ~ /^[ \t]*##[ \t]/) body = 1
    if (!body && $0 ~ /^[ \t]*>/) last_quote = NR
    if (!added && $0 ~ /Links:\*\*/) {
      if ($0 ~ /_\(none\)_/) { sub(/_\(none\)_/, link) }
      else { sub(/[ \t]*$/, ""); $0 = $0 "; " link }
      lines[NR] = $0; added = 1; saw_header = 1
    }
  }
  END {
    for (i = 1; i <= NR; i++) {
      print lines[i]
      # No Links line at all (a bug filed before the field existed): insert one
      # at the end of the header blockquote rather than dropping the link.
      if (!saw_header && i == last_quote) print "> **Links:** " link
    }
  }
' "$bug_dir/bug.md" > "$bug_dir/bug.md.tmp" && mv "$bug_dir/bug.md.tmp" "$bug_dir/bug.md"

if ! grep -qF "$text" "$bug_dir/bug.md"; then
  echo "Error: could not write the link into $bug_dir/bug.md — nothing changed" >&2
  exit 1
fi

if $do_commit; then
  if ! "$SELF_DIR/lv-commit.sh" "bug($bug_id): link — $text" --add "$bug_dir"; then
    echo "Error: $bug_id's link is written but could not be committed — commit it before another worker does" >&2
    exit 1
  fi
fi

echo "$bug_id links: $text"
