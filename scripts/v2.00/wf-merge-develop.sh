#!/usr/bin/env bash
# wf-merge-develop.sh
# Merges develop into the current feature branch, auto-resolving conflicts
# in plans/ and .plan-ref by taking develop's version (these files belong
# to develop, not feature branches).
#
# Exit codes:
#   0 — merge succeeded (clean or auto-resolved)
#   1 — non-plan conflicts remain (caller must resolve)

set -euo pipefail

# Must be on a feature branch
branch=$(git branch --show-current)
[[ "$branch" == feature/* ]] || { echo "Error: not on a feature branch (on $branch)" >&2; exit 1; }

# Auto-claim: mark this plan as actively being worked on
develop_root=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
plan_name=$(echo "$branch" | sed 's#^feature/##')
claim_dir="$develop_root/plans/$plan_name"
if [ -d "$claim_dir" ]; then
  _pid=$PPID
  for _i in 1 2 3 4 5; do
    _name=$(ps -o comm= -p "$_pid" 2>/dev/null)
    case "$_name" in bash|sh|zsh|dash) _pid=$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ') ;; *) break ;; esac
  done
  printf '%s\n%s\n' "$(date +%s)" "$_pid" > "$claim_dir/.wf-claim"
fi

# ── Refresh the harness, before and after ───────────────────────────────────
#
# The three runtime paths a session needs on disk (.claude/skills/wf-*,
# .claude/workflow.md, scripts/wf-exec.sh) are GITIGNORED as of v5.0.0, so they
# are invisible to git: they cannot be dirty, cannot conflict, and cannot abort
# this merge. All of the reconciliation that used to live here — an infra-sync
# commit before merging, and `git checkout develop --` for a dozen paths — was
# managing a problem that no longer exists.
#
# The pre-merge call is what makes the v5.0.0 migration self-healing. A feature
# branch cut BEFORE the untrack commit still tracks those paths; merging
# develop applies the deletion and strips them from this worktree mid-plan. The
# post-merge call puts them straight back as ignored files, so the session
# survives a migration that happened underneath it.
# Before merging: if the harness is still TRACKED here — a branch cut before
# the v5.0.0 migration — a deploy will have left it modified, and `git merge`
# aborts on that ("your local changes would be overwritten") BEFORE it can
# deliver the very commit that untracks it. The worktree would be permanently
# unable to take the migration.
#
# Discarding those modifications is safe precisely because the content is
# generated: the post-merge copy below reproduces it from the main worktree.
for _p in .claude/workflow.md scripts/wf-exec.sh .claude/skills/wf-*/SKILL.md; do
  git ls-files --error-unmatch "$_p" >/dev/null 2>&1 || continue
  git checkout -- "$_p" 2>/dev/null || true
done

# NOTE: no harness COPY here, only the clean above. Copying before the merge
# re-dirties the very files just restored — the main worktree holds develop's
# newer content, which is exactly what makes them differ from this branch's
# committed blob. The copy belongs after the merge, once they are untracked and
# git can no longer see them (_restore_harness below).

# ── Reset develop-only content for non-sparse worktrees ─────────────────────
# Legacy (non-sparse) worktrees still track plans/, bugs/ and templates/ —
# reset them to develop's version before merging so they cannot cause
# dirty-tree failures or conflicts. Sparse worktrees never have them on disk.
if ! git config core.sparseCheckout 2>/dev/null | grep -q true; then
  needs_sync=false
  # Do NOT sync .claude/workflow-version — it's the plan's immovable WF stamp
  # and must not change mid-flight. Dispatcher routes on this value.
  git checkout develop -- plans/ 2>/dev/null && needs_sync=true || true
  git checkout develop -- bugs/ 2>/dev/null && needs_sync=true || true
  git checkout develop -- briefs/ 2>/dev/null && needs_sync=true || true
  git checkout develop -- templates/ 2>/dev/null && needs_sync=true || true
  if $needs_sync; then
    "$(dirname "$0")/wf-commit.sh" "chore: sync plan content from develop" \
      --add plans/ bugs/ briefs/ templates/ >/dev/null 2>&1 || true
  fi
fi

# Restore the harness after the merge, on every successful path.
#
# This is the half that makes the v5.0.0 migration self-healing: a feature
# branch cut before the untrack commit still tracks those paths, so merging
# develop DELETES them from this worktree. Putting them back as ignored files
# leaves the session working and the tree clean.
_restore_harness() { "$(dirname "$0")/wf-worktree-harness.sh" . >/dev/null 2>&1 || true; }

# Attempt clean merge first
if git merge develop --no-edit 2>/dev/null; then
  _restore_harness
  echo "Merged develop cleanly."
  exit 0
fi

echo "Merge conflicts detected — auto-resolving plan files..."

# If no MERGE_HEAD, the merge was aborted (dirty working tree), not conflicted.
if ! git rev-parse MERGE_HEAD >/dev/null 2>&1; then
  echo "Error: merge aborted — working tree has uncommitted changes that would be overwritten." >&2
  echo "Run 'git status' to see which files are dirty, then commit or stash them." >&2
  exit 1
fi

# Auto-resolve plans/ and .plan-ref by taking develop's version
# Use ls-files -u instead of diff --diff-filter=U: the latter skips files excluded
# by sparse checkout, leaving hidden unmerged index entries that block git commit.
conflicted=$(git ls-files -u | awk '{print $4}' | sort -u)
has_non_plan_conflicts=false

while IFS= read -r file; do
  [ -z "$file" ] && continue
  if [[ "$file" == plans/* ]] || [[ "$file" == bugs/* ]] || [[ "$file" == briefs/* ]] || [[ "$file" == .claude/* ]] || [[ "$file" == scripts/* ]] || [[ "$file" == skills/* ]] || [[ "$file" == templates/* ]]; then
    git checkout develop -- "$file" 2>/dev/null || git checkout --theirs -- "$file"
    git add "$file"
    echo "  resolved: $file (took develop's version)"
  elif [[ "$file" == .plan-ref ]]; then
    # Derive plan ID from branch name — more reliable than git checkout --ours
    # which can fail with "pathspec did not match" in some conflict states
    plan_id=$(echo "$branch" | sed 's#^feature/##; s#^\(PLN-[0-9]*\).*#\1#')
    echo "$plan_id" > "$file"
    git add "$file"
    echo "  resolved: $file (kept $plan_id from branch name)"
  else
    has_non_plan_conflicts=true
    echo "  CONFLICT: $file (requires manual resolution)"
  fi
done <<< "$conflicted"

if $has_non_plan_conflicts; then
  echo ""
  echo "Error: non-plan conflicts remain. Resolve them, then run: git commit --no-edit"
  exit 1
fi

git commit --no-edit
_restore_harness
echo "Merged develop with auto-resolved plan files."
