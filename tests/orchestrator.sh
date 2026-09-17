#!/usr/bin/env bash
# orchestrator.sh — tests for the orchestrator: locking, gates, dispatch.
#
# Dispatch tests put a STUB `claude` binary first on PATH. It records its argv
# and simulates the state transition a real worker would make, so every bit of
# dispatcher logic is exercised for zero tokens.
#
# Usage: ./tests/orchestrator.sh
# Exit 0 if all pass, 1 otherwise.

set -uo pipefail

# ── Paths ──────────────────────────────────────────────────────────────
LIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_SCRIPTS="$LIB_ROOT/scripts"
SCRIPT_FOLDER=$(awk '{sub(/#.*/, "")} NF >= 2 {folder = $2} END {print folder}' "$LIB_SCRIPTS/version-map.txt")
[ -n "$SCRIPT_FOLDER" ] || { echo "cannot resolve script folder from version-map.txt" >&2; exit 1; }
# WF_TEST_SCRIPT_DIR points the suite at an alternate copy of the scripts —
# used to prove these assertions actually fail against pre-fix code.
SCRIPT_DIR="${WF_TEST_SCRIPT_DIR:-$LIB_SCRIPTS/$SCRIPT_FOLDER}"

TEST_DIR=""
PASS=0
FAIL=0

# ── Helpers ────────────────────────────────────────────────────────────
# Must end truthy — an EXIT trap's status becomes the script's exit status.
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

assert_ok() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  else
    printf '  \033[31m✗\033[0m %s (command failed)\n' "$label"; FAIL=$((FAIL + 1))
  fi
}

assert_fails() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '  \033[31m✗\033[0m %s (expected failure, got success)\n' "$label"; FAIL=$((FAIL + 1))
  else
    printf '  \033[32m✓\033[0m %s\n' "$label"; PASS=$((PASS + 1))
  fi
}

setup_repo() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR" || exit 1
  git init -q
  git config user.email "test@test.com"
  git config user.name "Test"

  mkdir -p plans/briefs bugs/open bugs/triaged bugs/closed .claude

  cat > plans/REGISTRY.md << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|

<!-- Counter: 1 -->
SEED

  cat "$LIB_ROOT/VERSION" > .claude/workflow-version
  git add -A >/dev/null 2>&1
  git commit -qm "seed" >/dev/null 2>&1
}

# Insert a registry row above the counter comment.
registry_add_row() {
  local id="$1" slug="$2" state="${3:-draft}"
  awk -v row="| $id | $slug | $state | — | — | 2026-04-07 | ${SCRIPT_FOLDER#v} | — | — |" '
    /<!-- Counter:/ && !done { print row; done = 1 }
    { print }
  ' plans/REGISTRY.md > plans/REGISTRY.tmp && mv plans/REGISTRY.tmp plans/REGISTRY.md
  mkdir -p "plans/$id-$slug"
  # The `## Review` section is part of the default fixture because `ready` now
  # requires one: wf-registry-update.sh refuses draft→ready for a plan whose
  # plan.md records no verdict (WFI-164). A fixture without it is not a plan
  # any pipeline would advance, so it would test the guard rather than the
  # thing under test. registry_add_row_unreviewed is the one that omits it.
  printf '# %s-%s\n\n## Goal\nTest goal for %s\n\n## Review\n> **2026-04-07 — Plan Review**\n> **Result:** Approved\n' \
    "$id" "$slug" "$id" > "plans/$id-$slug/plan.md"
}

# Same, minus the review — for the guard's own tests.
registry_add_row_unreviewed() {
  registry_add_row "$@"
  printf '# %s-%s\n\n## Goal\nTest goal for %s\n\n## Review\n> Filled by the planner'"'"'s review gate before status is set to Ready.\n>\n> **[date] — Plan Review / Code Review**\n> **Result:** Approved | Approved with notes | Blocked\n' \
    "$1" "$2" "$1" > "plans/$1-$2/plan.md"
}

# Read column n of a registry row, whitespace-trimmed.
registry_col() {
  grep "^| $1 |" plans/REGISTRY.md | head -1 | awk -F'|' -v n="$2" '{print $n}' | xargs
}

# ═══════════════════════════════════════════════════════════════════════
setup_repo

section "Lock basics"

assert_ok "wf-lock.sh is executable" test -x "$SCRIPT_DIR/wf-lock.sh"

# Acquire in a subshell, confirm the lock dir appears while held.
lockroot="$(git rev-parse --git-common-dir)/wf-locks"
(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/wf-lock.sh"
  wf_lock_acquire testlock
  [ -d "$lockroot/testlock" ] || exit 1
)
assert_eq "lock dir created while held" "0" "$?"
assert_eq "lock released on exit" "false" "$([ -d "$lockroot/testlock" ] && echo true || echo false)"

# A dead owner must not wedge the lock.
mkdir -p "$lockroot/stale"
echo "999999" > "$lockroot/stale/pid"       # PID that cannot be alive
date +%s > "$lockroot/stale/ts"
(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/wf-lock.sh"
  WF_LOCK_TIMEOUT=3 wf_lock_acquire stale
) >/dev/null 2>&1
assert_eq "stale lock reclaimed when owner PID is dead" "0" "$?"

# A live owner must block, then time out rather than hang forever.
mkdir -p "$lockroot/busy"
echo $$ > "$lockroot/busy/pid"
date +%s > "$lockroot/busy/ts"
out=$(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/wf-lock.sh"
  WF_LOCK_TIMEOUT=2 WF_LOCK_TTL=9999 wf_lock_acquire busy 2>&1
  echo "rc=$?"
)
assert_eq "live lock blocks and times out" "true" "$(echo "$out" | grep -q 'rc=1' && echo true || echo false)"
rm -rf "$lockroot/busy"

# Re-entrancy: a child that acquires the same lock must not deadlock.
out=$(
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/wf-lock.sh"
  wf_lock_acquire reentrant
  WF_LOCK_TIMEOUT=3 bash -c "source '$SCRIPT_DIR/wf-lock.sh'; wf_lock_acquire reentrant && echo NESTED_OK"
)
assert_eq "re-entrant acquire from a child is a no-op" "NESTED_OK" "$out"

section "Counter is race-free"

# The sharpest edge: two concurrent specs must not be handed the same ID.
# Without the registry lock this collides on essentially every run.
"$SCRIPT_DIR/wf-counter-next.sh" PLN > /tmp/wf-c1.$$ 2>/dev/null &
p1=$!
"$SCRIPT_DIR/wf-counter-next.sh" PLN > /tmp/wf-c2.$$ 2>/dev/null &
p2=$!
wait $p1 $p2
id1=$(cat /tmp/wf-c1.$$); id2=$(cat /tmp/wf-c2.$$)
rm -f /tmp/wf-c1.$$ /tmp/wf-c2.$$
assert_eq "concurrent counter calls yield distinct IDs" "true" \
  "$([ -n "$id1" ] && [ -n "$id2" ] && [ "$id1" != "$id2" ] && echo true || echo false)"
assert_eq "counter advanced by exactly 2" "3" \
  "$(grep -oE 'Counter: [0-9]+' plans/REGISTRY.md | grep -oE '[0-9]+')"

section "Registry writes are portable and column-exact"

registry_add_row PLN-010 alpha draft
registry_add_row PLN-011 beta draft

assert_ok "state update" "$SCRIPT_DIR/wf-registry-update.sh" PLN-010 draft ready
assert_eq "state written to column 4" "ready" "$(registry_col PLN-010 4)"
assert_eq "sibling row untouched" "draft" "$(registry_col PLN-011 4)"

assert_ok "branch update" "$SCRIPT_DIR/wf-registry-update.sh" PLN-010 ready active feature/PLN-010-alpha
assert_eq "branch written to column 6" "feature/PLN-010-alpha" "$(registry_col PLN-010 6)"
assert_eq "state advanced" "active" "$(registry_col PLN-010 4)"

assert_ok "priority set" "$SCRIPT_DIR/wf-set-priority.sh" PLN-010 urgent
assert_eq "priority written to column 5" "urgent" "$(registry_col PLN-010 5)"
assert_eq "branch survived priority write" "feature/PLN-010-alpha" "$(registry_col PLN-010 6)"

assert_ok "branch cleared with '-'" "$SCRIPT_DIR/wf-registry-update.sh" PLN-010 active verify -
assert_eq "branch cleared to em-dash" "—" "$(registry_col PLN-010 6)"

# Prefix-collision guard: PLN-01 must not match PLN-010 / PLN-011.
assert_fails "prefix ID does not match a longer row" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-01 verify testing

section "A plan does not become 'ready' without a review of record (WFI-164)"

# The failure this closes: wf-spec wrote both review rounds, a concurrent
# worker's stash swept the shared checkout before the transition committed, and
# the row went to `ready` over a plan.md holding the bare template placeholder.
registry_add_row_unreviewed PLN-012 unreviewed draft
assert_fails "draft→ready refused with only the template placeholder" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-012 draft ready
assert_eq "row left in draft" "draft" "$(registry_col PLN-012 4)"

assert_ok "WF_ALLOW_UNREVIEWED=1 overrides for migrations" \
  env WF_ALLOW_UNREVIEWED=1 "$SCRIPT_DIR/wf-registry-update.sh" PLN-012 draft ready
assert_eq "override wrote the state" "ready" "$(registry_col PLN-012 4)"

# A row with no plan folder at all is the WFI-053 shape: registry says ready,
# git has never seen the plan.
awk '/<!-- Counter:/ && !d { print "| PLN-013 | ghost | draft | — | — | 2026-04-07 | 2.00 | — | — |"; d=1 } { print }' \
  plans/REGISTRY.md > plans/REGISTRY.tmp && mv plans/REGISTRY.tmp plans/REGISTRY.md
assert_fails "draft→ready refused when the plan folder does not exist" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-013 draft ready

# Every other transition is untouched by the guard.
registry_add_row PLN-014 elsewhere verify
assert_ok "verify→testing unaffected" "$SCRIPT_DIR/wf-registry-update.sh" PLN-014 verify testing

section "A plan does not become 'complete' with its branch merged nowhere (WFI-165)"

# Branch refs are built with plumbing and never checked out: this suite's
# working tree is shared by every section, and a checkout mid-run would move
# files out from under the tests that follow.
git branch develop HEAD >/dev/null 2>&1
# `git mktree` rejects an entry whose name contains a slash, so the blob is
# always `work.txt` — the branch name goes on the ref, not on the file.
_orphan_branch() {
  local name="$1" blob tree commit
  blob=$(printf 'work on %s\n' "$name" | git hash-object -w --stdin)
  tree=$(printf '100644 blob %s\twork.txt\n' "$blob" | git mktree)
  commit=$(git commit-tree "$tree" -p HEAD -m "impl: $name")
  [ -n "$commit" ] || { echo "  _orphan_branch: could not build a commit for $name" >&2; return 1; }
  git branch "$name" "$commit" >/dev/null 2>&1
}

registry_add_row PLN-015 unmerged testing
_orphan_branch feature/PLN-015-unmerged
"$SCRIPT_DIR/wf-registry-update.sh" PLN-015 testing testing feature/PLN-015-unmerged >/dev/null 2>&1

assert_fails "testing→complete refused for a branch merged into nothing" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-015 testing complete -
assert_eq "row left in testing" "testing" "$(registry_col PLN-015 4)"
assert_eq "branch NOT cleared by the refused call" "feature/PLN-015-unmerged" "$(registry_col PLN-015 6)"

assert_ok "WF_ALLOW_UNMERGED=1 overrides" \
  env WF_ALLOW_UNMERGED=1 "$SCRIPT_DIR/wf-registry-update.sh" PLN-015 testing complete -

# Merged: the same transition is allowed. The branch points at develop itself,
# which is the state a feature branch is left in once its merge has landed.
registry_add_row PLN-016 merged testing
git branch feature/PLN-016-merged develop >/dev/null 2>&1
"$SCRIPT_DIR/wf-registry-update.sh" PLN-016 testing testing feature/PLN-016-merged >/dev/null 2>&1
assert_ok "testing→complete allowed once the branch is an ancestor of develop" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-016 testing complete -

# A branch that is GONE is accepted: `git branch -d` refuses an unmerged
# branch, so its absence is evidence, and wf-deploy runs long after wf-test
# removed it.
registry_add_row PLN-018 deleted testing
"$SCRIPT_DIR/wf-registry-update.sh" PLN-018 testing testing feature/PLN-018-deleted >/dev/null 2>&1
assert_ok "testing→complete allowed when the branch no longer exists" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-018 testing complete -

# No branch on the row: nothing to check, nothing to refuse.
registry_add_row PLN-017 branchless testing
assert_ok "testing→complete allowed for a plan with no branch" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-017 testing complete -

git branch -D develop feature/PLN-015-unmerged feature/PLN-016-merged >/dev/null 2>&1 || true

section "'complete' is only ever reached from 'testing' (client-d WFI-003)"

# The WFI-165 branch-merge guard above only fires when the row HAS a branch.
# A never-implemented draft has none, so it slipped through untouched — an
# unattended deploy worker did exactly this to a plan whose plan.md had
# reached the release branch on its own via a planning-only commit (WFI-001).
registry_add_row PLN-026 neverbuilt draft
assert_fails "draft→complete refused even with no branch to check" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-026 draft complete -
assert_eq "row left in draft" "draft" "$(registry_col PLN-026 4)"

assert_ok "WF_ALLOW_UNMERGED=1 still overrides (a plan completed by hand)" \
  env WF_ALLOW_UNMERGED=1 "$SCRIPT_DIR/wf-registry-update.sh" PLN-026 draft complete -

registry_add_row PLN-027 midbuild active
assert_fails "active→complete refused" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-027 active complete -

registry_add_row PLN-028 reviewed ready
assert_fails "ready→complete refused" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-028 ready complete -

section "Code that reached develop outside the pipeline is reported (WFI-155)"

registry_add_row PLN-019 prior ready
printf '## Goal\nCopy the minted token.\n\n**Bug:** BUG-019\n' > plans/PLN-019-prior/plan.md
git branch develop HEAD >/dev/null 2>&1

assert_fails "a clean base reports no prior work" \
  "$SCRIPT_DIR/wf-prior-work.sh" PLN-019

# A spec commit naming the plan is bookkeeping, not a build.
git add plans/PLN-019-prior/plan.md >/dev/null 2>&1
git commit -q -m "spec(PLN-019-prior): plan drafted" -- plans/PLN-019-prior/plan.md >/dev/null 2>&1
git branch -f develop HEAD >/dev/null 2>&1
assert_fails "a plans/-only commit naming the plan is not prior work" \
  "$SCRIPT_DIR/wf-prior-work.sh" PLN-019

# A code commit naming the bug, straight onto develop, is.
mkdir -p src
echo "the prototype that bypassed wf-implement" > src/clipboard.js
git add src/clipboard.js >/dev/null 2>&1
git commit -q -m "fix(BUG-019): copy button writes the minted token" -- src/clipboard.js >/dev/null 2>&1
git branch -f develop HEAD >/dev/null 2>&1

assert_ok "a code commit naming the bug IS prior work" \
  "$SCRIPT_DIR/wf-prior-work.sh" PLN-019
prior_out=$("$SCRIPT_DIR/wf-prior-work.sh" PLN-019 2>&1 || true)
assert_eq "it names the commit subject" "true" \
  "$(printf '%s' "$prior_out" | grep -q 'copy button writes the minted token' && echo true || echo false)"
assert_eq "it says a human decides" "true" \
  "$(printf '%s' "$prior_out" | grep -q 'A human decides' && echo true || echo false)"

git branch -D develop >/dev/null 2>&1 || true

section "Prefix-safe column writes"

# PLN-1 is a strict string prefix of PLN-11, so a regex field match (`$2 ~ id`)
# writes both rows. Only an exact, trimmed comparison gets this right.
registry_add_row PLN-1 gamma draft
registry_add_row PLN-11 delta draft

assert_ok "tags on the short ID" "$SCRIPT_DIR/wf-set-tags.sh" PLN-1 infra
assert_eq "PLN-1 got the tag" "infra" "$(registry_col PLN-1 9)"
assert_eq "PLN-11 tags NOT overwritten by the PLN-1 write" "—" "$(registry_col PLN-11 9)"

assert_ok "deps on the short ID" "$SCRIPT_DIR/wf-set-deps.sh" PLN-1 PLN-011
assert_eq "PLN-1 got the dep" "PLN-011" "$(registry_col PLN-1 10)"
assert_eq "PLN-11 deps NOT overwritten by the PLN-1 write" "—" "$(registry_col PLN-11 10)"

assert_ok "priority on the short ID" "$SCRIPT_DIR/wf-set-priority.sh" PLN-1 urgent
assert_eq "PLN-1 got the priority" "urgent" "$(registry_col PLN-1 5)"
assert_eq "PLN-11 priority NOT overwritten by the PLN-1 write" "—" "$(registry_col PLN-11 5)"

section "Config reader"

cat > claude-workflow.yml << 'YML'
project_slug: "demo"
orchestrator:
  enabled: true
  sweep_interval: 45
  max_concurrent:
    implement: 2
    spec: 1
  models:
    spec: opus
    implement: sonnet
YML

cfg() { bash -c "source '$SCRIPT_DIR/wf-orch-lib.sh'; wf_cfg $1 ${2:-}"; }
assert_eq "top-level scalar"        "demo"   "$(cfg project_slug NONE)"
assert_eq "nested scalar"           "45"     "$(cfg orchestrator.sweep_interval 60)"
assert_eq "two levels deep"         "2"      "$(cfg orchestrator.max_concurrent.implement 1)"
assert_eq "sibling subtree not confused" "opus" "$(cfg orchestrator.models.spec haiku)"
assert_eq "missing key falls back"  "haiku"  "$(cfg orchestrator.models.test haiku)"
assert_eq "missing branch falls back" "5"    "$(cfg orchestrator.nope.nope 5)"

section "Gates"

assert_fails "no gates open initially" "$SCRIPT_DIR/wf-list-gates.sh"

# The question deliberately carries an apostrophe and a semicolon — gate files
# are eval'd, and unquoted values are exactly what BUG-094 was.
assert_ok "open a gate" "$SCRIPT_DIR/wf-gate-open.sh" PLN-010-alpha spec-approval \
  "It's 8 steps; approve?" --context plans/PLN-010-alpha/plan.md --skill wf-spec
assert_ok "probe finds the open gate" "$SCRIPT_DIR/wf-list-gates.sh" PLN-010
assert_fails "probe misses an ungated plan" "$SCRIPT_DIR/wf-list-gates.sh" PLN-011

gate_row=$("$SCRIPT_DIR/wf-list-gates.sh" PLN-010 2>/dev/null)
assert_eq "gate name in probe output" "spec-approval" "$(printf '%s' "$gate_row" | cut -f2)"
assert_eq "question survives quotes and semicolons" "It's 8 steps; approve?" \
  "$(printf '%s' "$gate_row" | cut -f4)"
assert_eq "context recorded" "plans/PLN-010-alpha/plan.md" "$(printf '%s' "$gate_row" | cut -f5)"

# Re-opening the same gate must not reset queue position.
opened_first=$(printf '%s' "$gate_row" | cut -f3)
sleep 1
"$SCRIPT_DIR/wf-gate-open.sh" PLN-010 spec-approval "different wording" >/dev/null 2>&1
opened_again=$("$SCRIPT_DIR/wf-list-gates.sh" PLN-010 2>/dev/null | cut -f3)
assert_eq "re-opening the same gate keeps the original timestamp" "$opened_first" "$opened_again"

# Queue is ranked by what a gate COSTS, not by when it was opened.
#
# A gate's cost is not the minute it takes to answer — it is that minute times
# the number of plans that cannot start until it is. On a dependency chain one
# gate at the root holds everything behind it, and a FIFO queue presents it
# indistinguishably from a gate blocking nothing. PLN-1 declares a dep on
# PLN-011 above, so PLN-011's gate blocks one plan and PLN-010's blocks none —
# even though PLN-010 was opened first.
"$SCRIPT_DIR/wf-gate-open.sh" PLN-011-beta manual-test "does /play feel smooth?" >/dev/null 2>&1
gates=$("$SCRIPT_DIR/wf-list-gates.sh" 2>/dev/null)
assert_eq "costliest gate is first" "PLN-011" "$(printf '%s' "$gates" | head -1 | cut -f1)"
assert_eq "the blocked-closure size is reported" "1" \
  "$(printf '%s' "$gates" | awk -F'\t' '$1 == "PLN-011" { print $6 }')"
assert_eq "a gate blocking nothing reports zero" "0" \
  "$(printf '%s' "$gates" | awk -F'\t' '$1 == "PLN-010" { print $6 }')"
assert_eq "both gates listed" "2" "$(printf '%s\n' "$gates" | wc -l | xargs)"

# Equal cost still breaks oldest-first, so nothing starves.
"$SCRIPT_DIR/wf-gate-open.sh" PLN-010 spec-approval "still?" >/dev/null 2>&1
sleep 1
"$SCRIPT_DIR/wf-gate-open.sh" PLN-012-gamma manual-test "later, also blocking nothing" >/dev/null 2>&1
assert_eq "ties break oldest-first" "PLN-010" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" 2>/dev/null | awk -F'\t' '$6 == 0 { print $1; exit }')"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-012 done >/dev/null 2>&1

assert_ok "close a gate" "$SCRIPT_DIR/wf-gate-close.sh" PLN-010 approved
assert_fails "closed gate no longer probes open" "$SCRIPT_DIR/wf-list-gates.sh" PLN-010
assert_ok "closing an already-closed gate is a no-op" "$SCRIPT_DIR/wf-gate-close.sh" PLN-010
assert_fails "a bad artifact id is rejected" "$SCRIPT_DIR/wf-gate-open.sh" NOPE-1 x "y"

# ── An answer that settles a finding ticks the finding (WFI-233/237) ───────
#
# wf-findings-route.sh routes on checkboxes and cannot read a resolution
# paragraph. A gate answered in full, written up in the same findings.md and
# left unchecked, sent plans with clean builds and green suites back to
# `draft` over decisions already made — twice, on two different plans.
registry_add_row PLN-038 settled ready
cat > "plans/PLN-038-settled/findings.md" <<'FIND'
## Consistency — 2026-09-01

- [ ] **Design**: D7 contradicts the migration story ← ESCALATED
- [ ] **Behavior**: unrelated, still open
FIND
assert_eq "an unchecked finding routes the plan away from clean" "escalated" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-038-settled)"
"$SCRIPT_DIR/wf-gate-open.sh" PLN-038 consistency-migration "D7 or the steps?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-038 "D7 corrected, step 4 widened" \
  --resolves "D7 contradicts" >/dev/null 2>&1
assert_eq "the settled finding is checked off" "1" \
  "$(grep -c '^- \[x\] \*\*Design\*\*' "plans/PLN-038-settled/findings.md" | xargs)"
assert_eq "and the finding that was not settled is left alone" "1" \
  "$(grep -c '^- \[ \] \*\*Behavior\*\*' "plans/PLN-038-settled/findings.md" | xargs)"
assert_eq "so the plan no longer routes as escalated" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-038-settled)"
"$SCRIPT_DIR/wf-gate-open.sh" PLN-038 needs-input "and the rest?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-038 "all of it" --resolves all >/dev/null 2>&1
assert_eq "--resolves all clears what is left" "clean" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-038-settled)"
"$SCRIPT_DIR/wf-gate-open.sh" PLN-038 needs-input "again?" >/dev/null 2>&1
assert_eq "a close with no --resolves warns about what it leaves unchecked" "false" \
  "$("$SCRIPT_DIR/wf-gate-close.sh" PLN-038 "noted" 2>&1 >/dev/null | grep -q 'unchecked finding' && echo true || echo false)"

# ── The resolved slot has no memory; the ledger does (WFI-100) ─────────────
#
# `resolved/<id>.<gate>` is one slot per plan per gate name, and a manual-test
# gate is opened and answered once per test CYCLE. Every cycle overwrote the
# record of the one before it, so a resolution carrying the previous cycle's
# outcome verbatim — an escalation that never happened — was indistinguishable
# from a real one. The state at close time is written down for the same reason.
resolved_dir="$(git rev-parse --show-toplevel)/.claude/orchestrator/gates/resolved"
"$SCRIPT_DIR/wf-gate-open.sh" PLN-019 manual-test "cycle one?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-019 "criteria 1-8 pass" >/dev/null 2>&1
assert_ok "a close records the registry state it happened in" \
  grep -q "^GATE_RESOLVED_STATE=" "$resolved_dir/PLN-019.manual-test"

"$SCRIPT_DIR/wf-gate-open.sh" PLN-019 manual-test "cycle two?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-019 "criterion 8 FAIL, escalated" >/dev/null 2>&1
assert_eq "the slot carries the latest outcome" "1" \
  "$(grep -c "criterion 8 FAIL, escalated" "$resolved_dir/PLN-019.manual-test" | xargs)"
assert_eq "the ledger keeps both cycles" "2" \
  "$(wc -l < "$resolved_dir/PLN-019.manual-test.log" | xargs)"
assert_ok "the earlier outcome is still readable" \
  grep -q "criteria 1-8 pass" "$resolved_dir/PLN-019.manual-test.log"

# The ledger sits beside the slot in the same directory, and the slot is a
# record of KEY='value' lines that every caller evals. A reader that reached the
# ledger instead would eval a tab-separated line — arbitrary execution of a
# human's resolution text.
#
# Asserted on behaviour rather than on the source string it used to match: the
# lookup resolves by artifact NUMBER now (WFI-187), so it globs, and what
# matters is what it will not return.
GATE_STATUS_OUT=$("$SCRIPT_DIR/wf-gate-status.sh" PLN-019 manual-test 2>&1)
assert_eq "gate-status reads the slot's resolution" "criterion 8 FAIL, escalated" \
  "$(printf '%s\n' "$GATE_STATUS_OUT" | grep '^GATE_RESOLUTION=' | cut -d"'" -f2)"
assert_eq "and emits only assignments — never a ledger line" "0" \
  "$(printf '%s\n' "$GATE_STATUS_OUT" | grep -cvE "^[A-Z_]+='.*'$" | xargs)"
assert_eq "the resolver never hands back the .log" "false" \
  "$(bash -c "source '$SCRIPT_DIR/wf-orch-lib.sh'
     f=\$(wf_gate_resolved_file PLN-019 manual-test || true)
     case \"\$f\" in *.log) echo true ;; *) echo false ;; esac")"

# ── A promotion approved at the gate authorizes the promotion (WFI-005) ───
#
# client-b: /wf-attend closed `release-approval` with an approval, the daemon
# dispatched /wf-release a minute later, that run asked wf-autonomy.sh (which
# knows only about STANDING grants), was told no, and re-opened the gate it had
# just been let through — twice, each time quoting a longer commit list so
# dedup saw a new question. The answer existed and nothing on the path from it
# to the merge could read it.
section "Promotion approvals"

PROMO_ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git checkout -q -b develop
git commit -q --allow-empty -m "a commit to promote"
DEV_TIP=$(git rev-parse refs/heads/develop)

assert_fails "no approval of record refuses the promotion" \
  "$SCRIPT_DIR/wf-promote-approval.sh" release

"$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "promote 1 commit?" --skill wf-release >/dev/null 2>&1
assert_eq "the open gate records the commit set it asks about" "$DEV_TIP" \
  "$(grep "^GATE_PROMOTE_TIP=" "$(git rev-parse --show-toplevel)/.claude/orchestrator/gates/RELEASE.gate" | cut -d"'" -f2)"
assert_eq "an open gate is not an answer" "1" \
  "$("$SCRIPT_DIR/wf-promote-approval.sh" release --quiet; echo $?)"

# Prose alone is what WFI-005 had, and it authorizes nothing.
"$SCRIPT_DIR/wf-gate-close.sh" RELEASE "approved" >/dev/null 2>&1
assert_eq "a close with no --decision authorizes nothing" "1" \
  "$("$SCRIPT_DIR/wf-promote-approval.sh" release --quiet; echo $?)"
# The stderr is CAPTURED, then matched — not piped into `grep -q`. The suite
# runs under `pipefail`, and grep -q exits on its first match, so wf-gate-close
# takes SIGPIPE writing the second of its three warning lines: the pipeline's
# status becomes 141 and the assertion reads `false` on a run where the message
# was printed exactly as intended. It failed roughly one run in three, on timing
# alone.
assert_eq "and says so on stderr when it happens" "true" \
  "$("$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "again?" >/dev/null 2>&1
     err=$("$SCRIPT_DIR/wf-gate-close.sh" RELEASE "approved" 2>&1 >/dev/null)
     if printf '%s' "$err" | grep -q 'NOT authorized'; then echo true; else echo false; fi)"

"$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "promote 1 commit?" --skill wf-release >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" RELEASE "approved — ship it" --decision approve >/dev/null 2>&1
assert_ok "--decision approve authorizes the batch it was given for" \
  "$SCRIPT_DIR/wf-promote-approval.sh" release
assert_eq "the decision is in the record a reader can audit" "approve" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" RELEASE release-approval | grep '^GATE_DECISION=' | cut -d"'" -f2)"

# An approval is for a batch, not for the branch forever.
git commit -q --allow-empty -m "work that landed after the answer"
assert_eq "new commits after the answer make it stale, not authorized" "2" \
  "$("$SCRIPT_DIR/wf-promote-approval.sh" release --quiet; echo $?)"

# A rejection is an answer too, and it is not an approval.
"$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "now?" --skill wf-release >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" RELEASE "not yet — staging is down" --decision reject >/dev/null 2>&1
assert_eq "a rejection refuses the promotion" "1" \
  "$("$SCRIPT_DIR/wf-promote-approval.sh" release --quiet; echo $?)"
assert_fails "--decision takes only approve or reject" \
  "$SCRIPT_DIR/wf-gate-close.sh" RELEASE "maybe" --decision perhaps

# Leave the fixture exactly as it was found — later sections make their own
# `develop`, and the empty commits above belong to this one.
git checkout -q "$PROMO_ORIG_BRANCH"
git branch -q -D develop

section "Events"

log_for() { "$SCRIPT_DIR/wf-event.sh" --for "$1" 2>/dev/null; }
assert_eq "gate-open logged" "1" "$(log_for PLN-010 | awk -F'\t' '$2 == "gate-open"' | wc -l | xargs)"
assert_eq "gate-close logged" "1" "$(log_for PLN-010 | awk -F'\t' '$2 == "gate-close"' | wc -l | xargs)"
assert_eq "--for filters by artifact" "1" "$(log_for PLN-011 | wc -l | xargs)"
"$SCRIPT_DIR/wf-event.sh" spawn PLN-011 "implement (sonnet) pid 999" >/dev/null
assert_eq "arbitrary events append" "2" "$(log_for PLN-011 | wc -l | xargs)"

section "Skill unattended contracts"

SKILLS="$LIB_ROOT/skills"
for s in wf-spec wf-implement wf-test; do
  assert_eq "$s declares an Unattended mode section" "1" \
    "$(grep -c '^## Unattended mode' "$SKILLS/$s/SKILL.md" | xargs)"
  assert_eq "$s tells the worker to open a gate" "true" \
    "$(grep -q 'wf-gate-open.sh' "$SKILLS/$s/SKILL.md" && echo true || echo false)"
  assert_eq "$s forbids guessing" "true" \
    "$(grep -qi 'never guess' "$SKILLS/$s/SKILL.md" && echo true || echo false)"
done
# The one gate that must never become [AUTO].
assert_eq "wf-spec keeps approval as a hard gate" "true" \
  "$(grep -q 'spec-approval' "$SKILLS/wf-spec/SKILL.md" && echo true || echo false)"

section "Dispatcher — selection logic (dry run)"

# Enable the orchestrator for the remaining sections.
cat > claude-workflow.yml << 'YML'
project_slug: "demo"
orchestrator:
  enabled: true
  sweep_interval: 1
  max_concurrent:
    spec: 1
    implement: 2
    verify: 2
    test: 1
  models:
    spec: opus
    implement: sonnet
    verify: sonnet
    test: haiku
  max_attempts_per_plan: 2
  max_spawns_per_hour: 20
YML

ORCH="$(git rev-parse --show-toplevel)/.claude/orchestrator"
rm -rf "$ORCH"; mkdir -p "$ORCH/gates" "$ORCH/logs" "$ORCH/attempts"

# Clean slate: one plan per actionable state.
cat > plans/REGISTRY.md << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|

<!-- Counter: 50 -->
SEED
for spec in "PLN-020 aaa ready" "PLN-021 bbb verify" "PLN-022 ccc testing" "PLN-023 ddd active"; do
  # shellcheck disable=SC2086
  set -- $spec
  registry_add_row "$1" "$2" "$3"
done

orch() { "$SCRIPT_DIR/wf-orchestrate.sh" "$@"; }

plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "verify plan selected"    "true" "$(printf '%s' "$plan" | grep -q 'verify PLN-021-bbb'    && echo true || echo false)"
assert_eq "testing plan selected"   "true" "$(printf '%s' "$plan" | grep -q 'test PLN-022-ccc'      && echo true || echo false)"
assert_eq "ready plan selected"     "true" "$(printf '%s' "$plan" | grep -q 'implement PLN-020-aaa' && echo true || echo false)"
assert_eq "active plan selected"    "true" "$(printf '%s' "$plan" | grep -q 'implement PLN-023-ddd' && echo true || echo false)"
# Furthest-along work is dispatched first so WIP does not pile up.
assert_eq "verify dispatched before implement" "true" \
  "$([ "$(printf '%s' "$plan" | grep -n 'verify PLN-021' | cut -d: -f1)" -lt \
       "$(printf '%s' "$plan" | grep -n 'implement PLN-020' | cut -d: -f1)" ] && echo true || echo false)"

# A gate must take the plan out of the running entirely.
"$SCRIPT_DIR/wf-gate-open.sh" PLN-020 spec-approval "approve?" >/dev/null 2>&1
plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "gated plan is skipped" "false" \
  "$(printf '%s' "$plan" | grep -q 'implement PLN-020-aaa' && echo true || echo false)"
assert_eq "ungated plans still dispatch" "true" \
  "$(printf '%s' "$plan" | grep -q 'implement PLN-023-ddd' && echo true || echo false)"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-020 approved >/dev/null 2>&1

# Unmet deps must block dispatch.
registry_add_row PLN-024 eee ready
"$SCRIPT_DIR/wf-set-deps.sh" PLN-024 PLN-023 >/dev/null 2>&1
plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "dep-blocked plan is skipped" "false" \
  "$(printf '%s' "$plan" | grep -q 'implement PLN-024-eee' && echo true || echo false)"

# max_concurrent must cap a role. implement:2 with three eligible plans.
registry_add_row PLN-025 fff ready
"$SCRIPT_DIR/wf-set-deps.sh" PLN-024 — >/dev/null 2>&1
plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "implement capped at max_concurrent 2" "2" \
  "$(printf '%s' "$plan" | grep -c 'would spawn: implement' | xargs)"

# The registry is a file on develop. Any other branch checked out in the main
# worktree means the dispatcher is reading a different, older copy of the state
# machine — client-a's WFI-135: /wf-release parked the shared checkout on
# release, where PLN-051 still read `active` while develop had it `complete`,
# and two wf-implement workers were dispatched at a finished plan within three
# minutes. release and main used to be on the allow-list for exactly the reason
# that turned out to be wrong.
seed_branch=$(git branch --show-current)
git checkout -q -b develop
plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "on develop, the sweep dispatches" "true" \
  "$(printf '%s' "$plan" | grep -q 'would spawn' && echo true || echo false)"
for parked in wf-release-tmp feature/PLN-999-elsewhere someones-session; do
  git checkout -q -b "$parked"
  plan=$(orch --sweep --dry-run 2>/dev/null)
  assert_eq "no dispatch while the checkout is off develop, on '$parked'" "0" \
    "$(printf '%s' "$plan" | grep -c 'would spawn' | xargs)"
  assert_eq "and the pause names the branch it is standing on" "true" \
    "$(printf '%s' "$plan" | grep -q "paused — main worktree is on '$parked'" && echo true || echo false)"
  git checkout -q develop
  git branch -q -D "$parked"
done
plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "back on develop, dispatch resumes on the next sweep" "true" \
  "$(printf '%s' "$plan" | grep -q 'would spawn' && echo true || echo false)"
# Before develop exists there is no other copy to be stale against, so a
# greenfield client is not paused out of the gate.
git checkout -q "$seed_branch"
git branch -q -D develop
plan=$(orch --sweep --dry-run 2>/dev/null)
assert_eq "no develop yet: the branch in front of us IS the registry" "true" \
  "$(printf '%s' "$plan" | grep -q 'would spawn' && echo true || echo false)"

# Disabled by default is the safety posture that matters most.
sed 's/enabled: true/enabled: false/' claude-workflow.yml > cfg.tmp && mv cfg.tmp claude-workflow.yml
assert_fails "sweep refuses to run when disabled" orch --sweep
assert_ok "--force overrides disabled" orch --sweep --dry-run --force
sed 's/enabled: false/enabled: true/' claude-workflow.yml > cfg.tmp && mv cfg.tmp claude-workflow.yml

section "Dispatcher — spawning (stub claude)"

# A stub `claude` first on PATH: records its invocation and simulates the state
# transition a real worker would make. Exercises the whole spawn path for zero
# tokens. STUB_MODE picks the behavior being simulated.
STUB_BIN="$TEST_DIR/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/claude" << STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TEST_DIR/stub-argv.log"
printf 'role=%s artifact=%s unattended=%s\n' "\${WF_ROLE:-}" "\${WF_ARTIFACT:-}" "\${WF_UNATTENDED:-}" >> "$TEST_DIR/stub-env.log"
S="$SCRIPT_DIR"
id=\$(printf '%s' "\${WF_ARTIFACT:-}" | grep -oE '^(PLN|BUG|BRF)-[0-9]+')
case "\${STUB_MODE:-advance}" in
  advance)
    case "\${WF_ROLE:-}" in
      spec)      "\$S/wf-registry-update.sh" "\$id" draft ready   >/dev/null 2>&1 ;;
      implement) st=\$("\$S/wf-plan-info.sh" "\$id" 2>/dev/null | grep "^PLAN_STATE=" | sed "s/PLAN_STATE='//;s/'\$//")
                 "\$S/wf-registry-update.sh" "\$id" "\$st" verify >/dev/null 2>&1 ;;
      verify)    "\$S/wf-registry-update.sh" "\$id" verify testing  >/dev/null 2>&1 ;;
      test)      "\$S/wf-registry-update.sh" "\$id" testing complete >/dev/null 2>&1 ;;
    esac
    ;;
  gate)  "\$S/wf-gate-open.sh" "\$id" manual-test "2 criteria need eyes" >/dev/null 2>&1 ;;
  noop)  : ;;
  fail)  exit 7 ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/claude"
export PATH="$STUB_BIN:$PATH"

assert_eq "stub claude is first on PATH" "$STUB_BIN/claude" "$(command -v claude)"

# --- drive-one, happy path: ready → implement → verify → test → complete
registry_add_row PLN-030 happy ready
rc=0; orch PLN-030 >/dev/null 2>&1 || rc=$?
assert_eq "drive-one exits 0 on completion" "0" "$rc"
assert_eq "plan reached complete" "complete" "$(registry_col PLN-030 4)"
assert_eq "workers ran unattended" "true" \
  "$(grep -q 'unattended=1' "$TEST_DIR/stub-env.log" && echo true || echo false)"
# Seeded at `ready`, so spec is correctly skipped: implement → verify → test.
assert_eq "the three post-spec roles each ran once" "3" \
  "$(grep -cE 'role=(implement|verify|test) artifact=PLN-030' "$TEST_DIR/stub-env.log" | xargs)"
assert_eq "spec did not run for an already-ready plan" "0" \
  "$(grep -cE 'role=spec artifact=PLN-030' "$TEST_DIR/stub-env.log" | xargs)"
assert_eq "model tier passed through for implement" "true" \
  "$(grep -q -- '--model sonnet' "$TEST_DIR/stub-argv.log" && echo true || echo false)"

# --- drive-one, --until stops early
registry_add_row PLN-031 early ready
rc=0; orch PLN-031 --until verify >/dev/null 2>&1 || rc=$?
assert_eq "--until halts at the requested state" "0" "$rc"
assert_eq "state is the requested one" "verify" "$(registry_col PLN-031 4)"

# --- drive-one, blocked on a human → exit 20
registry_add_row PLN-032 gated testing
rc=0; STUB_MODE=gate orch PLN-032 >/dev/null 2>&1 || rc=$?
assert_eq "drive-one exits 20 when a gate opens" "20" "$rc"
assert_ok "the gate is queued for /wf-attend" "$SCRIPT_DIR/wf-list-gates.sh" PLN-032

json=$(STUB_MODE=gate orch PLN-032 --json 2>/dev/null || true)
assert_eq "--json reports blocked-on-human" "true" \
  "$(printf '%s' "$json" | grep -q '"result": "blocked-on-human"' && echo true || echo false)"
assert_eq "--json names the gate" "true" \
  "$(printf '%s' "$json" | grep -q '"name": "manual-test"' && echo true || echo false)"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-032 done >/dev/null 2>&1

# --- drive-one, worker ran but changed nothing → exit 30
registry_add_row PLN-033 stalled ready
rc=0; STUB_MODE=noop orch PLN-033 >/dev/null 2>&1 || rc=$?
assert_eq "drive-one exits 30 when nothing moved" "30" "$rc"

# --- drive-one, worker failed → exit 1
registry_add_row PLN-034 broken ready
rc=0; STUB_MODE=fail orch PLN-034 >/dev/null 2>&1 || rc=$?
assert_eq "drive-one exits 1 on worker failure" "1" "$rc"

# --- attempt budget parks a thrashing plan instead of looping forever
registry_add_row PLN-035 thrash ready
rm -f "$ORCH/attempts/PLN-035".*
STUB_MODE=noop orch PLN-035 >/dev/null 2>&1 || true
STUB_MODE=noop orch PLN-035 >/dev/null 2>&1 || true
# Mark urgent so the sweep evaluates it before implement hits max_concurrent —
# otherwise the cap short-circuits the loop and this plan is never reached.
"$SCRIPT_DIR/wf-set-priority.sh" PLN-035 urgent >/dev/null 2>&1
plan=$(orch --sweep --dry-run 2>/dev/null || true)
assert_eq "the parked plan is not offered for dispatch" "false" \
  "$(printf '%s' "$plan" | grep -q 'implement PLN-035-thrash' && echo true || echo false)"
# A preview must not park anything. Opening a `stuck` gate is a persistent
# mutation that takes the plan out of the pipeline — --dry-run promises to
# "spawn nothing", and a run that leaves a gate behind has done more than
# report. The gate is owed, but only a real sweep may open it.
assert_fails "dry-run does not open the stuck gate" \
  "$SCRIPT_DIR/wf-list-gates.sh" PLN-035
orch --sweep >/dev/null 2>&1 || true
assert_ok "plan over its attempt budget is parked as 'stuck'" \
  "$SCRIPT_DIR/wf-list-gates.sh" PLN-035
assert_eq "the gate names the reason" "stuck" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" PLN-035 2>/dev/null | cut -f2)"

# --- one worker per artifact+role, however many callers ask
#
# The guard is keyed on the artifact NUMBER, not its name: a bug keeps its
# number when it becomes a plan, so BUG-036 and PLN-036-dup are one piece of
# work with two names, and one guard has to cover both (client-a WFI-067).
registry_add_row PLN-036 dup ready
echo $$ > "$ORCH/logs/036-implement.pid"   # pretend a worker is live
rc=0; "$SCRIPT_DIR/wf-spawn.sh" implement PLN-036-dup >/dev/null 2>&1 || rc=$?
assert_eq "second spawn for a live worker is refused (rc 2)" "2" "$rc"
# `consistency`, not `spec`, because PLN-036 is `ready`: the state guard below
# refuses a spec worker at a plan that is past drafting, and this assertion is
# about the PIDFILE being per-role, not about eligibility.
rc=0; "$SCRIPT_DIR/wf-spawn.sh" consistency PLN-036-dup >/dev/null 2>&1 || rc=$?
assert_eq "a different role for the same number still spawns" "0" "$rc"
rc=0; "$SCRIPT_DIR/wf-spawn.sh" implement BUG-036 >/dev/null 2>&1 || rc=$?
assert_eq "the same work under its other name is refused too" "2" "$rc"
rm -f "$ORCH/logs/036-implement.pid" "$ORCH/logs/036-consistency.pid"

# --- a launch that dies before its worker starts is not an attempt
#
# nohup refusing to detach ("can't detach from console") ends the launch before
# `claude` runs at all. wf-spawn.sh used to report that as a healthy spawn — it
# had a PID and exited 0 — so the orchestrator charged an attempt to a plan
# nothing had run on, six times over, and opened `stuck` gates asserting a
# worker had made no progress. Nothing had run (WFI-231, WFI-232).
section "A launch that never started costs no attempt (WFI-231/232)"
registry_add_row PLN-037 launchfail ready
cat > "$STUB_BIN/nohup" <<'STUB'
#!/usr/bin/env bash
echo "nohup: can't detach from console: Inappropriate ioctl for device" >&2
exit 1
STUB
chmod +x "$STUB_BIN/nohup"
rm -f "$ORCH/attempts/PLN-037".* "$ORCH/launch-fails"
rc=0; out=$("$SCRIPT_DIR/wf-spawn.sh" consistency PLN-037-launchfail 2>&1) || rc=$?
assert_eq "wf-spawn reports a pre-start launch failure as rc 3" "3" "$rc"
assert_eq "and says nothing ran" "true" \
  "$(printf '%s' "$out" | grep -q 'before the worker started' && echo true || echo false)"
assert_eq "no pidfile is left behind" "false" \
  "$([ -f "$ORCH/logs/037-consistency.pid" ] && echo true || echo false)"
orch --sweep >/dev/null 2>&1 || true
assert_eq "the sweep charges PLN-037 no attempt" "0" \
  "$(cat "$ORCH/attempts/PLN-037.consistency" 2>/dev/null || echo 0)"
assert_eq "and counts the failure against the daemon instead" "true" \
  "$([ -f "$ORCH/launch-fails" ] && echo true || echo false)"
rm -f "$STUB_BIN/nohup" "$ORCH/launch-fails"
rc=0; "$SCRIPT_DIR/wf-spawn.sh" consistency PLN-037-launchfail >/dev/null 2>&1 || rc=$?
assert_eq "a healthy launch is rc 0 again once nohup works" "0" "$rc"
assert_eq "and a successful spawn clears the daemon's failure count" "false" \
  "$([ -f "$ORCH/launch-fails" ] && echo true || echo false)"
rm -f "$ORCH/logs/037-consistency.pid"

section "Dispatcher — spawning (stub claude), continued"
echo "999999" > "$ORCH/logs/036-implement.pid"  # dead PID
rc=0; "$SCRIPT_DIR/wf-spawn.sh" implement PLN-036-dup --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "a dead pidfile does not block a respawn" "0" "$rc"
rm -f "$ORCH/logs/036-implement.pid"

# An upgrade mid-flight must not double-launch: a pidfile written under the old
# name is adopted rather than ignored.
echo $$ > "$ORCH/logs/PLN-036-dup-implement.pid"
rc=0; "$SCRIPT_DIR/wf-spawn.sh" implement PLN-036-dup >/dev/null 2>&1 || rc=$?
assert_eq "a pre-v5.1 pidfile still guards its worker" "2" "$rc"
assert_eq "and is renamed to the number-keyed form" "true" \
  "$([ -f "$ORCH/logs/036-implement.pid" ] && echo true || echo false)"
rm -f "$ORCH/logs/036-implement.pid" "$ORCH/logs/PLN-036-dup-implement.pid"

section "Board"

"$SCRIPT_DIR/wf-gate-open.sh" PLN-022-ccc manual-test "does /play feel smooth?" >/dev/null 2>&1
echo $$ > "$ORCH/logs/PLN-021-bbb-verify.pid"
board=$("$SCRIPT_DIR/wf-board.sh" --plain 2>/dev/null)

assert_eq "board renders without error" "0" "$?"
assert_eq "running worker shown with its role" "true" \
  "$(printf '%s' "$board" | grep -q 'verify .*PLN-021-bbb' && echo true || echo false)"
assert_eq "open gate shown" "true" \
  "$(printf '%s' "$board" | grep -q 'manual-test .*PLN-022' && echo true || echo false)"
assert_eq "pipeline counts rendered" "true" \
  "$(printf '%s' "$board" | grep -qE '^  (draft|ready|verify|testing) +[0-9]+' && echo true || echo false)"
assert_eq "recent events rendered" "true" \
  "$(printf '%s' "$board" | grep -q 'RECENT' && echo true || echo false)"
assert_eq "board spawns nothing" "0" \
  "$(printf '%s' "$board" | grep -c 'would spawn' | xargs)"

# A dead pidfile must not be reported as a running worker.
echo "999999" > "$ORCH/logs/PLN-099-dead-implement.pid"
board=$("$SCRIPT_DIR/wf-board.sh" --plain 2>/dev/null)
assert_eq "dead worker is not listed as running" "false" \
  "$(printf '%s' "$board" | grep -q 'PLN-099-dead' && echo true || echo false)"
rm -f "$ORCH/logs/PLN-021-bbb-verify.pid" "$ORCH/logs/PLN-099-dead-implement.pid"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-022 done >/dev/null 2>&1

section "Brainstorms — the count, the drift, and the park"

# The backlog these tests build:
#   BRF-101 Exploring, listed          → an incomplete brainstorm
#   BRF-102 Idea, NOT listed           → drift (and an incomplete brainstorm
#                                        the index cannot see)
#   BRF-103 Planned, NOT listed, has a plan → unlisted ON PURPOSE (WFI-028);
#                                        neither counted nor drift
mkdir -p plans/PLN-103-shipped
touch plans/PLN-103-shipped/plan.md
brief() {
  printf '# %s\n\n> **ID:** %s\n> **schema_version:** 4\n> **Status:** %s\n> **Created:** 2026-04-07\n> **Plan:** %s\n\n## Problem\nx\n' \
    "$4" "$1" "$2" "${3:-—}" > "plans/briefs/$1-$5.md"
}
brief BRF-101 Exploring "—" "One idea" one
brief BRF-102 Idea "—" "Two idea" two
brief BRF-103 Planned "[PLN-103](../PLN-103-shipped/plan.md)" "Shipped" shipped
cp "$LIB_ROOT/templates/plans/briefs/INDEX.md" plans/briefs/INDEX.md
"$SCRIPT_DIR/wf-brief-park.sh" BRF-101 --clear >/dev/null 2>&1 || true
# Only BRF-101 gets a row.
awk '/^## Exploring/{print; print "> blurb"; print ""; print "- [BRF-101-one.md](BRF-101-one.md) — One idea"; next}1' \
  plans/briefs/INDEX.md > plans/briefs/INDEX.tmp && mv plans/briefs/INDEX.tmp plans/briefs/INDEX.md

assert_eq "only the listed Idea/Exploring brief is counted" "1" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --count 2>/dev/null)"
assert_eq "a Decided brief is not an incomplete brainstorm" "true" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" 2>/dev/null | grep -qv 'Decided' && echo true || echo false)"
assert_eq "an unlisted brief is reported as drift" "1" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift --count 2>/dev/null)"
assert_eq "and it is BRF-102, not the shipped BRF-103" "true" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift 2>/dev/null | grep -q '^BRF-102' && echo true || echo false)"
assert_eq "a brief whose plan exists is never drift (WFI-028 pruning)" "false" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift 2>/dev/null | grep -q 'BRF-103' && echo true || echo false)"

# The board carries both numbers, and nothing else moved.
board_fields=$("$SCRIPT_DIR/wf-board.sh" --fields 2>/dev/null)
assert_eq "--fields reports brainstorms" "true" \
  "$(printf '%s' "$board_fields" | grep -q 'brainstorms=1' && echo true || echo false)"
assert_eq "--fields reports brainstorms_drift" "true" \
  "$(printf '%s' "$board_fields" | grep -q 'brainstorms_drift=1' && echo true || echo false)"
# Captured first, not piped into `grep -q`: this suite runs under `pipefail`,
# and `grep -q` exits on its first match, SIGPIPEs the board mid-write and
# makes the pipeline status 141 no matter what grep found.
board_plain=$("$SCRIPT_DIR/wf-board.sh" --plain 2>/dev/null)
assert_eq "the board renders a brainstorms line above draft" "true" \
  "$(printf '%s\n' "$board_plain" | grep -qE '^  brainstorms +1' && echo true || echo false)"
assert_eq "and names the drift repair on that line" "true" \
  "$(printf '%s\n' "$board_plain" | grep -q 'not in INDEX.md' && echo true || echo false)"

# Reindex: adds the missing row, leaves the shipped brief pruned.
assert_eq "a dry run exits 2 when there is drift and writes nothing" "2" \
  "$("$SCRIPT_DIR/wf-brainstorm-reindex.sh" >/dev/null 2>&1; echo $?)"
assert_eq "and really wrote nothing" "1" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --count 2>/dev/null)"
"$SCRIPT_DIR/wf-brainstorm-reindex.sh" --apply >/dev/null 2>&1
assert_eq "--apply clears the drift" "0" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift --count 2>/dev/null)"
assert_eq "the reindexed brief now counts" "2" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --count 2>/dev/null)"
assert_eq "the shipped brief was not put back" "false" \
  "$(grep -q 'BRF-103' plans/briefs/INDEX.md && echo true || echo false)"

# Parking: out of the count, into ## Parked, reversible.
assert_eq "parking with no reason is refused" "1" \
  "$("$SCRIPT_DIR/wf-brief-park.sh" BRF-102 >/dev/null 2>&1; echo $?)"
"$SCRIPT_DIR/wf-brief-park.sh" BRF-102 "not this year" >/dev/null 2>&1
assert_eq "a parked brief leaves the count" "1" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --count 2>/dev/null)"
assert_eq "it is not drift either — its row moved, it wasn't deleted" "0" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift --count 2>/dev/null)"
assert_eq "--parked shows it with the recorded reason" "true" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --parked 2>/dev/null | grep -q 'not this year' && echo true || echo false)"
assert_eq "the reason records what it was parked FROM" "true" \
  "$(grep -q 'was Idea' plans/briefs/BRF-102-two.md && echo true || echo false)"
"$SCRIPT_DIR/wf-brief-park.sh" BRF-102 --clear >/dev/null 2>&1
assert_eq "--clear restores the status it had" "true" \
  "$(grep -qE '^> \*\*Status:\*\* Idea$' plans/briefs/BRF-102-two.md && echo true || echo false)"
assert_eq "and it counts again" "2" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --count 2>/dev/null)"
assert_eq "INDEX.md never grows a duplicate row through all of that" "1" \
  "$(grep -c 'BRF-102-two.md](BRF-102-two.md)' plans/briefs/INDEX.md | tr -d ' ')"

# A brief written with YAML frontmatter instead of the template blockquote —
# client-e's BRF-066/067/068 are this shape. Read only the blockquote and its
# status reads "unknown", which files a Decided brief under Idea.
printf -- '---\nname: Frontmatter Brief\nstatus: Decided\nschema_version: 4\n---\n\nbody\n' \
  > plans/briefs/BRF-104-frontmatter.md
assert_eq "a frontmatter brief's status is read, not guessed" "true" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift 2>/dev/null | grep -q '^BRF-104	Decided' && echo true || echo false)"
assert_eq "and its title comes from the frontmatter, not '---'" "true" \
  "$("$SCRIPT_DIR/wf-list-brainstorms.sh" --drift 2>/dev/null | grep -q 'Frontmatter Brief' && echo true || echo false)"
"$SCRIPT_DIR/wf-brainstorm-reindex.sh" --apply >/dev/null 2>&1
assert_eq "it reindexes under Decided, not Idea" "true" \
  "$(awk '/^## /{s=$2} /BRF-104-frontmatter/{print s}' plans/briefs/INDEX.md | grep -q Decided && echo true || echo false)"
"$SCRIPT_DIR/wf-brief-park.sh" BRF-104 "example" >/dev/null 2>&1
assert_eq "parking rewrites the frontmatter status in place" "true" \
  "$(grep -q '^status: Parked$' plans/briefs/BRF-104-frontmatter.md && echo true || echo false)"
assert_eq "and leaves the frontmatter block valid — note goes after it" "true" \
  "$(awk 'NR==5 && /^---$/' plans/briefs/BRF-104-frontmatter.md | grep -q -- '---' && echo true || echo false)"
"$SCRIPT_DIR/wf-brief-park.sh" BRF-104 --clear >/dev/null 2>&1
assert_eq "--clear restores Decided from the recorded reason" "true" \
  "$(grep -q '^status: Decided$' plans/briefs/BRF-104-frontmatter.md && echo true || echo false)"

# Leave the fixture as this section found it: a Decided brief and an unclaimed
# plan folder are both specable work, and the dispatcher sections below assert
# on exactly how many skip lines a sweep writes.
rm -rf plans/briefs/*.md plans/PLN-103-shipped
git add -A >/dev/null 2>&1; git commit -qm "brainstorm fixtures removed" >/dev/null 2>&1

section "Skills wired up"

for s in wf-board wf-attend wf-orchestrate; do
  assert_ok "$s/SKILL.md exists" test -f "$LIB_ROOT/skills/$s/SKILL.md"
  assert_eq "$s declares frontmatter name" "true" \
    "$(grep -q "^name: $s\$" "$LIB_ROOT/skills/$s/SKILL.md" && echo true || echo false)"
done
# The two rules that keep an autonomous pipeline honest.
assert_eq "wf-attend forbids deciding for the user" "true" \
  "$(grep -qi 'never approve, pass, or reject on the user' "$LIB_ROOT/skills/wf-attend/SKILL.md" && echo true || echo false)"
assert_eq "wf-orchestrate refuses to self-enable" "true" \
  "$(grep -qi 'do \*\*not\*\* flip it to `true`' "$LIB_ROOT/skills/wf-orchestrate/SKILL.md" && echo true || echo false)"

section "wf-claim --list, and the /wf-claim verb"

registry_add_row PLN-907 listed ready

assert_eq "no claims reads as none" "No live claims." \
  "$("$SCRIPT_DIR/wf-claim.sh" --list 2>&1)"

# A claim of our own, and one held by a live sibling process.
"$SCRIPT_DIR/wf-claim.sh" PLN-907 >/dev/null 2>&1
out=$("$SCRIPT_DIR/wf-claim.sh" --list 2>&1)
case "$out" in *"PLN-907-listed"*) r=1 ;; *) r=0 ;; esac
assert_eq "a held artifact is listed by name and state" "1" "$r"
case "$out" in *"← yours"*) r=1 ;; *) r=0 ;; esac
assert_eq "and our own claim is marked as ours" "1" "$r"

# A claim on a number the registry has never heard of must still be reported —
# and it is the case that killed the first cut of --list: `grep` matching
# nothing exits 1, which pipefail promotes and `set -e` turns into a silent
# exit part-way through the listing, hiding every claim after it.
mkdir -p "$(pwd)/.claude/orchestrator/claims/994"
printf '%s\n%s\n' "$(date +%s)" "$$" > ".claude/orchestrator/claims/994/.wf-claim"
out=$("$SCRIPT_DIR/wf-claim.sh" --list 2>&1)
case "$out" in *"994"*) r=1 ;; *) r=0 ;; esac
assert_eq "an artifact with no registry row is still reported" "1" "$r"
case "$out" in *"PLN-907-listed"*) r=1 ;; *) r=0 ;; esac
assert_eq "and does not truncate the rest of the listing" "1" "$r"
rm -rf ".claude/orchestrator/claims/994"

"$SCRIPT_DIR/wf-unclaim.sh" PLN-907 >/dev/null 2>&1
assert_eq "a released claim leaves the listing" "No live claims." \
  "$("$SCRIPT_DIR/wf-claim.sh" --list 2>&1)"

# The verb a human reaches for. It must not grow into a skill that edits plans.
CLAIM_SKILL="$LIB_ROOT/skills/wf-claim/SKILL.md"
assert_ok "the /wf-claim skill exists" test -f "$CLAIM_SKILL"
assert_eq "it is user-invocable" "true" \
  "$(grep -q '^user_invocable: true' "$CLAIM_SKILL" && echo true || echo false)"
assert_eq "it opens on --list" "true" \
  "$(grep -q 'wf-claim.sh --list' "$CLAIM_SKILL" && echo true || echo false)"
assert_eq "it says exit 2 is an answer, not an error" "true" \
  "$(grep -qi 'exit 2 means another live session' "$CLAIM_SKILL" && echo true || echo false)"
assert_eq "it forbids deleting the claim file by hand" "true" \
  "$(grep -qi 'delete a `.wf-claim` file directly' "$CLAIM_SKILL" && echo true || echo false)"
assert_eq "it warns that releasing is a trigger" "true" \
  "$(grep -qi 'flushes any spawn the orchestrator deferred' "$CLAIM_SKILL" && echo true || echo false)"
assert_eq "install.sh lists it" "true" \
  "$(grep -q '/wf-claim ' "$LIB_ROOT/install.sh" && echo true || echo false)"

section "install.sh reports an untracked registry on every deploy"

# The pipeline's state machine must be in git: plan.md, findings.md and
# progress.md are all versioned, and a registry that is not leaves the one file
# indexing them reconstructable only by hand.
#
# install.sh warned about this only inside the block that strips
# `plans/REGISTRY.md` from .gitignore — so it fired ONCE per client, on the
# single deploy that un-ignored it, and never again. Un-ignoring a file does
# not add it. client-i's rule came off in `chore: stop tracking the
# generated workflow harness` and its registry then sat untracked, silently,
# across every deploy from v5.0.15 to v6.9.0.
#
# Driven through a real install rather than a grep, because the bug was the
# nesting and not the message: a grep for the warning text passed the whole time.
INST_DIR=$(mktemp -d)
(
  cd "$INST_DIR" || exit 1
  git init -q . && git commit -q --allow-empty -m init
  "$LIB_ROOT/install.sh" . >/dev/null 2>&1
  sed -i.bak 's/^project_slug:.*/project_slug: "itest"/' claude-workflow.yml
  "$LIB_ROOT/install.sh" . > install-1.log 2>&1
  git add plans/REGISTRY.md && git commit -q -m "track registry"
  "$LIB_ROOT/install.sh" . > install-2.log 2>&1
) >/dev/null 2>&1

# No .gitignore rule was ever present here, so the old nested check could not
# have run at all — this is exactly client-i's state.
assert_eq "an untracked registry is reported" "1" \
  "$(grep -c 'REGISTRY.md is untracked' "$INST_DIR/install-1.log" 2>/dev/null || true)"
assert_eq "and the fix is a command, not a description" "1" \
  "$(grep -c "git add plans/REGISTRY.md" "$INST_DIR/install-1.log" 2>/dev/null || true)"
assert_eq "a tracked registry is not reported" "0" \
  "$(grep -c 'REGISTRY.md is untracked' "$INST_DIR/install-2.log" 2>/dev/null || true)"
rm -rf "$INST_DIR"

section "Deployed entry-point contract"

WF_TMPL="$LIB_ROOT/templates/WORKFLOW.md"
assert_ok "templates/WORKFLOW.md exists" test -f "$WF_TMPL"
assert_eq "install.sh generates it into the client root" "true" \
  "$(grep -q 'templates/WORKFLOW.md" | atomic_write "$TARGET_DIR/WORKFLOW.md"' "$LIB_ROOT/install.sh" && echo true || echo false)"
assert_eq "install.sh substitutes both placeholders" "true" \
  "$(grep -q '{{workflow_version}}' "$LIB_ROOT/install.sh" && grep -q '{{project_slug}}' "$LIB_ROOT/install.sh" && echo true || echo false)"

# An external agent reads this file to learn how to drive the pipeline; every
# exit code must be documented or the contract is unusable.
for code in '`0`' '`20`' '`30`' '`1`'; do
  assert_eq "WORKFLOW.md documents exit $code" "true" \
    "$(grep -qF "| $code |" "$WF_TMPL" && echo true || echo false)"
done
assert_eq "WORKFLOW.md warns against retrying on 20" "true" \
  "$(grep -qi 'do not retry' "$WF_TMPL" && echo true || echo false)"
assert_eq "WORKFLOW.md lists the git hooks" "true" \
  "$(grep -q 'post-commit' "$WF_TMPL" && echo true || echo false)"
assert_eq "WORKFLOW.md tells callers to use wf-exec.sh" "true" \
  "$(grep -q 'scripts/wf-exec.sh' "$WF_TMPL" && echo true || echo false)"
assert_eq "install.sh gitignores orchestrator runtime state" "true" \
  "$(grep -q '.claude/orchestrator/' "$LIB_ROOT/install.sh" && echo true || echo false)"

section "Version resolution"

# wf-exec.sh + version-map.txt must be installed for these.
cp "$LIB_SCRIPTS/wf-exec.sh" scripts/wf-exec.sh 2>/dev/null || mkdir -p scripts && cp "$LIB_SCRIPTS/wf-exec.sh" scripts/wf-exec.sh
cp "$LIB_SCRIPTS/version-map.txt" scripts/version-map.txt
mkdir -p "scripts/$SCRIPT_FOLDER"
cp "$SCRIPT_DIR"/*.sh "scripts/$SCRIPT_FOLDER/"
chmod +x scripts/wf-exec.sh "scripts/$SCRIPT_FOLDER"/*.sh

# A probe script reporting which folder it was dispatched from — dropped into
# EVERY mapped folder, so a row that resolves to an older generation is
# measured rather than failing as "script not found".
while read -r _minver folder; do
  case "${_minver:-}" in ''|\#*) continue ;; esac
  mkdir -p "scripts/$folder"
  cat > "scripts/$folder/wf-whichfolder.sh" << 'PROBE'
#!/usr/bin/env bash
basename "$(dirname "$0")"
PROBE
  chmod +x "scripts/$folder/wf-whichfolder.sh"
done < <(sed 's/#.*//' "$LIB_SCRIPTS/version-map.txt")

# Every version-map row must name a folder that actually exists, or dispatch
# fails at runtime for whoever lands on that row.
missing=""
while read -r minver folder; do
  case "$minver" in ''|\#*) continue ;; esac
  [ -d "$LIB_SCRIPTS/$folder" ] || missing="$missing $folder"
done < <(sed 's/#.*//' "$LIB_SCRIPTS/version-map.txt")
assert_eq "every mapped script folder exists" "" "$missing"

# Thresholds must be dotted digits — the same rule wf-exec.sh enforces on input.
bad_rows=$(sed 's/#.*//' "$LIB_SCRIPTS/version-map.txt" \
  | awk 'NF >= 2 && $1 !~ /^[0-9]+(\.[0-9]+)*$/ { print $1 }')
assert_eq "every threshold is dotted digits" "" "$bad_rows"

# Rows must be ascending — wf-exec.sh takes the LAST match, so an out-of-order
# file silently resolves to the wrong folder.
sorted=$(sed 's/#.*//' "$LIB_SCRIPTS/version-map.txt" | awk 'NF >= 2 { print $1 }')
assert_eq "rows are in ascending version order" "$sorted" "$(printf '%s\n' "$sorted" | sort -V)"

# Live WF values seen in the field, plus plausible future ones.
resolves_to() { WF_VERSION="$1" ./scripts/wf-exec.sh wf-whichfolder.sh 2>/dev/null; }
assert_eq "legacy 1.32.13 → v1.x"   "v1.x"  "$(resolves_to 1.32.13)"
assert_eq "legacy 0.00 → v1.x"      "v1.x"  "$(resolves_to 0.00)"
assert_eq "2.00.13 → v2.00"         "v2.00" "$(resolves_to 2.00.13)"
assert_eq "current 2.5.1 → v2.00"   "v2.00" "$(resolves_to 2.5.1)"
# The trap the map header warns about: a 2.10 minor must not fall back to v1.x.
assert_eq "future 2.10.0 → v2.00"   "v2.00" "$(resolves_to 2.10.0)"
assert_eq "future 3.0.0 → v2.00"    "v2.00" "$(resolves_to 3.0.0)"

# A bogus explicit override is a typo — fail loudly rather than route oddly.
assert_fails "non-version WF_VERSION is rejected" \
  env WF_VERSION="—" ./scripts/wf-exec.sh wf-whichfolder.sh
assert_fails "garbage WF_VERSION is rejected" \
  env WF_VERSION="latest" ./scripts/wf-exec.sh wf-whichfolder.sh

# A plan stamped with the registry's em-dash must be treated as UNSTAMPED and
# fall back — not sort above every row and grab the newest folder.
echo "2.5.1" > .claude/workflow-version
registry_add_row PLN-040 dashwf ready
awk -F'|' -v OFS='|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) == "PLN-040" { $8 = " — " } { print }
' plans/REGISTRY.md > r.tmp && mv r.tmp plans/REGISTRY.md
assert_eq "em-dash WF falls back to the project version" "v2.00" \
  "$(./scripts/wf-exec.sh wf-whichfolder.sh PLN-040 2>/dev/null)"

# Same for a blank stamp — the 61 unstamped plans in the field rely on this.
registry_add_row PLN-041 blankwf ready
awk -F'|' -v OFS='|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) == "PLN-041" { $8 = "  " } { print }
' plans/REGISTRY.md > r.tmp && mv r.tmp plans/REGISTRY.md
assert_eq "blank WF falls back to the project version" "v2.00" \
  "$(./scripts/wf-exec.sh wf-whichfolder.sh PLN-041 2>/dev/null)"

# A real stamp still pins, which is the entire point of the column.
registry_add_row PLN-042 pinned ready
awk -F'|' -v OFS='|' '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) == "PLN-042" { $8 = " 1.32.13 " } { print }
' plans/REGISTRY.md > r.tmp && mv r.tmp plans/REGISTRY.md
assert_eq "a stamped plan stays pinned to its generation" "v1.x" \
  "$(./scripts/wf-exec.sh wf-whichfolder.sh PLN-042 2>/dev/null)"

section "Workflow issue reporting"

rm -f WORKFLOW-ISSUES.md
assert_eq "clean client reports zero open" "0" "$("$SCRIPT_DIR/wf-issue.sh" --count)"

# A real report carries a multi-line error and an apostrophe — awk -v cannot
# hold either, which is how the first implementation broke.
multi=$(printf "Error: PLN-097 not found in state 'active'\n  at wf-registry-update.sh:88")
assert_ok "file an issue" "$SCRIPT_DIR/wf-issue.sh" \
  --source wf-implement --expected "active→verify to succeed" --actual "$multi" \
  --context "PLN-097, feature/PLN-097-foo" --notes "Registry already showed verify."
assert_ok "file a second" "$SCRIPT_DIR/wf-issue.sh" \
  --source wf-list-testable.sh --expected "one row per testing plan" --actual "awk: cannot open"

assert_eq "count reflects both, on one line" "2" "$("$SCRIPT_DIR/wf-issue.sh" --count)"
assert_eq "IDs increment" "true" \
  "$(grep -q '^## WFI-001 ' WORKFLOW-ISSUES.md && grep -q '^## WFI-002 ' WORKFLOW-ISSUES.md && echo true || echo false)"
assert_eq "newest is first" "WFI-002" \
  "$(grep -m1 -oE 'WFI-[0-9]+' WORKFLOW-ISSUES.md)"
assert_eq "multi-line error preserved verbatim" "true" \
  "$(grep -q 'at wf-registry-update.sh:88' WORKFLOW-ISSUES.md && echo true || echo false)"
assert_eq "apostrophe survives" "true" \
  "$(grep -q "state 'active'" WORKFLOW-ISSUES.md && echo true || echo false)"
assert_eq "workflow version recorded" "true" \
  "$(grep -q '^\*\*Workflow version:\*\*' WORKFLOW-ISSUES.md && echo true || echo false)"
assert_eq "header survives an append" "true" \
  "$(head -1 WORKFLOW-ISSUES.md | grep -q '^# Workflow Issues' && echo true || echo false)"

# Resolution takes an entry out of the open set without deleting the record.
assert_ok "resolve an issue" "$SCRIPT_DIR/wf-issue.sh" --resolve WFI-001 "fixed in v2.6.0"
assert_eq "open count drops" "1" "$("$SCRIPT_DIR/wf-issue.sh" --count)"
assert_eq "--list shows only open" "1" \
  "$("$SCRIPT_DIR/wf-issue.sh" --list | grep -c '^## WFI-' | xargs)"
assert_eq "--list --all shows both" "2" \
  "$("$SCRIPT_DIR/wf-issue.sh" --list --all | grep -c '^## WFI-' | xargs)"
assert_eq "resolved entry is retained as a record" "true" \
  "$(grep -q 'fixed in v2.6.0' WORKFLOW-ISSUES.md && echo true || echo false)"

assert_fails "missing --actual is rejected" "$SCRIPT_DIR/wf-issue.sh" --source wf-spec
assert_fails "missing --source is rejected" "$SCRIPT_DIR/wf-issue.sh" --actual "boom"

# Concurrent filing must not lose a report — several workers can hit the same
# harness bug at once.
rm -f WORKFLOW-ISSUES.md
"$SCRIPT_DIR/wf-issue.sh" --source a --expected e --actual x1 >/dev/null 2>&1 &
"$SCRIPT_DIR/wf-issue.sh" --source b --expected e --actual x2 >/dev/null 2>&1 &
"$SCRIPT_DIR/wf-issue.sh" --source c --expected e --actual x3 >/dev/null 2>&1 &
wait
assert_eq "three concurrent reports all land" "3" "$("$SCRIPT_DIR/wf-issue.sh" --count)"
assert_eq "no duplicate IDs under concurrency" "3" \
  "$(grep -oE '^## WFI-[0-9]+' WORKFLOW-ISSUES.md | sort -u | wc -l | xargs)"

# Regression: the IDs are zero-padded, so WFI-008 and WFI-009 are read as octal
# unless the increment forces base 10 — which left the heading with no ID at all
# and made the next report collide. Seen live in client-a.
rm -f WORKFLOW-ISSUES.md
"$SCRIPT_DIR/wf-issue.sh" --source seed --expected e --actual x >/dev/null 2>&1
awk '{ sub(/^## WFI-001 /, "## WFI-008 "); print }' WORKFLOW-ISSUES.md > tmp.$$ && mv tmp.$$ WORKFLOW-ISSUES.md
assert_ok "filing after WFI-008 succeeds" "$SCRIPT_DIR/wf-issue.sh" \
  --source wf-spec --expected "no octal" --actual "octal"
assert_eq "the ID after 008 is 009, not blank" "true" \
  "$(grep -q '^## WFI-009 ' WORKFLOW-ISSUES.md && echo true || echo false)"
awk '{ sub(/^## WFI-009 /, "## WFI-019 "); print }' WORKFLOW-ISSUES.md > tmp.$$ && mv tmp.$$ WORKFLOW-ISSUES.md
assert_ok "filing after WFI-019 succeeds" "$SCRIPT_DIR/wf-issue.sh" \
  --source wf-spec --expected "no octal" --actual "octal"
assert_eq "the ID after 019 is 020" "true" \
  "$(grep -q '^## WFI-020 ' WORKFLOW-ISSUES.md && echo true || echo false)"

section "Issue reporting is wired into the skills"

for s in wf-spec wf-implement wf-test wf-verify; do
  assert_eq "$s tells the worker to file harness problems" "true" \
    "$(grep -q 'wf-issue.sh' "$LIB_ROOT/skills/$s/SKILL.md" && echo true || echo false)"
done
assert_eq "the ambient CLAUDE.md rule exists" "true" \
  "$(grep -q 'wf-issue.sh' "$LIB_ROOT/claude-md/workflow-snippet.md" && echo true || echo false)"
assert_eq "WORKFLOW.md documents the channel for external agents" "true" \
  "$(grep -q 'wf-issue.sh' "$LIB_ROOT/templates/WORKFLOW.md" && echo true || echo false)"
# The distinction that keeps this channel signal rather than noise: without an
# explicit "do not file" list, every failing app test becomes a workflow issue.
assert_eq "guidance has a 'File it when' list" "true" \
  "$(grep -q '\*\*File it when:\*\*' "$LIB_ROOT/claude-md/workflow-snippet.md" && echo true || echo false)"
assert_eq "guidance has a 'Do not file' list" "true" \
  "$(grep -q '\*\*Do not file:\*\*' "$LIB_ROOT/claude-md/workflow-snippet.md" && echo true || echo false)"
assert_eq "app build/test failures are excluded by name" "true" \
  "$(grep -qi 'application build or test failures' "$LIB_ROOT/claude-md/workflow-snippet.md" && echo true || echo false)"
assert_eq "plan findings are excluded by name" "true" \
  "$(grep -qi 'findings.md' "$LIB_ROOT/claude-md/workflow-snippet.md" && echo true || echo false)"
assert_ok "library sweep script is executable" test -x "$LIB_ROOT/sweep-issues.sh"

section "Library sweep across clients"

# Two fake clients with their own issue files; WF_DEPLOYMENTS keeps the real
# deployments.txt out of it.
SWEEP_A="$TEST_DIR/client-a"; SWEEP_B="$TEST_DIR/client-b"
mkdir -p "$SWEEP_A" "$SWEEP_B"
printf '%s\n%s\n' "$SWEEP_A" "$SWEEP_B" > "$TEST_DIR/deployments.txt"
export WF_DEPLOYMENTS="$TEST_DIR/deployments.txt"
sweep() { "$LIB_ROOT/sweep-issues.sh" "$@"; }

# Clean clients: no issue files at all.
assert_fails "sweep exits 1 when every client is clean" sweep
assert_eq "count is zero for a client with no issue file" "0" \
  "$(sweep --count | awk -F': ' '$1 == "client-a" { print $2 }')"

mk_issue() {  # <dir> <id> <status>
  local d="$1" id="$2" status="$3"
  [ -f "$d/WORKFLOW-ISSUES.md" ] || printf '# Workflow Issues\n\n<!-- New entries are inserted directly below this line, newest first. -->\n' > "$d/WORKFLOW-ISSUES.md"
  printf '\n## %s — wf-implement — 2026-07-31T00:00:00Z\n\n**Status:** %s\n**Context:** —\n\n**Expected:**\ne\n\n**Actual:**\n```\nboom\n```\n' \
    "$id" "$status" >> "$d/WORKFLOW-ISSUES.md"
}
mk_issue "$SWEEP_A" WFI-001 open
mk_issue "$SWEEP_B" WFI-001 open
mk_issue "$SWEEP_B" WFI-002 "resolved 2026-07-30 — fixed"

assert_ok "sweep exits 0 when there is work" sweep
assert_eq "per-client open counts"  "1" "$(sweep --count | awk -F': ' '$1 == "client-a" { print $2 }')"
assert_eq "resolved entries are not counted" "1" "$(sweep --count | awk -F': ' '$1 == "client-b" { print $2 }')"
assert_eq "counts are single-valued, not doubled lines" "2" "$(sweep --count | wc -l | xargs)"
assert_eq "output groups by client" "2" \
  "$(sweep 2>/dev/null | grep -c 'client-[ab] (' | xargs)"
# Match on the issue heading, not on words like "fixed" — the sweep's own
# footer help text contains "fixed in vX.Y.Z" and would match anywhere.
assert_eq "default view hides resolved entries" "0" \
  "$(sweep 2>/dev/null | grep -c '^## WFI-002 ' | xargs)"
assert_eq "default view shows the open ones from both clients" "2" \
  "$(sweep 2>/dev/null | grep -c '^## WFI-001 ' | xargs)"
assert_eq "--all reveals resolved entries" "1" \
  "$(sweep --all 2>/dev/null | grep -c '^## WFI-002 ' | xargs)"

# An entry whose BODY quotes a status line is still read by its own status.
#
# The most natural evidence to paste into an Actual block, for a workflow
# issue, is a diff of WORKFLOW-ISSUES.md — which carries `+**Status:** open`
# inside a resolved entry. The listing matched anywhere in the entry and the
# count anchored to the line start, so one run printed client-a's RESOLVED
# WFI-065 and then reported "No open workflow issues" directly underneath it.
cat >> "$SWEEP_A/WORKFLOW-ISSUES.md" << 'PASTED'

## WFI-003 — wf-issue.sh — 2026-08-08T00:00:00Z

**Status:** resolved 2026-08-08 — fixed

**Actual:**
```
A diff of this very file:
+## WFI-999 — wf-spec — 2026-08-01T00:00:00Z
+
+**Status:** open
+
```
PASTED

printf '%s\n%s\n' "$SWEEP_A" "$SWEEP_B" > "$TEST_DIR/deployments.txt"
assert_eq "a resolved entry quoting an open status is not listed" "0" \
  "$(sweep 2>/dev/null | grep -c '^## WFI-003 ' | xargs)"
assert_eq "and is not counted" "1" \
  "$(sweep --count | awk -F': ' '$1 == "client-a" { print $2 }')"
assert_eq "the pasted entry it quotes is not conjured into existence" "0" \
  "$(sweep 2>/dev/null | grep -c '^## WFI-999 ' | xargs)"
assert_eq "--all still shows it" "1" \
  "$(sweep --all 2>/dev/null | grep -c '^## WFI-003 ' | xargs)"
# The count and the listing must never disagree: the count is what the footer
# reports, and a footer contradicting the body above it is how this surfaced.
assert_eq "the footer count equals the entries printed" "true" \
  "$([ "$(sweep 2>/dev/null | grep -c '^## WFI-')" = "$(sweep 2>/dev/null | grep -oE '^[0-9]+ open workflow' | grep -oE '^[0-9]+')" ] && echo true || echo false)"

# A dead path in deployments.txt must be skipped, not fatal — clients get moved.
printf '%s\n%s\n%s\n' "$SWEEP_A" "$TEST_DIR/gone" "$SWEEP_B" > "$TEST_DIR/deployments.txt"
assert_eq "a missing client is skipped, others still counted" "2" \
  "$(sweep --count 2>/dev/null | wc -l | xargs)"
unset WF_DEPLOYMENTS

section "Daemon lifecycle (client-a WFI-006, WFI-012)"

# --stop used to send SIGTERM and print success immediately, but the daemon
# spent nearly all its life in a FOREGROUND `sleep $interval` — and bash defers
# a trap until a foreground child returns. So it kept sweeping for up to a full
# interval after being declared dead, alongside the replacement the operator
# started on the strength of that message.
#
# A long interval is the point: with the fix --stop returns in about a second,
# without it the daemon would outlive this assertion by a hundred.
"$SCRIPT_DIR/wf-orchestrate.sh" --daemon --interval 30 >daemon.log 2>&1 &
daemon_wrapper=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$ORCH/daemon.pid" ] && break
  sleep 0.5
done
daemon_pid=$(cat "$ORCH/daemon.pid" 2>/dev/null || echo "")
assert_eq "daemon wrote a pidfile" "true" \
  "$([ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null && echo true || echo false)"

stop_start=$(date +%s)
"$SCRIPT_DIR/wf-orchestrate.sh" --stop >stop.log 2>&1
stop_elapsed=$(( $(date +%s) - stop_start ))

# Checked HERE, before `wait` — "the daemon is gone" has to be true at the
# moment --stop returns, which is the claim its output makes. Waiting first
# would let the old behavior pass: --stop returned instantly, the daemon kept
# sweeping for the rest of its interval, and only `wait` hid the gap.
assert_eq "the daemon is gone the moment --stop returns" "false" \
  "$([ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null && echo true || echo false)"
assert_eq "--stop returns promptly, not after a whole interval" "true" \
  "$([ "$stop_elapsed" -lt 10 ] && echo true || echo false)"

wait "$daemon_wrapper" 2>/dev/null || true

# The trap was `... exit 0` on INT TERM EXIT: the TERM handler's own exit
# re-entered it through EXIT, logging "stopped" twice and running `rm -f` a
# second time on a pidfile a replacement daemon may by then own.
assert_eq "shutdown is logged exactly once" "1" \
  "$(grep -c 'daemon.*stopped' "$ORCH/events.log" 2>/dev/null | xargs)"
assert_eq "the pidfile is cleared" "false" \
  "$([ -f "$ORCH/daemon.pid" ] && echo true || echo false)"

section "--daemon-status is a read-only query (client-c WFI-033)"

rc=0; out=$("$SCRIPT_DIR/wf-orchestrate.sh" --daemon-status 2>&1) || rc=$?
assert_eq "no daemon → exit 1" "1" "$rc"
assert_eq "and says so" "true" "$(printf '%s' "$out" | grep -q 'not running' && echo true || echo false)"

"$SCRIPT_DIR/wf-orchestrate.sh" --daemon --interval 30 >daemon2.log 2>&1 &
daemon2_wrapper=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -f "$ORCH/daemon.pid" ] && break
  sleep 0.5
done
rc=0; out=$("$SCRIPT_DIR/wf-orchestrate.sh" --daemon-status 2>&1) || rc=$?
assert_eq "live daemon → exit 0" "0" "$rc"
assert_eq "and names the pid" "true" \
  "$(printf '%s' "$out" | grep -q "running (pid $(cat "$ORCH/daemon.pid"))" && echo true || echo false)"

"$SCRIPT_DIR/wf-orchestrate.sh" --stop >/dev/null 2>&1
wait "$daemon2_wrapper" 2>/dev/null || true

# An outgoing daemon must not delete a pidfile it no longer owns.
echo 999999 > "$ORCH/daemon.pid"
"$SCRIPT_DIR/wf-orchestrate.sh" --stop >/dev/null 2>&1
assert_eq "a stale pidfile is cleared, not left behind" "false" \
  "$([ -f "$ORCH/daemon.pid" ] && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Stall is announced once, not every minute (client-a P-008b)"

# A daemon that sweeps, spawns nothing and has no workers live is not idle —
# every candidate is behind a gate or an unmet dep and nothing will change
# until a human acts. The old code wrote one `sweep — spawned 0` per interval
# regardless: ~1,440 identical lines a day, 146 KB in one measured run, whose
# entire content was "nobody has looked yet".
#
# Swap in a one-plan registry so a sweep is instant and the assertion is about
# the stall logic rather than about how long the fixture takes to walk.
cp plans/REGISTRY.md plans/REGISTRY.full
cat > plans/REGISTRY.md << 'STALLSEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-050 | stalled | draft | — | — | 2026-08-02 | 2.00 | — | — |

<!-- Counter: 51 -->
STALLSEED
mkdir -p plans/PLN-050-stalled
printf '# PLN-050\n\n## Goal\nstall fixture\n' > plans/PLN-050-stalled/plan.md
# An unchecked escalated finding is what makes a draft plan SPECABLE, so it
# reaches dispatch and is skipped there. Without it the plan is not a candidate
# at all and the skip path is never exercised.
printf '# Findings\n\n- [ ] **Design**: needs a replan ← ESCALATED\n' > plans/PLN-050-stalled/findings.md
mv "$ORCH/gates" "$ORCH/gates.full" 2>/dev/null || true
mkdir -p "$ORCH/gates"
rm -f "$ORCH/logs"/*.pid "$ORCH/stalled"
rm -rf "$ORCH/skips"
"$SCRIPT_DIR/wf-gate-open.sh" PLN-050-stalled spec-approval "approve?" >/dev/null 2>&1
: > "$ORCH/events.log"

"$SCRIPT_DIR/wf-orchestrate.sh" --daemon --interval 1 >stall.log 2>&1 &
stall_wrapper=$!
sleep 5
"$SCRIPT_DIR/wf-orchestrate.sh" --stop >/dev/null 2>&1
wait "$stall_wrapper" 2>/dev/null || true

assert_eq "an empty sweep writes no sweep event" "0" \
  "$(grep -c 'sweep.*spawned 0' "$ORCH/events.log" 2>/dev/null | xargs)"
assert_eq "stall is announced exactly once across those sweeps" "1" \
  "$(grep -c 'stalled' "$ORCH/events.log" 2>/dev/null | xargs)"
assert_eq "and it names the gate responsible" "true" \
  "$(grep 'stalled' "$ORCH/events.log" 2>/dev/null | grep -q 'PLN-050(spec-approval' && echo true || echo false)"

# client-a WFI-023 — the per-candidate skip line under the same fixture.
# Silencing the sweep summary while every line it summarised still fired once
# per candidate per interval just moved the unbounded growth one level down:
# 1,583 identical `skip PLN-002 spec: gate open` lines in 26 hours, in the same
# run whose stall event was correctly written exactly once.
assert_eq "a standing skip is logged once, not once per sweep" "1" \
  "$(grep -c 'skip.*gate open' "$ORCH/events.log" 2>/dev/null | xargs)"

# Restarting into the SAME situation must stay quiet — otherwise the daemon is
# just re-logging on a longer period.
"$SCRIPT_DIR/wf-orchestrate.sh" --daemon --interval 1 >>stall.log 2>&1 &
stall_wrapper=$!
sleep 3
"$SCRIPT_DIR/wf-orchestrate.sh" --stop >/dev/null 2>&1
wait "$stall_wrapper" 2>/dev/null || true
assert_eq "an unchanged stall is not re-announced" "1" \
  "$(grep -c 'stalled' "$ORCH/events.log" 2>/dev/null | xargs)"
assert_eq "nor is the skip that caused it" "1" \
  "$(grep -c 'skip.*gate open' "$ORCH/events.log" 2>/dev/null | xargs)"

# A CHANGED situation must announce again — suppression is per-situation, not
# once-and-never-again.
registry_add_row PLN-051 alsostalled draft
printf '# Findings\n\n- [ ] **Design**: needs a replan ← ESCALATED\n' > plans/PLN-051-alsostalled/findings.md
"$SCRIPT_DIR/wf-gate-open.sh" PLN-051-alsostalled spec-approval "this one too?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-orchestrate.sh" --daemon --interval 1 >>stall.log 2>&1 &
stall_wrapper=$!
sleep 3
"$SCRIPT_DIR/wf-orchestrate.sh" --stop >/dev/null 2>&1
wait "$stall_wrapper" 2>/dev/null || true
assert_eq "a changed stall is announced again" "2" \
  "$(grep -c 'stalled' "$ORCH/events.log" 2>/dev/null | xargs)"
# A latch per (role, artifact): a NEW gated plan is a new fact and is reported,
# so suppression never hides something that has not been said yet.
assert_eq "a newly gated plan gets its own skip line" "2" \
  "$(grep -c 'skip.*gate open' "$ORCH/events.log" 2>/dev/null | xargs)"

rm -rf "$ORCH/gates"
mv "$ORCH/gates.full" "$ORCH/gates" 2>/dev/null || mkdir -p "$ORCH/gates"
mv plans/REGISTRY.full plans/REGISTRY.md
rm -f "$ORCH/stalled"
rm -rf "$ORCH/skips"

# ═══════════════════════════════════════════════════════════════════════
section "Dry run leaves no trace (client-a WFI-011, WFI-003)"

events_before=$(wc -l < "$ORCH/events.log" 2>/dev/null | xargs)
rm -rf "$ORCH/skips"
out=$("$SCRIPT_DIR/wf-orchestrate.sh" --sweep --dry-run 2>/dev/null || true)
events_after=$(wc -l < "$ORCH/events.log" 2>/dev/null | xargs)
assert_eq "a preview writes nothing to events.log" "$events_before" "$events_after"
# The skip latch is state on disk too — a preview that primes it would silence
# the first real report of whatever it previewed.
assert_eq "and leaves no skip latches behind" "false" \
  "$([ -d "$ORCH/skips" ] && echo true || echo false)"
assert_eq "and says so rather than claiming a dispatch" "true" \
  "$(printf '%s' "$out" | grep -q 'would be dispatched (dry run' && echo true || echo false)"

# sweep() reported its count on stdout, so everything dispatch() and
# wf-spawn.sh printed was captured by the same `n=$(sweep)` — the daemon then
# tested a spawn message as an integer and failed on every sweep that had
# something to report.
assert_eq "the sweep count is an integer, not a spawn message" "true" \
  "$(printf '%s' "$out" | grep -qE '^sweep: [0-9]+ worker' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A worker recognises the claim its dispatcher took out for it (WFI-073/075/076)"

# wf-spawn.sh claims a plan BEFORE launching the worker, naming the worker's
# PID. The worker's own "is this free?" check then had no way to tell that
# claim from an attended human's, so it stood down against itself: wf-test
# exited in ~15s reporting a human who did not exist, and every plan reaching
# testing under the daemon parked after three no-op dispatches.
registry_add_row PLN-900 self-claim active
# The claim keys on the artifact NUMBER and lives under the orchestrator dir,
# not in the plan folder — a brief has no plan folder and still needs claiming
# (WFI-004).
claim_plan="$ORCH/claims/900"
mkdir -p "$claim_plan"

# 1. The dispatcher's claim, recognised through the exported PID.
printf '%s\n%s\n' "$(date +%s)" "$$" > "$claim_plan/.wf-claim"
WF_CLAIM_PID=$$ "$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim --if-free >/dev/null 2>&1
assert_eq "--if-free exits 0 on a claim naming this process (WF_CLAIM_PID)" "0" "$?"

# 2. Same, with the environment lost — ancestry alone must carry it, since the
#    claim names an ancestor of whatever shell ends up running the check.
printf '%s\n%s\n' "$(date +%s)" "$$" > "$claim_plan/.wf-claim"
env -u WF_CLAIM_PID "$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim --if-free >/dev/null 2>&1
assert_eq "--if-free exits 0 on an ancestor's claim with no WF_CLAIM_PID" "0" "$?"

# 3. The guard that must survive all of this: a genuinely foreign live session
#    still blocks. The sleep is a CHILD, never an ancestor, so it is not ours.
sleep 30 & foreign=$!
printf '%s\n%s\n' "$(date +%s)" "$foreign" > "$claim_plan/.wf-claim"
"$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim --if-free >/dev/null 2>&1
assert_eq "--if-free still exits 2 for another live session" "2" "$?"

# 4. A stale WF_CLAIM_PID naming some other process must not grant ownership.
printf '%s\n%s\n' "$(date +%s)" "$foreign" > "$claim_plan/.wf-claim"
WF_CLAIM_PID=999999 "$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim --if-free >/dev/null 2>&1
assert_eq "--if-free ignores a WF_CLAIM_PID that does not match the claim" "2" "$?"

# 5. The same ownership question, asked by the list script: an explicitly
#    dispatched implementer was told its own plan was "processing" and exited.
printf '%s\n%s\n' "$(date +%s)" "$$" > "$claim_plan/.wf-claim"
own_type=$(WF_CLAIM_PID=$$ "$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null \
  | awk -F'\t' '$2 == "PLN-900-self-claim" {print $1}')
assert_eq "wf-list-implementable does not call our own claim 'processing'" "resume" "$own_type"

printf '%s\n%s\n' "$(date +%s)" "$foreign" > "$claim_plan/.wf-claim"
foreign_type=$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null \
  | awk -F'\t' '$2 == "PLN-900-self-claim" {print $1}')
assert_eq "wf-list-implementable still reports a foreign claim as 'processing'" "processing" "$foreign_type"

{ kill "$foreign"; wait "$foreign"; } 2>/dev/null
rm -f "$claim_plan/.wf-claim"

# wf-spawn must hand the PID it stamped on the claim to the worker, or the
# worker has only ancestry to go on.
assert_ok "wf-spawn exports WF_CLAIM_PID to the worker" \
  grep -q "WF_CLAIM_PID" "$SCRIPT_DIR/wf-spawn.sh"

# ═══════════════════════════════════════════════════════════════════════
section "An attended claim records the session, not the shell that ran it (WFI-102)"

# Every tool call in an attended session is its own short-lived process, and a
# sandbox wrapper between it and the session is not a shell — so the ancestor
# walk stops on something that dies within the second. client-a's WFI-102:
# the daemon read a live attended claim as stale, dispatched an unattended
# tester onto the plan a human was testing, and that worker tore down the
# container mid-test and blanked test-progress.md.
sleep 60 & session=$!

# The claim is taken from a subshell that exits immediately — the WFI-102
# shape. What lands on disk must be the session PID, which outlives it.
( CLAUDE_PID=$session "$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim >/dev/null 2>&1 )
assert_eq "the claim records CLAUDE_PID, not the transient caller" \
  "$session" "$(sed -n '2p' "$claim_plan/.wf-claim")"

# And it still reads live to somebody else once that caller is gone. The claim
# names a child of this shell, so neither ancestry nor identity can call it
# ours: this is the daemon's view of a human's claim.
CLAUDE_PID=$$ "$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim --if-free >/dev/null 2>&1
assert_eq "another session still sees that claim as live" "2" "$?"

{ kill "$session"; wait "$session"; } 2>/dev/null

# Dead session, same claim file: the artifact must not stay parked forever.
"$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim --if-free >/dev/null 2>&1
assert_eq "a claim whose session died is reaped" "0" "$?"
rm -f "$claim_plan/.wf-claim"

# WF_SESSION_PID is the escape hatch for a caller that knows its own identity.
( WF_SESSION_PID=4242 "$SCRIPT_DIR/wf-claim.sh" PLN-900-self-claim >/dev/null 2>&1 )
assert_eq "WF_SESSION_PID overrides both CLAUDE_PID and the walk" \
  "4242" "$(sed -n '2p' "$claim_plan/.wf-claim")"
rm -f "$claim_plan/.wf-claim"

section "Test-account keys reach a client's config (WFI-074)"

# The keys lived only in wf-docker-up.sh's source comments: five clients on
# 5.2.4, zero hits for test_account anywhere. A tester kept getting a URL for a
# container with no account, and the fix never reached the config it reads.
assert_ok "config.example.yml carries test_account_command" \
  grep -q "^test_account_command:" "$LIB_ROOT/config.example.yml"
assert_ok "the block has its own '# ── ' header so install.sh can backfill it" \
  grep -q "^# ── Test account" "$LIB_ROOT/config.example.yml"

backfilled=$(awk -v start="# ── Test account" '
  index($0, start) == 1 { on = 1; print; next }
  on && /^# ── / { exit }
  on { print }
' "$LIB_ROOT/config.example.yml" | grep -c "^test_account_")
assert_eq "the extracted block ends with both keys and nothing else" "2" "$backfilled"

assert_ok "install.sh backfills the block into an existing client config" \
  grep -q 'extract_block "# ── Test account"' "$LIB_ROOT/install.sh"

section "A worker is not launched at a state that has already moved (WFI-079)"

# client-a: a gate closed at 15:32:33Z, a sweep spawned a tester at
# 15:32:35Z, and `testing → draft` committed at 15:32:38Z. Inside those two
# seconds the plan was ungated, unclaimed and still reading `testing` — every
# dispatcher guard said go, and the state they were guarding was stale. The
# tester re-ran the whole scope and opened a fresh manual-test gate on a plan
# that had been in draft with five unaddressed findings for four minutes.
#
# wf-spawn re-reads the row with the launch decision already made, so the
# window shrinks from a sweep interval to the gap between grep and exec.
# --dry-run throughout: the guard runs before the dry-run bail-out, and the
# stub worker these would otherwise launch advances the very state under test.
registry_add_row PLN-079 raced testing
rm -f "$ORCH/logs/079-"*.pid

rc=0; "$SCRIPT_DIR/wf-spawn.sh" test PLN-079-raced --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "a tester launches while the plan is still 'testing'" "0" "$rc"

# The exiting session's transition lands. Nothing else changes: no gate, no
# claim — exactly the window that produced the false gate.
"$SCRIPT_DIR/wf-registry-update.sh" PLN-079 testing draft >/dev/null 2>&1
assert_eq "the plan is now 'draft'" "draft" "$(registry_col PLN-079 4)"

rc=0; out=$("$SCRIPT_DIR/wf-spawn.sh" test PLN-079-raced --dry-run 2>&1) || rc=$?
assert_eq "the tester is refused once the state has moved (rc 2)" "2" "$rc"
assert_eq "and says which state turned it away" "true" \
  "$(printf '%s' "$out" | grep -q "draft" && echo true || echo false)"

# rc=2 is 'not mine to do', not a fault — no pidfile is left for the next
# caller to trip over, and the dispatcher reads it as a skip rather than an
# error (no attempt burned).
assert_eq "a refused launch leaves no pidfile" "false" \
  "$([ -f "$ORCH/logs/079-test.pid" ] && echo true || echo false)"

# The role the new state DOES call for still launches — the guard filters by
# role, it does not park the plan.
rc=0; "$SCRIPT_DIR/wf-spawn.sh" spec PLN-079-raced --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "the role the new state calls for still launches" "0" "$rc"

# Every role's allowed set, so a future edit to the table has to be deliberate.
registry_add_row PLN-080 states ready
for pair in "implement:0" "consistency:0" "verify:2" "test:2" "spec:2"; do
  role="${pair%%:*}"; want="${pair##*:}"
  rc=0; "$SCRIPT_DIR/wf-spawn.sh" "$role" PLN-080-states --dry-run >/dev/null 2>&1 || rc=$?
  assert_eq "role '$role' against a 'ready' plan → rc $want" "$want" "$rc"
done

registry_add_row PLN-082 built verify
for pair in "verify:0" "implement:2" "test:2"; do
  role="${pair%%:*}"; want="${pair##*:}"
  rc=0; "$SCRIPT_DIR/wf-spawn.sh" "$role" PLN-082-built --dry-run >/dev/null 2>&1 || rc=$?
  assert_eq "role '$role' against a 'verify' plan → rc $want" "$want" "$rc"
done

# A bug or brief with no registry row is a first spec, and the guard must
# abstain rather than invent a rule for a row it cannot see.
rc=0; "$SCRIPT_DIR/wf-spawn.sh" spec BUG-081 --dry-run >/dev/null 2>&1 || rc=$?
assert_eq "an unspecced bug still reaches a spec worker" "0" "$rc"

# A worker owns no lock it did not acquire itself.
#
# wf-lock.sh marks a held lock with an exported WF_LOCK_HELD_<NAME>=1 and reads
# it back to stay re-entrant. Since Phase 3 fuses its transition and its commit,
# the verify hook fires from inside wf-commit.sh — with `registry` and `commit`
# both held. A worker inheriting those marks would skip the registry lock for
# its whole run, which is the serialization every other worker depends on.
registry_add_row PLN-084 inherit verify
lock_out=$(WF_LOCK_HELD_REGISTRY=1 WF_LOCK_HELD_COMMIT=1 \
  "$SCRIPT_DIR/wf-spawn.sh" verify PLN-084-inherit --dry-run 2>&1) || true
assert_eq "a spawn under a held lock still runs" "true" \
  "$(printf '%s' "$lock_out" | grep -q 'DRY-RUN spawn' && echo true || echo false)"
assert_ok "wf-spawn scrubs inherited lock ownership" \
  grep -q 'WF_LOCK_HELD_\*) unset' "$SCRIPT_DIR/wf-spawn.sh"

# Terminal states turn every role away — an abandoned or complete plan is the
# re-dispatch loop `abandoned` exists to end.
registry_add_row PLN-083 dropped abandoned
for role in spec implement verify test consistency; do
  rc=0; "$SCRIPT_DIR/wf-spawn.sh" "$role" PLN-083-dropped --dry-run >/dev/null 2>&1 || rc=$?
  assert_eq "role '$role' is refused at an abandoned plan" "2" "$rc"
done

section "Skills release their guards after the transition, not before (WFI-079)"

# The other half of the same fix, and the half that actually removes the race.
# An uncommitted transition does not exist to any other session; a gate or a
# claim is absolute while it is up. So the only safe exit order is: commit the
# transition, close the gate, unclaim. Reversed, the plan is unguarded AND
# stale for as long as the commit takes.
#
# Asserted per fenced code block, because a block is what a worker executes as
# one unit. Blocks that release a guard without transitioning anything (the
# stale-claim clearing in the entry menus) carry no ordering to get wrong and
# are not the subject here.
guard_order_ok() {
  awk '
    /^ *```/ { in_block = !in_block; if (in_block) seen_commit = 0; next }
    !in_block { next }
    /wf-registry-update\.sh|wf-commit\.sh/ { seen_commit = 1 }
    /wf-unclaim\.sh|wf-gate-close\.sh/ {
      if (!seen_commit && has_transition_later(NR)) bad = 1
    }
    END { print (bad ? "false" : "true") }
    function has_transition_later(n,   line) {
      # A guard released inside a block that goes on to transition is the bug.
      while ((getline line) > 0) {
        if (line ~ /^ *```/) return 0
        if (line ~ /wf-registry-update\.sh|wf-commit\.sh/) return 1
      }
      return 0
    }
  ' "$1"
}
for skill in wf-test wf-chrome-test wf-verify wf-implement wf-spec wf-consistency; do
  assert_eq "$skill releases no guard above a transition in the same block" "true" \
    "$(guard_order_ok "$LIB_ROOT/skills/$skill/SKILL.md")"
done

# And the exact sequences, for the exits that ran backwards. Only lines that
# actually invoke something — prose naming a script is not a call.
exit_seq() { awk "/$2/,/$3/" "$LIB_ROOT/skills/$1/SKILL.md" | grep 'wf-exec\.sh' \
  | grep -oE 'wf-(registry-update|gate-close|unclaim)\.sh' | paste -sd, -; }

assert_eq "wf-test's pass exit is transition → gate → claim" \
  "wf-registry-update.sh,wf-gate-close.sh,wf-unclaim.sh" \
  "$(exit_seq wf-test '^4\. Move the plan out of .testing' '^5\. Close linked bugs')"

assert_eq "wf-test's findings exit is transition → gate → claim" \
  "wf-registry-update.sh,wf-gate-close.sh,wf-unclaim.sh" \
  "$(exit_seq wf-test '^4\. Determine the route' '^### Order of exit')"

assert_eq "wf-implement moves to verify before it unclaims" \
  "wf-registry-update.sh,wf-unclaim.sh" \
  "$(exit_seq wf-implement '^25\. \*\*Move the plan to' '^27\. \*\*Post completion')"

# Every one of wf-verify's three routes, not just the one that was noticed.
verify_routes=$(awk '/^1\. \*\*`escalated`/,/^After each route/' \
  "$LIB_ROOT/skills/wf-verify/SKILL.md" | grep 'wf-exec\.sh' \
  | grep -oE 'wf-(registry-update|unclaim)\.sh' | paste -sd, -)
assert_eq "all three wf-verify routes commit before unclaiming" \
  "wf-registry-update.sh,wf-unclaim.sh,wf-registry-update.sh,wf-unclaim.sh,wf-registry-update.sh,wf-unclaim.sh" \
  "$verify_routes"

section "A finding fixable only in plan.md never routes to the implementer (WFI-078)"

# PLN-007 got an unescalated Spec finding whose only fix was rewording a row in
# the Tests table — a section wf-implement's Rules forbid it to touch. Verify
# routes unescalated findings to `active`, so the implementer was handed a task
# it was explicitly barred from doing and had to pick a rule to break.
assert_ok "verify escalates every Spec finding" \
  grep -q 'Use `\*\*Spec\*\*:`.*always append.*ESCALATED' \
  "$LIB_ROOT/skills/wf-verify/SKILL.md"

# The example list is what a model pattern-matches on; an unescalated Spec
# finding sitting in it outweighs the rule above.
spec_examples=$(grep -c '^\- \[ \] \*\*Spec\*\*:' "$LIB_ROOT/skills/wf-verify/SKILL.md")
spec_escalated=$(grep -c '^\- \[ \] \*\*Spec\*\*:.*ESCALATED' "$LIB_ROOT/skills/wf-verify/SKILL.md")
assert_eq "no unescalated Spec finding appears in the examples" \
  "$spec_examples" "$spec_escalated"

assert_ok "the escalation test names the file the fix edits" \
  grep -q 'name the file the fix edits' "$LIB_ROOT/skills/wf-verify/SKILL.md"

# And the receiving side, for a finding that arrives misrouted anyway.
assert_ok "the implementer escalates a finding it cannot fix in src/" \
  grep -q 'cannot fix without editing `plan.md` is not yours' \
  "$LIB_ROOT/skills/wf-implement/SKILL.md"

section "No BSD-only in-place sed"

# `sed -i ''` is macOS-only; it fails outright on GNU sed, so any of these
# would break the pipeline the moment it runs anywhere but a Mac.
offenders=$(grep -rln "sed -i ''" "$SCRIPT_DIR"/*.sh 2>/dev/null | while read -r f; do
  # Ignore matches that are only inside comments.
  grep -v '^[[:space:]]*#' "$f" | grep -q "sed -i ''" && basename "$f"
done)
assert_eq "no executable 'sed -i' remains in $SCRIPT_FOLDER" "" "$offenders"

# ═══════════════════════════════════════════════════════════════════════
section "An artifact with no plan folder can still be claimed (WFI-004)"

# client-c: a spec worker dispatched onto BRF-002 could not claim it —
# `wf-claim.sh BRF-002 --if-free` exited 1 with "plan directory not found",
# because the claim lived in a folder the worker had not created yet. The whole
# window between spawn and mkdir was unclaimed, and two spec workers in it both
# pass --if-free.
brf_rc=0
"$SCRIPT_DIR/wf-claim.sh" BRF-002 --if-free >/dev/null 2>&1 || brf_rc=$?
assert_eq "a brief with no plan folder claims cleanly" "0" "$brf_rc"
assert_eq "the claim lands under the artifact's number" "true" \
  "$([ -f "$ORCH/claims/2/.wf-claim" ] && echo true || echo false)"

# The brief and the plan it becomes are one piece of work, so one claim.
foreign2_rc=0
sleep 30 & foreign2=$!
printf '%s\n%s\n' "$(date +%s)" "$foreign2" > "$ORCH/claims/2/.wf-claim"
"$SCRIPT_DIR/wf-claim.sh" PLN-002-durable-state --if-free >/dev/null 2>&1 || foreign2_rc=$?
assert_eq "the plan inherits the brief's claim rather than a fresh one" "2" "$foreign2_rc"

# The list script must not offer work somebody is already specced onto — it
# used to emit bugs and briefs unconditionally, having no folder to check.
mkdir -p bugs/open/BUG-002-claimed
printf '# A claimed bug\n\n> **Severity:** High\n\nBUG-002\n' > bugs/open/BUG-002-claimed/bug.md
offered=$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null | grep -c '^BUG-002' || true)
assert_eq "wf-list-specable withholds a bug under a live claim" "0" "$offered"

{ kill "$foreign2"; wait "$foreign2"; } 2>/dev/null
rm -f "$ORCH/claims/2/.wf-claim"
offered_free=$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null | grep -c '^BUG-002' || true)
assert_eq "and offers it again once the claim is gone" "1" "$offered_free"
rm -rf bugs/open/BUG-002-claimed

# A claim written by a pre-v5.6 worker still counts, or the upgrade itself
# double-books whatever was in flight across it.
registry_add_row PLN-901 legacy-claim active
sleep 30 & legacy_holder=$!
printf '%s\n%s\n' "$(date +%s)" "$legacy_holder" > "plans/PLN-901-legacy-claim/.wf-claim"
legacy_type=$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null \
  | awk -F'\t' '$2 == "PLN-901-legacy-claim" {print $1}')
assert_eq "a pre-v5.6 claim in the plan folder is still honoured" "processing" "$legacy_type"
{ kill "$legacy_holder"; wait "$legacy_holder"; } 2>/dev/null
rm -f "plans/PLN-901-legacy-claim/.wf-claim"

# ═══════════════════════════════════════════════════════════════════════
section "Ticking a criterion does not invalidate an answered gate (WFI-005)"

# client-c: wf-defer-criterion.sh tells a tester to tick a deferred
# criterion in plan.md by hand. The gate ledger hashed the whole file, so the
# tick reported GATE_STALE=true and a plan later routed back to draft would
# re-gate an approval the human had already given — the WFI-047 loop.
registry_add_row PLN-902 fingerprint testing
plan902="plans/PLN-902-fingerprint/plan.md"
{
  printf '## Goal\nProve a tick is not a revision\n\n'
  printf '### Human Test Criteria\n\n#### Manual\n- [ ] Someone external confirms it (external)\n'
} > "$plan902"

"$SCRIPT_DIR/wf-gate-open.sh" PLN-902 spec-approval "approve?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-902 "approved" >/dev/null 2>&1

eval "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-902 spec-approval)"
assert_eq "a freshly closed gate reads as answered" "true" "$GATE_ANSWERED"

# The tick wf-defer-criterion.sh instructs.
sed 's/- \[ \] Someone external/- [x] Someone external/' "$plan902" > "$plan902.tmp" && mv "$plan902.tmp" "$plan902"
eval "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-902 spec-approval)"
assert_eq "ticking a criterion leaves it answered" "true" "$GATE_ANSWERED"
assert_eq "and does not report the plan as changed" "false" "$GATE_STALE"

# A real edit to the specification must still re-open it.
printf '\n## Steps\n1. Something the human never approved\n' >> "$plan902"
eval "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-902 spec-approval)"
assert_eq "an edit to the spec still goes stale" "true" "$GATE_STALE"
assert_eq "and stops reading as answered" "false" "$GATE_ANSWERED"

# ═══════════════════════════════════════════════════════════════════════
section "The consistency done-marker is not a specification change (WFI-151)"

# client-a PLN-077: wf-consistency appended its `## Consistency` record
# after the review had been stamped, and REVIEW_STALE flipped to true with the
# Amendments section still empty. The pass runs on every `ready` plan that
# declares Deps, so it invalidated the verdict — and, by the same fingerprint,
# the closed spec-approval gate — of every plan it touched.
registry_add_row PLN-904 consistency-fp ready
plan904="plans/PLN-904-consistency-fp/plan.md"
{
  printf '## Goal\nProve a done-marker is not a revision\n\n'
  printf '## Consistency\n> Not yet checked.\n\n'
  printf '## Review\n> **Result:** Approved\n'
} > "$plan904"

"$SCRIPT_DIR/wf-gate-open.sh" PLN-904 spec-approval "approve?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-904 "approved" >/dev/null 2>&1
"$SCRIPT_DIR/wf-review-stamp.sh" PLN-904 --no-commit >/dev/null 2>&1

eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-904)"
assert_eq "a freshly stamped review reads as current" "false" "$REVIEW_STALE"

# What wf-consistency writes on exit, per its SKILL and the template.
sed 's/^> Not yet checked\./> **Checked:** 2026-08-15 — closure: PLN-905 — docs: —\n> **Result:** clean/' \
  "$plan904" > "$plan904.tmp" && mv "$plan904.tmp" "$plan904"

eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-904)"
assert_eq "the consistency record leaves the verdict current" "false" "$REVIEW_STALE"
eval "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-904 spec-approval)"
assert_eq "and leaves the approval gate answered" "true" "$GATE_ANSWERED"
assert_eq "and does not report the plan as changed" "false" "$GATE_STALE"

# A consistency pass that actually amends the spec must still go stale — the
# amendment lands in the plan body, which is hashed.
printf '\n## Amendments\n2026-08-15 — list API needs a `before=` parameter\n' >> "$plan904"
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-904)"
assert_eq "a real consistency amendment still goes stale" "true" "$REVIEW_STALE"

# ═══════════════════════════════════════════════════════════════════════
section "The write guard refuses a write into a claimed artifact"

# The claim was only ever read at DISPATCH, so it answered "should I launch a
# worker onto this?" and never "may I write this file?". A session already
# running — attended, or one that never claimed — walked straight into a plan
# another session was driving. wf-guard-write.sh is the PreToolUse answer.
#
# Fail-open is the whole safety property: this runs before EVERY Edit and
# Write in the repo, so anything short of a positively identified foreign live
# claim must exit 0.
registry_add_row PLN-906 guarded ready
guard() {
  printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" \
    | "$SCRIPT_DIR/wf-guard-write.sh" 2>&1
  printf 'rc=%s' "$?"
}
guard_rc() { guard "$1" | sed -n 's/.*rc=\([0-9]*\)$/\1/p'; }

assert_eq "an unclaimed plan is writable" "0" "$(guard_rc "plans/PLN-906-guarded/plan.md")"

# Another live session: a sibling process, which is neither this caller nor any
# ancestor of it — the two things wf_claim_mine recognises as its own.
sleep 30 & other=$!
claim_dir=$(cd "$TEST_DIR" && "$SCRIPT_DIR/wf-claim.sh" PLN-906 --pid "$other" >/dev/null 2>&1; \
            printf '%s' ".claude/orchestrator/claims/906")
printf '%s\n%s\n' "$(date +%s)" "$other" > "$claim_dir/.wf-claim"

out=$(guard "plans/PLN-906-guarded/plan.md")
assert_eq "a foreign live claim blocks the write" "2" "$(printf '%s' "$out" | sed -n 's/.*rc=\([0-9]*\)$/\1/p')"
case "$out" in
  *"PLN-906"*)  ok_guard=1 ;; *) ok_guard=0 ;;
esac
assert_eq "and the message names the artifact" "1" "$ok_guard"
case "$out" in *"--steal"*) ok_guard=1 ;; *) ok_guard=0 ;; esac
assert_eq "and the one command that resolves it" "1" "$ok_guard"

# Everything the guard must wave through while that same claim is live.
assert_eq "a path naming no artifact is untouched" "0" "$(guard_rc "src/Program.cs")"
assert_eq "REGISTRY.md is not any one artifact's" "0" "$(guard_rc "plans/REGISTRY.md")"
assert_eq "a different artifact is unaffected" "0" "$(guard_rc "plans/PLN-905-other/plan.md")"

# The feature worktree is that plan's territory too — a second writer in there
# is the same collision as one in plans/.
assert_eq "the plan's worktree is guarded as well" "2" \
  "$(guard_rc "feature-branches/PLN-906-guarded/src/Thing.cs")"

# Ours, by the same test wf-claim.sh and wf-spawn.sh use. Reading a claim
# written on our own behalf as somebody else's is what parked every plan that
# reached testing (WFI-073, WFI-075) — here it would block our own edits.
printf '%s\n%s\n' "$(date +%s)" "$$" > "$claim_dir/.wf-claim"
assert_eq "our own claim does not block us" "0" "$(guard_rc "plans/PLN-906-guarded/plan.md")"

# A claim whose owner is gone is not a claim.
{ kill "$other"; wait "$other"; } 2>/dev/null
printf '%s\n%s\n' "$(date +%s)" "$other" > "$claim_dir/.wf-claim"
assert_eq "a dead holder's claim does not block" "0" "$(guard_rc "plans/PLN-906-guarded/plan.md")"

# Fail open on anything it cannot read: a guard that blocks on its own bugs
# bricks the editor for the whole project.
assert_eq "malformed payload allows" "0" \
  "$(printf 'not json at all' | "$SCRIPT_DIR/wf-guard-write.sh" >/dev/null 2>&1; echo $?)"
assert_eq "empty payload allows" "0" \
  "$(printf '' | "$SCRIPT_DIR/wf-guard-write.sh" >/dev/null 2>&1; echo $?)"
assert_eq "a payload carrying no path allows" "0" \
  "$(printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' \
     | "$SCRIPT_DIR/wf-guard-write.sh" >/dev/null 2>&1; echo $?)"
rm -f "$claim_dir/.wf-claim"

# ═══════════════════════════════════════════════════════════════════════
section "The promote guard refuses a push or merge behind an open gate (WFI-004, WFI-005, WFI-034)"

# Four separate runs — client-c WFI-032, client-d WFI-004 and WFI-005,
# client-c WFI-034 — each opened its own release-approval/deploy-approval
# gate on a refusal and promoted release or main anyway. A "STOP" sentence in
# the skill did not hold; this hook is the mechanical version.
# The payload's `cwd` is what the guard probes for the current branch, so it
# decides which arm of the merge detection runs. It must be explicit here.
# Without it the guard fell back to "." — the fixture repo, which `git init`
# puts on whatever `init.defaultBranch` says, `main` on the machine this was
# written on. Every `git merge` in the suite therefore read as "a merge
# advancing main", two assertions about unrelated merges failed for a reason
# that had nothing to do with the merges, and the ref-text fallback arm — the
# one that actually had the bug — was never reached by any test at all.
#
# Note the gate files still resolve from the *process* cwd (TEST_DIR), not
# from this, so a probe cwd can point anywhere without disturbing them.
PROMOTE_CWD_DEVELOP="$TEST_DIR/promote-cwd/develop"
PROMOTE_CWD_RELEASE="$TEST_DIR/promote-cwd/release"
PROMOTE_CWD_MAIN="$TEST_DIR/promote-cwd/main"
for b in develop release main; do
  mkdir -p "$TEST_DIR/promote-cwd/$b"
  ( cd "$TEST_DIR/promote-cwd/$b" \
    && git init -qb "$b" . \
    && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init ) >/dev/null 2>&1
done

# promote_guard <command> [probe-cwd]   — defaults to the develop checkout,
# which is where /wf-deploy steps 6 and 12 genuinely run from.
promote_guard() {
  printf '{"tool_name":"Bash","cwd":"%s","tool_input":{"command":"%s"}}' \
    "${2:-$PROMOTE_CWD_DEVELOP}" "$1" \
    | "$SCRIPT_DIR/wf-guard-promote.sh" 2>&1
  printf 'rc=%s' "$?"
}
promote_guard_rc() { promote_guard "$1" "${2:-}" | sed -n 's/.*rc=\([0-9]*\)$/\1/p'; }

assert_eq "no gate open: push release allowed" "0" \
  "$(promote_guard_rc 'git push origin release')"
assert_eq "no gate open: push main allowed" "0" \
  "$(promote_guard_rc 'git push origin main')"

"$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "promote 3 commits?" >/dev/null 2>&1
out=$(promote_guard 'git push origin release')
assert_eq "release-approval open: push release blocked" "2" \
  "$(printf '%s' "$out" | sed -n 's/.*rc=\([0-9]*\)$/\1/p')"
case "$out" in *"promote 3 commits?"*) ok_pg=1 ;; *) ok_pg=0 ;; esac
assert_eq "and the message quotes the gate's own question" "1" "$ok_pg"
case "$out" in *"wf-gate-close.sh RELEASE"*) ok_pg=1 ;; *) ok_pg=0 ;; esac
assert_eq "and names the way out" "1" "$ok_pg"

assert_eq "release-approval open: push main is unaffected (different gate)" "0" \
  "$(promote_guard_rc 'git push origin main')"
assert_eq "release-approval open: push develop is unaffected — routine, unrelated traffic" "0" \
  "$(promote_guard_rc 'git push origin develop')"
assert_eq "release-approval open: a chained command still trips it" "2" \
  "$(promote_guard_rc 'cd release-branches/release && git push origin release')"
assert_eq "release-approval open: an unrelated push is unaffected" "0" \
  "$(promote_guard_rc 'git push origin feature/PLN-010-alpha')"

# The false positive that made an approved deploy unrunnable.
#
# /wf-deploy step 7 is `git merge -X theirs --no-ff release` — a DEPLOY action,
# owned by DEPLOY.gate. The ref-text fallback used to read the word "release"
# there as a RELEASE action, so with a release-approval gate parked (the normal
# resting state after any refused release worker) the deploy's merge into main
# was refused by a gate that has nothing to do with it. Reproduced live against
# client-c, whose release-approval gate had been open since the previous
# afternoon while its deploy was separately approved.
assert_eq "release-approval open: deploy's step-7 release→main merge is unaffected" "0" \
  "$(promote_guard_rc "git merge -X theirs --no-ff release -m release-promote-to-main")"
assert_eq "release-approval open: deploy's step-12 back-merge is unaffected" "0" \
  "$(promote_guard_rc "git merge -X ours main -m sync-bring-completed-plans-back-to-develop")"

# The current-branch arm, which the ref text cannot express: /wf-release step 6
# is `git merge origin/develop` run while checked out on release (WFI-005,
# WFI-007). Nothing on that command line names `release` at all.
assert_eq "release-approval open: step-6 merge in the release checkout blocked" "2" \
  "$(promote_guard_rc 'git merge origin/develop --no-edit' "$PROMOTE_CWD_RELEASE")"
assert_eq "release-approval open: the same merge in the main checkout is unaffected" "0" \
  "$(promote_guard_rc 'git merge origin/develop --no-edit' "$PROMOTE_CWD_MAIN")"

"$SCRIPT_DIR/wf-gate-close.sh" RELEASE "approved" >/dev/null 2>&1
assert_eq "closed: push release allowed again" "0" \
  "$(promote_guard_rc 'git push origin release')"

"$SCRIPT_DIR/wf-gate-open.sh" DEPLOY deploy-approval "promote to main?" >/dev/null 2>&1
assert_eq "deploy-approval open: push main blocked" "2" \
  "$(promote_guard_rc 'git push origin main')"
assert_eq "deploy-approval open: push release is unaffected (different gate)" "0" \
  "$(promote_guard_rc 'git push origin release')"

# WFI-034: the push to main was correctly refused, but the LOCAL merge that
# promotes release into main (step 7) and the back-merge that carries it into
# develop (step 12) are not pushes at all — and it's the second of those that
# actually reached origin, via the develop push this guard deliberately never
# gates. Blocking both merges closes the leak at its source.
assert_eq "deploy-approval open: local release→main merge blocked (step 7)" "2" \
  "$(promote_guard_rc "git merge -X theirs --no-ff release -m release-promote-to-main")"
assert_eq "deploy-approval open: back-merge main→develop blocked (step 12)" "2" \
  "$(promote_guard_rc "git merge -X ours main -m sync-bring-completed-plans-back-to-develop")"
assert_eq "deploy-approval open: wf-release's own develop→release merge is unaffected" "0" \
  "$(promote_guard_rc 'git merge origin/develop --no-edit' "$PROMOTE_CWD_RELEASE")"
assert_eq "deploy-approval open: a feature-branch merge naming neither ref is unaffected" "0" \
  "$(promote_guard_rc 'git merge feature/PLN-030-happy --no-edit')"
assert_eq "deploy-approval open: step-7 merge in the main checkout blocked (current-branch arm)" "2" \
  "$(promote_guard_rc "git merge -X theirs --no-ff release -m release-promote-to-main" "$PROMOTE_CWD_MAIN")"
"$SCRIPT_DIR/wf-gate-close.sh" DEPLOY "approved" >/dev/null 2>&1
assert_eq "closed: both merges allowed again" "0" \
  "$(promote_guard_rc "git merge -X theirs --no-ff release -m release-promote-to-main")"

# Fail open on anything it cannot read.
assert_eq "malformed payload allows" "0" \
  "$(printf 'not json at all' | "$SCRIPT_DIR/wf-guard-promote.sh" >/dev/null 2>&1; echo $?)"
assert_eq "empty payload allows" "0" \
  "$(printf '' | "$SCRIPT_DIR/wf-guard-promote.sh" >/dev/null 2>&1; echo $?)"
assert_eq "a command with no push allows" "0" \
  "$(promote_guard_rc 'git log --oneline release --not main')"

# ═══════════════════════════════════════════════════════════════════════
section "A plan ID collision has a procedure (WFI-011)"

# client-e: BRF-091 would inherit PLN-091, already held by an unrelated
# completed plan. wf-spec forbade the counter and gave no collision rule, so
# the only two moves were overwriting a live plan or departing from the docs.
registry_add_row PLN-903 already-taken complete

eval "$("$SCRIPT_DIR/wf-plan-id.sh" BRF-905)"
assert_eq "a free number is inherited" "PLN-905" "$PLAN_ID"
assert_eq "and says so" "true" "$PLAN_ID_INHERITED"

eval "$("$SCRIPT_DIR/wf-plan-id.sh" BUG-903)"
assert_eq "a taken number is not reused" "false" "$PLAN_ID_INHERITED"
assert_eq "the collision names what held it" "true" \
  "$(printf '%s' "$PLAN_ID_COLLISION" | grep -q 'PLN-903' && echo true || echo false)"
assert_eq "the allocated ID is past every live artifact" "true" \
  "$([ "$((10#${PLAN_ID#*-}))" -gt 903 ] && echo true || echo false)"

# The counter is only a usable fallback if it cannot itself hand out a live
# number — client-e's read 11 while live IDs were at 099.
awk '{sub(/<!-- Counter: [0-9]+ -->/, "<!-- Counter: 11 -->"); print}' plans/REGISTRY.md \
  > plans/REGISTRY.tmp && mv plans/REGISTRY.tmp plans/REGISTRY.md
drifted=$("$SCRIPT_DIR/wf-counter-next.sh" PLN 2>/dev/null)
assert_eq "a counter behind reality advances past it" "true" \
  "$([ "$((10#${drifted#*-}))" -gt 903 ] && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A verify worker may not exit on work it never collected (WFI-012)"

# client-e: the worker exited rc=0 having written two lines — a permission
# warning, then "Waiting for the background test run to complete." It was still
# waiting. findings.md was never written and the plan sat in `verify`, a state
# whose only owner is the worker that just left.
assert_ok "wf-verify forbids backgrounded checks" \
  grep -q 'never a backgrounded Bash call' "$LIB_ROOT/skills/wf-verify/SKILL.md"
assert_ok "wf-verify states what finishing means" \
  grep -q 'You have not finished until' "$LIB_ROOT/skills/wf-verify/SKILL.md"
assert_ok "an uncompletable check is a finding, not an exit" \
  grep -q 'Routing on incomplete evidence is recoverable' "$LIB_ROOT/skills/wf-verify/SKILL.md"

# The same shape one level down (client-a WFI-179): the haiku TEST AGENT came
# back after ~133s with "I'm waiting for the test run to complete. The monitor is
# streaming events from the output log." — no counts, and the dotnet process
# still alive. Rule 5 binds the agents the worker spawns, so its prompt has to
# say so and the worker has to check the reply's shape.
assert_ok "the spawned test agent is told to run in the foreground" \
  grep -q 'RUN IT IN THE FOREGROUND' "$LIB_ROOT/skills/wf-verify/SKILL.md"
assert_ok "and told not to monitor or poll" \
  grep -q 'Do not use Monitor' "$LIB_ROOT/skills/wf-verify/SKILL.md"
assert_ok "a reply with no counts is discarded, not re-spawned" \
  grep -q 'did not run the tests' "$LIB_ROOT/skills/wf-verify/SKILL.md"

# The other line in that log: a permission rule matched by nothing. The
# allow-list now lives in wf-worktree-harness.sh, because a heredoc in the
# skill is something the permission classifier can refuse and did (WFI-015).
# Both files are checked — the skill still explains the rule in prose, and the
# grep below looks only at a literal allow-list entry.
assert_eq "the worktree grants writes through Edit(), not Write()" "" \
  "$(grep -ho '"Write(//\*\*)"' "$LIB_ROOT/skills/wf-implement/SKILL.md" \
       "$SCRIPT_DIR/wf-worktree-harness.sh" | head -1)"
assert_ok "and uses the rule that is actually honoured" \
  grep -q '"Edit(//\*\*)"' "$SCRIPT_DIR/wf-worktree-harness.sh"
assert_ok "the harness script is what writes it, not a heredoc in the skill" \
  grep -q 'settings.local.json' "$SCRIPT_DIR/wf-worktree-harness.sh"
assert_eq "the skill no longer heredocs it into the worktree" "" \
  "$(grep -c "cat > feature-branches.*settings.local.json" "$LIB_ROOT/skills/wf-implement/SKILL.md" | grep -v '^0$' || true)"

# ═══════════════════════════════════════════════════════════════════════
section "An empty registry column does not shift the ones after it"

# wf_registry_rows feeds every wf-list-* script, and the obvious separator is a
# tab — which is IFS *whitespace*, so `IFS=$'\t' read` collapses a run of them
# and an empty column silently hands the next field's value to the wrong
# variable. Legacy 7-column rows (no WF, no Tags, no Deps) are exactly that
# shape: wf-plan-info.sh reported PLAN_WF='—', the Tags value, on every pre-v5
# plan in client-e. Caught by diffing real output, not by a fixture — every
# fixture in this suite writes '—' rather than a blank.
EMPTYCOL="$TEST_DIR/emptycol"
mkdir -p "$EMPTYCOL/plans/PLN-801-legacy" && (
  cd "$EMPTYCOL" && git init -qb develop . && git config user.email t@t && git config user.name t
  { printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n'
    printf '| PLN-801 | legacy | ready |  |  | 2026-07-01 |  |  |  |\n'
    printf '| PLN-802 | modern | ready | urgent | feature/PLN-802-modern | 2026-08-01 | 6.6.0 | infra | PLN-801 |\n'
    printf '\n<!-- Counter: 810 -->\n'
  } > plans/REGISTRY.md
  printf '## Goal\nthe legacy plan goal\n' > plans/PLN-801-legacy/plan.md
) >/dev/null 2>&1

row=$(cd "$EMPTYCOL" && bash -c "source '$SCRIPT_DIR/wf-orch-lib.sh'; wf_registry_rows plans/REGISTRY.md | head -1")
assert_eq "nine fields survive, empties included" "9" \
  "$(printf '%s' "$row" | awk -F'\037' '{print NF}')"
assert_eq "the state is still in field 3" "ready" \
  "$(printf '%s' "$row" | awk -F'\037' '{print $3}')"
assert_eq "an empty WF column reads as empty, not as the Tags value" "" \
  "$(printf '%s' "$row" | awk -F'\037' '{print $7}')"

eval "$(cd "$EMPTYCOL" && "$SCRIPT_DIR/wf-plan-info.sh" PLN-801 2>/dev/null)"
assert_eq "and wf-plan-info reports the empty WF column as empty" "" "$PLAN_WF"
assert_eq "with the columns before it intact" "ready" "$PLAN_STATE"
assert_eq "the goal still comes off plan.md" "the legacy plan goal" "$PLAN_GOAL"

# A fully populated row must still land field-for-field.
eval "$(cd "$EMPTYCOL" && "$SCRIPT_DIR/wf-plan-info.sh" PLN-802 2>/dev/null)"
assert_eq "a full row keeps its WF stamp" "6.6.0" "$PLAN_WF"
assert_eq "its tags" "infra" "$PLAN_TAGS"
assert_eq "and its deps" "PLN-801" "$PLAN_DEPS"

# ═══════════════════════════════════════════════════════════════════════
section "A promotion nothing can authorize is never dispatched"

# client-d and client-c, 2026-09-15: 34 release/deploy workers spawned
# between them, 26 of the 37 autonomy questions they asked were refusals, and
# 17 of those parked a gate. Every one of those workers did the same thing —
# refuse, open an approval gate, unclaim, exit — and the dispatcher could have
# known before spawning any of them. It matters beyond the waste: a refused
# worker is the one most likely to promote anyway (WFI-004, WFI-005, WFI-007,
# WFI-032, WFI-034 are five incidents and five refused workers).
AUTH=$TEST_DIR/autonomy-dispatch
mkdir -p "$AUTH/plans" "$AUTH/.claude"
(
  cd "$AUTH" && git init -qb develop . && git config user.email t@t && git config user.name t
  printf '# Plan Registry\n\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n\n<!-- Counter: 1 -->\n' > plans/REGISTRY.md
  printf 'x\n' > src.txt
  git add -A && git commit -qm seed
  git branch release
  # Shippable work: a commit touching something outside plans/ and bugs/, which
  # is what wf-list-release.sh requires before it calls a release eligible.
  printf 'y\n' > src.txt && git commit -qam "real work"
) >/dev/null 2>&1

auth_cfg() {   # auth_cfg <mode> [standing_for...]
  { printf 'project_slug: "auth-demo"\norchestrator:\n  enabled: true\n  autonomy:\n    mode: %s\n' "$1"
    if [ "$1" = standing ]; then
      printf '    granted_by: "A Tester"\n    granted_on: 2026-01-01\n    expires_on: 2099-01-01\n    max_per_day: 4\n    standing_for:\n'
      shift; for a in "$@"; do printf '      - %s\n' "$a"; done
    fi
  } > "$AUTH/claude-workflow.yml"
}

# Captured and matched in-shell, never piped into `grep -q`: this file runs
# under `pipefail`, and a -q grep exits on its first match, so the sweep takes
# SIGPIPE and the pipeline reports 141 exactly when the thing being asserted
# IS present. The negative cases would still have read correctly, which is what
# makes the mistake worth naming — it fails only in the direction that matters.
auth_dispatches_release() {
  local out
  out=$( cd "$AUTH" && "$SCRIPT_DIR/wf-orchestrate.sh" --sweep --dry-run 2>/dev/null )
  case "$out" in *"would spawn: release RELEASE"*) echo true ;; *) echo false ;; esac
}

# attended is the default and the shipping posture — every promotion stops for
# a human, so there is nothing for an unattended worker to do.
auth_cfg attended
assert_eq "attended: release is not dispatched" "false" "$(auth_dispatches_release)"

# The grant is what makes it dispatchable — and only for the action it names.
auth_cfg standing release
assert_eq "a grant covering release dispatches it" "true" "$(auth_dispatches_release)"

auth_cfg standing deploy
assert_eq "a grant covering only deploy does not dispatch release" "false" "$(auth_dispatches_release)"

# An expired grant is not a grant, and a malformed one authorizes nothing —
# exit 2 is never "proceed", at the dispatcher as much as in the skill.
auth_cfg standing release
sed -i.bak 's/expires_on: 2099-01-01/expires_on: 2020-01-01/' "$AUTH/claude-workflow.yml"
assert_eq "an expired grant does not dispatch" "false" "$(auth_dispatches_release)"
auth_cfg standing release everything
assert_eq "a malformed grant does not dispatch either" "false" "$(auth_dispatches_release)"

# The skip is latched and named, so a real sweep says why once rather than
# every 60 seconds forever — and the probe must not spend the budget it is
# asking about, or the worker it clears the way for finds it gone.
auth_cfg attended
rm -rf "$AUTH/.claude/orchestrator"
( cd "$AUTH" && "$SCRIPT_DIR/wf-orchestrate.sh" --sweep >/dev/null 2>&1 ) || true
( cd "$AUTH" && "$SCRIPT_DIR/wf-orchestrate.sh" --sweep >/dev/null 2>&1 ) || true
AUTH_LOG="$AUTH/.claude/orchestrator/events.log"
# `grep -c` prints 0 and exits 1 on no match, so `|| echo 0` would emit a
# second line and every "0" assertion would compare against "0\n0".
auth_log_count() { awk -v pat="$1" 'index($0, pat) { n++ } END { print n + 0 }' "$AUTH_LOG" 2>/dev/null || echo 0; }
assert_eq "the skip names autonomy as the reason" "true" \
  "$([ "$(auth_log_count 'not authorized unattended')" -gt 0 ] && echo true || echo false)"
assert_eq "and says it once across two sweeps, not once per sweep" "1" \
  "$(auth_log_count 'not authorized unattended')"
assert_eq "no release worker was spawned" "0" \
  "$(auth_log_count "$(printf 'spawn\tRELEASE')")"
assert_eq "and the dispatcher's probe spent none of the grant" "0" \
  "$(auth_log_count 'autonomy-use')"
assert_eq "nor recorded a refusal no skill acted on" "0" \
  "$(auth_log_count 'autonomy-refuse')"

# ── …but an approval at the gate IS something that can authorize it ────────
#
# The pre-flight above reads as "no grant, so nothing to dispatch". client-b
# WFI-005 is what that costs when a human has just answered the gate: the
# approval exists, the dispatcher cannot see it, and the only way it ever
# reaches a worker is the loop of re-opened gates the approval was meant to end.
auth_cfg attended
( cd "$AUTH" && "$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "promote this?" ) >/dev/null 2>&1
assert_eq "an open approval gate does not dispatch" "false" "$(auth_dispatches_release)"
( cd "$AUTH" && "$SCRIPT_DIR/wf-gate-close.sh" RELEASE "approved" ) >/dev/null 2>&1
assert_eq "closing it with prose alone still does not dispatch" "false" "$(auth_dispatches_release)"
( cd "$AUTH" && "$SCRIPT_DIR/wf-gate-open.sh" RELEASE release-approval "promote this?" \
  && "$SCRIPT_DIR/wf-gate-close.sh" RELEASE "approved — ship it" --decision approve ) >/dev/null 2>&1
assert_eq "an approval recorded at the gate dispatches with no grant at all" "true" \
  "$(auth_dispatches_release)"
( cd "$AUTH" && git commit -q --allow-empty -m "work that landed after the answer" ) >/dev/null 2>&1
assert_eq "and stops dispatching once the batch it approved has moved on" "false" \
  "$(auth_dispatches_release)"


# ═══════════════════════════════════════════════════════════════════════
section "The release suite is run by the harness, not typed by the worker"

# WFI-252. /wf-release and /wf-deploy stated the full-suite aggregation
# guarantee as a comment above a {{test_command}} placeholder and left the
# running of it to the worker, so nothing downstream could tell a full run from
# a filtered one. A RELEASE worker reported "474 passed, 0 failed" — one
# assembly — and pushed `release`; the configured suite on that content was
# 3100 tests with 121 failures, all in the E2E assembly it named as passing.
SUITE=$(mktemp -d)
git init -q "$SUITE" >/dev/null
cd "$SUITE" || exit 1
git config user.email t@t.com; git config user.name T
git commit -q --allow-empty -m base
mkdir -p scripts; printf '0.00 v2.00\n' > scripts/version-map.txt

printf 'build_command: "echo building"\ntest_command: "echo 3100 total"\n' > claude-workflow.yml
out=$("$SCRIPT_DIR/wf-suite-run.sh" --label t --build 2>&1); rc=$?
assert_eq "a passing suite exits 0" "0" "$rc"
assert_eq "and says so in a receipt the skill quotes" "true" \
  "$(printf '%s' "$out" | grep -q '^SUITE_RESULT=pass' && echo true || echo false)"
assert_eq "naming the command it actually ran" "true" \
  "$(printf '%s' "$out" | grep -q '^SUITE_CMD=echo 3100 total$' && echo true || echo false)"
assert_eq "and the log holding the whole output" "true" \
  "$([ -f "$(printf '%s' "$out" | sed -n 's/^SUITE_LOG=//p')" ] && echo true || echo false)"

printf 'build_command: "echo b"\ntest_command: "exit 1"\n' > claude-workflow.yml
out=$("$SCRIPT_DIR/wf-suite-run.sh" --label t 2>&1); rc=$?
assert_eq "a failing suite exits 1" "1" "$rc"
assert_eq "and never prints a pass" "true" \
  "$(printf '%s' "$out" | grep -q '^SUITE_RESULT=fail' && echo true || echo false)"

printf 'build_command: "exit 1"\ntest_command: "echo never reached"\n' > claude-workflow.yml
out=$("$SCRIPT_DIR/wf-suite-run.sh" --label t --build 2>&1); rc=$?
assert_eq "a failing build exits 1 without running the suite" "1" "$rc"
assert_eq "and says the suite never ran" "true" \
  "$(printf '%s' "$out" | grep -q 'the suite never ran' && echo true || echo false)"

# No suite configured is a gap to report, never a pass.
printf 'build_command: "echo b"\n' > claude-workflow.yml
"$SCRIPT_DIR/wf-suite-run.sh" >/dev/null 2>&1
assert_eq "an unconfigured suite exits 2, not 0" "2" "$?"

cd "$TEST_DIR" || exit 1
rm -rf "$SUITE"

section "What a harness needs to be intact depends on the worktree"

# WFI-253. Two faults in one check. `harness_intact()` demanded
# scripts/v*/wf-*.sh, a layout no client has had since v9.0.0 put the scripts
# under scripts/gen/<build>/v*/ — so it condemned every current MAIN worktree.
# And it demanded version-map.txt inside a LINKED worktree, where wf-exec.sh
# resolves that from the main checkout and it is not supposed to exist at all.
# /wf-deploy's release-branches/main worktree hit both, and the recovery that
# followed reported an unrestorable harness over a dispatcher that worked.
HR=$(mktemp -d)
RESTORE="$SCRIPT_DIR/wf-harness-restore.sh"
git init -q -b develop "$HR" >/dev/null
cd "$HR" || exit 1
git config user.email t@t.com; git config user.name T
mkdir -p scripts/gen/b1/v2.00 .claude
cp "$SCRIPT_DIR/wf-worktree-harness.sh" scripts/gen/b1/v2.00/
printf '0.00 v2.00\n' > scripts/version-map.txt
echo b1 > scripts/current
printf '#!/usr/bin/env bash\necho dispatch\n' > scripts/wf-exec.sh; chmod +x scripts/wf-exec.sh
printf 'scripts/\n.claude/\n' > .gitignore
git add -A >/dev/null 2>&1; git commit -qm seed >/dev/null 2>&1

bash "$RESTORE" --check >/dev/null 2>&1
assert_eq "a gen-era main worktree reads as intact" "0" "$?"

git worktree add -q "$HR/rel" -b release >/dev/null 2>&1
cd "$HR/rel" || exit 1
bash "$RESTORE" --check >/dev/null 2>&1
assert_eq "a linked worktree with no dispatcher reads as missing" "1" "$?"

bash "$RESTORE" >/dev/null 2>&1
assert_eq "and is restored from the main worktree, no library and no network" "0" "$?"
assert_eq "the dispatcher is what landed" "true" \
  "$([ -x scripts/wf-exec.sh ] && echo true || echo false)"
assert_eq "version-map.txt is NOT copied — it resolves from the main worktree" "false" \
  "$([ -f scripts/version-map.txt ] && echo true || echo false)"
bash "$RESTORE" --check >/dev/null 2>&1
assert_eq "and the linked worktree now reads as intact" "0" "$?"

# Exit 2 is a total failure to restore, and must never be reported as 0.
NOHOPE=$(mktemp -d)
git init -q "$NOHOPE" >/dev/null
cd "$NOHOPE" || exit 1
git config user.email t@t.com; git config user.name T
git commit -q --allow-empty -m base
bash "$RESTORE" >/dev/null 2>&1
assert_eq "nothing left to try exits 2, not 0" "2" "$?"

cd "$TEST_DIR" || exit 1
git -C "$HR" worktree remove --force "$HR/rel" >/dev/null 2>&1
rm -rf "$HR" "$NOHOPE"

section "Forward progress for RELEASE/DEPLOY reads the PUSHED ref"

# progress_sig() is a pure function for these two ids — it returns before it
# touches SELF_DIR or the registry — so it is lifted out and called directly.
eval "$(sed -n '/^progress_sig()/,/^}/p' "$SCRIPT_DIR/wf-orchestrate.sh")"

PROG=$(mktemp -d)
git init -q -b develop "$PROG" >/dev/null
git init -q --bare "$PROG.origin.git" >/dev/null
cd "$PROG" || exit 1
git config user.email t@t.com; git config user.name T
git commit -q --allow-empty -m base
git branch release
git remote add origin "$PROG.origin.git"
git push -q origin release
git fetch -q origin

before=$(progress_sig RELEASE)
assert_eq "the signature names the pushed ref" "true" \
  "$(printf '%s' "$before" | grep -q '^release:origin/release@' && echo true || echo false)"

# WFI-254: /wf-release fast-forwards LOCAL release at step 6 and only finds out
# at step 7 that the suite failed. When the rollback then refuses, the local ref
# is left ahead for a run that promoted nothing — and the old signature
# (`git rev-parse release`) moved, resetting the attempt budget and spawning the
# next release worker. Three runs, three "Do NOT deploy", 3 of a 4/day grant.
git checkout -q release
git commit -q --allow-empty -m "untested commits a failed run left on local release"
git checkout -q develop
assert_eq "a failed run that left local release ahead is NOT forward progress" \
  "$before" "$(progress_sig RELEASE)"

# A real promotion pushes, and only a push moves the remote-tracking ref.
git push -q origin release
assert_eq "an actual push to origin/release IS forward progress" "false" \
  "$([ "$before" = "$(progress_sig RELEASE)" ] && echo true || echo false)"

# A local-only client has no remote-tracking ref; the local one is all there is,
# and no signal at all would park every release as `stuck`.
git remote remove origin
git update-ref -d refs/remotes/origin/release
assert_eq "falls back to the local ref when nothing tracks a remote" "true" \
  "$(progress_sig RELEASE | grep -q '^release:release@' && echo true || echo false)"

cd "$TEST_DIR" || exit 1
rm -rf "$PROG" "$PROG.origin.git"

# ═══════════════════════════════════════════════════════════════════════
printf '\n══════════════════════════════════════════════════════════════\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32mResults: %d/%d passed\033[0m\n' "$PASS" "$((PASS + FAIL))"
else
  printf '\033[31mResults: %d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
fi
printf '══════════════════════════════════════════════════════════════\n'

[ "$FAIL" -eq 0 ]
