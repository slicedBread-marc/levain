#!/usr/bin/env bash
# lv-review-stamp.sh <PLN-NNN> [--no-commit]
#
# Records WHICH revision of a plan the review in its `## Review` section is a
# verdict on, by appending one line to that section:
#
#   > **Plan-Hash:** 3f2a…    <!-- lv-review-stamp -->
#
# Run it immediately after writing a review verdict into plan.md — from
# /lv-spec, from /lv-attend, from a review agent's exit path. Nothing else in
# the pipeline needs to know it exists; lv-review-status.sh reads it back.
#
# WHY
#
# Staleness was decided by comparing the review's date with the amendment's,
# and both are day-granular. A plan reviewed and amended on the same day — the
# ordinary case, since findings and the amendment answering them land in the
# same session — is unorderable, so lv-review-status.sh reports
# REVIEW_STALE=unknown. lv-spec's replanning gate says the verdict "must be
# false", which such a plan can never satisfy: the documented gate condition is
# unreachable exactly when replanning is fastest (client-a WFI-069).
#
# A hash of the plan body settles it. Stamped and unchanged → the verdict is
# about this text: not stale, definitively. Stamped and changed → stale,
# definitively. Unstamped → the old date comparison, unknown and all.
#
# --no-commit: write the stamp and leave it staged for the caller's own commit.
#
# The stamp normally commits itself, which is right for a caller that has no
# commit of its own coming (lv-attend deciding a stale verdict, a review agent's
# exit). It is wrong inside lv-spec's replan, where the whole amendment — the
# new Amendment entry, the Tests rows, the Design Decisions, two review rounds —
# is still uncommitted when the stamp runs. The stamp swept all of it into
# "spec(PLN-NNN): stamp review against the reviewed text", a message describing
# none of it, and the replan's own commit two steps later then had nothing left
# to record. Anyone reading git log for why the plan changed was pointed at the
# wrong commit (client-a WFI-085).
#
# Exit 0 on success, 1 if the plan or its `## Review` section is missing.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"
# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"

raw_id="${1:?Usage: $0 <$LV_PLN-NNN> [--no-commit]}"
shift
no_commit=false
while [ $# -gt 0 ]; do
  case "$1" in
    --no-commit) no_commit=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <$LV_PLN-NNN> [--no-commit]" >&2; exit 1; }

ROOT="$(wf_develop_root)"
slug=$(wf_registry_field "$plan_id" slug "$ROOT/plans/REGISTRY.md")
[ -n "$slug" ] || { echo "Error: $plan_id has no row in plans/REGISTRY.md" >&2; exit 1; }

plan_md="$ROOT/plans/${plan_id}-${slug}/plan.md"
[ -f "$plan_md" ] || { echo "Error: $plan_md not found" >&2; exit 1; }

if ! grep -qE '^## Review([ \t]|$)' "$plan_md"; then
  echo "Error: $plan_id has no '## Review' section to stamp" >&2
  exit 1
fi

# ── A stamp on a verdict nobody can read is worse than no stamp ───────────
#
# This used to stamp any section with the right heading, whatever was in it.
# That is how a review becomes invisible without anyone noticing: client-a's
# PLN-209 carried a hand-written prose `## Review` — `### Round 1 — 2026-08-20
# — **Approved with notes**`, no blockquote, no `Result:` line — and three
# scripts touched it without complaint. lv-manual-lint.sh returned 0 twice,
# this script stamped a Plan-Hash into it, and only lv-review-status.sh, read
# by chance on the way to the transition, reported REVIEW_LOCATION='none' and
# REVIEW_STAMPED='false' for the very same plan. That is the row /lv-attend
# renders as "the plan gated before its review" — a harness fault — on a plan
# that had in fact been reviewed and approved (WFI-207).
#
# The stamp is what made it silent. An unstamped unparseable review still reads
# as unstamped; a STAMPED unparseable one asserts a verdict was anchored, and
# every later staleness check on it returns `none` while looking like it worked.
#
# So the parser that will read this back gets consulted before anything is
# written. Same script, same rules — there is no second opinion to disagree
# with later.
review_status_out=$("$(dirname "$0")/lv-review-status.sh" "$plan_id" 2>/dev/null || true)
review_location=$(printf '%s' "$review_status_out" | grep -m1 "^REVIEW_LOCATION=" \
                  | sed "s/^REVIEW_LOCATION='\{0,1\}//; s/'\{0,1\}$//" || true)
if [ "${review_location:-none}" = "none" ]; then
  echo "Error: $plan_id has a '## Review' section, but lv-review-status.sh cannot read a verdict out of it." >&2
  echo "       Refusing to stamp — a stamp on an unreadable verdict makes it look anchored while every" >&2
  echo "       later check reports 'none', which reads downstream as 'never reviewed' (WFI-207)." >&2
  echo "" >&2
  echo "       A verdict is a line naming a Result. plans/TEMPLATE.md writes it as a blockquote:" >&2
  echo "" >&2
  echo "         > **Result:** Approved with notes — <what the notes were>" >&2
  echo "" >&2
  echo "       Rewrite the section into that shape and re-run. Do not work around this by skipping the stamp." >&2
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
    if (inside && !stamped) { print "> **Plan-Hash:** " fp "    <!-- lv-review-stamp -->"; print ""; stamped = 1 }
    inside = ($0 ~ /^## Review([ \t]|$)/) ? 1 : 0
    print; next
  }
  inside && /lv-review-stamp/ { next }
  { print }
  END { if (inside && !stamped) print "> **Plan-Hash:** " fp "    <!-- lv-review-stamp -->" }
' "$plan_md" > "$plan_md.tmp" && mv "$plan_md.tmp" "$plan_md"

if $no_commit; then
  ( cd "$ROOT" && git add "plans/${plan_id}-${slug}/plan.md" >/dev/null 2>&1 ) || true
  echo "$plan_id: review stamped ${fp:0:12} (staged, not committed)"
else
  ( cd "$ROOT" && "$(cd "$(dirname "$0")" && pwd)/lv-commit.sh" \
      "spec($plan_id): stamp review against the reviewed text" \
      --add "plans/${plan_id}-${slug}/plan.md" >/dev/null ) || true
  echo "$plan_id: review stamped ${fp:0:12}"
fi
