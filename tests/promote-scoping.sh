#!/usr/bin/env bash
# promote-scoping.sh — the four client-a WFI-264 faults, tested.
#
#   1. A promotion gate stamps the tip that EXISTS, not the one this checkout
#      last heard about (wf_promote_fetch on the open path).
#   2. An `approve` for a batch the ref has moved past is refused at CLOSE
#      time, loudly, with the gate left open — not recorded and silently
#      discarded by the next worker. `--batch-moved-ok` records it against the
#      current tip for a caller that re-derived the batch.
#   3. lv-release-sync.sh refreshes origin/main and names DEPLOY_BASE, so the
#      commit counts put to a human are not taken from a local main carrying an
#      unrecovered promote merge.
#   4. lv-deploy-suite-memo.sh remembers a red suite against the release tip it
#      was reached on, so the same batch is not re-merged and re-run.
#
# Usage: ./tests/promote-scoping.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts/v2.00"
TEST_DIR=""
PASS=0
FAIL=0

cleanup() { [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$label"; else bad "$label" "want [$want], got [$got]"; fi
}

TEST_DIR=$(mktemp -d)
UPSTREAM="$TEST_DIR/upstream.git"
CLIENT="$TEST_DIR/client"

# A client with a real origin, so the remote-tracking refs this whole file is
# about actually exist and can be made stale on purpose.
new_client() {
  # The wt-* dirs go too: a worktree left from the previous case still points
  # into a .git that has just been deleted, and push_to would reuse it.
  rm -rf "$UPSTREAM" "$CLIENT" "$TEST_DIR"/wt-*
  git init -q --bare "$UPSTREAM"
  git init -q -b develop "$CLIENT"
  cd "$CLIENT" || exit 1
  git config user.email t@t; git config user.name t
  printf 'project_slug: "promote-test"\n' > levain.yml
  mkdir -p plans .claude/orchestrator
  printf '# Plan Registry\n\n<!-- Counter: 1 -->\n' > plans/REGISTRY.md
  git add -A; git commit -qm init
  git branch main; git branch release
  git remote add origin "$UPSTREAM"
  git push -q origin develop main release
  git fetch -q origin
}

# One commit onto a branch, pushed — the way work actually reaches `release`:
# through the remote, leaving this checkout's remote-tracking ref stale until
# something fetches.
push_to() {
  local branch="$1" msg="$2"
  git -C "$CLIENT" worktree add -q "$TEST_DIR/wt-$branch" "$branch" 2>/dev/null || true
  git -C "$TEST_DIR/wt-$branch" config user.email t@t
  git -C "$TEST_DIR/wt-$branch" config user.name t
  echo "$msg" >> "$TEST_DIR/wt-$branch/log.txt"
  git -C "$TEST_DIR/wt-$branch" add -A
  git -C "$TEST_DIR/wt-$branch" commit -qm "$msg"
  git -C "$TEST_DIR/wt-$branch" push -q origin "$branch"
}

# Make this checkout forget the push, exactly as a checkout that never fetched.
stale_remote_ref() {
  local branch="$1" sha="$2"
  git -C "$CLIENT" update-ref "refs/remotes/origin/$branch" "$sha"
}

echo "promote-scoping.sh"
echo "=================="

# ── 1. The gate stamps the tip that exists ──────────────────────────────────
echo ""
echo "1. lv-gate-open.sh fetches before stamping GATE_PROMOTE_TIP"
new_client
before=$(git -C "$CLIENT" rev-parse origin/release)
push_to release "work that lands on release out of band"
after=$(git -C "$TEST_DIR/wt-release" rev-parse HEAD)
stale_remote_ref release "$before"

assert_eq "precondition: the checkout's origin/release is stale" \
  "$before" "$(git -C "$CLIENT" rev-parse origin/release)"

cd "$CLIENT" || exit 1
"$SCRIPTS/lv-gate-open.sh" DEPLOY deploy-deferred-criteria "ship these?" >/dev/null 2>&1
stamped=$(sed -n "s/^GATE_PROMOTE_TIP='\(.*\)'$/\1/p" "$CLIENT/.claude/orchestrator/gates/DEPLOY.gate")
assert_eq "the gate carries the pushed tip, not the stale one" "$after" "$stamped"
# coordinator WFI-037: "Push main  to origin?" — the question lost its sha and
# the human approved a tip they were never shown.
asked=$(sed -n "s/^GATE_QUESTION='\(.*\)'$/\1/p" "$CLIENT/.claude/orchestrator/gates/DEPLOY.gate")
assert_eq "a question that names no tip is told the one it binds to" \
  "ship these? [release at ${after:0:7}]" "$asked"

# ── 2. An approval for a moved batch is refused at close ────────────────────
echo ""
echo "2. lv-gate-close.sh refuses an approve for a batch that moved"
# The gate is open and correctly stamped. Now move release underneath it, the
# by-design case: real commits landed between the question and the answer.
push_to release "more work, after the question was asked"
moved=$(git -C "$TEST_DIR/wt-release" rev-parse HEAD)

out=$("$SCRIPTS/lv-gate-close.sh" DEPLOY "approved" --decision approve 2>&1); rc=$?
assert_eq "exit 5" "5" "$rc"
case "$out" in
  *"batch that has moved"*) ok "it says the batch moved" ;;
  *) bad "it says the batch moved" "$out" ;;
esac
if [ -f "$CLIENT/.claude/orchestrator/gates/DEPLOY.gate" ]; then
  ok "the gate is left open"
else
  bad "the gate is left open" "the gate file was removed by a refused close"
fi
if [ ! -f "$CLIENT/.claude/orchestrator/gates/resolved/DEPLOY.deploy-deferred-criteria" ]; then
  ok "nothing was recorded in the ledger"
else
  bad "nothing was recorded in the ledger" "a dead approval was written"
fi

echo ""
echo "2a. --batch-moved-ok records against the CURRENT tip"
"$SCRIPTS/lv-gate-close.sh" DEPLOY "approved, batch re-derived" \
  --decision approve --batch-moved-ok >/dev/null 2>&1
rec="$CLIENT/.claude/orchestrator/gates/resolved/DEPLOY.deploy-deferred-criteria"
recorded=$(sed -n "s/^GATE_PROMOTE_TIP='\(.*\)'$/\1/p" "$rec" 2>/dev/null)
assert_eq "the record carries the moved-to tip" "$moved" "$recorded"

# And the whole point: a worker reading it back is now authorized.
"$SCRIPTS/lv-promote-approval.sh" deferred --quiet; rc=$?
assert_eq "lv-promote-approval.sh deferred → authorized" "0" "$rc"

# ── 3. DEPLOY_BASE names origin/main ────────────────────────────────────────
echo ""
echo "3. lv-release-sync.sh refreshes origin/main and names the base"
new_client
# A local main ahead of origin/main — an unrecovered provisional promote merge,
# exactly the state that made a 353-commit batch read as 205 (WFI-264).
git -C "$CLIENT" worktree add -q "$TEST_DIR/wt-main" main
git -C "$TEST_DIR/wt-main" config user.email t@t
git -C "$TEST_DIR/wt-main" config user.name t
echo local >> "$TEST_DIR/wt-main/log.txt"
git -C "$TEST_DIR/wt-main" add -A
git -C "$TEST_DIR/wt-main" commit -qm "release: promote to main (never pushed)"

cd "$CLIENT" || exit 1
out=$("$SCRIPTS/lv-release-sync.sh" 2>&1)
case "$out" in
  *"DEPLOY_BASE=origin/main"*) ok "DEPLOY_BASE names origin/main" ;;
  *) bad "DEPLOY_BASE names origin/main" "$out" ;;
esac
origin_main=$(git -C "$CLIENT" rev-parse --short origin/main)
local_main=$(git -C "$TEST_DIR/wt-main" rev-parse --short HEAD)
case "$out" in
  *"($origin_main)"*) ok "it is the REMOTE sha, not the local one ($local_main)" ;;
  *) bad "it is the REMOTE sha" "wanted $origin_main, line was: $out" ;;
esac

# ── 4. A red suite is remembered against its tip ────────────────────────────
echo ""
echo "4. lv-deploy-suite-memo.sh"
new_client
cd "$CLIENT" || exit 1

"$SCRIPTS/lv-deploy-suite-memo.sh" --check >/dev/null 2>&1; rc=$?
assert_eq "no memo → exit 0" "0" "$rc"

"$SCRIPTS/lv-deploy-suite-memo.sh" --fail "CaptureTimingTests.SendNote — 1 of 3339" >/dev/null 2>&1
out=$("$SCRIPTS/lv-deploy-suite-memo.sh" --check 2>&1); rc=$?
assert_eq "same tip → exit 1" "1" "$rc"
case "$out" in
  *"CaptureTimingTests.SendNote"*) ok "the check quotes the recorded summary" ;;
  *) bad "the check quotes the recorded summary" "$out" ;;
esac

# A fix landing on release moves the tip, which is what makes the memo
# self-clearing — there is no stale-memo case to manage.
push_to release "the fix"
git -C "$CLIENT" fetch -q origin release
"$SCRIPTS/lv-deploy-suite-memo.sh" --check >/dev/null 2>&1; rc=$?
assert_eq "release moved → exit 0 (memo is keyed to the tip)" "0" "$rc"

"$SCRIPTS/lv-deploy-suite-memo.sh" --fail "" >/dev/null 2>&1; rc=$?
assert_eq "--fail with no summary is a usage error" "2" "$rc"

# ── 5. postMergeCheck dispatch ──────────────────────────────────────────────
echo ""
echo "5. lv-post-merge-check.sh reads postMergeCheck:"
new_client
cd "$CLIENT" || exit 1

printf 'project_slug: "promote-test"\nbuild_command: "true"\npostMergeCheck: build\n' > levain.yml
out=$("$SCRIPTS/lv-post-merge-check.sh" 2>&1); rc=$?
assert_eq "build mode → exit 0 on a passing build" "0" "$rc"
case "$out" in
  *"build only, no suite"*) ok "it says it ran build only" ;;
  *) bad "it says it ran build only" "$out" ;;
esac

printf 'project_slug: "promote-test"\nbuild_command: "true"\ntest_command: "false"\n' > levain.yml
"$SCRIPTS/lv-post-merge-check.sh" --label t >/dev/null 2>&1; rc=$?
assert_eq "default is full — a red suite fails the check" "1" "$rc"

printf 'project_slug: "promote-test"\nbuild_command: "true"\ntest_command: "true"\n' > levain.yml
"$SCRIPTS/lv-post-merge-check.sh" --label t >/dev/null 2>&1; rc=$?
assert_eq "default is full — a green suite passes" "0" "$rc"

printf 'project_slug: "promote-test"\nbuild_command: "true"\ntest_command: "true"\npostMergeCheck: sometimes\n' > levain.yml
"$SCRIPTS/lv-post-merge-check.sh" --label t >/dev/null 2>&1; rc=$?
assert_eq "an unrecognized value is refused, never defaulted past" "2" "$rc"

# ── 6. production-push: the push is asked for, and the answer acts ─────────
echo ""
echo "6. production-push gate (coordinator WFI-008)"
new_client
git -C "$CLIENT" worktree add -q "$TEST_DIR/wt-main" main
git -C "$TEST_DIR/wt-main" config user.email t@t
git -C "$TEST_DIR/wt-main" config user.name t
echo promoted >> "$TEST_DIR/wt-main/log.txt"
git -C "$TEST_DIR/wt-main" add -A
git -C "$TEST_DIR/wt-main" commit -qm "release: promote to main"
local_main=$(git -C "$CLIENT" rev-parse main)
cd "$CLIENT" || exit 1

assert_eq "unpushed main is a DEPLOY candidate" "DEPLOY" "$("$SCRIPTS/lv-list-deploy.sh" 2>/dev/null)"

"$SCRIPTS/lv-gate-open.sh" DEPLOY production-push "push main?" >/dev/null 2>&1
stamped=$(sed -n "s/^GATE_PROMOTE_TIP='\(.*\)'$/\1/p" "$CLIENT/.claude/orchestrator/gates/DEPLOY.gate")
assert_eq "the gate is stamped with LOCAL main — the commit the push sends" "$local_main" "$stamped"

"$SCRIPTS/lv-promote-approval.sh" push --quiet; rc=$?
assert_eq "open and unanswered → not authorized" "1" "$rc"

"$SCRIPTS/lv-gate-close.sh" DEPLOY "approved — push it" --decision approve >/dev/null 2>&1; rc=$?
assert_eq "the approval closes cleanly" "0" "$rc"
"$SCRIPTS/lv-promote-approval.sh" push --quiet; rc=$?
assert_eq "approved for this tip → authorized" "0" "$rc"

echo more >> "$TEST_DIR/wt-main/log.txt"
git -C "$TEST_DIR/wt-main" commit -qam "another promotion"
"$SCRIPTS/lv-promote-approval.sh" push --quiet; rc=$?
assert_eq "main moved since the answer → ask again (exit 2)" "2" "$rc"

"$SCRIPTS/lv-gate-open.sh" DEPLOY production-push "push main again?" >/dev/null 2>&1
"$SCRIPTS/lv-gate-close.sh" DEPLOY "declined — not tonight" --decision reject >/dev/null 2>&1
assert_eq "a rejected push for this tip is no longer a candidate" "" "$("$SCRIPTS/lv-list-deploy.sh" 2>/dev/null)"

echo later >> "$TEST_DIR/wt-main/log.txt"
git -C "$TEST_DIR/wt-main" commit -qam "a newer promotion"
assert_eq "a new main tip is a new question" "DEPLOY" "$("$SCRIPTS/lv-list-deploy.sh" 2>/dev/null)"

git -C "$TEST_DIR/wt-main" push -q origin main
git -C "$CLIENT" fetch -q origin
assert_eq "pushed → nothing left to deploy" "" "$("$SCRIPTS/lv-list-deploy.sh" 2>/dev/null)"

echo ""
echo "=================="
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
