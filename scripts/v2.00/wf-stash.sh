#!/usr/bin/env bash
# wf-stash.sh push|pop <label>
#
# A stash that can only ever restore its own work.
#
# WHY THIS EXISTS
#
# wf-test brackets its develop merge with `git stash --include-untracked` and a
# later `git stash pop 2>/dev/null || true`. That pop is positional: it restores
# whatever sits at `stash@{0}`, which is only the right entry if this run
# actually pushed one.
#
# It very often has not. `git stash` on a clean tree saves NOTHING and still
# exits 0, so the pop reaches straight past it to the previous session's entry.
# A stale stash is the normal state after any interrupted wf-test run — which is
# precisely when the next run is most likely to hit this.
#
# client-a hit it live (WFI-036): develop was clean, `stash@{0}` was an
# 18-file superseded workflow deploy left by an earlier run, and popping it
# would have reverted that day's skills and overwritten WORKFLOW-ISSUES.md. The
# next line in the skill then commits whatever landed in `plans/`, so the
# damage would have been committed automatically. The `git checkout HEAD --`
# guard that follows the pop covered 2 of those 18 files.
#
# So: record the stash this run created, and pop that exact commit or nothing.
#
#   push — stashes only if there is something to stash. Records the resulting
#          stash commit under .git/. Prints WF_STASHED=true|false.
#   pop  — restores the recorded commit, wherever it has drifted to in the
#          stack. No record means this run stashed nothing, and popping is
#          therefore not a no-op but a mistake — so it does nothing and says so.
#
# Both are safe to call unconditionally, in either order, any number of times.
# Exit 0 unless the working tree genuinely conflicts with the restore.

set -euo pipefail

action="${1:-}"
label="${2:-default}"

case "$action" in
  push|pop) ;;
  *) echo "Usage: $0 push|pop <label>" >&2; exit 1 ;;
esac

git_dir=$(git rev-parse --git-dir 2>/dev/null || true)
if [ -z "$git_dir" ]; then
  echo "Error: not in a git repository" >&2
  exit 1
fi

# Per-worktree by construction: `--git-dir` in a linked worktree points at
# .git/worktrees/<name>, so two worktrees never share a marker.
safe_label=$(printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '-')
marker="$git_dir/wf-stash-$safe_label"

if [ "$action" = "push" ]; then
  # A pre-existing marker means an earlier push never got its pop. Keep the
  # older one — it holds work that is still unrestored — and refuse to stash
  # again under the same label rather than burying it.
  if [ -f "$marker" ]; then
    echo "wf-stash: '$label' already holds an unrestored stash — not stashing again" >&2
    echo "WF_STASHED=false"
    exit 0
  fi

  before=$(git stash list | wc -l | tr -d ' ')
  git stash push --include-untracked -m "wf-stash: $label" >/dev/null 2>&1 || true
  after=$(git stash list | wc -l | tr -d ' ')

  if [ "$after" -gt "$before" ]; then
    git rev-parse 'stash@{0}' > "$marker"
    echo "wf-stash: stashed working tree as '$label'" >&2
    echo "WF_STASHED=true"
  else
    # Nothing to save. Deliberately no marker — this is the exact state that
    # made the old unconditional pop restore a stranger's work.
    echo "WF_STASHED=false"
  fi
  exit 0
fi

# ── pop ───────────────────────────────────────────────────────────────────
if [ ! -f "$marker" ]; then
  echo "WF_RESTORED=false"
  exit 0
fi

want=$(tr -d '[:space:]' < "$marker")
[ -n "$want" ] || { rm -f "$marker"; echo "WF_RESTORED=false"; exit 0; }

# Find where our entry sits NOW. Another stash pushed in between shifts every
# index, so the recorded position would be wrong; the commit SHA does not move.
ref=""
while IFS=' ' read -r name sha; do
  [ "$sha" = "$want" ] && { ref="$name"; break; }
done < <(git stash list --format='%gd %H' 2>/dev/null || true)

if [ -z "$ref" ]; then
  echo "wf-stash: '$label' is recorded but no longer in the stack — already restored?" >&2
  rm -f "$marker"
  echo "WF_RESTORED=false"
  exit 0
fi

if git stash pop "$ref" >/dev/null 2>&1; then
  rm -f "$marker"
  echo "wf-stash: restored '$label'" >&2
  echo "WF_RESTORED=true"
else
  # Conflict on restore. Leave the marker and the entry in place — the work is
  # still recoverable, and dropping either would lose it.
  echo "wf-stash: '$label' conflicts with the working tree; left at $ref" >&2
  echo "      Resolve, then: git stash drop $ref && rm $marker" >&2
  echo "WF_RESTORED=conflict"
  exit 1
fi
