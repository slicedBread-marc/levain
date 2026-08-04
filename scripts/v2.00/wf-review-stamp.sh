#!/usr/bin/env bash
# wf-review-stamp.sh <PLN-NNN>
#
# Records WHICH revision of a plan the review in its `## Review` section is a
# verdict on, by appending one line to that section:
#
#   > **Plan-Hash:** 3f2a…    <!-- wf-review-stamp -->
#
# Run it immediately after writing a review verdict into plan.md — from
# /wf-spec, from /wf-attend, from a review agent's exit path. Nothing else in
# the pipeline needs to know it exists; wf-review-status.sh reads it back.
#
# WHY
#
# Staleness was decided by comparing the review's date with the amendment's,
# and both are day-granular. A plan reviewed and amended on the same day — the
# ordinary case, since findings and the amendment answering them land in the
# same session — is unorderable, so wf-review-status.sh reports
# REVIEW_STALE=unknown. wf-spec's replanning gate says the verdict "must be
# false", which such a plan can never satisfy: the documented gate condition is
# unreachable exactly when replanning is fastest (client-a WFI-069).
#
# A hash of the plan body settles it. Stamped and unchanged → the verdict is
# about this text: not stale, definitively. Stamped and changed → stale,
# definitively. Unstamped → the old date comparison, unknown and all.
#
# Exit 0 on success, 1 if the plan or its `## Review` section is missing.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"
# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"

raw_id="${1:?Usage: $0 <PLN-NNN>}"
plan_id=$(printf '%s' "$raw_id" | grep -oE '^PLN-[0-9]+' || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <PLN-NNN>" >&2; exit 1; }

ROOT="$(wf_develop_root)"
slug=$(grep "^| $plan_id |" "$ROOT/plans/REGISTRY.md" 2>/dev/null \
       | head -1 | awk -F'|' '{print $3}' | xargs || true)
[ -n "$slug" ] || { echo "Error: $plan_id has no row in plans/REGISTRY.md" >&2; exit 1; }

plan_md="$ROOT/plans/${plan_id}-${slug}/plan.md"
[ -f "$plan_md" ] || { echo "Error: $plan_md not found" >&2; exit 1; }

if ! grep -qE '^## Review([ \t]|$)' "$plan_md"; then
  echo "Error: $plan_id has no '## Review' section to stamp" >&2
  exit 1
fi

wf_lock_acquire "plan-$plan_id"

fp=$(wf_plan_body_fingerprint "$plan_id")
[ -n "$fp" ] || { echo "Error: could not fingerprint $plan_id" >&2; exit 1; }

# Replace any previous stamp, then append the current one at the end of the
# Review section. Re-stamping after a re-review is the normal case, and two
# stamps would leave the reader — and the reader's `grep -m1` — guessing.
awk -v fp="$fp" '
  /^## / {
    if (inside && !stamped) { print "> **Plan-Hash:** " fp "    <!-- wf-review-stamp -->"; print ""; stamped = 1 }
    inside = ($0 ~ /^## Review([ \t]|$)/) ? 1 : 0
    print; next
  }
  inside && /wf-review-stamp/ { next }
  { print }
  END { if (inside && !stamped) print "> **Plan-Hash:** " fp "    <!-- wf-review-stamp -->" }
' "$plan_md" > "$plan_md.tmp" && mv "$plan_md.tmp" "$plan_md"

( cd "$ROOT" && "$(cd "$(dirname "$0")" && pwd)/wf-commit.sh" \
    "spec($plan_id): stamp review against the reviewed text" \
    --add "plans/${plan_id}-${slug}/plan.md" >/dev/null ) || true

echo "$plan_id: review stamped ${fp:0:12}"
