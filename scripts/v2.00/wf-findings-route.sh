#!/usr/bin/env bash
# wf-findings-route.sh <plan-dir>
# Reads findings.md in the given plan directory and determines routing.
# Output: one of "escalated", "active", "clean"
#   escalated → has ESCALATED items (route to draft)
#   active    → has unchecked non-escalated items (route to active)
#   clean     → no unchecked findings (route to testing)
#
# Exit 0 always.

set -euo pipefail

plan_dir="${1:-}"

if [ -z "$plan_dir" ]; then
  echo "Usage: $0 <plan-dir>" >&2
  exit 1
fi

findings="$plan_dir/findings.md"

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
