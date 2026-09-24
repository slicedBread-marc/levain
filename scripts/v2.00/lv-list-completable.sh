#!/usr/bin/env bash
# lv-list-completable.sh [--ref <ref>]
#
# Which plans in state `testing` this deploy may transition to `complete`.
#
# WHY THIS EXISTS
#
# /lv-deploy step 9 used to select them itself, by a rule written in prose:
# "each plan in state `testing` whose folder is on the release branch". That
# rule has been wrong twice, in the same direction, on the same plan.
#
# WFI-001 found the first half: a plan's folder reaches release on its own,
# through a planning-only commit on develop, while the plan is still `draft` or
# `ready`. The fix was "select by registry state, not by folder presence".
#
# client-b WFI-030 and WFI-035 found that selecting by registry state is not
# sufficient either, and that the two conditions together are not sufficient.
# PLN-012 was in state `testing` AND its folder was on release — satisfying the
# step exactly — while feature/PLN-012-prototypes carried 10 commits that were
# not an ancestor of release and had shipped nothing. The 33 PLN-012 commits
# inside `release --not origin/main` were all spec, registry, progress and gate
# bookkeeping made on develop. Following the step literally marks an untested,
# unshipped plan `complete`, which removes it from /lv-test's queue and records
# production content that does not exist.
#
# The direction of the error is what makes it worth a script. `testing` means
# "passed verify, needs a human" — precisely the state whose code is normally
# NOT yet on release, because /lv-test is what merges the PR and sets
# `complete`. Every plan whose code did ship is already `complete` before a
# deploy runs. So step 9 fires rarely, and when it fires it is usually firing
# on exactly the wrong plan: a human's acceptance test is the thing standing
# between the plan and `complete`, and this would step over it.
#
# THE TEST
#
# Not the folder, and not the state alone: whether the plan's IMPLEMENTATION is
# in the ref being promoted. Three shapes, and only one of them ships.
#
#   merged     the plan's branch is an ancestor of <ref>. Its code is in what
#              is being promoted. Transition it.
#   unmerged   the branch exists and is not an ancestor. This is WFI-030's
#              plan. Leave it in `testing` for /lv-test.
#   no-branch  the registry names no branch, or the ref is gone. Reported, not
#              decided — a branch deleted after a merge and a branch deleted
#              instead of one are indistinguishable from here, and guessing in
#              favour of `complete` is the failure this script exists to stop.
#
# Output, tab-separated, one plan per line:
#   <plan-name>\t<merged|unmerged|no-branch>\t<branch>\t<detail>
#
# stdout carries every plan in `testing` so the caller can report on all of
# them; `--shippable` narrows it to the `merged` rows, which is the set step 9
# actually runs lv-registry-update.sh over.
#
# Exit 0 if any plan is `merged`, 1 if none is, 2 on a bad ref.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REF="release"
SHIPPABLE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --ref)        REF="${2:-}"; shift 2 ;;
    --shippable)  SHIPPABLE_ONLY=1; shift ;;
    -h|--help)    sed -n '2,50p' "$0"; exit 0 ;;
    *)            echo "lv-list-completable: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if ! git rev-parse --verify --quiet "$REF" >/dev/null 2>&1; then
  echo "lv-list-completable: no such ref '$REF'" >&2
  exit 2
fi

REGISTRY="plans/REGISTRY.md"
shippable=0
rows=()

while IFS=$'\037' read -r id slug state _priority branch _rest; do
  [ "$state" = "testing" ] || continue
  plan_name="${id}-${slug}"

  # The registry's own Branch column, falling back to the naming convention
  # every worktree is created under. A row written before the column existed
  # carries nothing there.
  case "$branch" in
    ""|"—"|"-") branch="feature/${plan_name}" ;;
  esac

  if ! git rev-parse --verify --quiet "$branch" >/dev/null 2>&1; then
    rows+=("$(printf '%s\tno-branch\t%s\tbranch does not exist — cannot prove its code is in %s' \
      "$plan_name" "$branch" "$REF")")
    continue
  fi

  if git merge-base --is-ancestor "$branch" "$REF" 2>/dev/null; then
    rows+=("$(printf '%s\tmerged\t%s\tancestor of %s' "$plan_name" "$branch" "$REF")")
    shippable=$((shippable + 1))
  else
    ahead=$(git rev-list --count "$REF..$branch" 2>/dev/null || echo "?")
    rows+=("$(printf '%s\tunmerged\t%s\t%s commit(s) not in %s — its implementation did not ship' \
      "$plan_name" "$branch" "$ahead" "$REF")")
  fi
done < <(wf_registry_rows "$REGISTRY")

# bash 3.2: "${arr[@]}" of an empty array is unbound under `set -u`.
if [ ${#rows[@]} -gt 0 ]; then
  for row in "${rows[@]}"; do
    if [ "$SHIPPABLE_ONLY" -eq 1 ]; then
      case "$row" in *$'\t'merged$'\t'*) ;; *) continue ;; esac
    fi
    printf '%s\n' "$row"
  done
fi

exit $((shippable > 0 ? 0 : 1))
