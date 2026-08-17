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
out=$("$SCRIPT_DIR/wf-branch-check.sh" nonexistent-branch true 2>/dev/null)
assert_eq "a missing branch is created rather than failing silently" "true" \
  "$(printf '%s' "$out" | grep -q "CREATED_BRANCH='nonexistent-branch" && echo true || echo false)"
assert_eq "and the caller is told what it is now on" "true" \
  "$(printf '%s' "$out" | grep -q 'CURRENT_BRANCH=nonexistent-branch' && echo true || echo false)"
git checkout -q develop
git branch -q -D nonexistent-branch main 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════
section "Branch check stdout is an eval contract (client-a WFI-124)"

# Callers run `eval "$(wf-branch-check.sh develop true)"`. Switching a DIRTY
# checkout let git's carried-over "M <file>" list and wf-infra-reset.sh's
# progress note reach stdout, so eval tried to run them: `no matches found:
# (was  M)`, then `command not found: M` once per modified file.
# Empty output is not a pass: a script that printed nothing would satisfy
# "no stray lines" while telling the caller nothing.
stdout_is_assignments() {
  printf '%s\n' "$1" | awk '
    NF && $0 !~ /^[A-Z_]+=/ { bad = 1 }
    NF                      { seen = 1 }
    END { print (seen && !bad) ? "true" : "false" }'
}

# The file has to be tracked and identical on both branches, so the switch
# succeeds and git carries the edit across — which is when it prints the
# "M <file>" line that used to reach the caller's eval.
printf 'seed\n' > carried.txt
git add -A && git commit -q -m "wfi124 fixture: tracked file on develop"
git checkout -q -b feature/wfi124-side
printf 'local edit\n' >> carried.txt   # uncommitted
out=$("$SCRIPT_DIR/wf-branch-check.sh" develop true 2>/dev/null)
assert_eq "a dirty switch emits only KEY=VALUE lines" "true" "$(stdout_is_assignments "$out")"
assert_eq "and still reports the branch it landed on" "true" \
  "$(printf '%s' "$out" | grep -q 'CURRENT_BRANCH=develop' && echo true || echo false)"
assert_eq "and where it came from" "true" \
  "$(printf '%s' "$out" | grep -q 'SWITCHED_FROM=feature/wfi124-side' && echo true || echo false)"

git checkout -q -- carried.txt 2>/dev/null || true
git checkout -q develop
git rm -q carried.txt && git commit -q -m "wfi124 cleanup"
git branch -q -D feature/wfi124-side 2>/dev/null || true

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

# Deleting it from the library was only half the job: deploy writes scripts and
# never removed one, so every client installed before v5.0.0 still had the
# August copy of wf-infra-sync.sh sitting in scripts/v2.00/ at v6.7.0 — a
# script deleted precisely because running it commits develop's own bytes onto
# a feature branch. scripts/v*/ is generated, so anything there the library
# does not ship is residue.
assert_eq "deploy prunes a script the library no longer ships" "true" \
  "$(grep -q 'Removed stale scripts/\$folder_name/\$base' "$LIB_ROOT/install.sh" && echo true || echo false)"
assert_eq "and it prunes only inside the generated version folder" "true" \
  "$(grep -q 'for existing in "\$DEST_VDIR"/wf-\*.sh' "$LIB_ROOT/install.sh" && echo true || echo false)"
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

# Staged was never enough (client-a WFI-065): a dirty REGISTRY.md on the
# develop root is taken by any other worker's stash and carried by any other
# worker's commit, and a transition that evaporates mid-implementation reads to
# the next sweep as free work. So the transition commits itself, immediately,
# whether or not the caller passed --commit.
assert_eq "a transition without --commit commits itself" "true" \
  "$(git show --stat --name-only HEAD | grep -qx 'plans/REGISTRY.md' && echo true || echo false)"
assert_eq "and nothing is left dirty for someone else to pick up" "true" \
  "$(git diff --cached --name-only | grep -qx 'plans/REGISTRY.md' && echo false || echo true)"
assert_eq "and HEAD's registry holds the new state" "active" \
  "$(git show HEAD:plans/REGISTRY.md | grep '^| PLN-120 |' | awk -F'|' '{print $4}' | xargs)"
assert_eq "and the message names the transition" "true" \
  "$(git log -1 --format=%s | grep -q 'registry(PLN-120): ready → active' && echo true || echo false)"

# --no-commit is the opt-out, for a caller that really does want to bundle it.
registry_add_row PLN-121 staged-only ready
"$SCRIPT_DIR/wf-commit.sh" "add PLN-121" --add plans/REGISTRY.md >/dev/null 2>&1
"$SCRIPT_DIR/wf-registry-update.sh" PLN-121 ready active --no-commit >/dev/null 2>&1
assert_eq "--no-commit stages without committing" "true" \
  "$(git diff --cached --name-only | grep -qx 'plans/REGISTRY.md' && echo true || echo false)"
git commit -qm "implement(PLN-121-staged-only): carries its own transition" >/dev/null 2>&1

# Phase 3 named only progress.md and findings.md, so the plan.md checklist
# ticks that step 21 writes were dropped on the floor too.
#
# It is now one call rather than a transition followed by a `git add`: the
# `--add` carries the whole plan folder and wf-registry-update.sh stages
# REGISTRY.md itself, so the row and the files it describes share a commit.
# That also removes the window where the post-commit hook could fire against a
# transition that had not landed (WFI-079).
phase3=$(awk '/^25\. \*\*Move the plan to/,/^26\./' \
  "$LIB_ROOT/skills/wf-implement/SKILL.md")
assert_eq "Phase 3 commits the whole plan folder and the registry" "true" \
  "$(printf '%s' "$phase3" | grep -q -- '--add plans/PLN-NNN-<slug>/' && echo true || echo false)"
assert_eq "and carries the transition in that same commit" "true" \
  "$(printf '%s' "$phase3" | grep -q 'wf-registry-update.sh PLN-NNN active verify' && echo true || echo false)"
# The hook that launches the verify agent matches on the commit SUBJECT, so
# fusing the two commits only works if the fused one still says the words.
assert_eq "and its message still triggers the verify hook" "true" \
  "$(printf '%s' "$phase3" | grep -q -- '--commit "implement(PLN-NNN-<slug>): verified, moved to verify"' && echo true || echo false)"

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
cp "$SCRIPT_DIR/wf-test-scope.sh" "$SCRIPT_DIR/wf-plan-info.sh" \
   "$SCRIPT_DIR/wf-orch-lib.sh" "$SCOPE2/scripts/"
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

# The check must still fire for a counter that really is behind — but as a note,
# not a fault. wf-counter-next.sh derives its floor from the artifacts that
# exist and advances past drift, so the collision the old wording asserted
# cannot happen; the one way to cause it is to take the old advice and
# hand-edit the counter. client-a read a standing "1 problem(s)" on every
# /wf-status and /wf-board render for a registry with nothing wrong (WFI-133).
( cd "$SLUG" && sed -i.bak 's/<!-- Counter: 21 -->/<!-- Counter: 19 -->/' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak )
behind_audit=$(cd "$SLUG" && "$SCRIPT_DIR/wf-registry-audit.sh" 2>&1 || true)
assert_eq "a counter behind the highest live ID is still surfaced" "true" \
  "$(printf '%s' "$behind_audit" | grep -q 'COUNTER.*highest ID in use (20)' && echo true || echo false)"
assert_eq "and it says the allocator handles it, not 'set it by hand'" "true" \
  "$(printf '%s' "$behind_audit" | grep -q 'advances past it on its own' && echo true || echo false)"
assert_eq "no hand-edit is advised — that is the one way to cause a collision" "false" \
  "$(printf '%s' "$behind_audit" | grep -q 'Set it to' && echo true || echo false)"
assert_eq "and it does not count as a problem" "registry audit: clean" \
  "$(printf '%s' "$behind_audit" | grep 'registry audit:')"
# The allocator's own behaviour is the reason the audit can stand down.
( cd "$SLUG" && "$SCRIPT_DIR/wf-counter-next.sh" BUG >/dev/null 2>&1 ) || true
assert_eq "the next allocation skips every live ID rather than colliding" "true" \
  "$(cd "$SLUG" && grep -qE '<!-- Counter: 2[12] -->' plans/REGISTRY.md && echo true || echo false)"

assert_eq "wf-status runs the audit" "true" \
  "$(grep -q 'wf-registry-audit.sh' "$LIB_ROOT/skills/wf-status/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Claiming is not a mode-specific rule (client-a WFI-130)"

# "Claim the artifact before you read anything" lived inside wf-spec's
# Unattended-mode section, and the attended menu claimed on ONE path out of
# three — the escalated plan. So an attended session creating a plan from a bug
# wrote plans/PLN-NNN-<slug>/ and committed a draft REGISTRY row holding no
# claim, and a draft row is dispatchable the moment it is committed. The daemon
# put three unattended spec workers onto PLN-048/049/050 within ~3 minutes;
# both sessions then edited the same plan.md files.
spec_skill="$LIB_ROOT/skills/wf-spec/SKILL.md"
assert_eq "the rule has its own section, not a home inside Unattended mode" "true" \
  "$(grep -q '^## Claiming' "$spec_skill" && echo true || echo false)"
assert_eq "and says it applies in both modes" "true" \
  "$(grep -q 'before you read anything, in both modes' "$spec_skill" && echo true || echo false)"
for path in 'wf-claim.sh BUG-NNN`, then go to \[Plan from bug\]' 'wf-claim.sh BRF-NNN`, then go to step 1' 'wf-claim.sh PLN-NNN-<slug>`, then go to \[Replanning\]'; do
  assert_eq "the attended menu claims on this path: ${path%%\`*}" "true" \
    "$(grep -qE "$path" "$spec_skill" && echo true || echo false)"
done
# The unattended rule still exists — it is now a pointer, not a second copy.
assert_eq "unattended rule 0 still claims, with --if-free" "true" \
  "$(grep -q 'wf-claim.sh BRF-NNN --if-free' "$spec_skill" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A deploy owns its own changes (client-a WFI-131)"

# Almost everything install.sh writes is gitignored in the client. A handful of
# paths are deliberately not — the config, the entry contract, the version
# stamp — so a deploy left develop dirty and walked away. The next worker in
# read those as somebody else's work in progress and filed WFI-131 mid-plan;
# meanwhile they sat on the shared develop index, where the next wf-commit.sh
# from any live worker would have carried them under that plan's message.
DEPLOYC="$TEST_DIR/deployclient"
mkdir -p "$DEPLOYC" && (
  cd "$DEPLOYC" && git init -qb develop . && git config user.email t@t && git config user.name t
  echo '# app' > README.md && git add -A && git commit -qm seed
) >/dev/null 2>&1
# First run creates the config and stops; second run installs.
bash "$LIB_ROOT/install.sh" "$DEPLOYC" >/dev/null 2>&1 || true
( cd "$DEPLOYC" && sed -i.bak 's|^project_slug:.*|project_slug: "deployclient"|' claude-workflow.yml \
    && rm -f claude-workflow.yml.bak ) >/dev/null 2>&1
bash "$LIB_ROOT/install.sh" "$DEPLOYC" >/dev/null 2>&1 || true
( cd "$DEPLOYC" && git add -A && git commit -qm "install" ) >/dev/null 2>&1

# Dirty a tracked path the way a real deploy does (a config backfill, a new
# version stamp), then re-deploy.
printf '\n# forced change\n' >> "$DEPLOYC/claude-workflow.yml"
deploy_out=$(bash "$LIB_ROOT/install.sh" "$DEPLOYC" 2>&1 || true)
assert_eq "a re-deploy leaves the client's tree clean" "true" \
  "$(cd "$DEPLOYC" && git status --porcelain | grep -q . && echo false || echo true)"
assert_eq "and says what it landed" "true" \
  "$(printf '%s' "$deploy_out" | grep -q 'tree left clean' && echo true || echo false)"
assert_eq "under its own message, not a plan's" "true" \
  "$(cd "$DEPLOYC" && git log -1 --pretty=%s | grep -q '^chore: sync workflow harness to v' && echo true || echo false)"

# It must commit ONLY its own paths — never the shared index, which on develop
# holds every other live worker's staged work (WFI-122, WFI-123).
( cd "$DEPLOYC" && echo 'someone elses work' > other.txt && git add other.txt ) >/dev/null 2>&1
printf '\n# forced change\n' >> "$DEPLOYC/claude-workflow.yml"
bash "$LIB_ROOT/install.sh" "$DEPLOYC" >/dev/null 2>&1 || true
assert_eq "another worker's staged file is not swept into the deploy commit" "true" \
  "$(cd "$DEPLOYC" && git diff --cached --name-only | grep -qx 'other.txt' && echo true || echo false)"
( cd "$DEPLOYC" && git reset -q HEAD other.txt && rm -f other.txt ) >/dev/null 2>&1

# Off a pipeline branch, the deploy's changes are not this branch's to carry.
( cd "$DEPLOYC" && git checkout -q -- . && git checkout -q -b someones-session ) >/dev/null 2>&1
printf '\n# forced change\n' >> "$DEPLOYC/claude-workflow.yml"
foreign_out=$(bash "$LIB_ROOT/install.sh" "$DEPLOYC" 2>&1 || true)
assert_eq "on a foreign branch it says so instead of committing" "true" \
  "$(printf '%s' "$foreign_out" | grep -q "not a branch a deploy should commit to" && echo true || echo false)"
assert_eq "and leaves the change for develop to land" "true" \
  "$(cd "$DEPLOYC" && git status --porcelain | grep -q 'claude-workflow.yml' && echo true || echo false)"

# --no-commit restores the old behaviour for a caller that wants to bundle it.
( cd "$DEPLOYC" && git checkout -q develop && git checkout -q -- . ) >/dev/null 2>&1
printf '\n# forced change\n' >> "$DEPLOYC/claude-workflow.yml"
bash "$LIB_ROOT/install.sh" "$DEPLOYC" --no-commit >/dev/null 2>&1 || true
assert_eq "--no-commit leaves the tree dirty on purpose" "true" \
  "$(cd "$DEPLOYC" && git status --porcelain | grep -q 'claude-workflow.yml' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A test result carries proof of which tree it measured (client-a WFI-132)"

# An unattended tester recorded "Total: 1120, Passed: 1114, Failed: 6" against
# PLN-051 and gated saying the implementation "appears incomplete". The feature
# tree holds 1123 — the plan adds 3 — so 1120 is develop, which does not carry
# the fix. Verify's own run ten minutes earlier, in the right tree, was 1123/0.
# Three skills warned about this in prose already (WFI-094, WFI-098, WFI-105);
# prose did not hold, so the instruction is a precondition now.
TREE="$TEST_DIR/treecheck"
mkdir -p "$TREE" && (
  cd "$TREE" && git init -qb develop . && git config user.email t@t && git config user.name t
  echo seed > README.md && git add -A && git commit -qm seed
  git worktree add -q -b feature/PLN-051-mint-names feature-branches/PLN-051-mint-names
) >/dev/null 2>&1

assert_fails "a run from the main worktree is refused" \
  env -C "$TREE" "$SCRIPT_DIR/wf-test-tree.sh" PLN-051-mint-names
tree_err=$(cd "$TREE" && "$SCRIPT_DIR/wf-test-tree.sh" PLN-051-mint-names 2>&1 >/dev/null || true)
assert_eq "and says the result would be about develop, not this plan" "true" \
  "$(printf '%s' "$tree_err" | grep -q 'main worktree' && echo true || echo false)"
assert_eq "and gives the cd that fixes it" "true" \
  "$(printf '%s' "$tree_err" | grep -q 'Fix: cd .*feature-branches/PLN-051-mint-names' && echo true || echo false)"

tree_ok=$(cd "$TREE/feature-branches/PLN-051-mint-names" && "$SCRIPT_DIR/wf-test-tree.sh" PLN-051-mint-names)
assert_eq "from the plan's own worktree it stamps the run" "true" \
  "$(printf '%s' "$tree_ok" | grep -qE '^TREE feature-branches/PLN-051-mint-names @ feature/PLN-051-mint-names [0-9a-f]+ \(' && echo true || echo false)"

# Right path, wrong branch: the directory name says one plan and the code is
# another. The stamp must not vouch for that.
( cd "$TREE/feature-branches/PLN-051-mint-names" && git checkout -q -b feature/PLN-052-something-else ) >/dev/null 2>&1
assert_fails "a worktree moved off its own branch is refused too" \
  env -C "$TREE/feature-branches/PLN-051-mint-names" "$SCRIPT_DIR/wf-test-tree.sh" PLN-051-mint-names

assert_eq "wf-test chains the stamp ahead of the test command" "true" \
  "$(grep -q 'wf-test-tree.sh' "$LIB_ROOT/skills/wf-test/SKILL.md" && echo true || echo false)"
assert_eq "and forbids transcribing a figure from an earlier run" "true" \
  "$(grep -q 'Never transcribe a figure you did not just produce' "$LIB_ROOT/skills/wf-test/SKILL.md" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "Filing a bug goes through the counter (client-a WFI-133)"

# Every skill that files a bug carried the same instruction as a COMMENT —
# "create bugs/open/BUG-NNN-<slug>/bug.md with these fields". A comment
# addressed to a model is a suggestion: client-a hand-created BUG-051 and
# BUG-052, bypassing the counter, then reported that no script for this existed
# and reached for a `wf-bug-new.sh` that wasn't there.
BUGNEW="$TEST_DIR/bugnew"
mkdir -p "$BUGNEW/plans" "$BUGNEW/bugs/open" && (
  cd "$BUGNEW" && git init -qb develop . && git config user.email t@t && git config user.name t
  printf '| ID | Slug | State |\n|-|-|-|\n\n<!-- Counter: 40 -->\n' > plans/REGISTRY.md
  git add -A && git commit -qm seed
) >/dev/null 2>&1

bugnew_out=$(cd "$BUGNEW" && "$SCRIPT_DIR/wf-bug-new.sh" 'Guest logout loops forever' \
  --severity High --source agent:wf-test --description 'session cookie is never cleared' 2>/dev/null)
assert_eq "stdout is the eval contract and nothing else" "true" \
  "$(printf '%s' "$bugnew_out" | grep -qvE "^(BUG_ID|BUG_DIR)='.*'$" && echo false || echo true)"
eval "$bugnew_out"
assert_eq "the ID came from the counter, not from a guess" "BUG-040" "$BUG_ID"
assert_eq "the counter advanced" "true" \
  "$(grep -q '<!-- Counter: 41 -->' "$BUGNEW/plans/REGISTRY.md" && echo true || echo false)"
assert_eq "bug.md is written where wf-list-bugs.sh looks" "true" \
  "$([ -f "$BUGNEW/$BUG_DIR/bug.md" ] && echo true || echo false)"
assert_eq "and in the shape it parses" "BUG-040	High	Guest logout loops forever" \
  "$(cd "$BUGNEW" && "$SCRIPT_DIR/wf-list-bugs.sh" 2>/dev/null | grep '^BUG-040' | cut -f1-3)"
assert_eq "unstated fields are TBD, never invented" "true" \
  "$(grep -q '^TBD$' "$BUGNEW/$BUG_DIR/bug.md" && echo true || echo false)"
assert_eq "it commits its own work rather than leaving it staged" "true" \
  "$(cd "$BUGNEW" && git status --short | grep -q . && echo false || echo true)"
assert_fails "a bad severity is refused, not silently recorded" \
  env -C "$BUGNEW" "$SCRIPT_DIR/wf-bug-new.sh" 'whatever' --severity Urgent

# The skills that used to hand-write the folder now call it.
for skill in wf-bug wf-test wf-verify wf-implement; do
  assert_eq "$skill files through wf-bug-new.sh" "true" \
    "$(grep -q 'wf-bug-new.sh' "$LIB_ROOT/skills/$skill/SKILL.md" && echo true || echo false)"
done

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
#
# The diff has to be reachable the way the script looks for it: from the plan's
# own branch, or from `feature-branches/<plan>`. Anything else is somebody
# else's history — the script used to diff whatever directory it was called in,
# so on the develop root a registry commit read as "the plan changed the
# registry", and the surface rule then answered about that.
mkdir -p "$GATE_DIR/src/Cli"
(
  cd "$GATE_DIR" && git init -q . && git config user.email t@t && git config user.name t
  git add -A && git commit -qm seed
  git checkout -q -b develop
  git checkout -q -b feature/PLN-004-tool-cli
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
# whose criteria someone actually tagged eyes:* — and, since WFI-129, only for
# the cosmetic ones. Dismissing a COSMETIC criterion on a surface miss fails
# open: the plan ships unseen, which is the documented trade.
cat > "$GATE_DIR/plans/PLN-004-tool-cli/plan.md" << 'PLANEOF'
schema_version: 6

## Goal
A CLI.

#### Manual
- [ ] (eyes:cosmetic) /app/board — the column spacing reads clearly at 1280px
PLANEOF
tagged_out=$(cd "$GATE_DIR" && ./scripts/wf-manual-gate.sh PLN-004 2>/dev/null || true)
assert_eq "a cosmetic eyes criterion still skips on a surface miss" "GATE='false'" \
  "$(printf '%s' "$tagged_out" | grep "^GATE=")"

# A BLOCKING criterion fails into a deadlock instead: an unattended worker
# cannot judge it, and with no matching surface no gate opens, so the plan
# neither ships nor asks. client-a's PLN-041 sat in `testing` through three
# wf-test runs until the stuck detector noticed (WFI-129).
cat > "$GATE_DIR/plans/PLN-004-tool-cli/plan.md" << 'PLANEOF'
schema_version: 6

## Goal
A CLI.

#### Manual
- [ ] (eyes:blocking) tool --help — the command list is readable enough to use
PLANEOF
blocking_out=$(cd "$GATE_DIR" && ./scripts/wf-manual-gate.sh PLN-004 2>/dev/null || true)
assert_eq "a blocking eyes criterion gates even on a surface miss" "GATE='true'" \
  "$(printf '%s' "$blocking_out" | grep "^GATE=")"
assert_eq "and the reason names the blocking criterion, not the surface" "true" \
  "$(printf '%s' "$blocking_out" | grep '^GATE_REASON=' | grep -q 'eyes:blocking' && echo true || echo false)"

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
cp "$SCRIPT_DIR/wf-goal-delta.sh" "$SCRIPT_DIR/wf-plan-info.sh" \
   "$SCRIPT_DIR/wf-orch-lib.sh" "$DELTA/scripts/" 2>/dev/null || true
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
section "A formatted criterion still ticks (client-a WFI-137)"

# The tick was a literal substring match. The caller reads the criterion off
# the screen and types it back with the inline markdown gone, so any criterion
# a planner formatted — backticks round a command, ** round a conjunction —
# never matched, and the plan completed with the box still empty. Twice in one
# day on client-a (PLN-051, PLN-052).
DEFERMD="$TEST_DIR/defer-md"
mkdir -p "$DEFERMD/scripts" "$DEFERMD/plans/PLN-052-gitignore-probe"
cp "$SCRIPT_DIR/wf-defer-criterion.sh" "$SCRIPT_DIR/wf-plan-info.sh" \
   "$SCRIPT_DIR/wf-orch-lib.sh" "$SCRIPT_DIR/wf-lock.sh" "$DEFERMD/scripts/"
printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-052 | gitignore-probe | testing | — | — | 2026-08-14 | %s | — | — |\n' \
  "${SCRIPT_FOLDER#v}" > "$DEFERMD/plans/REGISTRY.md"
cat > "$DEFERMD/plans/PLN-052-gitignore-probe/plan.md" << 'PLANEOF'
schema_version: 6

## Goal
Probe the control path.

#### Manual
- [ ] (external) run `tool doctor` on `D:\git\Enterprise_DevDrive` **and** confirm `gitignore:ddN` names `.git/info/exclude`
PLANEOF
(cd "$DEFERMD" && git init -q . && git config user.email t@t && git config user.name t) >/dev/null 2>&1

# The stripped form — what a caller actually passes.
(cd "$DEFERMD" && ./scripts/wf-defer-criterion.sh PLN-052 external \
   'run tool doctor on D:\git\Enterprise_DevDrive and confirm gitignore:ddN names .git/info/exclude') >/dev/null 2>&1
defermd_line=$(grep -- '- \[' "$DEFERMD/plans/PLN-052-gitignore-probe/plan.md")
assert_eq "a criterion whose plan text carries backticks and ** still ticks" "true" \
  "$(printf '%s' "$defermd_line" | grep -q '^- \[x\]' && echo true || echo false)"
assert_eq "and cites its DC id" "true" \
  "$(printf '%s' "$defermd_line" | grep -q 'deferred as DC-001' && echo true || echo false)"
assert_eq "and the plan's own formatting survives the tick" "true" \
  "$(printf '%s' "$defermd_line" | grep -q '`tool doctor`' && echo true || echo false)"

# When it genuinely cannot match, the miss has to read as work to do — the
# worker treated the old lowercase 'note:' as informational and completed anyway.
defermd_miss=$(cd "$DEFERMD" && ./scripts/wf-defer-criterion.sh PLN-052 soak \
   'something no line in the plan resembles' 2>&1 >/dev/null || true)
assert_eq "an unmatched criterion says ACTION REQUIRED, not 'note'" "true" \
  "$(printf '%s' "$defermd_miss" | grep -q 'ACTION REQUIRED' && echo true || echo false)"

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
cp "$SCRIPT_DIR/wf-list-specable.sh" "$SCRIPT_DIR/wf-orch-lib.sh" "$SPEC_DIR/scripts/"
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
section "A rename commits both of its halves (client-a WFI-066)"

# `git diff --cached --name-only` reports a rename as ONE path — the
# destination. wf-commit.sh read its commit list back that way, so the source
# never reached the pathspec and its deletion stayed staged: HEAD held the same
# bug in bugs/open/ AND bugs/triaged/, and the next worklist re-offered the
# still-open copy as unplanned work.
cd "$TEST_DIR/main" || exit 1
mkdir -p bugs/open/BUG-900-dup bugs/triaged
echo 'a bug' > bugs/open/BUG-900-dup/bug.md
"$SCRIPT_DIR/wf-commit.sh" "bug: file BUG-900" --add bugs/ >/dev/null 2>&1
git mv bugs/open/BUG-900-dup bugs/triaged/BUG-900-dup >/dev/null 2>&1
"$SCRIPT_DIR/wf-commit.sh" "spec: consume BUG-900" --add bugs/ >/dev/null 2>&1
assert_eq "the triaged copy is committed" "true" \
  "$(git ls-tree -r --name-only HEAD | grep -qx 'bugs/triaged/BUG-900-dup/bug.md' && echo true || echo false)"
assert_eq "and the open copy is gone from HEAD, not merely from the worktree" "false" \
  "$(git ls-tree -r --name-only HEAD | grep -qx 'bugs/open/BUG-900-dup/bug.md' && echo true || echo false)"
assert_eq "and nothing is left staged" "true" \
  "$(git diff --cached --name-only | grep -q . && echo false || echo true)"

# ═══════════════════════════════════════════════════════════════════════
section "Closing a bug commits its own rename (client-a WFI-136)"

# wf-bug-close.sh left the rename staged and wf-test's completion commit was
# pathspec-scoped to bugs/closed/ — a path the caller chose without knowing the
# source side existed. The addition committed, the deletion did not, and six
# bugs ended up tracked at BOTH paths in the same HEAD, each with a stale
# `Status: Triaged` copy beside the authoritative closed one.
cd "$TEST_DIR/main" || exit 1
mkdir -p bugs/triaged/BUG-901-close bugs/closed
printf '# guest logout loops\n\n> **Status:** Triaged\n\n## Notes\n' \
  > bugs/triaged/BUG-901-close/bug.md
"$SCRIPT_DIR/wf-commit.sh" "bug: triage BUG-901" --add bugs/triaged/BUG-901-close >/dev/null 2>&1
"$SCRIPT_DIR/wf-bug-close.sh" BUG-901 PLN-901-claimed >/dev/null 2>&1
assert_eq "the closed copy is in HEAD" "true" \
  "$(git ls-tree -r --name-only HEAD | grep -qx 'bugs/closed/BUG-901-close/bug.md' && echo true || echo false)"
assert_eq "and the triaged copy is gone from HEAD, not just from the worktree" "false" \
  "$(git ls-tree -r --name-only HEAD | grep -qx 'bugs/triaged/BUG-901-close/bug.md' && echo true || echo false)"
assert_eq "the caller inherits nothing staged" "true" \
  "$(git diff --cached --name-only | grep -q . && echo false || echo true)"
assert_eq "and the commit is attributed to the bug, not to whoever commits next" "true" \
  "$(git log -1 --pretty=%s | grep -q '^bug(BUG-901): closed' && echo true || echo false)"

# --no-commit still exists for a caller that really does want to bundle it.
mkdir -p bugs/triaged/BUG-902-close
printf '# stale token\n\n> **Status:** Triaged\n\n## Notes\n' > bugs/triaged/BUG-902-close/bug.md
"$SCRIPT_DIR/wf-commit.sh" "bug: triage BUG-902" --add bugs/triaged/BUG-902-close >/dev/null 2>&1
"$SCRIPT_DIR/wf-bug-close.sh" BUG-902 PLN-901-claimed --no-commit >/dev/null 2>&1
assert_eq "--no-commit leaves the move staged for the caller" "true" \
  "$(git diff --cached --name-only | grep -q 'BUG-902-close' && echo true || echo false)"
"$SCRIPT_DIR/wf-commit.sh" "test: bundle BUG-902" \
  --add bugs/triaged/BUG-902-close bugs/closed/BUG-902-close >/dev/null 2>&1

# A bug that somehow reached both paths reports as closed, not as work to redo.
mkdir -p bugs/triaged/BUG-903-dup bugs/closed/BUG-903-dup
printf '# double\n\n> **Status:** Triaged\n' > bugs/triaged/BUG-903-dup/bug.md
printf '# double\n\n> **Status:** Closed\n' > bugs/closed/BUG-903-dup/bug.md
assert_eq "a bug tracked at two paths is not re-offered as triaged" "false" \
  "$("$SCRIPT_DIR/wf-list-bugs.sh" 2>/dev/null | grep -q 'BUG-903' && echo true || echo false)"
rm -rf bugs/triaged/BUG-903-dup bugs/closed/BUG-903-dup

# ═══════════════════════════════════════════════════════════════════════
section "A claim names a process that outlives the shell (client-a WFI-062)"

# The PID walk compared `ps -o comm=` against bare shell names, which never
# match on macOS (comm is `/bin/zsh`). The walk stopped on its first step and
# recorded the transient shell that ran the script — dead by the next tool
# call — so every attended claim read as stale and the daemon dispatched
# unattended workers straight into worktrees a human was using.
registry_add_row PLN-901 claimed active
# The claim file keys on the artifact number under .claude/orchestrator/, not
# on the plan folder — a brief being specced has no folder and still needs one
# (client-c WFI-004).
claim_901=".claude/orchestrator/claims/901/.wf-claim"
"$SCRIPT_DIR/wf-claim.sh" PLN-901-claimed >/dev/null 2>&1
claim_pid=$(sed -n '2p' "$claim_901")
assert_eq "the claim records a live process" "true" \
  "$(kill -0 "$claim_pid" 2>/dev/null && echo true || echo false)"
assert_eq "and not the shell that has already exited" "false" \
  "$([ "$claim_pid" = "$$" ] && echo true || echo false)"
# The claim above names this test's own process tree, which as of 5.3.0 reads
# as *ours* rather than a stranger's (WFI-073/075/076: a dispatched worker used
# to stand down against the claim its own dispatcher took out for it). So the
# "somebody else is in here" half of WFI-062 has to be posed with an owner that
# is genuinely foreign — a live process this one did not descend from.
sleep 30 & other_session=$!
printf '%s\n%s\n' "$(date +%s)" "$other_session" > "$claim_901"
assert_eq "so the plan reads as processing, not free" "processing" \
  "$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null | awk -F'\t' '$2 == "PLN-901-claimed" { print $1 }')"

# --if-free is what lets a second worker stand down instead of racing.
assert_fails "a live claim refuses a second claimant" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-901-claimed --if-free
{ kill "$other_session"; wait "$other_session"; } 2>/dev/null
# A claim whose owner is gone must not park the artifact forever.
printf '%s\n999999\n' "$(date +%s)" > "$claim_901"
assert_ok "a dead owner's claim is reaped" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-901-claimed --if-free
"$SCRIPT_DIR/wf-unclaim.sh" PLN-901-claimed >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "An open gate is part of eligibility (client-a WFI-063)"

# The dispatcher checked gates before spawning; wf-list-implementable.sh, which
# every human and skill treats as the source of truth for what is buildable,
# did not. An implementer landed on a plan carrying an unanswered
# consistency-migration gate with the worklist calling it ordinary `new` work.
registry_add_row PLN-902 gated ready
mkdir -p .claude/orchestrator/gates
cat > .claude/orchestrator/gates/PLN-902.gate << 'GATEEOF'
GATE_ID='PLN-902'
GATE_ARTIFACT='PLN-902'
GATE_NAME='consistency-migration'
GATE_QUESTION='Which capsule format wins?'
GATE_CONTEXT=''
GATE_SKILL='wf-consistency'
GATE_OPENED='2026-08-04T19:45:44Z'
GATEEOF
gated_out=$("$SCRIPT_DIR/wf-list-implementable.sh" 2>/dev/null || true)
assert_eq "a gated plan is not offered as new work" "gated" \
  "$(printf '%s' "$gated_out" | awk -F'\t' '$2 == "PLN-902-gated" { print $1 }')"
assert_eq "and the row names the gate that holds it" "consistency-migration" \
  "$(printf '%s' "$gated_out" | awk -F'\t' '$2 == "PLN-902-gated" { print $5 }')"
assert_eq "the dispatcher's own parse drops it" "false" \
  "$(printf '%s' "$gated_out" \
     | awk -F'\t' '$1 == "new" || $1 == "resume" || $1 == "fix" { print $2 }' \
     | grep -qx 'PLN-902-gated' && echo true || echo false)"
rm -f .claude/orchestrator/gates/PLN-902.gate

# ═══════════════════════════════════════════════════════════════════════
section "An answered gate can be recorded after the fact (client-a WFI-060)"

# The resolved-gate ledger was introduced after some gates had already closed,
# and there was no way to write a resolution proven by commit history into it.
# wf-spec then re-derived its gating rule, saw GATE_ANSWERED=false, and re-asked
# a question the user had answered in writing.
registry_add_row PLN-903 backfill draft
"$SCRIPT_DIR/wf-gate-close.sh" PLN-903 "approved as reviewed (5c369e2)" --gate spec-approval >/dev/null 2>&1
eval "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-903 spec-approval)"
assert_eq "the backfilled resolution answers the gate" "true" "$GATE_ANSWERED"
assert_eq "and carries the evidence forward" "approved as reviewed (5c369e2)" "$GATE_RESOLUTION"
# Scoped to the revision, like any other resolution: edit the plan and it re-opens.
echo 'a new step' >> plans/PLN-903-backfill/plan.md
eval "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-903 spec-approval)"
assert_eq "an edited plan makes it stale again" "true" "$GATE_STALE"

# ═══════════════════════════════════════════════════════════════════════
section "A review says which text it judged (client-a WFI-069)"

# Staleness was a comparison of two day-granular dates, so a plan reviewed and
# amended in one session — every replan that finishes in one sitting — was
# unorderable. The script correctly said `unknown`, and wf-spec's gate condition
# ("REVIEW_STALE must be false") could then never be met.
registry_add_row PLN-904 stamped draft
cat > plans/PLN-904-stamped/plan.md << 'PLANEOF'
# Stamped

## Goal
Prove staleness is answerable.

## Amendments
2026-08-04 — narrowed the wire format.

## Review
> **2026-08-04 — Plan Review (round 1 of 3)**
> **Result:** Approved
PLANEOF
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-904)"
assert_eq "same-day review and amendment are unorderable by date" "unknown" "$REVIEW_STALE"
"$SCRIPT_DIR/wf-review-stamp.sh" PLN-904 >/dev/null 2>&1
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-904)"
assert_eq "a stamp settles it" "false" "$REVIEW_STALE"
assert_eq "and says it is stamped" "true" "$REVIEW_STAMPED"
assert_eq "the verdict survives stamping" "Approved" "$REVIEW_RESULT"
# Amend after the stamp and it is stale — definitively, not by date. The
# amendment goes in the plan BODY: writing more rounds into `## Review` is not
# an edit to the thing under review, which is why the hash excludes it.
awk '/^## Review/ && !done { print "2026-08-04 — dropped the retry path."; done = 1 } { print }' \
  plans/PLN-904-stamped/plan.md > plans/PLN-904-stamped/plan.tmp \
  && mv plans/PLN-904-stamped/plan.tmp plans/PLN-904-stamped/plan.md
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-904)"
assert_eq "editing the plan makes the verdict stale" "true" "$REVIEW_STALE"
# Re-stamping after a re-review replaces the old stamp rather than stacking.
"$SCRIPT_DIR/wf-review-stamp.sh" PLN-904 >/dev/null 2>&1
assert_eq "one stamp, not two" "1" \
  "$(grep -c 'wf-review-stamp' plans/PLN-904-stamped/plan.md | xargs)"

# ═══════════════════════════════════════════════════════════════════════
section "Progress ticks and registry rows are durable (client-a WFI-064, WFI-065)"

# Both files sat dirty on the develop root for the length of an implementation.
# Any other worker's `git stash push --include-untracked` takes every dirty file
# in that working tree, so a 2/6 checklist reverted to 0/6 and a whole
# ready→active transition vanished — which the next sweep reads as free work.
registry_add_row PLN-905 durable ready
cat > plans/PLN-905-durable/progress.md << 'PROGEOF'
# Progress — PLN-905

## Steps
- [ ] Step 1: wire the reader
- [ ] Step 2: wire the writer

## Log
PROGEOF
"$SCRIPT_DIR/wf-commit.sh" "spec: seed PLN-905" --add plans/ >/dev/null 2>&1
"$SCRIPT_DIR/wf-registry-update.sh" PLN-905 ready active feature/PLN-905-durable >/dev/null 2>&1
"$SCRIPT_DIR/wf-progress-tick.sh" PLN-905 1 "wired the reader" >/dev/null 2>&1

# The test for durability is the one that actually happened: a concurrent
# worker stashes the whole working tree and pops it later.
git stash push --include-untracked -m "another worker" >/dev/null 2>&1 || true
assert_eq "the transition survives a stranger's stash" "active" "$(registry_state PLN-905)"
assert_eq "and so does the tick" "1" \
  "$("$SCRIPT_DIR/wf-progress-count.sh" PLN-905 | cut -d/ -f1)"
git stash pop >/dev/null 2>&1 || true
"$SCRIPT_DIR/wf-unclaim.sh" PLN-905-durable >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "A stamp tracks the spec, not the bookkeeping (client-a WFI-092, WFI-093, WFI-095)"

# Three mechanical writes moved the hashed body while the specification stood
# still, and each one made wf-spec's replan gate ("REVIEW_STALE must be false")
# demand a fresh architectural review of byte-identical text:
#   - ticking a Verification Checklist box, which implement and verify do every
#     cycle (WFI-095);
#   - wf-goal-pop.sh resolving a Goal History row (WFI-092, WFI-093).
registry_add_row PLN-906 fingerprint draft
cat > plans/PLN-906-fingerprint/plan.md << 'PLANEOF'
# Fingerprint

## Goal
Prove the fingerprint tracks the specification.

### Goal History
| Date | Previous Goal | Trigger | Resolution |
|-|-|-|-|

## Verification Checklist
- [ ] Build passes
- [ ] Tests pass

## Review
> **2026-08-06 — Plan Review (round 1 of 3)**
> **Result:** Approved
PLANEOF
"$SCRIPT_DIR/wf-review-stamp.sh" PLN-906 >/dev/null 2>&1
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-906)"
assert_eq "the stamp starts fresh" "false" "$REVIEW_STALE"

sed 's/- \[ \] Build passes/- [x] Build passes/' plans/PLN-906-fingerprint/plan.md \
  > plans/PLN-906-fingerprint/plan.tmp && mv plans/PLN-906-fingerprint/plan.tmp plans/PLN-906-fingerprint/plan.md
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-906)"
assert_eq "ticking a criterion is not a spec change" "false" "$REVIEW_STALE"

# Adding one is. The box state is normalised; the text is not.
awk '/^- \[ \] Tests pass/ { print; print "- [ ] Docs updated"; next } { print }' \
  plans/PLN-906-fingerprint/plan.md > plans/PLN-906-fingerprint/plan.tmp \
  && mv plans/PLN-906-fingerprint/plan.tmp plans/PLN-906-fingerprint/plan.md
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-906)"
assert_eq "adding a criterion is" "true" "$REVIEW_STALE"

# Goal History is script-managed end to end: push archives a row, pop resolves
# it. Neither is a decision anyone reviewed.
"$SCRIPT_DIR/wf-review-stamp.sh" PLN-906 >/dev/null 2>&1
"$SCRIPT_DIR/wf-goal-push.sh" PLN-906 "Fix the two verify findings" "Verify: 2 findings" >/dev/null 2>&1
"$SCRIPT_DIR/wf-goal-pop.sh" PLN-906 >/dev/null 2>&1
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-906)"
assert_eq "a push and pop that restore the goal leave the verdict standing" "false" "$REVIEW_STALE"

# The Goal one-liner itself stays in the hash — a scope reduction is exactly
# what a stale verdict has to catch, which is why wf-spec stamps AFTER the pop.
"$SCRIPT_DIR/wf-goal-amend.sh" PLN-906 "Prove much less than promised" --reason "scope reduction" >/dev/null 2>&1
eval "$("$SCRIPT_DIR/wf-review-status.sh" PLN-906)"
assert_eq "changing what the plan promises is" "true" "$REVIEW_STALE"

# --no-commit leaves the stamp for the caller's own commit, so a replan lands
# under a message describing the amendment rather than "stamp review" (WFI-085).
"$SCRIPT_DIR/wf-commit.sh" "spec: PLN-906 amended" --add plans/PLN-906-fingerprint/ >/dev/null 2>&1
"$SCRIPT_DIR/wf-review-stamp.sh" PLN-906 --no-commit >/dev/null 2>&1
assert_eq "--no-commit stages the stamp instead of committing it" "true" \
  "$(git diff --cached --name-only | grep -q 'PLN-906-fingerprint/plan.md' && echo true || echo false)"
assert_eq "and the last commit is still the caller's" "spec: PLN-906 amended" \
  "$(git log -1 --pretty=%s)"
"$SCRIPT_DIR/wf-commit.sh" "spec: PLN-906 stamped" --add plans/PLN-906-fingerprint/ >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "A goal a human corrected stays corrected (client-a WFI-084)"

# The scope-reduction gate says to amend the Goal so it describes what will be
# built. Mid-fix-cycle the live one-liner is the pushed SUB-goal; the promise
# the reduction contradicts is archived in Goal History, and pop restores that
# text verbatim. Nothing could edit it, so accepting a reduction by amending
# only the live line let the unreduced promise come back and undo the human.
registry_add_row PLN-907 archived-goal draft
printf '# Archived\n\n## Goal\nShip a browser timer and a CLI timer.\n' > plans/PLN-907-archived-goal/plan.md
"$SCRIPT_DIR/wf-goal-push.sh" PLN-907 "Fix the auth bypass" "Verify: 1 ESCALATED" >/dev/null 2>&1
"$SCRIPT_DIR/wf-goal-amend.sh" PLN-907 "Ship a CLI timer." --reason "browser timer deferred to BRF-908" >/dev/null 2>&1

# The live goal is untouched: the fix cycle is still about the auth bypass.
assert_eq "the active sub-goal is left alone" "Fix the auth bypass" \
  "$(grep -A1 '^## Goal' plans/PLN-907-archived-goal/plan.md | tail -1)"
"$SCRIPT_DIR/wf-goal-pop.sh" PLN-907 >/dev/null 2>&1
assert_eq "the pop restores the CORRECTED promise" "Ship a CLI timer." \
  "$(grep -A1 '^## Goal' plans/PLN-907-archived-goal/plan.md | tail -1)"
assert_eq "and the reason is on the record" "true" \
  "$(grep -q 'goal amended .*browser timer deferred to BRF-908' plans/PLN-907-archived-goal/plan.md && echo true || echo false)"

# With nothing pending restore, the same call amends the live one-liner.
"$SCRIPT_DIR/wf-goal-amend.sh" PLN-907 "Ship a CLI timer with --watch." >/dev/null 2>&1
assert_eq "no archived row means amend the live goal" "Ship a CLI timer with --watch." \
  "$(grep -A1 '^## Goal' plans/PLN-907-archived-goal/plan.md | tail -1)"

# ═══════════════════════════════════════════════════════════════════════
section "A routing tag is a tag, not a substring (client-a WFI-089)"

# The grep matched ESCALATED / PLAN-SCOPED anywhere in an unchecked finding, so
# a finding whose body explained why a tag did NOT apply routed the plan on the
# strength of its own prose. The only way out was to reword the sentence.
mkdir -p plans/PLN-908-routing
cat > plans/PLN-908-routing/findings.md << 'FEOF'
## Verify — 2026-08-06

- [ ] **Code**: the guard runs after the write — a code-only fix, not `← PLAN-SCOPED`
FEOF
assert_eq "prose naming a tag does not wear it" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-908-routing)"
printf -- '- [ ] **Design**: the auth model cannot express this ← ESCALATED\n' >> plans/PLN-908-routing/findings.md
assert_eq "a trailing tag still routes" "escalated" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-908-routing)"

# ═══════════════════════════════════════════════════════════════════════
section "A worker's own claim does not block its successor (client-a WFI-086, WFI-091)"

# The exit contract is: commit the transition, close the gate, unclaim. So the
# post-commit hook that starts verify ALWAYS fires while implement still holds
# the claim, and the spawn guard declined every single time — the hook's inline
# spawn was structurally dead for the exact order the skill mandates. The
# trigger belongs at the release, which is the first moment every guard can
# answer honestly.
registry_add_row PLN-909 deferred-spawn verify
export WF_CLAIM_PID=$$
printf '%s\n%s\n' "$(date +%s)" "$$" > plans/PLN-909-deferred-spawn/.wf-claim
out=$("$SCRIPT_DIR/wf-spawn.sh" verify PLN-909-deferred-spawn --dry-run 2>&1); rc=$?
assert_eq "a spawn behind our own claim is queued, not declined outright" "true" \
  "$(printf '%s' "$out" | grep -q 'queued until it is released' && echo true || echo false)"
assert_eq "and says so with 'nothing to do' rather than an error" "2" "$rc"

# --dry-run reports the deferral and writes nothing, which is what lets the
# dispatcher's own `--sweep --dry-run` delegate here for the real answer instead
# of printing "would spawn" past guards it never ran (WFI-160).
assert_eq "a dry run does not write the marker" "false" \
  "$([ -f .claude/orchestrator/pending/909-verify.spawn ] && echo true || echo false)"

"$SCRIPT_DIR/wf-spawn.sh" verify PLN-909-deferred-spawn >/dev/null 2>&1 || true
assert_eq "the marker is keyed on the artifact number" "true" \
  "$([ -f .claude/orchestrator/pending/909-verify.spawn ] && echo true || echo false)"

# A stranger's claim is still a hard stop — the guard did not simply get weaker.
# A live process that is NOT one of our ancestors: a child qualifies, init does
# not (kill -0 1 fails for an unprivileged user, so the claim reads as dead).
sleep 30 & stranger=$!
disown "$stranger" 2>/dev/null || true
printf '%s\n%s\n' "$(date +%s)" "$stranger" > plans/PLN-909-deferred-spawn/.wf-claim
out=$("$SCRIPT_DIR/wf-spawn.sh" verify PLN-909-deferred-spawn --dry-run 2>&1)
assert_eq "someone else's claim still declines" "true" \
  "$(printf '%s' "$out" | grep -q 'claimed by a live session' && echo true || echo false)"
kill "$stranger" 2>/dev/null || true

# Releasing serves the queue. Launching a real worker is out of scope here, so
# move the plan to a state no role acts on first: wf-spawn.sh then declines at
# its own last-moment state check, after the release has done its part.
"$SCRIPT_DIR/wf-registry-update.sh" PLN-909 verify testing >/dev/null 2>&1
"$SCRIPT_DIR/wf-registry-update.sh" PLN-909 testing complete >/dev/null 2>&1
printf '%s\n%s\n' "$(date +%s)" "$$" > plans/PLN-909-deferred-spawn/.wf-claim
"$SCRIPT_DIR/wf-unclaim.sh" PLN-909-deferred-spawn >/dev/null 2>&1
assert_eq "the release consumes the deferred spawn" "false" \
  "$([ -f .claude/orchestrator/pending/909-verify.spawn ] && echo true || echo false)"
assert_eq "and the claim is gone" "false" \
  "$([ -f plans/PLN-909-deferred-spawn/.wf-claim ] && echo true || echo false)"
unset WF_CLAIM_PID

# ═══════════════════════════════════════════════════════════════════════
section "Config values arrive unquoted (client-a WFI-088, WFI-090)"

# install.sh stripped double quotes only, and every filter example is
# single-quoted YAML because the value itself contains double quotes. So the
# rendered skill said `dotnet test '--ignore-exit-code 8 --filter-not-namespace
# "*E2E*"'` — two flags fused into one unrecognised argument. The filter was
# ignored, the full suite ran, and the run failed on the very e2e test the
# filter existed to exclude.
cfg_probe=$(mktemp -d)
cat > "$cfg_probe/claude-workflow.yml" << 'CFGEOF'
test_exclude_e2e: '--ignore-exit-code 8 --filter-not-namespace "*E2E*"'
build_command: "dotnet build"
CFGEOF
extract=$(awk '/^get_config\(\)/,/^}/' "$LIB_ROOT/install.sh")
value=$(CONFIG_FILE="$cfg_probe/claude-workflow.yml" bash -c "$extract"$'\nget_config test_exclude_e2e')
assert_eq "single-quoted YAML loses its quotes" '--ignore-exit-code 8 --filter-not-namespace "*E2E*"' "$value"
value=$(CONFIG_FILE="$cfg_probe/claude-workflow.yml" bash -c "$extract"$'\nget_config build_command')
assert_eq "so does double-quoted YAML" 'dotnet build' "$value"
rm -rf "$cfg_probe"

# ═══════════════════════════════════════════════════════════════════════
section "A gate is presented against the state it can be answered from (client-a WFI-082)"

# A gate outlives the state it was opened in. A manual-test gate left behind by
# an earlier bug sat on a plan that had gone back to draft with five unaddressed
# findings; the queue showed it as ordinary work and sent the attendant to
# /wf-test, which cannot run on a draft plan.
registry_add_row PLN-910 stale-gate draft
"$SCRIPT_DIR/wf-gate-open.sh" PLN-910 manual-test "Ready to test?" --skill wf-test >/dev/null 2>&1
row=$("$SCRIPT_DIR/wf-list-gates.sh" PLN-910 2>/dev/null)
assert_eq "the row carries the plan's current state" "draft" "$(printf '%s' "$row" | cut -f7)"
assert_eq "and says the gate cannot be answered from there" "mismatch" "$(printf '%s' "$row" | cut -f8)"
"$SCRIPT_DIR/wf-registry-update.sh" PLN-910 draft testing >/dev/null 2>&1
assert_eq "in the state it belongs to, it is ordinary work" "ok" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" PLN-910 2>/dev/null | cut -f8)"
# A gate any state can answer makes no claim, so it never reads as stale.
"$SCRIPT_DIR/wf-gate-close.sh" PLN-910 "tested" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-open.sh" PLN-910 needs-input "Which way?" --skill wf-implement >/dev/null 2>&1
assert_eq "needs-input fits any state" "ok" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" PLN-910 2>/dev/null | cut -f8)"
# …except a terminal one. A gate that outlives its plan's completion asks a
# question the pipeline has already answered. client-a's WFI-126: a
# needs-input gate reading "land PLN-039 and drive it through the pipeline"
# listed state=complete fit=ok, 45 minutes after PLN-039 was committed, merged,
# completed and promoted to main. Answering it as written would have re-landed
# all of it; only reading git history caught that.
"$SCRIPT_DIR/wf-registry-update.sh" PLN-910 testing complete >/dev/null 2>&1
assert_eq "but not once the plan is complete" "mismatch" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" PLN-910 2>/dev/null | cut -f8)"
"$SCRIPT_DIR/wf-registry-update.sh" PLN-910 complete abandoned >/dev/null 2>&1
assert_eq "nor abandoned" "mismatch" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" PLN-910 2>/dev/null | cut -f8)"
"$SCRIPT_DIR/wf-registry-update.sh" PLN-910 abandoned testing >/dev/null 2>&1
# The six documented fields are untouched — consumers index by position.
assert_eq "the original contract still holds at field 6" "0" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" PLN-910 2>/dev/null | cut -f6)"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-910 "answered" >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "A bounce with nothing to build goes back to the tester (client-a WFI-096)"

# A tester filed a behavior finding, the replan found it did not reproduce, and
# neither `ready` nor `active` fitted: `active` dispatches a builder onto an
# empty work list and re-runs a scoped verify the same tip already passed. The
# orchestrator refused to guess and parked on a gate that blocked eight plans.
registry_add_row PLN-911 not-reproducible draft feature/PLN-911-not-reproducible
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-911" >/dev/null 2>&1
git worktree add -q -b feature/PLN-911-not-reproducible "$TEST_DIR/wt-911" develop 2>/dev/null
cat > plans/PLN-911-not-reproducible/findings.md << 'FEOF'
## Human Test — 2026-08-07

- [x] **Behavior**: stylesheet link missing from app.html — did not reproduce; the re-test ran from the develop root
FEOF
cat > plans/PLN-911-not-reproducible/progress.md << 'PEOF'
# Progress — PLN-911

## Steps
- [x] Step 1: add the link
PEOF
assert_eq "an answered human-test bounce with a live worktree goes to testing" "testing" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-911)"

# One outstanding finding and it is a fix cycle again.
printf -- '- [ ] **Behavior**: the second one does reproduce\n' >> plans/PLN-911-not-reproducible/findings.md
assert_eq "an outstanding finding is still a fix cycle" "active" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-911)"

# A verify bounce has code to answer even when every finding is checked off —
# only the tester's own bounce can go straight back to the tester.
cat > plans/PLN-911-not-reproducible/findings.md << 'FEOF'
## Human Test — 2026-08-07

- [x] **Behavior**: did not reproduce

## Verify — 2026-08-08

- [x] **Code**: null guard added
FEOF
assert_eq "a verify bounce still routes to the builder" "active" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-911)"

# And an unfinished checklist means there is work outstanding whatever the
# findings say.
cat > plans/PLN-911-not-reproducible/findings.md << 'FEOF'
## Human Test — 2026-08-07

- [x] **Behavior**: did not reproduce
FEOF
printf -- '- [ ] Step 2: wire the reader\n' >> plans/PLN-911-not-reproducible/progress.md
assert_eq "an unfinished checklist keeps it with the builder" "active" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-911)"
git worktree remove --force "$TEST_DIR/wt-911" >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "A resolved issue is not re-resolved (this sweep)"

# --resolve rewrote whatever Status line it found, so re-running it over an
# entry closed months ago replaced the original date and the version that
# actually carried the fix — a silent rewrite of the record the file exists
# to be. Found by doing it: this sweep overwrote four of client-a's.
cat > WORKFLOW-ISSUES.md << 'IEOF'
# Workflow Issues

<!-- New entries are inserted directly below this line, newest first. -->

## WFI-001 — wf-spec — 2026-08-01T10:00:00Z

**Status:** resolved 2026-08-02 — fixed in v5.2.4
**Workflow version:** 5.0.15

## WFI-002 — wf-test — 2026-08-01T09:00:00Z

**Status:** open
**Workflow version:** 5.0.15
IEOF
"$SCRIPT_DIR/wf-issue.sh" --resolve WFI-001 "fixed in v9.9.9" >/dev/null 2>&1
assert_eq "an already-resolved entry keeps its original record" "true" \
  "$(grep -q '^\*\*Status:\*\* resolved 2026-08-02 — fixed in v5.2.4$' WORKFLOW-ISSUES.md && echo true || echo false)"
assert_eq "and the caller is told why nothing happened" "true" \
  "$("$SCRIPT_DIR/wf-issue.sh" --resolve WFI-001 "fixed in v9.9.9" 2>&1 | grep -q 'not overwriting' && echo true || echo false)"
"$SCRIPT_DIR/wf-issue.sh" --resolve WFI-002 "fixed in v5.5.1" >/dev/null 2>&1
assert_eq "an open entry still resolves" "true" \
  "$(grep -q "^\*\*Status:\*\* resolved .* — fixed in v5.5.1$" WORKFLOW-ISSUES.md && echo true || echo false)"
rm -f WORKFLOW-ISSUES.md

# ═══════════════════════════════════════════════════════════════════════
section "A goal pop reads the Goal History table, not any table (client-e WFI-013)"

# wf-goal-pop.sh found its row with `grep "| — |$"` over the whole file. A plan
# amended by A3 carries withdrawn Tests rows whose last cell is a bare em dash,
# and PLN-100 had one: the pop wrote `~~E2E~~` into `## Goal`, stamped
# "Resolved" onto the Tests row, and reported success. `## Goal` is what
# wf-plan-info.sh feeds to wf-implement, wf-test and every PR description.
registry_add_row PLN-913 goal-scope draft
cat > plans/PLN-913-goal-scope/plan.md << 'PLAN913'
# PLN-913

## Goal

Remove the duplicated brochure pages

### Goal History
| Date | Previous Goal | Trigger | Resolution |
|-|-|-|-|
| 2026-08-07 | Retire the duplicate brochure routes | Verify: 2 findings | — |

## Tests

| ID | Type | Notes | Command |
|-|-|-|-|
| ~~T14~~ | ~~E2E~~ | **Withdrawn by A3** | — |
PLAN913

"$SCRIPT_DIR/wf-goal-pop.sh" PLN-913 >/dev/null 2>&1
goal913=$(awk '/^## Goal([ \t]|$)/ { g = 1; next } g && /^#/ { exit } g && NF { print; exit }' \
  plans/PLN-913-goal-scope/plan.md)
assert_eq "the pop restores the archived goal" "Retire the duplicate brochure routes" "$goal913"
assert_eq "and does not write a Tests cell into the goal" "false" \
  "$(printf '%s' "$goal913" | grep -q 'E2E' && echo true || echo false)"
assert_eq "the withdrawn Tests row is left alone" "true" \
  "$(grep -q '| ~~T14~~ | ~~E2E~~ | \*\*Withdrawn by A3\*\* | — |' plans/PLN-913-goal-scope/plan.md && echo true || echo false)"
assert_eq "and the history row is the one marked resolved" "true" \
  "$(grep -q '| Retire the duplicate brochure routes | Verify: 2 findings | Resolved' plans/PLN-913-goal-scope/plan.md && echo true || echo false)"

# Nothing left to pop is an error, not a silent grab at some other table.
assert_fails "a second pop finds no unresolved row" \
  "$SCRIPT_DIR/wf-goal-pop.sh" PLN-913

# client-a's PLN-007 printed "Goal restored: '2'" and wrote `2` as the whole
# `## Goal` one-liner, exit 0 — the only signal was the 2 in the success line
# (WFI-097). A goal is a sentence; a lone token is a column index that went
# somewhere it should not have, and writing it is worse than failing.
registry_add_row PLN-915 goal-guard draft
cat > plans/PLN-915-goal-guard/plan.md << 'PLAN915'
# PLN-915

## Goal
The live sub-goal that must survive a refusal

### Goal History
| Date | Previous Goal | Trigger | Resolution |
|-|-|-|-|
| 2026-08-08 | 2 | Human Test | — |
PLAN915

assert_fails "a pop refuses to restore something that is not a goal" \
  "$SCRIPT_DIR/wf-goal-pop.sh" PLN-915
assert_eq "and leaves the live goal standing" "true" \
  "$(grep -q '^The live sub-goal that must survive a refusal$' plans/PLN-915-goal-guard/plan.md && echo true || echo false)"
assert_eq "and does not stamp the row it refused" "true" \
  "$(grep -q '| 2026-08-08 | 2 | Human Test | — |' plans/PLN-915-goal-guard/plan.md && echo true || echo false)"

# wf-goal-amend.sh matched rows the same way, so it could rewrite a Tests row
# with the plan's goal.
registry_add_row PLN-914 amend-scope draft
cat > plans/PLN-914-amend-scope/plan.md << 'PLAN914'
# PLN-914

## Goal
The live sub-goal

## Tests

| ID | Type | Notes | Command |
|-|-|-|-|
| ~~T9~~ | ~~E2E~~ | Withdrawn | — |
PLAN914

"$SCRIPT_DIR/wf-goal-amend.sh" PLN-914 "A narrower promise" >/dev/null 2>&1
assert_eq "an amend with no history row edits the live goal" "true" \
  "$(grep -q '^A narrower promise$' plans/PLN-914-amend-scope/plan.md && echo true || echo false)"
assert_eq "and leaves the Tests table untouched" "true" \
  "$(grep -q '| ~~T9~~ | ~~E2E~~ | Withdrawn | — |' plans/PLN-914-amend-scope/plan.md && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A merge that deletes the harness is recoverable (client-c WFI-006)"

# The harness is gitignored as of 5.0.0, so the first merge that carries the
# untrack commit onto a branch which still tracks it deletes the files from
# disk — and nothing puts them back. client-c lost 106 files including
# wf-exec.sh inside /wf-release step 5 and found out at step 8, exit 127.
harness_repo=$(mktemp -d)
(
  cd "$harness_repo" || exit 1
  git init -qb main && git config user.email t@t && git config user.name t
  mkdir -p scripts/v2.00 .claude/skills/wf-spec
  printf '#!/bin/sh\n' > scripts/wf-exec.sh && chmod +x scripts/wf-exec.sh
  printf 'x\n' > scripts/version-map.txt
  printf '#!/bin/sh\n' > scripts/v2.00/wf-claim.sh
  printf 'skill\n' > .claude/skills/wf-spec/SKILL.md
  printf 'the project own tooling\n' > scripts/my-own-tool.sh
  git add -A && git commit -qm "tracked harness"

  git checkout -qb release
  git rm -r --cached -q scripts/wf-exec.sh scripts/version-map.txt scripts/v2.00 .claude/skills/wf-spec
  printf 'scripts/wf-exec.sh\nscripts/version-map.txt\nscripts/v2.00/\n.claude/skills/wf-*/\n' > .gitignore
  git add .gitignore && git commit -qm "chore: stop tracking generated workflow harness"

  git checkout -q main && git merge -q --no-edit release -m merge
) >/dev/null 2>&1

assert_eq "the merge deletes the harness from disk" "false" \
  "$([ -x "$harness_repo/scripts/wf-exec.sh" ] && echo true || echo false)"
assert_fails "--check reports it missing rather than passing silently" \
  bash -c "cd '$harness_repo' && '$SCRIPT_DIR/wf-harness-restore.sh' --check"

( cd "$harness_repo" && "$SCRIPT_DIR/wf-harness-restore.sh" ) >/dev/null 2>&1
assert_eq "the restore puts the dispatcher back" "true" \
  "$([ -x "$harness_repo/scripts/wf-exec.sh" ] && echo true || echo false)"
assert_eq "and the versioned scripts with it" "true" \
  "$([ -f "$harness_repo/scripts/v2.00/wf-claim.sh" ] && echo true || echo false)"
assert_eq "and the skills" "true" \
  "$([ -f "$harness_repo/.claude/skills/wf-spec/SKILL.md" ] && echo true || echo false)"
assert_eq "the tree is left clean, not dirty with restored files" "" \
  "$(git -C "$harness_repo" status --porcelain)"
assert_eq "the restored harness is untracked, as the ignore rules say" "false" \
  "$(git -C "$harness_repo" ls-files | grep -q 'scripts/wf-exec.sh' && echo true || echo false)"
# The recovery must never reach for scripts/ wholesale: a project keeps its own
# tooling there, and untracking it would turn a recovery into a bigger accident.
assert_eq "the project's own tooling is still tracked" "true" \
  "$(git -C "$harness_repo" ls-files | grep -q 'scripts/my-own-tool.sh' && echo true || echo false)"
rm -rf "$harness_repo"

# ═══════════════════════════════════════════════════════════════════════
section ".plan-ref stays in its worktree (client-a WFI-103)"

# .plan-ref names the plan a WORKTREE is building. It was COMMITTED until
# v6.0.0, so it rode every merge out of that worktree — feature → release →
# main → develop. client-a found develop tracking a .plan-ref reading
# PLN-015, carried in by that plan's own PR merge. The next worktree cut from
# develop is then born pointing at a finished plan.
assert_eq "install.sh seeds the .plan-ref ignore" "true" \
  "$(grep -q '^    echo "\.plan-ref" >> "\$GITIGNORE"' "$LIB_ROOT/install.sh" && echo true || echo false)"
# .gitignore never untracks what is already in the index, so a pre-v6.0.0
# client keeps propagating it until told to run the one-time removal.
assert_eq "install.sh prints the untrack migration when it is still tracked" "true" \
  "$(grep -q 'git rm --cached --quiet --ignore-unmatch \.plan-ref' "$LIB_ROOT/install.sh" && echo true || echo false)"
assert_eq "wf-implement no longer commits it" "false" \
  "$(grep -q 'commit -m "chore(PLN-NNN): add \.plan-ref"' "$LIB_ROOT/skills/wf-implement/SKILL.md" && echo true || echo false)"
assert_eq "and says not to" "true" \
  "$(grep -q '\*\*Do not commit it\.\*\*' "$LIB_ROOT/skills/wf-implement/SKILL.md" && echo true || echo false)"

# A branch cut BEFORE the migration still tracks it, so the conflict path is
# still reachable — and must resolve by dropping it from the index while
# leaving the right ID on disk. Re-adding it (what the old code did) puts the
# leak straight back on the very merge that was supposed to end it.
PR="$TEST_DIR/planref"
mkdir -p "$PR" && (
  cd "$PR" && git init -qb develop . && git config user.email t@t && git config user.name t
  printf 'feature-branches/\n.plan-ref\n' > .gitignore
  printf 'code\n' > src.txt
  printf 'PLN-001\n' > .plan-ref
  git add -A -f && git commit -qm "init with a tracked .plan-ref"
  git worktree add -q feature-branches/wt -b feature/PLN-042-x HEAD
  cd feature-branches/wt && printf 'PLN-042\n' > .plan-ref
  git add -f .plan-ref && git commit -qm "chore(PLN-042): add .plan-ref"
  cd "$PR"
  printf 'PLN-002\n' > .plan-ref
  git add -f .plan-ref && git commit -qm "another plan leaked its ref onto develop"
) >/dev/null 2>&1

( cd "$PR/feature-branches/wt" && "$SCRIPT_DIR/wf-merge-develop.sh" ) >/dev/null 2>&1
assert_eq "the .plan-ref conflict resolves" "0" \
  "$(git -C "$PR/feature-branches/wt" ls-files -u | wc -l | xargs)"
assert_eq "the worktree still knows which plan it is building" "PLN-042" \
  "$(cat "$PR/feature-branches/wt/.plan-ref" 2>/dev/null)"
assert_eq "but git no longer carries it" "false" \
  "$(git -C "$PR/feature-branches/wt" ls-files --error-unmatch .plan-ref >/dev/null 2>&1 && echo true || echo false)"
assert_eq "and the tree is clean, so the merge to develop takes nothing along" "0" \
  "$(git -C "$PR/feature-branches/wt" status --porcelain | wc -l | xargs)"

# ═══════════════════════════════════════════════════════════════════════
section "Routing reads the plan wherever the caller stands (client-a WFI-117)"

# `plans/` is sparse-excluded from every feature worktree, and verify runs
# inside one. A CWD-relative read found nothing there, and the missing-file
# branch answered `clean` — the one verdict that sends a plan onward to
# testing. The same findings.md answered `active` from the develop root. Two
# opposite verdicts, byte-identical output, no warning.
cd "$TEST_DIR/main" || exit 1
registry_add_row PLN-920 route-cwd verify
cat > plans/PLN-920-route-cwd/findings.md << 'FEOF'
## Verify — 2026-08-10

- [ ] **Code**: the guard runs after the write
FEOF
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-920" >/dev/null 2>&1
# The worktree is cut BEFORE findings.md is written, so `plans/PLN-920-route-cwd`
# genuinely does not resolve against its CWD — the client's exact shape.
git worktree add -q -b feature/PLN-920 "$TEST_DIR/wt-909" HEAD~1 2>/dev/null \
  || git worktree add -q -b feature/PLN-920 "$TEST_DIR/wt-909" develop 2>/dev/null
rm -rf "$TEST_DIR/wt-909/plans"

assert_eq "an unchecked finding routes active from the develop root" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-920-route-cwd 2>/dev/null)"
assert_eq "and reads the same from inside the feature worktree" "active" \
  "$(env -C "$TEST_DIR/wt-909" "$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-920-route-cwd 2>/dev/null)"
assert_eq "an absolute path still works" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" "$TEST_DIR/main/plans/PLN-920-route-cwd" 2>/dev/null)"

# "I could not look" must never wear the same output as "I looked and it was
# clean" — that verdict promotes a plan.
assert_fails "a plan directory that exists nowhere is an error, not a verdict" \
  "$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-999-does-not-exist
assert_eq "and it emits no verdict at all" "" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-999-does-not-exist 2>/dev/null || true)"

# A plan dir with no findings.md is the genuine clean case and still routes.
mkdir -p plans/PLN-920-route-cwd-empty
assert_eq "no findings.md in a real plan dir is still clean" "clean" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-920-route-cwd-empty 2>/dev/null)"

# ═══════════════════════════════════════════════════════════════════════
section "A tick names one step, not a family (client-a WFI-115)"

# The label was reduced to its leading digits, so a checklist written as
# `Step 1a-i` … `Step 1a-v`, `Step 1b` collapsed to six rows all keyed `1` and
# one `wf-progress-tick.sh PLN-016 1` ticked every one of them — including a
# soak window that could not close for another three weeks.
registry_add_row PLN-921 sub-lettered active
cat > plans/PLN-921-sub-lettered/progress.md << 'PEOF'
# PLN-921

## Steps

- [ ] Step 1a-i: parse the input
- [ ] Step 1a-ii: validate it
- [ ] Step 1b: soak window, closes 2026-09-03
- [ ] Step 2: wire the command
- [ ] Step 12: the last one

## Log
PEOF
git add -A >/dev/null 2>&1 && git commit -qm "add PLN-921" >/dev/null 2>&1

ticked() { grep -c "^- \[x\] Step $1" plans/PLN-921-sub-lettered/progress.md | xargs; }

assert_fails "the bare family label is refused" \
  "$SCRIPT_DIR/wf-progress-tick.sh" PLN-921 1 "everything at once"
# Captured first, then matched: the refusal exits 1, and under `pipefail` a
# pipeline off it reports that failure no matter what grep found.
tick_refusal=$("$SCRIPT_DIR/wf-progress-tick.sh" PLN-921 1 x 2>&1 || true)
assert_eq "the refusal names the rows it could have meant" "true" \
  "$(printf '%s' "$tick_refusal" | grep -q '1a-i 1a-ii 1b' && echo true || echo false)"
assert_eq "and nothing was ticked" "0/5" "$("$SCRIPT_DIR/wf-progress-count.sh" PLN-921)"
# Nor invented: appending `- [x] Step 1` beside `Step 1a-i` would corrupt the
# one checklist the orchestrator reads for forward progress.
assert_eq "nor was a bogus row appended" "0" "$(ticked 1$)"

"$SCRIPT_DIR/wf-progress-tick.sh" PLN-921 1a-i "parsed" >/dev/null 2>&1
assert_eq "the named sub-step ticks" "1" "$(ticked '1a-i')"
assert_eq "and only that one" "1/5" "$("$SCRIPT_DIR/wf-progress-count.sh" PLN-921)"
assert_eq "the soak window is untouched" "0" "$(ticked '1b')"

# `2` must not reach `12` either — the same prefix bug, one digit over.
"$SCRIPT_DIR/wf-progress-tick.sh" PLN-921 2 "wired" >/dev/null 2>&1
assert_eq "a plain step still ticks" "1" "$(ticked '2:')"
assert_eq "and does not reach the step it prefixes" "0" "$(ticked '12')"
assert_eq "two of five" "2/5" "$("$SCRIPT_DIR/wf-progress-count.sh" PLN-921)"

# A label matching nothing at all is still an amendment's new step (WFI-111).
"$SCRIPT_DIR/wf-progress-tick.sh" PLN-921 7 "added by amendment" >/dev/null 2>&1
assert_eq "an unheard-of step is still appended, ticked" "3/6" \
  "$("$SCRIPT_DIR/wf-progress-count.sh" PLN-921)"

# ═══════════════════════════════════════════════════════════════════════
section "A Test Scope bullet may carry a comment (client-a WFI-116)"

# Plans justify a scope inline —
#   - vectors <!-- A3: Step 1a edits src/Tracker.Cli/**, mapped to vectors -->
# — and the comment was read as part of the category name, so the key missed
# and the scope was dropped with a "warning: unknown category". client-a
# kept `vectors` only because testMappings auto-detected it from the same diff;
# a plan whose changed files did not also map to it would have silently lost
# the category and run a narrower suite than it declared.
#
# wf-test-scope.sh finds its config by walking up from its OWN directory, so
# the fixture needs a copy of the scripts beside a claude-workflow.yml.
if ! command -v yq >/dev/null 2>&1; then
  printf '  \033[33m—\033[0m skipped: yq not installed\n'
else
  SC="$TEST_DIR/scope-comment"
  mkdir -p "$SC/plans/PLN-950-annotated" "$SC/plans/PLN-951-bare"
  cp -R "$LIB_SCRIPTS" "$SC/scripts"
  cat > "$SC/claude-workflow.yml" << 'YEOF'
project_slug: scope-fixture
testScopes:
  vectors:
    - Demo.Vector.Tests
testScopeMandatory: []
YEOF
  cp "$LIB_ROOT/templates/plans/REGISTRY.md" "$SC/plans/REGISTRY.md"
  awk '/<!-- Counter:/ && !d {
         print "| PLN-950 | annotated | draft | — | — | 2026-08-02 | 2.00 | — | — |"
         print "| PLN-951 | bare | draft | — | — | 2026-08-02 | 2.00 | — | — |"; d = 1 }
       { print }' "$SC/plans/REGISTRY.md" > "$SC/plans/R.tmp" && mv "$SC/plans/R.tmp" "$SC/plans/REGISTRY.md"
  printf '# x\n\n## Test Scope\n- vectors <!-- A3: Step 1a edits src/Cli/**, mapped to vectors -->\n\n## E2E Scope\n' \
    > "$SC/plans/PLN-950-annotated/plan.md"
  printf '# x\n\n## Test Scope\n- vectors\n\n## E2E Scope\n' > "$SC/plans/PLN-951-bare/plan.md"
  ( cd "$SC" && git init -qb develop . && git config user.email t@t && git config user.name t \
      && git add -A && git commit -qm seed ) >/dev/null 2>&1

  # env -C: wf-plan-info.sh, which resolves the plan directory, anchors on the
  # CALLER's repo — and the caller here is standing in a different fixture.
  scope_run() { env -C "$SC" "$SC/scripts/$SCRIPT_FOLDER/wf-test-scope.sh" "$@"; }
  annotated=$(scope_run PLN-950-annotated 2>/dev/null)
  annotated_err=$(scope_run PLN-950-annotated 2>&1 >/dev/null || true)
  assert_eq "the annotated bullet resolves" "FullyQualifiedName~Demo.Vector.Tests" "$annotated"
  assert_eq "and is not reported unknown" "false" \
    "$(printf '%s' "$annotated_err" | grep -q 'unknown category' && echo true || echo false)"
  assert_eq "it reads identically to the bare bullet" \
    "$(scope_run PLN-951-bare 2>/dev/null)" "$annotated"
  cd "$TEST_DIR/main" || exit 1
fi

# ═══════════════════════════════════════════════════════════════════════
section "A skipped commit proves the tree was clean (client-a WFI-141)"

# wf-commit.sh printed "nothing to commit for the given paths — skipped" and
# exited 0 over a path `git status` reported as ' M' with a 47-insertion diff,
# under four concurrent daemon workers. The message reads as a benign no-op, so
# an unattended caller trusting rc=0 loses the write silently.
#
# The add is simulated as the silent no-op it behaved as: what must not happen
# is this script agreeing that there was nothing to do.
cd "$TEST_DIR/main" || exit 1
mkdir -p fakebin
# The real git by absolute path: this shim shadows `git` on PATH, so a bare
# `exec git` inside it re-enters the shim forever.
real_git=$(command -v git)
cat > fakebin/git << FAKEGIT
#!/usr/bin/env bash
if [ "\$1" = "add" ]; then exit 0; fi
exec "$real_git" "\$@"
FAKEGIT
chmod +x fakebin/git
printf 'seed\n' > wfi141.txt
"$SCRIPT_DIR/wf-commit.sh" "seed wfi141" --add wfi141.txt >/dev/null 2>&1
printf 'a write that must not be lost\n' > wfi141.txt

fake_path="$TEST_DIR/main/fakebin:$PATH"
out=$(PATH="$fake_path" "$SCRIPT_DIR/wf-commit.sh" "should not skip" --add wfi141.txt 2>&1)
rc=$?
assert_eq "a dirty path with nothing staged is not 'skipped'" "false" \
  "$(printf '%s' "$out" | grep -q 'nothing to commit for the given paths' && echo true || echo false)"
assert_eq "it exits non-zero instead of reporting success" "true" \
  "$([ "$rc" -ne 0 ] && echo true || echo false)"
assert_eq "and names the path it refused to lose" "true" \
  "$(printf '%s' "$out" | grep -q 'wfi141.txt' && echo true || echo false)"

# The benign case still has to stay benign, or every caller naming an optional
# path (WFI-053) breaks.
out=$("$SCRIPT_DIR/wf-commit.sh" "genuinely nothing" --add plans/does-not-exist.md 2>&1)
assert_eq "a path that was never created is still a skip" "true" \
  "$(printf '%s' "$out" | grep -q 'nothing to commit for the given paths' && echo true || echo false)"
assert_ok "and that skip exits 0" "$SCRIPT_DIR/wf-commit.sh" "genuinely nothing" --add plans/does-not-exist.md

"$SCRIPT_DIR/wf-commit.sh" "wfi141 write lands on retry" --add wfi141.txt >/dev/null 2>&1
assert_eq "re-running commits the write it protected" "a write that must not be lost" \
  "$(git show HEAD:wfi141.txt 2>/dev/null)"
rm -rf fakebin

# ═══════════════════════════════════════════════════════════════════════
section "A finding is a block, not a physical line (client-a WFI-142)"

# A verify agent wrote PLN-060's one finding as a hard-wrapped paragraph — 25
# physical lines, continuations indented two spaces. The tag on the last of them
# matched nothing, because every tag test required ONE line to both start with
# '- [ ]' and end with the tag, so routing answered 'active' while the file
# plainly showed the tag. The only way out was reflowing the finding by hand.
mkdir -p plans/PLN-940-wrapped
cat > plans/PLN-940-wrapped/findings.md << 'FEOF'
## Verify — 2026-08-15

- [ ] **Design**: the signing-key doc contradicts the implementation, and the
  contradiction is wider than this plan — three other documents repeat the same
  claim, so the fix belongs in a doc sweep rather than here.
  <- BROAD-SCOPE
FEOF
assert_eq "a wrapped BROAD-SCOPE finding does not route" "clean" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-940-wrapped 2>/dev/null)"

cat > plans/PLN-940-wrapped/findings.md << 'FEOF'
- [ ] **Design**: users expect a different flow, and the plan cannot absorb
  that without a respec.
  ← ESCALATED
FEOF
assert_eq "a wrapped ESCALATED finding still escalates" "escalated" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-940-wrapped 2>/dev/null)"

cat > plans/PLN-940-wrapped/findings.md << 'FEOF'
- [ ] **Behavior**: the button does not respond
  on mobile Safari.
FEOF
assert_eq "a wrapped untagged finding routes back to the builder" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-940-wrapped 2>/dev/null)"

# WFI-089 must survive the rewrite: prose may name a tag without wearing it.
cat > plans/PLN-940-wrapped/findings.md << 'FEOF'
- [ ] **Code**: a code-only fix, not `← PLAN-SCOPED`, so it stays in this plan
  and gets fixed in place.
FEOF
assert_eq "a wrapped mention of a tag is still not a tag" "active" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-940-wrapped 2>/dev/null)"

# An indented checkbox has never been a finding here; folding one into its
# parent would push the parent's tag off the end and un-tag a tagged finding.
cat > plans/PLN-940-wrapped/findings.md << 'FEOF'
- [x] **Design**: handled, out of this plan's scope ← BROAD-SCOPE
  - [ ] a sub-note nobody routes on
FEOF
assert_eq "an indented checkbox does not un-tag its parent" "clean" \
  "$("$SCRIPT_DIR/wf-findings-route.sh" plans/PLN-940-wrapped 2>/dev/null)"
rm -rf plans/PLN-940-wrapped

# ═══════════════════════════════════════════════════════════════════════
section "Both sides of a deferral land in one commit (client-a WFI-144)"

# wf-defer-criterion.sh writes the DC row AND the plan.md checkoff, and
# committed neither. /wf-test's exit pathspec names deferred-criteria.md and
# never that plan's plan.md, so six checkoffs across one 16-plan sweep stayed
# uncommitted on plans already marked complete — read from git those plans show
# the criterion as '[ ]', the "silently dropped" reading deferral exists to
# remove.
registry_add_row PLN-941 defer-both testing
cat > plans/PLN-941-defer-both/plan.md << 'PEOF'
> **ID:** PLN-941

## Acceptance Criteria

#### Manual

- [ ] (external) run `tool doctor` **against a real signing service**
PEOF
"$SCRIPT_DIR/wf-commit.sh" "seed PLN-941" --add plans/PLN-941-defer-both plans/REGISTRY.md >/dev/null 2>&1
"$SCRIPT_DIR/wf-defer-criterion.sh" PLN-941 external \
  "(external) run tool doctor **against a real signing service**" >/dev/null 2>&1

assert_eq "the checkoff is in HEAD, not just the working tree" "true" \
  "$(git show HEAD:plans/PLN-941-defer-both/plan.md 2>/dev/null | grep -q 'deferred as DC-' && echo true || echo false)"
assert_eq "the DC row is in the same commit" "true" \
  "$(git show --name-only --format= HEAD 2>/dev/null | grep -q 'plans/deferred-criteria.md' && echo true || echo false)"
assert_eq "and the plan.md side is in that same commit" "true" \
  "$(git show --name-only --format= HEAD 2>/dev/null | grep -q 'plans/PLN-941-defer-both/plan.md' && echo true || echo false)"
assert_eq "nothing is left dirty for a caller to forget" "" \
  "$(git status --porcelain -- plans/PLN-941-defer-both plans/deferred-criteria.md)"

# ═══════════════════════════════════════════════════════════════════════
section "Closing a bug is idempotent, and takes a duplicate (client-a WFI-143, WFI-139)"

# WFI-143: /wf-test closed 8 of 11 completed plans' bugs and left 3, with
# identical plan metadata, so /wf-deploy step 9 met a mix of hard errors and
# real work with nothing distinguishing them. WFI-139: a duplicate is never
# triaged and has no fixing plan, so no scripted path could close one at all —
# BUG-061 was closed by hand across two paths, the shape that put six bugs at
# triaged/ AND closed/ in the same HEAD (WFI-136).
mkdir -p bugs/triaged/BUG-942-already bugs/open/BUG-943-dup bugs/closed
printf '# BUG-942 — x\n\n> **Status:** Triaged\n> **Plan:** PLN-942\n\n## Notes\n—\n' \
  > bugs/triaged/BUG-942-already/bug.md
printf '# BUG-943 — same as the brief\n\n> **Status:** Open\n\n## Description\nx\n' \
  > bugs/open/BUG-943-dup/bug.md
"$SCRIPT_DIR/wf-commit.sh" "seed bugs" --add bugs >/dev/null 2>&1

"$SCRIPT_DIR/wf-bug-close.sh" BUG-942 PLN-942-fix >/dev/null 2>&1
out=$("$SCRIPT_DIR/wf-bug-close.sh" BUG-942 PLN-942-fix 2>&1)
rc=$?
assert_eq "a second close of the same bug exits 0" "0" "$rc"
assert_eq "and says so rather than erroring" "true" \
  "$(printf '%s' "$out" | grep -q 'already closed' && echo true || echo false)"

out=$("$SCRIPT_DIR/wf-bug-close.sh" BUG-943 --duplicate-of BRF-944 2>&1)
assert_eq "a duplicate closes from bugs/open/" "0" "$?"
assert_eq "the record says it was not fixed" "true" \
  "$(grep -q 'Closed as duplicate of: BRF-944' bugs/closed/BUG-943-dup/bug.md && echo true || echo false)"
assert_eq "its status is Closed" "true" \
  "$(grep -q 'Status:\*\* Closed' bugs/closed/BUG-943-dup/bug.md && echo true || echo false)"
assert_eq "and the open/ side of the rename is gone from HEAD" "false" \
  "$(git ls-tree -r --name-only HEAD | grep -q 'bugs/open/BUG-943-dup' && echo true || echo false)"
assert_fails "a bug that exists nowhere is still an error" \
  "$SCRIPT_DIR/wf-bug-close.sh" BUG-999 PLN-999-nope
assert_fails "and a plan and a duplicate are mutually exclusive" \
  "$SCRIPT_DIR/wf-bug-close.sh" BUG-942 PLN-942-fix --duplicate-of BRF-944

# ═══════════════════════════════════════════════════════════════════════
section "A new registry row is committed where it is written (client-a WFI-140)"

# The one write to REGISTRY.md left outside wf-registry-update.sh's rule. A
# hand-edited row sat dirty on the shared develop checkout through the whole
# review loop, and PLN-060's was carried off by a concurrent implement worker's
# correctly-pathspecced commit. Both workers legitimately name
# plans/REGISTRY.md, so no pathspec defends against it — only not being dirty.
out=$("$SCRIPT_DIR/wf-registry-add.sh" PLN-945 new-row --tags "docs,security" 2>&1)
assert_eq "the row is added" "draft" "$(registry_state PLN-945)"
assert_eq "and committed, not left dirty" "" "$(git status --porcelain -- plans/REGISTRY.md)"
assert_eq "the commit names the registry" "true" \
  "$(git show --name-only --format= HEAD 2>/dev/null | grep -q 'plans/REGISTRY.md' && echo true || echo false)"
assert_eq "the tags land in the Tags column" "docs,security" \
  "$(grep '^| PLN-945 |' plans/REGISTRY.md | awk -F'|' '{print $9}' | xargs)"
assert_eq "the WF column is stamped from .claude/workflow-version" "$(tr -d '[:space:]' < .claude/workflow-version)" \
  "$(grep '^| PLN-945 |' plans/REGISTRY.md | awk -F'|' '{print $8}' | xargs)"
assert_eq "the row is inside the table, above the Counter comment" "true" \
  "$(awk '/^\| PLN-945 \|/ { row = NR } /<!-- Counter:/ { counter = NR } END { print (row > 0 && row < counter) ? "true" : "false" }' plans/REGISTRY.md)"
assert_fails "a second row for the same plan is refused" \
  "$SCRIPT_DIR/wf-registry-add.sh" PLN-945 new-row
assert_eq "so the plan still has exactly one row" "1" \
  "$(grep -c '^| PLN-945 |' plans/REGISTRY.md | xargs)"
assert_fails "an invented state is refused" \
  "$SCRIPT_DIR/wf-registry-add.sh" PLN-946 bad-state --state wibble
# A PLN-NNN-slug is the folder name; passing it as the slug must not double it.
"$SCRIPT_DIR/wf-registry-add.sh" PLN-947 PLN-947-folder-form >/dev/null 2>&1
assert_eq "a PLN-NNN-slug argument is read as the slug" "folder-form" \
  "$(grep '^| PLN-947 |' plans/REGISTRY.md | awk -F'|' '{print $3}' | xargs)"

# ═══════════════════════════════════════════════════════════════════════
section "A bug fixed without a plan can be closed (client-a WFI-149)"

# BUG-076 was fixed on develop in one 12-line commit. No plan exists, so
# /wf-deploy's close-by-plan path never reaches it and wf-bug-close.sh demanded
# a plan name — the bug was fixed and stuck at Open, invisible to the board,
# with "invent a plan ID that does not exist" as the only scripted way out.
mkdir -p bugs/open/BUG-948-small-fix
printf '# BUG-948 — a one-commit fix\n\n> **Status:** Open\n\n## Description\nx\n' \
  > bugs/open/BUG-948-small-fix/bug.md
"$SCRIPT_DIR/wf-commit.sh" "seed BUG-948" --add bugs/open/BUG-948-small-fix >/dev/null 2>&1
fix_sha=$(git rev-parse --short HEAD)

out=$("$SCRIPT_DIR/wf-bug-close.sh" BUG-948 --fixed-in "$fix_sha" --note "no acceptance criteria to check" 2>&1)
assert_eq "a bug closes against a commit, with no plan" "true" \
  "$([ -f bugs/closed/BUG-948-small-fix/bug.md ] && echo true || echo false)"
assert_eq "its status is Closed" "true" \
  "$(grep -q 'Status:\*\* Closed' bugs/closed/BUG-948-small-fix/bug.md && echo true || echo false)"
assert_eq "the commit is the record, resolved to its subject" "true" \
  "$(grep -q "Fixed directly in: .*seed BUG-948 — no plan" bugs/closed/BUG-948-small-fix/bug.md && echo true || echo false)"
assert_eq "the note the caller passed is kept" "true" \
  "$(grep -q 'no acceptance criteria to check' bugs/closed/BUG-948-small-fix/bug.md && echo true || echo false)"
assert_eq "and the open/ side of the rename is gone from HEAD" "false" \
  "$(git ls-tree -r --name-only HEAD | grep -q 'bugs/open/BUG-948-small-fix' && echo true || echo false)"
reclose=$("$SCRIPT_DIR/wf-bug-close.sh" BUG-948 --fixed-in "$fix_sha" 2>&1 || true)
assert_eq "a second close says so rather than erroring" "true" \
  "$(printf '%s' "$reclose" | grep -q 'already closed' && echo true || echo false)"
assert_fails "a commit and a plan are mutually exclusive" \
  "$SCRIPT_DIR/wf-bug-close.sh" BUG-948 PLN-948-nope --fixed-in "$fix_sha"

# An unresolvable sha is still recorded — the fix may live in another repo —
# but the caller is told it was not verified, rather than being handed a record
# that reads as evidence and is not.
mkdir -p bugs/open/BUG-949-elsewhere
printf '# BUG-949 — fixed in another repo\n\n> **Status:** Open\n\n## Description\nx\n' \
  > bugs/open/BUG-949-elsewhere/bug.md
"$SCRIPT_DIR/wf-commit.sh" "seed BUG-949" --add bugs/open/BUG-949-elsewhere >/dev/null 2>&1
out=$("$SCRIPT_DIR/wf-bug-close.sh" BUG-949 --fixed-in deadbee 2>&1)
assert_eq "an unknown sha does not block the close" "true" \
  "$([ -f bugs/closed/BUG-949-elsewhere/bug.md ] && echo true || echo false)"
assert_eq "and it says the commit was not verified" "true" \
  "$(printf '%s' "$out" | grep -q 'does not resolve to a commit' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A deferred criterion can be recorded as satisfied (client-a WFI-148)"

# --consume was the only verb, and it means "another plan adopted this". An
# external criterion's ordinary ending is that the real use happens and the
# criterion turns out true, with no plan involved: DC-040 was satisfied by a
# green production run and could only be recorded as consumed by a completed
# plan — which reads as pending work nobody will do. All 40 rows stayed open.
dc=$(grep -oE '^\| DC-[0-9]+' plans/deferred-criteria.md | tail -1 | tr -d '| ')
assert_eq "the fixture left a DC row to work with" "true" \
  "$([ -n "$dc" ] && echo true || echo false)"

out=$("$SCRIPT_DIR/wf-defer-criterion.sh" --satisfy "$dc" --evidence "run 31898065270 green on 2026-08-15" 2>&1)
assert_eq "the row records satisfaction, not consumption" "true" \
  "$(grep "^| $dc " plans/deferred-criteria.md | grep -q 'satisfied .* — run 31898065270 green' && echo true || echo false)"
assert_eq "no plan is named as owing it" "false" \
  "$(grep "^| $dc " plans/deferred-criteria.md | grep -q 'consumed by' && echo true || echo false)"
open_list=$("$SCRIPT_DIR/wf-defer-criterion.sh" --list || true)
assert_eq "it drops out of the open list /wf-spec reads" "false" \
  "$(printf '%s' "$open_list" | grep -q "^$dc" && echo true || echo false)"
assert_eq "the row is committed, not left dirty on develop" "" \
  "$(git status --porcelain -- plans/deferred-criteria.md)"
assert_eq "and the commit names the file" "true" \
  "$(git show --name-only --format= HEAD 2>/dev/null | grep -q 'plans/deferred-criteria.md' && echo true || echo false)"
# Captured first, then grepped: under `pipefail` a `grep -q` that exits on the
# first match SIGPIPEs a script still writing, and the pipeline reports 141.
again=$("$SCRIPT_DIR/wf-defer-criterion.sh" --satisfy "$dc" --evidence "again" 2>&1 || true)
assert_eq "satisfying it twice warns rather than lying about the old status" "true" \
  "$(printf '%s' "$again" | grep -q "was already 'satisfied" && echo true || echo false)"
# A DC id with no row rewrote nothing and reported success — the shape that
# lets a row go unrecorded silently.
assert_fails "a DC id that has no row is an error, not a no-op" \
  "$SCRIPT_DIR/wf-defer-criterion.sh" --satisfy DC-999 --evidence x
# --consume keeps working, and now commits its own write for the same reason
# the add path does (WFI-144/WFI-140).
"$SCRIPT_DIR/wf-defer-criterion.sh" PLN-941 soak "(soak) leave it running for a week" >/dev/null 2>&1
dc2=$(grep -oE '^\| DC-[0-9]+' plans/deferred-criteria.md | tail -1 | tr -d '| ')
"$SCRIPT_DIR/wf-defer-criterion.sh" --consume "$dc2" PLN-945 >/dev/null 2>&1
assert_eq "a consumed row names the plan that took it on" "true" \
  "$(grep "^| $dc2 " plans/deferred-criteria.md | grep -q 'consumed by PLN-945' && echo true || echo false)"
assert_eq "and that write is committed too" "" \
  "$(git status --porcelain -- plans/deferred-criteria.md)"

# ═══════════════════════════════════════════════════════════════════════
section "A live claim is never taken silently (client-a WFI-146)"

# --if-free respected a live claim and the bare form ignored one — and the
# skills present the bare form as the attended default. An attended session
# claiming PLN-059 overwrote the dispatcher's claim for a test worker that was
# alive and mid-run, printed "Claimed PLN-059" and exited 0.
registry_add_row PLN-950 contended active
claim_950=".claude/orchestrator/claims/950/.wf-claim"
sleep 30 & other_session=$!
mkdir -p "$(dirname "$claim_950")"
printf '%s\n%s\n' "$(date +%s)" "$other_session" > "$claim_950"

assert_fails "the bare form refuses a claim held by another live session" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-950-contended
assert_eq "and it leaves the incumbent's PID in place" "$other_session" \
  "$(sed -n '2p' "$claim_950")"
out=$("$SCRIPT_DIR/wf-claim.sh" PLN-950-contended 2>&1 || true)
assert_eq "the refusal names who holds it" "true" \
  "$(printf '%s' "$out" | grep -q "PID $other_session" && echo true || echo false)"
assert_eq "and points at the deliberate way through" "true" \
  "$(printf '%s' "$out" | grep -q -- '--steal' && echo true || echo false)"
assert_eq "the exit code is 2 — stood down, not broken" "2" \
  "$("$SCRIPT_DIR/wf-claim.sh" PLN-950-contended >/dev/null 2>&1; echo $?)"

assert_ok "--steal takes it on purpose" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-950-contended --steal
assert_eq "and the claim is now this session's" "false" \
  "$([ "$(sed -n '2p' "$claim_950")" = "$other_session" ] && echo true || echo false)"
assert_eq "the takeover is in the event log" "true" \
  "$(grep -q 'claim-steal' .claude/orchestrator/events.log 2>/dev/null && echo true || echo false)"
assert_fails "--steal and --if-free contradict each other" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-950-contended --if-free --steal
{ kill "$other_session"; wait "$other_session"; } 2>/dev/null
"$SCRIPT_DIR/wf-unclaim.sh" PLN-950-contended >/dev/null 2>&1

# A free artifact still claims in one call, and a session's own claim is not
# somebody else's — the refusal must not fire against the caller itself.
assert_ok "a free artifact claims without ceremony" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-950-contended
assert_ok "and re-claiming your own is a refresh, not a refusal" \
  "$SCRIPT_DIR/wf-claim.sh" PLN-950-contended
"$SCRIPT_DIR/wf-unclaim.sh" PLN-950-contended >/dev/null 2>&1

# ═══════════════════════════════════════════════════════════════════════
section "A resume names the folder to continue in (client-a WFI-147)"

# Two sessions on BUG-075 both got PLN-075/RESUME=false seconds apart, both
# correct at the time they asked, and both drafted a plan under that number
# with different slugs. The answer is only true at the instant it is given.
mkdir -p plans/PLN-951-earlier-attempt
printf '# PLN-951\n\n> **Bug:** BUG-951 — the earlier attempt\n\n## Goal\nx\n' \
  > plans/PLN-951-earlier-attempt/plan.md
eval "$("$SCRIPT_DIR/wf-plan-id.sh" BUG-951 2>/dev/null)"
assert_eq "the artifact's own folder is a resume, not a collision" "true" "$PLAN_ID_RESUME"
assert_eq "and the caller is told WHERE to continue" "plans/PLN-951-earlier-attempt" "$PLAN_ID_DIR"
assert_eq "the number is kept" "PLN-951" "$PLAN_ID"
# The slug the earlier attempt chose is rarely the one this run would choose,
# so a caller that writes to its own slug orphans the folder holding the row.
assert_eq "PLAN_ID_DIR is empty when there is nothing to resume" "" \
  "$(eval "$("$SCRIPT_DIR/wf-plan-id.sh" BUG-952 2>/dev/null)"; printf '%s' "$PLAN_ID_DIR")"
rm -rf plans/PLN-951-earlier-attempt

# The instruction is the other half of the fix: step 3's answer is provisional
# and step 5 asks again, in the call that actually creates the folder.
spec_skill="$LIB_ROOT/skills/wf-spec/SKILL.md"
assert_eq "wf-spec re-asks for the ID at folder creation" "true" \
  "$(grep -q 'Re-ask for the ID, then create the plan folder' "$spec_skill" && echo true || echo false)"
assert_eq "and says to continue in \$PLAN_ID_DIR, not in its own slug" "true" \
  "$(grep -q 'Write into `\$PLAN_ID_DIR`' "$spec_skill" && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A fix cycle is not a lost state write (client-a WFI-145)"

# testing → draft is a documented route: wf-test's findings path keeps the
# feature branch for the fix that follows. The audit called that shape a
# disagreement — "a state write was lost, or the work was abandoned. Check the
# branch, then set the state deliberately" — and following that advice moves
# the plan out of the cycle wf-test just routed it into.
FIXCYCLE="$TEST_DIR/fixcycle"
mkdir -p "$FIXCYCLE/plans/PLN-953-replanning" && (
  cd "$FIXCYCLE" && git init -qb develop . && git config user.email t@t && git config user.name t
  printf '| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n| PLN-953 | replanning | draft | — | — | 2026-08-15 | 2.00 | — | — |\n\n<!-- Counter: 999 -->\n' \
    > plans/REGISTRY.md
  printf '# x\n' > plans/PLN-953-replanning/plan.md
  printf -- '- [ ] **Behavior**: the nav bar hides the last route ← from human test\n' \
    > plans/PLN-953-replanning/findings.md
  git add -A && git commit -qm seed
  git checkout -qb feature/PLN-953-replanning
  echo work > src.txt && git add src.txt && git commit -qm "implement(PLN-953): step 1"
  git checkout -q develop
) >/dev/null 2>&1

fix_audit=$(cd "$FIXCYCLE" && "$SCRIPT_DIR/wf-registry-audit.sh" 2>&1 || true)
assert_eq "a draft plan with open findings is not called stale" "false" \
  "$(printf '%s' "$fix_audit" | grep -q 'STALE STATE' && echo true || echo false)"
assert_eq "it is named for what it is" "true" \
  "$(printf '%s' "$fix_audit" | grep -q 'REPLANNING.*PLN-953' && echo true || echo false)"
assert_eq "and it does not count as a problem" "registry audit: clean" \
  "$(printf '%s' "$fix_audit" | grep 'registry audit:')"

# WFI-010 — the report this check exists for — was explicit that those plans
# had NO findings to explain the route back. Close the findings and it is a
# lost write again.
( cd "$FIXCYCLE" && printf -- '- [x] **Behavior**: fixed\n' > plans/PLN-953-replanning/findings.md )
closed_audit=$(cd "$FIXCYCLE" && "$SCRIPT_DIR/wf-registry-audit.sh" 2>&1 || true)
assert_eq "a draft plan with nothing open on it is still reported" "true" \
  "$(printf '%s' "$closed_audit" | grep -q 'STALE STATE.*PLN-953' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "An unparseable plan is not a passing plan (client-a WFI-150)"

# One stray NUL byte in plan.md made `file` call it binary data, so every grep
# against it matched nothing. The schema probe fell through to `|| echo 0`, the
# lint announced "schema_version 0 (< 6) — skipping" and exited 0: a plan that
# could not be parsed at all got LESS checking than a normal one, silently.
registry_add_row PLN-954 nul-byte draft
printf '> **schema_version:** 6\n\n#### Manual\n\n- [ ] (eyes:blocking) a jud\000gment call\n' \
  > plans/PLN-954-nul-byte/plan.md
nul_out=$("$SCRIPT_DIR/wf-manual-lint.sh" PLN-954 2>&1 || true)
assert_eq "a NUL byte fails the lint instead of skipping it" "2" \
  "$("$SCRIPT_DIR/wf-manual-lint.sh" PLN-954 >/dev/null 2>&1; echo $?)"
assert_eq "and it says what is wrong with the file" "true" \
  "$(printf '%s' "$nul_out" | grep -q 'contains a NUL byte' && echo true || echo false)"
assert_eq "it does not claim the plan is pre-v6" "false" \
  "$(printf '%s' "$nul_out" | grep -q 'skipping' && echo true || echo false)"
assert_eq "and it says how to fix it" "true" \
  "$(printf '%s' "$nul_out" | grep -q "tr -d" && echo true || echo false)"

# Stripped, the same plan lints normally — the guard must not become a new way
# for a real plan to be refused.
( LC_ALL=C tr -d '\000' < plans/PLN-954-nul-byte/plan.md > plans/PLN-954-nul-byte/plan.clean \
  && mv plans/PLN-954-nul-byte/plan.clean plans/PLN-954-nul-byte/plan.md )
assert_ok "the same plan lints clean once the byte is gone" \
  "$SCRIPT_DIR/wf-manual-lint.sh" PLN-954

# A genuinely pre-v6 plan still skips — but the message no longer says "0" for
# a file that simply has no schema line, which is what made the two look alike.
registry_add_row PLN-955 no-schema draft
printf '#### Manual\n\n- [ ] an untagged v5 criterion\n' > plans/PLN-955-no-schema/plan.md
old_out=$("$SCRIPT_DIR/wf-manual-lint.sh" PLN-955 2>&1 || true)
assert_eq "a pre-v6 plan is still skipped, not failed" "0" \
  "$("$SCRIPT_DIR/wf-manual-lint.sh" PLN-955 >/dev/null 2>&1; echo $?)"
assert_eq "and it names the actual reason" "true" \
  "$(printf '%s' "$old_out" | grep -q 'no schema_version line' && echo true || echo false)"

# ═══════════════════════════════════════════════════════════════════════
section "A brief is not looked up as a plan (client-a WFI-160)"

# wf-spawn's last-moment state re-read took the NUMERIC part of any artifact and
# grepped it as a plan row. BRF-081, a brand-new brief with no registry row at
# all, resolved to PLN-081 — an unrelated plan completed the day before — so the
# guard refused, logged "state moved to 'complete' before launch" for a
# transition that never happened, and the brief became permanently
# undispatchable: every sweep re-ran the same lookup and got the same answer.
registry_add_row PLN-960 unrelated-and-done complete
out=$("$SCRIPT_DIR/wf-spawn.sh" spec BRF-960 --dry-run 2>&1); rc=$?
assert_eq "a brief whose number collides with a complete plan still spawns" "0" "$rc"
assert_eq "and the refusal message is not about that plan" "false" \
  "$(printf '%s' "$out" | grep -q "PLN-960 is 'complete'" && echo true || echo false)"

# The guard itself is untouched for the artifact it was actually given.
assert_eq "a PLN in the wrong state is still refused" "2" \
  "$("$SCRIPT_DIR/wf-spawn.sh" spec PLN-960-unrelated-and-done --dry-run >/dev/null 2>&1; echo $?)"

registry_add_row PLN-961 specable draft
assert_eq "and a PLN in the right state is not" "0" \
  "$("$SCRIPT_DIR/wf-spawn.sh" spec PLN-961-specable --dry-run >/dev/null 2>&1; echo $?)"

# ═══════════════════════════════════════════════════════════════════════
section "The write guard covers a plan's files, not a plan's name (client-a WFI-163)"

# It matched the ID anywhere in the path string, so a scratchpad note named
# after the plan it concerns — outside the repository, invisible to every other
# session — was refused. The workaround is to rename the file, which teaches
# people to route around the guard rather than respect it.
registry_add_row PLN-962 guarded active
claim_962=".claude/orchestrator/claims/962/.wf-claim"
sleep 30 & guard_holder=$!
mkdir -p "$(dirname "$claim_962")"
printf '%s\n%s\n' "$(date +%s)" "$guard_holder" > "$claim_962"

guard_write() {
  printf '{"tool_input":{"file_path":"%s"}}' "$1" \
    | "$SCRIPT_DIR/wf-guard-write.sh" >/dev/null 2>&1
  echo $?
}

assert_eq "a claimed plan's own file is still blocked" "2" \
  "$(guard_write "plans/PLN-962-guarded/findings.md")"
assert_eq "so is a file in its worktree" "2" \
  "$(guard_write "feature-branches/PLN-962-guarded/src/App.cs")"
assert_eq "a scratchpad note merely named after it is not" "0" \
  "$(guard_write "/private/tmp/claude-501/x/scratchpad/PLN-962-spec-correction.md")"
assert_eq "nor is a source file that mentions it" "0" \
  "$(guard_write "src/PLN-962-notes.md")"
assert_eq "the shared registry is never an artifact" "0" \
  "$(guard_write "plans/REGISTRY.md")"

# A file inside one plan's worktree belongs to that plan whatever it is named —
# a greedy match over intervening segments hands it to the wrong claim.
assert_eq "a bug-named file in a plan's worktree answers to the plan" "2" \
  "$(guard_write "feature-branches/PLN-962-guarded/src/BUG-013-fix.cs")"
{ kill "$guard_holder"; wait "$guard_holder"; } 2>/dev/null

# ═══════════════════════════════════════════════════════════════════════
section "A resume is found under a reallocated number (client-a WFI-161, WFI-162)"

# The resume probe only ever globbed plans/PLN-<inherited-num>-*. But the
# attempt it looks for has already run this script, and if that attempt hit the
# collision branch it wrote under a REALLOCATED number — where nothing looked.
# So a resume was undetectable for exactly the plans that had collided, and
# every re-dispatch allocated another number and burned another counter tick.
registry_add_row PLN-970 unrelated-and-complete complete
printf '# PLN-970\n\n> **Bug:** BUG-955 — something else entirely\n\n## Goal\nx\n' \
  > plans/PLN-970-unrelated-and-complete/plan.md

registry_add_row PLN-971 the-real-resume draft
printf '# PLN-971\n\n> **Brief:** briefs/BRF-970-headless-snapshot.md\n\n## Goal\nx\n' \
  > plans/PLN-971-the-real-resume/plan.md

counter_before=$(grep -oE 'Counter: [0-9]+' plans/REGISTRY.md | head -1)
eval "$("$SCRIPT_DIR/wf-plan-id.sh" BRF-970)"
assert_eq "the resume is found under its reallocated number" "PLN-971" "$PLAN_ID"
assert_eq "and it is reported as a resume" "true" "$PLAN_ID_RESUME"
assert_eq "inherited is false — the number is not the source's" "false" "$PLAN_ID_INHERITED"
assert_eq "the folder to continue in is named" "plans/PLN-971-the-real-resume" "$PLAN_ID_DIR"
assert_eq "and no counter tick was burned" "$counter_before" \
  "$(grep -oE 'Counter: [0-9]+' plans/REGISTRY.md | head -1)"

# Two folders naming one source is a real duplicate. Picking the lowest is
# better than making a third, but it must be said where the skill reports it.
registry_add_row PLN-972 the-duplicate draft
printf '# PLN-972\n\n> **Brief:** briefs/BRF-970-headless-snapshot.md\n\n## Goal\nx\n' \
  > plans/PLN-972-the-duplicate/plan.md
eval "$("$SCRIPT_DIR/wf-plan-id.sh" BRF-970)"
assert_eq "a duplicate resumes into the lowest-numbered folder" "PLN-971" "$PLAN_ID"
assert_eq "and the duplicate is named in the collision note" "true" \
  "$(printf '%s' "$PLAN_ID_COLLISION" | grep -q 'DUPLICATE PLANS FOR BRF-970' && echo true || echo false)"
rm -rf plans/PLN-972-the-duplicate

# WFI-161: a reallocation leaves the session's claim on the SOURCE number, so
# the plan it is writing is unclaimed — and the daemon dispatched a second spec
# worker onto it the moment wf-registry-add.sh committed the draft row.
registry_add_row PLN-973 holds-the-number complete
printf '# PLN-973\n\n> **Bug:** BUG-956 — unrelated\n\n## Goal\nx\n' \
  > plans/PLN-973-holds-the-number/plan.md
"$SCRIPT_DIR/wf-claim.sh" BUG-973 >/dev/null 2>&1
eval "$("$SCRIPT_DIR/wf-plan-id.sh" BUG-973)"
assert_eq "a taken number is still reallocated" "false" "$PLAN_ID_INHERITED"
assert_eq "and the claim follows it to the new number" "true" \
  "$([ -f ".claude/orchestrator/claims/${PLAN_ID#PLN-}/.wf-claim" ] && echo true || echo false)"
assert_eq "naming the same session that holds the source" "true" \
  "$([ "$(sed -n 2p ".claude/orchestrator/claims/${PLAN_ID#PLN-}/.wf-claim" 2>/dev/null)" \
      = "$(sed -n 2p .claude/orchestrator/claims/973/.wf-claim 2>/dev/null)" ] && echo true || echo false)"
"$SCRIPT_DIR/wf-unclaim.sh" BUG-973 >/dev/null 2>&1

section "Standing authorization is recorded, scoped and expiring (client-a WFI-159)"

# WFI-159: a person granted standing merge/deploy authorization in conversation
# and there was nowhere to record it, so it died at the session boundary. The
# report also named the failure mode to avoid — "an unread key would look
# load-bearing and be honoured by no script" — which is why the vocabulary is
# closed and an unread entry is a reported problem rather than a silent no-op.
AUTONOMY_CFG_BACKUP=""
[ -f claude-workflow.yml ] && AUTONOMY_CFG_BACKUP=$(cat claude-workflow.yml)

# Absent config is the pre-v6.18 behaviour exactly: everything stops for a human.
rm -f claude-workflow.yml
assert_fails "with no config at all, nothing is authorized" \
  "$SCRIPT_DIR/wf-autonomy.sh" release --quiet
assert_eq "and --show says so without calling it a fault" "0" \
  "$("$SCRIPT_DIR/wf-autonomy.sh" --show >/dev/null 2>&1; echo $?)"

write_grant() {
  cat > claude-workflow.yml <<YML
orchestrator:
  autonomy:
    mode: $1
    granted_by: "$2"
    granted_on: 2026-08-16
    expires_on: $3
    max_per_day: $4
    standing_for:
$(for a in $5; do printf '      - %s\n' "$a"; done)
YML
}

write_grant standing "A Tester" 2026-09-16 4 "release"
assert_ok "a coherent grant authorizes the action it names" \
  env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" release --quiet
assert_fails "and refuses one it does not name" \
  env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" deploy --quiet
assert_eq "the refusal is exit 1 — a decision, not a config fault" "1" \
  "$(env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" deploy --quiet; echo $?)"

# "I authorize deployments" must not silently cover the production push.
write_grant standing "A Tester" 2026-09-16 4 "deploy"
assert_fails "granting deploy does not grant the production push" \
  env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" production-push --quiet

# An authorization with no end date is a permission, not a record of a decision.
write_grant standing "A Tester" 2026-08-15 4 "release"
assert_fails "an expired grant authorizes nothing" \
  env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" release --quiet

# The report's own failure mode: a key nothing reads must be NAMED, not ignored.
write_grant standing "A Tester" 2026-09-16 4 "release everything"
assert_eq "an unread standing_for entry is exit 2, not a silent pass" "2" \
  "$(env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" --show >/dev/null 2>&1; echo $?)"
# Captured, not piped into `grep -q`: this file runs under `pipefail`, and a
# -q grep exits on the first match, so the writer takes SIGPIPE and the whole
# pipeline reports 141 however good the output was.
AUTONOMY_SHOW=$(env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" --show 2>&1 || true)
assert_eq "and --show names the entry nothing reads" "true" \
  "$(if [[ "$AUTONOMY_SHOW" == *"honoured by nothing"* ]]; then echo true; else echo false; fi)"
assert_eq "a malformed grant blocks the action too — 2 is never 'proceed'" "2" \
  "$(env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" release --quiet; echo $?)"

# Judgment gates have their own surfaces; two surfaces for one decision is how
# they end up disagreeing.
write_grant standing "A Tester" 2026-09-16 4 "spec-approval"
assert_eq "spec-approval is never grantable here" "2" \
  "$(env WF_AUTONOMY_TODAY=2026-08-16 "$SCRIPT_DIR/wf-autonomy.sh" --show >/dev/null 2>&1; echo $?)"

# WFI-159 lists merges among the blocked decisions, and that part is wrong:
# wf-test already pushes, opens the PR and merges it unattended.
AUTONOMY_MERGE=$("$SCRIPT_DIR/wf-autonomy.sh" merge 2>&1 || true)
assert_eq "merge reports that it is already unattended, not that it is refused" "true" \
  "$(if [[ "$AUTONOMY_MERGE" == *"already runs unattended"* ]]; then echo true; else echo false; fi)"

# A typo must not read as a deliberate refusal, or it gets worked around.
assert_eq "an unknown action is exit 2, never exit 1" "2" \
  "$("$SCRIPT_DIR/wf-autonomy.sh" relase --quiet; echo $?)"

# The ceiling bounds the blast radius of a grant when the pipeline goes wrong.
rm -f .claude/orchestrator/events.log
write_grant standing "A Tester" 2026-09-16 1 "release"
TODAY_UTC=$(date -u +%Y-%m-%d)
assert_ok "the first action inside the ceiling is authorized" \
  env WF_AUTONOMY_TODAY="$TODAY_UTC" "$SCRIPT_DIR/wf-autonomy.sh" release --quiet
assert_fails "the one past it is not" \
  env WF_AUTONOMY_TODAY="$TODAY_UTC" "$SCRIPT_DIR/wf-autonomy.sh" release --quiet
assert_eq "every question asked is on the event log, refusals included" "true" \
  "$(grep -q 'autonomy-use' .claude/orchestrator/events.log \
     && grep -q 'autonomy-refuse' .claude/orchestrator/events.log && echo true || echo false)"
assert_eq "and an authorization carries the grant's identity, not just 'ok'" "true" \
  "$(grep 'autonomy-use' .claude/orchestrator/events.log \
     | grep -q 'A Tester' && echo true || echo false)"

[ -n "$AUTONOMY_CFG_BACKUP" ] && printf '%s\n' "$AUTONOMY_CFG_BACKUP" > claude-workflow.yml
rm -f .claude/orchestrator/events.log

# ═══════════════════════════════════════════════════════════════════════
section "A bug's id is the one it declares (client-a WFI-176, WFI-173)"

# BUG-141 is titled "BUG-131's console encoding fix lives in the wrapper
# script…". The listers took the first BUG-NNN token in the file, three lines
# above the ID field, so it was listed, claimed and dispatched as BUG-131 — a
# bug closed the day before — while BUG-141 appeared in no list at all.
mkdir -p bugs/open/BUG-241-console-encoding bugs/open/BUG-242-plain
cat > bugs/open/BUG-241-console-encoding/bug.md <<'EOF'
# BUG-231's console encoding fix lives in the wrapper script, not the app

> **Status:** Open
> **ID:** BUG-241
> **Severity:** Medium
> **Links:** BUG-231
EOF
cat > bugs/open/BUG-242-plain/bug.md <<'EOF'
# An ordinary report

> **Status:** Open
> **ID:** BUG-242
> **Severity:** Low
EOF
SPECABLE=$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null || true)
assert_eq "the citing bug is listed under its own number" "1" \
  "$(printf '%s\n' "$SPECABLE" | grep -c '^BUG-241' | xargs)"
assert_eq "and never under the one its title cites" "0" \
  "$(printf '%s\n' "$SPECABLE" | grep -c '^BUG-231' | xargs)"
BUGLIST=$("$SCRIPT_DIR/wf-list-bugs.sh" 2>/dev/null || true)
assert_eq "wf-list-bugs reads the same field" "1" \
  "$(printf '%s\n' "$BUGLIST" | grep -c '^BUG-241' | xargs)"

# The folder name is the fallback, not the source — WFI-173 blamed it, and
# renaming the folder changed nothing, which is what disproved that theory.
mkdir -p bugs/open/BUG-243-no-id-field
printf '# A bug filed without an ID field\n\n> **Status:** Open\n> **Severity:** Low\n' \
  > bugs/open/BUG-243-no-id-field/bug.md
assert_eq "a bug with no ID field falls back to its folder" "1" \
  "$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null | grep -c '^BUG-243' | xargs)"
rm -rf bugs/open/BUG-241-console-encoding bugs/open/BUG-242-plain bugs/open/BUG-243-no-id-field

# ═══════════════════════════════════════════════════════════════════════
section "The specable detail column agrees with the review (client-a WFI-174)"

# Four client-a drafts were listed `never reviewed` while wf-review-status.sh
# answered 'Approved with notes', STALE=false, STAMPED=true for every one of
# them. wf-spec fans out a review agent for each plan reporting none, so four
# current reviews were queued to run again.
registry_add_row PLN-244 detail-column draft
assert_eq "a draft with no review still says so" "never reviewed" \
  "$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null | awk -F'\t' '$1 == "PLN-244-detail-column" {print $2}')"

cat >> plans/PLN-244-detail-column/plan.md <<'EOF'

## Review
> **Result:** Approved with notes
> **Date:** 2026-08-17
EOF
assert_eq "a reviewed draft reports the verdict, not 'never reviewed'" "reviewed: Approved with notes" \
  "$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null | awk -F'\t' '$1 == "PLN-244-detail-column" {print $2}')"

# A verdict on a plan that has moved since is not a verdict on this plan.
cat >> plans/PLN-244-detail-column/plan.md <<'EOF'

## Amendments
2026-08-18 — scope widened from 2 documents to 10.
EOF
assert_eq "and a stale one is named as stale" "review stale (Approved with notes)" \
  "$("$SCRIPT_DIR/wf-list-specable.sh" 2>/dev/null | awk -F'\t' '$1 == "PLN-244-detail-column" {print $2}')"

# ═══════════════════════════════════════════════════════════════════════
section "A guessed flag must not spend a number (client-a WFI-166, WFI-175)"

counter_now() { grep -oE 'Counter: [0-9]+' plans/REGISTRY.md | grep -oE '[0-9]+'; }
COUNTER_BEFORE=$(counter_now)

# `wf-counter-next.sh --peek` printed "--peek-136", advanced the counter and
# committed the advance — so `git status` came back clean and the burn was
# invisible until the next real allocation returned the wrong number.
assert_fails "an unknown flag is refused" "$SCRIPT_DIR/wf-counter-next.sh" --peekk
assert_fails "and so is a prefix that is not an artifact type" "$SCRIPT_DIR/wf-counter-next.sh" FOO
assert_eq "neither one spent a number" "$COUNTER_BEFORE" "$(counter_now)"

# The read-only question the mistyped flag was reaching for.
PEEKED=$("$SCRIPT_DIR/wf-counter-next.sh" PLN --peek)
assert_eq "--peek answers with the number a real call would take" "$(printf 'PLN-%03d' "$COUNTER_BEFORE")" "$PEEKED"
assert_eq "and takes nothing" "$COUNTER_BEFORE" "$(counter_now)"
assert_eq "the allocating call still allocates" "$(printf 'PLN-%03d' "$COUNTER_BEFORE")" \
  "$("$SCRIPT_DIR/wf-counter-next.sh" PLN)"
assert_eq "and only that one moved the counter" "$((COUNTER_BEFORE + 1))" "$(counter_now)"

# ═══════════════════════════════════════════════════════════════════════
section "Asking twice for a plan ID gets one answer (client-a WFI-177, WFI-175)"

# wf-spec is told to call wf-plan-id.sh twice, because the answer is only true
# at the moment it is given (WFI-147). Every branch but one was a pure read.
# The collision branch allocated on every call, so BUG-137's step 3 answered
# PLN-144 and step 5 answered PLN-145 with the identical collision string and
# nothing changed in between — PLN-144 exists nowhere and the counter is
# permanently one higher.
registry_add_row PLN-250 held-by-someone-else draft
printf '# held\n\n> **Bug:** BUG-999 — an unrelated bug\n\n## Goal\nx\n' > plans/PLN-250-held-by-someone-else/plan.md
COUNTER_BEFORE=$(counter_now)
ID_CALL1=$("$SCRIPT_DIR/wf-plan-id.sh" BUG-250 | grep '^PLAN_ID=' | cut -d"'" -f2)
ID_CALL2=$("$SCRIPT_DIR/wf-plan-id.sh" BUG-250 | grep '^PLAN_ID=' | cut -d"'" -f2)
assert_eq "the second call answers what the first one did" "$ID_CALL1" "$ID_CALL2"
assert_eq "and it cost exactly one number, not two" "$((COUNTER_BEFORE + 1))" "$(counter_now)"
assert_eq "the reallocated number is not the inherited one" "false" \
  "$(if [ "$ID_CALL1" = "PLN-250" ]; then echo true; else echo false; fi)"

# A diagnostic must not spend an artifact number to ask a question (WFI-175).
COUNTER_BEFORE=$(counter_now)
assert_eq "--peek answers the same thing" "$ID_CALL1" \
  "$("$SCRIPT_DIR/wf-plan-id.sh" BUG-250 --peek | grep '^PLAN_ID=' | cut -d"'" -f2)"
assert_eq "and takes nothing" "$COUNTER_BEFORE" "$(counter_now)"

# An attempt that got as far as mkdir and no further is this artifact's own —
# client-a was left with an empty, untracked plans/PLN-136-…/ that the next
# run read as somebody else's number (WFI-169).
mkdir -p "plans/$ID_CALL1-abandoned-slug"
ID_RESUME=$("$SCRIPT_DIR/wf-plan-id.sh" BUG-250)
assert_eq "an empty reserved folder is resumed, not orphaned" "true" \
  "$(printf '%s' "$ID_RESUME" | grep -q "PLAN_ID_RESUME='true'" && echo true || echo false)"
assert_eq "and the run is pointed at it" "plans/$ID_CALL1-abandoned-slug" \
  "$(printf '%s' "$ID_RESUME" | grep '^PLAN_ID_DIR=' | cut -d"'" -f2)"

# A reservation is advisory. A number somebody else has since taken is theirs.
rm -rf "plans/$ID_CALL1-abandoned-slug"
mkdir -p "plans/$ID_CALL1-someone-else"
printf '# other\n\n> **Bug:** BUG-998 — unrelated\n\n## Goal\nx\n' > "plans/$ID_CALL1-someone-else/plan.md"
assert_eq "a reservation somebody else took is dropped, not honoured" "false" \
  "$(if [ "$("$SCRIPT_DIR/wf-plan-id.sh" BUG-250 | grep '^PLAN_ID=' | cut -d"'" -f2)" = "$ID_CALL1" ]; then echo true; else echo false; fi)"
rm -rf "plans/$ID_CALL1-someone-else"

# ═══════════════════════════════════════════════════════════════════════
section "A resume is claimed by a field, not by prose (client-a WFI-168)"

# PLN-137 was renumbered away from BUG-137 mid-run and carried a note saying so:
# "> **Duplicate risk:** this plan was drafted under a dispatch naming
# **BUG-137**. Commit 671983e renumbered that artifact to **BUG-136**…". The old
# test read every line before the first `##`, so the note that recorded the plan
# is NOT BUG-137's made it claim BUG-137 — RESUME=true onto a parked, gated
# duplicate awaiting a human decision.
registry_add_row PLN-251 renumbered-away draft
cat > plans/PLN-251-renumbered-away/plan.md <<'EOF'
# renumbered away

> **ID:** PLN-251
> **Bug:** BUG-252 — the bug this plan is actually for
> **Duplicate risk:** this plan was drafted under a dispatch naming **BUG-251**.
> Commit 671983e renumbered that artifact to **BUG-252**.

## Goal
x
EOF
ID_PROSE=$("$SCRIPT_DIR/wf-plan-id.sh" BUG-251 --peek)
assert_eq "prose naming a renumbered artifact does not claim it" "false" \
  "$(printf '%s' "$ID_PROSE" | grep '^PLAN_ID_RESUME=' | cut -d"'" -f2)"

# The other half: the field DOES claim it, including from under a reallocated
# number (WFI-162). PLN-252 is taken by a stranger, so the collision branch runs
# and has to find BUG-252's own plan sitting under 251.
registry_add_row PLN-252 taken-by-a-stranger draft
printf '# stranger\n\n> **Bug:** BUG-997 — not this one\n\n## Goal\nx\n' > plans/PLN-252-taken-by-a-stranger/plan.md
ID_FIELD=$("$SCRIPT_DIR/wf-plan-id.sh" BUG-252 --peek)
assert_eq "the Bug field claims the plan across a reallocated number" "true" \
  "$(printf '%s' "$ID_FIELD" | grep '^PLAN_ID_RESUME=' | cut -d"'" -f2)"
assert_eq "and it is the field's plan, not a fresh number" "PLN-251" \
  "$(printf '%s' "$ID_FIELD" | grep '^PLAN_ID=' | cut -d"'" -f2)"

# ═══════════════════════════════════════════════════════════════════════
section "An answered gate is not asked again (client-a WFI-180/181/182)"

# PLN-135's prior-work gate was answered and closed at 11:43:42Z and re-opened
# at 12:01:45Z with identical wording, while wf-gate-status.sh still reported
# GATE_ANSWERED=true, GATE_STALE=false. Then a third time, a minute after a
# close returned 0. Then a fourth, thirty minutes after the decision was
# committed to findings.md — by which point the worker had RE-DERIVED the
# question, offering an option the human never authorized and describing a
# HashSet that had been a Dictionary since a merge two plans earlier.
registry_add_row PLN-260 answered-once ready
"$SCRIPT_DIR/wf-gate-open.sh" PLN-260 prior-work "accept it or revert it?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-260 "Do not revert 00d3d23, all 5 steps run" >/dev/null 2>&1
GATE_REOPEN_OUT=$("$SCRIPT_DIR/wf-gate-open.sh" PLN-260 prior-work "accept it or revert it?" 2>&1 || true)
"$SCRIPT_DIR/wf-gate-open.sh" PLN-260 prior-work "accept it or revert it?" >/dev/null 2>&1
assert_eq "re-opening an answered revision-scoped gate is refused with 3" "3" \
  "$("$SCRIPT_DIR/wf-gate-open.sh" PLN-260 prior-work "again?" >/dev/null 2>&1; echo $?)"
assert_eq "and the refusal hands back the answer of record" "true" \
  "$(if [[ "$GATE_REOPEN_OUT" == *"Do not revert 00d3d23"* ]]; then echo true; else echo false; fi)"
assert_fails "so nothing is parked" "$SCRIPT_DIR/wf-list-gates.sh" PLN-260

# The answer is for a revision, not for the plan forever.
printf '\n## Amendments\n2026-08-18 — scope widened to ten documents.\n' >> plans/PLN-260-answered-once/plan.md
assert_ok "a plan that moved since re-opens normally" \
  "$SCRIPT_DIR/wf-gate-open.sh" PLN-260 prior-work "the plan moved — accept or revert?"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-260 "revert it" >/dev/null 2>&1

# manual-test is asked once per test CYCLE by design (WFI-100). Blocking the
# second one would stop the pipeline dead.
registry_add_row PLN-261 cycle-scoped testing
"$SCRIPT_DIR/wf-gate-open.sh" PLN-261 manual-test "cycle one?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-261 "criteria 1-8 pass" >/dev/null 2>&1
assert_ok "a cycle-scoped gate still opens every cycle" \
  "$SCRIPT_DIR/wf-gate-open.sh" PLN-261 manual-test "cycle two?"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-261 "criteria pass again" >/dev/null 2>&1

# Refusing to ask a human on the strength of a file that is not there is how a
# real question goes unasked.
mkdir -p plans/PLN-262-no-registry-row
printf '# rowless\n\n## Goal\nx\n' > plans/PLN-262-no-registry-row/plan.md
"$SCRIPT_DIR/wf-gate-open.sh" PLN-262 spec-approval "approve?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-262 "approved" >/dev/null 2>&1
assert_eq "an answer nothing could fingerprint is 'assumed', not 'revision'" "assumed" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-262 spec-approval | grep '^GATE_ANSWERED_BASIS=' | cut -d"'" -f2)"
assert_ok "and it never refuses on that basis" \
  "$SCRIPT_DIR/wf-gate-open.sh" PLN-262 spec-approval "approve?"
"$SCRIPT_DIR/wf-gate-close.sh" PLN-262 "approved again" >/dev/null 2>&1

# An operator who means it can still re-open one.
assert_ok "--force re-opens deliberately" \
  "$SCRIPT_DIR/wf-gate-open.sh" PLN-260 prior-work "asking again on purpose" --force
"$SCRIPT_DIR/wf-gate-close.sh" PLN-260 "done" >/dev/null 2>&1

# The other half: the worker reads plan artifacts, so the answer has to be in
# them. Nothing wrote it there, and each dispatched worker correctly re-derived
# the gate from evidence it could see (WFI-181).
assert_eq "the resolution is transcribed into findings.md" "true" \
  "$(grep -q 'Do not revert 00d3d23' plans/PLN-260-answered-once/findings.md && echo true || echo false)"
assert_eq "under a Decisions heading" "true" \
  "$(grep -q '^## Decisions' plans/PLN-260-answered-once/findings.md && echo true || echo false)"
assert_eq "with no unchecked box — that would read as 'needs replanning'" "0" \
  "$(grep -c '^- \[ \]' plans/PLN-260-answered-once/findings.md | xargs)"
assert_eq "and it is committed, not left dirty for a merge to take" "" \
  "$(git status --porcelain -- plans/PLN-260-answered-once/findings.md)"

# The question as asked is kept with the answer (WFI-184). One question
# regenerated across five re-openings collected three errors of fact — a
# Dictionary described as a HashSet three times running, and a file called
# untouched by a commit that changes it +22/-8. A reader who can replay the
# original does not have to write it again from what they happen to see now.
registry_add_row PLN-263 question-replay ready
"$SCRIPT_DIR/wf-gate-open.sh" PLN-263 prior-work "00d3d23 touches ExemptFromRule3 — accept it, or revert it?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-263 "do not revert" >/dev/null 2>&1
assert_eq "the resolved record carries the question as asked" \
  "00d3d23 touches ExemptFromRule3 — accept it, or revert it?" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-263 prior-work | grep '^GATE_QUESTION=' | cut -d"'" -f2)"
assert_eq "and findings.md records what was asked alongside the answer" "true" \
  "$(grep -q '\*\*Asked:\*\* 00d3d23 touches ExemptFromRule3' plans/PLN-263-question-replay/findings.md && echo true || echo false)"

# Answering a gate is forward progress (WFI-185). PLN-135 accrued three
# implement attempts from workers that each correctly parked on the prior-work
# gate; when it was finally answered at 11:36 the dispatcher read the stale
# counter and opened a `stuck` gate at 11:37, so answering a gate produced
# another gate and a human had to delete the counter file by hand.
mkdir -p .claude/orchestrator/attempts
echo 3 > .claude/orchestrator/attempts/PLN-263.implement
"$SCRIPT_DIR/wf-gate-open.sh" PLN-263 manual-test "does it look right?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-263 "looks right" >/dev/null 2>&1
assert_eq "closing a gate clears the plan's attempt budget" "false" \
  "$([ -f .claude/orchestrator/attempts/PLN-263.implement ] && echo true || echo false)"
assert_eq "and says so on the event log" "true" \
  "$(grep -q 'attempts-reset' .claude/orchestrator/events.log && echo true || echo false)"
assert_eq "another plan's budget is untouched" "true" \
  "$(echo 2 > .claude/orchestrator/attempts/PLN-264.implement
     "$SCRIPT_DIR/wf-gate-close.sh" PLN-263 "again" >/dev/null 2>&1
     [ -f .claude/orchestrator/attempts/PLN-264.implement ] && echo true || echo false)"
rm -f .claude/orchestrator/attempts/PLN-264.implement

# ═══════════════════════════════════════════════════════════════════════
section "A gate belongs to the number, not the name (client-a WFI-187)"

# wf-spec opened spec-approval on the plan it had just written, producing
# gates/PLN-161.gate. The dispatcher's skip check asked under the name it had
# dispatched — BRF-161 — found no BRF-161.gate, and concluded nothing was
# parked. It re-dispatched a spec worker onto a brief whose plan sat behind an
# unanswered gate, and would have done so every sweep until a human answered.
# Claims had settled this already: they key on the artifact NUMBER.
registry_add_row PLN-290 gate-under-the-plan draft
printf '# under the plan\n\n> **ID:** PLN-290\n> **Brief:** briefs/BRF-290-thing.md\n\n## Goal\nx\n' \
  > plans/PLN-290-gate-under-the-plan/plan.md
"$SCRIPT_DIR/wf-gate-open.sh" PLN-290 spec-approval "8 steps — approve?" >/dev/null 2>&1

assert_ok "a gate opened on the plan is visible under the brief" \
  "$SCRIPT_DIR/wf-list-gates.sh" BRF-290
assert_eq "and the row names the plan that owns it" "PLN-290" \
  "$("$SCRIPT_DIR/wf-list-gates.sh" BRF-290 2>/dev/null | cut -f1)"
assert_eq "gate-status under the brief sees it open" "true" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" BRF-290 spec-approval | grep '^GATE_OPEN=' | cut -d"'" -f2)"

# One artifact, one gate file — not one per name it happens to be called by.
"$SCRIPT_DIR/wf-gate-open.sh" BRF-290 spec-approval "8 steps — approve?" >/dev/null 2>&1
assert_eq "opening under the brief does not make a second gate file" "false" \
  "$([ -f .claude/orchestrator/gates/BRF-290.gate ] && echo true || echo false)"

# Closing under either name closes the one gate, and the answer is an answer
# under both — with a fingerprint, so the WFI-180 refusal still has its evidence.
"$SCRIPT_DIR/wf-gate-close.sh" BRF-290 "approved" >/dev/null 2>&1
assert_fails "closing under the brief closes the plan's gate" \
  "$SCRIPT_DIR/wf-list-gates.sh" PLN-290
assert_eq "the answer is visible under the brief" "true" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" BRF-290 spec-approval | grep '^GATE_ANSWERED=' | cut -d"'" -f2)"
assert_eq "and under the plan" "true" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" PLN-290 spec-approval | grep '^GATE_ANSWERED=' | cut -d"'" -f2)"
assert_eq "asked under the brief, it is still fingerprinted against the plan" "revision" \
  "$("$SCRIPT_DIR/wf-gate-status.sh" BRF-290 spec-approval | grep '^GATE_ANSWERED_BASIS=' | cut -d"'" -f2)"

# ═══════════════════════════════════════════════════════════════════════
section "A brief that already has a plan is not specable (client-a WFI-188)"

# The last-moment state guard abstained for a bug or brief because "there is no
# plan row to be stale". That stops being true the moment spec writes one:
# BRF-161 got a fresh spec worker minutes after its plan had gone draft -> ready
# and its spec-approval had been recorded. wf-list-specable.sh was empty, the
# review was Approved and unstale — there was no spec work left to do.
registry_add_row PLN-291 already-specced ready
printf '# already specced\n\n> **ID:** PLN-291\n> **Brief:** briefs/BRF-291-thing.md\n\n## Goal\nx\n' \
  > plans/PLN-291-already-specced/plan.md
COUNTER_BEFORE=$(counter_now)
assert_eq "a brief whose plan is past draft stands down with exit 2" "2" \
  "$("$SCRIPT_DIR/wf-spawn.sh" spec BRF-291 --dry-run >/dev/null 2>&1; echo $?)"
# Captured, not piped into `grep -q`: this file runs under `pipefail` and a -q
# grep exits on the first match, so the writer takes SIGPIPE and the pipeline
# reports 141 however good the output was.
SPAWN_REFUSAL=$("$SCRIPT_DIR/wf-spawn.sh" spec BRF-291 --dry-run 2>&1 || true)
assert_eq "the refusal names the plan it was already specced as" "true" \
  "$(if [[ "$SPAWN_REFUSAL" == *"already specced as PLN-291"* ]]; then echo true; else echo false; fi)"
assert_eq "asking cost no artifact number — the lookup peeks" "$COUNTER_BEFORE" "$(counter_now)"

# The WFI-160 direction still holds: a brief with no plan is legitimate work,
# and must never be judged by an unrelated plan that happens to share its number.
#
# This fixture also carries the trap that WFI-168's first fix left standing: the
# Bug field's TITLE names BRF-292, so a test that matched anywhere on the field
# LINE read the line as a claim. A field line is not all field — the title after
# the value is free text, and titling a bug after another artifact is how every
# follow-up is written (WFI-176). Only the field's value counts.
registry_add_row PLN-292 unrelated-same-number complete
printf '# unrelated\n\n> **ID:** PLN-292\n> **Bug:** BUG-777 — nothing to do with BRF-292\n\n## Goal\nx\n' \
  > plans/PLN-292-unrelated-same-number/plan.md
assert_eq "an id in a field's title does not claim the plan" "false" \
  "$("$SCRIPT_DIR/wf-plan-id.sh" BRF-292 --peek 2>/dev/null | grep '^PLAN_ID_RESUME=' | cut -d"'" -f2)"
assert_ok "a brief with no plan of its own is still dispatchable" \
  "$SCRIPT_DIR/wf-spawn.sh" spec BRF-292 --dry-run

# A plan sent back for replanning is spec work again.
"$SCRIPT_DIR/wf-registry-update.sh" PLN-291 ready draft >/dev/null 2>&1
assert_ok "and one whose plan returned to draft is dispatchable again" \
  "$SCRIPT_DIR/wf-spawn.sh" spec BRF-291 --dry-run

# ═══════════════════════════════════════════════════════════════════════
section "A consume checks which bug it is taking (client-a WFI-167)"

# Commit 671983e renumbered BUG-137 -> BUG-136 while an unattended wf-spec
# worker dispatched on BUG-137 was drafting from that bug's content, and a
# different bug took the number. wf-claim.sh kept reporting the claim as held,
# because claims key on the number too. The consume matched by number alone and
# triaged the unrelated new BUG-137 — a bug about image parsing — into a plan
# about API versions. Exit 0, no warning.
mkdir -p bugs/open/BUG-270-devops-api-version
printf '# devops per-resource apiVersion\n\n> **Status:** Open\n> **ID:** BUG-270\n> **Severity:** High\n> **Plan:** _(none)_\n' \
  > bugs/open/BUG-270-devops-api-version/bug.md
git add -A >/dev/null 2>&1; git commit -qm "the bug is filed" >/dev/null 2>&1
registry_add_row PLN-270 devops-api-version draft
printf '# devops\n\n> **ID:** PLN-270\n> **Bug:** BUG-270 — devops per-resource apiVersion\n\n## Goal\nx\n' \
  > plans/PLN-270-devops-api-version/plan.md
git add -A >/dev/null 2>&1; git commit -qm "the plan is drafted from it" >/dev/null 2>&1

# The ordinary consume is untouched.
assert_ok "the bug the plan was drafted from is consumed normally" \
  "$SCRIPT_DIR/wf-bug-consume.sh" BUG-270 PLN-270-devops-api-version
assert_eq "and it landed in triaged" "true" \
  "$([ -f bugs/triaged/BUG-270-devops-api-version/bug.md ] && echo true || echo false)"

# The renumber: a different bug takes the freed number.
mkdir -p bugs/open/BUG-270-onprem-rendered-text
printf '# on-prem renderedText uses a third src shape\n\n> **Status:** Open\n> **ID:** BUG-270\n> **Severity:** Medium\n> **Plan:** _(none)_\n' \
  > bugs/open/BUG-270-onprem-rendered-text/bug.md
git add -A >/dev/null 2>&1; git commit -qm "an unrelated bug takes the freed number" >/dev/null 2>&1
assert_eq "a bug filed after the plan is refused, with exit 2" "2" \
  "$("$SCRIPT_DIR/wf-bug-consume.sh" BUG-270 PLN-270-devops-api-version >/dev/null 2>&1; echo $?)"
assert_eq "and it is left where its own planner will find it" "true" \
  "$([ -f bugs/open/BUG-270-onprem-rendered-text/bug.md ] && echo true || echo false)"

# The other half: a plan that says it is for a different bug is a
# contradiction, and consuming on top of it makes the plan wrong twice.
registry_add_row PLN-271 says-another-bug draft
printf '# other\n\n> **ID:** PLN-271\n> **Bug:** BUG-999 — something else entirely\n\n## Goal\nx\n' \
  > plans/PLN-271-says-another-bug/plan.md
assert_eq "a plan naming another bug in its Bug field refuses too" "2" \
  "$("$SCRIPT_DIR/wf-bug-consume.sh" BUG-270 PLN-271-says-another-bug >/dev/null 2>&1; echo $?)"
assert_ok "--force is there for an operator repairing one by hand" \
  "$SCRIPT_DIR/wf-bug-consume.sh" BUG-270 PLN-271-says-another-bug --force
rm -rf bugs/triaged/BUG-270-onprem-rendered-text

# ═══════════════════════════════════════════════════════════════════════
section "A replan does not promote on a stale approval (client-a WFI-178)"

# PLN-110 was tagged `contract`, the project's only gating tag. A replan widened
# Step 10 from 2 documents to 10 and added a test, then reached
# wf-replan-target.sh --apply, which transitioned draft -> ready and committed
# it. wf-gate-status.sh reported GATE_ANSWERED=false, GATE_STALE=true seconds
# later. wf-registry-update.sh's guard could not catch it: it refuses
# draft -> ready without a review OF RECORD, and a fresh one existed.
REPLAN_CFG_BACKUP=""
[ -f claude-workflow.yml ] && REPLAN_CFG_BACKUP=$(cat claude-workflow.yml)
printf 'specApproval:\n  mode: verdict\n  gateTags:\n    - contract\n' > claude-workflow.yml
registry_add_row PLN-280 gate-tagged-replan draft "—" "contract"
cat > plans/PLN-280-gate-tagged-replan/plan.md <<'EOF'
# gate-tagged

> **ID:** PLN-280

## Goal
Refresh the drive on a schedule.

## Review
> **Result:** Approved with notes
EOF
"$SCRIPT_DIR/wf-gate-open.sh" PLN-280 spec-approval "approve?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-280 "approved" >/dev/null 2>&1
printf '\n## Amendments\n2026-08-18 — Step 10 widened from 2 documents to 10.\n' >> plans/PLN-280-gate-tagged-replan/plan.md

assert_eq "a widened gate-tagged plan is refused with exit 2" "2" \
  "$("$SCRIPT_DIR/wf-replan-target.sh" PLN-280 --apply >/dev/null 2>&1; echo $?)"
assert_eq "and it is still draft, not dispatchable" "draft" "$(registry_state PLN-280)"

# Self-clearing: once the human has answered the new question it goes through.
"$SCRIPT_DIR/wf-gate-open.sh" PLN-280 spec-approval "wider scope — approve?" >/dev/null 2>&1
"$SCRIPT_DIR/wf-gate-close.sh" PLN-280 "approved at the wider scope" >/dev/null 2>&1
assert_ok "a re-approved plan promotes normally" "$SCRIPT_DIR/wf-replan-target.sh" PLN-280 --apply
assert_eq "and lands where the replan target says" "ready" "$(registry_state PLN-280)"

# A finished plan does not walk backwards (client-a WFI-172).
#
# PLN-111 was complete, its PR merged, its worktree removed. An unattended
# tester ran against it anyway; the runner could not write its TOOL into a
# deleted working directory, that one writer failure was reported as "29
# errors", and the tester wrote a finding and moved the plan complete -> active.
# Re-running the suite on develop gave 871 total, 0 failed.
registry_add_row PLN-282 already-shipped complete
assert_fails "a complete plan cannot be moved back to active" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-282 complete active
assert_eq "and the row did not move" "complete" "$(registry_state PLN-282)"
assert_ok "terminal to terminal is still allowed — /wf-rollback needs it" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-282 complete rolled-back
assert_ok "and a deliberate revival has an override" \
  env WF_ALLOW_REOPEN=1 "$SCRIPT_DIR/wf-registry-update.sh" PLN-282 rolled-back active
registry_add_row PLN-283 dropped-on-purpose abandoned
assert_ok "abandoned keeps its own revival path to draft" \
  "$SCRIPT_DIR/wf-registry-update.sh" PLN-283 abandoned draft

# An untagged plan is not touched by any of this.
registry_add_row PLN-281 untagged-replan draft
printf '\n## Review\n> **Result:** Approved\n' >> plans/PLN-281-untagged-replan/plan.md
assert_ok "a plan carrying no gating tag replans without a gate" \
  "$SCRIPT_DIR/wf-replan-target.sh" PLN-281 --apply
assert_eq "and promotes" "ready" "$(registry_state PLN-281)"
[ -n "$REPLAN_CFG_BACKUP" ] && printf '%s\n' "$REPLAN_CFG_BACKUP" > claude-workflow.yml

# ═══════════════════════════════════════════════════════════════════════
printf '\n'
if [ "$FAIL" -eq 0 ]; then
  printf '\033[1m%d passed, 0 failed\033[0m\n' "$PASS"
  exit 0
else
  printf '\033[1;31m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
  exit 1
fi
