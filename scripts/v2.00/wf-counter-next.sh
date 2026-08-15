#!/usr/bin/env bash
# wf-counter-next.sh [prefix]
# Reads the counter from REGISTRY.md, prints the next ID, and increments.
# Optional prefix (PLN, BUG, BRF) — if given, prints prefixed ID (e.g., PLN-021).
# Without prefix, prints just the number.
#
# Examples:
#   wf-counter-next.sh PLN   → prints "PLN-021", counter becomes 22
#   wf-counter-next.sh BUG   → prints "BUG-021"
#   wf-counter-next.sh       → prints "21"
#
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
prefix="${1:-}"

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Read-then-write: without the lock two concurrent callers hand out the same ID.
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
    grep -oE '(PLN|BUG|BRF)-[0-9]+' "$REGISTRY" 2>/dev/null
    ls -d plans/*/ bugs/*/*/ plans/briefs/* 2>/dev/null \
      | grep -oE '(PLN|BUG|BRF)-[0-9]+' 2>/dev/null
  } | sed 's/.*-//' | sort -u
)

# 10# forces base 10 in case the counter was hand-edited with a leading zero.
if [ "$max_used" -ge "$((10#$current))" ]; then
  echo "wf-counter-next: counter was $current but $(printf 'artifact %03d' "$max_used") exists — advancing past it" >&2
  current=$((max_used + 1))
fi
next=$((10#$current + 1))

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
