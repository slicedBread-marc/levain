#!/usr/bin/env bash
# lv-registry-audit.sh [--quiet]
#
# Checks that the registry and the plans/ directory still describe the same
# world.
#
# WHY THIS EXISTS
#
# REGISTRY.md is the single source of truth for plan state, which means every
# lv-list-* script, the orchestrator and /lv-tray see plans *only* through it.
# A plan folder with no row is therefore not "partly tracked" — it is invisible.
# Nothing offers it, nothing dispatches it, nothing reports it missing.
#
# app found exactly that during a worktree drain (WFI-009): a full plan folder
# with plan.md, findings.md, progress.md, a feature branch and a live worktree,
# and no row anywhere. Alongside it, two folders shared the ID PLN-064 — the
# counter had handed the same number out twice — and the two carried competing
# database migrations against the same schema.
#
# Both are silent by construction: the pipeline cannot report a plan it cannot
# see, and a duplicate ID resolves to whichever row `grep | head -1` reaches
# first. So they need a check that looks from the *directory* inward, which is
# the direction nothing else in the harness looks.
#
# Checks:
#   1. Plan folder with no registry row        (invisible to the pipeline)
#   2. Registry row with no plan folder        (dangling — state without work)
#   3. Duplicate plan IDs, in either place     (ambiguous resolution)
#   4. Counter below the highest ID in use     (the next allocation collides)
#   5. State values outside the documented set (unroutable; orchestrator fails)
#   6. draft/ready plan whose feature branch is ahead of develop (lost write),
#      unless open findings explain it — that is the fix cycle, and it is noted
#   7. Live worktree the Branch column does not name (the classifier's evidence
#      and the filesystem disagree; client-a WFI-219/220/221/224)
#
# Exit 0 when clean, 1 when anything was found. Reports only — it never edits
# the registry, because every finding here has more than one correct repair and
# picking one is the operator's call.

set -euo pipefail

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "lv-registry-audit.sh: $REGISTRY not found" >&2; exit 1; }

# shellcheck source=lv-states.sh
source "$(dirname "$0")/lv-states.sh"

problems=0
report() {
  problems=$((problems + 1))
  [ "$QUIET" = "true" ] || printf '%s\n' "$1"
}

# The second line of a two-line finding. It is the SAME problem — printing it
# through report() counted every such finding twice, so a registry with one
# thing wrong announced "2 problem(s)" and the reader went looking for a second
# one that was never there. Found on client-c, and filed independently from
# client-a as WFI-050.
detail() {
  [ "$QUIET" = "true" ] || printf '%s\n' "$1"
}

# Something worth knowing that is not something to fix. It prints, but it does
# not count — an audit that reports a standing "1 problem(s)" for a condition
# nothing can go wrong from trains its readers to ignore the count (WFI-133).
note() {
  [ "$QUIET" = "true" ] || printf '%s\n' "$1"
}

# ── One pass over the registry ───────────────────────────────────────────
#
# Every check below reads the same rows, so they are parsed ONCE into shell
# variables rather than re-awked per check. This script now runs on every
# /lv-status and every /lv-tray render, including --watch, so its cost is
# paid continuously rather than on demand: the first cut spawned six
# subprocesses per registry row and measured 1.7s on a 75-plan project, 3.8s
# at 100. Everything below is string work in bash — no subprocess per row.
#
# `reg_rows`  one "<id> <slug> <state> <branch>" line per PLN row
# `reg_ids`   space-delimited PLN ids, for membership tests
# `art_ids`   every PLN/BUG/BRF id, for the counter check
eval "$(awk -F'|' -v work_re="^($LV_WORK_RE)-[0-9]+$" -v plan_re="^($LV_PLN_RE)-" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function esc(s)  { gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", s); return s }
  {
    id = trim($2)
    if (id !~ work_re) next
    nums = nums id "\n"
    if (id !~ plan_re) next
    # The Branch column is field 6 — see check 7. An empty one is carried as
    # the em-dash sentinel so the read below always gets four fields.
    br = trim($6); if (br == "") br = "—"
    rows = rows id " " trim($3) " " trim($4) " " br "\n"
    ids  = ids id " "
  }
  END {
    printf "reg_rows='"'"'%s'"'"'\n", esc(rows)
    printf "reg_ids='"'"' %s'"'"'\n",  esc(ids)
    printf "art_ids='"'"'%s'"'"'\n",  esc(nums)
  }
' "$REGISTRY")"

# Plan folders on disk — bash parameter expansion, not basename + grep per entry.
disk_rows=""
disk_ids=" "
for d in plans/*-*/; do
  [ -d "$d" ] || continue
  base="${d%/}"; base="${base##*/}"
  [[ "$base" =~ ^($LV_PLN_RE)-[0-9] ]] || continue
  rest="${base#*-}"            # 051-maze-crumbs
  id="${base%%-*}-${rest%%-*}" # PLN-051
  disk_rows="$disk_rows$id $base"$'\n'
  disk_ids="$disk_ids$id "
done

# ── 1. Folder with no row ────────────────────────────────────────────────
while IFS=' ' read -r id base; do
  [ -n "$id" ] || continue
  case "$reg_ids" in
    *" $id "*) ;;
    *)
      report "MISSING ROW   plans/$base has no row in $REGISTRY — invisible to every lv-list-* script and to the orchestrator."
      detail "              Add a row, or abandon it: scripts/lv-exec.sh lv-abandon.sh $id --reason \"...\""
      ;;
  esac
done <<< "$disk_rows"

# ── 2. Row with no folder ────────────────────────────────────────────────
while IFS=' ' read -r id _slug _state; do
  [ -n "$id" ] || continue
  case "$disk_ids" in
    *" $id "*) ;;
    *) report "DANGLING ROW  $id has a registry row but no plans/$id-*/ folder — state with nothing behind it." ;;
  esac
done <<< "$reg_rows"

# ── 3. Duplicate IDs ─────────────────────────────────────────────────────
dupe_rows=$(printf '%s' "$reg_rows" | awk '{print $1}' | sort | uniq -d || true)
for id in $dupe_rows; do
  report "DUPLICATE ROW $id appears more than once in $REGISTRY — every lookup takes the first match and silently ignores the rest."
done

dupe_dirs=$(printf '%s' "$disk_rows" | awk '{print $1}' | sort | uniq -d || true)
for id in $dupe_dirs; do
  folders=$(printf '%s' "$disk_rows" | awk -v i="$id" '$1 == i { print $2 }' | tr '\n' ' ')
  report "DUPLICATE DIR $id names two plan folders: $folders"
  detail "              The counter handed the same number out twice. Check both for competing migrations or schema changes before removing either."
done

# ── 4. Counter sanity ────────────────────────────────────────────────────
counter=$(grep -oE '<!-- Counter: [0-9]+ -->' "$REGISTRY" | grep -oE '[0-9]+' | head -1 || true)
if [ -n "$counter" ]; then
  # One glob expansion into one grep, rather than basename + grep per entry.
  #
  # Match the ID, then take its digits — NOT every digit run in the path. Two
  # of these inputs are whole paths, and a slug is free to contain numbers:
  # `bugs/triaged/BUG-019-capsule-base64url-encoding/` yields 019 *and 64* to a
  # bare `[0-9]+`. client-a's counter sat correctly at 21 and the audit told
  # it to jump to 65, which would have burned IDs 21-64 — the check meant to
  # protect the counter was the only thing threatening it (WFI-050). Any slug
  # with a number in it does this: base64, sha256, oauth2, utf8, s3.
  highest=$(
    { printf '%s' "$art_ids"
      printf '%s' "$disk_rows" | awk '{print $1}'
      printf '%s\n' bugs/*/*/ plans/briefs/* 2>/dev/null
    } | { grep -oE "($LV_WORK_RE)-[0-9]+" || true; } \
      | sed -E 's/^[A-Z]+-0*//' | { grep -E '^[0-9]+$' || true; } | sort -n | tail -1
  )
  # Drift is a note, not a problem. lv-counter-next.sh derives its floor from
  # the artifacts that actually exist and advances past anything it finds, so a
  # counter sitting at or below the highest live ID cannot hand out a duplicate
  # — it self-corrects on the next allocation. Saying "the next allocation
  # collides" asserted a failure the allocator provably prevents, and it said
  # it on every /lv-status and every /lv-tray render until someone hand-edited
  # REGISTRY.md to silence it. Hand-editing the counter is the one way to
  # actually create the collision this line warned about (WFI-133).
  if [ -n "$highest" ] && [ "$counter" -le "$highest" ]; then
    note   "COUNTER       <!-- Counter: $counter --> is behind the highest ID in use ($highest)."
    detail "              Not a fault: the next allocation advances past it on its own. Something"
    detail "              wrote an ID without going through lv-counter-next.sh — worth knowing why."
  fi
fi

# Checked-out branches, read ONCE. Check 7 needs this per row, and this script
# runs on every /lv-status and every /lv-tray --watch — a `git worktree list`
# per row is exactly the per-row subprocess the parse above exists to avoid.
# Path AND branch, tab-separated: a worktree that should be drained is drained
# by path, and check 7's remedy for a `complete` plan is a `git worktree remove`
# that has to name one.
live_worktrees=$(git worktree list --porcelain 2>/dev/null \
  | awk '
      /^worktree /{ path = substr($0, 10) }
      /^branch /  { b = $0; sub(/^branch refs\/heads\//, "", b); print b "\t" path }
    ' || true)
live_worktree_branches=$(printf '%s\n' "$live_worktrees" | cut -f1)

# ── 5. Unroutable states, 6. pre-implementation states on real work, and ──
# ── 7. a live worktree the registry does not name ────────────────────────
#
# One loop, because both read the same three fields. `draft` means nobody has
# built it yet; app found two such plans carrying finished implementations —
# 21 and 16 commits, no findings to explain the route back (WFI-010). A state
# write that can be lost is worth catching from the branch side.
while IFS=' ' read -r id slug state reg_branch; do
  [ -n "$id" ] || continue

  wf_state_is_valid "$state" || \
    report "BAD STATE     $id is in state '$state', which is not a workflow state. The orchestrator hard-fails on it. Valid: $LV_STATES"

  # ── 7. A live worktree the registry does not name ──────────────────────
  #
  # The Branch column is what `lv-list-implementable.sh` used to key its
  # new/resume/fix decision on, and a `—` there is a bookkeeping fact rather
  # than a statement about the filesystem. client-a filed it four times in
  # one day (WFI-219, WFI-220, WFI-221, WFI-224): plans with 5, 7 and 11
  # commits of finished work on live worktrees, all classified `new`, all
  # ending in `git worktree add` failing with "already exists" and a gate a
  # human had to answer. The classifier no longer trusts the column — it falls
  # back to the `feature/<plan-name>` convention — but the drift itself is a
  # registry that disagrees with the filesystem, and the audit is where that
  # gets said out loud.
  #
  # Every state, not just draft/ready: a `complete` plan whose worktree is
  # still live is a drain that did not finish, and that is worth seeing too.
  # Matched on the PLN-NNN prefix, not on the full conventional name. A slug
  # shortened when the worktree was created — `feature/PLN-223-apply-by-content`
  # against a plan named `PLN-223-change-apply-recognizes-applied-by-content` —
  # made the whole block invisible, including the mismatch arm that exists to
  # catch exactly that. PLN-223 sat `complete` with a live worktree and the
  # prose "BUG-234-235 shipped alongside" in its Branch column, and the audit
  # printed "clean" (WFI-242). The prefix is the identity; the slug is a label.
  conv_branch="feature/${id}-${slug}"
  live_branch=$(printf '%s\n' "$live_worktree_branches" | grep -m1 -E "^feature/${id}(-|$)" || true)
  if [ -n "$live_branch" ]; then
    live_path=$(printf '%s\n' "$live_worktrees" | awk -F'\t' -v b="$live_branch" '$1 == b { print $2; exit }')
    case "$state" in
      complete|abandoned)
        # The remedy has to match the state. This branch used to print the same
        # "set the Branch column" advice as every other, which for a plan
        # completed weeks earlier meant writing a branch name into a column
        # every other complete row clears — and leaving the actual fault, an
        # undrained worktree, in place. The audit would then stop reporting it,
        # because the empty-column arm no longer matched (WFI-241).
        report "UNDRAINED     $id is '$state' but still has a live worktree on $live_branch."
        detail "              A terminal plan's worktree is a drain that did not finish. Remove it and leave the branch and the Branch column alone:"
        detail "                git worktree remove ${live_path:-<path>}"
        ;;
      *)
        if [ "$reg_branch" = "—" ] || [ -z "$reg_branch" ]; then
          report "BRANCH DRIFT  $id has a live worktree on $live_branch but its Branch column is empty."
          detail "              Anything reading the column alone sees a plan with no branch. Set it: lv-registry-update.sh $id $state $state $live_branch"
        elif [ "$reg_branch" != "$live_branch" ]; then
          report "BRANCH DRIFT  $id has a live worktree on $live_branch but its Branch column says '$reg_branch'."
          detail "              Two different branches are named for one plan. Establish which carries the work before dispatching it."
          [ "$live_branch" = "$conv_branch" ] || \
            detail "              (The worktree is not on the conventional name $conv_branch either — the slug was shortened when it was created.)"
        fi
        ;;
    esac
  fi

  # ── 7b. The Branch column holds a branch, or it holds an em-dash ───────
  #
  # Checked with no reference to the filesystem, because a bad cell is bad
  # whatever the filesystem holds. Everything above needs a live worktree to
  # reach a verdict, so a column containing prose was only ever caught when a
  # worktree happened to exist to contradict it — PLN-223's read
  # "BUG-234-235 shipped alongside" and PLN-115's read the literal word
  # "complete", and neither was reported (WFI-242). The column feeds
  # `git worktree add` and `git rev-parse`; a value neither of those can use
  # is a fault on its own.
  if [ -n "$reg_branch" ] && [ "$reg_branch" != "—" ] && [ "$reg_branch" != "-" ]; then
    if ! git rev-parse --verify --quiet "refs/heads/$reg_branch" >/dev/null 2>&1; then
      report "BAD BRANCH    $id's Branch column reads '$reg_branch', which is not a branch in this repository."
      detail "              The column is a ref or an em-dash — nothing else. Anything reading it feeds it to git."
      case "$state" in
        complete|abandoned)
          detail "              This plan is terminal, so the convention is an em-dash: lv-registry-update.sh $id $state $state -" ;;
        *)
          detail "              Set it to the branch that carries the work, or to '-' if none does yet." ;;
      esac
    fi
  fi

  case "$state" in draft|ready) ;; *) continue ;; esac
  branch="feature/${id}-${slug}"
  git rev-parse --verify "$branch" >/dev/null 2>&1 || continue
  ahead=$(git rev-list --count "develop..$branch" 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || continue

  # A draft plan with OPEN findings is the fix cycle, not a lost write.
  #
  # `testing → draft` is a documented route: lv-test's findings path and the
  # implementer's escalation both send a plan back to be replanned, and both
  # deliberately keep the feature branch and its worktree for the fix that
  # follows. "draft, branch ahead of develop" is therefore the NORMAL shape of a
  # failed human test — and this check called it a disagreement, told the reader
  # a state write had been lost or the work abandoned, and advised setting the
  # state deliberately. Following that advice moves the plan out of the cycle
  # lv-test just routed it into (client-a WFI-145).
  #
  # The findings are what tell the two apart, and they are the same signal
  # lv-findings-route.sh and lv-list-replanning.sh already route on. WFI-010 —
  # the report this check exists for — was explicit that the plans it found had
  # *no findings to explain the route back*. That is still reported.
  if [ "$state" = "draft" ] && \
     grep -q '^- \[ \]' "plans/${id}-${slug}/findings.md" 2>/dev/null; then
    open_findings=$(grep -c '^- \[ \]' "plans/${id}-${slug}/findings.md" 2>/dev/null || echo 0)
    note "REPLANNING    $id is 'draft' with $open_findings open finding(s) and $branch $ahead ahead of develop."
    detail "              The fix cycle: lv-test or the implementer routed it back and kept the branch. Not a fault."
    continue
  fi

  report "STALE STATE   $id is '$state' but $branch is $ahead commit(s) ahead of develop — the registry and the branch disagree."
  detail "              Either a state write was lost, or the work was abandoned. Check the branch, then set the state deliberately."
done <<< "$reg_rows"

if [ "$problems" -eq 0 ]; then
  [ "$QUIET" = "true" ] || echo "registry audit: clean"
  exit 0
fi

[ "$QUIET" = "true" ] || { echo; echo "registry audit: $problems problem(s)"; }
exit 1
