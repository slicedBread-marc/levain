#!/usr/bin/env bash
# lv-counter-next.sh [prefix] [--peek]
# Reads the counter from REGISTRY.md, prints the next ID, and increments.
# Optional kind (plan, bug, brief — or its prefix, PLN, BUG, BRF, or a renamed one
# from the ID map) — if given, prints the ID under the prefix the map issues.
# Without prefix, prints just the number.
#
# Examples:
#   lv-counter-next.sh PLN         → prints "PLN-021", counter becomes 22
#   lv-counter-next.sh BUG         → prints "BUG-021"
#   lv-counter-next.sh             → prints "21"
#   lv-counter-next.sh PLN --peek  → prints "PLN-021", counter unchanged
#
# --peek  Answer without taking. This is the ONLY read-only way to ask what the
#         next number would be. Before it existed the question could not be
#         asked at all: the script's single behaviour was to advance, so every
#         diagnostic invocation permanently consumed an artifact number, and
#         because it commits its own increment the burn left `git status` clean
#         and no trace in the worktree (client-a WFI-166, WFI-175). A peeked
#         answer is not a reservation — a concurrent allocation moves it.
#
# THE PREFIX IS CHECKED, BECAUSE AN UNCHECKED ONE IS SPENT
#
# `lv-counter-next.sh --peek` — a flag guessed by a caller who wanted exactly
# the read-only behaviour above — was accepted as an ID prefix. It printed
# `--peek-136`, advanced the counter to 137 and committed
# "registry: counter → 137 (allocated --peek 136)". BUG-136 through BUG-141 were
# already numbered on another machine against that value, so one mistyped flag
# shifted six filed bugs by one against a report and a patch written on the far
# side of a drive gap (WFI-166).
#
# Every allocation here is irreversible by design — there is no lv-* script that
# can walk the counter back, and workflow.md forbids hand-editing REGISTRY.md —
# so an argument this script does not recognise must cost nothing. Unknown is
# refused before the lock is taken.
#
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
prefix=""
peek=false

usage() {
  echo "Usage: $0 [plan|bug|brief] [--peek]" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    --peek|--dry-run) peek=true; shift ;;
    -*) echo "Error: unknown option '$1' — it is not an ID prefix (WFI-166)" >&2; usage ;;
    *)
      [ -z "$prefix" ] || { echo "Error: only one prefix, got '$prefix' and '$1'" >&2; usage; }
      # A kind, or any prefix the map accepts for one (PLN, a renamed LOAF):
      # either way the ID comes out under the prefix the map ISSUES today.
      case "$1" in
        plan)  prefix="$LV_PLN" ;;
        bug)   prefix="$LV_BUG" ;;
        brief) prefix="$LV_BRF" ;;
        *) if   [[ "$1" =~ ^($LV_PLN_RE)$ ]]; then prefix="$LV_PLN"
           elif [[ "$1" =~ ^($LV_BUG_RE)$ ]]; then prefix="$LV_BUG"
           elif [[ "$1" =~ ^($LV_BRF_RE)$ ]]; then prefix="$LV_BRF"
           else echo "Error: '$1' is not an ID prefix — expected $LV_PLN, $LV_BUG or $LV_BRF" >&2; usage
           fi ;;
      esac
      shift ;;
  esac
done

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Read-then-write: without the lock two concurrent callers hand out the same ID.
# Taken on the peek path too — a torn read of a counter mid-rewrite would answer
# with a number that was never there.
wf_lock_acquire registry

# Extract current counter. `recorded` is what the file literally says, and is
# what the rewrite below must match on — `current` may be advanced past it.
current=$(grep -oE 'Counter: [0-9]+' "$REGISTRY" | grep -oE '[0-9]+')
if [ -z "$current" ]; then
  echo "Error: no counter found in $REGISTRY" >&2
  exit 1
fi
recorded="$current"

# ── Never hand out a number that is already in use ────────────────────────
#
# The counter is the only allocator, which makes it authoritative right up
# until something writes an ID without going through it — a hand-created plan
# folder, a migration, a restored backup, a merge that took the other side of
# the `<!-- Counter: N -->` line. After that the counter is BEHIND reality and
# every ID it hands out collides with a live artifact.
#
# client-e ran with the counter reading 11 while live IDs were at 099 (WFI-011)
# — so the counter was not usable as a fallback at the one moment a collision
# made it necessary. The floor below is derived from what exists rather than
# from what was recorded, so drift self-corrects on the next allocation instead
# of turning into a duplicate ID.
max_used=0
while read -r n; do
  n=$((10#$n))
  [ "$n" -gt "$max_used" ] && max_used=$n
done < <(
  {
    grep -oE "($LV_WORK_RE)-[0-9]+" "$REGISTRY" 2>/dev/null
    ls -d plans/*/ bugs/*/*/ plans/briefs/* 2>/dev/null \
      | grep -oE "($LV_WORK_RE)-[0-9]+" 2>/dev/null
  } | sed 's/.*-//' | sort -u
)

# 10# forces base 10 in case the counter was hand-edited with a leading zero.
if [ "$max_used" -ge "$((10#$current))" ]; then
  echo "lv-counter-next: counter was $current but $(printf 'artifact %03d' "$max_used") exists — advancing past it" >&2
  current=$((max_used + 1))
fi
next=$((10#$current + 1))

if $peek; then
  # Answer and touch nothing. The floor advance above is a read of what exists,
  # not a write, so the number reported is the one a real allocation would take
  # — right up until somebody takes it.
  if [ -n "$prefix" ]; then printf "%s-%03d\n" "$prefix" "$current"; else echo "$current"; fi
  exit 0
fi

# Update counter (awk into a tempfile — `sed -i ''` is macOS-only)
awk -v cur="$recorded" -v nxt="$next" '
  { sub("<!-- Counter: " cur " -->", "<!-- Counter: " nxt " -->"); print }
' "$REGISTRY" > "$REGISTRY.tmp" && mv "$REGISTRY.tmp" "$REGISTRY"

# An allocation that is not committed can be taken back — by a stash, or by a
# concurrent worker's checkout — and the same number then goes out twice.
wf_registry_commit "registry: counter → $next (allocated ${prefix:-ID} $current)"

# Output the ID
if [ -n "$prefix" ]; then
  printf "%s-%03d\n" "$prefix" "$current"
else
  echo "$current"
fi
