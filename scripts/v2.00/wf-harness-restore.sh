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
# TWO RECOVERIES, IN THIS ORDER
#
# 1. THE LIBRARY. `install.sh` writes its own path to .claude/workflow-source
#    (untracked, so a checkout cannot delete it). Re-running it regenerates the
#    harness the project's .claude/workflow-version actually names.
#
# 2. HISTORY. The files are still on whatever ref has not taken the untrack
#    commit yet: check them out, then drop them from the index again, which
#    returns them to exactly the state the ignore rules describe — present on
#    disk, invisible to git. Needs no library and no network.
#
# History was the only recovery until v6.3.1, and on its own it is a trap. The
# newest ref that still TRACKS the harness is by definition a ref from before
# that client's untrack commit — so the older the migration, the staler the
# restore. client-a's WFI-119: the search landed on a v3.3.0-era commit and
# installed those scripts into a project stamped 6.2.1, reporting success.
# Three major versions of stale wf-* scripts is exactly the failure WFI-014
# warns about, arrived at by running the recovery as documented.
#
# So the ref's own .claude/workflow-version is read and compared. A matching
# ref is preferred; a stale one is still used when it is all there is — a stale
# harness beats no dispatcher — but it says so, loudly, and exits 3.
#
#   --check   report only: exit 0 if the harness is intact, 1 if it is not.
#
# Exit 0 restored (or already intact), 1 --check found it missing, 2 it is
# missing and nothing in this repository or on this machine can restore it,
# 3 restored from a ref whose workflow version does not match this project's.

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

# Reading an absent file is a SHELL redirection error, which `2>/dev/null` on
# the command does not suppress — it prints "No such file or directory" from
# the shell itself. Both of these files are routinely absent.
read_stamp() { [ -f "$1" ] && tr -d '[:space:]' < "$1" || true; }

# What this project says it should be running. Empty in a pre-v5 client.
want_version=$(read_stamp .claude/workflow-version)

# ── 1. The library, if this machine still has it ──────────────────────────
#
# .claude/workflow-source is UNTRACKED, and that has a consequence in a git
# worktree: untracked files are not materialised there, so the file exists in
# the MAIN checkout and nowhere else. client-a's WFI-191 ran the documented
# recovery inside a dedicated release worktree, `cat .claude/workflow-source`
# came back empty, and the guarded one-liner became a silent no-op that exited
# 0 — the operator had to go read the file out of the main checkout by hand.
#
# So the main worktree is the fallback. `git worktree list` reports it first,
# and it is where install.sh wrote the path.
library=$(read_stamp .claude/workflow-source)
if [ -z "$library" ]; then
  main_root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  if [ -n "$main_root" ] && [ "$main_root" != "$(pwd)" ]; then
    library=$(read_stamp "$main_root/.claude/workflow-source")
    [ -n "$library" ] && echo "Read the library path from the main worktree at $main_root"
  fi
fi
if [ -n "$library" ] && [ -f "$library/install.sh" ]; then
  echo "Restoring from the workflow library at $library ..."
  if bash "$library/install.sh" "$(pwd)" >/dev/null 2>&1 && harness_intact; then
    got=$(read_stamp .claude/workflow-version)
    echo "Harness reinstalled from the library (workflow ${got:-unknown})"
    exit 0
  fi
  echo "Warning: the library install did not produce a usable harness — falling back to history." >&2
fi

# ── 2. History ────────────────────────────────────────────────────────────
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
#
# Two passes, because "carries the files" and "carries the RIGHT files" are
# different questions. Pass 1 takes only a ref whose own
# .claude/workflow-version matches what this project declares; pass 2 accepts
# any carrying ref and the caller is told what it got (WFI-119).
restored_from=""
restored_version=""
reflog_refs=""
for n in $(seq 1 40); do reflog_refs="$reflog_refs HEAD@{$n}"; done

ref_version() {
  git show "$1:.claude/workflow-version" 2>/dev/null | tr -d '[:space:]' || true
}

for pass in matching any; do
  # shellcheck disable=SC2086
  for ref in $reflog_refs main origin/main release origin/release; do
    git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
    git ls-tree -r --name-only "$ref" -- scripts/wf-exec.sh 2>/dev/null | grep -q . || continue
    v=$(ref_version "$ref")
    if [ "$pass" = "matching" ]; then
      [ -n "$want_version" ] && [ "$v" = "$want_version" ] || continue
    fi
    restored_from="$ref"
    restored_version="$v"
    break
  done
  [ -n "$restored_from" ] && break
done

if [ -z "$restored_from" ]; then
  echo "Error: no ref in this repository still tracks scripts/wf-exec.sh," >&2
  echo "       and no workflow library is recorded in .claude/workflow-source." >&2
  echo "       Re-run the workflow library's install.sh against this project:" >&2
  echo "         bash /path/to/lv-levain/install.sh $(pwd)" >&2
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

# Say what was actually installed. A restore that reports nothing but success
# while putting a three-major-versions-old harness on disk is the whole of
# WFI-119, and the version was knowable the entire time.
if [ -n "$want_version" ] && [ "$restored_version" != "$want_version" ]; then
  echo "" >&2
  echo "WARNING: this harness is STALE." >&2
  echo "  restored: workflow ${restored_version:-unknown} (from $restored_from)" >&2
  echo "  declared: workflow $want_version (.claude/workflow-version)" >&2
  echo "  The newest ref that still TRACKS the harness necessarily predates this" >&2
  echo "  client's untrack commit, so history cannot hold a current copy. You are" >&2
  echo "  running wf-* scripts from another workflow generation (WFI-014)." >&2
  echo "  Fix it by reinstalling from the library, which is the real recovery:" >&2
  echo "    bash /path/to/lv-levain/install.sh $(pwd)" >&2
  exit 3
fi
