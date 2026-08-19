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
# WHERE ELSE A PROJECT TALKS ABOUT A PLAN
#
# Those four paths are the harness's own vocabulary, and a project may have
# more. client-a's WFI-193: `drive/exchange/` is the cross-machine message
# log for an air-gapped pair, so every bug filed from the remote machine
# arrives as a commit naming its bug ID and touching a path outside the four.
# Three plans in one session — PLN-171, PLN-172, PLN-174 — each opened a gate
# over a communication-log note, each stalled, each cost a human round trip to
# answer "it is a note". On that project the false positive fires on
# essentially every bug-sourced plan.
#
#   priorWork:
#     ignorePaths:
#       - "drive/exchange/"        # a note about a bug, not an implementation
#
# Entries are path PREFIXES from the repository root, added to the four
# built-ins — write the trailing slash for a directory. They are not globs:
# this decides whether a HUMAN IS INTERRUPTED, and a pattern language whose
# misfires are silent is the wrong trade here. Nothing is ever removed from the
# four built-ins, so a project cannot configure the gate away entirely.
#
# WHAT IT SAYS WHEN IT DOES FIRE
#
# The report names the offending files, not just how many. Answering the gate
# means knowing whether the commit is code or a note, and a bare count sends
# the human to `git show --stat` before they can say either — which is exactly
# what all three of those round trips were spent on.
#
# Merges are skipped: a feature branch merged into develop is the pipeline
# working correctly, and its own commits carry the plan ID too. `--no-merges`
# plus first-parent exclusion would still list the branch's commits, so the
# filter is the merge boundary — anything reachable only through a merge into
# base came from a branch, which is the sanctioned route.
#
# Output, one line per commit:
#   <short-sha> <subject>
#     <n> file(s) outside the pipeline's own paths:
#       <path>
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

# The paths that are bookkeeping rather than implementation: the four the
# harness owns, plus whatever this project declares (see the header).
ignore_prefixes=(plans/ bugs/ briefs/ .claude/)
extra_prefixes=()
while IFS= read -r p; do
  [ -n "$p" ] || continue
  extra_prefixes+=("$p")
done < <(wf_cfg_list priorWork.ignorePaths)
ignore_prefixes+=("${extra_prefixes[@]+"${extra_prefixes[@]}"}")

# Prefixes are literal, so every regex metacharacter in one is escaped — a `.`
# in `.claude/` matching any character is harmless, but a project prefix like
# `docs/api-v1.2/` silently over-matching is not.
ignore_re=""
for p in "${ignore_prefixes[@]}"; do
  esc=$(printf '%s' "$p" | sed 's/[][\.^$*+?(){}|\\]/\\&/g')
  ignore_re="${ignore_re:+$ignore_re|}$esc"
done
ignore_re="^($ignore_re)"

# Candidate commits: named by ID, no merges, and reachable on base by the
# first-parent path only — i.e. committed ONTO base rather than merged into it.
found=0
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  # Files this commit touched that are not pipeline bookkeeping.
  code_files=$(git show --pretty=format: --name-only "$sha" 2>/dev/null \
               | grep -vE "$ignore_re" | grep . || true)
  [ -n "$code_files" ] || continue
  code=$(printf '%s\n' "$code_files" | grep -c . || true)
  if [ "$found" -eq 0 ]; then
    echo "Prior work for $plan_id on '$base', outside the pipeline:"
  fi
  found=$((found + 1))
  printf '  %s %s\n' "$(git log -1 --format=%h "$sha")" "$(git log -1 --format=%s "$sha")"
  # NAME the files. Answering this gate is deciding "code, or a note?", and a
  # count alone makes the human run `git show --stat` first (WFI-193).
  printf '    %s file(s) outside the pipeline'"'"'s own paths:\n' "$code"
  printf '%s\n' "$code_files" | head -10 | sed 's/^/      /'
  [ "$code" -gt 10 ] && printf '      … and %s more\n' "$((code - 10))"
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
echo ""
echo "If those paths are notes rather than implementation and this keeps firing,"
echo "declare them once in claude-workflow.yml instead of answering per plan:"
echo "  priorWork:"
echo "    ignorePaths:"
echo "      - \"path/prefix/\""
exit 0
