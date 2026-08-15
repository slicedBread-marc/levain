#!/usr/bin/env bash
# wf-bug-new.sh "<title>" [options]
#
# Files a bug: allocates its ID through the counter, writes bug.md in the shape
# the rest of the pipeline parses, and commits it.
#
#   --severity  Critical|High|Medium|Low   (default: Medium)
#   --source    <who filed it>             (default: human; agents pass agent:wf-verify etc.)
#   --project   <repo or app>
#   --slug      <kebab-case>               (default: derived from the title)
#   --description / --steps / --expected / --actual / --links / --notes  <text>
#   --no-commit                            leave it staged for the caller
#
# Output is an eval contract:
#   BUG_ID='BUG-041'
#   BUG_DIR='bugs/open/BUG-041-login-crash'
# Everything else goes to stderr.
#
# WHY THIS EXISTS
#
# Every skill that files a bug — wf-bug, wf-verify's broad-scope security path,
# wf-implement's out-of-scope defect path — carried the same instruction as a
# comment: "create bugs/open/BUG-NNN-<slug>/bug.md with these fields". A comment
# addressed to a model is a suggestion. client-a filed BUG-051 and BUG-052 by
# hand without going near wf-counter-next.sh, then reported that no script for
# this existed at all and reached for a `wf-bug-new.sh` that wasn't there
# (WFI-133). The counter is described everywhere as the only allocator; it is
# only actually the only allocator if using it is easier than not.
#
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Bug work is develop-root work: the paths below are relative, and a verify or
# implement worker's CWD is inside a feature worktree, where bugs/ is excluded.
# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

title=""
severity="Medium"
source_who="human"
project=""
slug=""
description=""
steps=""
expected=""
actual=""
links=""
notes=""
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --severity)    severity="${2:?--severity requires a value}"; shift 2 ;;
    --source)      source_who="${2:?--source requires a value}"; shift 2 ;;
    --project)     project="${2:?--project requires a value}"; shift 2 ;;
    --slug)        slug="${2:?--slug requires a value}"; shift 2 ;;
    --description) description="${2:?--description requires a value}"; shift 2 ;;
    --steps)       steps="${2:?--steps requires a value}"; shift 2 ;;
    --expected)    expected="${2:?--expected requires a value}"; shift 2 ;;
    --actual)      actual="${2:?--actual requires a value}"; shift 2 ;;
    --links)       links="${2:?--links requires a value}"; shift 2 ;;
    --notes)       notes="${2:?--notes requires a value}"; shift 2 ;;
    --no-commit)   do_commit=false; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  if [ -z "$title" ]; then title="$1"; else
          echo "Error: unexpected argument '$1' — the title is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$title" ]; then
  echo "Usage: $0 \"<title>\" [--severity Critical|High|Medium|Low] [--source <who>] [--slug <kebab>] ..." >&2
  exit 1
fi

case "$severity" in
  Critical|High|Medium|Low) ;;
  *) echo "Error: --severity must be Critical, High, Medium or Low (got '$severity')" >&2; exit 1 ;;
esac

# Derive the slug from the title when none was given: lowercase, non-alphanumerics
# to single hyphens, trimmed, capped at 6 words so the folder name stays readable.
if [ -z "$slug" ]; then
  slug=$(printf '%s' "$title" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\{1,\}/-/g' -e 's/^-//' -e 's/-$//' \
    | awk -F'-' '{ n = (NF > 6) ? 6 : NF; out = $1; for (i = 2; i <= n; i++) out = out "-" $i; print out }' \
    | sed -E 's/-(a|an|the|of|on|in|to|is|it|at|by|for|and|or|when|with|from|that)$//')
fi
[ -n "$slug" ] || slug="untitled"

# The counter is the allocator, and it commits its own increment — an
# allocation that is not committed can be taken back by a stash or a concurrent
# checkout, and the same number then goes out twice.
bug_id=$("$SELF_DIR/wf-counter-next.sh" BUG)
bug_dir="bugs/open/$bug_id-$slug"

if [ -e "$bug_dir" ]; then
  echo "Error: $bug_dir already exists — refusing to overwrite it" >&2
  exit 1
fi

mkdir -p "$bug_dir"

{
  printf '# %s\n\n' "$title"
  printf '> **Status:** Open\n'
  printf '> **ID:** %s\n' "$bug_id"
  printf '> **Filed:** %s\n' "$(date +%Y-%m-%d)"
  [ -n "$project" ] && printf '> **Project:** %s\n' "$project"
  printf '> **Severity:** %s\n' "$severity"
  printf '> **Source:** %s\n' "$source_who"
  printf '> **Plan:** _(none — link added by /wf-spec when a fix plan is created)_\n'
  printf '> **Links:** %s\n' "${links:-_(none)_}"
  printf '\n## Description\n%s\n' "${description:-TBD}"
  printf '\n## Steps to Reproduce\n%s\n' "${steps:-TBD}"
  printf '\n## Expected\n%s\n' "${expected:-TBD}"
  printf '\n## Actual\n%s\n' "${actual:-TBD}"
  printf '\n## Notes\n%s\n' "${notes:-—}"
} > "$bug_dir/bug.md"

echo "$bug_id filed → $bug_dir" >&2

if $do_commit; then
  # >&2: stdout is the eval contract above, and wf-commit.sh reports what it
  # committed on stdout. A caller running `eval "$(wf-bug-new.sh …)"` would
  # otherwise execute that report as shell.
  if ! "$SELF_DIR/wf-commit.sh" "bug($bug_id): $title" --add "$bug_dir" >&2; then
    echo "wf-bug-new: $bug_dir is written but could not be committed — commit it before another worker does" >&2
  fi
fi

printf "BUG_ID='%s'\n" "$bug_id"
printf "BUG_DIR='%s'\n" "$bug_dir"
