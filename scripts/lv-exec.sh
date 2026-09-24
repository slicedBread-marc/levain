#!/usr/bin/env bash
# lv-exec.sh <script-name> [args...]
#
# Dispatcher that resolves which versioned script folder to invoke based on
# (in priority order):
#   1. $LV_VERSION env override
#   2. WF column in plans/REGISTRY.md for the first PLN-looking arg
#   3. .claude/workflow-version (current workflow)
#
# The resolved workflow version is mapped to a generation label via
# scripts/version-map.txt — the highest row whose min_workflow_version
# is <= the effective version wins. Missing/empty version is treated as 0.00.
#
# The label is then resolved to a directory through scripts/current, which
# names the published build under scripts/gen/. A deploy never writes into a
# build anything is resolving; it builds elsewhere and rewrites that one line.
# docs/atomic-deploy.md.
#
# This dispatcher is unversioned; it lives at scripts/lv-exec.sh on every
# client. Changing it is a coordinated breaking change.

set -euo pipefail

# Pre-14.0.0 environment names: each WF_* still seeds its LV_* counterpart
# unless that is set already, so shell profiles and daemons started before the
# rename keep working.
for _wf in $(compgen -e | grep '^WF_' || true); do
  _lv="LV_${_wf#WF_}"; [ -n "${!_lv+x}" ] || export "$_lv=${!_wf}"
done; unset _wf _lv

if [ $# -lt 1 ]; then
  echo "Usage: $0 <script-name> [args...]" >&2
  exit 1
fi

case "$1" in
  -h|--help)
    echo "Usage: $0 <script-name> [args...]"
    echo
    echo "Runs a versioned lv-* script. '$0 <script-name> --help' prints that"
    echo "script's own manual. Version resolution: \$LV_VERSION, then the WF"
    echo "column in plans/REGISTRY.md, then .claude/workflow-version."
    exit 0 ;;
esac

script_name="$1"
shift

# ── Locate the project root ──────────────────────────────────────────────
# The MAIN worktree first, then a walk up from CWD.
#
# Walking up from CWD alone is wrong inside a feature worktree. plans/, the
# registry and the deployed script snapshots all live on develop, and a
# worktree that picked up a partial `scripts/` from an interrupted deploy
# answers the walk with itself — at which point `.claude/workflow-version` is
# sparse-excluded there, the effective version reads as unstamped, and every
# call routes to the v1.x baseline folder that no longer exists on disk.
find_project_root() {
  local main
  main=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  if [ -n "$main" ] && [ -f "$main/scripts/version-map.txt" ]; then
    printf '%s' "$main"; return 0
  fi
  local dir="$PWD"
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/scripts/version-map.txt" ]; then printf '%s' "$dir"; return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

ROOT="$(find_project_root)" || { echo "lv-exec.sh: cannot locate scripts/version-map.txt (run from within a project)" >&2; exit 1; }

# ── Resolve effective workflow version ───────────────────────────────────
# A version is dotted digits and nothing else. This matters: `sort -V` places
# any non-numeric string ABOVE every numeric version, so an unstamped marker
# like the registry's em-dash would satisfy EVERY row in version-map.txt and
# resolve to the newest script folder — the precise opposite of what the WF
# column exists to guarantee. Such a value is treated as "not stamped".
is_version() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)*$ ]]; }

effective=""

if [ -n "${LV_VERSION:-}" ]; then
  # An explicit override is human input, so a typo fails loudly rather than
  # silently routing somewhere surprising.
  if ! is_version "$LV_VERSION"; then
    echo "lv-exec.sh: LV_VERSION='$LV_VERSION' is not a version (expected digits and dots, e.g. 2.5.1)" >&2
    exit 1
  fi
  effective="$LV_VERSION"
elif [ $# -ge 1 ] && [[ "$1" =~ ^[A-Z]{1,5}-[0-9]+ ]]; then
  # Extract bare PLN-NNN from the arg (handles both PLN-041 and PLN-041-slug forms).
  # Any ID shape, not PLN alone: a project may rename its plan prefix (the ID
  # map, lv-ids.sh), and reading the map here would cost a fork on every call.
  # Only an ID with a registry row is routed; anything else falls through.
  # The `=~` in the elif above already matched it, so BASH_REMATCH has it and
  # no `grep` fork is needed — this runs on every single harness call.
  plan_id="${BASH_REMATCH[0]}"
  if [ -f "$ROOT/plans/REGISTRY.md" ]; then
    # Row format: | PLN-NNN | slug | state | priority | branch | updated | WF |
    # awk -F'|' fields:  $2    $3      $4       $5       $6       $7     $8
    #
    # One awk does the row match, the field pick and the trim that used to be
    # a grep|head|awk|sed chain of four processes.
    effective=$(awk -F'|' -v id="$plan_id" '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      trim($2) == id { print trim($8); exit }
    ' "$ROOT/plans/REGISTRY.md")
    # "—", "?", "n/a" and friends all mean the same thing as blank: this plan
    # was never stamped. Fall through to the project's current version.
    is_version "$effective" || effective=""
  fi
fi

if [ -z "$effective" ] && [ -f "$ROOT/.claude/workflow-version" ]; then
  effective=$(tr -d '[:space:]' < "$ROOT/.claude/workflow-version")
  if [ -n "$effective" ] && ! is_version "$effective"; then
    echo "lv-exec.sh: .claude/workflow-version contains '$effective', not a version — using baseline" >&2
    effective=""
  fi
fi

[ -z "$effective" ] && effective="0.00"

# ── Resolve script folder via version-map.txt ────────────────────────────
# Pick the highest min_workflow_version that is <= effective.
# Version comparison: use sort -V (natural version sort).
map="$ROOT/scripts/version-map.txt"
[ -f "$map" ] || { echo "lv-exec.sh: missing $map" >&2; exit 1; }

# ver_le <a> <b> — true when version a <= version b, comparing dotted numeric
# components. Replaces a `printf | sort -V | head` subshell that was spawned
# once per map row, per harness call, to order two strings is_version() has
# already proved are dotted digits. A missing component reads as 0, so
# `2` <= `2.0` <= `2.00`, which is what sort -V did for these inputs too.
ver_le() {
  local a="$1" b="$2" i n
  local -a A B
  IFS=. read -r -a A <<< "$a"
  IFS=. read -r -a B <<< "$b"
  n=${#A[@]}; [ "${#B[@]}" -gt "$n" ] && n=${#B[@]}
  for ((i = 0; i < n; i++)); do
    (( 10#${A[i]:-0} < 10#${B[i]:-0} )) && return 0
    (( 10#${A[i]:-0} > 10#${B[i]:-0} )) && return 1
  done
  return 0
}

script_folder=""
while IFS= read -r line; do
  # Skip blanks and comments
  line="${line%%#*}"
  [ -z "${line// }" ] && continue
  # `read` into named vars, NOT `set --`: the positional parameters here are
  # the caller's argv and are dispatched to the target script further down.
  read -r min_ver folder _ <<< "$line"
  [ -n "$min_ver" ] && [ -n "$folder" ] || continue
  # If min_ver <= effective, this row is a candidate (rows are ascending,
  # so the last candidate wins).
  if ver_le "$min_ver" "$effective"; then
    script_folder="$folder"
  fi
done < "$map"

if [ -z "$script_folder" ]; then
  echo "lv-exec.sh: no script folder maps to workflow version '$effective' (check $map)" >&2
  exit 1
fi

# ── Resolve the generation label to a directory on disk ──────────────────
#
# The label (v2.00) is a GENERATION, not a path. Since v9.0.0 a deploy builds
# into scripts/gen/<build id>/ — immutable from the moment it is named — and
# publishes it by writing one line to scripts/current. So a caller mid-run
# keeps resolving a complete, self-consistent harness while a deploy replaces
# it, and the next caller gets the new one. Before that, deploy rewrote the
# folder in place and a sweep landing inside the write window read a
# half-replaced harness (coordinator WFI-003). See docs/atomic-deploy.md.
#
# The legacy fallback is not dead code. install.sh flips scripts/current
# BEFORE it replaces this dispatcher, so on a client's first gen-era deploy an
# old wf-exec.sh — which knows nothing of scripts/current — has to resolve the
# legacy folder, and that folder is still the old harness, whole. It is also
# what answers for a client that has not been redeployed at all.
build=""
[ -f "$ROOT/scripts/current" ] && build=$(tr -d '[:space:]' < "$ROOT/scripts/current")

script_dir=""
if [ -n "$build" ] && [ -d "$ROOT/scripts/gen/$build/$script_folder" ]; then
  script_dir="$ROOT/scripts/gen/$build/$script_folder"
elif [ -d "$ROOT/scripts/$script_folder" ]; then
  script_dir="$ROOT/scripts/$script_folder"
else
  echo "lv-exec.sh: no directory on disk for generation '$script_folder'" >&2
  echo "            (build '${build:-none}' in $ROOT/scripts) — run deploy-all.sh to reinstall" >&2
  exit 1
fi

target="$script_dir/$script_name"

# A pre-14.0.0 name (wf-*.sh) still resolves, to its lv-* successor, when no
# script by the old name exists: skills, notes and muscle memory written before
# the rename keep working. wf-board became lv-tray.
if [ ! -x "$target" ] && [[ "$script_name" == wf-* ]]; then
  renamed="lv-${script_name#wf-}"
  case "$renamed" in lv-board.sh) renamed=lv-tray.sh ;; lv-board-drill.sh) renamed=lv-tray-drill.sh ;; esac
  [ -x "$script_dir/$renamed" ] && target="$script_dir/$renamed"
fi

if [ ! -x "$target" ]; then
  echo "lv-exec.sh: $target is missing or not executable — run deploy-all.sh to reinstall" >&2
  exit 1
fi

# ── --help, for every script, whether or not it parses one ───────────────
#
# Each script's leading comment block IS its manual — usage lines, options,
# and the incident behind each. Almost none of them routed `--help` to it: 6
# of 98 handled the flag, and the rest either answered "Unknown option" and
# exited 1, or worse, consumed it. `lv-commit.sh --help` took `--help` as the
# positional <message> and printed "nothing to commit for the given paths —
# skipped", exit 0 — the flag silently became a no-op commit attempt
# (client-b WFI-006; WFI-008 reports the same for lv-bug-close.sh and
# lv-claim.sh). Fixing that one script at a time leaves 92 to go and the next
# new script starts out wrong again.
#
# So the dispatcher answers it, once, for all of them: every skill and every
# worker reaches a lv-* script through here. A script that handles the flag
# itself still wins — we only step in when its own parser has no case for it.
if [ $# -ge 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  if ! grep -qE '^[[:space:]]*(-h\|)?--help\)' "$target"; then
    awk 'NR == 1 && /^#!/ { next }
         /^#/ { sub(/^#[ ]?/, ""); print; next }
         { exit }' "$target"
    exit 0
  fi
fi

exec "$target" "$@"
