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

WF_STATES="draft ready active verify testing complete rolled-back abandoned"

problems=0
report() {
  problems=$((problems + 1))
  [ "$QUIET" = "true" ] || printf '%s\n' "$1"
}

# Registry rows: ID -> state. Only real artifact rows, never the header or the
# separator line.
registry_ids=$(awk -F'|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) ~ /^PLN-[0-9]+$/ { print trim($2) }
' "$REGISTRY")

# Plan folders on disk.
disk_ids=""
for d in plans/PLN-*/; do
  [ -d "$d" ] || continue
  base=$(basename "$d")
  id=$(printf '%s' "$base" | grep -oE '^PLN-[0-9]+' || true)
  [ -n "$id" ] || continue
  disk_ids="$disk_ids$id $base"$'\n'
done

# ── 1. Folder with no row ────────────────────────────────────────────────
while IFS=' ' read -r id base; do
  [ -n "$id" ] || continue
  if ! printf '%s\n' "$registry_ids" | grep -qx "$id"; then
    report "MISSING ROW   plans/$base has no row in $REGISTRY — invisible to every wf-list-* script and to the orchestrator."
    report "              Add a row, or abandon it: scripts/wf-exec.sh wf-abandon.sh $id --reason \"...\""
  fi
done <<< "$disk_ids"

# ── 2. Row with no folder ────────────────────────────────────────────────
while IFS= read -r id; do
  [ -n "$id" ] || continue
  found=false
  for d in plans/${id}-*/; do [ -d "$d" ] && found=true && break; done
  if [ "$found" = "false" ]; then
    report "DANGLING ROW  $id has a registry row but no plans/$id-*/ folder — state with nothing behind it."
  fi
done <<< "$registry_ids"

# ── 3. Duplicate IDs ─────────────────────────────────────────────────────
dupe_rows=$(printf '%s\n' "$registry_ids" | sort | uniq -d || true)
for id in $dupe_rows; do
  report "DUPLICATE ROW $id appears more than once in $REGISTRY — every lookup takes the first match and silently ignores the rest."
done

dupe_dirs=$(printf '%s' "$disk_ids" | awk '{print $1}' | sort | uniq -d || true)
for id in $dupe_dirs; do
  folders=$(printf '%s' "$disk_ids" | awk -v i="$id" '$1 == i { print $2 }' | tr '\n' ' ')
  report "DUPLICATE DIR $id names two plan folders: $folders"
  report "              The counter handed the same number out twice. Check both for competing migrations or schema changes before removing either."
done

# ── 4. Counter sanity ────────────────────────────────────────────────────
counter=$(grep -oE '<!-- Counter: [0-9]+ -->' "$REGISTRY" | grep -oE '[0-9]+' | head -1 || true)
if [ -n "$counter" ]; then
  highest=$(
    { printf '%s\n' "$registry_ids"
      awk -F'|' '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        trim($2) ~ /^(PLN|BUG|BRF)-[0-9]+$/ { print trim($2) }
      ' "$REGISTRY"
      printf '%s' "$disk_ids" | awk '{print $1}'
      for d in bugs/*/*/ plans/briefs/*; do
        [ -e "$d" ] || continue
        basename "$d" | grep -oE '^(BUG|BRF)-[0-9]+' || true
      done
    } | grep -oE '[0-9]+$' | sed 's/^0*//' | sort -n | tail -1
  )
  if [ -n "$highest" ] && [ "$counter" -le "$highest" ]; then
    report "COUNTER       <!-- Counter: $counter --> is not above the highest ID in use ($highest) — the next allocation collides."
    report "              Set it to $((highest + 1))."
  fi
fi

# ── 5. Unroutable states ─────────────────────────────────────────────────
while IFS= read -r line; do
  [ -n "$line" ] || continue
  id=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2}')
  st=$(printf '%s' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$4); print $4}')
  case " $WF_STATES " in
    *" $st "*) ;;
    *) report "BAD STATE     $id is in state '$st', which is not a workflow state. The orchestrator hard-fails on it. Valid: $WF_STATES" ;;
  esac
done < <(awk -F'|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) ~ /^PLN-[0-9]+$/ { print }
' "$REGISTRY")

# ── 6. Pre-implementation state sitting on a real implementation ─────────
#
# `draft` means "being written or needs replanning" — nobody has built it yet.
# app found two plans at `draft` carrying finished work: 22 files/+2590 across
# 21 commits, and 33 files/+1639 across 16 commits including passing tests,
# neither with an unchecked or ESCALATED finding that would explain the route
# back (WFI-010). Whatever wrote those rows, the registry stopped describing
# the branch — and a state write that can be lost is worth catching from the
# other side rather than trusting.
while IFS='|' read -r _ id slug state _rest; do
  id=$(printf '%s' "$id" | xargs); state=$(printf '%s' "$state" | xargs)
  slug=$(printf '%s' "$slug" | xargs)
  [ -n "$id" ] || continue
  case "$state" in draft|ready) ;; *) continue ;; esac
  branch="feature/${id}-${slug}"
  git rev-parse --verify "$branch" >/dev/null 2>&1 || continue
  ahead=$(git rev-list --count "develop..$branch" 2>/dev/null || echo 0)
  [ "$ahead" -gt 0 ] || continue
  report "STALE STATE   $id is '$state' but $branch is $ahead commit(s) ahead of develop — the registry and the branch disagree."
  report "              Either a state write was lost, or the work was abandoned. Check the branch, then set the state deliberately."
done < <(awk -F'|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) ~ /^PLN-[0-9]+$/ { print }
' "$REGISTRY")

if [ "$problems" -eq 0 ]; then
  [ "$QUIET" = "true" ] || echo "registry audit: clean"
  exit 0
fi

[ "$QUIET" = "true" ] || { echo; echo "registry audit: $problems problem(s)"; }
exit 1
