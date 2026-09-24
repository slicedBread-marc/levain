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

  cat > claude-workflow.yml << 'CFG'
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

# The Build column is the whole point of that file: a PASS is a measurement of
# one tree, and this is no longer that tree.
sed -i.bak "s/$ui_sha/0000000/g" plans/PLN-007-ui/test-progress.md && rm -f plans/PLN-007-ui/test-progress.md.bak
eval "$("$SCRIPT_DIR/lv-manual-gate.sh" PLN-007)"
assert_eq "a PASS recorded against an older build settles nothing" "true" "$GATE"
assert_eq "and nothing is subtracted" "0" "$MANUAL_RESOLVED_RECORD"

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

# ── config reads ───────────────────────────────────────────────────────
section "lv-config-get"

assert_eq "reads a nested scalar" "verdict" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.mode gate)"
assert_eq "falls back to the default" "3" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.maxReviewRounds 3)"
assert_eq "reads a sequence" "2" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.gateTags --list | wc -l | tr -d ' ')"
assert_eq "an absent key uses its default" "gate" "$("$SCRIPT_DIR/lv-config-get.sh" specApproval.nothingHere gate)"

# ── Summary ────────────────────────────────────────────────────────────
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
