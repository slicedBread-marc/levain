#!/usr/bin/env bash
# client-reports.sh — one regression per defect swept out of a client's
# WORKFLOW-ISSUES.md.
#
# Every assertion here failed in a real project before the fix that follows it.
# The comment above each block names the report, so a future change that
# reintroduces the behavior fails against the evidence rather than a guess.
#
# Usage: ./tests/client-reports.sh
# Exit 0 if all pass, 1 otherwise.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB_SCRIPTS="$LIB_ROOT/scripts"
SCRIPT_FOLDER=$(awk '{sub(/#.*/, "")} NF >= 2 {folder = $2} END {print folder}' "$LIB_SCRIPTS/version-map.txt")
[ -n "$SCRIPT_FOLDER" ] || { echo "cannot resolve script folder from version-map.txt" >&2; exit 1; }
SCRIPT_DIR="${WF_TEST_SCRIPT_DIR:-$LIB_SCRIPTS/$SCRIPT_FOLDER}"

TEST_DIR=""
PASS=0
FAIL=0

cleanup() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then
    # Feature worktrees hold the parent repo open; drop them first.
    (cd "$TEST_DIR/main" 2>/dev/null && git worktree prune) >/dev/null 2>&1
    rm -rf "$TEST_DIR"
  fi
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

registry_add_row() {
  local id="$1" slug="$2" state="${3:-draft}" branch="${4:-—}" tags="${5:-—}" deps="${6:-—}"
  awk -v row="| $id | $slug | $state | — | $branch | 2026-08-02 | ${SCRIPT_FOLDER#v} | $tags | $deps |" '
    /<!-- Counter:/ && !done { print row; done = 1 }
    { print }
  ' plans/REGISTRY.md > plans/REGISTRY.tmp && mv plans/REGISTRY.tmp plans/REGISTRY.md
  mkdir -p "plans/$id-$slug"
  printf '# %s-%s\n\n## Goal\nTest goal for %s\n' "$id" "$slug" "$id" > "plans/$id-$slug/plan.md"
}

registry_state() {
  grep "^| $1 |" plans/REGISTRY.md | head -1 | awk -F'|' '{print $4}' | xargs
}

# ═══════════════════════════════════════════════════════════════════════
TEST_DIR=$(mktemp -d)
mkdir -p "$TEST_DIR/main"
cd "$TEST_DIR/main" || exit 1
git init -q -b develop
git config user.email "test@test.com"
git config user.name "Test"
mkdir -p plans .claude
cp "$LIB_ROOT/templates/plans/REGISTRY.md" plans/REGISTRY.md
cat "$LIB_ROOT/VERSION" > .claude/workflow-version
git add -A >/dev/null 2>&1
git commit -qm seed >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "Seeded REGISTRY header (client-a WFI-002)"

# The shipped template was still the 7-column v4 header while wf-spec had been
# writing 9-field rows since v5, so header and rows disagreed from the very
# first plan. wf-set-tags.sh patched each row on the way past, which hid the
# mismatch instead of fixing it.
assert_eq "template header carries Tags and Deps" "true" \
  "$(grep -q '^| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |$' plans/REGISTRY.md && echo true || echo false)"
assert_eq "separator has nine columns" "9" \
  "$(grep -m1 '^|-' plans/REGISTRY.md | tr -cd '-' | wc -c | xargs)"

# ═══════════════════════════════════════════════════════════════════════
section "Branch check on a greenfield repo (client-a WFI-001)"

# `git checkout <missing> 2>/dev/null` under set -e exited 1 with EMPTY stdout
# and stderr, so "develop does not exist yet" was indistinguishable from any
# other failure. Every greenfield project hit this on its first spec.
git checkout -q -b main 2>/dev/null || git checkout -q main
out=$("$SCRIPT_DIR/wf-branch-check.sh" nonexistent-branch true 2>&1)
assert_eq "a missing branch is created rather than failing silently" "true" \
  "$(printf '%s' "$out" | grep -q 'CREATED_BRANCH=nonexistent-branch' && echo true || echo false)"
assert_eq "and the caller is told what it is now on" "true" \
  "$(printf '%s' "$out" | grep -q 'CURRENT_BRANCH=nonexistent-branch' && echo true || echo false)"
git checkout -q develop
git branch -q -D nonexistent-branch main 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
section "Registry writes from a feature worktree (app WFI-002)"

# Registry scripts resolved "plans/REGISTRY.md" against the CWD. Verify and
# implement workers run inside a feature worktree, where that path is the
# worktree's own stale copy: the write landed there, the script's own
# verification grep passed against the file it had just written, and the real
# registry never moved. The plan read as stuck in `verify` with a completed
# clean round already committed.
registry_add_row PLN-101 worktree-write verify
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-101" >/dev/null 2>&1
git worktree add -q -b feature/PLN-101 "$TEST_DIR/wt-101" develop 2>/dev/null

assert_ok "registry update runs from inside a feature worktree" \
  env -C "$TEST_DIR/wt-101" "$SCRIPT_DIR/wf-registry-update.sh" PLN-101 verify testing
assert_eq "the DEVELOP registry is the one that moved" "testing" "$(registry_state PLN-101)"

# The same path bug made every read report the worktree's copy.
assert_eq "reads from a worktree see develop's registry" "true" \
  "$(env -C "$TEST_DIR/wt-101" "$SCRIPT_DIR/wf-list-testable.sh" 2>/dev/null \
     | grep -q 'PLN-101-worktree-write' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Sparse checkout in a linked worktree (client-a WFI-004, app WFI-006)"

# REPO_ROOT came from `git rev-parse --show-toplevel`, which in a linked
# worktree returns THAT worktree. The script then ran `mkdir -p <wt>/.git/info`
# — but a linked worktree's .git is a regular file, a gitdir pointer — and died
# with "Not a directory" before configuring anything.
assert_ok "sparse-checkout configures a linked worktree" \
  "$SCRIPT_DIR/wf-worktree-sparse.sh" "$TEST_DIR/wt-101"
assert_eq "patterns landed in the worktree's own admin dir" "true" \
  "$(grep -q '^!plans/\*\*$' "$(git -C "$TEST_DIR/wt-101" rev-parse --git-dir)/info/sparse-checkout" && echo true || echo false)"
assert_eq "develop's sparse-checkout stayed a catch-all" "/**" \
  "$(head -1 "$(git rev-parse --git-common-dir)/info/sparse-checkout" 2>/dev/null)"

git worktree remove --force "$TEST_DIR/wt-101" >/dev/null 2>&1

# The frozen v1.x snapshot carried the same line and the same failure — it is a
# pure bug fix, so it propagates in place rather than forking a folder.
assert_eq "the v1.x snapshot no longer derives REPO_ROOT from --show-toplevel" "false" \
  "$(grep -q 'REPO_ROOT=$(git rev-parse --show-toplevel)' "$LIB_SCRIPTS/v1.x/wf-worktree-sparse.sh" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Implementable type vs. existing worktree (client-a WFI-014)"

# The header documents type `new` as "state ready AND no existing worktree",
# but the type was read off the state alone. A plan sent back to `ready` for a
# replan keeps its branch and worktree, so it came back as `new` and the
# implementer tried to create both again.
registry_add_row PLN-102 replanned ready feature/PLN-102
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-102" >/dev/null 2>&1
assert_eq "ready with no worktree is 'new'" "new" \
  "$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null | awk -F'\t' '$2 == "PLN-102-replanned" { print $1 }')"

git worktree add -q -b feature/PLN-102 "$TEST_DIR/wt-102" develop 2>/dev/null
assert_eq "ready WITH a worktree is a resume, not a new build" "resume" \
  "$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null | awk -F'\t' '$2 == "PLN-102-replanned" { print $1 }')"

printf '# Findings\n\n- [ ] Replan: implement Amendment A1\n' > plans/PLN-102-replanned/findings.md
assert_eq "…and a fix when findings are outstanding" "fix" \
  "$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null | awk -F'\t' '$2 == "PLN-102-replanned" { print $1 }')"

git worktree remove --force "$TEST_DIR/wt-102" >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "Goal history lands in its own table (client-a WFI-009)"

# The append matched the first `|-|-|-|-|` ANYWHERE in the file. Goal History
# ships with its header commented out, so the first LIVE four-column separator
# belongs to ## Tests — and the goal row was prepended there, giving the Tests
# table an ID column holding a date and a Command column holding an em-dash.
registry_add_row PLN-103 goal-table draft
cat > plans/PLN-103-goal-table/plan.md <<'PLAN'
# PLN-103

## Goal
Freeze the v1 capsule envelope contract

### Goal History
<!-- Managed by wf-spec via wf-goal-push.sh / wf-goal-pop.sh. Do not edit manually. -->
<!-- | Date | Previous Goal | Trigger | Resolution | -->

## Tests
| ID | Name | Command | Expected |
|-|-|-|-|
| T1 | round-trips | dotnet test | pass |
PLAN

"$SCRIPT_DIR/wf-goal-push.sh" PLN-103 "Implement Amendment A1" "Verify: 1 finding" >/dev/null 2>&1
hist=$(awk '/^### Goal History/{f=1;next} /^## /{f=0} f' plans/PLN-103-goal-table/plan.md)
assert_eq "the row is inside ### Goal History" "true" \
  "$(printf '%s' "$hist" | grep -q 'Freeze the v1 capsule envelope contract' && echo true || echo false)"
assert_eq "the Tests table is untouched" "true" \
  "$(grep -q '^| T1 | round-trips | dotnet test | pass |$' plans/PLN-103-goal-table/plan.md && echo true || echo false)"
assert_eq "no goal row leaked into Tests" "false" \
  "$(awk '/^## Tests/{f=1} f' plans/PLN-103-goal-table/plan.md | grep -q 'Verify: 1 finding' && echo true || echo false)"
assert_eq "the commented header became a real one" "1" \
  "$(grep -c '^| Date | Previous Goal | Trigger | Resolution |$' plans/PLN-103-goal-table/plan.md | xargs)"

# ═══════════════════════════════════════════════════════════════════════
section "The 'unbuilt' manual tag (client-a WFI-010)"

# wf-defer-criterion.sh documents and writes `unbuilt`, and the v3.0.0 response
# named it as the fourth tag — but the lint's tag switch never learned it, so
# deferring a criterion the documented way produced a plan that failed back to
# draft for an "unknown tag".
registry_add_row PLN-104 unbuilt-tag draft
cat > plans/PLN-104-unbuilt-tag/plan.md <<'PLAN'
# PLN-104

> **schema_version:** 6

## Verification Checklist

#### Manual
- [ ] (eyes:blocking) /app — the flow is completable one-handed
- [ ] (unbuilt) the export button — the screen it lives on ships in PLN-112
PLAN

assert_ok "a plan using (unbuilt) lints clean" \
  "$SCRIPT_DIR/wf-manual-lint.sh" --file plans/PLN-104-unbuilt-tag/plan.md
eval "$("$SCRIPT_DIR/wf-manual-lint.sh" --file plans/PLN-104-unbuilt-tag/plan.md --counts)"
assert_eq "unbuilt is counted as its own tag" "1" "${MANUAL_UNBUILT:-unset}"
assert_eq "and not as untagged" "0" "${MANUAL_UNTAGGED:-unset}"
assert_eq "it does not gate — only open eyes:* do" "1" "${MANUAL_OPEN_EYES:-unset}"

# A tag that really is unknown must still fail, or the lint means nothing.
printf -- '- [ ] (whenever) something vague\n' >> plans/PLN-104-unbuilt-tag/plan.md
assert_fails "an actually-unknown tag is still rejected" \
  "$SCRIPT_DIR/wf-manual-lint.sh" --file plans/PLN-104-unbuilt-tag/plan.md

# ═══════════════════════════════════════════════════════════════════════
section "BROAD-SCOPE findings do not route (app WFI-003)"

# A BROAD-SCOPE finding is out of the plan's declared scope and is resolved by
# spawning an independent bug. Routing on it sent the plan back to an
# implementer whose own Out of Scope section forbids the fix, so the only way
# out was to check off a finding nobody had acted on.
registry_add_row PLN-105 broad-scope verify
mkdir -p plans/PLN-105-broad-scope
printf '# Findings\n\n- [ ] SQLitePCLRaw CVE in an unrelated package ← BROAD-SCOPE\n' \
  > plans/PLN-105-broad-scope/findings.md
assert_eq "a lone BROAD-SCOPE finding leaves the plan clean" "clean" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-105-broad-scope 2>/dev/null)"

printf -- '- [ ] the retry loop swallows cancellation\n' >> plans/PLN-105-broad-scope/findings.md
assert_eq "an in-scope finding alongside it still routes to active" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-105-broad-scope 2>/dev/null)"

printf -- '- [ ] the spec never said which store wins ← ESCALATED\n' >> plans/PLN-105-broad-scope/findings.md
assert_eq "escalation still wins over everything" "escalated" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-105-broad-scope 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════
section "wf-verify documents its unattended contract (reported 3×)"

VERIFY_SKILL="$LIB_ROOT/skills/wf-verify/SKILL.md"
assert_eq "wf-verify has an Unattended mode section" "true" \
  "$(grep -qi '^## Unattended mode' "$VERIFY_SKILL" && echo true || echo false)"
assert_eq "it resolves prompts with [AUTO]/[GATE] like its siblings" "true" \
  "$(grep -q '\[AUTO\]' "$VERIFY_SKILL" && grep -q '\[GATE\]' "$VERIFY_SKILL" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "The registry is tracked (client-a WFI-007)"

# It was gitignored as "operational state", so plan.md, findings.md and
# progress.md were all versioned while the state machine indexing them was
# not — and the documented "row-based, so concurrent edits auto-merge"
# rationale described something that cannot happen in an untracked file.
assert_eq "install.sh does not add it to .gitignore" "false" \
  "$(grep -qE '^\s*echo "plans/REGISTRY\.md" >> "\$GITIGNORE"' "$LIB_ROOT/install.sh" && echo true || echo false)"
assert_eq "install.sh removes an existing ignore line" "true" \
  "$(grep -q 'Removed plans/REGISTRY.md from .gitignore' "$LIB_ROOT/install.sh" && echo true || echo false)"

# A transition and the findings that justify it must land in ONE commit.
registry_add_row PLN-108 tracked verify
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-108" >/dev/null 2>&1
# Written after the baseline commit, so it is genuinely part of the transition.
printf '# Findings\n\n## Verify — 2026-08-02\n\n- [x] all clear\n' > plans/PLN-108-tracked/findings.md
"$SCRIPT_DIR/wf-registry-update.sh" PLN-108 verify testing \
  --commit "verify(PLN-108-tracked): clean — ready for human test" \
  --add plans/PLN-108-tracked/findings.md >/dev/null 2>&1
committed=$(git show --stat --name-only --pretty=format: HEAD | tr -d ' ')
assert_eq "the registry is in the transition commit" "true" \
  "$(printf '%s' "$committed" | grep -qx 'plans/REGISTRY.md' && echo true || echo false)"
assert_eq "so are the findings that justify it" "true" \
  "$(printf '%s' "$committed" | grep -qx 'plans/PLN-108-tracked/findings.md' && echo true || echo false)"
assert_eq "and HEAD agrees with the working tree" "testing" \
  "$(git show HEAD:plans/REGISTRY.md | grep '^| PLN-108 |' | awk -F'|' '{print $4}' | xargs)"

# Feature branches must still never carry it.
assert_eq "sparse-checkout still excludes plans/ from feature worktrees" "true" \
  "$(grep -q '^!plans/\*\*$' "$SCRIPT_DIR/wf-worktree-sparse.sh" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Test filter vs. Microsoft.Testing.Platform (client-a, unnumbered)"

# FullyQualifiedName~X is VSTest syntax. Under MTP `dotnet test --filter` is
# not recognised: it prints MTP's help, reports "Zero tests ran" and exits 1.
# A verify agent reading only that exit code fails a fully passing plan.
if command -v yq >/dev/null 2>&1; then
  SCOPE_DIR="$TEST_DIR/scope"
  mkdir -p "$SCOPE_DIR/plans/PLN-107-scoped" "$SCOPE_DIR/scripts"
  cp "$SCRIPT_DIR"/wf-test-scope.sh "$SCRIPT_DIR"/wf-plan-info.sh \
     "$SCRIPT_DIR"/wf-orch-lib.sh "$SCRIPT_DIR"/wf-lock.sh "$SCOPE_DIR/scripts/" 2>/dev/null
  cp plans/REGISTRY.md "$SCOPE_DIR/plans/REGISTRY.md"
  printf '| PLN-107 | scoped | verify | — | — | 2026-08-02 | 2.00 | — | — |\n' >> "$SCOPE_DIR/plans/REGISTRY.md"
  printf '# PLN-107\n\n## Goal\nscoped\n\n## Test Scope\n- unit\n' > "$SCOPE_DIR/plans/PLN-107-scoped/plan.md"
  cat > "$SCOPE_DIR/claude-workflow.yml" <<'YML'
testFilterStyle: auto
testScopes:
  unit:
    - Core.Tests
YML

  out=$(cd "$SCOPE_DIR" && ./scripts/wf-test-scope.sh PLN-107-scoped 2>/dev/null || true)
  assert_eq "a VSTest project still gets a filter" "true" \
    "$(printf '%s' "$out" | grep -q 'FullyQualifiedName~Core.Tests' && echo true || echo false)"

  printf '{ "test": { "runner": "Microsoft.Testing.Platform" } }\n' > "$SCOPE_DIR/global.json"
  rc=0
  out=$(cd "$SCOPE_DIR" && ./scripts/wf-test-scope.sh PLN-107-scoped 2>/dev/null) || rc=$?
  assert_eq "an MTP project gets no filter at all" "" "$out"
  assert_eq "and it is a clean exit, not a failure" "0" "$rc"

  # An explicit setting must beat the detection in both directions.
  printf 'testFilterStyle: vstest\ntestScopes:\n  unit:\n    - Core.Tests\n' > "$SCOPE_DIR/claude-workflow.yml"
  out=$(cd "$SCOPE_DIR" && ./scripts/wf-test-scope.sh PLN-107-scoped 2>/dev/null || true)
  assert_eq "testFilterStyle: vstest overrides the detection" "true" \
    "$(printf '%s' "$out" | grep -q 'FullyQualifiedName~Core.Tests' && echo true || echo false)"
else
  printf '  \033[33m—\033[0m yq not installed, skipping filter-style checks\n'
fi

# ═══════════════════════════════════════════════════════════════════════
section "local-env deploy is feature-branch only (client-a WFI-016)"

# Hooks live in the shared admin dir and fire from every worktree, so an
# `implement(` commit made on develop during a fix cycle deployed develop's
# tree. Under sparse-checkout that tree does not match the Dockerfile's build
# context, and the deploy failed on every such commit.
# The installer must refresh an existing hook on CONTENT. It used to skip
# whenever the hook already contained "claude-workflow: verify agent trigger",
# a one-shot migration check — which froze the hook on every client that had
# it, so this very fix reached exactly one of four projects on first deploy.
assert_eq "install.sh refreshes the hook when it differs" "true" \
  "$(grep -q 'cmp -s "$HOOK_SRC" "$HOOK"' "$LIB_ROOT/install.sh" && echo true || echo false)"
assert_eq "and no longer gates on the verify-trigger marker" "false" \
  "$(grep -q 'grep -q "claude-workflow: verify agent trigger" "$HOOK"' "$LIB_ROOT/install.sh" && echo true || echo false)"

cp "$LIB_ROOT/templates/hooks/post-commit" .git/hooks/post-commit
chmod +x .git/hooks/post-commit
cat > .claude/on-implement-commit.sh <<'STUB'
#!/bin/bash
echo "$1" >> "$(git rev-parse --show-toplevel)/.claude/deploy-ran"
STUB
chmod +x .claude/on-implement-commit.sh
rm -f .claude/deploy-ran

git checkout -q develop
echo one > marker.txt && git add marker.txt >/dev/null 2>&1
git commit -qm "implement(PLN-001-x): fix findings" >/dev/null 2>&1
assert_eq "an implement( commit on develop does NOT deploy" "false" \
  "$([ -f .claude/deploy-ran ] && echo true || echo false)"

git checkout -q -b feature/PLN-106-hooked
echo two > marker.txt && git add marker.txt >/dev/null 2>&1
git commit -qm "implement(PLN-106-hooked): step 1" >/dev/null 2>&1
assert_eq "the same commit on a feature branch still deploys" "true" \
  "$([ -f .claude/deploy-ran ] && echo true || echo false)"

git checkout -q develop
rm -f .git/hooks/post-commit .claude/on-implement-commit.sh .claude/deploy-ran

# ═══════════════════════════════════════════════════════════════════════
section "wf-bug points at a template that exists (app WFI-005)"

# Step 5 sent the planner to bugs/_template/bug.md, which install.sh has never
# deployed. The skill's own inline format block was complete all along.
assert_eq "no reference to an undeployed template file" "false" \
  "$(grep -q 'bugs/_template' "$LIB_ROOT/skills/wf-bug/SKILL.md" && echo true || echo false)"
assert_eq "the inline bug.md format is still there" "true" \
  "$(grep -q '^## Steps to Reproduce' "$LIB_ROOT/skills/wf-bug/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A deploy must not dirty a feature worktree (client-a WFI-021)"

# A sparse-checkout exclusion holds only while the path is ABSENT from the
# working tree or byte-identical to the branch's blob. install.sh wrote fresh
# content to exactly the paths this list excluded, which clears the
# skip-worktree bit on the next index refresh — so a deploy mid-plan left 33
# files the implementer never touched showing as modified, `reapply` refused to
# re-exclude them, and `git merge develop` ABORTED with "your local changes
# would be overwritten" before reaching a real conflict.
cd "$TEST_DIR/main" || exit 1
mkdir -p scripts/v2.00 .claude/skills/wf-attend
printf 'orig\n' > scripts/v2.00/wf-sample.sh
printf 'orig\n' > scripts/version-map.txt
printf 'orig\n' > .claude/skills/wf-attend/SKILL.md
printf 'orig\n' > scripts/wf-exec.sh
git add -A >/dev/null 2>&1 && git commit -qm "seed infra" >/dev/null 2>&1

registry_add_row PLN-121 deploy-drift active feature/PLN-121-deploy-drift
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-121" >/dev/null 2>&1
git worktree add -q -b feature/PLN-121-deploy-drift "$TEST_DIR/wt-103" develop 2>/dev/null
"$SCRIPT_DIR/wf-worktree-sparse.sh" "$TEST_DIR/wt-103" >/dev/null 2>&1

# What a deploy does: newer content into every path a session reads on disk,
# and — as install.sh used to — into the develop-owned ones as well.
mkdir -p "$TEST_DIR/wt-103/scripts/v2.00" "$TEST_DIR/wt-103/.claude/skills/wf-attend"
printf 'v3.4.0\n' > "$TEST_DIR/wt-103/scripts/v2.00/wf-sample.sh"
printf 'v3.4.0\n' > "$TEST_DIR/wt-103/scripts/version-map.txt"
printf 'v3.4.0\n' > "$TEST_DIR/wt-103/.claude/skills/wf-attend/SKILL.md"
printf 'v3.4.0\n' > "$TEST_DIR/wt-103/scripts/wf-exec.sh"
# ...and develop adopts the same release.
printf 'v3.4.0\n' > scripts/v2.00/wf-sample.sh
printf 'v3.4.0\n' > scripts/version-map.txt
printf 'v3.4.0\n' > .claude/skills/wf-attend/SKILL.md
printf 'v3.4.0\n' > scripts/wf-exec.sh
chmod +x scripts/wf-exec.sh
git add -A >/dev/null 2>&1 && git commit -qm "chore: adopt v3.4.0" >/dev/null 2>&1

# Re-running sparse configuration is what install.sh now does first. It clears
# deploy copies of develop-owned paths — identified as byte-identical to
# develop's, so a file someone actually edited here is left alone.
"$SCRIPT_DIR/wf-worktree-sparse.sh" "$TEST_DIR/wt-103" >/dev/null 2>&1
assert_eq "develop-owned script copies no longer dirty the worktree" "0" \
  "$(git -C "$TEST_DIR/wt-103" status --porcelain -- scripts/v2.00 scripts/version-map.txt | wc -l | xargs)"

# The three paths a session reads off its own disk are gitignored as of v5.0.0
# and copied in rather than tracked. Migrate this fixture the way a real client
# migrates, so the merge assertion below tests the CURRENT contract: under
# tracking, a mid-plan deploy left them modified and the merge aborted before it
# could conflict on anything real.
printf '.claude/skills/wf-*/\n.claude/workflow.md\nscripts/wf-exec.sh\n' >> .gitignore
git rm -r -q --cached .claude/skills scripts/wf-exec.sh >/dev/null 2>&1 || true
git add .gitignore >/dev/null 2>&1
git commit -qm "chore: stop tracking the generated harness" >/dev/null 2>&1

# The worktree takes the migration through wf-merge-develop.sh, which is what
# clears the deploy's local modifications first — a plain `git merge` ABORTS on
# them and the worktree can then never receive the untrack commit at all.
( cd "$TEST_DIR/wt-103" && "$SCRIPT_DIR/wf-merge-develop.sh" ) >/dev/null 2>&1 || true

assert_eq "the runtime files are on the worktree's disk" "true" \
  "$([ -f "$TEST_DIR/wt-103/.claude/skills/wf-attend/SKILL.md" ] && [ -f "$TEST_DIR/wt-103/scripts/wf-exec.sh" ] && echo true || echo false)"
assert_eq "and cannot dirty it, because git cannot see them" "0" \
  "$(git -C "$TEST_DIR/wt-103" status --porcelain | wc -l | xargs)"

# The whole point: the merge runs.
assert_ok "git merge develop succeeds after a mid-plan deploy" \
  git -C "$TEST_DIR/wt-103" merge develop --no-edit

# A release adds scripts AFTER a branch is cut, so an old deploy left them in
# the worktree as UNTRACKED files. `git ls-files` cannot see those, and they sit
# in `git status` as `??` — where a `git add -A` commits develop's tooling as
# plan work.
printf 'brand new\n' > scripts/v2.00/wf-added-later.sh
git add -A >/dev/null 2>&1 && git commit -qm "add a script post-branch" >/dev/null 2>&1
mkdir -p "$TEST_DIR/wt-103/scripts/v2.00"
printf 'brand new\n' > "$TEST_DIR/wt-103/scripts/v2.00/wf-added-later.sh"
"$SCRIPT_DIR/wf-worktree-sparse.sh" "$TEST_DIR/wt-103" >/dev/null 2>&1
assert_eq "an untracked deploy leftover is cleared too" "false" \
  "$([ -f "$TEST_DIR/wt-103/scripts/v2.00/wf-added-later.sh" ] && echo true || echo false)"

# Legacy clients keep scripts flat at scripts/wf-*.sh. An untracked copy of one
# is a deploy artifact by the same reasoning — but wf-exec.sh shares the glob
# and is the one file a session inside the worktree must be able to invoke.
printf 'flat legacy\n' > scripts/wf-claim.sh
git add -A >/dev/null 2>&1 && git commit -qm "flat-layout script" >/dev/null 2>&1
printf 'flat legacy\n' > "$TEST_DIR/wt-103/scripts/wf-claim.sh"
"$SCRIPT_DIR/wf-worktree-sparse.sh" "$TEST_DIR/wt-103" >/dev/null 2>&1
assert_eq "a flat-layout leftover is cleared" "false" \
  "$([ -f "$TEST_DIR/wt-103/scripts/wf-claim.sh" ] && echo true || echo false)"
assert_eq "but wf-exec.sh survives the same glob" "true" \
  "$([ -f "$TEST_DIR/wt-103/scripts/wf-exec.sh" ] && echo true || echo false)"

# The exclusion list and the propagation list are the same decision made twice;
# a path may not appear in both.
assert_eq "install.sh no longer copies versioned scripts into a worktree" "false" \
  "$(grep -q 'wt_path/scripts/\$wt_folder' "$LIB_ROOT/install.sh" && echo true || echo false)"
assert_eq "nor stamps the sparse-excluded workflow-version there" "false" \
  "$(grep -q 'wt_path/.claude/workflow-version' "$LIB_ROOT/install.sh" && echo true || echo false)"

# The reconciliation that used to run here is gone, not relocated.
assert_eq "wf-infra-sync.sh no longer exists" "false" \
  "$([ -e "$SCRIPT_DIR/wf-infra-sync.sh" ] && echo true || echo false)"
assert_eq "and merge-develop restores the harness on every worktree instead" "true" \
  "$(grep -q 'wf-worktree-harness.sh' "$SCRIPT_DIR/wf-merge-develop.sh" && echo true || echo false)"

git worktree remove --force "$TEST_DIR/wt-103" >/dev/null 2>&1
git branch -q -D feature/PLN-121-deploy-drift 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
section "State transitions reach the commit that claims them (client-a WFI-022)"

# Every skill's post-transition commit was written when REGISTRY.md was
# gitignored, so none of their `git add` lists names it. Since v3.2.0 it is
# tracked — and wf-implement's Phase 3 commit, documented as "this commit
# triggers the verify agent", contained no registry change at all. Staging it
# inside wf-registry-update.sh fixes every call site at once, including ones
# not yet written.
registry_add_row PLN-120 unstaged ready
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-120" >/dev/null 2>&1

"$SCRIPT_DIR/wf-registry-update.sh" PLN-120 ready active >/dev/null 2>&1
assert_eq "a transition without --commit still stages the registry" "true" \
  "$(git diff --cached --name-only | grep -qx 'plans/REGISTRY.md' && echo true || echo false)"

# The caller's own commit is what must carry it — `git commit -m` commits the
# whole index, so staging here is enough for every skill's add-list.
git commit -qm "implement(PLN-120-unstaged): verified, moved to verify" >/dev/null 2>&1
assert_eq "the caller's commit carries the transition" "true" \
  "$(git show --stat --name-only HEAD | grep -qx 'plans/REGISTRY.md' && echo true || echo false)"
assert_eq "and HEAD's registry holds the new state" "active" \
  "$(git show HEAD:plans/REGISTRY.md | grep '^| PLN-120 |' | awk -F'|' '{print $4}' | xargs)"

# Phase 3 named only progress.md and findings.md, so the plan.md checklist
# ticks that step 21 writes were dropped on the floor too.
assert_eq "Phase 3 commits the whole plan folder and the registry" "true" \
  "$(grep -q 'git add plans/REGISTRY.md plans/PLN-NNN-<slug>/ &&' \
     "$LIB_ROOT/skills/wf-implement/SKILL.md" && echo true || echo false)"

# A bare `git add -A` on a feature branch commits whatever the last deploy
# wrote as if the plan had changed it.
assert_eq "no bare 'git add -A' left in the implementer" "0" \
  "$(grep -c '^\s*git add -A$' "$LIB_ROOT/skills/wf-implement/SKILL.md" | xargs)"

# ═══════════════════════════════════════════════════════════════════════
section "A replan lands where its builder's exit expects (client-a WFI-027, WFI-026)"

# wf-spec's replanning exit wrote `draft → ready` unconditionally. A replanned
# plan keeps its branch and worktree, so the dispatcher correctly read
# ready+worktree as a `resume` and sent it to the fix cycle — whose exit runs
# `wf-registry-update.sh <id> active verify`. That from_state does not match
# `ready`, so the transition silently no-opped: work committed on the branch,
# registry still `ready`, and verify then refused for the same reason.
registry_add_row PLN-122 replan-fresh draft
registry_add_row PLN-123 replan-resume draft feature/PLN-123-replan-resume
git add -A >/dev/null 2>&1 && git commit -qm "add replan fixtures" >/dev/null 2>&1

assert_eq "a replan with no worktree goes back to ready" "ready" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-122)"

git worktree add -q -b feature/PLN-123-replan-resume "$TEST_DIR/wt-123" develop 2>/dev/null
assert_eq "a replan WITH a worktree goes to active" "active" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-123)"

assert_ok "--apply performs the transition" \
  "$SCRIPT_DIR/wf-replan-target.sh" PLN-123 --apply
assert_eq "the registry agrees" "active" "$(registry_state PLN-123)"

# Which is exactly the state wf-implement's exit contract requires.
assert_ok "and the builder's exit transition now matches" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-123 active verify

# The error that sent a worker looking for a missing row.
err=$("$SCRIPT_DIR/wf-registry-update.sh" PLN-122 active verify 2>&1 || true)
assert_eq "a from_state mismatch names the state the plan IS in" "true" \
  "$(printf '%s' "$err" | grep -q "is in state 'draft', not 'active'" && echo true || echo false)"

assert_eq "wf-spec no longer hardcodes ready on the replan exit" "true" \
  "$(grep -q 'wf-replan-target.sh PLN-NNN --apply' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"

# The exit sequence must not commit a transition that was refused.
assert_eq "Phase 3 stops rather than committing a refused transition" "true" \
  "$(grep -q 'do NOT run step 26' "$LIB_ROOT/skills/wf-implement/SKILL.md" && echo true || echo false)"

git worktree remove --force "$TEST_DIR/wt-123" >/dev/null 2>&1
git branch -q -D feature/PLN-123-replan-resume 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
section "The fix cycle sets its own container name and port (client-a WFI-025)"

# The post-commit hook fires on every `implement(` commit and reads
# FEATURE_PORT / COMPOSE_PROJECT_NAME from the environment. The fix cycle had
# no equivalent of Phase 2 step 12, and these are shell variables in a NEW
# session — so docker-compose.yml fell back to its defaults, which are another
# plan's name and port. One fix-cycle commit deployed a PLN-002 build as
# ...-pln001 on 8101.
assert_eq "the fix cycle runs wf-plan-port.sh" "true" \
  "$(awk '/^## Fix cycle/, /^## Worktree workflow/' "$LIB_ROOT/skills/wf-implement/SKILL.md" \
     | grep -q 'wf-plan-port.sh' && echo true || echo false)"
assert_eq "and says why a second session cannot inherit it" "true" \
  "$(awk '/^## Fix cycle/, /^## Worktree workflow/' "$LIB_ROOT/skills/wf-implement/SKILL.md" \
     | grep -q 'COMPOSE_PROJECT_NAME' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "The tag vocabulary is the project's own (client-a WFI-030)"

# wf-spec offered `security, arcade, admin, lessons, ux, infra, e2e, bugfix`
# and wf-set-tags.sh REJECTED everything else. Three of those names are one
# project's game/admin/lessons app. Elsewhere the list named tags that meant
# nothing and omitted `contract` — the tag marking that program's frozen wire
# surface, and the only tag in its specApproval.gateTags. The list was already
# being ignored in practice, which is what makes it dangerous: it looks
# authoritative, is not, and sits directly in front of a gating decision.
cat > claude-workflow.yml <<'YML'
specApproval:
  mode: verdict
  gateTags:
    - contract
YML
registry_add_row PLN-130 wire-format ready — contract
registry_add_row PLN-131 relay-store ready — infra,relay
registry_add_row PLN-132 relay-host  ready — relay
git add -A >/dev/null 2>&1 && git commit -qm "tag fixture" >/dev/null 2>&1

tags_out=$("$SCRIPT_DIR/wf-list-tags.sh" 2>/dev/null || true)
assert_eq "a tag no shipped list contained is reported" "true" \
  "$(printf '%s' "$tags_out" | grep -q '^contract' && echo true || echo false)"
assert_eq "gating tags are marked as such" "true" \
  "$(printf '%s' "$tags_out" | grep -qE '^contract\s+1\s+gate$' && echo true || echo false)"
assert_eq "and non-gating ones are not" "true" \
  "$(printf '%s' "$tags_out" | grep -qE '^relay\s+2\s+—$' && echo true || echo false)"
assert_eq "most-used first" "relay" "$(printf '%s' "$tags_out" | head -1 | cut -f1)"
assert_eq "--gating lists only what carries a gate" "contract" \
  "$("$SCRIPT_DIR/wf-list-tags.sh" --gating 2>/dev/null | tr '\n' ',' | sed 's/,$//')"

# A gate tag nobody has used yet is the one a planner most needs offered.
printf 'specApproval:\n  mode: verdict\n  gateTags:\n    - contract\n    - unused-gate\n' > claude-workflow.yml
assert_eq "an unused gate tag is still listed" "true" \
  "$("$SCRIPT_DIR/wf-list-tags.sh" 2>/dev/null | grep -qE '^unused-gate\s+0\s+gate$' && echo true || echo false)"
printf 'specApproval:\n  mode: verdict\n  gateTags:\n    - contract\n' > claude-workflow.yml

# The hard failure: the tag that gates could not be assigned at all.
assert_ok "a tag outside the old hardcoded list can be assigned" \
  "$SCRIPT_DIR/wf-set-tags.sh" PLN-132 relay,contract
assert_eq "and it lands in the registry" "relay,contract" \
  "$(grep '^| PLN-132 |' plans/REGISTRY.md | awk -F'|' '{print $9}' | xargs)"
# Captured, not piped straight into `grep -q`: grep exits on its first match
# and SIGPIPEs the producer, which pipefail then reports as a failed pipeline.
warn=$("$SCRIPT_DIR/wf-set-tags.sh" PLN-132 relay,brand-new 2>&1 >/dev/null || true)
assert_eq "a name new to the project warns rather than failing" "true" \
  "$(printf '%s' "$warn" | grep -q 'new tag' && echo true || echo false)"

assert_eq "the prompt no longer offers another project's vocabulary" "false" \
  "$(grep -q 'Tags (comma-separated): security, arcade' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "step 4c reads the project's own tags" "true" \
  "$(awk '/^4c\./, /^5\./' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'wf-list-tags.sh' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "The review runs before the gate, not after it (client-a WFI-028)"

# The tag-gate path parked the plan BEFORE any review ran — SKILL.md said
# verbatim "Do not run the review agent". Two consequences in one drain: a
# tagged plan got LESS automated scrutiny than an untagged one and waited idle
# for a human to commission the review (one sat 3h20m unreviewed), and the
# human was handed approvable and unapprovable plans identically, so two of
# four gates were consumed only to end at `draft` with findings — exactly where
# an unattended Blocked verdict routes them anyway.
assert_eq "the skill no longer forbids reviewing a tagged plan" "false" \
  "$(grep -q 'Do \*\*not\*\* run the review agent' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "every unattended exit runs the review" "true" \
  "$(grep -q 'The review always runs. Nothing here skips it' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "the gate mode and the tag path share one exit" "true" \
  "$(grep -q '^## Exit — unattended' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "a Blocked verdict never reaches a human directly" "true" \
  "$(awk '/^## Exit — unattended/, /^## Replanning/' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'same fix loop' && echo true || echo false)"
assert_eq "the gate question carries the verdict" "true" \
  "$(awk '/^## Exit — unattended/, /^## Replanning/' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'Review: Approved with notes' && echo true || echo false)"
# v4.2.0 asserted a flat "do not re-run the review". WFI-046 made it
# conditional — a verdict that predates the plan's last amendment MUST be
# re-run — so the assertion tracks the narrower contract: don't re-run one that
# is current.
assert_eq "wf-attend reads the review instead of commissioning it" "true" \
  "$(grep -q 'do not re-run a review step 1 already found current' "$LIB_ROOT/skills/wf-attend/SKILL.md" && echo true || echo false)"
assert_eq "and a batch drain does not re-review what already has a verdict" "true" \
  "$(grep -q 'Read the verdicts that are already there' "$LIB_ROOT/skills/wf-attend/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "The consistency closure reaches the docs the plans cite (client-a WFI-029)"

# The pass read plans only. Shared reference docs sit outside every dependency
# closure, so a contradiction between two of them was invisible to the one role
# that exists to find cross-document contradictions. Observed: a review raised
# a Critical against a plan for a config schema the plan had gotten right —
# two reference docs disagreed, and each plan had faithfully followed one.
mkdir -p docs/plan/reference
touch docs/plan/reference/07-remote-cli.md docs/plan/reference/20-multi-instance.md
registry_add_row PLN-140 store   ready — infra
registry_add_row PLN-141 host    ready — infra PLN-140
registry_add_row PLN-142 chat    ready — relay PLN-141
printf '# PLN-142\n\n## Goal\nChat over the relay.\n\nWire per docs/plan/reference/07-remote-cli.md and docs/plan/reference/99-absent.md.\n' \
  > plans/PLN-142-chat/plan.md
printf '# PLN-141\n\n## Goal\nHost the relay.\n\nBuild block per docs/plan/reference/07-remote-cli.md, layout per docs/plan/reference/20-multi-instance.md.\n' \
  > plans/PLN-141-host/plan.md
git add -A >/dev/null 2>&1 && git commit -qm "closure fixture" >/dev/null 2>&1

closure=$("$SCRIPT_DIR/wf-list-closure.sh" PLN-142 2>/dev/null | cut -f1 | tr '\n' ',' | sed 's/,$//')
assert_eq "the closure is transitive, not just direct Deps" "PLN-141,PLN-140" "$closure"
assert_eq "and carries each plan's state" "ready" \
  "$("$SCRIPT_DIR/wf-list-closure.sh" PLN-142 2>/dev/null | head -1 | cut -f3)"

docs_out=$("$SCRIPT_DIR/wf-list-cited-docs.sh" PLN-142 2>/dev/null || true)
assert_eq "a doc cited by a TRANSITIVE dependency is reached" "true" \
  "$(printf '%s' "$docs_out" | grep -q '20-multi-instance.md' && echo true || echo false)"
assert_eq "the doc cited by two plans is listed first" "docs/plan/reference/07-remote-cli.md" \
  "$(printf '%s' "$docs_out" | head -1 | cut -f1)"
assert_eq "and names both citing plans, which is the pair to cross-read" "PLN-141,PLN-142" \
  "$(printf '%s' "$docs_out" | head -1 | cut -f2)"
assert_eq "a cited path that does not exist is dropped" "false" \
  "$(printf '%s' "$docs_out" | grep -q '99-absent' && echo true || echo false)"
assert_eq "a plan citing nothing is not an error" "0" \
  "$("$SCRIPT_DIR/wf-list-cited-docs.sh" PLN-140 >/dev/null 2>&1; echo $?)"

# A mutual Deps pair must terminate rather than loop forever.
registry_add_row PLN-143 loop-a ready — — PLN-144
registry_add_row PLN-144 loop-b ready — — PLN-143
assert_eq "a dependency cycle terminates" "PLN-144" \
  "$("$SCRIPT_DIR/wf-list-closure.sh" PLN-143 2>/dev/null | cut -f1 | tr '\n' ',' | sed 's/,$//')"

assert_eq "wf-consistency reads the cited docs" "true" \
  "$(grep -q 'wf-list-cited-docs.sh' "$LIB_ROOT/skills/wf-consistency/SKILL.md" && echo true || echo false)"
assert_eq "and checks them against each other, not just the plan" "true" \
  "$(grep -q 'Two reference docs that disagree' "$LIB_ROOT/skills/wf-consistency/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A replan cannot quietly shrink the Goal (client-a WFI-031)"

# Nothing compared an amended plan against what it originally promised. An
# amendment narrowed unattended relay to ANSWER-ONLY for a sound reason — its
# own text called it "a deliberate reduction of the Goal's headline capability"
# — so a reviewer would approve it, verdict mode would send it to `ready`, and
# the user would learn that "fix this while I'm out" no longer works when they
# next tried it. It reached a human only incidentally, via a tag that was
# removed from gateTags the same day.
registry_add_row PLN-150 relay-scope draft
printf '# PLN-150\n\n## Goal\nRelay answers and applies fixes while the user is away.\n' \
  > plans/PLN-150-relay-scope/plan.md
git add -A >/dev/null 2>&1 && git commit -qm "goal fixture" >/dev/null 2>&1

delta=$("$SCRIPT_DIR/wf-goal-delta.sh" PLN-150 2>/dev/null || true)
assert_eq "an untouched goal reports unchanged" "true" \
  "$(printf '%s' "$delta" | grep -q '^GOAL_STATUS:   unchanged' && echo true || echo false)"

# The case that actually occurred: the Goal LINE is untouched and the
# reduction lands in an amendment, so a goal-line diff alone would miss it.
printf '# PLN-150\n\n## Goal\nRelay answers and applies fixes while the user is away.\n\n## Amendments\n### A1.1(c)\nNarrow unattended relay to ANSWER-ONLY — a write-capable loop over untrusted input is the injection this plan prevents.\n' \
  > plans/PLN-150-relay-scope/plan.md
delta=$("$SCRIPT_DIR/wf-goal-delta.sh" PLN-150 2>/dev/null || true)
assert_eq "the goal line alone still reads unchanged" "true" \
  "$(printf '%s' "$delta" | grep -q '^GOAL_STATUS:   unchanged' && echo true || echo false)"
assert_eq "so the new amendment text is printed for the judgement" "true" \
  "$(printf '%s' "$delta" | grep -q 'ANSWER-ONLY' && echo true || echo false)"
assert_eq "and the amendment is counted" "1" \
  "$(printf '%s' "$delta" | awk '/^AMENDMENTS_NEW:/{print $2}')"

git add -A >/dev/null 2>&1 && git commit -qm "amend PLN-150" >/dev/null 2>&1
printf '# PLN-150\n\n## Goal\nRelay answers questions while the user is away.\n' \
  > plans/PLN-150-relay-scope/plan.md
delta=$("$SCRIPT_DIR/wf-goal-delta.sh" PLN-150 2>/dev/null || true)
assert_eq "an edited goal is measured against the ORIGINAL, not the last commit" "true" \
  "$(printf '%s' "$delta" | grep -q '^GOAL_ORIGINAL: Relay answers and applies fixes' && echo true || echo false)"
assert_eq "and reports changed" "true" \
  "$(printf '%s' "$delta" | grep -q '^GOAL_STATUS:   changed' && echo true || echo false)"

assert_eq "replanning runs the scope check" "true" \
  "$(awk '/^## Replanning/, /^## Cross-plan consistency/' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'wf-goal-delta.sh' && echo true || echo false)"
assert_eq "and gates on it whatever the review verdict says" "true" \
  "$(awk '/^## Replanning/, /^## Cross-plan consistency/' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'whatever the review verdict says' && echo true || echo false)"
assert_eq "wf-attend knows what to do with a scope-reduction gate" "true" \
  "$(grep -q '^### `scope-reduction`' "$LIB_ROOT/skills/wf-attend/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Port vars reach the post-commit hook (client-a WFI-039/041/043)"

# `eval "$(wf-plan-port.sh ...)"` on bare KEY=VALUE lines sets UNEXPORTED shell
# variables. The consumer is the post-commit hook, which git runs as a child
# process — and a child inherits the environment, not plain shell variables.
# The eval appeared to work and every plan deployed under the first plan's
# container name and port.
port_out=$("$SCRIPT_DIR/wf-plan-port.sh" PLN-004-capsule-service)
assert_eq "the port line is exported" "true" \
  "$(printf '%s' "$port_out" | grep -q '^export FEATURE_PORT=8104$' && echo true || echo false)"
assert_eq "the project name is exported" "true" \
  "$(printf '%s' "$port_out" | grep -q '^export COMPOSE_PROJECT_NAME=' && echo true || echo false)"

# The distinction the bug turned on: exported vars survive into a child.
port_seen=$(eval "$port_out"; bash -c 'echo "${FEATURE_PORT:-unset}"')
assert_eq "a child process sees the port" "8104" "$port_seen"

# Captured before grepping: `script | grep -q` races under pipefail — grep exits
# on the first match, SIGPIPEs the producer, and the pipeline reports the
# producer's 141 rather than grep's 0.
v1x_out=$("$LIB_SCRIPTS/v1.x/wf-plan-port.sh" PLN-004-x)
assert_eq "the v1.x snapshot exports too" "true" \
  "$(printf '%s' "$v1x_out" | grep -q '^export FEATURE_PORT=' && echo true || echo false)"

# Step 7 of the fix cycle is the one step that commits from its own bash call,
# so it must re-resolve rather than inherit.
assert_eq "the fix cycle's commit step sets the port itself" "true" \
  "$(awk '/^7\. \*\*When all findings are checked off/, /^## Worktree workflow/' \
       "$LIB_ROOT/skills/wf-implement/SKILL.md" | grep -q 'wf-plan-port.sh' && echo true || echo false)"

# The hook derives its own identity rather than trusting the caller at all.
assert_eq "the commit hook reads .plan-ref" "true" \
  "$(grep -q 'PROJECT_DIR/.plan-ref' "$LIB_ROOT/templates/on-implement-commit.sh" && echo true || echo false)"
# Scoped to the on-implement-commit.sh sed block: install.sh substitutes
# {{project_slug}} in several other places already, so an unanchored grep
# passes whether or not the hook gets it.
assert_eq "and install.sh bakes the slug into it" "true" \
  "$(awk '/{{local_start_command}}/, /on-implement-commit.sh"$/' "$LIB_ROOT/install.sh" \
     | grep -q 'project_slug' && echo true || echo false)"

# The hook duplicates wf-plan-port.sh's formula, so prove they agree — by
# RUNNING the hook's copy against the same input, not by pattern-matching the
# source. The first cut of this asserted `awk '/8100 \+ _plan_num/ {print "8104"}'`
# equals 8104, which is true whenever the pattern matches and says nothing at
# all about the arithmetic. A guard that cannot fail is worse than none: it
# reads as coverage.
hook_dir=$(mktemp -d)
sed 's|{{project_slug}}|testproj|g' "$LIB_ROOT/templates/on-implement-commit.sh" > "$hook_dir/hook.sh"
printf 'PLN-004\n' > "$hook_dir/.plan-ref"
# Source only the derivation block — running the whole hook would eval the
# project's deploy command.
hook_derived=$(
  cd "$hook_dir" && PROJECT_DIR="$hook_dir" \
    bash -c "$(awk '/^if \[ -f "\$PROJECT_DIR\/.plan-ref" \]/, /^fi$/' "$hook_dir/hook.sh"); echo \"\$FEATURE_PORT \$COMPOSE_PROJECT_NAME\"" 2>/dev/null | tail -1
)
port_ref=$(sed 's|{{project_slug}}|testproj|g' "$LIB_SCRIPTS/$SCRIPT_FOLDER/wf-plan-port.sh" > "$hook_dir/port.sh"
           chmod +x "$hook_dir/port.sh"
           eval "$("$hook_dir/port.sh" PLN-004-x)"; echo "$FEATURE_PORT $COMPOSE_PROJECT_NAME")
assert_eq "the hook's port formula agrees with wf-plan-port.sh" "$port_ref" "$hook_derived"
rm -rf "$hook_dir"

# ═══════════════════════════════════════════════════════════════════════
section "Rendering-surface globs span directories (client-a WFI-044)"

# `/**/` was rewritten to `/(.*/)?`, and then the rule narrowing a lone `*` to
# `[^/]*` rewrote the `*` INSIDE that `.*`. Every glob compiled to one optional
# directory level of at least two characters, so renderingSurfaces matched
# nothing in a real source tree and a plan changing three .razor pages shipped
# with its manual gate closed as "the diff renders nothing to a human".
eval "$(sed -n '/^glob_to_regex() {/,/^}/p' "$SCRIPT_DIR/wf-manual-gate.sh")"

changed_files='src/Tracker.Web.Client/Pages/Admin/Capsules.razor
src/Tracker.Web.Client/wwwroot/css/app.css
src/Tracker.Core/Services/CapsuleService.cs
src/foo-razor'
glob_hit() {
  printf '%s\n' "$changed_files" | grep -E "$(glob_to_regex "$1")" | head -1 || true
}

assert_eq "a nested .razor page matches src/**/*.razor" \
  "src/Tracker.Web.Client/Pages/Admin/Capsules.razor" "$(glob_hit 'src/**/*.razor')"
assert_eq "a nested wwwroot file matches src/**/wwwroot/**" \
  "src/Tracker.Web.Client/wwwroot/css/app.css" "$(glob_hit 'src/**/wwwroot/**')"
assert_eq "a glob that should not match still does not" "" "$(glob_hit 'src/**/Components/**')"
assert_eq "a single * does not span a separator" "" "$(glob_hit 'src/*.cs')"

# The escape rule was `[.[\]()+^$]`, which reads as a metacharacter set but is
# not one: a backslash is literal inside brackets, so `\]` closed it early and
# the rule never fired on any input.
assert_eq "the dot in a glob is escaped, so *.razor is not *?razor" "" "$(glob_hit 'src/**/*Xrazor')"
escaped=$(glob_to_regex 'a.b')
assert_eq "the escape pass actually escapes" "true" \
  "$(printf '%s' "$escaped" | grep -qF 'a\.b' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A stash only ever restores its own work (client-a WFI-036)"

# `git stash` on a clean tree saves NOTHING and exits 0, so the unconditional
# `git stash pop` that followed restored whatever was at stash@{0} — a stale
# entry from an interrupted session. Live, that was an 18-file superseded
# workflow deploy, and the next step commits whatever it restored.
STASH_DIR="$TEST_DIR/stash"
mkdir -p "$STASH_DIR" && (
  cd "$STASH_DIR" && git init -q . && git config user.email t@t && git config user.name t
  echo one > a.txt && git add . && git commit -qm init
  echo FOREIGN > a.txt && git stash push -m "someone else's work" >/dev/null
) >/dev/null 2>&1

pushed=$(cd "$STASH_DIR" && "$SCRIPT_DIR/wf-stash.sh" push merge 2>/dev/null)
assert_eq "a clean tree stashes nothing" "WF_STASHED=false" "$pushed"
restored=$(cd "$STASH_DIR" && "$SCRIPT_DIR/wf-stash.sh" pop merge 2>/dev/null)
assert_eq "and popping restores nothing" "WF_RESTORED=false" "$restored"
assert_eq "the foreign stash is untouched" "one" "$(cat "$STASH_DIR/a.txt")"
assert_eq "and is still in the stack" "1" \
  "$(cd "$STASH_DIR" && git stash list | wc -l | tr -d ' ')"

# A real round trip still works, and survives another stash landing on top.
(cd "$STASH_DIR" && echo MINE > a.txt && "$SCRIPT_DIR/wf-stash.sh" push merge) >/dev/null 2>&1
(cd "$STASH_DIR" && echo INTERLOPER > b.txt && git add b.txt && git stash push -m interloper) >/dev/null 2>&1
(cd "$STASH_DIR" && "$SCRIPT_DIR/wf-stash.sh" pop merge) >/dev/null 2>&1
assert_eq "our stash is found after the stack shifts under it" "MINE" "$(cat "$STASH_DIR/a.txt")"

assert_eq "wf-test no longer pops positionally" "false" \
  "$(grep -q 'git stash pop 2>/dev/null' "$LIB_ROOT/skills/wf-test/SKILL.md" && echo true || echo false)"
assert_eq "nor does wf-chrome-test" "false" \
  "$(grep -q 'git stash pop 2>/dev/null' "$LIB_ROOT/skills/wf-chrome-test/SKILL.md" && echo true || echo false)"
assert_eq "and the restored-changes commit is guarded on WF_RESTORED" "true" \
  "$(grep -q 'WF_RESTORED:-false' "$LIB_ROOT/skills/wf-test/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "MTP projects get a real filter (client-a WFI-045/038/035)"

# testFilterStyle accepted only vstest or none, so a Microsoft.Testing.Platform
# project could never emit a filter — tiered test gating always fell back to the
# full suite. The MTP syntax has since been confirmed against real runs.
SCOPE2="$TEST_DIR/mtp"
mkdir -p "$SCOPE2/scripts" "$SCOPE2/plans/PLN-160-mtp"
cp "$SCRIPT_DIR/wf-test-scope.sh" "$SCRIPT_DIR/wf-plan-info.sh" "$SCOPE2/scripts/"
printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-160 | mtp | verify | — | — | 2026-08-04 | %s | — | — |\n' \
  "${SCRIPT_FOLDER#v}" > "$SCOPE2/plans/REGISTRY.md"
printf '## Goal\nx\n\n## Test Scope\n- unit\n' > "$SCOPE2/plans/PLN-160-mtp/plan.md"
printf 'test_filter_flag: "--filter"\ntestFilterStyle: mtp\ntestScopes:\n  unit:\n    - Core.Tests\n' \
  > "$SCOPE2/claude-workflow.yml"

if command -v yq >/dev/null 2>&1; then
  mtp_args=$(cd "$SCOPE2" && ./scripts/wf-test-scope.sh PLN-160-mtp --args 2>/dev/null || true)
  assert_eq "an MTP scope emits --filter-class, not FullyQualifiedName" "true" \
    "$(printf '%s' "$mtp_args" | grep -q -- "--filter-class '\*Core.Tests\*'" && echo true || echo false)"
  # Filtering across a solution makes zero-match projects exit 8, so a run whose
  # selected tests all passed still reports failure without this.
  assert_eq "and carries --ignore-exit-code 8" "true" \
    "$(printf '%s' "$mtp_args" | grep -q -- '--ignore-exit-code 8' && echo true || echo false)"

  printf 'test_filter_flag: "--filter"\ntestFilterStyle: vstest\ntestScopes:\n  unit:\n    - Core.Tests\n' \
    > "$SCOPE2/claude-workflow.yml"
  vs_args=$(cd "$SCOPE2" && ./scripts/wf-test-scope.sh PLN-160-mtp --args 2>/dev/null || true)
  assert_eq "vstest --args still renders flag plus value" "--filter 'FullyQualifiedName~Core.Tests'" "$vs_args"
  # On an UNFILTERED run exit 8 means the suite really found no tests, so the
  # ignore must never leak into the vstest path.
  assert_eq "and never carries the MTP exit-code ignore" "false" \
    "$(printf '%s' "$vs_args" | grep -q -- '--ignore-exit-code' && echo true || echo false)"

  printf 'testFilterStyle: auto\ntestScopes:\n  unit:\n    - Core.Tests\n' > "$SCOPE2/claude-workflow.yml"
  printf '{ "test": { "runner": "Microsoft.Testing.Platform" } }\n' > "$SCOPE2/global.json"
  auto_args=$(cd "$SCOPE2" && ./scripts/wf-test-scope.sh PLN-160-mtp --args 2>/dev/null || true)
  assert_eq "auto-detection routes an MTP project to mtp, not to the full suite" "true" \
    "$(printf '%s' "$auto_args" | grep -q -- '--filter-class' && echo true || echo false)"
fi

assert_eq "wf-verify asks for the whole argument string" "true" \
  "$(grep -q 'wf-test-scope.sh PLN-NNN-<slug> --args' "$LIB_ROOT/skills/wf-verify/SKILL.md" && echo true || echo false)"
assert_eq "a solution takes --solution, not a positional path" "true" \
  "$(grep -q 'dotnet test --solution <file>' "$LIB_ROOT/config.example.yml" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A verdict is found, and known to be current (client-a WFI-046)"

# Two failures at one gate: the verdict was written to findings.md under
# `## Spec Review` (so wf-attend, reading only plan.md, would have called it a
# harness fault and re-run a review that existed), and both verdicts were
# Blocked on the PRE-amendment plan — the amendment then resolved every finding
# and nothing re-reviewed it.
mkdir -p plans/PLN-013-relay plans/PLN-018-fresh
cat > plans/PLN-013-relay/plan.md <<'PLAN13'
## Goal
Two-way relay
## Review
> Filled by the planner's review gate before status is set to Ready.
## Amendments
A1 — 2026-08-04 — narrowed to answer-only
PLAN13
cat > plans/PLN-013-relay/findings.md <<'FIND13'
## Spec Review — 2026-08-03
Independent architecture and security review run at the spec-approval gate. Result: Blocked
FIND13
cat > plans/PLN-018-fresh/plan.md <<'PLAN18'
## Review
**2026-08-04 — Plan Review (unattended, round 1)**
**Result:** Approved with notes
## Amendments
> Append-only.
PLAN18

# Read through eval, the way wf-attend and wf-spec do — the output is quoted
# precisely so that a verdict containing an apostrophe survives that eval.
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-013 2>/dev/null)"
assert_eq "a verdict filed in findings.md is still found" "findings" "$REVIEW_LOCATION"
assert_eq "and its verdict is read out of prose" "Blocked" "$REVIEW_RESULT"
assert_eq "a verdict older than the amendment is stale" "true" "$REVIEW_STALE"

# A review recorded as BLOCKQUOTE lines is still a review. The shipped template
# and wf-spec's own example both write the record that way, so a "filled means
# unquoted" test reports a correctly-filed verdict as missing — the same false
# harness fault this script exists to prevent. Caught against client-a's real
# PLN-018 after the first cut of the fix shipped.
mkdir -p plans/PLN-019-quoted
cat > plans/PLN-019-quoted/plan.md <<'PLAN19'
## Review
> Filled by the planner's review gate before status is set to Ready.

> **2026-08-04 — Plan Review (unattended, round 1 of 3)**
> **Result:** Approved with notes
> **Rounds:** 1 — no Critical findings.

> **2026-08-05 — Plan Review (unattended, round 2 of 3)**
> **Result:** Approved
## Amendments
> Append-only.
PLAN19
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-019 2>/dev/null)"
assert_eq "a blockquoted verdict is found, not read as a placeholder" "plan" "$REVIEW_LOCATION"
assert_eq "and the LAST round's verdict is the one reported" "Approved" "$REVIEW_RESULT"

eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-018 2>/dev/null)"
assert_eq "a fresh spec records its verdict in plan.md" "plan" "$REVIEW_LOCATION"
assert_eq "and an unamended plan is not stale" "false" "$REVIEW_STALE"

# Day-granular dates cannot order a review and an amendment written the same
# day — which is the ordinary case. Neither "current" nor "stale" is honest.
mkdir -p plans/PLN-020-sameday
cat > plans/PLN-020-sameday/plan.md <<'PLAN20'
## Review
**2026-08-04 — Plan Review**
**Result:** Approved
## Amendments
A1 — 2026-08-04 — narrowed
PLAN20
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-020 2>/dev/null)"
assert_eq "a same-day review and amendment is neither, and says so" "unknown" "$REVIEW_STALE"

assert_eq "wf-attend looks in both places before crying harness fault" "true" \
  "$(grep -q 'wf-review-status.sh' "$LIB_ROOT/skills/wf-attend/SKILL.md" && echo true || echo false)"
assert_eq "and re-reviews a plan amended since its verdict" "true" \
  "$(grep -q 'REVIEW_STALE=true' "$LIB_ROOT/skills/wf-attend/SKILL.md" && echo true || echo false)"
assert_eq "the replan path is told where the verdict goes" "true" \
  "$(awk '/^## Replanning/, /^## Cross-plan consistency/' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'Never in `findings.md`' && echo true || echo false)"
assert_eq "and wf-review names one home for it" "true" \
  "$(grep -q 'verdict of record' "$LIB_ROOT/skills/wf-review/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Consuming a freshly filed bug (client-a WFI-037)"

# `git mv` exits 128 on a folder git has never seen, and wf-bug commits only at
# the end of its run — so the FIRST consumption of any new bug failed. Separately
# the Status/Plan rewrites were pure sub() calls, silently no-ops on a header
# lacking those lines, so a "triaged" bug recorded neither.
mkdir -p bugs/open/BUG-017-landing-copy
cat > bugs/open/BUG-017-landing-copy/bug.md <<'BUG17'
# Landing copy is wrong

> **Severity:** Low
> **Source:** human
> **Created:** 2026-08-04

## Description
Copy says "beta".
BUG17

assert_ok "an untracked bug can be consumed at all" \
  "$SCRIPT_DIR/wf-bug-consume.sh" BUG-017 PLN-017-landing-copy
assert_eq "the bug moved to triaged" "true" \
  "$([ -d bugs/triaged/BUG-017-landing-copy ] && echo true || echo false)"
assert_eq "a missing Status line is inserted, not skipped" "true" \
  "$(grep -q '^> \*\*Status:\*\* Triaged$' bugs/triaged/BUG-017-landing-copy/bug.md && echo true || echo false)"
assert_eq "and the plan link is recorded" "true" \
  "$(grep -q '^> \*\*Plan:\*\* PLN-017-landing-copy$' bugs/triaged/BUG-017-landing-copy/bug.md && echo true || echo false)"
assert_eq "the insert lands inside the header block" "true" \
  "$(awk '/^## Description/ { exit } /Status:\*\* Triaged/ { found = 1 } END { print (found ? "true" : "false") }' \
       bugs/triaged/BUG-017-landing-copy/bug.md)"

# ═══════════════════════════════════════════════════════════════════════
section "A terminal state for dropped work (app WFI-008)"

# Six dropped plans were written as `abandoned` — a state that did not exist.
# wf-registry-update.sh accepted it silently, so any typo became a live value.
registry_add_row PLN-035 dropped verify
registry_add_row PLN-090 dependent draft "—" "—" PLN-035
printf '' > plans/PLN-035-dropped/progress.md

assert_fails "a state outside the documented set is rejected" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-035 verify abandonned
assert_eq "and the plan did not move" "verify" "$(registry_state PLN-035)"

assert_fails "abandoning without a reason is refused" \
  "$SCRIPT_DIR/wf-abandon.sh" PLN-035
assert_ok "abandoning with one works from any state" \
  "$SCRIPT_DIR/wf-abandon.sh" PLN-035 --reason "Superseded by PLN-073."
assert_eq "the plan is terminal" "abandoned" "$(registry_state PLN-035)"
assert_eq "and the reason survives in progress.md" "true" \
  "$(grep -q 'Superseded by PLN-073' plans/PLN-035-dropped/progress.md && echo true || echo false)"

# An incomplete dep is "not yet"; an abandoned one is "never". Reported the same
# way, an abandoned dep blocked its dependents forever with no way to clear it.
deps_out=$("$SCRIPT_DIR/wf-check-deps.sh" PLN-090 2>/dev/null)
assert_eq "a dependent is told the dep is dead, not late" "DEAD PLN-035" "$deps_out"

assert_fails "a terminal plan cannot jump back to a working state" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-035 abandoned active
assert_ok "but it can be revived to draft" \
  "$SCRIPT_DIR/wf-abandon.sh" PLN-035 --revive
assert_eq "which is where revival lands" "draft" "$(registry_state PLN-035)"

assert_eq "the orchestrator routes abandoned instead of hard-failing" "true" \
  "$(grep -q 'abandoned)      result="abandoned"' "$SCRIPT_DIR/wf-orchestrate.sh" && echo true || echo false)"
assert_eq "and gives it its own exit code" "true" \
  "$(grep -q 'exit 40' "$SCRIPT_DIR/wf-orchestrate.sh" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "The registry and plans/ still describe one world (app WFI-009/010)"

# A plan folder with no row is not partly tracked — it is invisible. Every
# wf-list-* script and the orchestrator see plans only through the registry, so
# nothing can report a plan the registry does not know about.
mkdir -p plans/PLN-051-maze-crumbs plans/PLN-064-session-telemetry plans/PLN-064-learning-portal
printf '# x\n' > plans/PLN-051-maze-crumbs/plan.md

audit=$("$SCRIPT_DIR/wf-registry-audit.sh" 2>/dev/null || true)
assert_eq "a plan folder with no registry row is reported" "true" \
  "$(printf '%s' "$audit" | grep -q 'MISSING ROW.*PLN-051' && echo true || echo false)"
assert_eq "two folders sharing an ID are reported" "true" \
  "$(printf '%s' "$audit" | grep -q 'DUPLICATE DIR PLN-064' && echo true || echo false)"
assert_eq "the audit exits non-zero when it finds something" "1" \
  "$("$SCRIPT_DIR/wf-registry-audit.sh" >/dev/null 2>&1; echo $?)"

# A `draft` plan carrying 21 commits of finished work means a state write was
# lost — visible only from the branch side, which nothing else looks at.
git checkout -q -b feature/PLN-090-dependent 2>/dev/null
printf 'work\n' > impl.txt && git add impl.txt >/dev/null 2>&1
git commit -qm "implement(PLN-090): step 1" >/dev/null 2>&1
git checkout -q develop 2>/dev/null
# A `draft` plan carrying 21 commits of finished work means a state write was
# lost — visible only from the branch side, which nothing else looks at.
#
# Run in its own repo: committing on a feature branch here would sweep the
# staged registry into that commit, and checking back out to develop would then
# discard the rows this fixture depends on.
STALE_DIR="$TEST_DIR/stale"
mkdir -p "$STALE_DIR/plans/PLN-037-lost" && (
  cd "$STALE_DIR" && git init -qb develop . && git config user.email t@t && git config user.name t
  printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-037 | lost | draft | — | — | 2026-08-04 | 2.00 | — | — |\n\n<!-- Counter: 99 -->\n' \
    > plans/REGISTRY.md
  printf '# x\n' > plans/PLN-037-lost/plan.md
  git add -A && git commit -qm seed
  git checkout -qb feature/PLN-037-lost
  echo work > src.txt && git add src.txt && git commit -qm "implement(PLN-037): step 1"
  git checkout -q develop
) >/dev/null 2>&1

stale_audit=$(cd "$STALE_DIR" && "$SCRIPT_DIR/wf-registry-audit.sh" 2>/dev/null || true)
assert_eq "a draft plan sitting on real commits is reported" "true" \
  "$(printf '%s' "$stale_audit" | grep -q 'STALE STATE.*PLN-037' && echo true || echo false)"

# This fixture has exactly ONE thing wrong, and the finding is written over two
# lines. Both lines used to go through report(), so the tally counted the
# continuation as a second problem and the reader went hunting for a finding
# that was never printed. client-a filed it as WFI-050; client-c showed
# the same shape — "2 problem(s)" above a single COUNTER finding.
assert_eq "a two-line finding counts as one problem" "registry audit: 1 problem(s)" \
  "$(printf '%s' "$stale_audit" | grep 'registry audit:')"

# The counter check used to read every digit run out of whole paths, so a slug
# containing a number became an artifact ID. client-a's highest real ID was
# 020 and `base64url` in two slugs made the audit report 64 and advise setting
# the counter to 65 — burning IDs 21-64. The check that guards the counter was
# the only thing endangering it (WFI-050).
SLUG="$TEST_DIR/slugdigits"
mkdir -p "$SLUG/plans/PLN-019-capsule-base64url-encoding" \
         "$SLUG/bugs/triaged/BUG-019-capsule-base64url-encoding" \
         "$SLUG/plans/briefs" && (
  cd "$SLUG" && git init -qb develop . && git config user.email t@t && git config user.name t
  { printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n'
    printf '| PLN-019 | capsule-base64url-encoding | complete | — | — | 2026-08-04 | 2.00 | — | — |\n'
    printf '| PLN-020 | tool-cli | draft | — | — | 2026-08-04 | 2.00 | — | — |\n'
    printf '\n<!-- Counter: 21 -->\n'
  } > plans/REGISTRY.md
  mkdir -p plans/PLN-020-tool-cli
) >/dev/null 2>&1

slug_audit=$(cd "$SLUG" && "$SCRIPT_DIR/wf-registry-audit.sh" 2>&1 || true)
assert_eq "a number inside a slug is not mistaken for an artifact ID" "true" \
  "$(printf '%s' "$slug_audit" | grep -q 'COUNTER' && echo false || echo true)"
assert_eq "and the audit is clean on client-a's actual shape" "registry audit: clean" \
  "$(printf '%s' "$slug_audit" | grep 'registry audit:')"

# The check must still fire for a counter that really is behind.
( cd "$SLUG" && sed -i.bak 's/<!-- Counter: 21 -->/<!-- Counter: 19 -->/' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak )
behind_audit=$(cd "$SLUG" && "$SCRIPT_DIR/wf-registry-audit.sh" 2>&1 || true)
assert_eq "a genuinely stale counter is still caught" "true" \
  "$(printf '%s' "$behind_audit" | grep -q 'COUNTER.*highest ID in use (20)' && echo true || echo false)"
assert_eq "and it advises the next free number, not a slug's digits" "true" \
  "$(printf '%s' "$behind_audit" | grep -q 'Set it to 21\.' && echo true || echo false)"

assert_eq "wf-status runs the audit" "true" \
  "$(grep -q 'wf-registry-audit.sh' "$LIB_ROOT/skills/wf-status/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "client-c's first three reports (WFI-001/002/003)"

# WFI-001 — wf-spec cited templates/plans/TEMPLATE.md, a path that exists in
# the LIBRARY. install.sh deploys it to the client as plans/TEMPLATE.md.
assert_eq "wf-spec cites the client's template path, not the library's" "false" \
  "$(grep -q 'templates/plans/TEMPLATE.md' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "and cites the one install.sh actually writes" "true" \
  "$(grep -q 'following `plans/TEMPLATE.md`' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"

# WFI-002 — the implementer spawns its own verify agent on exit. The
# orchestrator reached verify a moment later, was turned away by the
# already-running guard, saw no state change and reported exit 30 — documented
# as "something is wrong with the plan or the skill" — while that verify agent
# ran healthily. A retry would have burned one of max_attempts_per_plan.
assert_eq "an already-running peer is waited for, not called a stall" "true" \
  "$(grep -q 'rc" -eq 2' "$SCRIPT_DIR/wf-orchestrate.sh" && echo true || echo false)"
assert_eq "and has an exit code distinct from no-progress" "true" \
  "$(grep -q 'exit 41' "$SCRIPT_DIR/wf-orchestrate.sh" && echo true || echo false)"
assert_eq "the contract published to clients lists it" "true" \
  "$(grep -q '`41`' "$LIB_ROOT/templates/WORKFLOW.md" && echo true || echo false)"

# WFI-003 — wf-deploy asserted a deploy.yml that a project need not have. A
# user reading "deployed to production" when only CI ran cannot detect it.
assert_eq "wf-deploy checks what pushing main actually does" "true" \
  "$(grep -q '.github/workflows/\*.yml' "$LIB_ROOT/skills/wf-deploy/SKILL.md" && echo true || echo false)"
assert_eq "and no longer asserts a deploy workflow unconditionally" "false" \
  "$(grep -q 'Pushing `main` automatically triggers' "$LIB_ROOT/skills/wf-deploy/SKILL.md" && echo true || echo false)"
assert_eq "a blank production_url omits the live-site line" "true" \
  "$(grep -q 'omit the Live site line entirely' "$LIB_ROOT/skills/wf-deploy/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Feature worktrees are ignored by the planning branch (client-a WFI-032)"

# feature-branches/ is the workflow's own convention — wf-worktree-sparse.sh
# creates it — so a `git add -A` on develop committed an entire feature worktree
# into the planning branch.
assert_eq "install.sh seeds the ignore" "true" \
  "$(grep -q 'echo "feature-branches/" >> "\$GITIGNORE"' "$LIB_ROOT/install.sh" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A gate remembers it was answered (client-a WFI-047)"

# A skill re-derives its gating rule on every dispatch, and a CLOSED gate is
# indistinguishable from one never opened — both are just the absence of a gate
# file. So a plan whose spec-approval a human granted in writing gets re-gated
# on the next dispatch, and the next: each pass reproduces the condition, so the
# loop has no end. The only record of the approval was prose in findings.md,
# which nothing reads.
registry_add_row PLN-018 wire draft "—" "infra,contract"

st=$("$SCRIPT_DIR/wf-gate-status.sh" PLN-018 spec-approval 2>/dev/null)
assert_eq "an unasked gate is not answered" "false" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_ANSWERED='\\(.*\\)'$/\\1/p")"

"$SCRIPT_DIR/wf-gate-open.sh" PLN-018 spec-approval "Approve?" --skill wf-spec >/dev/null 2>&1
st=$("$SCRIPT_DIR/wf-gate-status.sh" PLN-018 spec-approval 2>/dev/null)
assert_eq "an open gate reads as open" "true" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_OPEN='\\(.*\\)'$/\\1/p")"
assert_eq "and not yet answered" "false" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_ANSWERED='\\(.*\\)'$/\\1/p")"

"$SCRIPT_DIR/wf-gate-close.sh" PLN-018 "plain approve, scope unchanged" >/dev/null 2>&1
st=$("$SCRIPT_DIR/wf-gate-status.sh" PLN-018 spec-approval 2>/dev/null)
assert_eq "a re-dispatch sees the answer, so it must not re-gate" "true" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_ANSWERED='\\(.*\\)'$/\\1/p")"
assert_eq "and the resolution is readable by a script, not just prose" \
  "plain approve, scope unchanged" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_RESOLUTION='\\(.*\\)'$/\\1/p")"

# An approval is given to a REVISION, not to an ID forever. Edit the plan and
# the question is genuinely open again.
printf '## Goal\nWire contract, now with extra scope\n' > plans/PLN-018-wire/plan.md
st=$("$SCRIPT_DIR/wf-gate-status.sh" PLN-018 spec-approval 2>/dev/null)
assert_eq "editing the plan after approval re-opens the question" "true" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_STALE='\\(.*\\)'$/\\1/p")"
assert_eq "and it no longer counts as answered" "false" \
  "$(printf '%s' "$st" | sed -n "s/^GATE_ANSWERED='\\(.*\\)'$/\\1/p")"

assert_eq "wf-spec checks before re-opening spec-approval" "true" \
  "$(awk '/^## Exit — unattended/, /^## Replanning/' "$LIB_ROOT/skills/wf-spec/SKILL.md" \
     | grep -q 'wf-gate-status.sh' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A commit carries only its own paths (client-a WFI-048/049)"

# `git add <paths> && git commit` does NOT commit those paths — it commits the
# whole index. On develop that index is shared: spec, consistency and test
# workers run concurrently in one working directory, and per-role caps do not
# help because the race is across roles.
#
# Both directions were observed within two minutes:
#   WFI-048 — a consistency commit swallowed a stranger's staged bug rename.
#   WFI-049 — a stranger's commit swallowed wf-spec's staged plan + REGISTRY
#             transition, leaving `git log --grep PLN-020` empty for a plan
#             that had been reviewed and approved.
CO_DIR="$TEST_DIR/commit"
mkdir -p "$CO_DIR/plans/PLN-020-x" "$CO_DIR/bugs/open/BUG-020-y" && (
  cd "$CO_DIR" && git init -q . && git config user.email t@t && git config user.name t
  printf '# bug\n'  > bugs/open/BUG-020-y/bug.md
  printf 'seed\n'   > seed.txt
  git add -A && git commit -qm init
) >/dev/null 2>&1

# A concurrent worker stages a bug rename; we then commit only our plan.
( cd "$CO_DIR" && mkdir -p bugs/triaged && git mv bugs/open/BUG-020-y bugs/triaged/BUG-020-y ) >/dev/null 2>&1
printf '# plan\n' > "$CO_DIR/plans/PLN-020-x/plan.md"
( cd "$CO_DIR" && "$SCRIPT_DIR/wf-commit.sh" "spec: PLN-020 — plan ready" --add plans/PLN-020-x/ ) >/dev/null 2>&1

assert_eq "the commit carries only the paths it was given" "plans/PLN-020-x/plan.md" \
  "$(cd "$CO_DIR" && git show --pretty=format: --name-only HEAD | tr -d '\n')"
assert_eq "a concurrent worker's staged work is left staged, not swallowed" "bugs/triaged/BUG-020-y/bug.md" \
  "$(cd "$CO_DIR" && git diff --cached --name-only | tr -d '\n')"
# WFI-049's real consequence: an unattended approval must be findable afterwards.
assert_eq "and the plan's own message stays attached to the plan's own change" "true" \
  "$(cd "$CO_DIR" && git log --grep 'PLN-020' --oneline | grep -q . && echo true || echo false)"

# An empty marker commit is the other way the index gets swept: a bare
# `git commit --allow-empty` commits whatever is staged.
( cd "$CO_DIR" && "$SCRIPT_DIR/wf-commit.sh" "test(PLN-020): complete" --allow-empty ) >/dev/null 2>&1
assert_eq "an empty marker commit changes no tree" "true" \
  "$(cd "$CO_DIR" && [ "$(git rev-parse 'HEAD^{tree}')" = "$(git rev-parse 'HEAD~1^{tree}')" ] && echo true || echo false)"
assert_eq "and still does not swallow the staged rename" "bugs/triaged/BUG-020-y/bug.md" \
  "$(cd "$CO_DIR" && git diff --cached --name-only | tr -d '\n')"

# Nothing to commit is a no-op, not a failure — skills call this unconditionally.
assert_ok "nothing to commit exits clean" \
  bash -c "cd '$CO_DIR' && '$SCRIPT_DIR/wf-commit.sh' 'spec: no change' --add plans/PLN-020-x/"

# The registry transition must travel WITH the findings that justify it, and
# still not pick up a bystander.
RU_DIR="$TEST_DIR/regcommit"
mkdir -p "$RU_DIR/plans/PLN-004-x" && (
  cd "$RU_DIR" && git init -qb develop . && git config user.email t@t && git config user.name t
  printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-004 | x | verify | — | — | 2026-08-04 | 2.00 | — | — |\n' > plans/REGISTRY.md
  printf 'f\n' > plans/PLN-004-x/findings.md
  printf 'other\n' > other.txt
  git add -A && git commit -qm init
  printf 'stranger\n' > other.txt && git add other.txt
  printf 'finding\n' >> plans/PLN-004-x/findings.md
) >/dev/null 2>&1
( cd "$RU_DIR" && "$SCRIPT_DIR/wf-registry-update.sh" PLN-004 verify active \
    --commit "verify(PLN-004): findings" --add plans/PLN-004-x/findings.md ) >/dev/null 2>&1

assert_eq "a transition commits together with its justification" "true" \
  "$(cd "$RU_DIR" && git show --pretty=format: --name-only HEAD | tr '\n' ' ' \
     | grep -q 'plans/PLN-004-x/findings.md' && echo true || echo false)"
assert_eq "and carries the REGISTRY row that changed" "true" \
  "$(cd "$RU_DIR" && git show --pretty=format: --name-only HEAD | grep -q 'plans/REGISTRY.md' && echo true || echo false)"
assert_eq "but not the bystander another worker staged" "other.txt" \
  "$(cd "$RU_DIR" && git diff --cached --name-only | tr -d '\n')"

# The skills that run on develop must not hand-roll `git add && git commit`.
for sk in wf-spec wf-consistency wf-bug wf-attend wf-brainstorm; do
  assert_eq "$sk commits through wf-commit.sh" "0" \
    "$(grep -c 'git commit -m' "$LIB_ROOT/skills/$sk/SKILL.md")"
done

# ═══════════════════════════════════════════════════════════════════════
section "Untracking the generated harness (v5.0.0 migration)"

# The client copy of the harness is build output. Tracking it meant deploy
# dirtied every client permanently — 253 files across five repos — and put a
# git-managed path under a second, independent writer. See
# docs/untracked-harness.md.
#
# The migration's one dangerous step is exercised here: the untrack commit
# DELETES those paths on develop, so a feature branch cut earlier loses them on
# its next `git merge develop` — mid-plan. wf-merge-develop.sh restoring the
# harness afterwards is what makes that survivable.
UT="$TEST_DIR/untracked"
mkdir -p "$UT" && (
  cd "$UT" && git init -qb develop . && git config user.email t@t && git config user.name t
  mkdir -p .claude/skills/wf-spec .claude/skills/ref-project scripts/v2.00
  printf 'spec v1\n'    > .claude/skills/wf-spec/SKILL.md
  printf 'mine\n'       > .claude/skills/ref-project/SKILL.md
  printf 'wf\n'         > .claude/workflow.md
  printf '#!/bin/sh\n'  > scripts/wf-exec.sh && chmod +x scripts/wf-exec.sh
  printf 'v\n'          > scripts/v2.00/wf-sample.sh
  printf 'feature-branches/\n' > .gitignore
  printf 'src\n' > src.txt
  git add -A && git commit -qm init
  git worktree add -q feature-branches/PLN-001-x -b feature/PLN-001-x HEAD
) >/dev/null 2>&1

assert_eq "before migrating, a worktree gets the harness from git" "true" \
  "$([ -f "$UT/feature-branches/PLN-001-x/.claude/skills/wf-spec/SKILL.md" ] && echo true || echo false)"

# The migration, on develop.
( cd "$UT"
  printf '.claude/skills/wf-*/\n.claude/workflow.md\nscripts/wf-exec.sh\nscripts/v*/\n' >> .gitignore
  git rm -r -q --cached .claude/skills/wf-spec .claude/workflow.md scripts/wf-exec.sh scripts/v2.00
  git add .gitignore && git commit -qm "chore: stop tracking the generated workflow harness"
) >/dev/null 2>&1

assert_eq "develop's tree is clean after the untrack commit" "0" \
  "$(git -C "$UT" status --porcelain | wc -l | xargs)"
assert_eq "the files are still on disk, just ignored" "true" \
  "$([ -f "$UT/scripts/wf-exec.sh" ] && [ -f "$UT/.claude/skills/wf-spec/SKILL.md" ] && echo true || echo false)"
assert_eq "a project's own skill stays tracked — the wf- prefix is load-bearing" "true" \
  "$(git -C "$UT" ls-files --error-unmatch .claude/skills/ref-project/SKILL.md >/dev/null 2>&1 && echo true || echo false)"

# THE DANGEROUS STEP: the live worktree merges develop and takes the deletion.
cp "$SCRIPT_DIR/wf-worktree-harness.sh" "$UT/scripts/" 2>/dev/null || true
( cd "$UT/feature-branches/PLN-001-x" && git merge develop --no-edit ) >/dev/null 2>&1
assert_eq "merging the migration strips the harness from a live worktree" "false" \
  "$([ -f "$UT/feature-branches/PLN-001-x/.claude/skills/wf-spec/SKILL.md" ] && echo true || echo false)"

# ...and the restore that makes it survivable.
( cd "$UT/feature-branches/PLN-001-x" && "$SCRIPT_DIR/wf-worktree-harness.sh" . ) >/dev/null 2>&1
assert_eq "the harness copier puts it back" "true" \
  "$([ -f "$UT/feature-branches/PLN-001-x/.claude/skills/wf-spec/SKILL.md" ] && echo true || echo false)"
assert_eq "wf-exec.sh too" "true" \
  "$([ -x "$UT/feature-branches/PLN-001-x/scripts/wf-exec.sh" ] && echo true || echo false)"
assert_eq "and the worktree is CLEAN — ignored files cannot dirty it" "0" \
  "$(git -C "$UT/feature-branches/PLN-001-x" status --porcelain | wc -l | xargs)"

# A later deploy changes the harness. Under tracking this is what dirtied every
# worktree and aborted the next merge; now it is invisible to git.
printf 'spec v2\n' > "$UT/.claude/skills/wf-spec/SKILL.md"
( cd "$UT/feature-branches/PLN-001-x" && "$SCRIPT_DIR/wf-worktree-harness.sh" . ) >/dev/null 2>&1
assert_eq "a mid-plan deploy leaves the worktree clean" "0" \
  "$(git -C "$UT/feature-branches/PLN-001-x" status --porcelain | wc -l | xargs)"
assert_eq "and the worktree has the new content" "spec v2" \
  "$(cat "$UT/feature-branches/PLN-001-x/.claude/skills/wf-spec/SKILL.md")"
assert_ok "so git merge develop still runs" \
  git -C "$UT/feature-branches/PLN-001-x" merge develop --no-edit

# MODIFY/DELETE is the shape this migration takes on any branch that ever ran
# the old infra-sync — which committed develop's bytes ONTO the feature branch,
# so the branch carries its own modifications to paths develop has since
# deleted. `git checkout develop -- <file>` then fails outright ("does not have
# their version") and the merge stays stuck. Hit for real on client-a's live
# PLN-004 worktree; every remaining client will hit it too.
MD="$TEST_DIR/modifydelete"
mkdir -p "$MD" && (
  cd "$MD" && git init -qb develop . && git config user.email t@t && git config user.name t
  mkdir -p .claude/skills/wf-spec scripts
  printf 'v1\n' > .claude/skills/wf-spec/SKILL.md
  printf 'v1\n' > scripts/wf-exec.sh && chmod +x scripts/wf-exec.sh
  printf 'feature-branches/\n' > .gitignore && printf 'code\n' > src.txt
  git add -A && git commit -qm init
  git worktree add -q feature-branches/wt -b feature/PLN-004-x HEAD
  # the old infra-sync behaviour: the BRANCH commits its own harness change
  cd feature-branches/wt && printf 'v2-branch\n' > .claude/skills/wf-spec/SKILL.md
  git add -A && git commit -qm "chore: sync workflow infra from develop"
  cd "$MD"
  printf 'v3-develop\n' > .claude/skills/wf-spec/SKILL.md
  git add -A && git commit -qm deploy
  printf '.claude/skills/wf-*/\nscripts/wf-exec.sh\n' >> .gitignore
  git rm -r -q --cached --ignore-unmatch .claude/skills/wf-* scripts/wf-exec.sh
  git add .gitignore && git commit -qm untrack
) >/dev/null 2>&1

( cd "$MD/feature-branches/wt" && "$SCRIPT_DIR/wf-merge-develop.sh" ) >/dev/null 2>&1
assert_eq "a modify/delete conflict on a deleted path resolves" "0" \
  "$(git -C "$MD/feature-branches/wt" ls-files -u | wc -l | xargs)"
assert_eq "the worktree is clean after taking the migration" "0" \
  "$(git -C "$MD/feature-branches/wt" status --porcelain | wc -l | xargs)"
assert_eq "and the harness is back on disk, from the main worktree" "v3-develop" \
  "$(cat "$MD/feature-branches/wt/.claude/skills/wf-spec/SKILL.md" 2>/dev/null)"
assert_eq "wf-exec.sh restored and executable" "true" \
  "$([ -x "$MD/feature-branches/wt/scripts/wf-exec.sh" ] && echo true || echo false)"

# install.sh must seed the ignores, or a client migrates halfway and re-dirties.
for pat in '.claude/skills/wf-\*/' '.claude/workflow.md' 'scripts/wf-exec.sh' 'scripts/v\*/'; do
  assert_eq "install.sh seeds the ignore for $pat" "true" \
    "$(grep -q "\"$pat\"" "$LIB_ROOT/install.sh" && echo true || echo false)"
done

# `git rm` is ATOMIC: one pathspec matching nothing tracked aborts the whole
# command and untracks nothing. app already ignored .claude/skills/*, so that
# pathspec matched no tracked file and the migration silently did nothing —
# hit for real while migrating it.
assert_eq "the printed migration command survives a pathspec that matches nothing" "true" \
  "$(grep -q 'git rm -r --cached --quiet --ignore-unmatch' "$LIB_ROOT/install.sh" && echo true || echo false)"

MIG="$TEST_DIR/atomicmig"
mkdir -p "$MIG/scripts" && (
  cd "$MIG" && git init -q . && git config user.email t@t && git config user.name t
  printf 'x\n' > scripts/wf-exec.sh
  printf 'x\n' > .gitignore
  git add -A && git commit -qm init
) >/dev/null 2>&1
# .claude/skills/wf-* is absent — exactly app's shape.
( cd "$MIG" && git rm -r --cached --quiet --ignore-unmatch .claude/skills/wf-* scripts/wf-exec.sh ) >/dev/null 2>&1
assert_eq "and it does untrack what IS tracked" "0" \
  "$(git -C "$MIG" ls-files scripts/wf-exec.sh | wc -l | xargs)"

# The v6 template swap used to drop plans/TEMPLATE.md.v5.bak beside the new
# one — an untracked file in a TRACKED directory that nothing ever removes.
# Three of five clients still carry one, so `deploy && status --porcelain`
# could never come back empty no matter how much of the harness got untracked.
# The old version is in git whenever the template is tracked, which is every
# client; the backup is only warranted when it is not.
assert_eq "the pre-v6 template backup is guarded by a tracked check" "true" \
  "$(awk '/if \[ "\$REPLACING" = true \]/, /^        fi$/' "$LIB_ROOT/install.sh" \
     | grep -q 'ls-files --error-unmatch "plans/TEMPLATE.md"' && echo true || echo false)"
assert_eq "and a tracked template is removed, not backed up" "true" \
  "$(awk '/ls-files --error-unmatch "plans\/TEMPLATE.md"/, /else/' "$LIB_ROOT/install.sh" \
     | grep -q 'rm -f "\$DEST"' && echo true || echo false)"
assert_eq "while an untracked one still keeps its copy" "true" \
  "$(awk '/ls-files --error-unmatch "plans\/TEMPLATE.md"/, /^            fi$/' "$LIB_ROOT/install.sh" \
     | grep -q 'mv "\$DEST" "\$DEST.v5.bak"' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "wf-commit stages each path on its own (client-a WFI-053/057)"

# `git add` is atomic across its pathspecs, and callers pass a fixed list that
# includes optional files. One missing file aborted the whole add, so nothing
# staged and the plan folder was silently left out of its own commit.
CMT="$TEST_DIR/commit"
mkdir -p "$CMT/scripts" "$CMT/plans/PLN-021-arg-injection"
cp "$SCRIPT_DIR/wf-commit.sh" "$SCRIPT_DIR/wf-lock.sh" "$CMT/scripts/"
(
  cd "$CMT" && git init -q . && git config user.email t@t && git config user.name t
  echo seed > seed.txt && git add seed.txt && git commit -qm seed
) >/dev/null 2>&1
echo "the plan" > "$CMT/plans/PLN-021-arg-injection/plan.md"
echo "registry" > "$CMT/plans/REGISTRY.md"

# plans/deferred-criteria.md does not exist — this project has never deferred one.
(cd "$CMT" && ./scripts/wf-commit.sh "spec: PLN-021" \
   --add plans/PLN-021-arg-injection/ plans/REGISTRY.md plans/deferred-criteria.md) >/dev/null 2>&1
assert_eq "a missing optional pathspec does not discard the rest of the add" "plans/PLN-021-arg-injection/plan.md" \
  "$(cd "$CMT" && git ls-files plans/PLN-021-arg-injection/plan.md)"
assert_eq "and the registry lands in the same commit" "plans/REGISTRY.md" \
  "$(cd "$CMT" && git ls-files plans/REGISTRY.md)"

# The other half: a failed add must not be reported as "nothing to commit".
# Under the orchestrator a concurrent worker holding .git/index.lock is routine,
# and the two outcomes had the same message AND the same exit code.
echo "changed" >> "$CMT/plans/REGISTRY.md"
touch "$CMT/.git/index.lock"
lock_out=$(cd "$CMT" && WF_LOCK_TIMEOUT=2 ./scripts/wf-commit.sh "workflow: file WFI-056" \
             --add plans/REGISTRY.md 2>&1); lock_rc=$?
rm -f "$CMT/.git/index.lock"
assert_eq "a held index.lock fails loudly rather than reporting nothing to commit" "1" "$lock_rc"
assert_eq "and does not print the benign skip message" "false" \
  "$(printf '%s' "$lock_out" | grep -q 'nothing to commit' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A CLI plan's human criteria still gate (client-a WFI-054)"

# wf-manual-lint reads a pre-v6 plan the v5 way and promotes every untagged
# criterion to eyes:blocking. wf-manual-gate then closed the gate because the
# diff touched no rendering surface — so in a CLI project, where no diff ever
# touches one, EVERY plan auto-completed EVERY human criterion. PLN-004 went
# testing → complete in ~40s with five criteria untested, two of them safety
# assertions about private key material on a shared drive.
GATE_DIR="$TEST_DIR/manualgate"
mkdir -p "$GATE_DIR/scripts" "$GATE_DIR/plans/PLN-004-tool-cli"
cp "$SCRIPT_DIR/wf-manual-gate.sh" "$SCRIPT_DIR/wf-manual-lint.sh" \
   "$SCRIPT_DIR/wf-plan-info.sh" "$SCRIPT_DIR/wf-orch-lib.sh" "$GATE_DIR/scripts/"
printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-004 | tool-cli | testing | — | — | 2026-08-04 | %s | — | — |\n' \
  "${SCRIPT_FOLDER#v}" > "$GATE_DIR/plans/REGISTRY.md"
# schema_version 5: no tags, exactly the population the surface rule mishandled.
cat > "$GATE_DIR/plans/PLN-004-tool-cli/plan.md" << 'PLANEOF'
schema_version: 5

## Goal
A CLI.

#### Manual
- [ ] tool take <handle> for a capsule with side effects stops for confirmation
- [ ] tool key export then tool key import leaves <drive>/keys/ empty afterwards
PLANEOF
printf 'manualTestGate:\n  requireRenderingSurface: true\n  minEyesCriteria: 1\n  blockOnCosmetic: false\n  renderingSurfaces:\n    - "src/**/wwwroot/**"\n' \
  > "$GATE_DIR/claude-workflow.yml"
# A real diff that touches no rendering surface — a CLI change. Without one the
# gate takes the "could not read the plan's diff" branch, which also gates, and
# the assertions below would pass for the wrong reason.
mkdir -p "$GATE_DIR/src/Cli"
(
  cd "$GATE_DIR" && git init -q . && git config user.email t@t && git config user.name t
  git add -A && git commit -qm seed
  echo 'class Program {}' > src/Cli/Program.cs
  git add -A && git commit -qm cli
) >/dev/null 2>&1

gate_out=$(cd "$GATE_DIR" && ./scripts/wf-manual-gate.sh PLN-004 2>/dev/null || true)
assert_eq "untagged criteria are counted as untagged, not silently as eyes" "2" \
  "$(printf '%s' "$gate_out" | grep "^MANUAL_OPEN_UNTAGGED=" | tr -d "MANUAL_OPEN_UNTAGGED='")"
assert_eq "a CLI plan whose diff renders nothing still gates" "GATE='true'" \
  "$(printf '%s' "$gate_out" | grep "^GATE=")"
assert_eq "and the reason names the untagged criteria, not the surface" "true" \
  "$(printf '%s' "$gate_out" | grep '^GATE_REASON=' | grep -q 'no reason tag' && echo true || echo false)"

# The surface rule must still work for the case it was written for: a v6 plan
# whose criteria someone actually tagged eyes:*.
cat > "$GATE_DIR/plans/PLN-004-tool-cli/plan.md" << 'PLANEOF'
schema_version: 6

## Goal
A CLI.

#### Manual
- [ ] (eyes:blocking) /app/board — the column spacing reads clearly at 1280px
PLANEOF
tagged_out=$(cd "$GATE_DIR" && ./scripts/wf-manual-gate.sh PLN-004 2>/dev/null || true)
assert_eq "a genuinely eyes-tagged criterion still skips on a surface miss" "GATE='false'" \
  "$(printf '%s' "$tagged_out" | grep "^GATE=")"

# ═══════════════════════════════════════════════════════════════════════
section "One gate is one record (client-a WFI-049)"

# GATE_QUESTION is free text and wf-spec's scope-reduction question embeds
# paragraphs. The lister emitted and counted LINES, so one open gate printed 11
# rows — 10 of them phantom, with empty ids — and reported GATES: 11.
GATES_DIR="$TEST_DIR/gates"
mkdir -p "$GATES_DIR/scripts" "$GATES_DIR/.claude/orchestrator/gates" "$GATES_DIR/plans"
cp "$SCRIPT_DIR/wf-list-gates.sh" "$SCRIPT_DIR/wf-orch-lib.sh" "$GATES_DIR/scripts/"
printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-004 | tool-cli | draft | — | — | 2026-08-04 | 2.00 | — | — |\n' \
  > "$GATES_DIR/plans/REGISTRY.md"
cat > "$GATES_DIR/.claude/orchestrator/gates/PLN-004.gate" << 'GATEEOF'
GATE_ID='PLN-004'
GATE_ARTIFACT='PLN-004'
GATE_NAME='scope-reduction'
GATE_QUESTION='The goal narrowed.

Goal: build the whole CLI.

After: build only tool take.

Reason: the rest depends on PLN-008.'
GATE_CONTEXT='replan'
GATE_SKILL='wf-spec'
GATE_OPENED='2026-08-04T14:47:36Z'
GATEEOF
(cd "$GATES_DIR" && git init -q . && git config user.email t@t && git config user.name t) >/dev/null 2>&1

gates_rows=$(cd "$GATES_DIR" && ./scripts/wf-list-gates.sh 2>/dev/null | wc -l | xargs)
gates_count=$(cd "$GATES_DIR" && ./scripts/wf-list-gates.sh 2>&1 >/dev/null | grep '^GATES:' || true)
assert_eq "a multi-line question still emits exactly one row" "1" "$gates_rows"
assert_eq "and the count reports gates, not lines" "GATES: 1" "$gates_count"
assert_eq "the question text survives, flattened onto the row" "true" \
  "$(cd "$GATES_DIR" && ./scripts/wf-list-gates.sh 2>/dev/null \
     | grep -q 'The goal narrowed. Goal: build the whole CLI.' && echo true || echo false)"
# The single-artifact probe is the dispatcher's "skip this one?" test and shares
# the same contract.
probe_rows=$(cd "$GATES_DIR" && ./scripts/wf-list-gates.sh PLN-004 2>/dev/null | wc -l | xargs)
assert_eq "the single-artifact probe is one row too" "1" "$probe_rows"

# ═══════════════════════════════════════════════════════════════════════
section "Dated amendments are counted (client-a WFI-051)"

# plans/TEMPLATE.md specifies "[date] — description", so every amendment is
# written `### [2026-08-04] — A9: ...`. The counting regex required the id
# immediately after the marker, so AMENDMENTS_NEW was always 0 — reported to a
# caller standing in front of the always-on scope-reduction gate.
DELTA="$TEST_DIR/goaldelta"
mkdir -p "$DELTA/scripts" "$DELTA/plans/PLN-004-tool-cli"
cp "$SCRIPT_DIR/wf-goal-delta.sh" "$SCRIPT_DIR/wf-plan-info.sh" "$DELTA/scripts/" 2>/dev/null || true
printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-004 | tool-cli | draft | — | — | 2026-08-04 | %s | — | — |\n' \
  "${SCRIPT_FOLDER#v}" > "$DELTA/plans/REGISTRY.md"
printf '## Goal\nBuild the CLI.\n\n## Amendments\n' > "$DELTA/plans/PLN-004-tool-cli/plan.md"
(
  cd "$DELTA" && git init -q . && git config user.email t@t && git config user.name t
  git add -A && git commit -qm seed
) >/dev/null 2>&1
printf '\n### [2026-08-04] — A9: narrow to tool take only\n' >> "$DELTA/plans/PLN-004-tool-cli/plan.md"
delta_out=$(cd "$DELTA" && ./scripts/wf-goal-delta.sh PLN-004 2>/dev/null || true)
assert_eq "an amendment written in the template's own dated form is counted" "1" \
  "$(printf '%s' "$delta_out" | grep '^AMENDMENTS_NEW:' | awk '{print $2}')"

# ═══════════════════════════════════════════════════════════════════════
section "Deferring a criterion ticks its box (client-a WFI-056)"

# The DC row is the program-wide record; the plan's checkbox is what a reader
# sees. Left unchecked, "deferred on purpose" and "silently dropped" look
# identical — the same ambiguity that made WFI-054 hard to notice.
DEFER="$TEST_DIR/defer"
mkdir -p "$DEFER/scripts" "$DEFER/plans/PLN-018-capsule-wire"
cp "$SCRIPT_DIR/wf-defer-criterion.sh" "$SCRIPT_DIR/wf-plan-info.sh" \
   "$SCRIPT_DIR/wf-orch-lib.sh" "$SCRIPT_DIR/wf-lock.sh" "$DEFER/scripts/"
printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-018 | capsule-wire | testing | — | — | 2026-08-04 | %s | — | — |\n' \
  "${SCRIPT_FOLDER#v}" > "$DEFER/plans/REGISTRY.md"
cat > "$DEFER/plans/PLN-018-capsule-wire/plan.md" << 'PLANEOF'
schema_version: 6

## Goal
Wire contract.

#### Manual
- [ ] (external) the relay accepts a sealed capsule from a real second device
PLANEOF
(cd "$DEFER" && git init -q . && git config user.email t@t && git config user.name t) >/dev/null 2>&1

(cd "$DEFER" && ./scripts/wf-defer-criterion.sh PLN-018 external \
   "the relay accepts a sealed capsule from a real second device" --prereq PLN-008) >/dev/null 2>&1
defer_line=$(grep -- '- \[' "$DEFER/plans/PLN-018-capsule-wire/plan.md")
assert_eq "the deferred criterion is checked off in its own plan" "true" \
  "$(printf '%s' "$defer_line" | grep -q '^- \[x\]' && echo true || echo false)"
assert_eq "and the line cites the DC id, so it cannot read as silently dropped" "true" \
  "$(printf '%s' "$defer_line" | grep -q 'deferred as DC-001' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Verify reads the branch's own config (client-a WFI-052)"

# claude-workflow.yml was located by walking up from SCRIPT_DIR, which
# wf-exec.sh always resolves to the MAIN worktree. A plan whose Step 1 adds a
# test project to testScopes commits that on its own branch; verify then read
# develop's config, did not see it, and filed a finding saying the scope was
# "never added" — citing the lines where the branch's own commit added it.
assert_eq "the config root is the invoking worktree when it has one" "true" \
  "$(grep -q 'CONFIG_ROOT="\$WORKTREE_ROOT"' "$SCRIPT_DIR/wf-test-scope.sh" && echo true || echo false)"
assert_eq "and the runner detection reads that same tree" "true" \
  "$(grep -q 'if \[ -f "\$CONFIG_ROOT/global.json" \]' "$SCRIPT_DIR/wf-test-scope.sh" && echo true || echo false)"
# On DEVELOP_ROOT, HEAD *is* develop, so this diff was empty by definition and
# the whole testMappings auto-detection could never fire.
assert_eq "the auto-detect diff runs in the branch worktree, not on develop" "true" \
  "$(grep -q 'changed_files=\$(git -C "\$CONFIG_ROOT" diff --name-only develop..HEAD' "$SCRIPT_DIR/wf-test-scope.sh" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Plan test commands come from the config (client-a WFI-055)"

# The planner wrote VSTest `--filter "FullyQualifiedName~X"` from its own
# knowledge. On Microsoft.Testing.Platform that is "Unknown option --filter",
# exit 5, zero tests run — and a verify agent reading the exit code fails a good
# plan. client-a's config had said `--filter-method` the whole time; the
# stale example in its seeded plans/TEMPLATE.md is what taught the wrong syntax.
assert_eq "wf-spec reads the filter flag from the config" "true" \
  "$(grep -q 'wf-config-get.sh test_filter_flag' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "and is warned off writing FullyQualifiedName from memory" "true" \
  "$(grep -q 'FullyQualifiedName~X`\*\* is \*\*VSTest\*\* syntax\|is \*\*VSTest\*\* syntax' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"
assert_eq "and told the seeded template is the stale one, not a second opinion" "true" \
  "$(grep -q 'never re-rendered' "$LIB_ROOT/skills/wf-spec/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A never-reviewed draft is dispatchable (client-a WFI-058)"

# The daemon reaches the spec role through wf-list-specable.sh, which emitted a
# draft plan only when its findings.md carried an unchecked box — the replanning
# shape. A draft that has a plan.md and has never been reviewed has empty
# findings, so nothing emitted it and the sweep could not see it. client-a
# stalled with 7 of them; PLN-008 gated five further plans while the spec slot
# sat idle at 0/1. A plan leaves `draft` only through a spec run.
SPEC_DIR="$TEST_DIR/specable"
mkdir -p "$SPEC_DIR/scripts" \
         "$SPEC_DIR/plans/PLN-008-capsule-take" \
         "$SPEC_DIR/plans/PLN-020-relay-wire" \
         "$SPEC_DIR/plans/PLN-030-row-only"
cp "$SCRIPT_DIR/wf-list-specable.sh" "$SPEC_DIR/scripts/"
cat > "$SPEC_DIR/plans/REGISTRY.md" << 'REGEOF'
| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-005 | done-already | ready | high | — | 2026-08-04 | 2.00 | — | — |
| PLN-008 | capsule-take | draft | high | — | 2026-08-04 | 2.00 | — | — |
| PLN-020 | relay-wire | draft | med | — | 2026-08-04 | 2.00 | — | — |
| PLN-030 | row-only | draft | low | — | 2026-08-04 | 2.00 | — | — |
REGEOF
echo '## Goal' > "$SPEC_DIR/plans/PLN-008-capsule-take/plan.md"
echo '## Goal' > "$SPEC_DIR/plans/PLN-020-relay-wire/plan.md"
printf -- '- [ ] ESCALATED: the wire format is undecided\n' \
  > "$SPEC_DIR/plans/PLN-020-relay-wire/findings.md"
# PLN-030 has a registry row and a folder but no plan.md: nothing to review yet,
# and it belongs to whatever created the row.
(cd "$SPEC_DIR" && git init -q . && git config user.email t@t && git config user.name t) >/dev/null 2>&1

spec_out=$(cd "$SPEC_DIR" && ./scripts/wf-list-specable.sh 2>/dev/null || true)
assert_eq "a draft with a plan.md and no findings is emitted" "true" \
  "$(printf '%s' "$spec_out" | grep -q '^PLN-008-capsule-take	never reviewed' && echo true || echo false)"
assert_eq "the replanning shape still is" "true" \
  "$(printf '%s' "$spec_out" | grep -q '^PLN-020-relay-wire	1 escalated' && echo true || echo false)"
# Escalated work has already been through the pipeline once, so something
# downstream is waiting on it; spec runs one at a time.
assert_eq "and escalated leads" "PLN-020-relay-wire" \
  "$(printf '%s' "$spec_out" | grep '^PLN-' | head -1 | cut -f1)"
assert_eq "a folder with no plan.md is left alone" "false" \
  "$(printf '%s' "$spec_out" | grep -q 'PLN-030' && echo true || echo false)"
assert_eq "a plan past draft is not spec work" "false" \
  "$(printf '%s' "$spec_out" | grep -q 'PLN-005' && echo true || echo false)"
# Both shapes ship under the existing header: the wf-spec entry menu parses
# exactly three section names and would drop rows under a fourth.
assert_eq "both shapes go out under # replanning" "1" \
  "$(printf '%s' "$spec_out" | grep -c '^# replanning' | xargs)"
assert_ok "the script reports work found" \
  bash -c "cd '$SPEC_DIR' && ./scripts/wf-list-specable.sh >/dev/null 2>&1"
# What candidates_spec() in wf-orchestrate.sh actually feeds the dispatcher.
assert_eq "the dispatcher's own parse yields both plans" "2" \
  "$(printf '%s\n' "$spec_out" | awk -F'\t' '/^# / { next } NF && $1 != "—" { print $1 }' | grep -c '^PLN-' | xargs)"

# One list populated and the other empty is the COMMON case, not the edge one —
# it is exactly what client-a had. Under `set -u` on bash 3.2, "${arr[@]}"
# of an empty array is an unbound variable, so the fix above printed the header
# and then exited 1 mid-list against the real registry.
rm -rf "$SPEC_DIR/plans/PLN-020-relay-wire"
only_unreviewed=$(cd "$SPEC_DIR" && ./scripts/wf-list-specable.sh 2>&1 || true)
assert_eq "unreviewed drafts with no escalated work list cleanly" "true" \
  "$(printf '%s' "$only_unreviewed" | grep -q 'unbound variable' && echo false || echo true)"
assert_eq "and the plan is still there" "true" \
  "$(printf '%s' "$only_unreviewed" | grep -q '^PLN-008-capsule-take	never reviewed' && echo true || echo false)"
assert_ok "and the exit code still says work is available" \
  bash -c "cd '$SPEC_DIR' && ./scripts/wf-list-specable.sh >/dev/null 2>&1"
# The mirror case: escalated only, no unreviewed.
rm -f "$SPEC_DIR/plans/PLN-008-capsule-take/plan.md"
printf -- '- [ ] ESCALATED: the wire format is undecided\n' \
  > "$SPEC_DIR/plans/PLN-008-capsule-take/findings.md"
only_escalated=$(cd "$SPEC_DIR" && ./scripts/wf-list-specable.sh 2>&1 || true)
assert_eq "escalated work with no unreviewed drafts lists cleanly" "true" \
  "$(printf '%s' "$only_escalated" | grep -q 'unbound variable' && echo false || echo true)"

# ═══════════════════════════════════════════════════════════════════════
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1m%d passed, 0 failed\033[0m\n' "$PASS"
  exit 0
else
  printf '\033[1;31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
  exit 1
fi
