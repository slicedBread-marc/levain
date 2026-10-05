#!/usr/bin/env bash
# lv-ignored-sources.sh <PLN-NNN> [--worktree <dir>]
#
# Lists the source files a plan wrote that git will never see: present in its
# feature worktree, untracked, and matched by an ignore rule.
#
# WHY THIS EXISTS
#
# A client's PLN-063 put new server code under `src/<App>/Debug/` and client
# code under `client/src/debug/`. The stock .NET `.gitignore` rule `[Dd]ebug/`
# matches both, so not one of those files was ever committed. Verify, test and
# the post-merge suite all passed, because every one of them ran in the feature
# worktree, where the files were on disk. The release then failed to build
# from a clean checkout (CS0234), and removing the worktree at completion
# deleted the only copy. The source was lost (the client's BUG-065).
#
# Nothing in the harness asked whether what the builder wrote is what git
# holds. This does, from the plan's own `**Files:**` lines:
#
#   - every listed path that exists in the worktree, is untracked, and is
#     ignored;
#   - every ignored, untracked file directly inside the directory of a listed
#     path, when it shares an extension with some listed path — the builder's
#     sibling file the plan did not name (DebugReportSetup.cs beside the two
#     it did). Direct children only, so `bin/` and `obj/` under a project
#     directory are not read; the root is skipped, so `.env` is not either.
#
# Read by lv-registry-update.sh's `active -> verify` guard, and by /lv-test
# before it removes a worktree.
#
# Exit 0 — nothing ignored.
# Exit 1 — ignored sources; one per line on stdout, `<path>\t<source:line:pattern>`.
# Exit 2 — usage, or the plan cannot be resolved.
# Exit 3 — the plan has no worktree (nothing on disk to lose, nothing to check).

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

usage() { sed -n '2,36p' "$0" >&2; }

raw="${1:-}"
case "$raw" in
  ""|-h|--help) usage; [ -n "$raw" ] && exit 0 || exit 2 ;;
esac
shift
wt=""
while [ $# -gt 0 ]; do
  case "$1" in
    --worktree) wt="${2:?--worktree requires a path}"; shift 2 ;;
    *) echo "lv-ignored-sources: unknown argument: $1" >&2; exit 2 ;;
  esac
done

plan_id=$(printf '%s' "$raw" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
[ -n "$plan_id" ] || { echo "lv-ignored-sources: not a plan ID: $raw" >&2; exit 2; }

root="$(wf_develop_root)"
slug=$(wf_registry_field "$plan_id" slug "$root/plans/REGISTRY.md")
plan_md="$root/plans/${plan_id}-${slug}/plan.md"
[ -n "$slug" ] && [ -f "$plan_md" ] || { echo "lv-ignored-sources: no plan.md for $plan_id" >&2; exit 2; }

if [ -z "$wt" ]; then
  branch=$(wf_registry_field "$plan_id" branch "$root/plans/REGISTRY.md")
  case "$branch" in ""|"—"|"-") branch="" ;; esac
  [ -n "$branch" ] && wt=$(cd "$root" && wf_worktree_for_branch "$branch")
fi
if [ -z "$wt" ] || [ ! -d "$wt" ]; then
  echo "lv-ignored-sources: $plan_id has no worktree — nothing to check" >&2
  exit 3
fi

files=$(wf_plan_files "$plan_md")
[ -n "$files" ] || exit 0

exts=$(printf '%s\n' "$files" | awk -F/ '{ n = $NF; i = match(n, /\.[^.]+$/); if (i > 1) print substr(n, i) }' | sort -u)

found=$(
  cd "$wt" || exit 0
  ignored() { ! git ls-files --error-unmatch -- "$1" >/dev/null 2>&1 && git check-ignore -q -- "$1" 2>/dev/null; }
  printf '%s\n' "$files" | while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ -f "$p" ] && ignored "$p"; then printf '%s\n' "$p"; fi
    d="${p%/*}"
    [ "$d" != "$p" ] && [ -d "$d" ] && [ -n "$exts" ] || continue
    git ls-files --others --ignored --exclude-standard -- "$d" 2>/dev/null \
      | awk -v d="$d/" 'index($0, d) == 1 && index(substr($0, length(d) + 1), "/") == 0' \
      | while IFS= read -r f; do
          [ "${f##*.}" != "$f" ] && printf '%s\n' "$exts" | grep -qxF ".${f##*.}" && printf '%s\n' "$f"
        done
  done | sort -u
)

[ -n "$found" ] || exit 0
printf '%s\n' "$found" | while IFS= read -r f; do
  rule=$(cd "$wt" && git check-ignore -v -- "$f" 2>/dev/null | cut -f1)
  printf '%s\t%s\n' "$f" "${rule:-ignored}"
done
exit 1
