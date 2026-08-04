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
# untouched. The now-deleted wf-infra-sync.sh reasoned this out first, for
# install.sh racing a worker; this generalizes it so every caller gets it.
#
# TWO TRAPS, both already met in this repo:
#
#   · `git commit -- <untracked path>` fails the whole commit with "pathspec
#     did not match any file(s) known to git". So paths are staged first, then
#     the real list is read back from the index — every element is then known
#     to git by construction.
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

# Stage one path at a time, and do NOT discard the result.
#
# This was a single `git add -- "${paths[@]}" 2>/dev/null || true`, which fails
# two ways that both end at the same silent no-op:
#
#   WFI-053 — `git add` is ATOMIC across its pathspecs. Callers pass a fixed
#     list including `plans/deferred-criteria.md`, and a project that has never
#     deferred a criterion does not have that file, so git aborts the WHOLE add
#     with "did not match any files" and stages nothing. wf-spec then committed
#     only what another script had already staged, reported "committed 2
#     path(s)", and left the new plan folder untracked — the registry said
#     `ready` for a plan whose plan.md was not in the repo, and a builder
#     picked it up and moved it to `active` against a folder git had never seen.
#
#   WFI-057 — a concurrent worker holding .git/index.lock makes the add fail
#     outright. The failure was swallowed, `git diff --cached` was then
#     legitimately empty, and the script announced "nothing to commit" and
#     exited 0 while the caller's modified file sat unstaged. Under the
#     orchestrator this is routine, not rare.
#
# So the two outcomes that must never look alike — "there was nothing to do"
# and "my write was lost" — were reported identically, with the same exit code,
# by the script written to close exactly that auditability hole.
#
# Now: a pathspec matching nothing is benign and skipped (it is how callers
# name optional files); a lock is retried; anything else fails loudly.
if [ "${#paths[@]}" -gt 0 ]; then
  for p in "${paths[@]}"; do
    add_err=""
    attempt=0
    while :; do
      if add_err=$(git add -- "$p" 2>&1); then add_err=""; break; fi
      case "$add_err" in
        *"did not match any file"*)
          # Named but never created here. Not this commit's problem.
          add_err=""; break ;;
        *index.lock*|*"Unable to create"*)
          attempt=$((attempt + 1))
          [ "$attempt" -lt 5 ] || break
          sleep 1 ;;
        *) break ;;
      esac
    done
    if [ -n "$add_err" ]; then
      echo "wf-commit: git add failed for '$p' — not committing." >&2
      printf '%s\n' "$add_err" >&2
      exit 1
    fi
  done
fi

# Read the list back from the index rather than trusting the requested paths:
# a directory pathspec, a gitignored file, or a path that did not change all
# resolve here to exactly what git will accept.
#
# --no-renames is load-bearing. `git diff --cached --name-only` reports a
# rename as ONE path — the destination — so the source never reaches the
# `git commit -- <paths>` pathspec below and its deletion stays staged.
#
# WFI-066: `wf-commit.sh ... --add bugs/` after wf-bug-consume.sh's
# open→triaged `git mv` reported "committed 5 path(s)" and left HEAD holding
# the same bug in bugs/open/ AND bugs/triaged/. The next worklist re-offered
# the still-open copy as an unplanned bug, which is how two spec workers ended
# up on one artifact (WFI-067). Every bug consumed by a spec run hit this.
changed=()
if [ "${#paths[@]}" -gt 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && changed+=("$f")
  done < <(git diff --cached --name-only --no-renames -- "${paths[@]}" 2>/dev/null || true)
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
