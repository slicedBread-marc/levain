#!/usr/bin/env bash
# wf-findings-route.sh <plan-dir>
# Reads findings.md in the given plan directory and determines routing.
# Output: one of "escalated", "active", "clean"
#   escalated → has ESCALATED items (route to draft)
#   active    → has unchecked non-escalated items (route to active)
#   clean     → no unchecked findings (route to testing)
#
# Two trailing tags are deliberately NOT routed on — BROAD-SCOPE and
# MANUAL-TEST. Both mean "real work, but not the implementer's". See the
# comment above `remaining=` for why routing on them cannot terminate.
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

# ── A finding is a BLOCK, not a line ──────────────────────────────────────
#
# Every tag test below is anchored to `$` — the tag ends the finding, and
# nothing may follow it. That was written against findings.md files where each
# finding is one physical line, however long, which is how every existing one
# happened to be written.
#
# A verify agent then wrote PLN-060's single finding as a hard-wrapped markdown
# paragraph: 25 physical lines, continuations indented two spaces. Appending
# `<- BROAD-SCOPE` to the last of them tagged the FINDING correctly and matched
# nothing, because no single line both started with `- [ ]` and ended with the
# tag. The script kept answering `active` while a plain read of the file showed
# the tag right there, and the only way out was to reflow the finding by hand
# (client-a WFI-142).
#
# Every tag test below runs against FLATTENED findings — one physical line per
# finding — because markdown does not promise that a list item is one line. The
# flattener is wf_findings_flat() in wf-orch-lib.sh; its comment carries the
# block rules and the two WFIs that set them. It lived here, privately, which
# is exactly why the routing test read a hard-wrapped `← ESCALATED` correctly
# while every display count in the worklists did not (client-d WFI-031).
#
# The tags keep their exact meaning: a tag ends the FINDING. A finding may be
# as long and as wrapped as its author needed, and "prose quoting a tag" stays
# unmatched for the reason it always was — the closing backtick after it.
flat=$(mktemp "${TMPDIR:-/tmp}/wf-findings.XXXXXX")
trap 'rm -f "$flat"' EXIT
wf_findings_flat "$findings" > "$flat"
findings="$flat"

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
# Two tags are the exception, and both mean the same structural thing: there is
# work here, and it is not the implementer's.
#
# BROAD-SCOPE is out of this plan's declared scope and is resolved by spawning
# an independent bug — the skill is explicit that "a plan can go to active or
# testing while still spawning bugs for out-of-scope security issues". Routing
# on it anyway sent the plan back to an implementer whose own Out of Scope
# section forbids the fix, so the only way out was to check off a finding
# nobody had acted on.
#
# MANUAL-TEST is a test-cycle item: a note that restates an `#### Manual`
# acceptance criterion still needing human eyes. It is resolved at the manual
# gate in `testing`, which is the purpose-built mechanism for it — so routing
# to `active` on one puts the plan in front of an implementer who has NO CODE
# TO WRITE, and whose only forward move is back to verify, which reaches this
# same line and routes to `active` again.
#
# client-a's PLN-204 ran that loop three times (WFI-203, then WFI-204 and
# WFI-205 watching it recur). Two leftover narrative lines from an earlier
# human-test cycle, both restating one still-open (eyes:blocking) criterion
# that no unattended session can execute, held a plan with a clean build,
# 2300/2300 tests and five clean verify layers out of `testing` indefinitely —
# and each pass re-asked a human the identical question through a fresh
# needs-input gate, because a cycle-scoped gate cannot recognise its own
# already-given answer.
#
# The exit from that loop is to let such a finding TRAVEL with the plan, which
# is what it was always characterised as doing. It stays unchecked and visible;
# it just stops deciding the route.
remaining=$(grep '^\- \[ \]' "$findings" 2>/dev/null \
            | grep -cvE "(←|<-)[[:space:]]*(BROAD-SCOPE|MANUAL-TEST)[[:space:]]*$" || true)
if [ "${remaining:-0}" -gt 0 ]; then
  echo "active"
  exit 0
fi

if wf_tagged "$findings" BROAD-SCOPE; then
  echo "wf-findings-route: unchecked BROAD-SCOPE finding(s) present — not routing on them; file each as an independent bug" >&2
fi

if wf_tagged "$findings" MANUAL-TEST; then
  echo "wf-findings-route: unchecked MANUAL-TEST finding(s) present — not routing on them; they travel with the plan and are resolved at the manual gate in 'testing'" >&2
fi

echo "clean"
