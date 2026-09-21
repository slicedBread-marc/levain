#!/usr/bin/env bash
# wf-suite-receipts.sh [--abandoned [--min-age <seconds>]] [--for <ref>] [--all]
#
# Answers two questions about detached suite runs (`wf-suite-run.sh --detach`)
# that nothing could answer before:
#
#   --abandoned   which suites FINISHED and had their verdict collected by
#                 nobody. Exit 0 if any, 1 if none.
#   --for <ref>   is there already a verdict for the tree at <ref>, so the
#                 caller can act on it instead of spending the suite again.
#                 Exit 0 it passed, 1 it failed, 2 no receipt for that tip.
#   --all         every receipt, newest first. Always exit 0.
#
# WHY THIS EXISTS
#
# wf-suite-wait.sh made waiting possible; it could not make a worker wait. The
# same failure has now happened three times in five days, in three roles:
#
#   WFI-255  a DEPLOY worker wrote "Awaiting test results" and exited rc=0
#            sixty seconds later. The suite was red, `main` was merged.
#   WFI-265  a DEPLOY worker merged into local main, armed the guard, logged
#            "will check again in 90 seconds" and exited. 22 hours, no spawns.
#   WFI-266  two RELEASE workers in a row ran the 22-minute suite, announced a
#            wait, and exited. The second one's suite PASSED — 3341 of 3342,
#            0 failed — and nothing was pushed. Local release sat 4 commits
#            ahead of origin/release, which wf-list-deploy.sh reads (correctly,
#            in general) as "commits /wf-release did not push, so commits that
#            did not pass". Here that inference was exactly wrong, and the
#            dispatcher could not tell the two apart.
#
# The damage is never the wasted wall-clock. It is that a green suite and a
# never-run suite become indistinguishable, so the work has to be done again —
# or, worse, the batch looks unproven and DEPLOY stays off the candidate list
# until a human reads the refs by hand.
#
# A verdict that nobody collected is the signal. wf-suite-wait.sh writes
# <log>.status.read when it hands a verdict back, so "finished, unread" is
# exactly "a worker started this and did not stay for the answer". That is a
# fact about the pipeline, visible without reading anyone's log.
#
# THIS SCRIPT DECIDES NOTHING. It reports. Whether an abandoned green run may
# be acted on is the promotion skill's call, and it is only ever allowed to be
# yes when SUITE_TIP is the tree the caller is standing in — a pass measures
# one tree, and nothing else.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

mode="all"
min_age=120
ref=""

while [ $# -gt 0 ]; do
  case "$1" in
    --abandoned) mode="abandoned"; shift ;;
    --all)       mode="all"; shift ;;
    --for)       mode="for"; ref="${2:?--for requires a ref}"; shift 2 ;;
    --min-age)   min_age="${2:?--min-age requires seconds}"; shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "wf-suite-receipts.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

DEVELOP_ROOT="$(wf_develop_root)"
LOG_DIR="$DEVELOP_ROOT/.claude/orchestrator/logs"

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# Seconds since a file was last modified. `stat` is the one portable-by-nobody
# command here: BSD and GNU disagree on the flag, so both are tried.
age_of() {
  local f="$1" mtime
  mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo "")
  [ -n "$mtime" ] || { echo 0; return; }
  echo $(( $(date +%s) - mtime ))
}

[ -d "$LOG_DIR" ] || { [ "$mode" = "for" ] && exit 2; exit 1; }

# Newest first, so "the receipt for this tip" is the most recent one.
statuses=$(ls -t "$LOG_DIR"/*.status 2>/dev/null || true)

if [ "$mode" = "for" ]; then
  want=$(git rev-parse --verify --quiet "$ref^{commit}" 2>/dev/null || true)
  if [ -z "$want" ]; then
    echo "Error: '$ref' does not resolve to a commit here." >&2
    exit 2
  fi
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    [ "$(field "$st" SUITE_TIP)" = "$want" ] || continue
    cat "$st"
    read_at=$(field "$st.read" READ_AT)
    printf 'SUITE_COLLECTED=%s\n' "${read_at:-never}"
    grep -q '^SUITE_RESULT=pass' "$st" && exit 0
    exit 1
  done <<< "$statuses"
  echo "No suite receipt for ${want:0:9}." >&2
  exit 2
fi

found=0
while IFS= read -r st; do
  [ -n "$st" ] || continue
  log="${st%.status}"
  if [ "$mode" = "abandoned" ]; then
    [ -f "$st.read" ] && continue
    [ "$(age_of "$st")" -ge "$min_age" ] || continue
  fi
  result=$(field "$st" SUITE_RESULT)
  tip=$(field "$st" SUITE_TIP)
  branch=$(field "$st" SUITE_BRANCH)
  [ -n "$branch" ] || branch=$(field "$log.meta" SUITE_BRANCH)
  [ -n "$tip" ] || tip=$(field "$log.meta" SUITE_TIP)
  collected="never"
  [ -f "$st.read" ] && collected=$(field "$st.read" READ_AT)
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${result:-unknown}" "${branch:-—}" "${tip:0:9}" "$collected" "$log"
  found=$((found + 1))
done <<< "$statuses"

[ "$found" -gt 0 ] && exit 0
exit 1
