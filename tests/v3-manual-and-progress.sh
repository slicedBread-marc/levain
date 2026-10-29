#!/usr/bin/env bash
# v3-manual-and-progress.sh — tests for the v3.0 additions:
#
#   lv-progress-tick.sh / lv-progress-count.sh   forward-progress signal (P-007)
#   lv-manual-lint.sh                            manual criterion tags (P-002)
#   lv-manual-gate.sh                            surface-gated manual test (P-003)
#   lv-defer-criterion.sh                        deferred-criteria producer (P-004)
#   lv-list-consistency.sh                       cross-plan pass candidates (P-005)
#   lv-config-get.sh                             config reads from skills
#
# Usage: ./tests/v3-manual-and-progress.sh
# Exit 0 if all pass, 1 otherwise.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_SCRIPTS="$LIB_ROOT/scripts"
SCRIPT_FOLDER=$(awk '{sub(/#.*/, "")} NF >= 2 {folder = $2} END {print folder}' "$LIB_SCRIPTS/version-map.txt")
[ -n "$SCRIPT_FOLDER" ] || { echo "cannot resolve script folder from version-map.txt" >&2; exit 1; }
SCRIPT_DIR="${LV_TEST_SCRIPT_DIR:-$LIB_SCRIPTS/$SCRIPT_FOLDER}"

TEST_DIR=""
PASS=0
FAIL=0

cleanup() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
  return 0
}
trap cleanup EXIT

section() { printf '\n\033[1m── %s ──\033[0m\n' "$1"; }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n      expected: %s\n      actual:   %s\n' "$label" "$expected" "$actual"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -q -e "$needle"; then
    printf '  \033[32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s\n      expected to contain: %s\n      actual: %s\n' "$label" "$needle" "$haystack"
    FAIL=$((FAIL + 1))
  fi
}

assert_exit() {
  local label="$1" expected="$2"; shift 2
  "$@" >/dev/null 2>&1
  local actual=$?
  if [ "$expected" -eq "$actual" ]; then
    printf '  \033[32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s (exit %d, expected %d)\n' "$label" "$actual" "$expected"; FAIL=$((FAIL + 1))
  fi
}

# ── Fixture ────────────────────────────────────────────────────────────
setup_repo() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR" || exit 1
  git init -qb develop
  git config user.email "test@test.com"
  git config user.name "Test"
  mkdir -p plans feature-branches src/App/Cli

  cat > levain.yml << 'CFG'
build_command: "dotnet build"

manualTestGate:
  requireRenderingSurface: true
  minEyesCriteria: 1
  blockOnCosmetic: false
  renderingSurfaces:
    - "src/**/wwwroot/**"
    - "src/**/*.razor"

specApproval:
  mode: verdict
  maxReviewRounds: 3
  gateTags:
    - security
    - infra
CFG

  cat > plans/REGISTRY.md << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-004 | cli | testing | — | — | 2026-08-01 | 3.0.0 | infra | — |
| PLN-007 | ui | testing | — | — | 2026-08-01 | 3.0.0 | ux | — |
| PLN-011 | dep | ready | — | — | 2026-08-01 | 3.0.0 | infra | PLN-004 |
| PLN-012 | nodep | ready | — | — | 2026-08-01 | 3.0.0 | infra | — |
| PLN-013 | done | ready | — | — | 2026-08-01 | 3.0.0 | infra | PLN-004 |
| PLN-020 | legacy | active | — | — | 2026-08-01 | 3.0.0 | infra | — |

<!-- Counter: 21 -->
SEED

  mkdir -p plans/PLN-004-cli plans/PLN-007-ui plans/PLN-011-dep plans/PLN-012-nodep plans/PLN-013-done plans/PLN-020-legacy

  cat > plans/PLN-004-cli/plan.md << 'P'
> **schema_version:** 6

## Goal
Ship the CLI export command.

## Verification Checklist

### Human Test Criteria

#### Manual
- [ ] (eyes:cosmetic) doctor output is pleasant to read
- [ ] (external) push to the real remote succeeds
- [ ] (soak) the Stalled section surfaces something forgotten
P

  cat > plans/PLN-007-ui/plan.md << 'P'
> **schema_version:** 6

## Goal
Ship the timer page.

#### Manual
- [ ] (eyes:blocking) /timer — usable one-handed on a phone
- [ ] /board — output contains the file name
- [ ] (eyes) /board — reads clearly
- [ ] (eyes:blocking) a patch touching azure-pipelines.yml is refused with a message naming the file

### Code Quality
- [ ] no TODOs
P

  cat > plans/PLN-020-legacy/plan.md << 'P'
> **schema_version:** 5

## Goal
A plan drafted before tags existed.

#### Manual
- [ ] /play — animation feels smooth
- [ ] /play — output contains the build id
P

  for p in PLN-011-dep PLN-012-nodep PLN-013-done; do
    printf '> **schema_version:** 6\n\n## Goal\nGoal for %s.\n' "$p" > "plans/$p/plan.md"
  done
  cat >> plans/PLN-013-done/plan.md << 'P'

## Consistency

> **Checked:** 2026-08-01 — closure: PLN-004
> **Result:** clean
P

  cat > plans/PLN-020-legacy/progress.md << 'P'
# Progress — Legacy

## Steps
- [ ] Step 1: scaffold
- [ ] Step 2: wire it
- [ ] Step 10: polish

## Log
P

  echo x > src/App/Cli/Program.cs
  git add -A
  git commit -qm "init: seed test repo"
}

setup_repo

# ── P-007 forward progress ─────────────────────────────────────────────
section "lv-progress-count / lv-progress-tick (P-007)"

assert_eq "counts an untouched checklist" "0/3" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_eq "unknown plan reads 0/0" "0/0" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-999)"

"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 2 "wired it" >/dev/null 2>&1
assert_eq "a tick moves the count" "1/3" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_contains "the Log line is written" "Step 2 — done (wired it)" "$(cat plans/PLN-020-legacy/progress.md)"

"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 10 "double-digit step" >/dev/null 2>&1
assert_eq "step 10 ticks, not step 1" "2/3" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_contains "step 1 is still open" "- \[ \] Step 1" "$(cat plans/PLN-020-legacy/progress.md)"

"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 1 "no migration yet" --blocked >/dev/null 2>&1
assert_eq "--blocked logs without ticking" "2/3" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_contains "the blocked reason is logged" "Step 1 — blocked" "$(cat plans/PLN-020-legacy/progress.md)"

# An amendment grows plan.md's Steps and leaves progress.md's checklist behind.
# The tick appends the missing row rather than reporting a frozen total (WFI-111).
"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 11 "amendment step" >/dev/null 2>&1
assert_eq "an amendment step joins the checklist" "3/4" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_contains "and is ticked where it landed" "- \[x\] Step 11: amendment step" \
  "$(cat plans/PLN-020-legacy/progress.md)"
"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 11 "amendment step" >/dev/null 2>&1
assert_eq "re-ticking it appends nothing" "3/4" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_eq "the appended row stays inside ## Steps" "1" \
  "$(awk '/^## Steps/{s=1;next} /^## /{s=0} s && /Step 11/' plans/PLN-020-legacy/progress.md | wc -l | tr -d ' ')"

# An amendment's own steps are labelled by the amendment — `Step A1.1` … —
# so the label carries a leading letter and dots. Those were a usage error
# until WFI-263, and eight rows were ticked by hand instead.
"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 A1.1 "amendment A-1 step one" >/dev/null 2>&1
assert_eq "an amendment-numbered step is accepted" "4/5" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_contains "and lands with its whole label" "- \[x\] Step A1.1: amendment A-1 step one" \
  "$(cat plans/PLN-020-legacy/progress.md)"
"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 A1.2 "amendment A-1 step two" >/dev/null 2>&1
assert_eq "a sibling amendment step is its own row" "5/6" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_contains "A1.1 was not re-ticked as A1.2" "- \[x\] Step A1.1: amendment A-1 step one" \
  "$(cat plans/PLN-020-legacy/progress.md)"
"$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 A1.1 "again" >/dev/null 2>&1
assert_eq "re-ticking an amendment step appends nothing" "5/6" \
  "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
# `A1` names the family, not a step — appending it beside A1.1/A1.2 would
# corrupt the checklist the orchestrator reads (the WFI-115 rule).
assert_exit "a bare amendment prefix is refused" 1 \
  "$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 A1 "family, not a step"
assert_exit "a label with no digit is a usage error" 1 \
  "$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 foo "not a label"
# Some plans keep the amendment's hyphen in the label — `Step A-1.1`. The
# label grammar refused it, so the row could not be ticked by its own name
# (LVI-022 on a client).
awk '{print} /^## Steps/ && !d {print "- [ ] Step A-2.1: hyphenated amendment step"; d=1}' \
  plans/PLN-020-legacy/progress.md > plans/PLN-020-legacy/progress.md.tmp \
  && mv plans/PLN-020-legacy/progress.md.tmp plans/PLN-020-legacy/progress.md
assert_exit "a hyphenated amendment label is accepted" 0 \
  "$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 A-2.1 "hyphenated amendment step"
assert_contains "and ticks the row the plan wrote" "- \[x\] Step A-2.1: hyphenated amendment step" \
  "$(cat plans/PLN-020-legacy/progress.md)"
assert_eq "without appending a second one" "6/7" "$("$SCRIPT_DIR/lv-progress-count.sh" PLN-020)"
assert_exit "a label ending on a separator is still a usage error" 1 \
  "$SCRIPT_DIR/lv-progress-tick.sh" PLN-020 A-2. "trailing dot"

# ── P-002 manual criterion lint ────────────────────────────────────────
section "lv-manual-lint (P-002)"

assert_exit "a fully tagged plan is clean" 0 "$SCRIPT_DIR/lv-manual-lint.sh" PLN-004
assert_exit "an offending plan exits 1" 1 "$SCRIPT_DIR/lv-manual-lint.sh" PLN-007

lint_out=$("$SCRIPT_DIR/lv-manual-lint.sh" PLN-007 2>/dev/null)
assert_contains "flags an untagged criterion" "untagged" "$lint_out"
assert_contains "flags a bare (eyes) tag" "unknown-tag" "$lint_out"
assert_contains "flags an assertable verb under eyes:*" "assertable" "$lint_out"
assert_eq "does not flag the genuine eyes criterion" "0" \
  "$(printf '%s\n' "$lint_out" | grep -c 'usable one-handed')"

assert_exit "a pre-v6 plan is not linted" 0 "$SCRIPT_DIR/lv-manual-lint.sh" PLN-020

eval "$("$SCRIPT_DIR/lv-manual-lint.sh" PLN-004 --counts)"
assert_eq "counts cosmetic criteria" "1" "$MANUAL_EYES_COSMETIC"
assert_eq "counts external criteria" "1" "$MANUAL_EXTERNAL"
assert_eq "counts soak criteria" "1" "$MANUAL_SOAK"
assert_eq "no open blocking criteria" "0" "$MANUAL_OPEN_BLOCKING"

eval "$("$SCRIPT_DIR/lv-manual-lint.sh" PLN-020 --counts)"
assert_eq "pre-v6 criteria count as blocking" "2" "$MANUAL_OPEN_BLOCKING"

# ── The template's own Review block is not a review (WFI-236) ──────────
#
# wf_review_has_content filtered the menu line and the stamp hint and nothing
# else, so a plan.md written verbatim from TEMPLATE.md — which lv-spec tells
# planners to follow — counted as "a review is written here but no Result:
# line" and failed the pre-review self-lint on every brand-new plan.
section "An unfilled Review reads as empty (WFI-236)"

review_says() {
  # shellcheck disable=SC1090
  ( source "$SCRIPT_DIR/lv-orch-lib.sh"
    wf_review_has_content "$1" && echo HAS || echo EMPTY )
}
assert_eq "the template's placeholder block is empty" "EMPTY" \
  "$(review_says "$(awk '/^## Review/{r=1;next} /^## /{r=0} r' "$LIB_ROOT/templates/plans/TEMPLATE.md")")"
assert_eq "the pre-v6.40 blockquoted placeholder is empty too" "EMPTY" \
  "$(review_says '> Filled by the planner'"'"'s review gate before status is set to Ready.
> Can also be populated by an independent `/review` invocation.
>
> **[date] — Plan Review / Code Review**
> **Result:** Approved | Approved with notes | Blocked
> | # | Severity | Category | Finding | Recommendation |
> |-|-|-|-|-|')"
assert_eq "a real verdict still reads as content" "HAS" \
  "$(review_says '> **2026-09-02 — Plan Review**
> **Result:** Approved')"

# ── A transition can carry the reason it happened (WFI-235) ────────────
section "lv-registry-update --note"

"$SCRIPT_DIR/lv-registry-update.sh" PLN-013 ready active - \
  --note "scope settled against the publish guard" >/dev/null 2>&1
assert_contains "the note lands in the plan's progress.md" "scope settled against the publish guard" \
  "$(cat plans/PLN-013-done/progress.md 2>/dev/null || true)"
assert_contains "stamped with the transition it explains" "ready → active" \
  "$(cat plans/PLN-013-done/progress.md 2>/dev/null || true)"
assert_eq "and REGISTRY.md is not where it went" "0" \
  "$(grep -c 'scope settled' plans/REGISTRY.md || true)"
"$SCRIPT_DIR/lv-registry-update.sh" PLN-013 active ready - >/dev/null 2>&1

# ── P-003 surface-gated manual test ────────────────────────────────────
section "lv-manual-gate (P-003)"

git worktree add -q -b feature/PLN-004-cli feature-branches/PLN-004-cli develop
( cd feature-branches/PLN-004-cli && echo more >> src/App/Cli/Program.cs && git add -A && git commit -qm cli )

git worktree add -q -b feature/PLN-007-ui feature-branches/PLN-007-ui develop
( cd feature-branches/PLN-007-ui && mkdir -p src/App/wwwroot && echo y > src/App/wwwroot/app.js && git add -A && git commit -qm ui )

eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-004)"
assert_eq "a CLI-only diff never stops for a human" "false" "$GATE"
assert_contains "and says why" "below minEyesCriteria" "$GATE_REASON"

eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a rendering-surface diff with open eyes gates" "true" "$GATE"
assert_eq "and names the file that decided it" "src/App/wwwroot/app.js" "$SURFACE_HIT"

# A criterion lv-test already recorded PASS against THIS build is not open —
# lv-test writes the result to test-progress.md and deliberately leaves
# plan.md's checkbox alone, so the two files disagree for every criterion that
# simply passed. client-b' PLN-011 was parked for a human with 8 of 8 recorded
# PASS on the build standing there (WFI-013).
ui_sha=$(git -C feature-branches/PLN-007-ui rev-parse --short HEAD)
cat > plans/PLN-007-ui/test-progress.md << PROGRESS
## Test Progress — PLN-007-ui

| # | Criterion | Build | Result | Notes |
|-|-|-|-|-|
| 1 | /timer — usable one-handed on a phone | Aug 01 09:15 ($ui_sha) | PASS | |
| 2 | /board — output contains the file name | Aug 01 09:15 ($ui_sha) | PASS | |
| 3 | /board — reads clearly | Aug 01 09:15 ($ui_sha) | PASS | |
| 4 | a patch touching azure-pipelines.yml is refused with a message naming the file | Aug 01 09:15 ($ui_sha) | PASS | |
PROGRESS

eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "every criterion PASS on this build does not stop for a human" "false" "$GATE"
assert_eq "and all four are counted as settled by the record" "4" "$MANUAL_RESOLVED_RECORD"
assert_contains "and the reason says where that came from" "already PASS on this build" "$GATE_REASON"

# A client's LVI-033: unattended, a PASS the worker wrote into the working copy
# is its own guess at an eyes criterion. Only the committed record settles one.
eval "$(LV_UNATTENDED=1 "$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "unattended, an uncommitted PASS settles nothing" "true 0" "$GATE $MANUAL_RESOLVED_RECORD"
git add plans/PLN-007-ui/test-progress.md && git commit -qm "test: record" >/dev/null
eval "$(LV_UNATTENDED=1 "$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a committed PASS does" "false 4" "$GATE $MANUAL_RESOLVED_RECORD"

# The Build column is the whole point of that file: a PASS is a measurement of
# one tree, and this is no longer that tree.
sed -i.bak "s/$ui_sha/0000000/g" plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a PASS recorded against an older build settles nothing" "true" "$GATE"
assert_eq "and nothing is subtracted" "0" "$MANUAL_RESOLVED_RECORD"

# A client's LVI-006: a later commit that renders nothing (a release merge of
# storage code) re-asked a PASSed print criterion, and the worker's gate
# question invented a CSS change. A PASS on an earlier build carries when no
# renderingSurfaces path changed since; one that did change still re-asks.
sed -i.bak "s/0000000/$ui_sha/g" plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
( cd feature-branches/PLN-007-ui && mkdir -p src/App/Storage && echo s > src/App/Storage/Replica.cs && git add -A && git commit -qm storage )
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a PASS carries over a commit that touches no rendering surface" "false" "$GATE"
assert_eq "all four carried" "4" "$MANUAL_CARRIED"
assert_contains "and the reason names the build it came from" "carried from build $ui_sha" "$GATE_REASON"
( cd feature-branches/PLN-007-ui && echo z >> src/App/wwwroot/app.js && git add -A && git commit -qm "ui again" )
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a commit that touches a rendering surface re-asks" "true" "$GATE"
assert_eq "and carries nothing" "0" "$MANUAL_CARRIED"
# A client's LVI-021: the re-ask quoted SURFACE_HIT — the plan's whole diff —
# naming a file identical on both builds. The path that blocked the carry is
# its own field, and the reason says it.
assert_eq "the surface path that moved since the PASS is named" "src/App/wwwroot/app.js" "$SURFACE_MOVED"
assert_eq "with the build the PASS was on" "${ui_sha:0:7}" "$SURFACE_MOVED_FROM"
assert_contains "and the reason says that path, not the plan's whole diff" \
  "did not carry: src/App/wwwroot/app.js" "$GATE_REASON"

# A client's LVI-040: an unattended tester left every Chrome-Assisted criterion
# unrun and gated on the one Manual criterion — the question never named the
# rest. The gate accounts for Chrome-Assisted criteria itself now.
ui_sha=$(git -C feature-branches/PLN-007-ui rev-parse --short HEAD)
sed -i.bak "s/([0-9a-f]\{7\})/($ui_sha)/g" plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
cp plans/PLN-007-ui/plan.md plans/PLN-007-ui/plan.md.orig
cat >> plans/PLN-007-ui/plan.md << 'P'

#### Chrome-Assisted
- [ ] /collage — the photo grid renders every uploaded image
- [ ] /collage — dragging a photo reorders the grid
- [x] /collage — prints on A4 — deferred as DC-001
P
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "unrun Chrome-Assisted criteria gate even with every Manual one PASS" "true" "$GATE"
assert_eq "both unchecked ones are unrecorded" "2" "$CHROME_UNRECORDED"
assert_eq "and the record is called incomplete" "true" "$PROGRESS_INCOMPLETE"
assert_contains "the reason names them" "dragging a photo reorders the grid" "$GATE_REASON"

cat >> plans/PLN-007-ui/test-progress.md << PROGRESS
| 5 | /collage — the photo grid renders every uploaded image | Aug 01 09:15 ($ui_sha) | PASS | headless eval |
| 6 | /collage — dragging a photo reorders the grid | — | — | needs browser mode (drag-and-drop requires user interaction) |
PROGRESS
# A client's LVI-030: a note is not a run. Drag-and-drop is scriptable.
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a note with no headless result is not a reason" "1 1 0" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
assert_eq "so the record is incomplete" "true" "$PROGRESS_INCOMPLETE"
assert_contains "and the tester is told to run it" "no headless result" "$GATE_REASON"
# A client's LVI-036: "needs: device" for a file download. Downloads, uploads
# and the clipboard all have headless verbs, so the four-thing excuse does not
# cover them.
sed -i.bak 's/| needs browser mode (drag-and-drop requires user interaction) |/| needs: device — file download requires real browser |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "needs: device for a download is an excuse, not a reason" "1 1 0" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
sed -i.bak 's/| needs: device — file download requires real browser |/| needs: device — the camera prompt on a real phone |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "needs: device for a real device is still a reason" "0 0 1" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
# A client's LVI-031 and LVI-028: a disagreement named as such, and a run whose
# capture could not be judged, are reasons — both were run.
sed -i.bak 's/| needs: device — the camera prompt on a real phone |/| Disagreement: a FAIL was recorded on 1f76729, headless now reads the grid reordered |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a note naming a disagreement is a reason" "0 0 1" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
sed -i.bak 's/| Disagreement: a FAIL was recorded on 1f76729, headless now reads the grid reordered |/| headless screenshot 390+1280: ambiguous — one tile moves by design |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "an ambiguous headless reading is a reason" "0 0 1" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
# A client's LVI-047: data the dev environment does not hold is a reason,
# when the note says what is missing.
sed -i.bak 's/| headless screenshot 390+1280: ambiguous — one tile moves by design |/| needs: data — dev DB has no photos and no seeder |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "needs: data naming what is missing is a reason" "0 0 1" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
sed -i.bak 's/| needs: data — dev DB has no photos and no seeder |/| needs: data |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a bare needs: data is an excuse" "1 1 0" "$CHROME_EXCUSED $CHROME_UNRECORDED $CHROME_UNTESTED"
sed -i.bak 's/| needs: data |/| needs: device — the camera prompt on a real phone |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
sed -i.bak 's/| needs: device — the camera prompt on a real phone |/| headless: ERROR waitForSelector #photo-2 timed out |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "one run, one untested with a reason: nothing unrecorded" "0" "$CHROME_UNRECORDED"
assert_eq "so the record is complete" "false" "$PROGRESS_INCOMPLETE"
assert_eq "but the untested one still reaches a human" "true" "$GATE"
assert_contains "named, as untested" "untested (reason in test-progress.md): /collage — dragging" "$GATE_REASON"

sed -i.bak '/dragging a photo/s/| — | — | headless.*|$/| Aug 01 09:15 ('"$ui_sha"') | PASS | |/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "every Chrome-Assisted criterion run and every Manual one PASS: no human" "false" "$GATE"
assert_eq "and nothing Chrome-Assisted is open" "0 0" "$CHROME_UNRECORDED $CHROME_UNTESTED"

# A client's LVI-029: every Chrome-Assisted row was a day and two client-code
# commits old, the tester ran nothing, and the plan went testing -> accept on
# the strength of them. A run settles a criterion for the build it was run on.
sed -i.bak '/photo grid renders/s/('"$ui_sha"')/(1111111)/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a PASS on another build leaves a Chrome-Assisted criterion unrecorded" "1 true" "$CHROME_UNRECORDED $PROGRESS_INCOMPLETE"
sed -i.bak '/photo grid renders/s/| (1111111) | PASS |/| Aug 01 09:15 (1111111) | FAIL |/; /photo grid renders/s/(1111111) | PASS/(1111111) | FAIL/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "so does a FAIL on another build" "1" "$CHROME_UNRECORDED"
sed -i.bak '/photo grid renders/s/(1111111) | FAIL/('"$ui_sha"') | PASS/' plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
( cd feature-branches/PLN-007-ui && echo t >> src/App/Storage/Replica.cs && git add -A && git commit -qm "storage again" )
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a PASS carried over a commit that renders nothing still settles it" "0" "$CHROME_UNRECORDED"
( cd feature-branches/PLN-007-ui && echo y >> src/App/wwwroot/app.js && git add -A && git commit -qm "ui once more" )
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "one that touched a rendering surface does not" "2 true" "$CHROME_UNRECORDED $PROGRESS_INCOMPLETE"

rm -f plans/PLN-007-ui/test-progress.md
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_contains "no test-progress.md at all is said out loud" "test-progress.md does not exist" "$GATE_REASON"
mv plans/PLN-007-ui/plan.md.orig plans/PLN-007-ui/plan.md

# A client's LVI-027: an amendment replaced criteria with its own, and the gate
# read only the original lists — it named the superseded criteria as unrun and
# never saw the amendment's. Replaced criteria drop out; the amendment's count.
cp plans/PLN-007-ui/plan.md plans/PLN-007-ui/plan.md.orig
eval "$("$SCRIPT_DIR/lv-manual-lint.sh" PLN-007 --counts)"; blocking_before=$MANUAL_OPEN_BLOCKING
cat >> plans/PLN-007-ui/plan.md << 'P'

#### Chrome-Assisted
- [ ] /collage — the old flat grid shows every photo in one row
- [ ] /collage — the photo grid renders every uploaded image

## Amendments

### A-1 (BUG-099): the grid becomes a tree

#### Human Test Criteria (A-1) — replace Chrome-Assisted 1

##### Chrome-Assisted
- [ ] /collage — the photo tree nests every photo under its album

##### Manual
- [ ] (eyes:blocking) /collage — the album tree reads as the albums the user made
P
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a replaced criterion drops out and the amendment's counts" "2" "$CHROME_OPEN"
assert_contains "the amendment's criterion is named" "photo tree nests" "$PROGRESS_MISSING"
assert_eq "the replaced one is not" "0" "$(printf '%s' "$PROGRESS_MISSING" | grep -c 'old flat grid')"
eval "$("$SCRIPT_DIR/lv-manual-lint.sh" PLN-007 --counts)"
assert_eq "an amendment's Manual criterion is open like any other" "$((blocking_before + 1))" "$MANUAL_OPEN_BLOCKING"
printf '\n**Supersedes:** Chrome-Assisted 2\n' >> plans/PLN-007-ui/plan.md
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a Supersedes line retires criteria too" "1" "$CHROME_OPEN"

# A client's LVI-010: a later amendment's "replace Manual 2" could retire only
# an ORIGINAL criterion, so A-4 left A-1's replacement live beside its own.
# Amendments apply in order: each counts the live list as it stood before it.
cat >> plans/PLN-007-ui/plan.md << 'P'

### A-2 (BUG-100): albums are folders

#### Human Test Criteria (A-2) — replace Chrome-Assisted 1

##### Chrome-Assisted
- [ ] /collage — the folder tree nests every photo under its folder
P
live=$(bash -c "source '$SCRIPT_DIR/lv-orch-lib.sh'; wf_live_criteria plans/PLN-007-ui/plan.md")
assert_eq "a later amendment retires an earlier amendment's criterion" "0" \
  "$(printf '%s\n' "$live" | grep -c 'photo tree nests')"
assert_eq "and its own replacement is live" "1" "$(printf '%s\n' "$live" | grep -c 'folder tree nests')"
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "the Chrome-Assisted count stays one" "1" "$CHROME_OPEN"
# Its flat position: every live Chrome-Assisted criterion, then its place among the Manual ones.
album_pos=$(printf '%s\n' "$live" | awk '
  /^####[[:space:]]*Chrome-Assisted/ { s = "c"; next }
  /^####[[:space:]]*Manual/ { s = "m"; next }
  /^#/ { s = ""; next }
  s == "c" && /^[[:space:]]*- \[/ { c++ }
  s == "m" && /^[[:space:]]*- \[/ { m++; if (/album tree reads/) p = m }
  END { print c + p }')
# A client's LVI-013: lv-test and lv-spec numbered the list by hand and put a
# replacement in the replaced criterion's slot. --live is the one numbering,
# and it is the one the retirement resolves against.
live_list=$("$SCRIPT_DIR/lv-manual-lint.sh" PLN-007 --live)
assert_eq "--live numbers the album criterion where the gate resolves it" "$album_pos" \
  "$(printf '%s\n' "$live_list" | grep 'album tree reads' | cut -f1)"
assert_eq "--live lists Chrome-Assisted first, the amendment's replacement in file order" \
  "1	Chrome-Assisted	1" "$(printf '%s\n' "$live_list" | grep 'folder tree nests' | cut -f1-3)"
assert_eq "--live numbers every live criterion once, contiguously" \
  "$(printf '%s\n' "$live_list" | wc -l | tr -d ' ')" "$(printf '%s\n' "$live_list" | cut -f1 | sort -n | uniq | tail -1)"
assert_eq "--live leaves out a retired criterion" "0" "$(printf '%s\n' "$live_list" | grep -c 'photo tree nests')"
cat >> plans/PLN-007-ui/plan.md << P

### A-3 (BUG-101): the album tree check moves to a script

**Supersedes:** Manual $album_pos
P
live=$(bash -c "source '$SCRIPT_DIR/lv-orch-lib.sh'; wf_live_criteria plans/PLN-007-ui/plan.md")
assert_eq "a flat Manual position reaches an amendment's Manual criterion" "0" \
  "$(printf '%s\n' "$live" | grep -c 'album tree reads')"
mv plans/PLN-007-ui/plan.md.orig plans/PLN-007-ui/plan.md

rm -f plans/PLN-007-ui/test-progress.md

git worktree remove --force feature-branches/PLN-007-ui
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "an unreadable diff gates rather than assumes" "true" "$GATE"
assert_contains "and admits it could not read the diff" "could not read" "$GATE_REASON"

# ── P-004 deferred criteria ────────────────────────────────────────────
section "lv-defer-criterion (P-004)"

assert_exit "rejects an eyes:* tag" 1 \
  "$SCRIPT_DIR/lv-defer-criterion.sh" PLN-004 eyes:blocking "should not defer"

"$SCRIPT_DIR/lv-defer-criterion.sh" PLN-004 external "push to the real remote succeeds" >/dev/null
"$SCRIPT_DIR/lv-defer-criterion.sh" PLN-004 soak "the Stalled section surfaces something forgotten" --prereq PLN-011 >/dev/null
"$SCRIPT_DIR/lv-defer-criterion.sh" PLN-007 unbuilt "admin can revoke a key" --note "revocation not built" >/dev/null

listed=$("$SCRIPT_DIR/lv-defer-criterion.sh" --list)
assert_eq "three open rows" "3" "$(printf '%s\n' "$listed" | grep -c '^DC-')"
assert_contains "external defaults to first-real-use" "first-real-use" "$listed"
assert_contains "the note survives" "revocation not built" "$listed"

filtered=$("$SCRIPT_DIR/lv-defer-criterion.sh" --list PLN-011)
assert_eq "filters by prereq" "1" "$(printf '%s\n' "$filtered" | grep -c '^DC-')"

"$SCRIPT_DIR/lv-defer-criterion.sh" --consume DC-002 PLN-011 >/dev/null
assert_eq "a consumed row leaves the open list" "2" \
  "$("$SCRIPT_DIR/lv-defer-criterion.sh" --list | grep -c '^DC-')"
assert_contains "and stays in the file as the record" "consumed by PLN-011" \
  "$(cat plans/deferred-criteria.md)"

# Zero-padded ids must not be read as octal — the WFI-008 → WFI-009 bug class.
for i in 4 5 6 7 8 9; do
  "$SCRIPT_DIR/lv-defer-criterion.sh" PLN-004 external "filler $i" >/dev/null
done
assert_contains "DC-009 increments to DC-010, not an octal error" "DC-010" \
  "$("$SCRIPT_DIR/lv-defer-criterion.sh" PLN-004 external "the tenth")"

# ── P-005 consistency candidates ───────────────────────────────────────
section "lv-list-consistency (P-005)"

cand=$("$SCRIPT_DIR/lv-list-consistency.sh")
assert_contains "lists a ready plan with deps" "PLN-011-dep" "$cand"
assert_eq "skips a plan with no deps" "0" "$(printf '%s\n' "$cand" | grep -c 'PLN-012')"
assert_eq "skips an already-checked plan" "0" "$(printf '%s\n' "$cand" | grep -c 'PLN-013')"
assert_eq "skips plans that are not ready" "0" "$(printf '%s\n' "$cand" | grep -c '^PLN-004')"
assert_exit "filters to one plan when asked" 0 "$SCRIPT_DIR/lv-list-consistency.sh" PLN-011
assert_exit "exits 1 when the filtered plan is done" 1 "$SCRIPT_DIR/lv-list-consistency.sh" PLN-013

# The plan template ships the Consistency section pre-filled. For as long as
# any `> **Checked:**` line was the done-marker, every plan was born already
# checked and this list was permanently empty — PLN-010 declared five deps and
# reached verify without a pass ever being dispatched (WFI-108).
cat >> plans/PLN-011-dep/plan.md << 'P'

## Consistency
> **Checked:** YYYY-MM-DD — closure: PLN-NNN, PLN-MMM
> **Result:** clean | amended PLN-NNN
P
assert_exit "the template placeholder is not a pass" 0 "$SCRIPT_DIR/lv-list-consistency.sh" PLN-011

# A client's LVI-028: a pass is a verdict on the closure as it stood. Amend a
# plan in the closure after the entry was committed and the pass is owed again.
git add -A >/dev/null && git commit -qm "fixture: consistency entries" >/dev/null
assert_exit "a checked plan whose closure is unchanged stays done" 1 "$SCRIPT_DIR/lv-list-consistency.sh" PLN-013
printf '\n## Amendments\n\n### A-1 (BUG-099): the CLI takes a --dry-run flag\n' >> plans/PLN-004-cli/plan.md
git add -A >/dev/null && git commit -qm "spec: amend PLN-004" >/dev/null
cand=$("$SCRIPT_DIR/lv-list-consistency.sh" PLN-013 || true)
assert_contains "amending a dependency makes the pass outstanding again" "PLN-013-done" "$cand"
assert_contains "and says which plan moved" "amended since the last pass — PLN-004" "$cand"
printf '\n> **Checked:** 2026-08-02 — closure: PLN-004\n' >> plans/PLN-013-done/plan.md
git add -A >/dev/null && git commit -qm "consistency: re-checked" >/dev/null
assert_exit "a fresh entry settles it" 1 "$SCRIPT_DIR/lv-list-consistency.sh" PLN-013

# A client's LVI-001..007: `## Lane` writes its own `> **Checked:**` line, and
# below `## Consistency` it was read as the pass, dated to the lane commit.
printf '\n## Lane\n> **Checked:** 2026-08-03 — downgraded to the normal lane\n' >> plans/PLN-013-done/plan.md
git add -A >/dev/null && git commit -qm "lane: downgraded" >/dev/null
printf '\n### A-2 (BUG-100): the CLI prints its version\n' >> plans/PLN-004-cli/plan.md
git add -A >/dev/null && git commit -qm "spec: amend PLN-004 again" >/dev/null
python3 - plans/PLN-013-done/plan.md <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
s=s.replace("\n## Lane\n", "\n> **Checked:** 2026-08-04 — closure: PLN-004\n\n## Lane\n", 1); open(p,"w").write(s)
PY
git add -A >/dev/null && git commit -qm "consistency: re-checked after A-2" >/dev/null
assert_exit "a Lane section's Checked line below it is not the pass" 1 "$SCRIPT_DIR/lv-list-consistency.sh" PLN-013

# ── config reads ───────────────────────────────────────────────────────
section "lv-config-get"

assert_eq "reads a nested scalar" "verdict" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.mode gate)"
assert_eq "falls back to the default" "3" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.maxReviewRounds 3)"
assert_eq "reads a sequence" "2" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.gateTags --list | wc -l | tr -d ' ')"
assert_eq "an absent key uses its default" "gate" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.nothingHere gate)"

# A client's LVI-011/012/016: a ` #` inside a quoted value is text. The note
# was cut at its first CSS selector.
cat >> levain.yml <<'Y'
test_account_note: "open /learners/new, fill input #Form_FirstName and #Form_Age, then save"   # the recipe
plain_with_comment: just text # a comment
single_quoted: 'it''s #1'
hashList:
  - "a #b"   # c
  - plain # d
Y
assert_eq "a double-quoted value keeps its ' #'" "open /learners/new, fill input #Form_FirstName and #Form_Age, then save" "$("$SCRIPT_DIR/lv-config-get.sh" test_account_note)"
assert_eq "an unquoted value still drops its comment" "just text" "$("$SCRIPT_DIR/lv-config-get.sh" plain_with_comment)"
assert_eq "a single-quoted value, '' and all" "it's #1" "$("$SCRIPT_DIR/lv-config-get.sh" single_quoted)"
assert_eq "a list item keeps a quoted ' #'" "a #b|plain" "$("$SCRIPT_DIR/lv-config-get.sh" hashList --list | paste -sd'|' -)"

# ── Summary ────────────────────────────────────────────────────────────
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
