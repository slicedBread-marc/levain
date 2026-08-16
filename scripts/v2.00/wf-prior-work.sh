#!/usr/bin/env bash
# wf-prior-work.sh <PLN-NNN> [--base develop]
#
# Answers one question a builder cannot afford to guess: has someone already
# written this plan's code, outside the pipeline?
#
# WHY THIS EXISTS
#
# client-a's WFI-155. PLN-092's plan.md carried an implementer note saying
# the BUG-092 clipboard prototype in the shared develop checkout was untracked
# scratch — "not in history, and it won't follow a git worktree add". By the
# time the builder was dispatched, develop HEAD held commit c3dd7db,
# `fix(BUG-092): copy button writes the minted token…`, touching all five files
# the plan's steps target. It had landed directly on develop with no feature
# branch, no `.plan-ref`, no registry linkage and no MUTATION marker — a
# fully-formed commit that bypassed wf-implement and wf-verify entirely. The
# worktree cut from develop inherited it, and the plan's own note said it
# would not.
#
# There is no way for a builder to reason its way out of that. Implementing
# per plan.md duplicates or fights work that is already there; treating it as
# done accepts unreviewed code as this plan's deliverable. Both are decisions a
# human owes an answer to, and both are cheap to prevent by LOOKING first.
#
# WHAT COUNTS
#
# A commit on the base branch that names this plan or the bug it consumes, and
# touches something other than pipeline bookkeeping. `plans/`, `bugs/`,
# `briefs/` and `.claude/` are how the pipeline talks about a plan; anything
# else is how it BUILDS one. A spec commit naming PLN-092 is expected and
# silent here. A commit naming PLN-092 that edits `src/` is the report.
#
# Merges are skipped: a feature branch merged into develop is the pipeline
# working correctly, and its own commits carry the plan ID too. `--no-merges`
# plus first-parent exclusion would still list the branch's commits, so the
# filter is the merge boundary — anything reachable only through a merge into
# base came from a branch, which is the sanctioned route.
#
# Output, one line per commit:
#   <short-sha> <subject>
#     files: <n> outside plans/ bugs/ briefs/ .claude/
#
# Exit 0 when prior work was found (there is something to answer), 1 when the
# base branch is clean of it — the same polarity as wf-list-gates.sh.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"

plan_id="${1:-}"
base="develop"
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --base) shift; base="${1:?--base requires a branch}"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if ! printf '%s' "$plan_id" | grep -qE '^PLN-[0-9]+'; then
  echo "Usage: $0 <PLN-NNN> [--base develop]" >&2
  exit 1
fi
plan_id=$(printf '%s' "$plan_id" | grep -oE '^PLN-[0-9]+')
num=${plan_id#PLN-}

git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || {
  echo "wf-prior-work: '$base' does not resolve — nothing to check against" >&2
  exit 1
}

# The bug this plan consumes, if any. The number is shared across types by the
# global counter (BUG-092 → PLN-092), so the bug ID is usually derivable — but
# only usually: an inherited number can be reallocated (WFI-011), so the Goal's
# `**Bug:** BUG-NNN` line is authoritative when it is there.
bug_id=""
plan_dir=""
for d in plans/${plan_id}-*/; do [ -d "$d" ] && { plan_dir="${d%/}"; break; }; done
if [ -n "$plan_dir" ] && [ -f "$plan_dir/plan.md" ]; then
  bug_id=$(grep -oE '\*\*Bug:\*\*[ \t]*BUG-[0-9]+' "$plan_dir/plan.md" | grep -oE 'BUG-[0-9]+' | head -1 || true)
fi
[ -n "$bug_id" ] || bug_id="BUG-$num"

# Candidate commits: named by ID, no merges, and reachable on base by the
# first-parent path only — i.e. committed ONTO base rather than merged into it.
found=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  # Files this commit touched that are not pipeline bookkeeping.
  code=$(git show --pretty=format: --name-only "$sha" 2>/dev/null \
         | grep -vE '^(plans/|bugs/|briefs/|\.claude/)' \
         | grep -c . || true)
  [ "${code:-0}" -gt 0 ] || continue
  if [ "$found" -eq 0 ]; then
    echo "Prior work for $plan_id on '$base', outside the pipeline:"
  fi
  found=$((found + 1))
  printf '  %s %s\n' "$(git log -1 --format=%h "$sha")" "$(git log -1 --format=%s "$sha")"
  printf '    files: %s outside plans/ bugs/ briefs/ .claude/\n' "$code"
done < <(git log --first-parent --no-merges --format=%H \
           --grep="$plan_id" --grep="$bug_id" "$base" 2>/dev/null || true)

if [ "$found" -eq 0 ]; then
  echo "No prior work for $plan_id on '$base'."
  exit 1
fi

echo ""
echo "This code did not come through wf-implement — no feature branch, no verify."
echo "Do not build over it and do not assume it is correct. A human decides:"
echo "  accept it as this plan's work (straight to verify), or revert it on the"
echo "  feature branch and implement per plan.md."
exit 0
