#!/usr/bin/env bash
# lv-bug-new.sh "<title>" [options]
#
# Files a bug: allocates its ID through the counter, writes bug.md in the shape
# the rest of the pipeline parses, and commits it.
#
#   --severity  Critical|High|Medium|Low   (default: Medium)
#   --kind      bug|request|notice         (default: bug — request is a capability ask, not a
#                                           defect; notice is an upstream change announcement
#                                           filed by lv-dep-notify.sh, not local to this project)
#   --source    <who filed it>             (default: human; agents pass agent:lv-verify etc.)
#   --project   <repo or app>
#   --slug      <kebab-case>               (default: derived from the title)
#   --description / --steps / --expected / --actual / --links / --notes  <text>
#   --no-commit                            leave it staged for the caller
#   --lane      express|normal             (default: normal) declare the express lane —
#                                           no human gate, if the written plan passes
#                                           lv-lane.sh's eligibility check. A human's
#                                           statement: refused under LV_UNATTENDED=1
#   --lane-by   <who>                      who declared it (default: git user.name)
#   --group     <slug>                     file straight into an intake group, opening it
#                                           if absent (lv-bug-group.sh): held off /lv-spec
#                                           until the overseer seals it. Refused under
#                                           LV_UNATTENDED=1. A bug whose --links says
#                                           "Amends BUG-NNN" joins that bug's Open group
#                                           without being told (LVI-024)
#
# Output is an eval contract:
#   BUG_ID='BUG-041'
#   BUG_DIR='bugs/open/BUG-041-login-crash'
# Everything else goes to stderr.
#
# WHY THIS EXISTS
#
# Every skill that files a bug — lv-bug, lv-verify's broad-scope security path,
# lv-implement's out-of-scope defect path — carried the same instruction as a
# comment: "create bugs/open/BUG-NNN-<slug>/bug.md with these fields". A comment
# addressed to a model is a suggestion. client-a filed BUG-051 and BUG-052 by
# hand without going near lv-counter-next.sh, then reported that no script for
# this existed at all and reached for a `lv-bug-new.sh` that wasn't there
# (WFI-133). The counter is described everywhere as the only allocator; it is
# only actually the only allocator if using it is easier than not.
#
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# Bug work is develop-root work: the paths below are relative, and a verify or
# implement worker's CWD is inside a feature worktree, where bugs/ is excluded.
# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

title=""
severity="Medium"
kind="bug"
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
lane="normal"
lane_by=""
group=""

while [ $# -gt 0 ]; do
  case "$1" in
    --severity)    severity="${2:?--severity requires a value}"; shift 2 ;;
    --kind)        kind="${2:?--kind requires a value}"; shift 2 ;;
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
    --lane)        lane="${2:?--lane requires a value}"; shift 2 ;;
    --lane-by)     lane_by="${2:?--lane-by requires a name}"; shift 2 ;;
    --group)       group="${2:?--group requires a slug}"; shift 2 ;;
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

case "$kind" in
  bug|request|notice) ;;
  *) echo "Error: --kind must be 'bug', 'request' or 'notice' (got '$kind')" >&2; exit 1 ;;
esac

case "$lane" in
  normal|express) ;;
  *) echo "Error: --lane must be 'express' or 'normal' (got '$lane')" >&2; exit 1 ;;
esac

# Checked before a number is allocated: a refused declaration must not leave a
# bug behind that the filer believes is in the express lane (LVI-025).
if [ "$lane" = express ] && [ "${LV_UNATTENDED:-}" = "1" ]; then
  echo "Error: --lane express is a human's statement, and this is an unattended worker (LV_UNATTENDED=1)." >&2
  echo "       A worker never declares its own work safe to ship unseen. Nothing was filed." >&2
  exit 1
fi
[ -n "$lane_by" ] || lane_by=$(git config user.name 2>/dev/null || whoami)

# An intake group is the overseer's (lv-bug-group.sh): refused before a number
# is allocated, for the same reason as the express lane above.
if [ -n "$group" ] && [ "${LV_UNATTENDED:-}" = "1" ]; then
  echo "Error: --group holds intake for the overseer, and this is an unattended worker (LV_UNATTENDED=1). Nothing was filed." >&2
  exit 1
fi
if [ -n "$group" ] && ! [[ "$group" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
  echo "Error: --group '$group' is not a kebab-case slug. Nothing was filed." >&2
  exit 1
fi
# A correction joins the batch it corrects. Without this, an amender filed
# after its target was grouped would be the one bug of the batch left
# offered on its own — the exact failure the group exists to stop (LVI-024).
if [ -z "$group" ] && [ -n "$links" ] && [ "${LV_UNATTENDED:-}" != "1" ]; then
  for t in $(printf '%s' "$links" | grep -oE "Amends[[:space:]]+($LV_BUG_RE)-[0-9]+" | grep -oE "($LV_BUG_RE)-[0-9]+" || true); do
    loc=$(wf_bug_md "$t"); [ -n "$loc" ] || continue
    g=$(wf_bug_field "${loc#*$'\t'}" Group)
    if [ -n "$g" ] && [ "$(wf_group_field "$g" Status)" = "Open" ]; then
      group="$g"; echo "lv-bug-new: amends $t, which is in open intake group $g — joining it" >&2; break
    fi
  done
fi

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
bug_id=$("$SELF_DIR/lv-counter-next.sh" bug)
bug_dir="bugs/open/$bug_id-$slug"

kind_label="Bug"
[ "$kind" = "request" ] && kind_label="Request"
[ "$kind" = "notice" ] && kind_label="Notice"

if [ -e "$bug_dir" ]; then
  echo "Error: $bug_dir already exists — refusing to overwrite it" >&2
  exit 1
fi

mkdir -p "$bug_dir"

{
  printf '# %s\n\n' "$title"
  printf '> **Status:** Open\n'
  printf '> **ID:** %s\n' "$bug_id"
  printf '> **Kind:** %s\n' "$kind_label"
  printf '> **Filed:** %s\n' "$(date +%Y-%m-%d)"
  [ -n "$project" ] && printf '> **Project:** %s\n' "$project"
  printf '> **Severity:** %s\n' "$severity"
  printf '> **Source:** %s\n' "$source_who"
  printf '> **Plan:** _(none — link added by /lv-spec when a fix plan is created)_\n'
  printf '> **Links:** %s\n' "${links:-_(none)_}"
  [ "$lane" = express ] && printf '> **Lane:** express (declared by %s, %s)\n' "$lane_by" "$(date -u +%Y-%m-%d)"
  printf '\n## Description\n%s\n' "${description:-TBD}"
  printf '\n## Steps to Reproduce\n%s\n' "${steps:-TBD}"
  printf '\n## Expected\n%s\n' "${expected:-TBD}"
  printf '\n## Actual\n%s\n' "${actual:-TBD}"
  printf '\n## Notes\n%s\n' "${notes:-—}"
} > "$bug_dir/bug.md"

echo "$bug_id filed → $bug_dir" >&2

# The events.log line is what lv-lane.sh corroborates the header field with: a
# Lane field typed into a bug by anything else does not count.
if [ "$lane" = express ]; then
  wf_event lane-declare "$bug_id" "express declared by $lane_by"
  "$SELF_DIR/lv-lane.sh" precheck "$bug_id" || true
fi

if $do_commit; then
  # >&2: stdout is the eval contract above, and lv-commit.sh reports what it
  # committed on stdout. A caller running `eval "$(lv-bug-new.sh …)"` would
  # otherwise execute that report as shell.
  if ! "$SELF_DIR/lv-commit.sh" "bug($bug_id): $title" --add "$bug_dir" >&2; then
    echo "lv-bug-new: $bug_dir is written but could not be committed — commit it before another worker does" >&2
  fi
fi

if [ -n "$group" ]; then
  if $do_commit; then
    "$SELF_DIR/lv-bug-group.sh" add "$group" "$bug_id" \
      --create "opened by filing $bug_id ($source_who)" >&2 \
      || echo "lv-bug-new: $bug_id is filed but NOT in group $group — it is offered to /lv-spec on its own. lv-bug-group.sh add $group $bug_id" >&2
  else
    echo "lv-bug-new: --no-commit — $bug_id is not added to group $group; run lv-bug-group.sh add $group $bug_id once it is committed" >&2
  fi
fi

printf "BUG_ID='%s'\n" "$bug_id"
printf "BUG_DIR='%s'\n" "$bug_dir"
