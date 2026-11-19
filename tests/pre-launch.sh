#!/usr/bin/env bash
# pre-launch.sh — a client's LVI-034: a pre-launch project does not stop for
# questions a worker can answer; a human checks the end state instead.
#
#   1. needs-input with --recommend is answered on the spot: no gate stays
#      open, the ledger and events.log record it as self-answered, and the
#      next open of the same question sees it as the prior answer.
#   2. --floor, an attended missing --recommend, and a non-question gate (stuck)
#      still park for a human (unattended, a missing one is refused, LVI-046); the recommendation is kept on the open gate.
#   3. spec-approval self-answers as an approve the next worker can act on.
#   4. The daily cap: past projectProfile.selfAnswerMaxPerDay the gate parks.
#   5. lv-gate-close.sh --basis pre-launch is checked, not believed (and inferred
#      when absent, never past a --floor, LVI-048): refused
#      unattended on a governed project and on a gate outside the set.
#   6. manual-test: lv-manual-gate.sh answers GATE=false with PRELAUNCH=true
#      on an eyes:blocking plan with no lane; lv-lane.sh answer moves it to the
#      post-ship checklist saying pre-launch; the completion guard passes.
#   7. lv-end-state.sh lists the decisions and the checklist.
#   8. Governed, or pre-launch past live_from: everything gates as before.
#
# Usage: ./tests/pre-launch.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO_ROOT/scripts/v2.00"
TEST_DIR=""
PASS=0
FAIL=0

cleanup() { [ -z "${KEEP:-}" ] && [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
assert_has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "no [$2] in: $(printf '%s' "$3" | head -c 400)"; fi; }
assert_not() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1" "unexpected [$2]"; else ok "$1"; fi; }

TEST_DIR=$(mktemp -d)
CLIENT="$TEST_DIR/client"
G=".claude/orchestrator/gates"

plan() {   # plan <id> <slug>
  mkdir -p "plans/$1-$2"
  cat > "plans/$1-$2/plan.md" <<P
# $2

> **ID:** $1
> **schema_version:** 6

## Goal
Show the label.

## Steps

### Step 1: Label
- **Files:** modify \`src/app.txt\`
- **What:** the label.
- **Acceptance:** it shows.

## Verification Checklist

### Human Test Criteria

#### Manual
- [ ] (eyes:blocking) /print — the label reads naturally next to the preview

## Review
> **Result:** Approved
P
  printf '| %s | %s | %s | — | — | 2026-10-27 | 15.16.0 | — | — |\n' "$1" "$2" "${3:-draft}" >> plans/REGISTRY.md.rows
}

new_client() {   # new_client <profile yaml lines>
  rm -rf "$CLIENT"
  git init -q -b develop "$CLIENT"
  cd "$CLIENT" || exit 1
  git config user.email t@t; git config user.name "Op Erator"
  { printf 'project_slug: "prelaunch-test"\n'; printf '%b' "${1:-}"; } > levain.yml
  mkdir -p plans .claude/orchestrator src
  printf 'x\n' > src/app.txt
  printf '.claude/orchestrator/\n' > .gitignore
  : > plans/REGISTRY.md.rows
  plan PLN-001 alpha draft
  plan PLN-002 beta testing
  {
    printf '# Plan Registry\n\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n'
    cat plans/REGISTRY.md.rows
    printf '\n<!-- Counter: 2 -->\n'
  } > plans/REGISTRY.md
  rm plans/REGISTRY.md.rows
  git add -A; git commit -qm init
}

PRE='projectProfile:\n  tier: pre-launch\n'

echo "pre-launch.sh"
echo "============="

# ── 1. needs-input answered by its recommendation ──────────────────────────
echo ""
echo "1. needs-input with --recommend is answered on the spot"
new_client "$PRE"
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Which label wording, (a) Print or (b) Print sheet?" \
  --recommend "(b) Print sheet — matches the brief" 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_has "…says it was answered by its recommendation" "answered by its recommendation (pre-launch)" "$out"
assert_eq "no gate is left open" "" "$(ls $G/*.gate 2>/dev/null)"
assert_has "the ledger records it as self-answered" "self-answered (pre-launch): (b) Print sheet" "$(cat $G/resolved/PLN-001.needs-input.log)"
assert_has "the slot says who answered" "pre-launch" "$(cat $G/resolved/PLN-001.needs-input)"
assert_has "events.log has gate-self-answered" "gate-self-answered	PLN-001	needs-input: (b) Print sheet" "$(cat .claude/orchestrator/events.log)"
assert_has "findings.md carries the decision for the next worker" "(b) Print sheet" "$(cat plans/PLN-001-alpha/findings.md 2>/dev/null)"

# ── 2. What still parks ────────────────────────────────────────────────────
echo ""
echo "2. --floor, no --recommend, and a circuit breaker still park"
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Spend \$40 on a calibration run?" \
  --recommend "yes" --floor "spends money" 2>&1); rc=$?
assert_eq "--floor: exit 0" 0 "$rc"
assert_has "…the gate stays open" "needs-input" "$(cat $G/PLN-001.gate 2>/dev/null)"
assert_has "…carrying the recommendation for the human" "GATE_RECOMMENDED='yes'" "$(cat $G/PLN-001.gate)"
assert_has "…and the floor" "GATE_FLOOR='spends money'" "$(cat $G/PLN-001.gate)"
"$S/lv-gate-close.sh" PLN-001 "no" --only needs-input >/dev/null 2>&1
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Which colour?" 2>&1); rc=$?
assert_eq "unattended, no --recommend: refused (exit 8)" 8 "$rc"
assert_has "…naming the flag to add" "--recommend" "$out"
assert_eq "…and no gate is written" false "$([ -f $G/PLN-001.gate ] && echo true || echo false)"
out=$("$S/lv-gate-open.sh" PLN-001 needs-input "Which colour?" 2>&1)
assert_has "attended, no --recommend: parked, saying why" "none was given" "$out"
assert_eq "…the gate is open" true "$([ -f $G/PLN-001.gate ] && echo true || echo false)"
"$S/lv-gate-close.sh" PLN-001 "blue" --only needs-input >/dev/null 2>&1
LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 stuck "attempt budget spent" --recommend "retry" >/dev/null 2>&1
assert_eq "stuck is never self-answered" true "$([ -f $G/PLN-001.gate ] && echo true || echo false)"
"$S/lv-gate-close.sh" PLN-001 "reset" --only stuck >/dev/null 2>&1

# ── 3. spec-approval ───────────────────────────────────────────────────────
echo ""
echo "3. spec-approval self-answers as an approve"
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 spec-approval "Approve PLN-001? Review: Approved, 0 Critical" \
  --recommend "approve — review Approved, nothing open" 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "no gate is left open" "" "$(ls $G/*.gate 2>/dev/null)"
eval "$("$S/lv-gate-status.sh" PLN-001 spec-approval 2>/dev/null)"
assert_eq "lv-gate-status reports it answered" true "${GATE_ANSWERED:-}"
assert_eq "…as an approve" approve "${GATE_DECISION:-}"

# ── 4. The cap ─────────────────────────────────────────────────────────────
echo ""
echo "4. The daily cap"
printf '  selfAnswerMaxPerDay: 2\n' >> levain.yml
for i in 1 2; do
  LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-002 needs-input "Question $i?" --recommend "answer $i" >/dev/null 2>&1
done
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-002 needs-input "Question 3?" --recommend "answer 3" 2>&1)
assert_has "the third today parks" "self-answered 2 times today" "$out"
assert_eq "…with a gate open" true "$([ -f $G/PLN-002.gate ] && echo true || echo false)"
assert_has "…and an event saying so" "self-answer-capped	PLN-002" "$(cat .claude/orchestrator/events.log)"
"$S/lv-gate-close.sh" PLN-002 "ok" --only needs-input >/dev/null 2>&1

# A client's LVI-029: the same question, in the same words, already answered.
out=$("$S/lv-gate-open.sh" PLN-002 needs-input "question  3?" 2>&1); rc=$?
assert_eq "an answered question asked again in the same words is refused (exit 3)" 3 "$rc"
assert_has "…naming the answer of record" "resolution:" "$out"
assert_eq "…with no gate open" false "$([ -f $G/PLN-002.gate ] && echo true || echo false)"

# ── 5. --basis pre-launch is checked ───────────────────────────────────────
echo ""
echo "5. --basis pre-launch is checked, not believed"
"$S/lv-gate-open.sh" PLN-001 merge-failed "PR would not merge" >/dev/null 2>&1
out=$(LV_UNATTENDED=1 "$S/lv-gate-close.sh" PLN-001 "retried" --only merge-failed --basis pre-launch 2>&1); rc=$?
assert_eq "a gate outside the set is refused (exit 4)" 4 "$rc"
"$S/lv-gate-close.sh" PLN-001 "fixed" --only merge-failed >/dev/null 2>&1
# A client's LVI-048: a worker self-closing its own needs-input without
# --basis was refused, and the gate parked for a human. Inferred now, where
# --basis pre-launch would pass, and never past a --floor.
"$S/lv-gate-open.sh" PLN-001 needs-input "Which colour?" >/dev/null 2>&1
out=$(LV_UNATTENDED=1 "$S/lv-gate-close.sh" PLN-001 "blue" --only needs-input 2>&1); rc=$?
assert_eq "no --basis on a self-answerable gate: closed as pre-launch" 0 "$rc"
assert_eq "…the gate is gone" false "$([ -f $G/PLN-001.gate ] && echo true || echo false)"
"$S/lv-gate-open.sh" PLN-001 merge-failed "PR #9 would not merge either" >/dev/null 2>&1
out=$(LV_UNATTENDED=1 "$S/lv-gate-close.sh" PLN-001 "retried" --only merge-failed 2>&1); rc=$?
assert_eq "no --basis outside the set: still refused (exit 4)" 4 "$rc"
"$S/lv-gate-close.sh" PLN-001 "fixed" --only merge-failed >/dev/null 2>&1
LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Spend \$40?" --recommend "yes" --floor "spends money" >/dev/null 2>&1
out=$(LV_UNATTENDED=1 "$S/lv-gate-close.sh" PLN-001 "yes" --only needs-input 2>&1); rc=$?
assert_eq "a floored gate, no --basis: refused (exit 4)" 4 "$rc"
out=$(LV_UNATTENDED=1 "$S/lv-gate-close.sh" PLN-001 "yes" --only needs-input --basis pre-launch 2>&1); rc=$?
assert_eq "a floored gate, --basis pre-launch: refused (exit 4)" 4 "$rc"
assert_has "…saying it was held for a human" "held for a human" "$out"
"$S/lv-gate-close.sh" PLN-001 "no" --only needs-input >/dev/null 2>&1

# ── 6. manual-test ─────────────────────────────────────────────────────────
echo ""
echo "6. manual-test goes to the end state"
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "lv-manual-gate does not gate an eyes:blocking plan" false "$GATE"
assert_eq "…saying pre-launch" true "$PRELAUNCH"
assert_eq "…on a plan with no lane" none "$LANE"
# A client's LVI-036: Chrome-Assisted criteria nobody ran stayed unchecked and
# off the checklist. One here has a PASS on record and must stay put.
python3 - plans/PLN-002-beta/plan.md <<'PY2'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("#### Manual\n", "#### Chrome-Assisted\n- [ ] /print — the preview shows the label beside the sheet title\n- [ ] /print — the download button saves a PDF of the sheet\n\n#### Manual\n", 1)
open(p,"w").write(s)
PY2
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n| 1 | /print — the preview shows the label beside the sheet title | abc1234 | PASS | headless eval |\n' > plans/PLN-002-beta/test-progress.md
git add -A && git commit -qm "chrome criteria"
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1); rc=$?
assert_eq "lv-lane.sh answer: exit 0" 0 "$rc"
assert_has "the criterion is ticked in place" "- [x] (eyes:blocking) /print" "$(cat plans/PLN-002-beta/plan.md)"
assert_has "…listed on the post-ship checklist as pre-launch" "shipped without eyes by pre-launch (end-state review)" "$(cat plans/PLN-002-beta/plan.md)"
assert_has "an untested Chrome-Assisted criterion goes to the checklist too" "- [ ] /print — the download button saves a PDF of the sheet _(chrome-assisted" "$(cat plans/PLN-002-beta/plan.md)"
assert_has "…ticked in place" "- [x] /print — the download button" "$(cat plans/PLN-002-beta/plan.md)"
assert_not "one with a PASS on record does not" "- [ ] /print — the preview shows the label beside the sheet title _(" "$(cat plans/PLN-002-beta/plan.md)"
# The coordinator's LVI-044: a failed layout audit is a FAIL on the build,
# though it is not a criterion row.
cp plans/PLN-002-beta/test-progress.md "$TEST_DIR/tp.keep"
printf 'LAYOUT_RESULT /print=fail — FAIL layout 390x844 1280x800: 1 problem(s) — target 1\n' >> plans/PLN-002-beta/test-progress.md
out=$("$S/lv-registry-update.sh" PLN-002 testing complete - 2>&1); rc=$?
assert_eq "a LAYOUT_RESULT fail line refuses completion" 1 "$rc"
assert_has "…quoting it" "LAYOUT_RESULT /print=fail" "$out"
cp "$TEST_DIR/tp.keep" plans/PLN-002-beta/test-progress.md
# LVI-042: the app as configured logged that it served no data.
printf 'STARTUP_RESULT=fail — warn: Bank: missing, serving no items (passed only with Bank__Path overridden)\n' >> plans/PLN-002-beta/test-progress.md
out=$("$S/lv-registry-update.sh" PLN-002 testing complete - 2>&1); rc=$?
assert_eq "a STARTUP_RESULT=fail line refuses completion" 1 "$rc"
assert_has "…quoting it" "STARTUP_RESULT=fail" "$out"
cp "$TEST_DIR/tp.keep" plans/PLN-002-beta/test-progress.md
printf 'STARTUP_RESULT=warn — 1 line, judged benign: no XML encryptor configured\n' >> plans/PLN-002-beta/test-progress.md
printf 'LAYOUT_RESULT /print=pass — PASS layout 390x844 1280x800\n' >> plans/PLN-002-beta/test-progress.md
assert_eq "the completion guard lets it complete" 0 \
  "$("$S/lv-registry-update.sh" PLN-002 testing complete - >/dev/null 2>&1; echo $?)"

# ── 7. lv-end-state.sh ─────────────────────────────────────────────────────
echo ""
echo "7. lv-end-state.sh lists what the human owes"
out=$("$S/lv-end-state.sh" --count)
assert_eq "counts" "DECISIONS=4 CHECKLIST=2 DEFERRED=0" "$out"
out=$("$S/lv-end-state.sh")
assert_has "the needs-input decision" "(b) Print sheet" "$out"
assert_has "the spec-approval decision" "approve — review Approved" "$out"
assert_has "the checklist item, under its plan" "PLN-002-beta" "$out"

# A client's LVI-052: Manual all PASS and one Chrome-Assisted criterion untested
# with a recorded reason. PRELAUNCH was set only by the Manual branch, so the
# Chrome one alone opened a human gate.
new_client "$PRE"
python3 - plans/PLN-002-beta/plan.md <<'PY3'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("- [ ] (eyes:blocking)", "- [x] (eyes:blocking)", 1)
s=s.replace("#### Manual\n", "#### Chrome-Assisted\n- [ ] /print — the label stays on one line at a phone width\n\n#### Manual\n", 1)
open(p,"w").write(s)
PY3
git add -A && git commit -qm "chrome only"
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n| 1 | /print — the label stays on one line at a phone width | %s | — | ambiguous headless screenshot at 390px |\n' "$(git rev-parse --short HEAD)" > plans/PLN-002-beta/test-progress.md
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "an untested Chrome criterion alone: CHROME_UNTESTED=1" 1 "$CHROME_UNTESTED"
assert_eq "…does not gate a pre-launch plan" false "$GATE"
assert_eq "…saying pre-launch" true "$PRELAUNCH"
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n' > plans/PLN-002-beta/test-progress.md
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "one with no result at all is still the tester's work, and gates" true "$GATE"

# LVI-043 from the coordinator: a criterion whose only result was a headless
# ERROR (the sign-in form submit did not navigate) went to the post-ship
# checklist as "untested" and shipped. An ERROR is no result.
sha=$(git rev-parse --short HEAD)
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n| 1 | /print — the label stays on one line at a phone width | %s | — | ERROR browser form submit did not navigate headlessly (page stayed on /signin) |\n' "$sha" > plans/PLN-002-beta/test-progress.md
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "an ERROR-only Chrome criterion: CHROME_ERRORED=1" 1 "$CHROME_ERRORED"
assert_eq "…gates a pre-launch plan" true "$GATE"
assert_has "…saying an ERROR is no result" "only a headless ERROR, which is no result" "$GATE_REASON"
git add -A && git commit -qm "errored row"
before=$(cat plans/PLN-002-beta/plan.md)
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1); rc=$?
assert_eq "lv-lane.sh answer refuses it (exit 4)" 4 "$rc"
assert_has "…naming the criterion" "the label stays on one line at a phone width" "$out"
assert_eq "…and moves nothing" "$before" "$(cat plans/PLN-002-beta/plan.md)"
# A client's LVI-023: the operator chose one walkthrough at the end over
# per-plan checks. With projectProfile.headlessError: end-state, the same
# ERROR goes to the end-state review, listed as never run, not as tested.
printf 'projectProfile:\n  tier: pre-launch\n  headlessError: end-state\n' > levain.yml
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "headlessError: end-state: the ERROR still counts" 1 "$CHROME_ERRORED"
assert_eq "…but does not gate" false "$GATE"
assert_eq "…saying pre-launch" true "$PRELAUNCH"
assert_has "…and that it goes as never run" "go to the end-state review as never run" "$GATE_REASON"
git add -A && git commit -qm "end-state knob"
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1); rc=$?
assert_eq "…lv-lane.sh answer: exit 0" 0 "$rc"
assert_has "…lists it on the checklist as never run" "- [ ] /print — the label stays on one line at a phone width _(chrome-assisted, headless ERROR — never ran" "$(cat plans/PLN-002-beta/plan.md)"
git checkout -q HEAD~1 -- plans/PLN-002-beta/plan.md levain.yml 2>/dev/null; git commit -qam "back" 2>/dev/null
printf 'projectProfile:\n  tier: governed\n  headlessError: end-state\n' > levain.yml
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "headlessError: end-state on a governed project still gates" true "$GATE"
printf '%b' "projectProfile:\n  tier: pre-launch\n" > levain.yml
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n| 1 | /print — the label stays on one line at a phone width | %s | — | needs: device — ERROR on the emulated touch path; a real phone is required |\n' "$sha" > plans/PLN-002-beta/test-progress.md
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "an ERROR beside a needs: reason is a reason, not a bare ERROR" 0 "$CHROME_ERRORED"
assert_eq "…and goes to the end-state review" false "$GATE"

# A client's LVI-006/007: the builder ticked both Chrome-Assisted criteria on
# its way to verify, test-progress.md held only a headless ERROR for them, and
# the gate read the ticks as settled: GATE=false, CHROME_OPEN=0.
new_client "$PRE"
python3 - plans/PLN-002-beta/plan.md <<'PY4'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("- [ ] (eyes:blocking)", "- [x] (eyes:blocking)", 1)
s=s.replace("#### Manual\n", "#### Chrome-Assisted\n- [x] /print — the label stays on one line at a phone width\n- [x] /print — the footer keeps the page count beside the title — deferred as DC-007\n\n#### Manual\n", 1)
open(p,"w").write(s)
PY4
git add -A && git commit -qm "builder ticked chrome"
sha=$(git rev-parse --short HEAD)
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n| 1 | /print — the label stays on one line at a phone width | %s | — | ERROR sign-in link rate limit |\n' "$sha" > plans/PLN-002-beta/test-progress.md
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "a tick with nothing behind it is read as open: CHROME_OPEN=1" 1 "$CHROME_OPEN"
assert_eq "…counted as ticked" 1 "$CHROME_TICKED"
assert_eq "…its ERROR still counts: CHROME_ERRORED=1" 1 "$CHROME_ERRORED"
assert_eq "…and it gates" true "$GATE"
assert_has "…saying the box is not the record" "ticked in plan.md with no PASS, deferral" "$GATE_REASON"
printf '| # | Criterion | Build | Result | Notes |\n|-|-|-|-|-|\n| 1 | /print — the label stays on one line at a phone width | %s | — | needs: device — a real phone is required |\n' "$sha" > plans/PLN-002-beta/test-progress.md
git add -A && git commit -qm "reasoned"
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "with a reason it goes to the end-state review" false "$GATE"
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1); rc=$?
assert_eq "lv-lane.sh answer: exit 0" 0 "$rc"
assert_has "…lists the ticked criterion on the post-ship checklist" "- [ ] /print — the label stays on one line at a phone width _(chrome-assisted" "$(cat plans/PLN-002-beta/plan.md)"
assert_not "…but not the deferred one" "- [ ] /print — the footer keeps the page count" "$(cat plans/PLN-002-beta/plan.md)"
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "once listed, the tick is backed: CHROME_TICKED=0" 0 "$CHROME_TICKED"
assert_eq "…and nothing is open" 0 "$CHROME_OPEN"

# A client's LVI-053: the tester had moved the plan to accept when it opened
# manual-test; answering it left the row where the daemon never looks.
new_client "$PRE"
sed -i.bak 's/| PLN-002 | beta | testing | — | — |/| PLN-002 | beta | accept | — | feature\/PLN-002-beta |/' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
git add -A && git commit -qm "in accept"
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1); rc=$?
assert_eq "answer from accept: exit 0" 0 "$rc"
assert_has "…moves the plan back to testing, branch kept" "| PLN-002 | beta | testing | — | feature/PLN-002-beta |" "$(cat plans/REGISTRY.md)"
assert_eq "…and commits it" "" "$(git status --porcelain plans/REGISTRY.md)"

# A client's LVI-017: a self-answered needs-input sent a criterion to
# /lv-accept; pre-launch carried it out as the end-state checklist, and the
# record said nothing of it. The operator's call: the checklist wins, and the
# answer step says that is how the answer was carried out.
new_client "$PRE"
cat > plans/PLN-002-beta/findings.md <<'F'
# Findings — beta

## Decisions

### needs-input — 2026-11-19T01:22:39Z
> **Asked:** How should criterion 1 be settled?
> **Resolution:** self-answered (pre-launch): Take the trace by hand in /lv-accept and record it there.
> **Answered by:** pre-launch
F
git add -A && git commit -qm "answer of record"
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1); rc=$?
assert_eq "answer with a /lv-accept answer of record: exit 0" 0 "$rc"
assert_has "…says how the answer was carried out" "carried out as the end-state checklist" "$out"
f=$(cat plans/PLN-002-beta/findings.md)
assert_has "…records it in findings.md, naming the answer" "**Answer of record:** needs-input — 2026-11-19T01:22:39Z — sent criteria to /lv-accept." "$f"
assert_has "…and that no manual-test gate opened" "no manual-test gate opened: 1 criteria" "$f"
assert_eq "…committed" "" "$(git status --porcelain plans/PLN-002-beta/findings.md)"
assert_eq "no manual-test gate is open" false "$([ -f $G/PLN-002.gate ] && echo true || echo false)"
new_client "$PRE"
printf '# Findings\n\n## Decisions\n\n### needs-input — 2026-11-19T00:00:00Z\n> **Resolution:** (b) Print sheet\n' > plans/PLN-002-beta/findings.md
git add -A && git commit -qm "unrelated answer"
out=$("$S/lv-lane.sh" answer PLN-002 manual-test 2>&1)
assert_not "an answer that never named /lv-accept adds no note" "Carried out as" "$(cat plans/PLN-002-beta/findings.md)"

# ── 8. Not pre-launch ──────────────────────────────────────────────────────
echo ""
echo "8. Governed, or past live_from: gates as before"
new_client 'projectProfile:\n  tier: governed\n'
LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Which?" --recommend "(a)" >/dev/null 2>&1
assert_eq "governed: needs-input parks" true "$([ -f $G/PLN-001.gate ] && echo true || echo false)"
assert_has "…showing the recommendation" "GATE_RECOMMENDED='(a)'" "$(cat $G/PLN-001.gate)"
out=$(LV_UNATTENDED=1 "$S/lv-gate-close.sh" PLN-001 "(a)" --only needs-input --basis pre-launch 2>&1); rc=$?
assert_eq "governed: --basis pre-launch refused (exit 4)" 4 "$rc"
eval "$("$S/lv-manual-gate.sh" PLN-002 2>/dev/null)"
assert_eq "governed: an eyes:blocking plan gates" true "$GATE"
new_client 'projectProfile:\n  tier: pre-launch\n  live_from: "2026-01-01"\n'
LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Which?" --recommend "(a)" >/dev/null 2>&1
assert_eq "past live_from: needs-input parks" true "$([ -f $G/PLN-001.gate ] && echo true || echo false)"

echo ""
echo "9. Today is the display zone's, not UTC's (LVI-037)"
# Two zones a day apart at the same instant: Kiritimati is UTC+14, Pago Pago
# UTC-11. Whichever date the far-east zone reads, live_from = that date is
# "today" there (not pre-launch) and "tomorrow" in the far west (pre-launch).
east=$(TZ=Pacific/Kiritimati date +%Y-%m-%d)
west=$(TZ=Pacific/Pago_Pago date +%Y-%m-%d)
new_client "projectProfile:\n  tier: pre-launch\n  live_from: \"$east\"\ndisplay:\n  timezone: Pacific/Kiritimati\n"
assert_eq "display.timezone sets today"  "$east" "$(bash -c '. "$1/lv-orch-lib.sh"; wf_today' _ "$S")"
assert_eq "live_from = today there: not pre-launch" no \
  "$(bash -c '. "$1/lv-orch-lib.sh"; wf_prelaunch && echo yes || echo no' _ "$S")"
assert_eq "LV_TZ overrides levain.yml"   "$west" "$(LV_TZ=Pacific/Pago_Pago bash -c '. "$1/lv-orch-lib.sh"; wf_today' _ "$S")"
assert_eq "the same live_from is tomorrow in the far west: pre-launch" yes \
  "$(LV_TZ=Pacific/Pago_Pago bash -c '. "$1/lv-orch-lib.sh"; wf_prelaunch && echo yes || echo no' _ "$S")"
assert_eq "a UTC stamp is shown in the zone, labelled" "2026-10-29 19:30:00 EDT" \
  "$(LV_TZ=America/Toronto bash -c '. "$1/lv-orch-lib.sh"; wf_show_time 2026-10-29T23:30:00Z' _ "$S")"
assert_eq "an epoch too" "2026-10-30 00:30:00 CET" \
  "$(LV_TZ=Europe/Paris bash -c '. "$1/lv-orch-lib.sh"; wf_show_time 1793316600' _ "$S")"
assert_eq "an unreadable stamp comes back unchanged" "soon" \
  "$(bash -c '. "$1/lv-orch-lib.sh"; wf_show_time soon' _ "$S")"
assert_eq "showing a time leaves the caller's TZ alone" unset \
  "$(LV_TZ=Europe/Paris bash -c 'unset TZ; . "$1/lv-orch-lib.sh"; wf_show_time >/dev/null; echo "${TZ-unset}"' _ "$S")"

# ── 1b. A hold answer is a dependency (a client's LVI-064) ─────────────────
#
# PLN-143 in verify asked "hold until PLN-144 lands, or send to testing?",
# answered it "hold", stayed in verify, and was dispatched to ask again: three
# times in four minutes. --hold-until writes the hold into Deps, and the lists
# the dispatcher reads stop offering the plan until the dependency completes.
echo ""
echo "1b. a 'hold until <plan> lands' answer is recorded in Deps"
new_client "$PRE"
sed -i.bak 's/^| PLN-001 | alpha | draft |/| PLN-001 | alpha | verify |/' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
git commit -qam "PLN-001 to verify"
assert_eq "before: verify offers PLN-001" "PLN-001-alpha" "$("$S/lv-list-verify.sh" 2>/dev/null | cut -f1)"
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-001 needs-input "Hold PLN-001 until PLN-002 lands, or send it to testing?" \
  --recommend "hold until PLN-002 lands" --hold-until PLN-002 2>&1); rc=$?
assert_eq "exit 0" 0 "$rc"
assert_eq "no gate is left open" "" "$(ls $G/*.gate 2>/dev/null)"
assert_eq "the hold is in PLN-001's Deps" "PLN-002" "$(cd "$CLIENT" && bash -c '. "$1/lv-orch-lib.sh"; wf_registry_field PLN-001 deps plans/REGISTRY.md' _ "$S")"
assert_eq "…committed, not left dirty" "" "$(git status --porcelain plans/REGISTRY.md)"
assert_has "…and named in the decision of record" "Held until:** PLN-002 lands" "$(cat plans/PLN-001-alpha/findings.md 2>/dev/null)"
assert_has "verify lists it as held" "blocked:PLN-002" "$("$S/lv-list-verify.sh" 2>/dev/null)"
assert_eq "…and the dispatcher's verify candidates leave it out" "" \
  "$("$S/lv-orchestrate.sh" --sweep --dry-run --force 2>&1 | grep -E 'spawn.*verify.*PLN-001|verify +PLN-001' | grep -v skip || true)"
out=$("$S/lv-gate-close.sh" PLN-001 "hold" --gate needs-input --hold-until PLN-002 2>&1)
assert_has "a second hold on the same plan adds nothing" "already depends on PLN-002" "$out"
sed -i.bak 's/^| PLN-002 | beta | testing |/| PLN-002 | beta | complete |/' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
git commit -qam "PLN-002 complete"
assert_eq "once PLN-002 lands, verify offers PLN-001 again" "PLN-001-alpha" "$("$S/lv-list-verify.sh" 2>/dev/null | cut -f1)"
out=$("$S/lv-gate-close.sh" PLN-001 "hold" --gate needs-input --hold-until PLN-999 2>&1); rc=$?
assert_eq "a hold on nothing is refused" 1 "$rc"
assert_has "…before anything is closed" "Nothing was closed" "$out"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
