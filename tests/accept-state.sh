#!/usr/bin/env bash
# accept-state.sh — the accept:auto / accept:manual split, tested.
#
#   1. Labels: testing reads accept:auto, accept reads accept:manual, and no
#      script in scripts/v2.00 matches on a label outside wf_state_label.
#   2. Shape: `-> accept` only from testing; `accept ->` only to testing,
#      active, draft or abandoned; complete is still reached only from testing.
#   3. Verdict: testing -> accept is refused while lv-manual-gate.sh says no
#      human is needed, while the automated half is unfinished, and for an
#      express-lane plan; allowed when GATE=true; LV_ALLOW_ACCEPT=1 overrides.
#   4. lv-list-acceptable.sh lists `accept` rows and legacy `testing` rows
#      with an open manual-test gate, and nothing else.
#   5. A manual-test gate fits accept and testing; lv-registry-audit.sh
#      reports UNQUEUED, PRE-SPLIT and STRAY GATE.
#   6. /lv-tray counts accept plans separately on its machine line.
#
# (The dispatcher half — exit 20 and no worker for an accept plan — is in
# tests/orchestrator.sh beside the other drive-one exits.)
#
# Usage: ./tests/accept-state.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO_ROOT/scripts/v2.00"
TEST_DIR=""
PASS=0
FAIL=0

cleanup() { [ -z "${KEEP:-}" ] && [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
assert_has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "no [$2] in: $(printf '%s' "$3" | head -c 400)"; fi; }
assert_not() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1" "unexpected [$2]"; else ok "$1"; fi; }

state_of() { awk -F'|' -v id="$1" '{ gsub(/ /, "", $2) } $2 == id { gsub(/ /, "", $4); print $4 }' plans/REGISTRY.md; }

echo "accept-state.sh"
echo "==============="

# ── 1. Labels ──────────────────────────────────────────────────────────────
echo ""
echo "1. Labels are display only"
# shellcheck source=../scripts/v2.00/lv-states.sh
source "$S/lv-states.sh"
assert_eq "testing reads accept:auto" "accept:auto" "$(wf_state_label testing)"
assert_eq "accept reads accept:manual" "accept:manual" "$(wf_state_label accept)"
assert_eq "every other state reads as itself" "verify complete" "$(wf_state_label verify) $(wf_state_label complete)"
assert_has "accept is a valid stored state" " accept " " $LV_STATES "
# A case pattern or a comparison against a label acts on the wrong half.
# Prose, comments and section titles may say the labels; matching may not.
matches=$(grep -nE "^[[:space:]]*[\"']?accept:(auto|manual)[\"']?\)|[!=]=? *[\"']?accept:(auto|manual)" "$S"/*.sh \
  | grep -v "^$S/lv-states.sh:" || true)
assert_eq "no script matches on a label outside wf_state_label" "" "$matches"

# ── fixture ────────────────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d)
CLIENT="$TEST_DIR/client"
git init -q -b develop "$CLIENT"
cd "$CLIENT" || exit 1
git config user.email t@t; git config user.name "Op Erator"
cat > levain.yml <<'CFG'
project_slug: "accept-test"
manualTestGate:
  requireRenderingSurface: true
  minEyesCriteria: 1
  blockOnCosmetic: false
  renderingSurfaces:
    - "src/**/wwwroot/**"
CFG
mkdir -p plans feature-branches src/App/Cli .claude/orchestrator
echo x > src/App/Cli/Program.cs
printf '.claude/orchestrator/\nfeature-branches/\n' > .gitignore
{
  printf '# Plan Registry\n\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n'
  for r in "PLN-041 ui testing" "PLN-042 cli testing" "PLN-043 chrome testing" "PLN-044 parked accept" \
           "PLN-045 legacy testing" "PLN-046 stray verify" "PLN-047 plain testing"; do
    set -- $r
    printf '| %s | %s | %s | — | feature/%s-%s | 2026-10-03 | 15.0.0 | — | — |\n' "$1" "$2" "$3" "$1" "$2"
  done
  printf '\n<!-- Counter: 50 -->\n'
} > plans/REGISTRY.md

eyes_plan() {   # eyes_plan <dir> [extra criteria block]
  mkdir -p "$1"
  cat > "$1/plan.md" <<P
> **schema_version:** 6

## Goal
Ship the page.

${2:-}
#### Manual
- [ ] (eyes:blocking) /page — reads clearly on a phone
P
}
eyes_plan plans/PLN-041-ui
eyes_plan plans/PLN-042-cli
# Cosmetic: an eyes:blocking criterion gates whatever the diff touches (WFI-129).
sed -i.bak 's/(eyes:blocking)/(eyes:cosmetic)/' plans/PLN-042-cli/plan.md && rm -f plans/PLN-042-cli/plan.md.bak
eyes_plan plans/PLN-043-chrome "#### Chrome-Assisted
- [ ] /page — the button submits the form
"
for p in PLN-044-parked PLN-045-legacy PLN-046-stray PLN-047-plain; do eyes_plan "plans/$p"; done
git add -A; git commit -qm init

for p in PLN-041-ui PLN-043-chrome; do
  git worktree add -q -b "feature/$p" "feature-branches/$p" develop
  ( cd "feature-branches/$p" && mkdir -p src/App/wwwroot && echo y > src/App/wwwroot/app.js && git add -A && git commit -qm ui )
done
git worktree add -q -b feature/PLN-042-cli feature-branches/PLN-042-cli develop
( cd feature-branches/PLN-042-cli && echo more >> src/App/Cli/Program.cs && git add -A && git commit -qm cli )

# ── 2. Shape ───────────────────────────────────────────────────────────────
echo ""
echo "2. accept sits only between testing and the exits it hands to"
out=$("$S/lv-registry-update.sh" PLN-046 verify accept 2>&1); rc=$?
assert_eq "verify -> accept is refused" 1 "$rc"
assert_eq "…and the row is unchanged" verify "$(state_of PLN-046)"
out=$("$S/lv-registry-update.sh" PLN-044 accept complete 2>&1); rc=$?
assert_eq "accept -> complete is refused" 1 "$rc"
assert_has "…pointing back through testing" "testing" "$out"
out=$("$S/lv-registry-update.sh" PLN-044 accept ready 2>&1); rc=$?
assert_eq "accept -> ready is refused" 1 "$rc"
assert_eq "…and the row is still accept" accept "$(state_of PLN-044)"

# ── 3. Verdict ─────────────────────────────────────────────────────────────
echo ""
echo "3. testing -> accept needs lv-manual-gate.sh to say a human is needed"
out=$("$S/lv-registry-update.sh" PLN-042 testing accept 2>&1); rc=$?
assert_eq "a CLI-only diff with only cosmetic eyes (GATE=false) is refused" 1 "$rc"
assert_has "…saying no human is needed" "no human is needed" "$out"
assert_eq "…and stays in testing" testing "$(state_of PLN-042)"

out=$("$S/lv-registry-update.sh" PLN-043 testing accept 2>&1); rc=$?
assert_eq "an unrun Chrome-Assisted criterion is refused" 1 "$rc"
assert_has "…as the automated half's unfinished work" "automated half is unfinished" "$out"

LANE_STUB="$TEST_DIR/lane-bin"
mkdir -p "$LANE_STUB"
cp -R "$S/." "$LANE_STUB/"
cat > "$LANE_STUB/lv-manual-gate.sh" <<'STUB'
#!/usr/bin/env bash
echo "GATE='true'"; echo "PROGRESS_INCOMPLETE='false'"; echo "LANE='express'"
STUB
chmod +x "$LANE_STUB/lv-manual-gate.sh"
out=$("$LANE_STUB/lv-registry-update.sh" PLN-041 testing accept 2>&1); rc=$?
assert_eq "an express-lane plan is refused even with GATE=true" 1 "$rc"
assert_has "…sent to the post-ship checklist" "post-ship checklist" "$out"

# Clients' LVI-009/018/040: the lane answers eyes criteria only, so an untested
# Chrome-Assisted criterion under it had no route to anyone.
cat > "$LANE_STUB/lv-manual-gate.sh" <<'STUB'
#!/usr/bin/env bash
echo "GATE='true'"; echo "PROGRESS_INCOMPLETE='false'"; echo "LANE='express'"; echo "CHROME_UNTESTED='1'"
STUB
out=$("$LANE_STUB/lv-registry-update.sh" PLN-041 testing accept 2>&1); rc=$?
assert_eq "an express-lane plan with an untested Chrome-Assisted criterion is allowed" 0 "$rc"
assert_eq "…and the row reads accept" accept "$(state_of PLN-041)"
"$S/lv-registry-update.sh" PLN-041 accept testing >/dev/null 2>&1
assert_eq "(back to testing for what follows)" testing "$(state_of PLN-041)"

# A client's LVI-029: the record's TREE was a day-old build, so the suite
# result under it was too, and the tester had run nothing on this one.
old41=$(git -C feature-branches/PLN-041-ui rev-parse --short HEAD~1)
new41=$(git -C feature-branches/PLN-041-ui rev-parse --short HEAD)
printf 'TREE feature-branches/PLN-041-ui @ feature/PLN-041-ui %s (2026-10-04T16:18:37Z)\n\nSUITE_RESULT=pass\n' "$old41" \
  > plans/PLN-041-ui/test-progress.md
out=$("$S/lv-registry-update.sh" PLN-041 testing accept 2>&1); rc=$?
assert_eq "a record stamped on another build is refused" 1 "$rc"
assert_has "…naming the stamp" "TREE is $old41" "$out"
assert_eq "…and stays in testing" testing "$(state_of PLN-041)"
sed -i.bak "s/ $old41 / $new41 /" plans/PLN-041-ui/test-progress.md && rm -f plans/PLN-041-ui/test-progress.md.bak

out=$("$S/lv-registry-update.sh" PLN-041 testing accept 2>&1); rc=$?
assert_eq "a rendering diff with open eyes criteria is allowed" 0 "$rc"
assert_eq "…and the row reads accept" accept "$(state_of PLN-041)"

# A client's LVI-031: the tester's testing -> accept was refused, and it
# opened manual-test anyway, leaving a plan in testing asking a human.
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-043 manual-test "1 criterion needs eyes" --skill lv-test 2>&1); rc=$?
assert_eq "unattended, manual-test on a testing row is refused" 6 "$rc"
assert_has "…pointing at the transition first" "testing accept first" "$out"
assert_eq "…and nothing is queued" "" "$(ls .claude/orchestrator/gates/PLN-043* 2>/dev/null)"
out=$(LV_UNATTENDED=1 "$S/lv-gate-open.sh" PLN-041 manual-test "1 criterion needs eyes" --skill lv-test 2>&1); rc=$?
assert_eq "beside an accept row it opens" 0 "$rc"
"$S/lv-gate-close.sh" PLN-041 done >/dev/null 2>&1

out=$(LV_ALLOW_ACCEPT=1 "$S/lv-registry-update.sh" PLN-042 testing accept 2>&1); rc=$?
assert_eq "LV_ALLOW_ACCEPT=1 overrides a refusal" 0 "$rc"
"$S/lv-registry-update.sh" PLN-042 accept testing >/dev/null 2>&1
assert_eq "accept -> testing hands back" testing "$(state_of PLN-042)"

# Clients' LVI-013/052: `--add findings.md` named the plan's own file and
# was skipped as a path that matched nothing at the develop root.
d42=$(ls -d plans/PLN-042-*/ | head -1)
printf '\n## Acceptance — finding\n' >> "${d42}findings.md"
LV_ALLOW_ACCEPT=1 "$S/lv-registry-update.sh" PLN-042 testing accept --commit "accept(PLN-042): bare --add" --add findings.md >/dev/null 2>&1
assert_has "a bare --add name commits the plan's own file" "${d42}findings.md" "$(git show --stat --format= HEAD)"
"$S/lv-registry-update.sh" PLN-042 accept testing >/dev/null 2>&1

# ── 4. lv-list-acceptable ──────────────────────────────────────────────────
echo ""
echo "4. lv-list-acceptable.sh lists what waits on a human"
"$S/lv-gate-open.sh" PLN-045 manual-test "1 criterion needs human eyes" >/dev/null 2>&1
"$S/lv-gate-open.sh" PLN-046 manual-test "left behind" >/dev/null 2>&1
out=$("$S/lv-list-acceptable.sh" 2>/dev/null)
assert_has "an accept row is listed, shape accept" "PLN-044-parked" "$(printf '%s\n' "$out" | awk -F'\t' '$6 == "accept"')"
assert_has "a testing row with an open manual-test gate is listed, shape legacy" "PLN-045-legacy" \
  "$(printf '%s\n' "$out" | awk -F'\t' '$6 == "legacy"')"
assert_not "a plain testing row is not" "PLN-047-plain" "$out"
assert_not "a verify row with a stray gate is not" "PLN-046-stray" "$out"
"$S/lv-list-acceptable.sh" PLN-047 >/dev/null 2>&1; rc=$?
assert_eq "asking for an ineligible plan exits 1" 1 "$rc"
"$S/lv-list-acceptable.sh" nonsense >/dev/null 2>&1; rc=$?
assert_eq "a bad id exits 2" 2 "$rc"

# ── 5. Gate fit and the audit ──────────────────────────────────────────────
echo ""
echo "5. manual-test fits accept and testing; the audit sees the rest"
"$S/lv-gate-open.sh" PLN-041 manual-test "1 criterion needs human eyes" >/dev/null 2>&1
gates=$("$S/lv-list-gates.sh" 2>/dev/null)
assert_eq "a manual-test gate on accept fits" ok "$(printf '%s\n' "$gates" | awk -F'\t' '$1 == "PLN-041" { print $8 }')"
assert_eq "…and on testing" ok "$(printf '%s\n' "$gates" | awk -F'\t' '$1 == "PLN-045" { print $8 }')"
assert_eq "…and not on verify" mismatch "$(printf '%s\n' "$gates" | awk -F'\t' '$1 == "PLN-046" { print $8 }')"

audit=$("$S/lv-registry-audit.sh" 2>&1)
assert_has "an accept row with no gate is UNQUEUED" "UNQUEUED      PLN-044" "$audit"
assert_has "a testing row with the gate is PRE-SPLIT" "PRE-SPLIT" "$audit"
assert_has "…naming it" "PLN-045" "$(printf '%s\n' "$audit" | grep PRE-SPLIT)"
assert_has "a manual-test gate elsewhere is a STRAY GATE" "PLN-046" "$(printf '%s\n' "$audit" | grep 'STRAY GATE')"
assert_not "accept with its gate is not reported" "PLN-041" "$(printf '%s\n' "$audit" | grep -E 'UNQUEUED|PRE-SPLIT|STRAY GATE')"

# ── 6. Tray ────────────────────────────────────────────────────────────────
echo ""
echo "6. /lv-tray counts accept apart from testing"
tray=$("$S/lv-tray.sh" --fields 2>/dev/null || true)
assert_has "the --fields line carries accept=2" "	accept=2" "$tray"
assert_has "…and testing apart from it" "	testing=" "$tray"

# ── 7. Completion ──────────────────────────────────────────────────────────
echo ""
echo "7. -> complete moves test-progress.md into progress.md (client LVI-043)"
printf '# Test Progress — PLN-047\n\n| Criterion | Result |\n|-|-|\n| reads clearly | PASS |\n' \
  > plans/PLN-047-plain/test-progress.md
git add plans/PLN-047-plain/test-progress.md && git commit -qm "progress"
LV_ALLOW_UNMERGED=1 LV_ALLOW_UNTESTED=1 "$S/lv-registry-update.sh" PLN-047 testing complete - >/dev/null 2>&1
assert_eq "the transition lands" complete "$(state_of PLN-047)"
assert_eq "test-progress.md is gone from disk" false \
  "$([ -f plans/PLN-047-plain/test-progress.md ] && echo true || echo false)"
assert_eq "…and from HEAD, in the transition's commit" "" \
  "$(git ls-tree -r --name-only HEAD -- plans/PLN-047-plain/test-progress.md)"
assert_has "its rows are kept in progress.md" "| reads clearly | PASS |" \
  "$(git show HEAD:plans/PLN-047-plain/progress.md 2>/dev/null)"
assert_eq "nothing is left dirty" "" "$(git status --porcelain -- plans/PLN-047-plain)"

echo ""
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
