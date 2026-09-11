#!/usr/bin/env bash
# wf-bug-consume.sh <bug-id> <plan-id> [--no-commit] [--force]
# Moves a bug from open → triaged and links it to a plan.
# Updates bug.md Status to Triaged and sets Plan field.
#
# THE NUMBER IS NOT THE IDENTITY, AND FOR ONE RUN IT WAS NOT EVEN STABLE
#
# This used to find its bug by globbing `bugs/open/<id>*/` and nothing else. An
# artifact ID handed to an unattended worker was assumed to keep naming the same
# artifact for the life of the run, and on client-a it did not: commit
# 671983e renumbered BUG-137 → BUG-136 while a wf-spec worker dispatched on
# BUG-137 was drafting from that bug's content, and a different bug took the
# BUG-137 number. wf-claim.sh kept reporting the claim as held throughout,
# because claims key on the number too, so nothing signalled the change.
#
# The consume then matched by number alone and triaged the UNRELATED new
# BUG-137 — a bug about image parsing — into a plan about API versions, writing
# `Plan: PLN-137-devops-per-resource-api-version` into it and moving it out of
# bugs/open/ where its own planner would have found it. Exit 0, no warning
# (WFI-167).
#
# So two things are checked before the move, and either one refuses (exit 2):
#
#   1. The plan's own `> **Bug:**` field, when it has one, must name this bug.
#      A plan that says it is for a different bug is not evidence of a rename;
#      it is a contradiction, and consuming on top of it makes the plan wrong
#      in two places instead of one (WFI-169).
#
#   2. A bug added to the repository AFTER the plan folder's first commit
#      cannot be the bug the plan was drafted from. That is the renumber
#      signature exactly, and it needs no guess about titles.
#
# --force performs the move anyway, for an operator repairing one of these by
# hand. Neither check fires when the evidence is missing — an uncommitted plan
# folder, a plan with no Bug field — because a refusal on absent evidence would
# block the ordinary first consume of every new bug.
#
# The rename is COMMITTED here, not left staged for the caller.
#
# It used to be left staged, for wf-spec's exit commit to name alongside the
# plan. That put a staged rename on the shared develop index for the whole
# review loop — three rounds and ~20 minutes on client-a's BUG-031 — and a
# staged path on a shared index belongs to whoever commits next. Twice in one
# hour it was somebody else: once an unrelated plan's test commit (WFI-112),
# once a feature-branch merge, which sweeps the entire index by construction
# and no pathspec discipline in the writing worker can prevent (WFI-106). Both
# times the content was right and the audit trail said a different plan did it.
# By the time wf-spec's own commit ran there was nothing left to stage.
#
# A commit is not stealable. --no-commit restores the old behaviour for a
# caller that really does want to bundle it.
#
# Example: wf-bug-consume.sh BUG-003 PLN-005-login-crash
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

bug_id=""
plan_id=""
do_commit=true
force=false

while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit) do_commit=false; shift ;;
    --force)     force=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  if [ -z "$bug_id" ]; then bug_id="$1"; else plan_id="$1"; fi; shift ;;
  esac
done

if [ -z "$bug_id" ] || [ -z "$plan_id" ]; then
  echo "Usage: $0 <bug-id> <plan-id> [--no-commit] [--force]" >&2
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

# ── Already in triaged/, but never actually linked ────────────────────────
#
# `triaged/` normally means "wf-bug-consume.sh already ran" — but a bug can
# land there another way: an unrelated commit moves it (a different plan's
# housekeeping, a hand-authored fix) without ever writing Status/Plan into
# bug.md. client-e's BUG-054 hit exactly this — moved open→triaged by a
# commit that had nothing to do with consuming it — and the bug then had no
# documented path to being linked to the plan that actually consumes it
# (WFI-015). Refusing outright is wrong: the bug IS triaged, it is just
# missing the record of why.
#
# So: fall back to triaged/ when open/ has nothing, and skip the move below
# (there is nothing left to move) but still write Status/Plan and commit that.
already_triaged=false
if [ -z "$bug_dir" ]; then
  for d in bugs/triaged/${bug_id}*/; do
    if [ -d "$d" ]; then
      bug_dir="${d%/}"
      already_triaged=true
      break
    fi
  done
fi

if [ -z "$bug_dir" ]; then
  echo "Error: $bug_id not found in bugs/open/ or bugs/triaged/" >&2
  exit 1
fi

bug_slug=$(basename "$bug_dir")
plan_dir="plans/$plan_id"

# ── Is this the bug the plan was drafted from? ────────────────────────────
#
# Both checks below are silent when there is nothing to check against. See the
# header for why they exist and what they refuse.
refuse() {
  echo "Error: $bug_id is not the bug $plan_id was drafted from." >&2
  echo "  $1" >&2
  echo "  Nothing was moved. A number that changed mid-run is the usual cause (WFI-167):" >&2
  echo "  check what \$bug_id names NOW before consuming it. --force overrides." >&2
  exit 2
}

if ! $force; then
  # 1. The plan says which bug it is for.
  if [ -f "$plan_dir/plan.md" ]; then
    declared=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Bug:\*\*' "$plan_dir/plan.md" 2>/dev/null \
               | grep -oE 'BUG-[0-9]+' | head -1 || true)
    if [ -n "$declared" ] && [ "$declared" != "$bug_id" ]; then
      refuse "$plan_dir/plan.md names $declared in its Bug field, not $bug_id."
    fi
  fi

  # 2. A bug that did not exist when the plan was written cannot be its source.
  #
  #    Asked as ancestry, not as timestamps: a bug filed and a plan drafted in
  #    the same second are the ordinary case in a fast unattended run, and
  #    `%ct > %ct` cannot order them. "Is the commit that introduced this bug an
  #    ancestor of the one that introduced the plan?" is exact and needs no
  #    clock. A commit is its own ancestor, so a bug and plan landing together
  #    pass.
  #
  #    --follow, so a bug already renamed once is traced to when it was filed
  #    rather than to the rename.
  bug_added=$(git log --diff-filter=A --follow --format=%H -- "$bug_dir/bug.md" 2>/dev/null | tail -1 || true)
  plan_added=$(git log --diff-filter=A --format=%H -- "$plan_dir" 2>/dev/null | tail -1 || true)
  if [ -n "$bug_added" ] && [ -n "$plan_added" ] \
     && ! git merge-base --is-ancestor "$bug_added" "$plan_added" 2>/dev/null; then
    refuse "$bug_dir was filed after $plan_dir was written — $(git log -1 --format=%h\ %s "$bug_added" 2>/dev/null) is not an ancestor of $(git log -1 --format=%h\ %s "$plan_added" 2>/dev/null)."
  fi
fi

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

if $already_triaged; then
  # Already in triaged/ — nothing to move, only the record was missing.
  echo "$bug_id already in bugs/triaged/ — linked to $plan_id"
  if $do_commit; then
    if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): linked to $plan_id (was already triaged)" \
          --add "bugs/triaged/$bug_slug"; then
      echo "wf-bug-consume: the link is staged but could not be committed — commit it before another worker does" >&2
    fi
  fi
  exit 0
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

# Land it now. Both sides of the rename are named, because `git diff --cached
# --name-only --no-renames` is how wf-commit.sh builds its pathspec and a
# rename is two paths — naming only the destination leaves the deletion staged,
# which is how a bug once appeared in bugs/open/ AND bugs/triaged/ at the same
# HEAD (WFI-066).
if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): triaged — consumed by $plan_id" \
        --add "bugs/open/$bug_slug" "bugs/triaged/$bug_slug"; then
    echo "wf-bug-consume: the move is staged but could not be committed — commit it before another worker does" >&2
  fi
fi
