#!/usr/bin/env bash
# directives.sh — steering colliding plans (LVI-033), tested.
#
#   1. Who may direct: a pipeline worker, an unknown --from, and --project from
#      a project that is not a coordinator are refused (exit 6).
#   2. add / list / status / apply, committed with a pathspec.
#   3. replan: refused on a built plan (exit 4); a ready plan returns to draft.
#   4. A spec-approval question names the upstreams in flux and the dependents.
#   5. Context: an upstream amendment makes an open question stale, and the
#      dispatcher withdraws it once the upstream leaves draft — never as an
#      approval. An upstream gate answer stales a dependent's closed approval.
#   6. A directive on a plan at spec-approval withdraws the question at once.
#   7. hold stops every launch until release-hold.
#   8. Consistency runs at spec-approval when Deps are not complete, through
#      the open gate.
#   9. A coordinator routes a directive through the target's own lv-exec.sh,
#      recorded as coordinator:<slug>.
#  10. Workers are told to load directives and the plan context.
#  11. A parked production-push that lv-autonomy.sh now authorizes is withdrawn
#      by the dispatcher — never approved — and one it still refuses stays.
#  12. A deploy-suite-red question is withdrawn once the release tip it failed
#      on has moved, and stays while it has not (memo, or no memo + gate age).
#
# Usage: ./tests/directives.sh     Exit 0 if all pass, 1 on any failure.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_FOLDER=$(awk '{sub(/#.*/, "")} NF >= 2 {folder = $2} END {print folder}' "$LIB_ROOT/scripts/version-map.txt")
S="${LV_TEST_SCRIPT_DIR:-$LIB_ROOT/scripts/$SCRIPT_FOLDER}"
PASS=0
FAIL=0
TEST_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpected [$3]" ;; *) ok "$1" ;; esac; }
section() { echo "── $1 ──"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2='\(.*\)'$/\1/p"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LV_UNATTENDED LV_DIRECT_FROM

P="$TEST_DIR/proj"
mkdir -p "$P/plans" "$P/scripts" "$P/.claude/orchestrator/gates/resolved"
cd "$P" || exit 1
git init -q -b develop
cat > levain.yml <<'YML'
project_slug: "proj"
orchestrator:
  enabled: true
  max_spawns_per_hour: 0
YML
printf '.claude/orchestrator/\n' > .gitignore
# The project's own dispatcher, as install.sh would leave it.
printf '#!/usr/bin/env bash\nn="$1"; shift; exec "%s/$n" "$@"\n' "$S" > scripts/lv-exec.sh
chmod +x scripts/lv-exec.sh
cat > plans/REGISTRY.md <<'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-025 | photos | complete | — | — | 2026-09-30 | 2.00 | — | — |
| PLN-026 | folders | draft | — | — | 2026-09-30 | 2.00 | — | PLN-025 |
| PLN-028 | serve | draft | — | — | 2026-09-30 | 2.00 | — | PLN-025,PLN-026 |
| PLN-029 | ready-one | ready | — | — | 2026-09-30 | 2.00 | — | — |
| PLN-030 | built | active | — | — | 2026-09-30 | 2.00 | — | — |

<!-- Counter: 30 -->
SEED
for p in 025-photos 026-folders 028-serve 029-ready-one 030-built; do
  mkdir -p "plans/PLN-$p"
  printf '# PLN-%s\n\n## Goal\nGoal of %s\n\n## Review\n> **2026-09-30 — Plan Review**\n> **Result:** Approved\n' "$p" "$p" > "plans/PLN-$p/plan.md"
done
git add -A >/dev/null; git commit -qm seed

D() { "$S/lv-direct.sh" "$@"; }
status_of() { "$S/lv-gate-status.sh" "$1" spec-approval 2>/dev/null; }

section "1. who may direct"
LV_UNATTENDED=1 D add PLN-028 --kind constraint --text "x" >/dev/null 2>&1
assert_eq "a pipeline worker is refused" "$?" "6"
D add PLN-028 --kind constraint --text "x" --from lv-spec >/dev/null 2>&1
assert_eq "an unknown --from is refused" "$?" "6"
D add PLN-028 --kind constraint --text "x" --project other >/dev/null 2>&1
assert_eq "--project from a project that is not a coordinator is refused" "$?" "6"
assert_eq "and nothing was written" "$([ -e plans/PLN-028-serve/directives.md ] && echo yes || echo no)" "no"

section "2. add, list, status, apply"
out=$(D add PLN-029 --kind constraint --text "Photos are served only to the owning tenant." 2>&1); rc=$?
assert_eq "constraint added" "$rc" "0"
has "prints its id" "$out" "DIRECTIVE_ID='D-1'"
has "committed on its own" "$(git log -1 --format=%s)" "direct(PLN-029): D-1 constraint"
assert_eq "and only its file" "$(git show --name-only --format= HEAD)" "plans/PLN-029-ready-one/directives.md"
has "list shows it" "$(D list PLN-029)" "Photos are served only to the owning tenant."
st=$(D status PLN-029)
assert_eq "status: one unapplied" "$(field "$st" DIRECTIVES_UNAPPLIED)" "1"
D apply PLN-029 D-1 --sha HEAD >/dev/null 2>&1
assert_eq "apply marks it applied" "$(field "$(D status PLN-029)" DIRECTIVES_UNAPPLIED)" "0"
has "with the commit" "$(D list PLN-029)" "applied $(git rev-parse --short=10 HEAD~1)"
D add PLN-029 --kind constraint --text "Owning tenant or a guardian." --supersedes D-1 >/dev/null 2>&1
st=$(D status PLN-029)
assert_eq "a superseded directive no longer binds" "$(field "$st" DIRECTIVE_IDS)" "D-2"

section "3. replan"
before=$(git rev-parse HEAD)
D add PLN-030 --kind replan --text "redo it" >/dev/null 2>&1
assert_eq "replan on a built plan is refused" "$?" "4"
assert_eq "and commits nothing" "$(git rev-parse HEAD)" "$before"
D add PLN-029 --kind replan --text "Re-spec around guardians." >/dev/null 2>&1
assert_eq "replan on a ready plan returns it to draft" "$(grep '^| PLN-029 ' plans/REGISTRY.md | awk -F'|' '{gsub(/ /,"",$4); print $4}')" "draft"

section "4. a design question names what it moves with"
"$S/lv-gate-open.sh" PLN-028 spec-approval "Approve PLN-028?" >/dev/null 2>&1
q=$(sed -n "s/^GATE_QUESTION='\(.*\)'$/\1/p" .claude/orchestrator/gates/PLN-028.gate)
has "names the upstream still in draft" "$q" "upstream still in flux: PLN-026 (draft)"
"$S/lv-gate-open.sh" PLN-026 spec-stuck "Stuck — decide the allow-list" >/dev/null 2>&1
q=$(sed -n "s/^GATE_QUESTION='\(.*\)'$/\1/p" .claude/orchestrator/gates/PLN-026.gate)
has "names the unbuilt dependent and its open gate" "$q" "PLN-028 (draft, spec-approval open)"

section "5. context"
st=$(status_of PLN-028)
assert_eq "fresh question: context not stale" "$(field "$st" GATE_PLAN_CONTEXT_STALE)" "false"
# The operator answers PLN-026's spec-stuck: drop the allow-list.
"$S/lv-gate-close.sh" PLN-026 "Remove the Folder allow-list" --only spec-stuck >/dev/null 2>&1
st=$(status_of PLN-028)
assert_eq "an answer on the upstream stales the question" "$(field "$st" GATE_PLAN_CONTEXT_STALE)" "true"
assert_eq "and names it" "$(field "$st" GATE_PLAN_CONTEXT_CHANGED)" "PLN-026"
assert_eq "the open question reads stale" "$(field "$st" GATE_QUESTION_STALE)" "true"
assert_eq "the attend queue calls it a collision (qfit moved)" "$("$S/lv-list-gates.sh" PLN-028 2>/dev/null | cut -f9)" "moved"
has "the tray marks it in attn for the rack" "$("$S/lv-tray.sh" --fields 2>/dev/null)" "28~"
out=$("$S/lv-orchestrate.sh" --sweep 2>&1)
assert_eq "not withdrawn while the upstream is still in draft" "$([ -f .claude/orchestrator/gates/PLN-028.gate ] && echo open || echo gone)" "open"
"$S/lv-registry-update.sh" PLN-026 draft ready >/dev/null 2>&1
printf '\n## Amendments\nA-1: no allow-list.\n' >> plans/PLN-026-folders/plan.md
git add -A >/dev/null; git commit -qm "amend 026"
out=$("$S/lv-orchestrate.sh" --sweep --dry-run 2>&1)
has "a dry run says it would withdraw" "$out" "would WITHDRAW: spec-approval on PLN-028"
assert_eq "and does not" "$([ -f .claude/orchestrator/gates/PLN-028.gate ] && echo open || echo gone)" "open"
"$S/lv-orchestrate.sh" --sweep >/dev/null 2>&1
assert_eq "withdrawn once the upstream settles" "$([ -f .claude/orchestrator/gates/PLN-028.gate ] && echo open || echo gone)" "gone"
st=$(status_of PLN-028)
assert_eq "a withdrawal is not an answer" "$(field "$st" GATE_ANSWERED)" "false"
assert_eq "it says it was withdrawn" "$(field "$st" GATE_WITHDRAWN)" "true"
has "with the reason, for the next lv-spec" "$(field "$st" GATE_RESOLUTION)" "PLN-026"
has "and findings.md says nothing was approved" "$(cat plans/PLN-028-serve/findings.md)" "nothing was approved"
has "lv-plan-context shows the decision of record upstream" "$("$S/lv-plan-context.sh" PLN-028)" "Remove the Folder allow-list"
# A client's LVI-015: another project's artifact has no row here.
sed -i.bak 's#^| PLN-030 | built | active | — | — | 2026-09-30 | 2.00 | — | — |#| PLN-030 | built | active | — | — | 2026-09-30 | 2.00 | — | other-app:BUG-050 |#' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
ctx=$("$S/lv-plan-context.sh" PLN-030)
has "a cross-project dep is listed" "$ctx" "== other-app:BUG-050"
hasnt "…and the plan is not 'No dependencies.'" "$ctx" "No dependencies"
sed -i.bak 's#| other-app:BUG-050 |#| — |#' plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak

# Re-asked and answered; then the upstream moves again.
"$S/lv-gate-open.sh" PLN-028 spec-approval "Approve PLN-028?" >/dev/null 2>&1
"$S/lv-gate-close.sh" PLN-028 "approved" --only spec-approval >/dev/null 2>&1
st=$(status_of PLN-028)
assert_eq "answered" "$(field "$st" GATE_ANSWERED)" "true"
printf 'A-2: guardians too.\n' >> plans/PLN-026-folders/plan.md
git add -A >/dev/null; git commit -qm "amend 026 again"
st=$(status_of PLN-028)
assert_eq "an upstream amendment stales a closed approval" "$(field "$st" GATE_STALE)" "true"
assert_eq "no longer answered" "$(field "$st" GATE_ANSWERED)" "false"
"$S/lv-gate-open.sh" PLN-028 spec-approval "Approve PLN-028?" >/dev/null 2>&1
assert_eq "so the gate opens again instead of being refused" "$?" "0"

section "6. a directive on a plan at spec-approval"
out=$(D add PLN-028 --kind constraint --text "Serving a photo checks tenant ownership, not a folder list." 2>&1)
has "withdraws the open question" "$out" "spec-approval withdrawn"
assert_eq "the gate is gone" "$([ -f .claude/orchestrator/gates/PLN-028.gate ] && echo open || echo gone)" "gone"
assert_eq "and it is not an approval" "$(field "$(status_of PLN-028)" GATE_ANSWERED)" "false"
has "an unapplied directive puts the plan on the replanning list" "$("$S/lv-list-specable.sh" 2>/dev/null)" "directive D-1 to apply"
has "and the tray lists it" "$("$S/lv-tray.sh" 2>/dev/null)" "CONSTRAINT PLN-028"

section "7. hold"
D add PLN-028 --kind hold --text "Reconciling with PLN-026" >/dev/null 2>&1
out=$("$S/lv-spawn.sh" spec PLN-028 --dry-run 2>&1); rc=$?
assert_eq "a held plan is not launched" "$rc" "2"
has "and says which directive holds it" "$out" "held by directive D-2"
has "the tray lists the hold" "$("$S/lv-tray.sh" 2>/dev/null)" "HOLD    PLN-028"
D add PLN-028 --kind release-hold >/dev/null 2>&1
out=$("$S/lv-spawn.sh" spec PLN-028 --dry-run 2>&1)
case "$out" in *"held by"*) bad "release-hold lifts it" "$out" ;; *) ok "release-hold lifts it" ;; esac
assert_eq "the hold is superseded" "$(D list PLN-028 | grep -c ' hold ')" "0"

section "8. consistency at spec-approval"
"$S/lv-gate-open.sh" PLN-028 spec-approval "Approve PLN-028?" >/dev/null 2>&1
"$S/lv-registry-update.sh" PLN-026 ready draft >/dev/null 2>&1
row=$("$S/lv-list-consistency.sh" PLN-028 2>/dev/null)
has "a draft plan at spec-approval with incomplete Deps owes a pass" "$row" "at spec-approval —"
out=$("$S/lv-spawn.sh" consistency PLN-028 --dry-run 2>&1); rc=$?
assert_eq "and may be launched through the open spec-approval" "$rc" "0"
out=$("$S/lv-spawn.sh" spec PLN-028 --dry-run 2>&1); rc=$?
assert_eq "while every other role still waits on it" "$rc" "2"
"$S/lv-gate-close.sh" PLN-028 "rejected" --only spec-approval >/dev/null 2>&1
"$S/lv-gate-open.sh" PLN-028 needs-input "Which tenant?" >/dev/null 2>&1
"$S/lv-spawn.sh" consistency PLN-028 --dry-run >/dev/null 2>&1
assert_eq "not through any other gate" "$?" "2"

section "9. routed from a coordinator"
C="$TEST_DIR/coord"
mkdir -p "$C"; git -C "$C" init -q
printf 'project_slug: "overseer"\nrole: coordinator\ncoordinates:\n  - "proj:%s"\n' "$P" > "$C/levain.yml"
"$S/lv-gate-close.sh" PLN-028 "answered" >/dev/null 2>&1
out=$(cd "$C" && "$S/lv-direct.sh" add PLN-026 --kind constraint --text "Keep the tenant check." --project proj 2>&1); rc=$?
assert_eq "a coordinator directs another project's plan" "$rc" "0"
has "recorded as the coordinator" "$(D list PLN-026)" "coordinator:overseer"
has "committed in the target" "$(git log -1 --format=%s)" "direct(PLN-026)"
(cd "$C" && "$S/lv-direct.sh" add PLN-026 --kind constraint --text "x" >/dev/null 2>&1)
assert_eq "a coordinator without --project is told it has no plans" "$?" "1"

section "10. the workers are told"
for s in lv-spec lv-implement lv-consistency lv-test lv-verify; do
  grep -q 'lv-direct.sh' "$LIB_ROOT/skills/$s/SKILL.md" && ok "$s loads directives" || bad "$s loads directives"
done
for s in lv-spec lv-consistency; do
  grep -q 'lv-plan-context.sh' "$LIB_ROOT/skills/$s/SKILL.md" && ok "$s reads the plan context" || bad "$s reads the plan context"
done
grep -q 'GATE_PLAN_CONTEXT_STALE' "$LIB_ROOT/skills/lv-attend/SKILL.md" && ok "lv-attend checks a question's context" || bad "lv-attend checks a question's context"

section "11. a push question policy now answers is withdrawn"
Q="$TEST_DIR/push"
mkdir -p "$Q/plans" "$Q/scripts" "$Q/.claude/orchestrator/gates/resolved"
cd "$Q" || exit 1
git init -q -b develop
printf 'project_slug: "push"\norchestrator:\n  enabled: true\n  max_spawns_per_hour: 0\nprojectProfile:\n  tier: governed\n' > levain.yml
printf '.claude/orchestrator/\n' > .gitignore
cp "$P/scripts/lv-exec.sh" scripts/
printf '# Plan Registry\n\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n\n<!-- Counter: 1 -->\n' > plans/REGISTRY.md
git add -A >/dev/null; git commit -qm seed
git branch main; git branch release
"$S/lv-gate-open.sh" DEPLOY production-push "push main to origin?" >/dev/null 2>&1
"$S/lv-orchestrate.sh" --sweep >/dev/null 2>&1
assert_eq "governed with no grant: the question stays" "$([ -f .claude/orchestrator/gates/DEPLOY.gate ] && echo open || echo gone)" "open"
printf 'project_slug: "push"\norchestrator:\n  enabled: true\n  max_spawns_per_hour: 0\nprojectProfile:\n  tier: pre-launch\n' > levain.yml
out=$("$S/lv-orchestrate.sh" --sweep --dry-run 2>&1)
has "a dry run says it would withdraw" "$out" "would WITHDRAW: production-push on DEPLOY"
assert_eq "and does not" "$([ -f .claude/orchestrator/gates/DEPLOY.gate ] && echo open || echo gone)" "open"
out=$("$S/lv-orchestrate.sh" --sweep 2>&1)
assert_eq "pre-launch (LVI-036): withdrawn" "$([ -f .claude/orchestrator/gates/DEPLOY.gate ] && echo open || echo gone)" "gone"
has "and the sweep says so" "$out" "withdrew production-push on DEPLOY"
st=$("$S/lv-gate-status.sh" DEPLOY production-push 2>/dev/null)
assert_eq "a withdrawal is not an answer" "$(field "$st" GATE_ANSWERED)" "false"
assert_eq "it says it was withdrawn" "$(field "$st" GATE_WITHDRAWN)" "true"
"$S/lv-promote-approval.sh" push --quiet >/dev/null 2>&1
assert_eq "and no push approval can be read back from it" "$?" "1"
assert_eq "the check spent no ceiling" "$(grep -c 'autonomy-use' .claude/orchestrator/events.log 2>/dev/null || true)" "0"

section "12. a red-suite question whose tip has moved is withdrawn"
gate_state() { [ -f .claude/orchestrator/gates/DEPLOY.gate ] && echo open || echo gone; }
# Land a commit on release without checking it out — the sweep pauses when the
# main worktree is on release (WFI-135).
land() { git update-ref refs/heads/release "$(git commit-tree 'release^{tree}' -p release -m "$1")"; }
"$S/lv-deploy-suite-memo.sh" --fail "UnitTest X failed" >/dev/null 2>&1
"$S/lv-gate-open.sh" DEPLOY deploy-suite-red "the suite failed on this tip" >/dev/null 2>&1
"$S/lv-orchestrate.sh" --sweep >/dev/null 2>&1
assert_eq "same tip as the memo: the question stays" "$(gate_state)" "open"
land "fix lands on release"
out=$("$S/lv-orchestrate.sh" --sweep --dry-run 2>&1)
has "a dry run says it would withdraw" "$out" "would WITHDRAW: deploy-suite-red on DEPLOY"
assert_eq "and does not" "$(gate_state)" "open"
out=$("$S/lv-orchestrate.sh" --sweep 2>&1)
assert_eq "tip moved past the memo: withdrawn" "$(gate_state)" "gone"
has "and the sweep says so" "$out" "withdrew deploy-suite-red on DEPLOY"
st=$("$S/lv-gate-status.sh" DEPLOY deploy-suite-red 2>/dev/null)
assert_eq "a withdrawal is not an answer" "$(field "$st" GATE_ANSWERED)" "false"
"$S/lv-deploy-suite-memo.sh" --clear >/dev/null 2>&1
"$S/lv-gate-open.sh" DEPLOY deploy-suite-red "the suite failed on this tip" >/dev/null 2>&1
"$S/lv-orchestrate.sh" --sweep >/dev/null 2>&1
assert_eq "no memo, tip older than the question: it stays" "$(gate_state)" "open"
sleep 1
GIT_COMMITTER_DATE="$(date -u -v+5S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+5 sec' +%Y-%m-%dT%H:%M:%SZ)" \
  land "another fix"
"$S/lv-orchestrate.sh" --sweep >/dev/null 2>&1
assert_eq "no memo, tip committed after the question: withdrawn" "$(gate_state)" "gone"
# A client's LVI-271: a push question policy already answers is refused at
# open, rather than parked for the daemon to withdraw after a human read it.
out=$("$S/lv-gate-open.sh" DEPLOY production-push "push main to origin?" 2>&1); rc=$?
assert_eq "pre-launch: an authorized production-push is refused at open" "$rc" "7"
has "…saying why" "$out" "already authorized"
assert_eq "…and nothing is open" "$(gate_state)" "gone"
# Clients' LVI-048/270: the coverage sentence is the script's to write.
out=$("$S/lv-gate-open.sh" DEPLOY deploy-approval "promote, and (with --covers-push) push main" 2>&1); rc=$?
assert_eq "a hand-written --covers-push mention is refused" "$rc" "1"
assert_eq "…and nothing is open" "$(gate_state)" "gone"
printf 'project_slug: "push"\norchestrator:\n  enabled: true\n  max_spawns_per_hour: 0\nprojectProfile:\n  tier: governed\n' > levain.yml
"$S/lv-gate-open.sh" DEPLOY production-push "push main to origin?" >/dev/null 2>&1
land "unrelated"
"$S/lv-orchestrate.sh" --sweep >/dev/null 2>&1
assert_eq "another question on DEPLOY is not touched" "$(gate_state)" "open"

section "13. an answer with no open gate is not recorded, and says so"
out=$("$S/lv-gate-close.sh" PLN-077 "approved" --decision approve 2>&1); rc=$?
assert_eq "a --decision with no gate open fails (a client's LVI-003)" "$rc" "6"
has "…saying it was not recorded" "$out" "NOT recorded"
out=$("$S/lv-gate-close.sh" PLN-077 "nothing to close" 2>&1); rc=$?
assert_eq "without a decision it stays a no-op" "$rc" "0"
"$S/lv-gate-open.sh" PLN-077 needs-input "first round?" >/dev/null 2>&1
"$S/lv-gate-close.sh" PLN-077 "approved round one" --decision approve >/dev/null 2>&1
"$S/lv-gate-open.sh" PLN-077 needs-input "second round?" --force >/dev/null 2>&1
st=$("$S/lv-gate-status.sh" PLN-077 needs-input 2>/dev/null)
assert_eq "an open gate is open" "$(field "$st" GATE_OPEN)" "true"
assert_eq "…and carries no decision from the round before (LVI-017)" "$(field "$st" GATE_DECISION)" ""
assert_eq "…nor its resolution" "$(field "$st" GATE_RESOLUTION)" ""

echo
echo "directives: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
