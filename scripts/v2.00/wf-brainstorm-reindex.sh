#!/usr/bin/env bash
# wf-brainstorm-reindex.sh [--apply] [--no-commit]
#
# Repairs INDEX.md drift: adds a row for every brief file that has none, under
# the section its own `> **Status:**` header names.
#
# WHY THIS EXISTS
#
# `plans/briefs/INDEX.md` is the backlog of record — it is what /wf-brainstorm
# renders on startup, what wf-list-specable.sh reads, and as of
# wf-list-brainstorms.sh it is where the board's incomplete-brainstorm count
# comes from. It is also maintained by hand, so it drifts: client-e carried
# ten briefs at Idea/Exploring with no row in it at all (BRF-038, 041, 042,
# 052, 061 and five pre-ID files), against one that was listed. An idea with
# no row is invisible to every surface a human looks at.
#
# This is the one-time cleanup for that legacy data, and the repair for any
# drift that appears later. It only ADDS rows — it never moves, rewrites or
# deletes one, because an existing row is a human's own words about their own
# idea and the file header is not a better source for it. A brief whose header
# says nothing usable lands under `## Idea`, the section that means "captured,
# not yet explored", which is exactly what an unindexed brief is.
#
# Dry run by default: prints what it would add, changes nothing. `--apply`
# writes and commits.
#
# Exit 0 if the index is clean or was repaired, 1 on error, 2 when a dry run
# found drift (so a check can fail a build on it).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

apply=false
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)     apply=true; shift ;;
    --no-commit) do_commit=false; shift ;;
    -h|--help)   wf_usage; exit 0 ;;
    *) echo "Usage: $0 [--apply] [--no-commit]" >&2; exit 1 ;;
  esac
done

cd "$(wf_develop_root)"

INDEX="plans/briefs/INDEX.md"
if [ ! -f "$INDEX" ]; then
  echo "Error: no $INDEX — nothing to reindex" >&2
  exit 1
fi

# Section per status. Anything else — a missing header, unedited template
# prose, a status nobody recognises — goes to Idea rather than to a section
# invented on the spot.
section_for() {
  case "$1" in
    [Ee]xploring*) echo "Exploring" ;;
    [Dd]ecided*)   echo "Decided" ;;
    [Pp]lanned*)   echo "Planned" ;;
    [Rr]eference*) echo "Reference" ;;
    [Pp]arked*)    echo "Parked" ;;
    *)             echo "Idea" ;;
  esac
}

pending=""
n=0
for brief_md in plans/briefs/*.md; do
  [ -f "$brief_md" ] || continue
  base=$(basename "$brief_md")
  case "$base" in INDEX.md|TEMPLATE.md) continue ;; esac
  grep -qF "$base" "$INDEX" && continue

  # A brief whose plan exists is unlisted ON PURPOSE — /wf-brainstorm removes
  # the row once the plan ships, so `## Planned` doesn't bury live work
  # (client-c WFI-028). Re-adding those would undo that pruning wholesale:
  # 40 of client-e's 43 unlisted briefs are exactly this case.
  wf_brief_has_plan "$brief_md" && continue

  status=$(wf_brief_status "$brief_md")
  section=$(section_for "$status")

  title=$(wf_brief_title "$brief_md")
  # Em dash, filename link text: the row shape every hand-written row in the
  # field already uses, so a repaired index reads like the rest of it.
  pending="${pending}${section}	- [${base}](${base}) — ${title}
"
  n=$((n + 1))
done

if [ "$n" -eq 0 ]; then
  echo "INDEX.md lists every brief — no drift"
  exit 0
fi

if ! $apply; then
  printf '%s brief file(s) missing from INDEX.md:\n' "$n"
  printf '%s' "$pending" | while IFS=$'\t' read -r section row; do
    printf '  %-10s %s\n' "$section" "$row"
  done
  printf '\nRe-run with --apply to add them.\n'
  exit 2
fi

# Append each row under its section, creating the section if the index predates
# it (`## Parked` is newer than every index in the field).
while IFS=$'\t' read -r section row; do
  [ -n "$section" ] || continue
  wf_index_put_row "$INDEX" "$section" "$row"
done <<EOF
$pending
EOF

echo "Added $n row(s) to $INDEX"

if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "brainstorm: reindex — $n brief(s) added to INDEX.md" --add "$INDEX"; then
    echo "Error: $INDEX is written but could not be committed" >&2
    exit 1
  fi
fi
