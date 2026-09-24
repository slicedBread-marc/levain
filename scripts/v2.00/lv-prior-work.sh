#!/usr/bin/env bash
# lv-prior-work.sh <PLN-NNN> [--base develop]
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
# fully-formed commit that bypassed lv-implement and lv-verify entirely. The
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
# base branch is clean of it — the same polarity as lv-list-gates.sh.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

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

if ! printf '%s' "$plan_id" | grep -qE "^($LV_PLN_RE)-[0-9]+"; then
  echo "Usage: $0 <$LV_PLN-NNN> [--base develop]" >&2
  exit 1
fi
plan_id=$(printf '%s' "$plan_id" | grep -oE "^($LV_PLN_RE)-[0-9]+")
num=${plan_id#*-}

git rev-parse --verify --quiet "$base" >/dev/null 2>&1 || {
  echo "lv-prior-work: '$base' does not resolve — nothing to check against" >&2
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
  bug_id=$(grep -oE "\*\*Bug:\*\*[ \t]*($LV_BUG_RE)-[0-9]+" "$plan_dir/plan.md" | grep -oE "($LV_BUG_RE)-[0-9]+" | head -1 || true)
fi
[ -n "$bug_id" ] || bug_id="$LV_BUG-$num"

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

# ── What the plan says it will touch ──────────────────────────────────────
#
# A commit naming this plan is not necessarily this plan's implementation, and
# the cheapest evidence for which is whether it touches the files the plan says
# it will. client-a's PLN-206: commit 6d8e7fc2 named PLN-206 and edited
# `docs/plan/reference/` files, while the plan's four steps target
# RedactionGuards.cs and two test files — Step 4 says in as many words "No
# docs/ change". Zero overlap. The commit was unrelated work that stands, the
# plan was correct as written, and neither of the two answers the gate offered
# fit; accepting it literally would have sent a plan at step 0 of 4, with no
# worktree and no code, straight to verify (WFI-208).
#
# This is REPORTED, not acted on. Zero overlap is strong evidence and not
# proof: a plan's `**Files:**` lines are a planner's forecast, and an
# implementation that legitimately reaches further would show a partial overlap
# — or, for a plan that declares nothing, none at all. Suppressing the gate on
# that inference would risk exactly the harm this script exists to prevent
# (WFI-155), silently. So the human still decides; they just get the answer
# handed to them instead of running `git show --stat` to reconstruct it, which
# is the same fix WFI-193 applied to the file list itself.
declared_files=""
if [ -n "$plan_dir" ] && [ -f "$plan_dir/plan.md" ]; then
  declared_files=$(grep -oE '^\-[ \t]*\*\*Files:\*\*.*' "$plan_dir/plan.md" 2>/dev/null \
                   | grep -oE '[A-Za-z0-9_./-]+\.[A-Za-z0-9]+' \
                   | grep -vE '^\.' | sort -u || true)
fi
declared_count=$(printf '%s' "$declared_files" | grep -c . || true)

# overlap_note <newline-separated code files> → a line describing the overlap
overlap_note() {
  [ "${declared_count:-0}" -gt 0 ] || { printf 'the plan declares no **Files:** — no overlap to compute'; return; }
  local hits
  hits=$(printf '%s\n' "$1" | grep -Fx -f <(printf '%s\n' "$declared_files") 2>/dev/null | grep -c . || true)
  if [ "${hits:-0}" -gt 0 ]; then
    printf '%s of them are among the %s files the plan declares' "$hits" "$declared_count"
  else
    printf 'NONE of them are among the %s files the plan declares — likely not this plan'"'"'s work' "$declared_count"
  fi
}

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
  printf '  %s\n' "$(git log -1 --format='%h %s' "$sha")"
  # NAME the files. Answering this gate is deciding "code, or a note?", and a
  # count alone makes the human run `git show --stat` first (WFI-193).
  printf '    %s file(s) outside the pipeline'"'"'s own paths — %s:\n' "$code" "$(overlap_note "$code_files")"
  printf '%s\n' "$code_files" | head -10 | sed 's/^/      /'
  [ "$code" -gt 10 ] && printf '      … and %s more\n' "$((code - 10))"
done < <(git log --first-parent --no-merges --format=%H \
           --grep="$plan_id" --grep="$bug_id" "$base" 2>/dev/null || true)

if [ "$found" -eq 0 ]; then
  echo "No prior work for $plan_id on '$base'."
  exit 1
fi

echo ""
echo "This code did not come through lv-implement — no feature branch, no verify."
echo "Do not build over it and do not assume it is correct. A human decides, and"
echo "there are THREE answers, not two:"
echo "  1. accept  — it IS this plan's work; the plan goes straight to verify"
echo "  2. revert  — undo it on the feature branch and implement per plan.md"
echo "  3. unrelated — it is not this plan's work at all. It STAYS on '$base',"
echo "     untouched, and the plan implements per plan.md unchanged."
echo ""
echo "Answer 3 is the right one whenever a commit merely mentions the ID while"
echo "doing something else, and it used not to be offered: client-a's PLN-206"
echo "had a commit naming it that touched only docs, sharing no file with any of"
echo "the plan's four steps. Answering 'accept' literally would have moved a plan"
echo "at step 0 of 4, with no worktree and no code written, into verify (WFI-208)."
echo "The overlap line under each commit above is the evidence for choosing."
echo ""
echo "If those paths are notes rather than implementation and this keeps firing,"
echo "declare them once in levain.yml instead of answering per plan:"
echo "  priorWork:"
echo "    ignorePaths:"
echo "      - \"path/prefix/\""
exit 0
