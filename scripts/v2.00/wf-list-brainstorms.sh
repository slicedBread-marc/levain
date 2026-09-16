#!/usr/bin/env bash
# wf-list-brainstorms.sh [--count] [--parked] [--drift]
#
# Lists INCOMPLETE BRAINSTORMS — briefs whose exploration never concluded.
#
# WHAT "INCOMPLETE" MEANS
#
# A brainstorm is a brief (`plans/briefs/BRF-NNN-*.md`, written by
# /wf-brainstorm), and `plans/briefs/INDEX.md` is the backlog: one section per
# status.
#
#   ## Idea → ## Exploring → ## Decided → ## Planned    plus Reference, Parked
#
# `Decided` is a FINISHED brainstorm: the thinking concluded and the brief is
# now the planner's input — already visible on the board as specable work and
# then as a `draft` plan. `Planned` and `Reference` are records, and `Parked`
# is a decision to stop carrying one. So incomplete is exactly `## Idea` and
# `## Exploring`: a brief someone started thinking about and never carried to
# a decision.
#
# Nothing else on the board can show that number. The pipeline histogram counts
# `PLN-` rows in REGISTRY.md; wf-list-specable.sh offers only `Decided` briefs.
# An idea captured and forgotten is invisible to every other surface, which is
# the whole reason this exists.
#
# THE INDEX IS THE SOURCE OF TRUTH, AND DRIFT IS REPORTED, NOT ABSORBED
#
# INDEX.md is maintained by hand, so a brief file can exist with no row in it —
# client-e had ten such briefs at Idea/Exploring against one that was listed.
# Counting brief-file headers instead would dodge that, but then the index (the
# thing a human actually reads, and the thing /wf-brainstorm renders on
# startup) stays wrong forever and the backlog is two disagreeing lists.
#
# So: the count comes from the index, and an unlisted brief file is reported as
# DRIFT rather than silently counted or silently dropped — to stderr in listing
# mode, on its own with `--drift`, and as `brainstorms_drift` on the board.
# `wf-brainstorm-reindex.sh` is the fix for a project carrying legacy drift.
#
# PARKING — the exit for a brainstorm nobody is carrying forward
#
# Without an exit, an idea nobody will pick up counts against the project
# forever and the number becomes noise a human learns to ignore. `## Parked`
# is that exit: `wf-brief-park.sh` moves the row there and stamps the brief
# with a dated reason. Parked briefs are not counted and not drift — and
# `--parked` lists them, so parking sets work aside without hiding it.
#
#   --count    print just the number (still exit 1 when it is zero)
#   --parked   list parked briefs instead — what was set aside, and why
#   --drift    list brief files with no INDEX.md row (exit 0 if any)
#
# Output: <id>\t<status>\t<name>\t<description>  (tab-separated)
# Exit 0 if any rows, 1 if none.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

mode="open"
count_only=false

while [ $# -gt 0 ]; do
  case "$1" in
    --count)   count_only=true; shift ;;
    --parked)  mode="parked"; shift ;;
    --drift)   mode="drift"; shift ;;
    -h|--help) wf_usage; exit 0 ;;
    *) echo "Usage: $0 [--count] [--parked] [--drift]" >&2; exit 1 ;;
  esac
done

cd "$(wf_develop_root)" || exit 1   # plans/* is develop-root work

INDEX="plans/briefs/INDEX.md"

# ── Which sections count ───────────────────────────────────────────────
# One place, so the board, coordinator' grid and a human all read the same definition.
case "$mode" in
  open)   WANTED="Idea Exploring" ;;
  parked) WANTED="Parked" ;;
  *)      WANTED="" ;;
esac

# ── Drift: brief files with no row in the index ────────────────────────
# Computed even in listing mode, because an idea missing from the backlog is
# exactly the idea that gets forgotten.
drift_rows=""
drift_n=0
if [ -f "$INDEX" ]; then
  for brief_md in plans/briefs/*.md; do
    [ -f "$brief_md" ] || continue
    base=$(basename "$brief_md")
    case "$base" in INDEX.md|TEMPLATE.md) continue ;; esac
    grep -qF "$base" "$INDEX" && continue

    # NOT EVERY UNLISTED BRIEF IS DRIFT
    #
    # /wf-brainstorm is told to REMOVE a brief's row once its plan reaches
    # `complete`: `## Planned` filling up with shipped work buries anything
    # still live under it (client-c WFI-028). So a graduated brief is
    # unlisted on purpose, and calling that drift would report 43 problems in
    # client-e, 40 of them the index working as designed — and would invite
    # wf-brainstorm-reindex.sh to put every shipped brief back.
    #
    # The test is the one wf-list-specable.sh already uses for "this brief is
    # done with": a plan exists for it (wf_brief_has_plan). A brief claiming
    # `Planned` with no plan anywhere is NOT excused — that is the shape a run
    # that died between stamping the brief and writing the plan leaves behind,
    # and it should be seen.
    wf_brief_has_plan "$brief_md" && continue

    id=$(printf '%s' "$base" | grep -oE '^BRF-[0-9]+' | head -1)
    # A pre-ID brief (plans/briefs/hotspot-maps.md and friends) predates the
    # counter. Name it by its filename rather than dropping it.
    [ -n "$id" ] || id="${base%.md}"
    status=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Status:\*\*' "$brief_md" 2>/dev/null \
             | sed -E 's/^.*\*\*Status:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)
    # TEMPLATE prose left unedited ("Idea | Exploring | Decided | Planned")
    # says nothing about this brief; report it as unknown rather than as a
    # status it does not have.
    case "$status" in ""|*"|"*) status="unknown" ;; esac
    title=$(head -1 "$brief_md" | sed 's/^#[[:space:]]*//')
    [ -n "$title" ] || title="(untitled)"
    drift_rows="${drift_rows}${id}	${status}	${base}	${title}
"
    drift_n=$((drift_n + 1))
  done
fi

if [ "$mode" = "drift" ]; then
  if $count_only; then echo "$drift_n"; else [ "$drift_n" -gt 0 ] && printf '%s' "$drift_rows"; fi
  [ "$drift_n" -gt 0 ] && exit 0
  exit 1
fi

# ── The listed backlog ─────────────────────────────────────────────────
rows=""
n=0
if [ -f "$INDEX" ]; then
  section=""
  while IFS= read -r line; do
    case "$line" in
      "## "*) section=$(printf '%s' "$line" | sed 's/^## //; s/[[:space:]]*$//'); continue ;;
    esac
    case "$line" in "- ["*) ;; *) continue ;; esac
    case " $WANTED " in *" $section "*) ;; *) continue ;; esac

    name=$(printf '%s' "$line" | sed 's/^\- \[//; s/\].*//')
    link=$(printf '%s' "$line" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
    id=$(printf '%s' "$link" | grep -oE 'BRF-[0-9]+' | head -1)
    [ -n "$id" ] || id=$(printf '%s' "$name" | grep -oE 'BRF-[0-9]+' | head -1)
    [ -n "$id" ] || id="${link%.md}"
    [ -n "$id" ] || id="—"
    desc=$(printf '%s' "$line" | sed 's/^[^—]*— //')
    [ "$desc" = "$line" ] && desc=""

    # In parked mode the useful second column is WHY, not the section — the
    # section is already `Parked` for every row here. The reason is on the
    # brief itself, dated, written by whoever parked it.
    detail="$section"
    if [ "$mode" = "parked" ] && [ -f "plans/briefs/$link" ]; then
      detail=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Parked:\*\*' "plans/briefs/$link" 2>/dev/null \
               | sed -E 's/^.*\*\*Parked:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)
      [ -n "$detail" ] || detail="(no reason recorded)"
    fi

    rows="${rows}${id}	${detail}	${name}	${desc}
"
    n=$((n + 1))
  done < "$INDEX"
fi

if $count_only; then
  echo "$n"
else
  [ "$n" -gt 0 ] && printf '%s' "$rows"
  # Same convention as wf-list-specable.sh's blocked briefs: what a consumer
  # parses stays on stdout, what a human needs to know goes to stderr.
  if [ "$drift_n" -gt 0 ] && [ "$mode" = "open" ]; then
    echo "$drift_n brief file(s) missing from INDEX.md — run wf-list-brainstorms.sh --drift" >&2
  fi
fi

[ "$n" -gt 0 ] && exit 0
exit 1
