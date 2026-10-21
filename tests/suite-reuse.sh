#!/usr/bin/env bash
# suite-reuse.sh — lv-suite-run.sh's receipts and --reuse (LVI-035).
#
# A client with no testScopes ran its whole suite about six times per plan,
# three of them on the same commit. Every run now leaves a receipt keyed on the
# tree, the commands, the toolchain and the Levain version, and --reuse accepts
# a PASS receipt for exactly that key instead of running again. These tests
# count real runs through a counter file the test command appends to.
#
# Usage: ./tests/suite-reuse.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "no /$3/ in: $2"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qE -- "$3"; then bad "$1" "unexpected /$3/ in: $2"; else ok "$1"; fi; }
section() { echo ""; echo "── $1"; }

SD="$TEST_DIR/scripts"
cp -R "${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}" "$SD"
RUN="$SD/lv-suite-run.sh"

R="$TEST_DIR/repo"
COUNT="$TEST_DIR/count"
TC="$TEST_DIR/toolchain"
FAILFLAG="$TEST_DIR/fail"
echo "sdk 10.0.100" > "$TC"
: > "$COUNT"

git init -q "$R"
cd "$R" || exit 1
git config user.email t@t.com; git config user.name T
printf '.claude/\n' > .gitignore
mkdir -p .claude; echo "14.40.0" > .claude/workflow-version

write_cfg() {
  cat > levain.yml <<EOF
build_command: "echo building"
test_command: "echo run >> $COUNT; [ ! -f $FAILFLAG ] && echo 5 total"
test_exclude_e2e: "${1:-}"
test_only_e2e: ""
suiteToolchain:
  - "cat $TC"
suiteKeyEnv:
  - SUITE_SECRET
${2:-}
EOF
}
write_cfg
echo "code v1" > app.txt
git add -A && git commit -q -m base

runs() { wc -l < "$COUNT" | tr -d ' '; }
result_of() { printf '%s' "$1" | sed -n 's/^SUITE_RESULT=//p' | tail -1; }
export SUITE_SECRET="hunter2-value"

# ═══════════════════════════════════════════════════════════════════════
section "A pass is reused for the identical tree, command and toolchain"

out=$("$RUN" --label implement --build --exclude-e2e 2>&1); rc=$?
assert_eq "the first run runs" "0:1" "$rc:$(runs)"
log=$(printf '%s' "$out" | sed -n 's/^SUITE_LOG=//p' | tail -1)
assert_eq "an inline run leaves a receipt" "true" "$([ -f "$log.meta" ] && [ -f "$log.status" ] && echo true || echo false)"
has "keyed on the tree" "$(cat "$log.meta")" "^SUITE_TREE=$(git rev-parse 'HEAD^{tree}')$"
has "with the toolchain it ran under" "$(cat "$log.meta")" "^SUITE_TOOLCHAIN=.*sdk 10.0.100"
has "and is a full-suite run when test_exclude_e2e is empty" "$(cat "$log.meta")" "^SUITE_SCOPE=full$"
hasnt "a suiteKeyEnv value never reaches the receipt" "$(cat "$log.meta" "$log.status" "$log")" "hunter2"

out=$("$RUN" --label verify --build --exclude-e2e --reuse 2>&1); rc=$?
assert_eq "verify on the same tree reuses it and runs nothing" "0:1" "$rc:$(runs)"
has "and says it was reused, naming the original log" "$(result_of "$out")" "^pass \(reused .*suite-implement-"
has "with the original log beside it" "$out" "^SUITE_REUSED_FROM=.*suite-implement-"

out=$("$RUN" --label test --reuse 2>&1); rc=$?
assert_eq "a build+suite pass also vouches for the suite alone" "0:1" "$rc:$(runs)"

out=$("$RUN" --label nobuild 2>&1)
git commit -q --allow-empty -m "a merge that changes no file"
out=$("$RUN" --label post-merge --build --reuse 2>&1); rc=$?
assert_eq "a new commit with an identical tree still reuses" "0:2" "$rc:$(runs)"

out=$("$RUN" --label again --build --reuse 2>&1)
assert_eq "a reused receipt is never itself reused (the original is)" "2" "$(runs)"
has "it still points at the run that measured the code" "$out" "^SUITE_REUSED_FROM=.*suite-implement-"

# ═══════════════════════════════════════════════════════════════════════
section "Anything outside the key forces a real run"

echo "code v2" > app.txt
out=$("$RUN" --label t --build --reuse 2>&1)
assert_eq "an uncommitted edit runs the suite" "3" "$(runs)"
has "and says why" "$out" "uncommitted or untracked"
git checkout -q app.txt

echo scratch > untracked.txt
out=$("$RUN" --label t --build --reuse 2>&1)
assert_eq "an untracked file runs the suite (it is outside the tree hash)" "4" "$(runs)"
rm -f untracked.txt

echo "code v2" > app.txt; git commit -qam v2
out=$("$RUN" --label t --build --reuse 2>&1)
assert_eq "a changed tree runs the suite" "5" "$(runs)"
"$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "and then is reusable itself" "5" "$(runs)"

echo "sdk 10.0.200" > "$TC"
"$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "an SDK upgrade with no code change runs the suite" "6" "$(runs)"

SUITE_SECRET="rotated" "$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "a changed suiteKeyEnv value runs the suite" "7" "$(runs)"
"$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "(and the original value's receipt is still good)" "7" "$(runs)"

echo "14.41.0" > .claude/workflow-version
"$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "a different Levain version runs the suite" "8" "$(runs)"

"$RUN" --label t --build --reuse --no-reuse >/dev/null 2>&1
assert_eq "--no-reuse runs the suite" "9" "$(runs)"
LV_SUITE_REUSE=0 "$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "LV_SUITE_REUSE=0 runs the suite" "10" "$(runs)"

"$RUN" --label t --reuse --extra-args "--filter X" >/dev/null 2>&1
assert_eq "a filtered request does not reuse a full pass" "11" "$(runs)"

# A filtered run is never a full-suite receipt.
write_cfg "--exclude E2E"; git commit -qam "exclude e2e"
"$RUN" --label verify --build --exclude-e2e >/dev/null 2>&1
assert_eq "(a filtered verify run)" "12" "$(runs)"
out=$("$RUN" --label post-merge --build --reuse 2>&1)
assert_eq "does not stand in for the full suite" "13" "$(runs)"
"$RUN" --label verify --build --exclude-e2e --reuse >/dev/null 2>&1
assert_eq "but does for the same filtered request" "13" "$(runs)"

# ═══════════════════════════════════════════════════════════════════════
section "Only a clean pass is reusable"

echo "code v3" > app.txt; git commit -qam v3
touch "$FAILFLAG"
out=$("$RUN" --label t --build 2>&1); rc=$?
assert_eq "(a failing run)" "1:14" "$rc:$(runs)"
rm -f "$FAILFLAG"
out=$("$RUN" --label t --build --reuse 2>&1); rc=$?
assert_eq "a fail is never reused — the suite runs again" "0:15" "$rc:$(runs)"

# A suite that writes un-ignored output leaves a receipt nobody can reuse.
write_cfg "" ""
sed -i.bak 's|^test_command: .*|test_command: "echo run >> '"$COUNT"'; echo out > TestResults.txt"|' levain.yml && rm -f levain.yml.bak
git commit -qam "dirtying suite"
out=$("$RUN" --label t --build 2>&1)
has "a run that dirties its tree says its receipt is not reusable" "$out" "not reusable.*tree changed"
has "naming what it wrote" "$out" "TestResults.txt"
rm -f TestResults.txt
"$RUN" --label t --build --reuse >/dev/null 2>&1
assert_eq "and it is not reused" "17" "$(runs)"
rm -f TestResults.txt
write_cfg; git commit -qam "back"

# ═══════════════════════════════════════════════════════════════════════
section "Release and deploy reuse only what suiteReuse allows"

"$RUN" --label release --build >/dev/null 2>&1      # 18
"$RUN" --label release --build --reuse-stage release >/dev/null 2>&1
assert_eq "release reuses by default" "18" "$(runs)"
"$RUN" --label deploy --build --reuse-stage deploy >/dev/null 2>&1
assert_eq "deploy does not by default" "19" "$(runs)"

write_cfg "" "suiteReuse: deploy"; git commit -qam deploy-reuse
"$RUN" --label t --build >/dev/null 2>&1            # 20
"$RUN" --label deploy --build --reuse-stage deploy >/dev/null 2>&1
assert_eq "suiteReuse: deploy lets deploy reuse" "20" "$(runs)"

write_cfg "" "suiteReuse: none"; git commit -qam none-reuse
"$RUN" --label t --build >/dev/null 2>&1            # 21
"$RUN" --label release --build --reuse-stage release >/dev/null 2>&1
assert_eq "suiteReuse: none makes release run" "22" "$(runs)"

# ═══════════════════════════════════════════════════════════════════════
section "Detached runs leave the same receipt, and a detached reuse is waited for"

write_cfg; git commit -qam detached
out=$("$RUN" --label release --build --detach 2>&1)
h=$(printf '%s' "$out" | sed -n 's/^SUITE_HANDLE=//p')
"$SD/lv-suite-wait.sh" "$h" --timeout 30 >/dev/null 2>&1
assert_eq "(the detached run passed)" "0:23" "$?:$(runs)"
out=$("$RUN" --label deploy --build --detach --reuse 2>&1)
h=$(printf '%s' "$out" | sed -n 's/^SUITE_HANDLE=//p')
w=$("$SD/lv-suite-wait.sh" "$h" --timeout 30 2>&1); rc=$?
assert_eq "a detached reuse is collected by lv-suite-wait.sh as a pass" "0:23" "$rc:$(runs)"
has "labelled as reused" "$w" "^SUITE_RESULT=pass \(reused "

ab=$("$SD/lv-suite-receipts.sh" --abandoned --min-age 0 2>/dev/null || true)
hasnt "an inline run is never listed as abandoned" "$ab" "suite-(implement|verify|t)-"

# ═══════════════════════════════════════════════════════════════════════
section "A run that executes no test is never a pass (eleven client LVIs)"

R2="$TEST_DIR/repo2"
git init -q "$R2"
cd "$R2" || exit 1
git config user.email t@t.com; git config user.name T
printf '.claude/\n' > .gitignore
mkdir -p .claude; echo "14.40.0" > .claude/workflow-version
cat > t.sh <<'SH'
#!/bin/sh
case "$*" in
  *E2E*|*Nope*) echo "No test matches the given testcase filter $*"; exit 0 ;;
  *banner*) echo "A total of 1 test files matched the specified pattern."; exit 0 ;;
esac
echo "Passed!  - Failed: 0, Passed: 5"
SH
chmod +x t.sh
printf 'test_command: "./t.sh"\ntest_only_e2e: "--filter E2E"\n' > levain.yml
git add -A && git commit -q -m base

out=$("$RUN" --label t --only-e2e --extra-args "" --no-reuse 2>&1); rc=$?
assert_eq "an empty plan scope on a project with no E2E tests passes" 0 "$rc"
has "…on the full suite it ran instead" "$out" "^SUITE_CMD=\./t\.sh$"
log=$(printf '%s' "$out" | sed -n 's/^SUITE_LOG=//p' | tail -1)
has "…and the log says why" "$(cat "$log")" "running the full suite instead"
has "…with real results" "$(cat "$log")" "Passed: 5"

out=$("$RUN" --label t --only-e2e --extra-args "Nope" --no-reuse 2>&1); rc=$?
assert_eq "a plan scope that matches nothing fails" 1 "$rc"
has "…and says no test ran" "$(result_of "$out")" "^fail \(no tests ran"

printf 'test_command: "./t.sh banner"\n' > levain.yml && git commit -qam banner
out=$("$RUN" --label t --no-reuse 2>&1); rc=$?
assert_eq "a test banner with no result summary is not a pass" 1 "$rc"
has "…it is a fail" "$(result_of "$out")" "^fail \(no tests ran"

echo ""
echo "suite-reuse: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
