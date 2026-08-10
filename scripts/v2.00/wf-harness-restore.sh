#!/usr/bin/env bash
# wf-harness-restore.sh [--check]
#
# Puts the harness back on disk after a git operation deleted it.
#
# WHY THIS EXISTS
#
# As of v5.0.0 the generated harness is gitignored in every client: the library
# is the source of truth and the client copy is build output. Adopting that is
# one commit per client — `chore: stop tracking generated workflow harness` —
# and until that commit reaches a branch, that branch still TRACKS the files.
#
# So the first git operation that brings the untrack commit onto a branch which
# still tracks them applies its deletions to the working tree, and because the
# files are gitignored afterwards, nothing puts them back. client-c ran
# `git pull origin release` inside /wf-release step 5 and lost 106 harness
# files mid-skill, including wf-exec.sh itself; the skill's own last step is
# what discovered it, with exit 127 (WFI-006). Switching back to develop does
# not help — ignored files are not restored by a checkout.
#
# The files are still in history on whatever ref has not taken the untrack
# commit yet, so recovery needs no library checkout and no network: check them
# out, then drop them from the index again, which returns them to exactly the
# state the ignore rules describe — present on disk, invisible to git.
#
#   --check   report only: exit 0 if the harness is intact, 1 if it is not.
#
# Exit 0 restored (or already intact), 1 --check found it missing, 2 it is
# missing and no ref in this repository still carries it.

set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

# The harness paths, named individually. NEVER `scripts/` wholesale: a client
# may keep its own tooling there, and `git rm -r --cached scripts` would untrack
# it — turning a recovery into a second, larger accident.
paths=(scripts/wf-exec.sh scripts/wf-prune-versions.sh scripts/version-map.txt)
for d in scripts/v*/; do [ -d "$d" ] && paths+=("${d%/}"); done
for d in .claude/skills/wf-*/; do [ -d "$d" ] && paths+=("${d%/}"); done
[ -f .claude/workflow.md ] && paths+=(.claude/workflow.md)

# Intact means the entry point is there and can dispatch: wf-exec.sh plus the
# map it resolves through plus at least one version folder.
harness_intact() {
  [ -x scripts/wf-exec.sh ] || return 1
  [ -f scripts/version-map.txt ] || return 1
  compgen -G "scripts/v*/wf-*.sh" >/dev/null 2>&1 || return 1
  return 0
}

if harness_intact; then
  $check_only && exit 0
  echo "Harness intact — nothing to restore"
  exit 0
fi

if $check_only; then
  echo "Harness is missing or incomplete at $(pwd)" >&2
  exit 1
fi

# The most recent ref that still tracks it. The reflog is searched BACKWARDS,
# entry by entry, because the deletion is not reliably one step behind.
#
# This used to try HEAD@{1} and nothing else from the reflog. client-e's
# WFI-014: `git pull origin release` in /wf-release step 5 fast-forwarded 75
# commits, sailing straight through the untrack commit, and the merge that
# followed was blamed for it. HEAD@{1} was therefore the post-pull commit —
# already past the deletion — so the path list came back empty and the restore
# was a silent no-op. HEAD@{2} carried all 82 paths. A local release branch
# many commits behind origin is the normal case, not the exception, so no fixed
# reflog distance is right; what is right is "the nearest ref that still has
# the files".
#
# main is the fallback, because main is the last branch to take the untrack
# commit and therefore the last to stop carrying the files.
restored_from=""
reflog_refs=""
for n in $(seq 1 40); do reflog_refs="$reflog_refs HEAD@{$n}"; done
# shellcheck disable=SC2086
for ref in $reflog_refs main origin/main release origin/release; do
  git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
  git ls-tree -r --name-only "$ref" -- scripts/wf-exec.sh 2>/dev/null | grep -q . || continue
  restored_from="$ref"
  break
done

if [ -z "$restored_from" ]; then
  echo "Error: no ref in this repository still tracks scripts/wf-exec.sh." >&2
  echo "       Re-run the workflow library's install.sh against this project." >&2
  exit 2
fi

# Checking out into the index is the only way git will write the files; the
# removal that follows is what makes the restore a no-op for tracked state.
tracked=$(git ls-tree -r --name-only "$restored_from" -- scripts .claude 2>/dev/null \
          | grep -E '^(scripts/(wf-exec\.sh|wf-prune-versions\.sh|version-map\.txt|v[^/]+/)|\.claude/(skills/wf-|workflow\.md))' || true)
[ -n "$tracked" ] || { echo "Error: $restored_from carries no harness paths" >&2; exit 2; }

printf '%s\n' "$tracked" | xargs git checkout "$restored_from" -- 2>/dev/null
printf '%s\n' "$tracked" | xargs git rm --cached --quiet -- 2>/dev/null || true

count=$(printf '%s\n' "$tracked" | grep -c . || true)
echo "Harness restored from $restored_from ($count files) and left untracked"

harness_intact || { echo "Error: restore did not produce a usable harness" >&2; exit 2; }
