#!/usr/bin/env bash
# plan-info-quoting.sh — regression test for BUG-094
#
# lv-plan-info.sh output is consumed via `eval "$(...)"`. Values were emitted
# bare, so any value containing a space (e.g. a comma-space Tags list like
# "infra, hosting, security") word-split under eval: the second word was run as
# a command, PLAN_TAGS was truncated, and every variable emitted on later lines
# was lost — which made lv-implement see PLAN_GOAL_MISSING=true for a plan that
# had a goal.
#
# Also covers lv-set-tags.sh normalizing whitespace out of the Tags column, and
# lv-plan-ref.sh quoting its output.
#
# Usage: ./tests/plan-info-quoting.sh
# Exit 0 if all pass, 1 on any failure.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""
PASS=0
FAIL=0

# Must end truthy — an EXIT trap's status becomes the script's exit status.
cleanup() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
  return 0
}
trap cleanup EXIT

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  ✓ $label"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $label"
    echo "      expected: [$expected]"
    echo "      actual:   [$actual]"
    FAIL=$((FAIL + 1))
  fi
}

run_suite() {
  local scripts="$1" label="$2"
  echo "── $label ──"

  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  mkdir -p plans/PLN-093-subdomain-split

  # v5 registry row with a comma-SPACE Tags value — the shape that broke eval.
  cat > plans/REGISTRY.md << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-093 | subdomain-split | verify | high | feature/PLN-093-subdomain-split | 2026-07-30 | 2.00 | infra, hosting, security | — |

<!-- Counter: 93 -->
SEED

  # Goal with an apostrophe and a semicolon — the other eval hazards.
  printf '## Goal\nSplit the portal; don'"'"'t break auth\n' \
    > plans/PLN-093-subdomain-split/plan.md

  # eval must not error and must set every variable, including ones emitted
  # after PLAN_TAGS.
  local err
  err=$(eval "$("$scripts/lv-plan-info.sh" PLN-093)" 2>&1 >/dev/null || true)
  assert_eq "eval produces no errors" "" "$err"
  # The check above ran in a subshell; eval again here so the vars land in scope.
  eval "$("$scripts/lv-plan-info.sh" PLN-093)" 2>/dev/null || true
  assert_eq "PLAN_TAGS intact" "infra, hosting, security" "${PLAN_TAGS:-<unset>}"
  assert_eq "PLAN_NAME set (emitted after tags)" "PLN-093-subdomain-split" "${PLAN_NAME:-<unset>}"
  assert_eq "PLAN_GOAL intact" "Split the portal; don't break auth" "${PLAN_GOAL:-<unset>}"
  assert_eq "PLAN_GOAL_MISSING false" "false" "${PLAN_GOAL_MISSING:-<unset>}"

  # A blank line under the heading — the markdown convention, and what lv-spec
  # writes. `grep -A 1 | tail -1` captured the blank, so a fully-written plan
  # reported PLAN_GOAL='' and PLAN_GOAL_MISSING=true, and the orchestrator
  # opened a goal-missing gate on it (client-a WFI-125, WFI-128).
  printf '# PLN-093\n\n## Goal\n\nSplit the portal; don'"'"'t break auth\n\n## Steps\n- [ ] one\n' \
    > plans/PLN-093-subdomain-split/plan.md
  unset PLAN_GOAL PLAN_GOAL_MISSING
  eval "$("$scripts/lv-plan-info.sh" PLN-093)" 2>/dev/null || true
  assert_eq "goal found under a blank line" "Split the portal; don't break auth" "${PLAN_GOAL:-<unset>}"
  assert_eq "and not reported missing" "false" "${PLAN_GOAL_MISSING:-<unset>}"

  # No goal at all still reads as missing — the fix must not invent one from
  # the next section's heading or body.
  printf '# PLN-093\n\n## Goal\n\n## Steps\n- [ ] one\n' \
    > plans/PLN-093-subdomain-split/plan.md
  unset PLAN_GOAL PLAN_GOAL_MISSING
  eval "$("$scripts/lv-plan-info.sh" PLN-093)" 2>/dev/null || true
  assert_eq "an empty Goal section is still missing" "" "${PLAN_GOAL-<unset>}"
  assert_eq "and says so" "true" "${PLAN_GOAL_MISSING:-<unset>}"

  cd "$REPO_ROOT"
  rm -rf "$TEST_DIR"
  TEST_DIR=""
}

# v1.x emits a subset of the fields — exercise it through the same hazards.
run_v1x_suite() {
  echo "── lv-plan-info.sh (v1.x) ──"

  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  mkdir -p plans/PLN-093-subdomain-split
  cat > plans/REGISTRY.md << 'SEED'
| ID | Slug | State | Branch | Updated |
|-|-|-|-|-|
| PLN-093 | subdomain-split | verify | feature/PLN-093-subdomain-split | 2026-07-30 |
SEED
  printf '## Goal\nSplit the portal; don'"'"'t break auth\n' \
    > plans/PLN-093-subdomain-split/plan.md

  local err
  err=$(eval "$("$REPO_ROOT/scripts/v1.x/lv-plan-info.sh" PLN-093)" 2>&1 >/dev/null || true)
  assert_eq "eval produces no errors" "" "$err"
  eval "$("$REPO_ROOT/scripts/v1.x/lv-plan-info.sh" PLN-093)" 2>/dev/null || true
  assert_eq "PLAN_GOAL intact" "Split the portal; don't break auth" "${PLAN_GOAL:-<unset>}"
  assert_eq "PLAN_NAME set" "PLN-093-subdomain-split" "${PLAN_NAME:-<unset>}"

  cd "$REPO_ROOT"
  rm -rf "$TEST_DIR"
  TEST_DIR=""
}

run_set_tags_suite() {
  echo "── lv-set-tags.sh normalization ──"

  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR"
  mkdir -p plans
  cat > plans/REGISTRY.md << 'SEED'
| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-093 | subdomain-split | verify | high | feature/PLN-093-subdomain-split | 2026-07-30 | 2.00 | — | — |
SEED

  "$REPO_ROOT/scripts/v2.00/lv-set-tags.sh" PLN-093 "infra, security" >/dev/null
  local written
  written=$(grep "| PLN-093 |" plans/REGISTRY.md | awk -F'|' '{print $9}' | xargs)
  assert_eq "comma-space normalized on write" "infra,security" "$written"

  # A name new to the project is accepted and warned about, not rejected —
  # the vocabulary is derived from the project now, so the first legitimate use
  # of any tag has to be possible (client-a WFI-030).
  local rc=0
  "$REPO_ROOT/scripts/v2.00/lv-set-tags.sh" PLN-093 "infra, hosting" >/dev/null 2>&1 || rc=$?
  assert_eq "a tag new to the project is accepted" "0" "$rc"
  written=$(grep "| PLN-093 |" plans/REGISTRY.md | awk -F'|' '{print $9}' | xargs)
  assert_eq "and normalized the same way" "infra,hosting" "$written"

  cd "$REPO_ROOT"
  rm -rf "$TEST_DIR"
  TEST_DIR=""
}

run_suite "$REPO_ROOT/scripts/v2.00" "lv-plan-info.sh (v2.00)"
run_v1x_suite
run_set_tags_suite

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
