#!/usr/bin/env bash
# wf-brief-park.sh <BRF-NNN|file> "<why>" [--no-commit]
# wf-brief-park.sh <BRF-NNN|file> --clear [--no-commit]
#
# Parks a brainstorm nobody is carrying forward: moves its INDEX.md row to
# `## Parked` and stamps the brief with `> **Status:** Parked` plus a dated
# `> **Parked:**` reason. `--clear` puts it back where it was.
#
# WHY THIS EXISTS
#
# wf-list-brainstorms.sh counts the briefs sitting at Idea/Exploring — ideas
# captured and never carried to a decision — and that count is on the board
# precisely because those are easy to forget. A number that can only go up
# stops being read: a project with a dozen ideas nobody intends to pick up
# this year looks identical to one with a dozen live ones.
#
# Parking is the difference. It is a decision, recorded with a reason and a
# date, not a deletion: the brief stays on disk, its row stays in INDEX.md
# under `## Parked`, and `wf-list-brainstorms.sh --parked` lists what was set
# aside and why. Nothing is hidden — it is just no longer counted as thinking
# in progress.
#
# A parked brief is not blocked. `wf-brief-block.sh` is the other verb, and it
# says something different: a DECIDED brief that cannot become a plan yet
# because of an external dependency. Blocked means "still ours, not yet
# convertible"; parked means "we stopped exploring this."
#
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

brief_arg=""
why=""
clear=false
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --clear)     clear=true; shift ;;
    --no-commit) do_commit=false; shift ;;
    -h|--help)   wf_usage; exit 0 ;;
    -*)          wf_bad_option "$1" ;;
    *)  if [ -z "$brief_arg" ]; then brief_arg="$1"
        elif [ -z "$why" ]; then why="$1"
        else echo "Error: unexpected argument '$1' — the reason is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$brief_arg" ] || { ! $clear && [ -z "$why" ]; }; then
  echo "Usage: $0 <BRF-NNN|file> \"<why>\" [--no-commit]" >&2
  echo "       $0 <BRF-NNN|file> --clear [--no-commit]" >&2
  echo >&2
  echo "Parking with no reason is an idea deleted quietly. The reason is required." >&2
  exit 1
fi

cd "$(wf_develop_root)"

INDEX="plans/briefs/INDEX.md"

# A pre-ID brief (plans/briefs/hotspot-maps.md) has no BRF number, so the
# argument is allowed to be a filename too — otherwise exactly the oldest,
# most-forgotten briefs would be the ones that cannot be parked.
brief_md=""
for candidate in "plans/briefs/$brief_arg" "plans/briefs/$brief_arg.md" plans/briefs/"$brief_arg"*.md; do
  [ -f "$candidate" ] && { brief_md="$candidate"; break; }
done
if [ -z "$brief_md" ]; then
  echo "Error: no brief matching '$brief_arg' in plans/briefs/" >&2
  exit 1
fi
base=$(basename "$brief_md")

brief_field() {
  grep -m1 -E "^[ \t]*>?[ \t]*\*\*$2:\*\*" "$1" 2>/dev/null \
    | sed -E "s/^.*\*\*$2:\*\*[[:space:]]*//; s/[[:space:]]*$//" || true
}

status=$(brief_field "$brief_md" "Status")
parked_field=$(brief_field "$brief_md" "Parked")

# ── Rewrite the header ─────────────────────────────────────────────────
# set_status / drop_field keep the header a single blockquote: one Status
# line, at most one Parked line, no stacking.
set_status() {
  WF_ST="$1" awk '
    BEGIN { done = 0 }
    !done && /^[ \t]*>?[ \t]*\*\*Status:\*\*/ { print "> **Status:** " ENVIRON["WF_ST"]; done = 1; next }
    { print }
  ' "$brief_md" > "$brief_md.tmp" && mv "$brief_md.tmp" "$brief_md"
}

drop_field() {
  awk -v f="$1" '$0 !~ "^[ \t]*>?[ \t]*\\*\\*" f ":\\*\\*"' "$brief_md" > "$brief_md.tmp" \
    && mv "$brief_md.tmp" "$brief_md"
}

add_parked_note() {
  WF_NOTE="> **Parked:** $1" awk '
    BEGIN { replaced = 0; last_quote = 0; body = 0 }
    {
      if (!replaced && $0 ~ /^[ \t]*>?[ \t]*\*\*Parked:\*\*/) { lines[NR] = ENVIRON["WF_NOTE"]; replaced = 1 }
      else lines[NR] = $0
      if ($0 ~ /^[ \t]*##[ \t]/) body = 1
      if (!body && $0 ~ /^[ \t]*>/) last_quote = NR
    }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (!replaced && i == last_quote) print ENVIRON["WF_NOTE"]
      }
    }
  ' "$brief_md" > "$brief_md.tmp" && mv "$brief_md.tmp" "$brief_md"
}

# ── Move the INDEX.md row between sections ─────────────────────────────
# Take-then-put, both from wf-orch-lib.sh so the row is carried verbatim: what
# a human wrote about their own idea survives the move. A brief with no row at
# all is drift (wf-list-brainstorms.sh --drift); say so rather than inventing a
# row from the filename.
move_index_row() {
  local target="$1" row
  [ -f "$INDEX" ] || { echo "no INDEX.md — brief header updated, index not touched" >&2; return 0; }

  # `## Parked` is newer than every index in the field, so the first park in a
  # project creates it — with the one-line blurb every other section has, or
  # the section reads as something a script dropped in rather than part of the
  # backlog.
  if [ "$target" = "Parked" ] && ! grep -qE '^## Parked[ \t]*$' "$INDEX"; then
    printf '\n## Parked\n> Set aside on purpose — not being explored, kept for the record with a dated reason.\n' >> "$INDEX"
  fi
  if ! row=$(wf_index_take_row "$INDEX" "$base"); then
    # No row to move: this brief is drift as well as parked — the legacy case
    # this verb exists for. Writing the row instead of refusing is what makes
    # parking a complete cleanup: after it, the brief is listed, not counted,
    # and one command (--parked) says why. Refusing would leave it exactly as
    # forgettable as it was, and demand a reindex first for the one brief the
    # operator has already decided about.
    local title
    title=$(wf_brief_title "$brief_md")
    row="- [${base}](${base}) — ${title}"
    echo "note: $base had no INDEX.md row — added one under ## $target" >&2
  fi
  wf_index_put_row "$INDEX" "$target" "$row"
}

if $clear; then
  case "$status" in
    [Pp]arked*) ;;
    *) echo "$base is not parked (status: ${status:-none}) — nothing to clear"; exit 0 ;;
  esac
  # The reason line records where it came from ("was Exploring"), so unparking
  # restores the status the brief actually had rather than guessing Idea.
  prior=$(printf '%s' "$parked_field" | sed -nE 's/.*was ([A-Za-z]+).*/\1/p')
  [ -n "$prior" ] || prior="Idea"
  set_status "$prior"
  drop_field "Parked"
  move_index_row "$prior"
  msg="brief($brief_arg): unparked — back to $prior"
  result="$base unparked — $prior again, counted as an open brainstorm"
else
  case "$status" in
    [Pp]arked*) echo "$base is already parked — ${parked_field:-no reason recorded}"; exit 0 ;;
  esac
  was="$status"
  [ -n "$was" ] || was="unknown"
  case "$was" in *"|"*) was="unknown" ;; esac   # unedited template prose
  set_status "Parked"
  add_parked_note "$(date +%Y-%m-%d) — was $was — $why"
  move_index_row "Parked"
  msg="brief($brief_arg): parked — $why"
  result="$base parked — $why"
fi

if $do_commit; then
  add_paths=("$brief_md")
  [ -f "$INDEX" ] && add_paths+=("$INDEX")
  if ! "$SELF_DIR/wf-commit.sh" "$msg" --add "${add_paths[@]}"; then
    echo "Error: $brief_md is written but could not be committed — commit it before another worker does" >&2
    exit 1
  fi
fi

echo "$result"
