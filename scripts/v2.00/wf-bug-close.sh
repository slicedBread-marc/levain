#!/usr/bin/env bash
# wf-bug-close.sh <bug-id> <plan-name> [--no-commit]
# wf-bug-close.sh <bug-id> --duplicate-of <ID> [--no-commit]
# wf-bug-close.sh <bug-id> --fixed-in <sha> [--note <text>] [--no-commit]
# wf-bug-close.sh <bug-id> --wont-fix [--note <text>] [--no-commit]
#
# Moves a bug to closed and marks it as resolved.
# Updates bug.md Status to Closed with date and the reason: the fixing plan,
# the artifact it duplicates, the commit that fixed it directly, or the decision
# not to fix it at all.
#
# NOT EVERY FIX IS WORTH A PLAN, AND THE ONES THAT ARE NOT WERE UNCLOSEABLE
#
# The two close reasons above assume a bug either gets a plan or turns out to
# be a duplicate. A third case is common and had no path at all: a bug fixed
# directly on develop in one small commit, no plan, nothing to spec. /wf-deploy
# closes bugs by plan and never reaches it, and this script's own usage line
# demanded a plan name — so client-a's BUG-076, fixed by a 12-line script
# change in b5fc375, could only be closed by inventing a plan ID that does not
# exist. It was left Open instead, fixed and stuck, invisible to the board
# forever (WFI-149).
#
# `--fixed-in <sha>` is that path. The commit is the evidence, in place of the
# plan that would otherwise carry it.
#
# AND NOT EVERY BUG GETS FIXED
#
# The argument above has an exact mirror. A bug the human decides not to fix —
# a needs-input gate answered "won't fix / defer indefinitely" — is decided and
# stuck in precisely the way WFI-149 describes, with none of the three reasons
# fitting: there is no plan, there is no commit, and `--duplicate-of` would put
# a false duplicate into the record just to reach the one phrase that says
# "closed by decision, not fixed". client-a's BUG-183 was closed by hand
# instead — a `git mv` and an edit, with only the operator's pathspec deciding
# whether both sides of the rename landed (WFI-195, and WFI-136 for what goes
# wrong when they do not).
#
# `--wont-fix` is that path. The decision is the resolution; `--note` carries
# the reason, and is worth giving.
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
# THE SUCCESS LINE IS PRINTED AFTER THE COMMIT, NOT BEFORE
#
# It used to be printed before, and that one ordering made every failure after
# it silent. client-a's WFI-192: /wf-deploy step 9 piped 14 consecutive
# closes through `head -1` to keep the output short. `head` exits after the
# first line, the next write takes SIGPIPE, and the script died between
# `git mv` and the commit. All 14 printed `BUG-NNN → closed` and none of them
# committed — indistinguishable, in the output, from the two that did.
#
# The damage compounds because the index is not per-branch: the 14 staged
# renames survived a `git checkout release` in the same worktree and turned up
# staged on release, where a later unrelated commit would have swept them in.
# That is the WFI-048/049 shape reached with no second worker involved. It was
# caught only by diffing `git ls-tree main:bugs/closed` against the closes the
# caller believed it had made; trusting the output would have pushed main with
# 14 bugs still in triaged.
#
# So: the line is printed once the commit has returned, a failed commit exits
# 1, and a death anywhere in the staging window says on stderr that a rename is
# staged and uncommitted. `head -1` was that caller's doing, but any early-
# closing pipe, any timeout and any kill reproduce it — the ordering is what
# made it silent.
#
# What is deliberately NOT done here is refusing to start when the index
# already holds unrelated staged paths. On develop that index is shared by
# concurrent workers by design, and wf-commit.sh's pathspec is what makes each
# commit correct in spite of it (WFI-048, WFI-049). A refusal would make the
# normal orchestrated case fail.
#
# Example: wf-bug-close.sh BUG-003 PLN-005-login-crash
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

bug_id=""
plan_name=""
duplicate_of=""
fixed_in=""
wont_fix=false
close_note_extra=""
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit)    do_commit=false; shift ;;
    --duplicate-of) duplicate_of="${2:?--duplicate-of requires an artifact ID}"; shift 2 ;;
    --fixed-in)     fixed_in="${2:?--fixed-in requires a commit sha}"; shift 2 ;;
    --wont-fix)     wont_fix=true; shift ;;
    --note)         close_note_extra="${2:?--note requires a value}"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  if [ -z "$bug_id" ]; then bug_id="$1"; else plan_name="$1"; fi; shift ;;
  esac
done

# Exactly one reason. Two would leave bug.md claiming two different resolutions.
reasons=0
[ -n "$plan_name" ]    && reasons=$((reasons + 1))
[ -n "$duplicate_of" ] && reasons=$((reasons + 1))
[ -n "$fixed_in" ]     && reasons=$((reasons + 1))
$wont_fix              && reasons=$((reasons + 1))

if [ "$reasons" -gt 1 ]; then
  echo "Error: a bug is closed by a plan, as a duplicate, by a commit, or as won't-fix — pick one." >&2
  exit 1
fi

if [ -z "$bug_id" ] || [ "$reasons" -eq 0 ]; then
  echo "Usage: $0 <bug-id> <plan-name> [--no-commit]" >&2
  echo "       $0 <bug-id> --duplicate-of <ID> [--no-commit]" >&2
  echo "       $0 <bug-id> --fixed-in <sha> [--note <text>] [--no-commit]" >&2
  echo "       $0 <bug-id> --wont-fix [--note <text>] [--no-commit]" >&2
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
      why=$(grep -m1 -E "^(Fixed by plan|Fixed directly in|Closed as duplicate of|Closed as won't-fix):" "$d/bug.md" 2>/dev/null || true)
      # "Already closed" is only the whole answer when the close was COMMITTED.
      # A run that died in the staging window (WFI-192) leaves the bug at
      # bugs/closed/ on disk with the rename staged, and a re-run must finish
      # that job rather than declare it done — otherwise the recovery for the
      # failure is itself silent.
      if $do_commit && [ -n "$(git status --porcelain -- "bugs" 2>/dev/null | grep -F "${bug_id}" || true)" ]; then
        echo "$bug_id is at bugs/closed/ but the move is not committed — committing it now" >&2
        if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): closed" \
              --add "bugs/triaged/$(basename "$d")" "bugs/open/$(basename "$d")" "bugs/closed/$(basename "$d")"; then
          echo "Error: $bug_id is staged at bugs/closed/ and could not be committed — commit it before another worker does" >&2
          exit 1
        fi
      fi
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
elif $wont_fix; then
  # The reason is the whole record, so say so where the note would otherwise be
  # missed: a won't-fix with no reason is a bug that will be re-filed.
  close_note="Closed as won't-fix: ${close_note_extra:-no reason recorded} — closed by decision, not fixed"
  close_line="won't fix"
  [ -n "$close_note_extra" ] || \
    echo "Note: closing $bug_id as won't-fix with no --note — the reason is the only record of this decision" >&2
elif [ -n "$fixed_in" ]; then
  # The commit is the whole record here, so resolve it and carry its subject:
  # a bare sha in bug.md is unreadable a month later, and an unresolvable one
  # is a record of nothing. A sha this repo cannot see is still recorded — the
  # fix may live in another repo — but the caller is told it was not verified.
  subject=$(git log -1 --format='%h %s' "$fixed_in" 2>/dev/null || true)
  if [ -n "$subject" ]; then
    close_note="Fixed directly in: $subject — no plan"
    close_line="fixed in $subject"
  else
    echo "Note: $fixed_in does not resolve to a commit in this repository — recording it unverified" >&2
    close_note="Fixed directly in: $fixed_in — no plan (commit not found in this repository)"
    close_line="fixed in $fixed_in"
  fi
  [ -n "$close_note_extra" ] && close_note="$close_note
$close_note_extra"
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
  # ENVIRON for the note, not -v: awk expands escape sequences in a -v
  # assignment, and the note now carries a commit subject written by a human —
  # a backslash in it would be eaten (same reasoning as wf-defer-criterion.sh).
  WF_CLOSE_NOTE="$close_note" awk -v today="$today" '
    BEGIN { saw_status = 0; saw_closed = 0; saw_notes = 0; body_started = 0; last_quote = 0
            note = ENVIRON["WF_CLOSE_NOTE"] }
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

# From here to the commit, a rename is staged and the close is not yet real.
# Anything that kills the script in that window — an early-closing pipe on
# stdout, a timeout, a kill — must not leave the caller believing otherwise,
# and must not leave the staged rename to be swept into a stranger's commit on
# whatever branch this checkout is on next (WFI-192). Signals are trapped
# explicitly: bash runs an EXIT trap for a signal only when that signal is
# trapped too, and SIGPIPE is exactly the one that arrives here.
staged_window=false
trap '
  if [ "$staged_window" = true ]; then
    printf "wf-bug-close: DIED before committing %s — the rename is STAGED, not committed.\n" "$bug_id" >&2
    printf "              Do NOT treat this bug as closed. Unstage it (git restore --staged bugs/)\n" >&2
    printf "              or commit it before switching branches in this worktree.\n" >&2
  fi
' EXIT
trap 'exit 141' PIPE
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Move to closed. Same fallback as wf-bug-consume.sh: `git mv` fails on a folder
# git has never seen, which a bug filed and fixed inside one session still is.
mkdir -p bugs/closed
staged_window=true
git add -- "$bug_dir" >/dev/null 2>&1 || true
if ! git mv "$bug_dir" "bugs/closed/$bug_slug" 2>/dev/null; then
  mv "$bug_dir" "bugs/closed/$bug_slug"
fi

# Land it now, naming BOTH sides of the rename — `git diff --cached --name-only
# --no-renames` is how wf-commit.sh builds its pathspec, so the destination
# alone leaves the deletion staged for whoever commits next (WFI-136). The
# source side is the stage the bug was actually found in, not always triaged.
if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): closed — $close_line" \
        --add "bugs/$found_in/$bug_slug" "bugs/closed/$bug_slug"; then
    staged_window=false
    echo "Error: $bug_id was moved to bugs/closed/ and staged, but the commit FAILED." >&2
    echo "       The bug is NOT closed. Commit it before another worker does, then re-run." >&2
    exit 1
  fi
fi
staged_window=false

# Only now. The success line outliving the work is the whole of WFI-192.
if $do_commit; then
  echo "$bug_id → closed ($close_line)"
else
  echo "$bug_id → closed ($close_line) — staged, NOT committed (--no-commit)"
fi
