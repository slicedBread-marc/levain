#!/usr/bin/env bash
# derived-refresh.sh — levain.yml derivedCommand, run by the post-merge and
# post-checkout hooks in the develop checkout (LVI-032), tested end to end on
# an installed client.
#
#   1. install.sh installs post-merge and post-checkout, and keeps a project's
#      own hook as .pre-workflow.
#   2. No derivedCommand: the hooks do nothing.
#   3. A merge into develop in the main worktree rebuilds; a merge in a linked
#      worktree does not.
#   4. post-checkout: a branch switch rebuilds; a file checkout and a checkout
#      that does not move HEAD do not.
#   5. A failing command is reported (exit 1, log tail) and never fails the
#      merge that fired it.
#   6. LV_DERIVED_SKIP=1 suppresses it; a stale lock from a dead process does
#      not wedge it.
#
# Usage: ./tests/derived-refresh.sh     Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TEST_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
section() { echo "── $1 ──"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LV_DERIVED_SKIP

C="$TEST_DIR/client"
mkdir -p "$C"
git -C "$C" init -q -b develop
printf 'project_slug: "derived-test"\n' > "$C/levain.yml"
mkdir -p "$C/.git/hooks"
printf '#!/bin/sh\necho mine\n' > "$C/.git/hooks/post-merge"

section "1. install"
LV_INSTALL_NO_COMMIT=1 bash "$REPO_ROOT/install.sh" "$C" >/dev/null 2>&1
for h in post-merge post-checkout post-commit; do
  if [ -x "$C/.git/hooks/$h" ] && grep -q claude-workflow "$C/.git/hooks/$h"; then
    ok "$h installed"
  else
    bad "$h installed"
  fi
done
grep -q 'echo mine' "$C/.git/hooks/post-merge.pre-workflow" 2>/dev/null \
  && ok "a project's own post-merge is kept as .pre-workflow" \
  || bad "a project's own post-merge is kept as .pre-workflow"

# A tracked file, so there are commits to merge and branches to switch.
cd "$C"
# levain.yml is ignored here so rewriting it between sections is not a
# change that rides along on the next commit or checkout.
printf 'derived.out\n.claude/\nscripts/\nlevain.yml\n' >> .gitignore
echo a > src.txt
git add -A >/dev/null 2>&1; git commit -qm init
counter="$TEST_DIR/runs"
: > "$counter"
runs() { wc -l < "$counter" | tr -d ' '; }

section "2. nothing configured"
git checkout -qb feature/x; echo b >> src.txt; git commit -qam b
git checkout -q develop
git merge -q --no-edit feature/x
assert_eq "no derivedCommand: no file, no run" "$( [ -e derived.out ] && echo yes || echo no)" "no"

section "3. post-merge"
printf 'project_slug: "derived-test"\nderivedCommand: "echo run >> %s; cat src.txt > derived.out"\n' "$counter" > levain.yml
git checkout -q feature/x; echo c >> src.txt; git commit -qam c
: > "$counter"
git checkout -q develop
assert_eq "switching to develop rebuilt once" "$(runs)" "1"
: > "$counter"
git merge -q --no-edit feature/x
assert_eq "a merge into develop rebuilt" "$(runs)" "1"
assert_eq "from the merged tree" "$(tail -1 derived.out)" "c"

git worktree add -q "$TEST_DIR/wt" -b feature/y >/dev/null 2>&1
: > "$counter"
( cd "$TEST_DIR/wt" && git commit -q --allow-empty -m e && git merge -q --no-edit develop )
assert_eq "a merge in a linked worktree does not rebuild develop's copy" "$(runs)" "0"
assert_eq "nor write one there" "$( [ -e "$TEST_DIR/wt/derived.out" ] && echo yes || echo no)" "no"

section "4. post-checkout"
: > "$counter"
git checkout -q develop
assert_eq "a checkout that does not move HEAD does nothing" "$(runs)" "0"
echo z > src.txt; git checkout -q -- src.txt
assert_eq "a file checkout does nothing" "$(runs)" "0"
git checkout -q feature/x~1
assert_eq "a branch switch that moves HEAD rebuilds" "$(runs)" "1"
assert_eq "to the checked-out tree" "$(tail -1 derived.out)" "b"
git checkout -q develop

section "5. failure"
printf 'project_slug: "derived-test"\nderivedCommand: "echo boom; exit 7"\n' > levain.yml
out=$(scripts/lv-exec.sh lv-derived-refresh.sh 2>&1); rc=$?
assert_eq "a failing command exits 1" "$rc" "1"
case "$out" in *"exit 7"*boom*|*boom*) ok "and prints the log tail" ;; *) bad "and prints the log tail" "$out" ;; esac
git checkout -q feature/x; echo d >> src.txt; git commit -qam d; git checkout -q develop
git merge -q --no-edit feature/x >/dev/null 2>&1; rc=$?
assert_eq "it never fails the merge that fired it" "$rc" "0"
grep -q boom .claude/orchestrator/logs/derived.log && ok "the log holds the output" || bad "the log holds the output"

section "6. skip and stale lock"
printf 'project_slug: "derived-test"\nderivedCommand: "echo run >> %s"\n' "$counter" > levain.yml
: > "$counter"
LV_DERIVED_SKIP=1 scripts/lv-exec.sh lv-derived-refresh.sh >/dev/null 2>&1
assert_eq "LV_DERIVED_SKIP=1 suppresses it" "$(runs)" "0"
mkdir -p .claude/orchestrator/derived.lock; echo 999999 > .claude/orchestrator/derived.lock/pid
scripts/lv-exec.sh lv-derived-refresh.sh >/dev/null 2>&1
assert_eq "a dead holder's lock is taken over" "$(runs)" "1"
assert_eq "and released after" "$( [ -e .claude/orchestrator/derived.lock ] && echo held || echo free)" "free"

echo
echo "derived-refresh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
