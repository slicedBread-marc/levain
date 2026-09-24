#!/usr/bin/env bash
# pipeline-lists.sh — the remaining scripts no test reached before 14.2.x:
# the lists /lv-tray and /lv-deploy read (completable, findings, replanning,
# rollbacks), the checks deploys run (deferred criteria, bug-close sweep,
# build), the state set, the project profile, the pinned release worktrees and
# the reboot reminder.
#
# Every fixture goes through the same registry format e2e-pipeline.sh seeds
# (schema v5), and deferred rows go through their producer, so a format change
# fails here as well as there.
#
# Usage: ./tests/pipeline-lists.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "no /$3/ in: $2"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qE -- "$3"; then bad "$1" "unexpected /$3/ in: $2"; else ok "$1"; fi; }

# rc <cmd…> → the exit code only
rc() { "$@" >/dev/null 2>&1; echo $?; }

cd "$TEST_DIR" || exit 1
git init -q -b develop . && git config user.email t@t && git config user.name T
mkdir -p plans bugs/open bugs/triaged bugs/closed .claude
printf 'project_slug: "demo"\n' > claude-workflow.yml
row() { printf '| %s | %s | %s | — | %s | 2026-09-24 | 14.2.0 | — | — |\n' "$1" "$2" "$3" "${4:-—}"; }
{
  printf '\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n'
  row PLN-001 merged-one   testing
  row PLN-002 unmerged-two testing
  row PLN-003 branchless   testing
  row PLN-004 custom-br    testing "hotfix/four"
  row PLN-005 fixing       active
  row PLN-006 checking     verify
  row PLN-007 replan       draft
  row PLN-008 plain-draft  draft
  row PLN-009 reverted     rolled-back
  row PLN-010 shipped      complete
  printf '\n<!-- Counter: 11 -->\n'
} > plans/REGISTRY.md
for d in 001-merged-one 002-unmerged-two 003-branchless 004-custom-br 005-fixing 006-checking \
         007-replan 008-plain-draft 009-reverted 010-shipped; do
  mkdir -p "plans/PLN-$d" && printf '# Plan\n\n## Goal\n\nGoal of %s.\n' "$d" > "plans/PLN-$d/plan.md"
done
git add -A && git commit -qm seed

echo "pipeline-lists.sh"
echo "================"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "1. lv-list-completable.sh — only a plan whose code is in the ref"
git branch release
git checkout -q -b feature/PLN-001-merged-one && git commit -q --allow-empty -m "PLN-001 work"
git checkout -q release && git merge -q --no-edit feature/PLN-001-merged-one
git checkout -q -b feature/PLN-002-unmerged-two develop && git commit -q --allow-empty -m "PLN-002 a" && git commit -q --allow-empty -m "PLN-002 b"
git checkout -q -b hotfix/four release && git commit -q --allow-empty -m "PLN-004"
git checkout -q release && git merge -q --no-edit hotfix/four
git checkout -q develop

out=$("$SD/lv-list-completable.sh" 2>/dev/null); code=$?
assert_eq "exit 0 when something is shippable"        "0" "$code"
has "a merged branch is 'merged'"                      "$out" "^PLN-001-merged-one	merged	feature/PLN-001-merged-one"
has "an unmerged one says how far ahead it is"         "$out" "^PLN-002-unmerged-two	unmerged	.*	2 commit\(s\) not in release"
has "no branch is reported, not decided"               "$out" "^PLN-003-branchless	no-branch"
has "the registry's Branch column wins over the convention" "$out" "^PLN-004-custom-br	merged	hotfix/four"
hasnt "plans not in testing are not offered"           "$out" "PLN-00[5-9]|PLN-010"
assert_eq "--shippable narrows to the merged rows"     "PLN-001-merged-one PLN-004-custom-br" \
  "$("$SD/lv-list-completable.sh" --shippable | cut -f1 | tr '\n' ' ' | sed 's/ $//')"
assert_eq "--ref another ref: nothing merged there, exit 1" "1" "$(rc "$SD/lv-list-completable.sh" --ref develop)"
assert_eq "a ref that does not exist is exit 2"        "2" "$(rc "$SD/lv-list-completable.sh" --ref nope)"
assert_eq "an unknown flag is exit 2"                  "2" "$(rc "$SD/lv-list-completable.sh" --bogus)"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "2. Findings, replanning, rollbacks"
printf '## Findings\n\n- [ ] F1 open in active\n- [x] F2 done\n' > plans/PLN-005-fixing/findings.md
printf '## Findings\n\n- [x] all done\n' > plans/PLN-006-checking/findings.md
printf '## Findings\n\n- [ ] F1 ESCALATED: the spec is wrong\n- [ ] F2 ESCALATED: so is this\n- [ ] F3 ordinary\n' > plans/PLN-007-replan/findings.md
printf '## Findings\n\n- [ ] F1 open but plain\n' > plans/PLN-008-plain-draft/findings.md
printf '\n**Rolled back:** 2026-09-20 — broke login\n' >> plans/PLN-009-reverted/plan.md

out=$("$SD/lv-list-findings.sh" 2>&1)
has "lists unchecked findings in active plans"         "$out" "=== PLN-005-fixing ==="
has "with the finding itself"                          "$out" "F1 open in active"
hasnt "not checked ones"                               "$out" "F2 done"
hasnt "a verify plan with nothing open is not listed"  "$out" "PLN-006"
hasnt "drafts are not its business"                    "$out" "PLN-007|PLN-008"

out=$("$SD/lv-list-replanning.sh" 2>/dev/null); code=$?
assert_eq "a draft with ESCALATED findings needs replanning" "PLN-007-replan	2	Goal of 007-replan." "$out"
assert_eq "exit 0 when one is found"                   "0" "$code"
mv plans/PLN-007-replan/findings.md plans/PLN-007-replan/findings.bak
assert_eq "none escalated: exit 1"                     "1" "$(rc "$SD/lv-list-replanning.sh")"
mv plans/PLN-007-replan/findings.bak plans/PLN-007-replan/findings.md

out=$("$SD/lv-list-rollbacks.sh" 2>/dev/null); code=$?
assert_eq "a rolled-back plan is listed with its reason" "PLN-009-reverted	**Rolled back:** 2026-09-20 — broke login" "$out"
assert_eq "exit 0 when one is found"                   "0" "$code"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "3. lv-deferred-check.sh — open deferrals read out before a promotion"
"$SD/lv-defer-criterion.sh" PLN-001 external "OIDC certificates set as secrets" --no-commit >/dev/null 2>&1
"$SD/lv-defer-criterion.sh" PLN-001 soak "no errors for a week" --no-commit >/dev/null 2>&1
"$SD/lv-defer-criterion.sh" PLN-004 external "the webhook is registered" --no-commit >/dev/null 2>&1
dc_done=$("$SD/lv-defer-criterion.sh" --list 2>/dev/null | grep -oE 'DC-[0-9]+' | tail -1)
"$SD/lv-defer-criterion.sh" --satisfy "$dc_done" --evidence "registered by hand" --no-commit >/dev/null 2>&1

out=$("$SD/lv-deferred-check.sh" PLN-001 2>/dev/null); code=$?
assert_eq "open rows for the plan: exit 1"             "1" "$code"
has "each is printed with its criterion"               "$out" "^DC-[0-9]+ \(PLN-001\): OIDC certificates set as secrets$"
assert_eq "both of that plan's rows"                   "2" "$(printf '%s\n' "$out" | grep -c 'PLN-001')"
assert_eq "a satisfied row is not read out"            "0" "$(rc "$SD/lv-deferred-check.sh" PLN-004)"
assert_eq "a plan with none: exit 0"                   "0" "$(rc "$SD/lv-deferred-check.sh" PLN-010)"
assert_eq "no plan ids (an empty range): exit 0, not a usage error" "0" "$(rc "$SD/lv-deferred-check.sh")"
has "ids are pulled out of commit-subject noise"       "$("$SD/lv-deferred-check.sh" "feat(PLN-001-merged-one):" 2>/dev/null)" "PLN-001"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "4. lv-bug-close-sweep.sh — triaged bugs whose plan already shipped"
mkbug() {   # mkbug <n> <plan-field> [status]
  mkdir -p "bugs/triaged/BUG-$1-b$1"
  printf '# Bug\n\n**ID:** BUG-%s\n**Status:** %s\n**Plan:** %s\n' "$1" "${3:-Triaged}" "$2" > "bugs/triaged/BUG-$1-b$1/bug.md"
}
mkbug 021 "PLN-010-shipped"
mkbug 022 "PLN-005-fixing"
mkbug 023 "(none)"
mkbug 024 "PLN-010-shipped/" "Closed 2026-09-01"
git add -A && git commit -qm bugs

out=$("$SD/lv-bug-close-sweep.sh" 2>"$TEST_DIR/sweep.err"); code=$?
assert_eq "reports the orphan only (report mode)"      "BUG-021	PLN-010	bugs/triaged/BUG-021-b021" "$out"
assert_eq "exit 0: a report, not a check"              "0" "$code"
has "and counts on stderr"                             "$(cat "$TEST_DIR/sweep.err")" "ORPHANED: 1"
assert_eq "report mode moves nothing"                  "true" "$([ -d bugs/triaged/BUG-021-b021 ] && echo true || echo false)"
"$SD/lv-bug-close-sweep.sh" --apply >/dev/null 2>&1
assert_eq "--apply closes it"                          "true" "$([ -d bugs/closed/BUG-021-b021 ] && echo true || echo false)"
has "with the fixing plan recorded"                    "$(cat bugs/closed/BUG-021-b021/bug.md 2>/dev/null)" "PLN-010"
assert_eq "and leaves the live plan's bug alone"       "true" "$([ -d bugs/triaged/BUG-022-b022 ] && echo true || echo false)"
assert_eq "an unknown argument is exit 1"              "1" "$(rc "$SD/lv-bug-close-sweep.sh" --now)"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "5. lv-build-check.sh"
assert_eq "no build_command: skipped, exit 0"          "0" "$(rc "$SD/lv-build-check.sh")"
printf 'project_slug: "demo"\nbuild_command: "true"\n' > claude-workflow.yml
assert_eq "a build that passes: exit 0"                "0" "$(rc "$SD/lv-build-check.sh")"
printf 'project_slug: "demo"\nbuild_command: "echo broken >&2; false"\n' > claude-workflow.yml
assert_eq "a build that fails: exit 1"                 "1" "$(rc "$SD/lv-build-check.sh")"
printf 'project_slug: "demo"\n' > claude-workflow.yml

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "6. lv-profile.sh"
prof() { printf 'project_slug: "demo"\n%s' "$1" > claude-workflow.yml; }
assert_eq "--show with no tier: exit 1"                "1" "$(rc "$SD/lv-profile.sh" --show)"
assert_eq "--check with no tier: exit 2"               "2" "$(rc "$SD/lv-profile.sh" --check)"
prof 'projectProfile:
  tier: governed
  reason: "customers depend on it"
  set_by: operator
  set_on: 2026-09-01
specApproval:
  mode: gate
manualTestGate:
  blockOnCosmetic: true
'
has "--show prints tier and reason"                    "$("$SD/lv-profile.sh" --show)" "tier:   governed"
assert_eq "governed, knobs as recommended: no drift"   "0" "$(rc "$SD/lv-profile.sh" --check)"
prof 'projectProfile:
  tier: governed
specApproval:
  mode: verdict
manualTestGate:
  blockOnCosmetic: true
orchestrator:
  autonomy:
    mode: standing
    standing_for:
      - release
      - production-push
'
out=$("$SD/lv-profile.sh" --check 2>&1); code=$?
assert_eq "drift: exit 1"                              "1" "$code"
has "names the knob that drifted"                      "$out" "DRIFT specApproval.mode: verdict \(tier 'governed' recommends gate\)"
has "and a production-push grant under governed"       "$out" "includes production-push under a governed tier"
prof 'projectProfile:
  tier: pre-launch
production_url: "https://example.test"
manualTestGate:
  blockOnCosmetic: false
orchestrator:
  autonomy:
    mode: standing
    standing_for:
      - release
      - deploy
'
has "pre-launch with a production URL wants production-push granted" "$("$SD/lv-profile.sh" --check 2>&1)" "missing 'production-push'"
prof 'projectProfile:
  tier: pre-launch
manualTestGate:
  blockOnCosmetic: false
'
assert_eq "pre-launch with nowhere to push: no autonomy demanded" "0" "$(rc "$SD/lv-profile.sh" --check)"
prof 'projectProfile:
  tier: yolo
'
assert_eq "an unknown tier: exit 2"                    "2" "$(rc "$SD/lv-profile.sh" --check)"
printf 'project_slug: "demo"\n' > claude-workflow.yml

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "7. lv-states.sh — one state set, and the dispatcher routes all of it"
# shellcheck source=/dev/null
source "$SD/lv-states.sh"
assert_eq "every terminal state is a state"            "" \
  "$(for s in $LV_TERMINAL_STATES; do wf_state_is_valid "$s" || printf '%s ' "$s"; done)"
assert_eq "an unknown state is not valid"              "1" "$(wf_state_is_valid shipped; echo $?)"
assert_eq "complete is terminal, testing is not"       "0 1" \
  "$(wf_state_is_terminal complete; a=$?; wf_state_is_terminal testing; echo "$a $?")"
# The block runs from the case to its fallthrough — the `*)` line, not the words
# "unknown state", which a comment inside the block also uses.
routes=$(awk '/case "\$state" in/{c=1; next} c && /^[[:space:]]*\*\)/{exit} c' "$SD/lv-orchestrate.sh")
unrouted=""
for s in $LV_STATES; do
  printf '%s\n' "$routes" | grep -qE "(^|[[:space:]|])$s(\)|\|)" || unrouted="$unrouted $s"
done
assert_eq "lv-orchestrate.sh has a route for every valid state" "" "$unrouted"
unknown=""
for s in $(printf '%s\n' "$routes" | grep -oE '^[[:space:]]+[a-z|-]+\)' | tr -d ' )' | tr '|' ' '); do
  wf_state_is_valid "$s" || unknown="$unknown $s"
done
assert_eq "and routes nothing lv-states.sh does not know" "" "$unknown"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "8. lv-worktree-pin.sh — release and main keep their own worktrees"
git remote add origin "$TEST_DIR/remote.git" && git init -q --bare "$TEST_DIR/remote.git"
git push -q origin develop 2>/dev/null
git branch main develop && git push -q origin main 2>/dev/null && git branch -D main >/dev/null

out=$("$SD/lv-worktree-pin.sh" release release-branches/release 2>/dev/null); code=$?
assert_eq "pins an existing local branch: exit 0"      "0" "$code"
assert_eq "prints the absolute path"                   "WORKTREE_PATH=$(cd release-branches/release && pwd -P)" "$out"
assert_eq "on that branch"                             "release" "$(git -C release-branches/release branch --show-current)"
assert_eq "pinning again is a no-op, exit 0"           "0" "$(rc "$SD/lv-worktree-pin.sh" release release-branches/release)"
git fetch -q origin
"$SD/lv-worktree-pin.sh" main release-branches/main >/dev/null 2>&1
assert_eq "a branch only on origin is tracked from it" "origin/main" \
  "$(git -C release-branches/main rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)"
"$SD/lv-worktree-pin.sh" staging release-branches/staging >/dev/null 2>&1
assert_eq "a branch nowhere yet is cut from develop"   "$(git rev-parse develop)" \
  "$(git -C release-branches/staging rev-parse HEAD 2>/dev/null)"
git -C release-branches/release checkout -q -b by-hand
assert_eq "a pin a human moved is refused, not fixed"  "1" "$(rc "$SD/lv-worktree-pin.sh" release release-branches/release)"
git -C release-branches/release checkout -q release
assert_eq "a branch already checked out elsewhere is refused" "1" \
  "$(rc "$SD/lv-worktree-pin.sh" release release-branches/elsewhere)"
assert_eq "missing arguments: exit 1"                  "1" "$(rc "$SD/lv-worktree-pin.sh" release)"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "9. The reboot reminder"
assert_eq "no flag: the check is silent"               "" "$("$SD/lv-check-reboot-flag.sh")"
"$SD/lv-set-reboot-flag.sh" "hooks changed — restart" >/dev/null
has "set: the check shows the message"                 "$("$SD/lv-check-reboot-flag.sh")" "Restart reminder: hooks changed — restart"
has "and how to dismiss it"                            "$("$SD/lv-check-reboot-flag.sh")" "lv-clear-reboot-flag.sh"
"$SD/lv-set-reboot-flag.sh" >/dev/null
has "no message: the default one"                      "$("$SD/lv-check-reboot-flag.sh")" "Restart this terminal at next opportunity"
assert_eq "clear removes it"                           "Reboot flag cleared." "$("$SD/lv-clear-reboot-flag.sh")"
assert_eq "clearing twice is harmless"                 "No reboot flag set." "$("$SD/lv-clear-reboot-flag.sh")"

echo
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
