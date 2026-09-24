#!/usr/bin/env bash
# lv-harness-restore.sh [--check]
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
# `git pull origin release` inside /lv-release step 5 and lost 106 harness
# files mid-skill, including lv-exec.sh itself; the skill's own last step is
# what discovered it, with exit 127 (WFI-006). Switching back to develop does
# not help — ignored files are not restored by a checkout.
#
# WHAT "INTACT" MEANS DEPENDS ON WHICH WORKTREE YOU ARE IN
#
# Only the MAIN worktree needs the versioned script folders. lv-exec.sh's
# find_project_root answers with the main worktree, so in a LINKED worktree
# (release-branches/main, release-branches/release, feature-branches/*) the
# whole harness is scripts/lv-exec.sh plus the lv-* skills — the versioned
# scripts, version-map.txt and scripts/current all resolve from the main
# checkout and are not supposed to be here. lv-worktree-harness.sh copies in
# exactly that much, by design.
#
# Applying the main-worktree test in a linked worktree is a false alarm, and an
# expensive one: client-a's WFI-253 saw `git merge -X theirs --no-ff release`
# delete version-map.txt inside release-branches/main, and both /lv-deploy step
# 7a and this script declared HARNESS MISSING over a dispatcher that worked.
# What actually recovered it was re-running lv-worktree-pin.sh — which is
# lv-worktree-harness.sh, recovery 1 below.
#
# THREE RECOVERIES, IN THIS ORDER
#
# 0. THE MAIN WORKTREE, when we are in a linked one. It is on the same disk,
#    already holds a complete harness, and needs neither library nor network.
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
# Three major versions of stale lv-* scripts is exactly the failure WFI-014
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
#
# 2 IS A TOTAL FAILURE TO RESTORE and the caller must treat it as one. Every
# path to it prints its reasons to stderr first; none of them returns 0.

set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

# The harness paths, named individually. NEVER `scripts/` wholesale: a client
# may keep its own tooling there, and `git rm -r --cached scripts` would untrack
# it — turning a recovery into a second, larger accident.
paths=(scripts/lv-exec.sh scripts/lv-prune-versions.sh scripts/version-map.txt)
for d in scripts/v*/; do [ -d "$d" ] && paths+=("${d%/}"); done
for d in .claude/skills/lv-*/; do [ -d "$d" ] && paths+=("${d%/}"); done
[ -f .claude/workflow.md ] && paths+=(.claude/workflow.md)

# Where the versioned scripts are supposed to live — the main worktree, which
# is the parent of the common git dir. Equal to $PWD when we ARE the main
# worktree.
main_root() {
  local common
  common=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || return 1
  dirname "$common"
}
MAIN_ROOT=$(main_root || true)
HERE=$(pwd -P)
IN_LINKED_WORKTREE=false
[ -n "$MAIN_ROOT" ] && [ "$MAIN_ROOT" != "$HERE" ] && IN_LINKED_WORKTREE=true

# Intact means the entry point is there and can dispatch. In the main worktree
# that is lv-exec.sh plus the map it resolves through plus at least one version
# folder. In a linked worktree it is lv-exec.sh here plus that same set over in
# the main worktree, because that is where this dispatcher resolves them from —
# demanding local copies there fails a working harness (WFI-253).
dispatch_set_at() {
  local r="$1"
  [ -f "$r/scripts/version-map.txt" ] || return 1
  compgen -G "$r/scripts/v*/lv-*.sh" >/dev/null 2>&1 \
    || compgen -G "$r/scripts/gen/*/v*/lv-*.sh" >/dev/null 2>&1 || return 1
  return 0
}
harness_intact() {
  [ -x scripts/lv-exec.sh ] || return 1
  if $IN_LINKED_WORKTREE; then
    dispatch_set_at "$MAIN_ROOT" || return 1
  else
    dispatch_set_at "$HERE" || return 1
  fi
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

# Whether a recovery was even attempted, so the final error can say which ones
# were tried rather than assert a library was never recorded when one was
# (WFI-253 — the operator was told "no workflow library is recorded in
# .claude/workflow-source" immediately after being told that library's install
# had failed).
tried=""

# ── 0. The main worktree, when this is a linked one ───────────────────────
#
# lv-worktree-harness.sh copies exactly the set a linked worktree needs —
# lv-exec.sh, the lv-* skills, settings.local.json — from the main checkout.
# No library, no network, no history search, and no chance of installing a
# stale generation, because the source is the harness this machine is running
# right now. This is what recovered client-a's release-branches/main after
# the promote merge deleted its tracked copies (WFI-253); it was reached by
# re-running lv-worktree-pin.sh, which calls this same script.
if $IN_LINKED_WORKTREE && dispatch_set_at "$MAIN_ROOT"; then
  tried="$tried main-worktree"
  helper=""
  for cand in "$(dirname "$0")/lv-worktree-harness.sh" \
              "$MAIN_ROOT"/scripts/gen/*/v*/lv-worktree-harness.sh \
              "$MAIN_ROOT"/scripts/v*/lv-worktree-harness.sh; do
    if [ -x "$cand" ]; then helper="$cand"; break; fi
  done
  if [ -n "$helper" ]; then
    echo "Restoring from the main worktree at $MAIN_ROOT ..."
    bash "$helper" "$HERE" || true
  else
    # Even with no helper on disk, the one file that must be here is copyable.
    mkdir -p scripts
    cp -p "$MAIN_ROOT/scripts/lv-exec.sh" scripts/lv-exec.sh 2>/dev/null || true
    chmod +x scripts/lv-exec.sh 2>/dev/null || true
  fi
  if harness_intact; then
    echo "Harness restored from the main worktree (dispatcher resolves $MAIN_ROOT/scripts)"
    exit 0
  fi
  echo "Warning: copying from the main worktree did not produce a usable harness." >&2
fi

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
    # `[ -n "$library" ] && echo ...` here would be the last command of this
    # block, so under `set -e` an empty result exits the script 1 — silently
    # skipping the history recovery that is the entire point of continuing.
    if [ -n "$library" ]; then
      echo "Read the library path from the main worktree at $main_root"
    fi
  fi
fi
if [ -n "$library" ] && [ -f "$library/install.sh" ]; then
  tried="$tried library"
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
# WFI-014: `git pull origin release` in /lv-release step 5 fast-forwarded 75
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
    git ls-tree -r --name-only "$ref" -- scripts/lv-exec.sh scripts/wf-exec.sh 2>/dev/null | grep -q . || continue
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
  # Say what was actually tried. Asserting "no workflow library is recorded"
  # two lines after reporting that library's install failed sent WFI-253's
  # operator looking for a missing config file that was there all along.
  echo "Error: the harness could not be restored at $(pwd)." >&2
  echo "       no ref in this repository still tracks scripts/lv-exec.sh or scripts/wf-exec.sh" >&2
  case " $tried " in
    *" main-worktree "*) echo "       the main worktree at $MAIN_ROOT was tried and did not produce one" >&2 ;;
  esac
  case " $tried " in
    *" library "*) echo "       the library at $library was tried and its install did not produce one" >&2 ;;
    *)             echo "       no workflow library is recorded in .claude/workflow-source" >&2 ;;
  esac
  echo "       Re-run the workflow library's install.sh against this project:" >&2
  echo "         bash /path/to/lv-levain/install.sh $(pwd)" >&2
  exit 2
fi

# Checking out into the index is the only way git will write the files; the
# removal that follows is what makes the restore a no-op for tracked state.
tracked=$(git ls-tree -r --name-only "$restored_from" -- scripts .claude 2>/dev/null \
          | grep -E '^(scripts/((lv|wf)-exec\.sh|(lv|wf)-prune-versions\.sh|version-map\.txt|v[^/]+/)|\.claude/(skills/(lv|wf)-|workflow\.md))' || true)
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
  echo "  running lv-* scripts from another workflow generation (WFI-014)." >&2
  echo "  Fix it by reinstalling from the library, which is the real recovery:" >&2
  echo "    bash /path/to/lv-levain/install.sh $(pwd)" >&2
  exit 3
fi
