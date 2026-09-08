#!/usr/bin/env bash
# wf-manual-lint.sh <plan-id-or-name> [--counts] [--file <plan.md>]
#
# Lints the `#### Manual` criteria in a plan's Verification Checklist.
#
# Every manual criterion must declare WHY a machine cannot check it, using
# exactly one tag, written first on the line:
#
#   #### Manual
#   - [ ] (eyes:blocking)  /app/time — the timer is usable one-handed on a phone
#   - [ ] (eyes:cosmetic)  /app/board — column spacing is even at 1280px
#   - [ ] (external)       tool ticket pull <id> — every image appears in the DevOps UI
#   - [ ] (soak)           tool work — the Stalled section surfaces something forgotten
#   - [ ] (unbuilt)        the export button — the screen it lives on ships in PLN-112
#
#   eyes:blocking  subjective judgment; failing it blocks the merge
#   eyes:cosmetic  subjective judgment; failing it files a bug and ships
#   external       needs a real third-party system, real credentials, or a physical act
#   soak           needs real elapsed calendar time
#   unbuilt        the prerequisite feature does not exist yet (the wf-test
#                  deferral path — see wf-defer-criterion.sh)
#
# Anything that fits none of the five is misclassified and belongs in the Tests
# table. `#### Manual` used to have no cost and no schema — writing a criterion
# there was strictly easier than writing a real test, so planners drifted into
# it under time pressure and shipped assertions (including security assertions)
# as one-shot human checks. Guidance lost to gradient; this makes it a gate.
#
# Modes:
#   (default)  print one finding per line, tab-separated:
#                <line-no> <TAB> <code> <TAB> <criterion> <TAB> <message>
#              exit 1 if any findings, 0 if clean.
#   --counts   print eval-safe KEY='value' lines and exit 0:
#                MANUAL_TOTAL, MANUAL_EYES_BLOCKING, MANUAL_EYES_COSMETIC,
#                MANUAL_EXTERNAL, MANUAL_SOAK, MANUAL_UNBUILT, MANUAL_UNTAGGED,
#                MANUAL_OPEN_EYES  (unchecked eyes:* criteria — what gates)
#                MANUAL_OPEN_UNTAGGED (unchecked criteria carrying no eyes:*
#                  tag of their own — overlaps MANUAL_OPEN_BLOCKING for a
#                  pre-v6 plan, where the tag was assumed rather than written)
#
# Codes: untagged | unknown-tag | assertable

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

raw_id=""
mode="lint"
plan_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --counts) mode="counts"; shift ;;
    --file)   plan_file="${2:?--file requires a path}"; shift 2 ;;
    -*)       echo "Unknown option: $1" >&2; exit 2 ;;
    *)        raw_id="$1"; shift ;;
  esac
done

if [ -z "$plan_file" ]; then
  plan_id=$(printf '%s' "$raw_id" | grep -oE 'PLN-[0-9]+' || true)
  [ -n "$plan_id" ] || { echo "Usage: $0 <plan-id-or-name> [--counts] [--file <plan.md>]" >&2; exit 2; }

  ROOT="$(wf_develop_root)"
  REGISTRY="$ROOT/plans/REGISTRY.md"
  [ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 2; }
  slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
  [ -n "$slug" ] || { echo "Error: $plan_id not found in registry" >&2; exit 2; }
  plan_file="$ROOT/plans/${plan_id}-${slug}/plan.md"
fi

[ -f "$plan_file" ] || { echo "Error: $plan_file not found" >&2; exit 2; }

# ── Is it text at all? ────────────────────────────────────────────────────
#
# Every check below is a grep or an awk over this file, and both stop matching
# entirely on a file that contains a NUL byte — grep classifies it as binary
# data and reports nothing rather than failing.
#
# So one stray NUL turned the whole lint into a pass. client-a's PLN-077 had
# exactly one, the schema probe below matched nothing, `|| echo 0` read that as
# "schema_version 0", and the plan was skipped as pre-v6 with exit 0 (WFI-150).
# A plan that could not be parsed at all therefore received LESS checking than a
# normal one, silently, and the exit code said it passed.
#
# "I could not read it" and "I read it and it is fine" must never wear the same
# exit code. tr, unlike grep and awk, is defined on arbitrary bytes.
if [ "$(LC_ALL=C tr -dc '\000' < "$plan_file" | wc -c | tr -d ' ')" != "0" ]; then
  # Same trick to locate it: map NUL to a byte grep will match, then count lines.
  nul_line=$(LC_ALL=C tr '\000' '\001' < "$plan_file" | grep -n "$(printf '\001')" | head -1 | cut -d: -f1)
  echo "Error: $plan_file contains a NUL byte (line ${nul_line:-?}) — it is not text." >&2
  echo "       grep and awk silently match nothing in a file like this, so no lint can be trusted on it." >&2
  echo "       Strip it first, then re-run:" >&2
  echo "         LC_ALL=C tr -d '\\000' < \"$plan_file\" > \"$plan_file.clean\" && mv \"$plan_file.clean\" \"$plan_file\"" >&2
  exit 2
fi

if ! grep -q . "$plan_file" 2>/dev/null; then
  echo "Error: $plan_file has no readable text — refusing to report a lint verdict on it." >&2
  exit 2
fi

# ── A review that was written and cannot be read ──────────────────────────
#
# This lints `#### Manual` criteria, and a review verdict is not one. It is
# checked here anyway because this is the pre-flight every plan passes through
# on its way out of /wf-spec — the last place a malformed section is cheap to
# fix, and the place PLN-209 went through twice, clean, carrying a `## Review`
# that wf-review-status.sh could not read a verdict out of (WFI-207).
#
# The distinction that matters is between EMPTY and UNREADABLE:
#
#   empty      no review has been written yet. Normal for a plan mid-draft, and
#              not this script's business. Silent.
#   unreadable a review WAS written — there is prose in the section — and the
#              parser that decides "has this plan been reviewed" finds no
#              verdict in it. Downstream that is indistinguishable from never
#              having been reviewed, and /wf-attend renders it as a harness
#              fault. Reported as a finding.
#
# Same parser wf-review-status.sh uses, from wf-orch-lib.sh, so there is no
# second opinion for the two to disagree on later.
review_body=$(wf_section_body "$plan_file" "Review")
review_finding=""
if wf_review_has_content "$review_body" && [ -z "$(wf_review_result_lines "$review_body")" ]; then
  review_line=$(grep -nE '^## Review([ \t]|$)' "$plan_file" | head -1 | cut -d: -f1)
  review_finding=$(printf 'F\t%s\tunreadable-review\t## Review\t%s' \
    "${review_line:-0}" \
    'a review is written here but no `Result:` line — wf-review-status.sh reads this plan as never reviewed. Write the verdict as `> **Result:** Approved | Approved with notes | Blocked — <why>` (WFI-207)')
fi

# ── Schema guard ──────────────────────────────────────────────────────────
# Tags arrived in schema v6. A v5 plan already in flight has none, and failing
# it back to `draft` mid-pipeline would punish plans for being early rather
# than for being wrong. So: v5 plans are never linted, and for counting they
# fall back to v5 semantics — every unchecked manual criterion is treated as
# eyes:blocking, which is exactly what "any Manual criterion gates" meant.
schema=$(grep -m1 -oE 'schema_version:\*{0,2}[[:space:]]*[0-9]+' "$plan_file" 2>/dev/null | grep -oE '[0-9]+$' || true)
# Absent and zero are different facts, and the skip message said "0" for both —
# which is what made WFI-150's unparseable plan look like an ordinary old one.
schema_said="${schema:-no schema_version line}"
[ -n "$schema" ] || schema=0
legacy=0
[ "$schema" -lt 6 ] && legacy=1

if [ "$mode" = "lint" ] && [ "$legacy" = "1" ]; then
  echo "wf-manual-lint: $(basename "$(dirname "$plan_file")") is $schema_said (< 6) — manual criterion tags not required, skipping" >&2
  exit 0
fi

# ── Parse ─────────────────────────────────────────────────────────────────
# Records are emitted prefixed F (finding) or C (count) and split below, so
# both modes share one parser and can never disagree about the same plan.
out=$(awk -v legacy="$legacy" '
  BEGIN {
    # Patterns are lowercase and applied to tolower(text): IGNORECASE is a GNU
    # awk extension and this has to run on the BSD awk macOS ships.
    # Verbs whose outcome a machine can decide. Deliberately narrow — a false
    # positive here costs a planner an edit, so it must earn its place.
    assertable = "(is refused|is rejected|refuses|is accepted|returns|responds with|contains|exists|is present|is absent|is empty|stops for|blocks on|prints|logs|matches|resolves|redirects|exits|parses|equals|no ansi|status code)"
    # Words that mark a genuine judgment call. Their presence vetoes the
    # assertable heuristic — "reads clearly and contains all five columns" is
    # a human question wearing an assertable verb.
    subjective = "(reads|feels|looks|legible|readable|natural|usable|ergonom|smooth|polish|at a glance|intuitive|clutter|aesthetic|pleasant|comfortable|obvious|confusing)"
  }
  /^####[[:space:]]*Manual/ { in_manual = 1; next }
  /^(#|##|###|####)[[:space:]]/ { if (in_manual && $0 !~ /^####[[:space:]]*Manual/) in_manual = 0 }
  !in_manual { next }
  /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ {
    total++
    line = $0
    checked = (line ~ /\[[xX]\]/)

    body = line
    sub(/^[[:space:]]*-[[:space:]]*\[[ xX]\][[:space:]]*/, "", body)

    tag = ""
    if (body ~ /^\(/) {
      tag = body
      sub(/^\(/, "", tag)
      sub(/\).*$/, "", tag)
      gsub(/[[:space:]]/, "", tag)
      text = body
      sub(/^\([^)]*\)[[:space:]]*/, "", text)
    } else {
      text = body
    }
    lower_tag = tolower(tag)

    if (tag == "") {
      # Pre-v6 plan: no tags were ever required, so read it the v5 way.
      # open_untagged is counted in BOTH paths and overlaps open_blocking on
      # purpose: it is a diagnostic, not a share of the total. It answers one
      # question the other counts cannot — "was this criterion ever judged to
      # need EYES, or did a compatibility rule say so on its behalf?" — and the
      # manual gate needs that to decide whether a rendering-surface miss is
      # evidence of anything. See wf-manual-gate.sh (WFI-054).
      if (legacy) { eyes_blocking++; if (!checked) { open_eyes++; open_blocking++; open_untagged++ } ; next }
      printf "F\t%d\tuntagged\t%s\t%s\n", NR, text, "no reason tag — add (eyes:blocking), (eyes:cosmetic), (external), (soak) or (unbuilt), or move it to the Tests table"
      untagged++
      if (!checked) open_untagged++
      next
    }

    if (lower_tag == "eyes:blocking")      { eyes_blocking++; if (!checked) { open_eyes++; open_blocking++ } }
    else if (lower_tag == "eyes:cosmetic") { eyes_cosmetic++; if (!checked) { open_eyes++; open_cosmetic++ } }
    else if (lower_tag == "external")      { external++ }
    else if (lower_tag == "soak")          { soak++ }
    # Written by wf-defer-criterion.sh when the prerequisite feature does not
    # exist yet. Deferring the documented way has to produce a plan that lints.
    else if (lower_tag == "unbuilt")       { unbuilt++ }
    else {
      untagged++
      msg = "unknown tag (" tag ")"
      if (lower_tag == "eyes") msg = msg " — pick a disposition: eyes:blocking or eyes:cosmetic"
      else msg = msg " — legal tags: eyes:blocking, eyes:cosmetic, external, soak, unbuilt"
      printf "F\t%d\tunknown-tag\t%s\t%s\n", NR, text, msg
      next
    }

    # Verb heuristic. Only eyes:* is graded — an (external) or (soak) criterion
    # may legitimately read as assertable and still be unrunnable at gate time.
    ltext = tolower(text)
    if (lower_tag ~ /^eyes:/ && ltext ~ assertable && ltext !~ subjective) {
      printf "F\t%d\tassertable\t%s\t%s\n", NR, text, "mechanically assertable — belongs in the Tests table, not behind a human gate"
    }
  }
  END {
    printf "C\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
      total + 0, eyes_blocking + 0, eyes_cosmetic + 0, external + 0, soak + 0, untagged + 0, \
      open_eyes + 0, open_blocking + 0, open_cosmetic + 0, unbuilt + 0, open_untagged + 0
  }
' "$plan_file")

counts=$(printf '%s\n' "$out" | grep '^C	' | tail -1)
findings=$(printf '%s\n' "$out" | grep '^F	' || true)

# The review finding is not a Manual-criterion finding, so it plays no part in
# --counts; it only ever affects the lint verdict.
if [ -n "$review_finding" ]; then
  findings=$(printf '%s%s%s' "$findings" "${findings:+$'\n'}" "$review_finding")
fi

if [ "$mode" = "counts" ]; then
  wf_emit MANUAL_TOTAL         "$(printf '%s' "$counts" | cut -f2)"
  wf_emit MANUAL_EYES_BLOCKING "$(printf '%s' "$counts" | cut -f3)"
  wf_emit MANUAL_EYES_COSMETIC "$(printf '%s' "$counts" | cut -f4)"
  wf_emit MANUAL_EXTERNAL      "$(printf '%s' "$counts" | cut -f5)"
  wf_emit MANUAL_SOAK          "$(printf '%s' "$counts" | cut -f6)"
  wf_emit MANUAL_UNBUILT       "$(printf '%s' "$counts" | cut -f11)"
  wf_emit MANUAL_UNTAGGED      "$(printf '%s' "$counts" | cut -f7)"
  wf_emit MANUAL_OPEN_EYES     "$(printf '%s' "$counts" | cut -f8)"
  wf_emit MANUAL_OPEN_BLOCKING "$(printf '%s' "$counts" | cut -f9)"
  wf_emit MANUAL_OPEN_COSMETIC "$(printf '%s' "$counts" | cut -f10)"
  wf_emit MANUAL_OPEN_UNTAGGED "$(printf '%s' "$counts" | cut -f12)"
  wf_emit MANUAL_SCHEMA        "${schema:-0}"
  exit 0
fi

[ -n "$findings" ] || exit 0
printf '%s\n' "$findings" | cut -f2-
exit 1
