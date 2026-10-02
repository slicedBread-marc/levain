#!/usr/bin/env bash
# lv-manual-lint.sh <plan-id-or-name> [--counts] [--file <plan.md>]
#                   [--resolved <file>]
# lv-manual-lint.sh <plan-id-or-name> --live [--file <plan.md>]
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
#   unbuilt        the prerequisite feature does not exist yet (the lv-test
#                  deferral path — see lv-defer-criterion.sh)
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
#   --open     print the criteria the `testing -> complete` guard would refuse
#              on — one per line, tab-separated:
#                <line-no> <TAB> <tag> <TAB> <criterion> <TAB> <near-miss note>
#              exit 1 if any are open, 0 if none. Same parser, same normalizer
#              and the same --resolved set the guard itself uses; with no
#              --resolved it builds one from the plan's test-progress.md
#              exactly as lv-registry-update.sh does.
#
#              THE DIAGNOSTIC HAS TO ANSWER THE QUESTION THE REFUSAL ASKS.
#              lv-registry-update.sh's refusal names `lv-manual-lint.sh <id>`
#              as "which criteria are open" — but the DEFAULT mode lints
#              WORDING (untagged / unknown-tag / assertable) and says nothing
#              about open criteria. client-b WFI-033: the guard refused
#              PLN-011 with "1 eyes:blocking criterion(s) are unchecked",
#              and the lint it pointed at exited 0 with no output, run
#              immediately before and immediately after. The guard was right —
#              a test-progress.md row held a paraphrase of criterion 6 rather
#              than plan.md's wording — and the diagnostic reported clean,
#              which is what made it expensive to find. A near-miss is now
#              reported AS a near-miss rather than as silence.
#
#   --live     print the live Human Test Criteria as ONE numbered flat list —
#              the numbering /lv-test shows and an amendment's `replace …`
#              names — and exit 0. One per line, tab-separated:
#                <flat#> <TAB> <Chrome-Assisted|Manual> <TAB> <n in section>
#                <TAB> <line-no> <TAB> <criterion line as written>
#              Chrome-Assisted first, then Manual, each in plan.md order,
#              after every amendment's retirements (wf_live_criteria).
#
#              THE NUMBERS HAD NO SINGLE SOURCE. lv-test assembled its own
#              flat list by reading the plan, and lv-spec wrote "replace
#              Chrome-Assisted 1" from its own reading of that, where an
#              amendment's replacement sat in the slot of the criterion it
#              replaced. The gate resolves positions in file order, so a
#              client's PLN-028 A-5 retired the 403 check it meant to keep and
#              left A-2's walkthrough live beside A-5's own (LVI-013). Both
#              skills read the list from here now.
#
#   --counts   print eval-safe KEY='value' lines and exit 0:
#                MANUAL_TOTAL, MANUAL_EYES_BLOCKING, MANUAL_EYES_COSMETIC,
#                MANUAL_EXTERNAL, MANUAL_SOAK, MANUAL_UNBUILT, MANUAL_UNTAGGED,
#                MANUAL_OPEN_EYES  (unchecked eyes:* criteria — what gates)
#                MANUAL_OPEN_UNTAGGED (unchecked criteria carrying no eyes:*
#                  tag of their own — overlaps MANUAL_OPEN_BLOCKING for a
#                  pre-v6 plan, where the tag was assumed rather than written)
#                MANUAL_RESOLVED_RECORD (unchecked criteria that --resolved
#                  settled — the gap between the two files, see below)
#
# --resolved <file>
#
#   A file of criterion texts, one per line, that some OTHER record already
#   settled. An unchecked criterion whose text matches one of them counts as
#   resolved: out of every MANUAL_OPEN_* count, and into MANUAL_RESOLVED_RECORD.
#
#   THE TWO FILES DISAGREE BY DESIGN, WHICH IS THE BUG THIS ANSWERS. lv-test
#   records a PASS in test-progress.md and deliberately leaves plan.md's
#   checkbox alone — it only ever ticks a box on a deferral or a cosmetic
#   failure. This parser reads plan.md. So a plan whose criteria had ALL passed
#   still counted them open, and the gate opened every time: client-b' PLN-011
#   recorded 8 of 8 PASS on the current build and was parked for a human
#   anyway, with GATE_REASON naming an eyes:blocking criterion that had in fact
#   been judged and passed twenty minutes earlier (WFI-013).
#
#   Matching is on normalized text — case, backticks, emphasis, the leading
#   tag, collapsed whitespace and trailing punctuation all removed — by the ONE
#   normalizer below, applied to both sides. Equal counts, and so does one
#   containing the other when both are at least 24 characters, because the
#   other record is written by hand and reaches this comparison with the route
#   prefix dropped or a trailing clause summarized. A criterion genuinely
#   paraphrased beyond that does not match and stays open: the failure mode is
#   a gate that opens when it needn't, which is the direction this must fail
#   in.
#
# Codes: untagged | unknown-tag | assertable

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

raw_id=""
mode="lint"
plan_file=""
resolved_file=""

while [ $# -gt 0 ]; do
  case "$1" in
    --counts)   mode="counts"; shift ;;
    --open)     mode="open"; shift ;;
    --live)     mode="live"; shift ;;
    --file)     plan_file="${2:?--file requires a path}"; shift 2 ;;
    --resolved) resolved_file="${2:?--resolved requires a path}"; shift 2 ;;
    -*)         echo "Unknown option: $1" >&2; exit 2 ;;
    *)          raw_id="$1"; shift ;;
  esac
done

if [ -n "$resolved_file" ] && [ ! -f "$resolved_file" ]; then
  echo "Error: --resolved $resolved_file not found" >&2
  exit 2
fi

# --open with no --resolved builds the same set the guard builds. Anything
# else and the two answer different questions again, which is the whole of
# WFI-033.
derived_resolved=""
cleanup_resolved() { [ -n "$derived_resolved" ] && rm -f "$derived_resolved"; return 0; }
trap cleanup_resolved EXIT

if [ -z "$plan_file" ]; then
  plan_id=$(printf '%s' "$raw_id" | grep -oE "($LV_PLN_RE)-[0-9]+" || true)
  [ -n "$plan_id" ] || { echo "Usage: $0 <plan-id-or-name> [--counts] [--file <plan.md>]" >&2; exit 2; }

  ROOT="$(wf_develop_root)"
  REGISTRY="$ROOT/plans/REGISTRY.md"
  [ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 2; }
  slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
  [ -n "$slug" ] || { echo "Error: $plan_id not found in registry" >&2; exit 2; }
  plan_file="$ROOT/plans/${plan_id}-${slug}/plan.md"
fi

[ -f "$plan_file" ] || { echo "Error: $plan_file not found" >&2; exit 2; }

if [ "$mode" = "open" ] && [ -z "$resolved_file" ]; then
  derived_resolved=$(mktemp "${TMPDIR:-/tmp}/wf-manual-open.XXXXXX")
  wf_test_progress_passes "$(dirname "$plan_file")/test-progress.md" > "$derived_resolved" 2>/dev/null || true
  resolved_file="$derived_resolved"
fi

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

if [ "$mode" = "live" ]; then
  wf_live_criteria "$plan_file" | awk '
    /^####[[:space:]]*Chrome-Assisted/ { cs = "Chrome-Assisted"; next }
    /^####[[:space:]]*Manual/          { cs = "Manual"; next }
    /^#+[[:space:]]/                   { cs = ""; next }
    cs != "" && /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (cs == "Chrome-Assisted") { nc++; C[nc] = nc "\t" NR "\t" line }
      else                         { nm++; M[nm] = nm "\t" NR "\t" line }
    }
    END {
      for (i = 1; i <= nc; i++) print i "\tChrome-Assisted\t" C[i]
      for (i = 1; i <= nm; i++) print (nc + i) "\tManual\t" M[i]
    }
  '
  exit 0
fi

# ── A review that was written and cannot be read ──────────────────────────
#
# This lints `#### Manual` criteria, and a review verdict is not one. It is
# checked here anyway because this is the pre-flight every plan passes through
# on its way out of /lv-spec — the last place a malformed section is cheap to
# fix, and the place PLN-209 went through twice, clean, carrying a `## Review`
# that lv-review-status.sh could not read a verdict out of (WFI-207).
#
# The distinction that matters is between EMPTY and UNREADABLE:
#
#   empty      no review has been written yet. Normal for a plan mid-draft, and
#              not this script's business. Silent.
#   unreadable a review WAS written — there is prose in the section — and the
#              parser that decides "has this plan been reviewed" finds no
#              verdict in it. Downstream that is indistinguishable from never
#              having been reviewed, and /lv-attend renders it as a harness
#              fault. Reported as a finding.
#
# Same parser lv-review-status.sh uses, from lv-orch-lib.sh, so there is no
# second opinion for the two to disagree on later.
review_body=$(wf_section_body "$plan_file" "Review")
review_finding=""
if wf_review_has_content "$review_body" && [ -z "$(wf_review_result_lines "$review_body")" ]; then
  review_line=$(grep -nE '^## Review([ \t]|$)' "$plan_file" | head -1 | cut -d: -f1)
  review_finding=$(printf 'F\t%s\tunreadable-review\t## Review\t%s' \
    "${review_line:-0}" \
    'a review is written here but no `Result:` line — lv-review-status.sh reads this plan as never reviewed. Write the verdict as `> **Result:** Approved | Approved with notes | Blocked — <why>` (WFI-207)')
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
  echo "lv-manual-lint: $(basename "$(dirname "$plan_file")") is $schema_said (< 6) — manual criterion tags not required, skipping" >&2
  exit 0
fi

# ── Parse ─────────────────────────────────────────────────────────────────
# Records are emitted prefixed F (finding) or C (count) and split below, so
# both modes share one parser and can never disagree about the same plan.
out=$(awk -v legacy="$legacy" -v resolved="$resolved_file" '
  # One normalizer, applied to both sides of the --resolved comparison, so the
  # two can never drift into disagreeing about what is the same criterion.
  function norm(s,   t) {
    t = tolower(s)
    gsub(/[`*_]/, "", t)
    sub(/^[[:space:]]*\([^)]*\)[[:space:]]*/, "", t)
    gsub(/[[:space:]]+/, " ", t)
    sub(/^ /, "", t); sub(/ $/, "", t)
    sub(/[.,;:]+$/, "", t)
    return t
  }
  # Equal after normalization, or one wholly contains the other and both are
  # long enough for that to mean something. The containment arm is what makes
  # this usable at all: the other record is written by hand, and the criterion
  # text reaches it with the route prefix dropped, or the tag kept, or a
  # trailing clause summarized. MIN_CONTAIN is the whole safety margin, so it
  # is deliberately longer than any criterion fragment that could belong to two
  # different criteria in one plan.
  function settled(nt,   k) {
    if (nt == "") return 0
    if (nt in RESOLVED) return 1
    for (k in RESOLVED) {
      if (length(nt) >= MIN_CONTAIN && length(k) >= MIN_CONTAIN) {
        if (index(k, nt) > 0 || index(nt, k) > 0) return 1
      }
    }
    return 0
  }
  # THE NEAR MISS IS THE EXPENSIVE CASE, SO IT GETS ITS OWN ANSWER.
  #
  # settled() is deliberately strict: it must fail toward "still open", because
  # a paraphrase that matched would dismiss a criterion nobody judged. The cost
  # of that strictness is silence — a row IS there for this criterion, worded
  # by another hand, and nothing said so. client-b WFI-033 spent a whole
  # diagnosis on exactly that gap.
  #
  # So: word overlap, reported and never acted on. It cannot settle anything;
  # it only names the row that was probably meant.
  function nearest(nt,   k, n, i, w, shared, best, bestk, score) {
    if (nt == "") return ""
    n = split(nt, W, " ")
    if (n < 3) return ""
    for (i = 1; i <= n; i++) WANT[W[i]] = 1
    best = 0; bestk = ""
    for (k in RESOLVED) {
      shared = 0
      split(k, K, " ")
      for (i in K) if (K[i] in WANT) shared++
      score = shared / n
      if (score > best) { best = score; bestk = k }
    }
    for (i in WANT) delete WANT[i]
    if (best >= 0.4 && bestk != "") {
      return sprintf("test-progress.md has a row %d%% matching this text but not matching it: \"%s\" — restore plan.md\047s exact wording", int(best * 100), (bestk in RAW ? RAW[bestk] : bestk))
    }
    return ""
  }
  # One line per still-open criterion, carrying the near-miss when there is
  # one. Emitted unconditionally and filtered by the caller, so --open and
  # --counts can never disagree about which criteria are open: they are two
  # renderings of the same pass.
  function report_open(nr, tagname, txt,   miss) {
    miss = nearest(norm(txt))
    printf "O\t%d\t%s\t%s\t%s\n", nr, tagname, txt, miss
  }
  BEGIN {
    MIN_CONTAIN = 24
    if (resolved != "") {
      while ((getline rline < resolved) > 0) {
        rn = norm(rline)
        if (rn != "") { RESOLVED[rn] = 1; RAW[rn] = rline }
      }
      close(resolved)
    }
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

    # An unchecked criterion the other record already settled is not open. It
    # is still counted in the total for its tag — it exists, it was written,
    # and the lint still grades its wording. Only the OPEN counts change,
    # because
    # those are the ones that answer "is a human needed now".
    if (!checked && settled(norm(text))) {
      checked = 1
      resolved_record++
    }

    if (tag == "") {
      # Pre-v6 plan: no tags were ever required, so read it the v5 way.
      # open_untagged is counted in BOTH paths and overlaps open_blocking on
      # purpose: it is a diagnostic, not a share of the total. It answers one
      # question the other counts cannot — "was this criterion ever judged to
      # need EYES, or did a compatibility rule say so on its behalf?" — and the
      # manual gate needs that to decide whether a rendering-surface miss is
      # evidence of anything. See lv-manual-gate.sh (WFI-054).
      if (legacy) { eyes_blocking++; if (!checked) { open_eyes++; open_blocking++; open_untagged++; report_open(NR, "untagged/v5", text) } ; next }
      printf "F\t%d\tuntagged\t%s\t%s\n", NR, text, "no reason tag — add (eyes:blocking), (eyes:cosmetic), (external), (soak) or (unbuilt), or move it to the Tests table"
      untagged++
      if (!checked) open_untagged++
      next
    }

    if (lower_tag == "eyes:blocking")      { eyes_blocking++; if (!checked) { open_eyes++; open_blocking++; report_open(NR, lower_tag, text) } }
    else if (lower_tag == "eyes:cosmetic") { eyes_cosmetic++; if (!checked) { open_eyes++; open_cosmetic++; report_open(NR, lower_tag, text) } }
    else if (lower_tag == "external")      { external++ }
    else if (lower_tag == "soak")          { soak++ }
    # Written by lv-defer-criterion.sh when the prerequisite feature does not
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
    printf "C\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n", \
      total + 0, eyes_blocking + 0, eyes_cosmetic + 0, external + 0, soak + 0, untagged + 0, \
      open_eyes + 0, open_blocking + 0, open_cosmetic + 0, unbuilt + 0, open_untagged + 0, \
      resolved_record + 0
  }
' <(wf_live_criteria "$plan_file"))

counts=$(printf '%s\n' "$out" | grep '^C	' | tail -1)
findings=$(printf '%s\n' "$out" | grep '^F	' || true)
opens=$(printf '%s\n' "$out" | grep '^O	' || true)

if [ "$mode" = "open" ]; then
  # eyes:* only — the guard refuses on MANUAL_OPEN_BLOCKING, and an (external)
  # or (soak) criterion is not something a human can close at this gate.
  if [ -z "$opens" ]; then
    echo "lv-manual-lint: no open eyes:* criteria in $(basename "$(dirname "$plan_file")")" >&2
    exit 0
  fi
  printf '%s\n' "$opens" | cut -f2-
  exit 1
fi

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
  wf_emit MANUAL_RESOLVED_RECORD "$(printf '%s' "$counts" | cut -f13)"
  wf_emit MANUAL_SCHEMA        "${schema:-0}"
  exit 0
fi

[ -n "$findings" ] || exit 0
printf '%s\n' "$findings" | cut -f2-
exit 1
