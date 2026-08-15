#!/usr/bin/env bash
# wf-bug-close.sh <bug-id> <plan-name> [--no-commit]
# wf-bug-close.sh <bug-id> --duplicate-of <ID> [--no-commit]
#
# Moves a bug to closed and marks it as resolved.
# Updates bug.md Status to Closed with date and either the fixing plan or the
# artifact it duplicates.
#
# CLOSING IS IDEMPOTENT, AND IT ACCEPTS A BUG WHEREVER IT ACTUALLY IS
#
# This searched `bugs/triaged/` and nothing else, and exited 1 for anything it
# did not find there. Two callers close bugs — `/wf-test` at plan completion and
# `/wf-deploy` step 9 — and client-a watched one sweep where 8 of 11
# completed plans had their bug moved by wf-test and 3 did not, with identical
# plan metadata (WFI-143). So step 9 met a mix: a hard `Error: BUG-NNN not found
# in bugs/triaged/` for the 8 already closed, and real work for the 3 that were
# not, with nothing telling the operator which was which.
#
# A bug that is already closed is the outcome this script exists to produce, so
# it is success, not an error. And a bug still in `bugs/open/` is closable: a
# duplicate never gets triaged at all, which left no scripted way to close one
# — BUG-061 was closed by hand, editing three fields and a `git mv` across two
# paths, with only the caller's pathspec deciding which side landed (WFI-139).
#
# The rename is COMMITTED here, not left staged for the caller — the same
# reasoning that moved wf-bug-consume.sh (WFI-106, WFI-112).
#
# A rename is two paths, and only the caller's pathspec decides which of them
# land. wf-test's completion commit named `bugs/closed/BUG-NNN-<slug>/` and
# nothing else, so the addition was committed and the staged deletion was
# orphaned: six bugs on client-a ended up tracked at BOTH paths in the same
# HEAD, each with a stale `Status: Triaged` copy beside the authoritative
# closed one, and a seventh blocked a release-branch merge outright (WFI-136).
# The caller's pathspec cannot know about a path this script chose; so this
# script commits both sides itself.
#
# Example: wf-bug-close.sh BUG-003 PLN-005-login-crash
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

bug_id=""
plan_name=""
duplicate_of=""
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit)    do_commit=false; shift ;;
    --duplicate-of) duplicate_of="${2:?--duplicate-of requires an artifact ID}"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  if [ -z "$bug_id" ]; then bug_id="$1"; else plan_name="$1"; fi; shift ;;
  esac
done

if [ -n "$duplicate_of" ] && [ -n "$plan_name" ]; then
  echo "Error: a bug is closed by a plan or as a duplicate, not both." >&2
  exit 1
fi

if [ -z "$bug_id" ] || { [ -z "$plan_name" ] && [ -z "$duplicate_of" ]; }; then
  echo "Usage: $0 <bug-id> <plan-name> [--no-commit]" >&2
  echo "       $0 <bug-id> --duplicate-of <ID> [--no-commit]" >&2
  exit 1
fi

# ── Where is the bug? ─────────────────────────────────────────────────────
#
# triaged first (the normal path), then open (a duplicate is never triaged),
# then closed — which is not a failure but the answer. See the header.
bug_dir=""
found_in=""
for stage in triaged open; do
  for d in bugs/$stage/${bug_id}*/; do
    if [ -d "$d" ]; then bug_dir="${d%/}"; found_in="$stage"; break 2; fi
  done
done

if [ -z "$bug_dir" ]; then
  for d in bugs/closed/${bug_id}*/; do
    if [ -d "$d" ]; then
      why=$(grep -m1 -E '^(Fixed by plan|Closed as duplicate of):' "$d/bug.md" 2>/dev/null || true)
      echo "$bug_id already closed${why:+ — $why} — nothing to do"
      exit 0
    fi
  done
  echo "Error: $bug_id not found in bugs/triaged/, bugs/open/ or bugs/closed/" >&2
  exit 1
fi

if [ "$found_in" = "open" ] && [ -n "$plan_name" ]; then
  echo "Note: $bug_id was still in bugs/open/ — closing it anyway, fixed by $plan_name" >&2
fi

bug_slug=$(basename "$bug_dir")
today=$(date +%Y-%m-%d)

if [ -n "$duplicate_of" ]; then
  close_note="Closed as duplicate of: $duplicate_of — closed by decision, not fixed"
  close_line="duplicate of $duplicate_of"
else
  close_note="Fixed by plan: $plan_name"
  close_line="fixed by $plan_name"
fi

# Update bug.md.
#
# Rewrite when present, insert when absent — a pure sub() silently does nothing
# on a header that lacks the line, which is how a bug was once triaged while
# recording neither its status nor its plan (WFI-037). The status being replaced
# is whatever is there: `Open` for a duplicate that never reached triage,
# `Triaged` for the normal path.
if [ -f "$bug_dir/bug.md" ]; then
  # awk into a tempfile — `sed -i ''` is macOS-only
  awk -v today="$today" -v note="$close_note" '
    BEGIN { saw_status = 0; saw_closed = 0; saw_notes = 0; body_started = 0; last_quote = 0 }
    {
      if ($0 ~ /Status:\*\*/) { sub(/Status:\*\*.*/, "Status:** Closed"); saw_status = 1 }
      if ($0 ~ /Closed:\*\*/) { sub(/Closed:\*\*.*/, "Closed:** " today);  saw_closed = 1 }
      lines[NR] = $0
      # The header is the blockquote above the first `##`; track its LAST line,
      # so a blank line inside it does not split the block (wf-bug-consume.sh).
      if ($0 ~ /^[ \t]*##[ \t]/) body_started = 1
      if (!body_started && $0 ~ /^[ \t]*>/) last_quote = NR
    }
    END {
      header_end = (last_quote > 0) ? last_quote : ((NR > 0) ? 1 : 0)
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (i == header_end) {
          if (!saw_status) print "> **Status:** Closed"
          if (!saw_closed) print "> **Closed:** " today
        }
        if (lines[i] ~ /^## Notes/ && !saw_notes) { print note; saw_notes = 1 }
      }
      if (!saw_notes) { print ""; print "## Notes"; print note }
    }
  ' "$bug_dir/bug.md" > "$bug_dir/bug.md.tmp" && mv "$bug_dir/bug.md.tmp" "$bug_dir/bug.md"

  # The rename is the visible half of the close and the record is the half that
  # matters, so prove the record landed rather than assuming it (WFI-037).
  if ! grep -q 'Status:\*\* Closed' "$bug_dir/bug.md"; then
    echo "Error: could not record Status in $bug_dir/bug.md — not moving the bug" >&2
    exit 1
  fi
fi

# Move to closed. Same fallback as wf-bug-consume.sh: `git mv` fails on a folder
# git has never seen, which a bug filed and fixed inside one session still is.
mkdir -p bugs/closed
git add -- "$bug_dir" >/dev/null 2>&1 || true
if ! git mv "$bug_dir" "bugs/closed/$bug_slug" 2>/dev/null; then
  mv "$bug_dir" "bugs/closed/$bug_slug"
fi

echo "$bug_id → closed ($close_line)"

# Land it now, naming BOTH sides of the rename — `git diff --cached --name-only
# --no-renames` is how wf-commit.sh builds its pathspec, so the destination
# alone leaves the deletion staged for whoever commits next (WFI-136). The
# source side is the stage the bug was actually found in, not always triaged.
if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): closed — $close_line" \
        --add "bugs/$found_in/$bug_slug" "bugs/closed/$bug_slug"; then
    echo "wf-bug-close: the move is staged but could not be committed — commit it before another worker does" >&2
  fi
fi
