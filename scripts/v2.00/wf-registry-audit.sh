#!/usr/bin/env bash
# wf-registry-audit.sh [--quiet]
#
# Checks that the registry and the plans/ directory still describe the same
# world.
#
# WHY THIS EXISTS
#
# REGISTRY.md is the single source of truth for plan state, which means every
# wf-list-* script, the orchestrator and /wf-board see plans *only* through it.
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
#   6. draft/ready plan whose feature branch is ahead of develop (lost write)
#
# Exit 0 when clean, 1 when anything was found. Reports only — it never edits
# the registry, because every finding here has more than one correct repair and
# picking one is the operator's call.

set -euo pipefail

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

_wf_root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || true
[ -n "$_wf_root" ] || _wf_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
cd "$_wf_root"

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "wf-registry-audit.sh: $REGISTRY not found" >&2; exit 1; }

# shellcheck source=wf-states.sh
source "$(dirname "$0")/wf-states.sh"

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

# ── One pass over the registry ───────────────────────────────────────────
#
# Every check below reads the same rows, so they are parsed ONCE into shell
# variables rather than re-awked per check. This script now runs on every
# /wf-status and every /wf-board render, including --watch, so its cost is
# paid continuously rather than on demand: the first cut spawned six
# subprocesses per registry row and measured 1.7s on a 75-plan project, 3.8s
# at 100. Everything below is string work in bash — no subprocess per row.
#
# `reg_rows`  one "<id> <slug> <state>" line per PLN row
# `reg_ids`   space-delimited PLN ids, for membership tests
# `art_ids`   every PLN/BUG/BRF id, for the counter check
eval "$(awk -F'|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  function esc(s)  { gsub(/'"'"'/, "'"'"'\\'"'"''"'"'", s); return s }
  {
    id = trim($2)
    if (id !~ /^(PLN|BUG|BRF)-[0-9]+$/) next
    nums = nums id "\n"
    if (id !~ /^PLN-/) next
    rows = rows id " " trim($3) " " trim($4) "\n"
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
for d in plans/PLN-*/; do
  [ -d "$d" ] || continue
  base="${d%/}"; base="${base##*/}"
  case "$base" in PLN-[0-9]*) ;; *) continue ;; esac
  rest="${base#PLN-}"          # 051-maze-crumbs
  id="PLN-${rest%%-*}"         # PLN-051
  disk_rows="$disk_rows$id $base"$'\n'
  disk_ids="$disk_ids$id "
done

# ── 1. Folder with no row ────────────────────────────────────────────────
while IFS=' ' read -r id base; do
  [ -n "$id" ] || continue
  case "$reg_ids" in
    *" $id "*) ;;
    *)
      report "MISSING ROW   plans/$base has no row in $REGISTRY — invisible to every wf-list-* script and to the orchestrator."
      detail "              Add a row, or abandon it: scripts/wf-exec.sh wf-abandon.sh $id --reason \"...\""
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
    } | { grep -oE '(PLN|BUG|BRF)-[0-9]+' || true; } \
      | sed -E 's/^[A-Z]+-0*//' | { grep -E '^[0-9]+$' || true; } | sort -n | tail -1
  )
  if [ -n "$highest" ] && [ "$counter" -le "$highest" ]; then
    report "COUNTER       <!-- Counter: $counter --> is not above the highest ID in use ($highest) — the next allocation collides."
    detail "              Set it to $((highest + 1))."
  fi
fi

# ── 5. Unroutable states, and 6. pre-implementation states on real work ──
#
# One loop, because both read the same three fields. `draft` means nobody has
# built it yet; app found two such plans carrying finished implementations —
# 21 and 16 commits, no findings to explain the route back (WFI-010). A state
# write that can be lost is worth catching from the branch side.
while IFS=' ' read -r id slug state; do
  [ -n "$id" ] || continue

  wf_state_is_valid "$state" || \
    report "BAD STATE     $id is in state '$state', which is not a workflow state. The orchestrator hard-fails on it. Valid: $WF_STATES"

  case "$state" in draft|ready) ;; *) continue ;; esac
  branch="feature/${id}-${slug}"
  git rev-parse --verify "$branch" >/dev/null 2>&1 || continue
  ahead=$(git rev-list --count "develop..$branch" 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || continue
  report "STALE STATE   $id is '$state' but $branch is $ahead commit(s) ahead of develop — the registry and the branch disagree."
  detail "              Either a state write was lost, or the work was abandoned. Check the branch, then set the state deliberately."
done <<< "$reg_rows"

if [ "$problems" -eq 0 ]; then
  [ "$QUIET" = "true" ] || echo "registry audit: clean"
  exit 0
fi

[ "$QUIET" = "true" ] || { echo; echo "registry audit: $problems problem(s)"; }
exit 1
