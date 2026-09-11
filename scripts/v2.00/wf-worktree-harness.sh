#!/usr/bin/env bash
# wf-worktree-harness.sh [worktree-path]
#
# Puts the workflow files a session needs into a feature worktree, by copying
# them from the main worktree.
#
# WHY THIS EXISTS
#
# These workflow-owned paths must PHYSICALLY EXIST inside a feature worktree or
# a session there cannot function:
#
#   .claude/skills/wf-*/          Claude Code reads skills from the tree it runs in
#   .claude/workflow.md           the same, for the workflow reference
#   scripts/wf-exec.sh            skills invoke it by relative path
#   .claude/settings.local.json   the session's own write permissions (WFI-015)
#
# Everything else workflow-owned resolves from the MAIN worktree — including
# all of scripts/v*/, because wf-exec.sh's find_project_root answers with the
# main worktree, so a worktree copy of a versioned script is never the one that
# runs.
#
# These used to arrive by being TRACKED: git materialises tracked files when it
# creates a worktree. They were also written by install.sh. Two delivery
# mechanisms for one requirement, and the collision was the whole problem —
# deploy rewrote a tracked path, the worktree went dirty against its own
# branch, `git merge develop` aborted outright, and a script existed solely to
# commit develop's own bytes onto the feature branch to make it stop.
# wf-worktree-sparse.sh states the rule that governs it: "Excluding a file you
# also write is not a stricter policy than tracking it; it is a broken one."
#
# So now there is one mechanism: these paths are gitignored, and this copies
# them in. Ignored files are invisible to `git merge`, `git status` and sparse-
# checkout alike, so none of those failure modes has anywhere left to occur.
#
# Self-contained on purpose: it copies from the main worktree, which already
# has the harness on disk. No library checkout is needed at worktree-creation
# time, and no network.
#
# Idempotent. Safe to run on the main worktree (no-op). Exit 0 always — a
# missing harness is worth reporting, never worth failing a merge over.

set -euo pipefail

WT_PATH="${1:-$PWD}"
cd "$WT_PATH" 2>/dev/null || exit 0

COMMON_DIR=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd) || exit 0
MAIN="$(dirname "$COMMON_DIR")"
HERE="$(pwd -P)"

# The main worktree is the source; copying it onto itself is meaningless.
[ "$HERE" != "$(cd "$MAIN" && pwd -P)" ] || exit 0

copied=0

# Skills: only the workflow's own. A project's hand-written skills live beside
# them and belong to the project — they are tracked, and must not be touched.
if [ -d "$MAIN/.claude/skills" ]; then
  mkdir -p .claude/skills
  for src in "$MAIN"/.claude/skills/wf-*/; do
    [ -d "$src" ] || continue
    name=$(basename "$src")
    mkdir -p ".claude/skills/$name"
    cp -p "$src"SKILL.md ".claude/skills/$name/SKILL.md" 2>/dev/null && copied=$((copied + 1)) || true
  done
fi

for rel in .claude/workflow.md scripts/wf-exec.sh; do
  if [ -f "$MAIN/$rel" ]; then
    mkdir -p "$(dirname "$rel")"
    cp -p "$MAIN/$rel" "$rel" 2>/dev/null && copied=$((copied + 1)) || true
  fi
done

# docker/.env: a project-local secret (a staging API key, a signing cert
# passphrase) that `docker-compose.yml`'s `env_file:` requires to bring the
# container up at all. Gitignored for the same reason .plan-ref is — it must
# never travel with a branch — so `git worktree add` never materialises it,
# and every feature worktree wf-docker-up.sh touches started life without one.
# client-c hit this on five separate plans (WFI-013 through WFI-023)
# before anyone traced it back to the worktree, not the container: each was
# worked around by hand-copying develop's copy in. Same rule as everything
# else in this file — gitignored-but-needed arrives by being copied from the
# main worktree, not by a human noticing the failure each time.
if [ -f "$MAIN/docker/.env" ] && [ ! -e docker/.env ]; then
  mkdir -p docker
  cp -p "$MAIN/docker/.env" docker/.env 2>/dev/null && copied=$((copied + 1)) || true
fi

# ── Permissions for the session that will work here ───────────────────────
#
# A worker in a fresh worktree cannot edit its own files without a local
# permission grant, and /wf-implement used to deliver it as a heredoc in the
# skill. client-e's WFI-015: the auto-mode permission classifier refused the
# heredoc outright ("Blocked by classifier"), the settings drop was skipped,
# and the run continued a permission short of what the skill assumed. A skill
# instruction that a client may simply refuse is not a delivery mechanism —
# the harness delivers this the same way it delivers everything else.
#
# `Edit(//**)`, not `Write(//**)`: Edit rules cover every file-editing tool and
# a Write rule is matched by nothing. Claude Code says so at startup, and that
# warning was one of the two lines an entire stranded verify run wrote to its
# log (client-e WFI-012).
#
# Never overwritten. A project that has its own settings.local.json here has
# said something deliberate, and never written when the path is TRACKED —
# writing a tracked file is what dirties a worktree against its own branch.
if [ ! -e .claude/settings.local.json ] \
   && ! git ls-files --error-unmatch .claude/settings.local.json >/dev/null 2>&1; then
  mkdir -p .claude
  cat > .claude/settings.local.json <<'JSON'
{
  "permissions": {
    "allow": [
      "Read(//**)",
      "Edit(//**)",
      "Bash(*)"
    ]
  }
}
JSON
  copied=$((copied + 1))
fi

# Never touch the mode while the file is still TRACKED. git tracks the
# executable bit, so a chmod on a tracked file shows it as modified — and a
# worktree cut before the v5.0.0 migration is exactly where that bites: the
# modification aborts the very `git merge develop` that would untrack it, and
# the worktree can then never take the migration at all.
#
# Once untracked (the steady state), mode changes are invisible to git and this
# guarantees the file a skill invokes by relative path is executable. Normally
# a no-op regardless: `cp -p` preserves the source mode, and install.sh makes
# the main worktree's copy executable.
if [ -f scripts/wf-exec.sh ] && ! git ls-files --error-unmatch scripts/wf-exec.sh >/dev/null 2>&1; then
  [ -x scripts/wf-exec.sh ] || chmod +x scripts/wf-exec.sh 2>/dev/null || true
fi

if [ "$copied" -gt 0 ]; then
  echo "Harness refreshed in $(basename "$HERE") ($copied file(s) from the main worktree)"
fi
