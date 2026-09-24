#!/usr/bin/env bash
# lv-commit.sh <message> [--add <path>...] [--allow-empty] [--branch <name>]
#
# Commits exactly the paths it is given, and nothing else, on a branch that is
# allowed to carry them.
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
#   WFI-048 — lv-consistency staged its plan folder and its commit also
#     swallowed a BUG-020 open→triaged rename another worker had staged
#     moments earlier. Your commit eats a stranger's work.
#
#   WFI-049 — lv-spec staged PLN-020's plan files and the REGISTRY draft→ready
#     transition; before it could commit, another worker's commit consumed the
#     index. lv-spec's own `git diff --cached` came back empty and it had
#     nothing left to commit. A stranger's commit eats yours.
#
# The second is the worse one. lv-spec's unattended exit requires that an
# approval be auditable after the fact — and after this, `git log --grep
# PLN-020` returns nothing at all. History says an unrelated workflow issue was
# filed. The plan was reviewed and approved and no commit says so.
#
# A pathspec commit (`git commit -m msg -- <paths>`) is immune: it builds the
# commit from those paths only and leaves every other index entry staged and
# untouched. The now-deleted lv-infra-sync.sh reasoned this out first, for
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
# AND THE BRANCH IT LANDS ON
#
# A pathspec makes the commit carry the right FILES. It says nothing about
# which branch receives them, and on the shared main worktree that is not
# fixed: a concurrent interactive session can check out a topic branch at any
# point in a skill's run. Every develop-side skill checks its branch at entry
# and nothing re-checks before the commit, so client-a's WFI-120 put a
# BUG-039 open→triaged rename and an unrelated plan's progress commit onto
# `fix/BUG-039-ci-test-portability`, minutes apart, both reporting success.
#
# So the check moves to the last possible moment — here, immediately before
# the commit, which is the only place it cannot be raced. Plan content in the
# MAIN worktree belongs on an integration branch (develop / release / main);
# lv-deploy legitimately commits it on main and lv-release on release, so the
# rule names the class, not one branch. A feature worktree is exempt: legacy
# non-sparse worktrees genuinely do carry and commit plans/ (lv-merge-*.sh).
#
#   --branch <name>   require exactly this branch. For callers that know.
#
# LV_REQUIRE_BRANCH does the same thing from the environment, for a caller that
# is a SKILL rather than a script — a sequence of steps that all have to land on
# one branch, several of which commit through helpers this caller does not pass
# arguments to. `lv-deploy` step 9 is seven `lv-bug-close.sh` calls, each of
# which commits its own rename; when the shared checkout moved from main to
# develop underneath them, all seven committed to develop and nothing said so
# (client-a's WFI-157). Exporting the branch once covers every commit made in
# that window, whoever makes it. An explicit --branch wins.
#
# Exit 0 on success or when there was nothing to do; 1 on a real git failure
# or a commit refused because the branch is wrong.

set -euo pipefail

# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"
# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

message="${1:-}"
shift || true

# Before anything else: --help is not a commit message. It used to be taken as
# one, which took this script all the way to "nothing to commit for the given
# paths — skipped" and exit 0 (client-b WFI-006).
case "$message" in
  -h|--help) wf_usage; exit 0 ;;
esac

paths=()
allow_empty=false
want_branch=""

while [ $# -gt 0 ]; do
  case "$1" in
    --add)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        # Trailing slashes off. `dir/` and `dir` are the same pathspec to git in
        # the ordinary case, and not in every case — a sparse index in
        # particular treats them differently. client-a's WFI-238: an --add
        # naming `plans/PLN-265-tool-verbs-live-directory/` staged nothing and
        # reported "nothing to commit for the given paths — skipped" while
        # `git status` showed the plan.md under it modified; naming the file
        # exactly committed the same diff. The directory form is what the
        # skills document, so it is the form that has to work.
        _p="$1"
        while [ "${_p%/}" != "$_p" ] && [ "${#_p}" -gt 1 ]; do _p="${_p%/}"; done
        paths+=("$_p")
        shift
      done
      ;;
    --allow-empty) allow_empty=true; shift ;;
    --branch) shift; want_branch="${1:-}"; shift || true ;;
    *) wf_bad_option "$1" ;;
  esac
done

if [ -z "$message" ]; then
  echo "Usage: $0 <message> [--add <path>...] [--allow-empty] [--branch <name>]" >&2
  exit 1
fi

# Env fallback — an explicit --branch always wins.
[ -n "$want_branch" ] || want_branch="${LV_REQUIRE_BRANCH:-}"

# Plan content (plans/, bugs/, briefs/) lives only on the develop worktree —
# by design, a feature worktree never carries it (docs/worktrees.md). But
# lv-implement invokes this script as
# `$DEVELOP_ROOT/scripts/lv-exec.sh lv-commit.sh ... --add plans/...` while
# the calling shell's CWD is still the feature worktree, and `git add` runs
# against CWD, not against the path of the script it happens to be running.
# A feature worktree's sparse-checkout excludes plans/, so that `git add`
# fails outright: "matched paths that exist outside of your sparse-checkout
# definition." lv-progress-tick.sh and lv-registry-update.sh both avoid this
# by `cd`-ing to the develop root themselves before touching plans/ — do the
# same here rather than trust the caller's CWD (WFI-026).
#
# But release-branches/release and release-branches/main are NOT sparse —
# lv-worktree-pin.sh deliberately gives them the real plans/**, because
# /lv-release and /lv-deploy commit plan-state transitions there on purpose
# (assert_branch below exempts exactly these branches for the same reason).
# The unconditional cd sent their commits to develop instead: lv-bug-close.sh
# staged a rename in release-branches/main, this block cd'd to develop before
# the commit ran, `git commit -- plans/...` found nothing staged THERE and
# printed "nothing to commit — skipped", and the bug still reported closed —
# with the rename left dangling, staged-but-uncommitted, in the worktree the
# caller was actually standing in. A later `--branch main` from that same
# worktree then failed too, because the cd had switched `git branch
# --show-current` out from under it. (client-f WFI-012.) So: cd only when the
# caller is NOT already on one of the branches that legitimately carries this
# content in place.
for p in "${paths[@]+"${paths[@]}"}"; do
  case "$p" in
    plans/*|plans|bugs/*|bugs|briefs/*|briefs)
      case "$(git branch --show-current 2>/dev/null || true)" in
        develop|release|main) ;;
        *)
          develop_root="$(wf_develop_root)"
          [ "$PWD" = "$develop_root" ] || cd "$develop_root"
          ;;
      esac
      break
      ;;
  esac
done

# assert_branch <path>... — refuse the commit if this branch may not carry it.
#
# Called at the LAST moment, not at entry: the whole point is that the branch
# can change under a long-running skill (WFI-120).
assert_branch() {
  local current toplevel develop_root p
  current=$(git branch --show-current 2>/dev/null || true)
  # Detached HEAD or no branch: nothing to assert against, and refusing here
  # would break a rebase or bisect that has nothing to do with us.
  [ -n "$current" ] || return 0

  if [ -n "$want_branch" ] && [ "$current" != "$want_branch" ]; then
    echo "lv-commit: refusing to commit on '$current' — caller requires '$want_branch'." >&2
    echo "           Another session moved this checkout mid-run (WFI-120). Nothing committed." >&2
    echo "           Get back onto '$want_branch' and re-run this step." >&2
    return 1
  fi

  # The rule applies to the MAIN worktree only. A feature worktree that still
  # tracks plans/ (legacy, non-sparse) commits it deliberately, via lv-merge-*.sh.
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || true)
  develop_root=$(wf_develop_root)
  [ -n "$toplevel" ] && [ "$toplevel" = "$develop_root" ] || return 0

  # feature/* is exempt for the same reason: a client that works feature
  # branches in the main checkout instead of a worktree is doing the pipeline's
  # own thing. What is refused is a branch the pipeline never creates — which is
  # what a foreign session's branch always is.
  case "$current" in
    develop|release|main|feature/*) return 0 ;;
  esac

  for p in "$@"; do
    case "$p" in
      plans/*|plans|bugs/*|bugs|briefs/*|briefs)
        echo "lv-commit: refusing to commit plan content on '$current'." >&2
        echo "           '$p' belongs on develop (or release/main during a deploy)." >&2
        echo "           This checkout is on a branch the pipeline does not own — another" >&2
        echo "           session moved it mid-run (WFI-120). Nothing committed; get back" >&2
        echo "           onto develop and re-run." >&2
        return 1 ;;
    esac
  done
  return 0
}

# Serialize commits in this repo. The pathspec is what makes the commit
# correct; the lock keeps two workers from colliding on .git/index.lock and
# keeps the stage→commit window from interleaving. Re-entrant, so a caller
# already holding it (lv-registry-update.sh) does not deadlock.
wf_lock_acquire commit

# Before staging: a refusal after `git add` would leave the wrong branch's
# index dirty, which is a worse state than the one being prevented.
assert_branch "${paths[@]+"${paths[@]}"}" || exit 1

# Stage one path at a time, and do NOT discard the result.
#
# This was a single `git add -- "${paths[@]}" 2>/dev/null || true`, which fails
# two ways that both end at the same silent no-op:
#
#   WFI-053 — `git add` is ATOMIC across its pathspecs. Callers pass a fixed
#     list including `plans/deferred-criteria.md`, and a project that has never
#     deferred a criterion does not have that file, so git aborts the WHOLE add
#     with "did not match any files" and stages nothing. lv-spec then committed
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
      echo "lv-commit: git add failed for '$p' — not committing." >&2
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
# WFI-066: `lv-commit.sh ... --add bugs/` after lv-bug-consume.sh's
# open→triaged `git mv` reported "committed 5 path(s)" and left HEAD holding
# the same bug in bugs/open/ AND bugs/triaged/. The next worklist re-offered
# the still-open copy as an unplanned bug, which is how two spec workers ended
# up on one artifact (WFI-067). Every bug consumed by a spec run hit this.
#
# WFI-141: `2>/dev/null || true` on this diff is the SAME swallow the add loop
# above was written to close, one line further down. Under four concurrent
# daemon workers the diff itself failed — it refreshes the index and so wants
# the lock — the failure was discarded, the list came back empty, and the
# script printed "nothing to commit for the given paths — skipped" and exited 0
# over a path `git status` reported as ` M` with a 47-insertion diff. Re-running
# it seconds later committed normally. So the diff is retried and its failure is
# fatal, exactly like the add.
changed=()
if [ "${#paths[@]}" -gt 0 ]; then
  diff_out=""
  diff_err=""
  attempt=0
  # stderr to its own file, not 2>&1: git writes advisory warnings to stderr on
  # a SUCCESSFUL run too ("LF will be replaced by CRLF"), and merging the
  # streams would put one in the pathspec as if it were a filename.
  err_file=$(mktemp "${TMPDIR:-/tmp}/lv-commit.XXXXXX")
  while :; do
    if diff_out=$(git diff --cached --name-only --no-renames -- "${paths[@]}" 2>"$err_file"); then
      diff_err=""; break
    fi
    diff_err=$(cat "$err_file" 2>/dev/null || true)
    case "$diff_err" in
      *index.lock*|*"Unable to create"*|*"unable to write"*)
        attempt=$((attempt + 1))
        [ "$attempt" -lt 5 ] || break
        sleep 1 ;;
      *) break ;;
    esac
  done
  rm -f "$err_file"
  if [ -n "$diff_err" ]; then
    echo "lv-commit: could not read the staged path list — not committing." >&2
    printf '%s\n' "$diff_err" >&2
    exit 1
  fi
  while IFS= read -r f; do
    [ -n "$f" ] && changed+=("$f")
  done <<< "$diff_out"
fi

# Again, on the real list and after the staging window — this is the check that
# cannot be raced.
assert_branch "${changed[@]+"${changed[@]}"}" || exit 1

if [ "${#changed[@]}" -gt 0 ]; then
  git commit -q -m "$message" -- "${changed[@]}"
  echo "committed ${#changed[@]} path(s): $message"
  # NAME them. A count is not a receipt: client-a's WFI-164 read "committed
  # 1 path(s)" as success for a call that asked for a REGISTRY transition AND
  # the reviewed plan folder, and carried only the registry — the plan.md the
  # caller believed it had just published was gone from the working tree before
  # the add ran, so there was nothing to stage and nothing said so. A caller
  # that can see `plans/REGISTRY.md` alone on this list catches it in the same
  # breath; one that only sees "1" cannot.
  #
  # No `| head`: `head` closing the pipe early kills printf with SIGPIPE, and
  # under `set -o pipefail` that fails the script AFTER the commit landed.
  shown=0
  for p in "${changed[@]}"; do
    if [ "$shown" -ge 30 ]; then
      echo "  … and $(( ${#changed[@]} - 30 )) more"
      break
    fi
    echo "  $p"
    shown=$((shown + 1))
  done
  exit 0
fi

# Nothing staged. Before believing it, ask the working tree.
#
# "There was nothing to do" and "my write was lost" are the two outcomes this
# script exists to keep apart, and everything above only rules out the failures
# that ANNOUNCE themselves. A silent one — a partial add, an index that moved
# under the diff, anything not yet met — still lands here wearing rc=0 and the
# word "skipped", which an unattended caller reads as success (WFI-141).
#
# So the state is checked instead of assumed: a path that is modified in the
# working tree but absent from the index AFTER this script's own `git add` is
# not a no-op, and there is no legitimate way to reach it. Say so and fail.
#
# --ignore-submodules=dirty: a submodule with modified or untracked content of
# its own shows as ` M` here but is not something `git add <path>` stages, and
# that is genuinely nothing to commit.
if [ "${#paths[@]}" -gt 0 ]; then
  dirty=$(git status --porcelain --ignore-submodules=dirty -- "${paths[@]}" 2>/dev/null || true)
  if [ -n "$dirty" ]; then
    echo "lv-commit: nothing is staged, but these paths are modified in the working tree:" >&2
    printf '%s\n' "$dirty" >&2
    echo "           That combination cannot be legitimate — the add did not take." >&2
    echo "           NOT reporting this as 'nothing to commit'. Re-run; the write is still" >&2
    echo "           in the working tree and nothing has been lost yet." >&2
    exit 1
  fi
fi

if [ "$allow_empty" != "true" ]; then
  echo "lv-commit: nothing to commit for the given paths — skipped"
  # WHICH paths, and whether they even exist. A bare "skipped" is the same line
  # whether the caller named an optional file that was never created or a
  # directory full of work that failed to stage, and the second reads as the
  # first (WFI-238). One line per requested path costs nothing and makes the
  # next occurrence diagnosable instead of mysterious.
  for p in "${paths[@]+"${paths[@]}"}"; do
    if [ -d "$p" ]; then    echo "           $p (directory, no staged changes under it)"
    elif [ -e "$p" ]; then  echo "           $p (exists, unchanged)"
    else                    echo "           $p (does not exist)"
    fi
  done
  exit 0
fi

# Empty marker commit, built so it cannot pick up anything staged by anyone
# else: same tree as HEAD, one parent, index and working tree untouched.
if ! head_sha=$(git rev-parse --verify HEAD 2>/dev/null); then
  echo "lv-commit: no HEAD yet — nothing to mark" >&2
  exit 0
fi
tree=$(git rev-parse "HEAD^{tree}")
new=$(git commit-tree "$tree" -p "$head_sha" -m "$message")
git update-ref HEAD "$new"
echo "committed (empty marker): $message"
