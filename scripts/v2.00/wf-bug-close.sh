#!/usr/bin/env bash
# wf-bug-close.sh <bug-id> <plan-name> [--no-commit]
# Moves a bug from triaged → closed and marks it as resolved.
# Updates bug.md Status to Closed with date and fixing plan.
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
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit) do_commit=false; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  if [ -z "$bug_id" ]; then bug_id="$1"; else plan_name="$1"; fi; shift ;;
  esac
done

if [ -z "$bug_id" ] || [ -z "$plan_name" ]; then
  echo "Usage: $0 <bug-id> <plan-name> [--no-commit]" >&2
  exit 1
fi

# Find the bug folder in triaged
bug_dir=""
for d in bugs/triaged/${bug_id}*/; do
  if [ -d "$d" ]; then
    bug_dir="${d%/}"
    break
  fi
done

if [ -z "$bug_dir" ]; then
  echo "Error: $bug_id not found in bugs/triaged/" >&2
  exit 1
fi

bug_slug=$(basename "$bug_dir")
today=$(date +%Y-%m-%d)

# Update bug.md
if [ -f "$bug_dir/bug.md" ]; then
  # awk into a tempfile — `sed -i ''` is macOS-only
  awk '{ sub(/Status:\*\* Triaged/, "Status:** Closed"); print }' \
    "$bug_dir/bug.md" > "$bug_dir/bug.md.tmp" && mv "$bug_dir/bug.md.tmp" "$bug_dir/bug.md"
  # Add closed date after Status line
  awk -v line="> **Closed:** $today" '
    { print }
    /Status:\*\* Closed/ && !done1 { print line; done1=1 }
  ' "$bug_dir/bug.md" > "$bug_dir/bug.md.tmp" && mv "$bug_dir/bug.md.tmp" "$bug_dir/bug.md"
  # Add note after ## Notes heading
  awk -v line="Fixed by plan: $plan_name" '
    { print }
    /^## Notes/ && !done2 { print line; done2=1 }
  ' "$bug_dir/bug.md" > "$bug_dir/bug.md.tmp" && mv "$bug_dir/bug.md.tmp" "$bug_dir/bug.md"
fi

# Move to closed. Same fallback as wf-bug-consume.sh: `git mv` fails on a folder
# git has never seen, which a bug filed and fixed inside one session still is.
mkdir -p bugs/closed
git add -- "$bug_dir" >/dev/null 2>&1 || true
if ! git mv "$bug_dir" "bugs/closed/$bug_slug" 2>/dev/null; then
  mv "$bug_dir" "bugs/closed/$bug_slug"
fi

echo "$bug_id → closed (fixed by $plan_name)"

# Land it now, naming BOTH sides of the rename — `git diff --cached --name-only
# --no-renames` is how wf-commit.sh builds its pathspec, so the destination
# alone leaves the deletion staged for whoever commits next (WFI-136).
if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): closed — fixed by $plan_name" \
        --add "bugs/triaged/$bug_slug" "bugs/closed/$bug_slug"; then
    echo "wf-bug-close: the move is staged but could not be committed — commit it before another worker does" >&2
  fi
fi
