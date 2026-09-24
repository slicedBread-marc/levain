#!/usr/bin/env bash
# id-map.sh — tests for the artifact ID prefix map (scripts/v2.00/lv-ids.sh):
# defaults, overrides, legacy acceptance, validation, and every kind end to end
# under a renamed map: issues (lv-issue.sh), then plans, bugs, briefs and
# deferred criteria through the pipeline scripts, then the prose renderer.
#
# Usage: ./tests/id-map.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SD="$REPO_ROOT/scripts/v2.00"
PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }

cd "$TEST_DIR" && git init -q . && printf 'project_slug: "ids"\n' > claude-workflow.yml
ids() { bash "$SD/lv-ids.sh" "$@" 2>&1; }

echo "id-map.sh"
echo "================"

echo
echo "1. Defaults"
assert_eq "plan issues PLN"                 "PLN"          "$(ids prefix plan)"
assert_eq "issue issues LVI, accepts WFI"   "LVI WFI"      "$(ids prefixes issue)"
assert_eq "test IDs default to T"           "T"            "$(ids prefix test)"
assert_eq "the default map checks clean"    "ids: ok"      "$(ids check)"
assert_eq "a legacy issue ID is an issue"   "issue"        "$(ids kind WFI-012)"
assert_eq "canon moves it to the issued prefix" "LVI-012"  "$(ids canon WFI-012)"
assert_eq "a test ID has no hyphen"         "test"         "$(ids kind T75)"

echo
echo "2. Overrides"
printf 'project_slug: "ids"\nids:\n  issue: HI LVI   # renamed\ntestIds:\n  prefix: TT\n' > claude-workflow.yml
assert_eq "issued prefix comes first"       "HI LVI WFI"   "$(ids prefixes issue)"
assert_eq "the default stays accepted"      "issue"        "$(ids kind WFI-001)"
assert_eq "testIds.prefix is honoured"      "TT T"         "$(ids prefixes test)"
assert_eq "match is an ERE alternation"     "HI|LVI|WFI"   "$(ids match issue)"
assert_eq "the override checks clean"       "ids: ok"      "$(ids check)"

echo
echo "3. Validation"
printf 'ids:\n  issue: BUG\n' > claude-workflow.yml
assert_eq "a prefix claimed by two kinds is refused" "1" "$(ids check >/dev/null 2>&1; echo $?)"
printf 'ids:\n  issue: hi\n' > claude-workflow.yml
assert_eq "a malformed prefix is refused"   "1" "$(ids check >/dev/null 2>&1; echo $?)"
printf 'ids:\n  plan: LOAF PLN\n  bug: FIX\n  brief: IDEA\n  deferred: DEF\n  rollback: UNDO\n' > claude-workflow.yml
assert_eq "every kind may be renamed"       "ids: ok"      "$(ids check)"
printf 'ids:\n  plan: FIX\n  bug: FIX\n' > claude-workflow.yml
assert_eq "but not onto another kind's prefix" "1" "$(ids check >/dev/null 2>&1; echo $?)"

echo
echo "4. Issues follow the map"
printf 'project_slug: "ids"\nids:\n  issue: HI LVI\n' > claude-workflow.yml
cat > WORKFLOW-ISSUES.md <<'EOF'
# Workflow Issues

<!-- New entries are inserted directly below this line, newest first. -->

## LVI-009 — lv-spec — 2026-09-23

**Status:** open

## WFI-007 — wf-spec — 2026-09-01

**Status:** open
EOF
git add -A >/dev/null && git commit -qm seed
out=$(bash "$SD/lv-issue.sh" --source lv-test --expected "e" --actual "## HI-001 looks like a heading" 2>&1)
assert_eq "a new issue takes the issued prefix, numbering carried on" "HI-010" "$(printf '%s' "$out" | grep -oE '^[A-Z]+-[0-9]+')"
assert_eq "a pasted heading in the body is neutralised" "1" "$(grep -c '^ ## HI-001' WORKFLOW-ISSUES.md)"
out=$(bash "$SD/lv-issue.sh" --resolve HI-007 "fixed" 2>&1)
assert_eq "resolving by the new prefix finds the WFI entry" "WFI-007: resolved — fixed" "$out"
assert_eq "open count follows"              "2"            "$(bash "$SD/lv-issue.sh" --count)"

echo
echo "5. Plans, bugs, briefs and deferred criteria follow the map"
# A project that ran on the defaults, then renamed: PLN-041 and BUG-042 exist,
# and everything issued from now on takes the new prefix.
P="$TEST_DIR/pipe"; mkdir -p "$P" && cd "$P" && git init -q . && git checkout -qb develop
printf 'project_slug: "ids"\nids:\n  plan: LOAF PLN\n  bug: FIX BUG\n  brief: IDEA\n  deferred: DEF\n' > claude-workflow.yml
mkdir -p plans/PLN-041-old-plan plans/briefs bugs/open/BUG-042-old-bug bugs/closed
cat > plans/REGISTRY.md <<'EOF'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-041 | old-plan | complete | P2 | feature/PLN-041-old-plan | 2026-09-01 | 14.0.0 | — | — |

<!-- Counter: 44 -->
EOF
printf '# Old bug\n' > bugs/open/BUG-042-old-bug/bug.md
printf '# A brief\n\n> **Status:** Exploring\n' > plans/briefs/IDEA-043-new-idea.md
git add -A >/dev/null && git commit -qm seed
src() { ( source "$SD/lv-orch-lib.sh"; "$@" ) 2>&1; }

assert_eq "the lib loads the map"            "LOAF|PLN"     "$(src eval 'printf %s "$LV_PLN_RE"')"
assert_eq "a plan counter peek takes the issued prefix" "LOAF-044" "$(bash "$SD/lv-counter-next.sh" plan --peek 2>/dev/null)"
assert_eq "the default name still asks for a plan"  "LOAF-044" "$(bash "$SD/lv-counter-next.sh" PLN --peek 2>/dev/null)"
assert_eq "a bug counter peek takes FIX"     "FIX-044"      "$(bash "$SD/lv-counter-next.sh" bug --peek 2>/dev/null)"
awk '{print} /^\| PLN-041/{print "| LOAF-050 | stray | draft | P2 | — | 2026-09-02 | 14.0.0 | — | — |"}' \
  plans/REGISTRY.md > plans/R.tmp && mv plans/R.tmp plans/REGISTRY.md
assert_eq "the floor counts IDs under the new prefix" "LOAF-051" "$(bash "$SD/lv-counter-next.sh" plan --peek 2>/dev/null)"
assert_eq "registry rows read both plan prefixes" "PLN-041 LOAF-050" \
  "$(src wf_registry_rows plans/REGISTRY.md | cut -d$'\x1f' -f1 | paste -sd' ' -)"
assert_eq "state lookup by an old plan ID"   "complete"     "$(src wf_state_of PLN-041 plans/REGISTRY.md)"
assert_eq "a bug's number names its plan"    "complete"     "$(src wf_state_of BUG-041 plans/REGISTRY.md)"
assert_eq "an existing number keeps its plan prefix" "PLN-041" "$(src wf_plan_id_for_num 041)"
assert_eq "a new number gets the issued one" "LOAF-060"     "$(src wf_plan_id_for_num 060)"
out=$(bash "$SD/lv-plan-id.sh" IDEA-043 --peek 2>&1)
assert_eq "a brief inherits its number as a LOAF plan" "PLAN_ID='LOAF-043'" "$(printf '%s\n' "$out" | grep '^PLAN_ID=')"
out=$(bash "$SD/lv-plan-id.sh" FIX-041 --peek 2>&1)
assert_eq "a taken number is reallocated under LOAF" "PLAN_ID='LOAF-051'" "$(printf '%s\n' "$out" | grep '^PLAN_ID=')"
case "$(src wf_artifacts_with_number 42)" in
  *"BUG "*bugs/open/BUG-042*) ok "an old bug folder still counts as in use" ;;
  *) bad "an old bug folder still counts as in use" "$(src wf_artifacts_with_number 42)" ;;
esac
out=$(bash "$SD/lv-bug-new.sh" "Renamed bug" --severity Low --source id-map 2>&1)
assert_eq "a new bug is filed as FIX"        "1"            "$(ls -d bugs/open/FIX-0*-renamed-bug 2>/dev/null | wc -l | tr -d ' ')"
out=$(bash "$SD/lv-registry-add.sh" LOAF-051 fresh-plan --no-commit 2>&1)
assert_eq "a LOAF row is added to the table" "1"            "$(grep -c '^| LOAF-051 | fresh-plan |' plans/REGISTRY.md)"
bash "$SD/lv-claim.sh" LOAF-051 --pid $$ >/dev/null 2>&1
assert_eq "a LOAF plan can be claimed"       "0"            "$(bash "$SD/lv-claim.sh" LOAF-051 --pid $$ --if-free >/dev/null 2>&1; echo $?)"
bash "$SD/lv-unclaim.sh" LOAF-051 >/dev/null 2>&1
out=$(bash "$SD/lv-defer-criterion.sh" PLN-041 external 'Confirm the thing' --no-commit 2>&1)
assert_eq "a deferred criterion is numbered DEF" "1"        "$(grep -c '^| DEF-001 |' plans/deferred-criteria.md 2>/dev/null)"
case "$(cat plans/deferred-criteria.md 2>/dev/null)" in
  *DEF-NNN*) ok "the file header names DEF" ;;
  *) bad "the file header names DEF" "$(head -30 plans/deferred-criteria.md 2>/dev/null)" ;;
esac

echo
echo "6. Prose is rendered to the issued prefixes"
assert_eq "skills and docs name the project's IDs" "Spec LOAF-NNN from IDEA-012 or FIX-9; DEF-001; T75; LV_PLN" \
  "$(echo 'Spec PLN-NNN from BRF-012 or BUG-9; DC-001; T75; LV_PLN' | bash "$SD/lv-ids.sh" render)"
cd "$TEST_DIR" && printf 'project_slug: "ids"\n' > claude-workflow.yml
assert_eq "the default map is a straight copy" "Spec PLN-NNN; RBK-1" "$(echo 'Spec PLN-NNN; RBK-1' | bash "$SD/lv-ids.sh" render)"

# And install actually does it: a client with a renamed map gets skills and a
# WORKFLOW.md that name its prefixes, and nothing else changes.
C="$TEST_DIR/client"; mkdir -p "$C" && ( cd "$C" && git init -q . && git checkout -qb develop \
  && git commit -q --allow-empty -m init )
printf 'project_slug: "ids-client"\nids:\n  plan: LOAF PLN\n  bug: FIX BUG\n' > "$C/claude-workflow.yml"
LV_INSTALL_NO_COMMIT=1 bash "$REPO_ROOT/install.sh" "$C" >"$TEST_DIR/install.log" 2>&1
assert_eq "install succeeds with a renamed map" "0" "$?"
spec="$C/.claude/skills/lv-spec/SKILL.md"
assert_eq "an installed skill names LOAF plans" "0" "$(grep -c '\bPLN-' "$spec" 2>/dev/null | tr -d ' ' )"
case "$(cat "$spec" 2>/dev/null)" in *LOAF-*) ok "and says LOAF" ;; *) bad "and says LOAF" "$(head -3 "$spec" 2>/dev/null)" ;; esac
case "$(cat "$C/WORKFLOW.md" 2>/dev/null)" in *FIX-*) ok "WORKFLOW.md names FIX bugs" ;; *) bad "WORKFLOW.md names FIX bugs" "$(tail -5 "$TEST_DIR/install.log")" ;; esac

echo
echo "7. No script matches a literal prefix"
# A literal PLN-[0-9] in a script reads the defaults and nothing else, so a
# project that renamed plans would silently lose them there. Comments, the map
# itself and the frozen v1.x generation are exempt; the test-scope self-test
# builds its fixtures under the defaults, which stay accepted.
lint() {
  grep -nE \
    -e '(PLN|BUG|BRF|DC|RBK)-\[0-9]' \
    -e '(PLN|BUG|BRF)\|(PLN|BUG|BRF)' \
    -e '\| (PLN|BUG|BRF|DC)-' \
    -e '(PLN|BUG|BRF|DC)-\*' \
    -e '"(PLN|BUG|BRF|DC)-\$' \
    -e "'(PLN|BUG|BRF|DC)-%" \
    "$@"
}
hits=$(cd "$REPO_ROOT/scripts/v2.00" && lint *.sh; [ $? -le 1 ] || echo "lint: grep failed")
hits=$(printf '%s\n' "$hits" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | grep -vE '^(lv-ids|lv-test-scope-test)\.sh:' | grep . || true)
assert_eq "no literal ID pattern in scripts/v2.00" "" "$hits"

echo
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
