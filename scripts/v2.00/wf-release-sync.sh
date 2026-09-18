#!/usr/bin/env bash
# wf-release-sync.sh [--check] [--dry-run]
#
# Answers one question for /wf-deploy: is the LOCAL `release` ref the batch
# that actually passed E2E and got pushed? — and, when the only difference is
# that local is behind, fast-forwards it so that it is.
#
# WHY THIS EXISTS
#
# Everything downstream of a release reads the local ref. `git rev-list
# --count release --not main` is the eligibility signal; `git merge release`
# is the promotion. Both are correct only while the local ref agrees with
# `origin/release`, and in a pinned-worktree layout it routinely does not:
# `release` and `main` live in long-lived worktrees (docs/release-worktrees.md)
# that a given session never enters, so whatever the last /wf-release or
# /wf-deploy pushed from somewhere else is invisible to the local ref here.
#
# Both directions of that disagreement have now shipped a wrong deploy:
#
#   · LOCAL AHEAD — client-b WFI-007. Commits on the local ref and on no
#     remote are commits whose E2E run did not reach its push: the suite was
#     red, or the worker died. Thirty of them reached a deploy-approval gate
#     quoted as ready for production. That is what wf-release-rollback.sh
#     undoes, and this script refuses to let a deploy past it (exit 2).
#
#   · LOCAL BEHIND — client-a WFI-258, and the reason the behind direction
#     is checked at all. An unattended /wf-deploy merged a local `release` that
#     was 34 commits behind `origin/release`, ran the full suite green on that
#     stale tree, pushed `main`, and reported "15 commits promoted (PLN-273
#     work)". PLN-273 was registry-complete, on origin/release, and not in
#     production. Nothing detected it: a stale tree still builds, still tests
#     green, and the completion message names plans it never carried. Only the
#     ahead direction was guarded, so this one had no guard at all.
#
# A behind-only local ref is the one case that is safe to repair rather than
# refuse: there is nothing local to lose, so the repair is a fast-forward and
# never a reset. Anything else is reported and left alone.
#
# Exit codes — the skill branches on these, not on the text:
#   0  local release == origin/release (already, or after a fast-forward).
#      Safe to promote.
#   2  local release is AHEAD of origin/release — unpushed commits no E2E run
#      validated. Do not promote. wf-release-rollback.sh is the undo.
#   3  local and origin/release have DIVERGED. Not promotable, and not
#      something this script guesses at.
#   1  could not establish the answer (no origin/release, fetch failed with no
#      cached ref, dirty worktree blocking the fast-forward, FF refused).
#
# --check   report only; never move the ref. A behind ref exits 2 as well,
#           since "not promotable as it stands" is the answer being asked for.
# --dry-run same as --check, phrased as what would happen.
#
# Read docs/release-worktrees.md before changing who may move `release`.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

check_only=false
while [ $# -gt 0 ]; do
  case "$1" in
    --check|--dry-run) check_only=true; shift ;;
    -h|--help) sed -n '2,54p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "wf-release-sync.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

# Where is `release` checked out? Its own pinned worktree normally, the shared
# checkout on a client that has not migrated, nowhere at all on one that has
# never released. Ask git rather than assume a path — same walk as
# wf-release-rollback.sh, for the same reason.
wt=""
_wt=""
while IFS= read -r line; do
  case "$line" in
    worktree\ *) _wt="${line#worktree }" ;;
    branch\ refs/heads/release) wt="$_wt" ;;
  esac
done < <(git worktree list --porcelain 2>/dev/null || true)

git_in() { if [ -n "$wt" ]; then git -C "$wt" "$@"; else git "$@"; fi; }

git_in fetch origin release --quiet 2>/dev/null || \
  echo "wf-release-sync: could not fetch origin/release — judging against the cached remote ref" >&2

local_sha=$(git_in rev-parse --verify --quiet release 2>/dev/null || true)
remote_sha=$(git_in rev-parse --verify --quiet origin/release 2>/dev/null || true)

if [ -z "$local_sha" ]; then
  echo "wf-release-sync: no local 'release' branch — nothing to promote." >&2
  exit 1
fi
if [ -z "$remote_sha" ]; then
  # Not "in sync by default". The whole meaning of `release --not main` is
  # "commits a pushed E2E run validated", and with no remote there is nothing
  # that could have been pushed to.
  echo "wf-release-sync: origin/release does not exist — cannot tell a validated" >&2
  echo "                 batch from an unpushed one. local release is at $(git_in rev-parse --short release)." >&2
  exit 1
fi

short_l=$(git_in rev-parse --short "$local_sha")
short_r=$(git_in rev-parse --short "$remote_sha")

if [ "$local_sha" = "$remote_sha" ]; then
  echo "release is in sync with origin/release ($short_l) — safe to promote"
  exit 0
fi

ahead=$(git_in rev-list --count "$remote_sha..$local_sha")
behind=$(git_in rev-list --count "$local_sha..$remote_sha")

if [ "$ahead" -gt 0 ] && [ "$behind" -gt 0 ]; then
  echo "wf-release-sync: local release and origin/release have DIVERGED — not promotable." >&2
  echo "                 local  $short_l ($ahead commit(s) origin does not have)" >&2
  echo "                 origin $short_r ($behind commit(s) local does not have)" >&2
  echo "                 Reconcile by hand before deploying; this script will not guess." >&2
  exit 3
fi

if [ "$ahead" -gt 0 ]; then
  echo "wf-release-sync: local release is $ahead commit(s) AHEAD of origin/release — unpushed." >&2
  echo "                 Commits on no remote are commits whose E2E run never reached its push" >&2
  echo "                 (client-b WFI-007). Do not promote them." >&2
  echo "                 Undo with: scripts/wf-exec.sh wf-release-rollback.sh" >&2
  exit 2
fi

# Behind only. Nothing local to lose, so this is a fast-forward.
if $check_only; then
  echo "local release is $behind commit(s) BEHIND origin/release ($short_l → $short_r)"
  echo "would fast-forward release to origin/release before promoting"
  exit 2
fi

if [ -n "$wt" ]; then
  dirty=$(git_in status --porcelain --ignore-submodules=dirty 2>/dev/null | grep -v '^??' || true)
  if [ -n "$dirty" ]; then
    echo "wf-release-sync: the release worktree has modified tracked files — refusing to move it." >&2
    printf '%s\n' "$dirty" >&2
    exit 1
  fi
  if ! git_in merge --ff-only --quiet "$remote_sha" 2>/dev/null; then
    echo "wf-release-sync: fast-forward of release → origin/release failed in $wt." >&2
    echo "                 Nothing changed; local release is still at $short_l." >&2
    exit 1
  fi
else
  # Not checked out anywhere: a bare ref update touches no working tree.
  git update-ref refs/heads/release "$remote_sha" "$local_sha"
fi

after=$(git_in rev-parse --short release)
echo "release fast-forwarded to origin/release: $short_l → $after ($behind commit(s) picked up)"
wf_event release-sync RELEASE "local release fast-forwarded $short_l → $after before promotion" 2>/dev/null || true
exit 0
