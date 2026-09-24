#!/usr/bin/env bash
# lv-prune-versions.sh [--dry-run | --list]
#
# Manages the script snapshots deployed in this project.
#
# TWO THINGS ACCUMULATE HERE, AND THEY ARE NOT THE SAME THING.
#
#   GENERATIONS (v1.x, v2.00)  — what a plan's WF stamp pins. A generation is
#     retained while any non-complete plan resolves to it, so an in-flight
#     plan keeps the script contract it was specced under.
#
#   BUILDS (scripts/gen/<version>-<timestamp>/) — what a DEPLOY produces. Each
#     is an immutable copy of every generation, published by one rename; a
#     deploy never writes into one anything is resolving (docs/atomic-deploy.md).
#     install.sh already keeps only the current build and the one before it, so
#     these rarely need pruning by hand — but a client that has taken a deploy
#     interrupted before its retention pass will have more.
#
# Modes:
#   --list      Print status only: current workflow version, current build,
#               current generation, and which generations are still referenced
#               by non-complete plans. Read-only; safe to run from any skill.
#   --dry-run   Enumerate what would be removed (in-use = retained); no changes.
#   (default)   Dry-run preview, then prompt before deleting.
#
# In-use set (generations):
#   1. For each non-complete plan in plans/REGISTRY.md, resolve its WF stamp
#      to a generation via scripts/version-map.txt (same algorithm as
#      scripts/lv-exec.sh). Empty WF → v1.x (legacy baseline).
#   2. Resolve .claude/workflow-version → its generation ("current").
#   3. Always retain v1.x (baseline floor for legacy app plans).
#
# In-use set (builds): the one scripts/current names, and nothing else. A build
# other than the published one is resolved by no caller, by construction.
#
# Unversioned — safe to run under any workflow version.

set -euo pipefail

MODE="${1:-prune}"
case "$MODE" in
  --list|--dry-run|prune) ;;
  *) echo "Usage: $0 [--dry-run | --list]" >&2; exit 1 ;;
esac

# ── Locate the project root ─────────────────────────────────────────────
find_project_root() {
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/scripts/version-map.txt" ]; then printf '%s' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

ROOT="$(find_project_root)" || { echo "lv-prune-versions.sh: cannot locate scripts/version-map.txt" >&2; exit 1; }
MAP="$ROOT/scripts/version-map.txt"
REGISTRY="$ROOT/plans/REGISTRY.md"
LV_FILE="$ROOT/.claude/workflow-version"
GEN_ROOT="$ROOT/scripts/gen"
CURRENT_BUILD=""
[ -f "$ROOT/scripts/current" ] && CURRENT_BUILD=$(tr -d '[:space:]' < "$ROOT/scripts/current")

# ── Resolve a workflow version → script folder (highest min ≤ version). ──
resolve_folder() {
  local wf="$1"
  [ -z "$wf" ] && wf="0.00"
  local folder=""
  while IFS= read -r line; do
    line="${line%%#*}"
    [ -z "${line// }" ] && continue
    local min_ver f
    min_ver=$(echo "$line" | awk '{print $1}')
    f=$(echo "$line" | awk '{print $2}')
    [ -z "$min_ver" ] || [ -z "$f" ] && continue
    if [ "$(printf '%s\n%s\n' "$min_ver" "$wf" | sort -V | head -1)" = "$min_ver" ]; then
      folder="$f"
    fi
  done < "$MAP"
  echo "$folder"
}

# ── Current workflow version + folder ───────────────────────────────────
current_wf=""
[ -f "$LV_FILE" ] && current_wf=$(tr -d '[:space:]' < "$LV_FILE")
current_folder=$(resolve_folder "$current_wf")

# ── Build in-use set from non-complete REGISTRY rows ────────────────────
declare -a in_use
in_use=("v1.x")  # always retain baseline
[ -n "$current_folder" ] && in_use+=("$current_folder")

if [ -f "$REGISTRY" ]; then
  while IFS='|' read -r _ id slug state priority branch updated wf _rest; do
    state=$(echo "$state" | xargs)
    wf=$(echo "$wf" | xargs)
    [ -z "$state" ] && continue
    [ "$state" = "complete" ] && continue
    [[ "$id" == *"ID"* ]] && continue  # header row
    folder=$(resolve_folder "$wf")
    [ -n "$folder" ] && in_use+=("$folder")
  done < <(grep -E "^\| [A-Z]{1,5}-[0-9]+ " "$REGISTRY" 2>/dev/null || true)   # any ID prefix (lv-ids.sh)
fi

# Dedupe in-use.
unique_in_use=()
for f in "${in_use[@]}"; do
  found=0
  for u in "${unique_in_use[@]+"${unique_in_use[@]}"}"; do
    [ "$u" = "$f" ] && found=1 && break
  done
  [ "$found" -eq 0 ] && unique_in_use+=("$f")
done

# ── Enumerate what is on disk ───────────────────────────────────────────
#
# Generations inside the published build, plus any legacy pre-gen folder still
# sitting at scripts/<label>/. Both are removable by the same rule, and a
# legacy folder that is no longer in use is exactly what the v9.0.0 migration
# leaves behind for this script to collect.
GEN_BASE=""
if [ -n "$CURRENT_BUILD" ] && [ -d "$GEN_ROOT/$CURRENT_BUILD" ]; then
  GEN_BASE="$GEN_ROOT/$CURRENT_BUILD"
fi

on_disk=()
for d in ${GEN_BASE:+"$GEN_BASE"/v*/} "$ROOT/scripts"/v*/; do
  [ -d "$d" ] || continue
  base=$(basename "$d")
  case " ${on_disk[*]+${on_disk[*]}} " in *" $base "*) continue ;; esac
  on_disk+=("$base")
done

# Stale builds: anything under scripts/gen/ that scripts/current does not name.
stale_builds=()
for d in "$GEN_ROOT"/*/; do
  [ -d "$d" ] || continue
  base=$(basename "$d")
  [ "$base" = "$CURRENT_BUILD" ] && continue
  stale_builds+=("$base")
done

# ── --list mode: print state and exit ───────────────────────────────────
if [ "$MODE" = "--list" ]; then
  echo "Workflow version:  ${current_wf:-<unset>}"
  echo "Current build:     ${CURRENT_BUILD:-<none — pre-v9.0.0 layout>}"
  echo "Current generation: ${current_folder:-<none>}"
  echo "Generations on disk: ${on_disk[*]:-<none>}"
  echo "Generations in use:  ${unique_in_use[*]}"
  echo "Stale builds:       ${stale_builds[*]:-<none>}"
  exit 0
fi

# ── Compute removable set ───────────────────────────────────────────────
#
# A generation is removable when no non-complete plan resolves to it. It is
# removed from BOTH places it can sit: inside the published build, and at the
# legacy scripts/<label>/ path a pre-v9.0.0 deploy left behind.
removable=()
for f in "${on_disk[@]}"; do
  keep=0
  for u in "${unique_in_use[@]}"; do
    [ "$u" = "$f" ] && keep=1 && break
  done
  [ "$keep" -eq 0 ] && removable+=("$f")
done

if [ "${#removable[@]}" -eq 0 ] && [ "${#stale_builds[@]}" -eq 0 ]; then
  echo "Nothing to prune. All ${#on_disk[@]} generation(s) on disk are in use or retained,"
  echo "and scripts/gen/ holds only the published build."
  exit 0
fi

echo "Generations on disk: ${on_disk[*]:-<none>}"
echo "In use (retained):   ${unique_in_use[*]}"
echo "Removable:           ${removable[*]:-<none>}"
[ "${#stale_builds[@]}" -gt 0 ] && echo "Stale builds:        ${stale_builds[*]}"

if [ "$MODE" = "--dry-run" ]; then
  echo "(dry-run — no changes written)"
  exit 0
fi

printf "Remove %d generation(s) and %d stale build(s)? [y/N] " \
  "${#removable[@]}" "${#stale_builds[@]}"
read -r ans
case "$ans" in
  y|Y|yes|YES)
    for f in "${removable[@]+"${removable[@]}"}"; do
      if [ -n "$GEN_BASE" ] && [ -d "$GEN_BASE/$f" ]; then
        rm -rf "$GEN_BASE/$f"
        echo "  removed scripts/gen/$CURRENT_BUILD/$f"
      fi
      if [ -d "$ROOT/scripts/$f" ]; then
        rm -rf "$ROOT/scripts/$f"
        echo "  removed legacy scripts/$f"
      fi
    done
    # Never the published build: it is the one thing every caller resolves.
    for b in "${stale_builds[@]+"${stale_builds[@]}"}"; do
      rm -rf "$GEN_ROOT/$b"
      echo "  removed scripts/gen/$b"
    done
    echo "Done."
    ;;
  *)
    echo "Aborted."
    exit 0
    ;;
esac
