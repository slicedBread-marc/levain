#!/usr/bin/env bash
# lv-merge-release.sh
# Merges origin/release into the current feature branch, auto-resolving
# conflicts in .plan-ref by keeping the feature branch's version.
# Run this before PR merge to ensure the branch is mergeable.
#
# Exit codes:
#   0 — merge succeeded (clean or auto-resolved)
#   1 — non-trivial conflicts remain (caller must resolve)

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

# Must be on a feature branch
branch=$(git branch --show-current)
[[ "$branch" == feature/* ]] || { echo "Error: not on a feature branch (on $branch)" >&2; exit 1; }

# Retried, because this is the one step here that depends on github.com being
# reachable and everything after it is local. client-a's PLN-157 (WFI-186)
# had this time out on a clean 1734/1734 run, which routed a plan to a human to
# be told "try again". Only transient failures retry — see lv-retry.sh.
"$(dirname "$0")/lv-retry.sh" --label "git fetch origin release" -- git fetch origin release

# ── Reset release-owned plan content for non-sparse worktrees ───────────────
# The generated harness is gitignored as of v5.0.0 — invisible to git, so it
# cannot conflict here and needs no reconciliation. Only plan content does.
if ! git config core.sparseCheckout 2>/dev/null | grep -q true; then
  needs_sync=false
  # Do NOT sync .claude/workflow-version — it's the plan's immovable WF stamp.
  git checkout origin/release -- plans/ 2>/dev/null && needs_sync=true || true
  git checkout origin/release -- bugs/ 2>/dev/null && needs_sync=true || true
  git checkout origin/release -- briefs/ 2>/dev/null && needs_sync=true || true
  git checkout origin/release -- templates/ 2>/dev/null && needs_sync=true || true
  if $needs_sync; then
    "$(dirname "$0")/lv-commit.sh" "chore: sync plan content from release" \
      --add plans/ bugs/ briefs/ templates/ >/dev/null 2>&1 || true
  fi
fi


# Restore the harness after the merge, on every successful path.
#
# A branch cut before the v5.0.0 untrack commit still TRACKS these paths, so
# merging a branch that has taken it deletes them from this worktree — and they
# are gitignored afterwards, so nothing puts them back (client-c WFI-006).
# In a feature worktree the main worktree still has the files, so copying is
# enough — and copying is all that is wanted: a worktree needs only the three
# paths lv-worktree-harness.sh delivers, because lv-exec.sh resolves scripts/v*/
# from the main worktree. Reaching into git history there would put a stale
# TRACKED copy back on a branch that no longer wants one.
#
# The main worktree is the case with nowhere to copy from — client-c lost
# the harness outright on the release side (WFI-006) — so only there does the
# fallback apply. See wf_restore_harness (lv-orch-lib.sh) for the shared body.

# Attempt clean merge first
if git merge origin/release --no-edit 2>/dev/null; then
  wf_restore_harness
  echo "Merged release cleanly."
  exit 0
fi

echo "Merge conflicts detected — auto-resolving known files..."

# If no MERGE_HEAD, the merge was aborted (dirty working tree), not conflicted.
if ! git rev-parse MERGE_HEAD >/dev/null 2>&1; then
  echo "Error: merge aborted — working tree has uncommitted changes that would be overwritten." >&2
  echo "Run 'git status' to see which files are dirty, then commit or stash them." >&2
  exit 1
fi

# Use ls-files -u instead of diff --diff-filter=U: the latter skips files excluded
# by sparse checkout, leaving hidden unmerged index entries that block git commit.
conflicted=$(git ls-files -u | awk '{print $4}' | sort -u)
has_real_conflicts=false

while IFS= read -r file; do
  [ -z "$file" ] && continue
  if [[ "$file" == .plan-ref ]]; then
    # Only reachable on a branch cut before v6.0.0, when .plan-ref was still
    # committed. It is per-worktree state now (docs/worktrees.md), so resolve by
    # dropping it from the INDEX while leaving the correct ID on disk — the
    # session still reads the file, git no longer carries it to release.
    #
    # Deriving the ID from the branch name beats `git checkout --ours`, which
    # fails with "pathspec did not match" in some conflict states.
    plan_id=$(echo "$branch" | sed 's#^feature/##' | grep -oE "^($LV_PLN_RE)-[0-9]+" || echo "${branch#feature/}")
    git rm --cached -q -f -- "$file" 2>/dev/null || true
    echo "$plan_id" > "$file"
    echo "  resolved: $file (untracked; $plan_id kept on disk)"
  elif [[ "$file" == plans/* ]] || [[ "$file" == bugs/* ]] || [[ "$file" == briefs/* ]]; then
    git checkout --ours -- "$file"
    git add "$file"
    echo "  resolved: $file (kept feature branch version)"
  elif [[ "$file" == .claude/* ]] || [[ "$file" == scripts/* ]] || [[ "$file" == skills/* ]] || [[ "$file" == templates/* ]]; then
    git checkout --theirs -- "$file"
    git add "$file"
    echo "  resolved: $file (took release version)"
  else
    has_real_conflicts=true
    echo "  CONFLICT: $file (requires manual resolution)"
  fi
done <<< "$conflicted"

if $has_real_conflicts; then
  echo ""
  echo "Error: non-trivial conflicts remain. Resolve them, then run: git commit --no-edit"
  exit 1
fi

git commit --no-edit
echo "Merged release with auto-resolved files."
