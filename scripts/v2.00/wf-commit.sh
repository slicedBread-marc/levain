#!/usr/bin/env bash
# wf-commit.sh <message> [--add <path>...] [--allow-empty]
#
# Commits exactly the paths it is given, and nothing else.
#
# WHY THIS EXISTS
#
# `git add <paths> && git commit -m "..."` does not commit those paths. It
# commits THE WHOLE INDEX. On develop that index is shared: the orchestrator
# runs `spec`, `consistency` and `test` workers concurrently in the same
# working directory, and per-role concurrency caps do not help because the race
# is across roles, not within one.
#
# client-a hit it from both directions inside two minutes:
#
#   WFI-048 — wf-consistency staged its plan folder and its commit also
#     swallowed a BUG-020 open→triaged rename another worker had staged
#     moments earlier. Your commit eats a stranger's work.
#
#   WFI-049 — wf-spec staged PLN-020's plan files and the REGISTRY draft→ready
#     transition; before it could commit, another worker's commit consumed the
#     index. wf-spec's own `git diff --cached` came back empty and it had
#     nothing left to commit. A stranger's commit eats yours.
#
# The second is the worse one. wf-spec's unattended exit requires that an
# approval be auditable after the fact — and after this, `git log --grep
# PLN-020` returns nothing at all. History says an unrelated workflow issue was
# filed. The plan was reviewed and approved and no commit says so.
#
# A pathspec commit (`git commit -m msg -- <paths>`) is immune: it builds the
# commit from those paths only and leaves every other index entry staged and
# untouched. wf-infra-sync.sh already reasoned this out for install.sh racing a
# worker; this generalizes it so every caller gets it.
#
# TWO TRAPS, both already met in this repo:
#
#   · `git commit -- <untracked path>` fails the whole commit with "pathspec
#     did not match any file(s) known to git". So paths are staged first, then
#     the real list is read back from the index — every element is then known
#     to git by construction (the wf-infra-sync.sh lesson).
#
#   · An empty commit cannot be scoped by pathspec at all, and a bare
#     `git commit --allow-empty` would sweep the shared index — the exact bug.
#     So --allow-empty with nothing to commit is built with plumbing: a commit
#     whose tree IS HEAD's tree, which cannot carry anyone else's work.
#
# Exit 0 on success or when there was nothing to do; 1 on a real git failure.

set -euo pipefail

# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"

message="${1:-}"
shift || true

paths=()
allow_empty=false

while [ $# -gt 0 ]; do
  case "$1" in
    --add)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do paths+=("$1"); shift; done
      ;;
    --allow-empty) allow_empty=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$message" ]; then
  echo "Usage: $0 <message> [--add <path>...] [--allow-empty]" >&2
  exit 1
fi

# Serialize commits in this repo. The pathspec is what makes the commit
# correct; the lock keeps two workers from colliding on .git/index.lock and
# keeps the stage→commit window from interleaving. Re-entrant, so a caller
# already holding it (wf-registry-update.sh) does not deadlock.
wf_lock_acquire commit

if [ "${#paths[@]}" -gt 0 ]; then
  git add -- "${paths[@]}" 2>/dev/null || true
fi

# Read the list back from the index rather than trusting the requested paths:
# a directory pathspec, a gitignored file, or a path that did not change all
# resolve here to exactly what git will accept.
changed=()
if [ "${#paths[@]}" -gt 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && changed+=("$f")
  done < <(git diff --cached --name-only -- "${paths[@]}" 2>/dev/null || true)
fi

if [ "${#changed[@]}" -gt 0 ]; then
  git commit -q -m "$message" -- "${changed[@]}"
  echo "committed ${#changed[@]} path(s): $message"
  exit 0
fi

if [ "$allow_empty" != "true" ]; then
  echo "wf-commit: nothing to commit for the given paths — skipped"
  exit 0
fi

# Empty marker commit, built so it cannot pick up anything staged by anyone
# else: same tree as HEAD, one parent, index and working tree untouched.
if ! head_sha=$(git rev-parse --verify HEAD 2>/dev/null); then
  echo "wf-commit: no HEAD yet — nothing to mark" >&2
  exit 0
fi
tree=$(git rev-parse "HEAD^{tree}")
new=$(git commit-tree "$tree" -p "$head_sha" -m "$message")
git update-ref HEAD "$new"
echo "committed (empty marker): $message"
