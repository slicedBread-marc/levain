#!/usr/bin/env bash
# wf-findings-route.sh <plan-dir>
# Reads findings.md in the given plan directory and determines routing.
# Output: one of "escalated", "active", "clean"
#   escalated → has ESCALATED items (route to draft)
#   active    → has unchecked non-escalated items (route to active)
#   clean     → no unchecked findings (route to testing)
#
# A relative <plan-dir> is anchored to the develop root, like every other
# wf-*.sh script, because `plans/` exists nowhere else.
#
# Exit 0 with a verdict on stdout; exit 1 if the plan directory cannot be
# found at all.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

plan_dir="${1:-}"

if [ -z "$plan_dir" ]; then
  echo "Usage: $0 <plan-dir>" >&2
  exit 1
fi

# ── Where is the plan? ────────────────────────────────────────────────────
#
# The skills all invoke this as `wf-findings-route.sh plans/PLN-NNN-<slug>`,
# and verify runs inside the FEATURE worktree, where `plans/` is sparse-
# excluded and so does not exist. A CWD-relative read therefore found nothing —
# and the missing-file branch answered `clean`, the one verdict that sends a
# plan onward to testing. client-a watched a plan with an unchecked finding
# route `clean` from the worktree and `active` from the root, on the same
# findings.md, with no warning either way (WFI-117).
#
# So: resolve like the rest of the harness. Absolute wins, then CWD (a caller
# already standing in the right tree keeps working), then the develop root.
# Nothing found is a caller bug, not a verdict — say so and exit non-zero,
# because "I could not look" and "I looked and it was clean" must never leave
# this script wearing the same output.
if [ "${plan_dir#/}" != "$plan_dir" ]; then
  resolved="$plan_dir"
elif [ -d "$PWD/$plan_dir" ]; then
  resolved="$PWD/$plan_dir"
else
  resolved="$(wf_develop_root)/$plan_dir"
fi

if [ ! -d "$resolved" ]; then
  echo "wf-findings-route: plan directory not found: $plan_dir" >&2
  echo "wf-findings-route: tried '$PWD/$plan_dir' and '$(wf_develop_root)/$plan_dir'." >&2
  echo "wf-findings-route: refusing to emit a verdict — no routing decision was made." >&2
  exit 1
fi

findings="$resolved/findings.md"

# An existing plan directory with no findings.md is the genuine article: verify
# found nothing worth writing down.
if [ ! -f "$findings" ]; then
  echo "clean"
  exit 0
fi

# A routing tag is a TRAILING tag, not a substring.
#
# wf-verify writes these as `← ESCALATED` at the end of the line, and this used
# to match the bare word anywhere in the finding. So a finding whose body
# explained why a tag did NOT apply — "a code-only fix, not `← PLAN-SCOPED`" —
# routed the plan to draft on the strength of its own prose, and the only way
# out was to reword the sentence (client-a WFI-089). A finding must be able
# to name a tag without wearing it.
#
# Both arrow spellings are accepted. Nothing may follow the tag — not even the
# closing backtick of a code span, which is precisely what separates the tag
# from a mention of it: prose quotes a tag (`← PLAN-SCOPED`), a finding wears
# one bare, at the end of its line, as wf-verify writes it.
wf_tagged() {   # wf_tagged <file> <TAG> → 0 if any UNCHECKED finding carries it
  grep -qE "^- \[ \].*(←|<-)[[:space:]]*$2[[:space:]]*$" "$1" 2>/dev/null
}

# Check for ESCALATED items or PLAN-SCOPED security findings (unchecked)
if wf_tagged "$findings" ESCALATED || wf_tagged "$findings" PLAN-SCOPED; then
  echo "escalated"
  exit 0
fi

# Check for any unchecked items.
#
# BROAD-SCOPE is the exception. A finding marked BROAD-SCOPE is out of this
# plan's declared scope and is resolved by spawning an independent bug — the
# skill is explicit that "a plan can go to active or testing while still
# spawning bugs for out-of-scope security issues". Routing on it anyway sent
# the plan back to an implementer whose own Out of Scope section forbids the
# fix, so the only way out was to check off a finding nobody had acted on.
remaining=$(grep '^\- \[ \]' "$findings" 2>/dev/null \
            | grep -cvE "(←|<-)[[:space:]]*BROAD-SCOPE[[:space:]]*$" || true)
if [ "${remaining:-0}" -gt 0 ]; then
  echo "active"
  exit 0
fi

if wf_tagged "$findings" BROAD-SCOPE; then
  echo "wf-findings-route: unchecked BROAD-SCOPE finding(s) present — not routing on them; file each as an independent bug" >&2
fi

echo "clean"
