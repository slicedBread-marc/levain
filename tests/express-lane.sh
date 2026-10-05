#!/usr/bin/env bash
# express-lane.sh — LVI-025: the per-artifact express lane, tested.
#
#   1. Declaring it is a human's act: lv-bug-new.sh --lane express writes the
#      field and the corroborating event, and every declaring path refuses
#      under LV_UNATTENDED=1 without leaving anything behind.
#   2. The eligibility check passes a small plan and downgrades the motivating
#      case (10 steps, Dockerfile + deploy workflow, npm deps, CSP and a route
#      policy, tagged security) with every one of those reasons listed.
#   3. A hand-typed Lane field is not a declaration.
#   4. --accept-warnings is human-only, covers exactly what it accepted, and a
#      new warning downgrades again.
#   5. spec-approval and manual-test are answered for a cleared plan; eyes
#      criteria move to a post-ship checklist and the completion guard passes;
#      none of the lane's writes makes the review fingerprint stale.
#   6. production-push: one push per cleared plan, and nothing else in the
#      batch — a commit naming no plan, or a plan outside the lane, is refused.
#   7. On a plan whose last section is ## Amendments (hashed), neither ## Lane
#      nor ## Post-ship checklist changes the fingerprint (LVI-032/033).
#   8. "no secrets", "rely on SameSite" and a compose command in a code span
#      do not downgrade; a real match later in the plan still does; a path on
#      a Files line is judged once (LVI-034/035).
#
# Usage: ./tests/express-lane.sh
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

TEST_DIR=$(mktemp -d)
UPSTREAM="$TEST_DIR/upstream.git"
CLIENT="$TEST_DIR/client"

registry_row() { printf '| %s | %s | %s | — | — | 2026-09-26 | 14.22.0 | %s | — |\n' "$1" "$2" "$3" "$4"; }

small_plan() {   # small_plan <dir> <source-header-line>
  mkdir -p "$1"
  cat > "$1/plan.md" <<P
# Rename the print button

> **ID:** ${1##*/}
> **schema_version:** 6
$2

## Goal
Rename the print button label to "Print sheet".

## Steps

### Step 1: Change the label
- **Files:** modify \`src/App/Pages/print.html\`
- **What:** the button text reads "Print sheet".
- **Acceptance:** the page shows the new label.

### Step 2: Update the test
- **Files:** modify \`tests/App.Tests/PrintPageTests.cs\`
- **What:** assert the new label.
- **Acceptance:** the test passes.

## Verification Checklist

### Human Test Criteria

#### Manual
- [ ] (eyes:blocking) /print — the label reads naturally next to the preview

## Design Decisions
- **Decision:** copy only — **Why:** nothing else changes.

## Out of Scope
- Anything about secrets, migrations or the Dockerfile.

## Review
> **2026-09-26 — Plan Review**
> **Result:** Approved
P
}

big_plan() {   # the motivating case, name-free
  mkdir -p "$1"
  {
    printf '# Photo tool\n\n> **ID:** %s\n> **schema_version:** 6\n%s\n\n## Goal\nShip a browser-only photo layout app.\n\n## Steps\n' "${1##*/}" "$2"
    printf '\n### Step 1: Client package\n- **Files:** create `clients/photo/package.json`, `clients/photo/package-lock.json`; modify `src/Web/Web.csproj`.\n- **What:** add `pdf-lib` under `"dependencies"`.\n'
    for n in 2 3 4 5 6; do printf '\n### Step %d: Module %d\n- **Files:** create `clients/photo/src/m%d.ts`, `a%d.ts`, `b%d.ts`.\n- **What:** pure functions.\n' "$n" "$n" "$n" "$n" "$n"; done
    printf '\n### Step 7: Endpoint and route policy\n- **Files:** create `src/Web/Photo/PhotoEndpoint.cs`; modify `src/Web/Catalogue/CatalogueRoutePolicy.cs`, `src/Web/Program.cs`.\n- **What:** `MapGet(Route).RequireAuthorization(...)` with its own Content-Security-Policy.\n'
    printf '\n### Step 8: Docker and CI\n- **Files:** modify `docker/Dockerfile`, `.github/workflows/deploy.yml`.\n- **What:** a node stage; `npm ci`.\n'
    printf '\n### Step 9: Tests\n- **Files:** create `tests/Web.Tests/PhotoRouteTests.cs`.\n'
    printf '\n### Step 10: Docs\n- **Files:** modify `README.md`.\n'
    printf '\n## Verification Checklist\n\n#### Manual\n- [ ] (eyes:blocking) the sheet looks right\n- [ ] (external) prints true to size on a real printer\n\n## Review\n> **Result:** Approved\n'
  } > "$1/plan.md"
}

new_client() {
  rm -rf "$UPSTREAM" "$CLIENT" "$TEST_DIR"/wt-*
  git init -q --bare "$UPSTREAM"
  git init -q -b develop "$CLIENT"
  cd "$CLIENT" || exit 1
  git config user.email t@t; git config user.name "Op Erator"
  cat > levain.yml <<'CFG'
project_slug: "lane-test"
specApproval:
  mode: gate
  gateTags:
    - security
CFG
  mkdir -p plans/briefs bugs/open .claude/orchestrator src
  printf 'x\n' > src/app.txt
  {
    printf '# Plan Registry\n\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n'
  } > plans/REGISTRY.md
  printf '\n<!-- Counter: 30 -->\n' >> plans/REGISTRY.md
  printf '# Briefs\n\n## Decided\n' > plans/briefs/INDEX.md
  printf '.claude/orchestrator/\n' > .gitignore
  git add -A; git commit -qm init
  git branch main; git branch release
  git remote add origin "$UPSTREAM"
  git push -q origin develop main release
  git fetch -q origin
}

add_row() {   # add_row <id> <slug> <state> <tags> — above the counter line
  local row; row=$(registry_row "$@")
  awk -v r="$row" '/<!-- Counter/ && !d { print r; d = 1 } { print }' plans/REGISTRY.md > plans/REGISTRY.md.tmp
  mv plans/REGISTRY.md.tmp plans/REGISTRY.md
}

echo "express-lane.sh"
echo "==============="

# ── 1. Declaring ───────────────────────────────────────────────────────────
echo ""
echo "1. Declaring is a human's act"
new_client
out=$(LV_UNATTENDED=1 "$S/lv-bug-new.sh" "Rename the print button" --lane express 2>&1); rc=$?
assert_eq "lv-bug-new --lane express refuses under LV_UNATTENDED=1" 1 "$rc"
assert_eq "…and files nothing" "" "$(ls bugs/open)"
assert_has "…saying why" "never declares its own work safe" "$out"

eval "$("$S/lv-bug-new.sh" "Rename the print button" --lane express --description 'the label' 2>/dev/null)"
assert_has "the bug carries the Lane field" "> **Lane:** express (declared by Op Erator," "$(cat "$BUG_DIR/bug.md")"
assert_has "a lane-declare event corroborates it" "lane-declare	$BUG_ID	express declared by Op Erator" "$(cat .claude/orchestrator/events.log)"
assert_eq "the filing is committed" "" "$(git status --porcelain -- bugs)"
BUG_SMALL="$BUG_ID"

out=$("$S/lv-bug-new.sh" "Add a Dockerfile stage and an API key" --lane express --description 'touch `docker/Dockerfile` and the api key' 2>&1 >/dev/null)
assert_has "the filing pre-check warns on the request text" "pre-check WARNING" "$out"
assert_has "…naming the build surface" "build/deploy surface" "$out"

printf '# Tiny idea\n\n> **ID:** BRF-040\n> **Status:** Decided\n\n## Problem\nsmall\n' > plans/briefs/BRF-040-tiny.md
git add -A; git commit -qm brief
assert_eq "lv-lane.sh declare refuses under LV_UNATTENDED=1" 1 "$(LV_UNATTENDED=1 "$S/lv-lane.sh" declare BRF-040 >/dev/null 2>&1; echo $?)"
assert_eq "…leaving the brief untouched" "" "$(grep 'Lane:' plans/briefs/BRF-040-tiny.md)"
"$S/lv-lane.sh" declare BRF-040 >/dev/null 2>&1
assert_has "declare writes the brief's Lane field" "> **Lane:** express (declared by Op Erator" "$(cat plans/briefs/BRF-040-tiny.md)"
out=$(LV_UNATTENDED=1 "$S/lv-dep-notify.sh" "x" --lane express 2>&1); rc=$?
assert_eq "lv-dep-notify --lane express refuses under LV_UNATTENDED=1" 1 "$rc"

# ── 2. Eligibility ─────────────────────────────────────────────────────────
echo ""
echo "2. The check passes small work and downgrades the motivating case"
N_SMALL=${BUG_SMALL#*-}
small_plan "plans/PLN-$N_SMALL-rename" "> **Bug:** $BUG_SMALL — Rename the print button"
add_row "PLN-$N_SMALL" rename draft ux
git add -A; git commit -qm plan
out=$("$S/lv-lane.sh" check "PLN-$N_SMALL" 2>&1); rc=$?
assert_eq "a small declared plan is eligible (exit 0)" 0 "$rc"
assert_has "…and the verdict is written into plan.md" "**express** — eligible" "$(cat "plans/PLN-$N_SMALL-rename/plan.md")"
assert_not "Out of Scope text is not read (it names secrets and the Dockerfile)" "secrets" "$out"

eval "$("$S/lv-bug-new.sh" "Photo tool" --lane express 2>/dev/null)"
N_BIG=${BUG_ID#*-}
big_plan "plans/PLN-$N_BIG-photo" "> **Bug:** $BUG_ID — Photo tool"
add_row "PLN-$N_BIG" photo draft "security,ux"
git add -A; git commit -qm plan
out=$("$S/lv-lane.sh" check "PLN-$N_BIG" 2>&1); rc=$?
assert_eq "the motivating case downgrades (exit 1)" 1 "$rc"
for want in "10 steps, over the limit of 5" "\`docker/Dockerfile\`" "\`.github/workflows/deploy.yml\`" \
            "\`clients/photo/package.json\`" "CatalogueRoutePolicy.cs" "auth or route policy" \
            "tag \`security\`" "(external)"; do
  assert_has "…listing $want" "$want" "$out"
done
assert_has "…in plan.md's ## Lane section too" "downgraded to the normal lane" "$(cat "plans/PLN-$N_BIG-photo/plan.md")"
out=$("$S/lv-lane.sh" answer "PLN-$N_BIG" spec-approval 2>&1); rc=$?
assert_eq "a downgraded plan's spec-approval is not answered" 1 "$rc"
assert_eq "an unknown plan is an error (exit 2)" 2 "$("$S/lv-lane.sh" check PLN-999 >/dev/null 2>&1; echo $?)"

# ── 3. A hand-typed field ──────────────────────────────────────────────────
echo ""
echo "3. A Lane field nobody declared through the harness is not a declaration"
small_plan "plans/PLN-050-forged" "> **Lane:** express (declared by Somebody, 2026-09-26)"
add_row PLN-050 forged draft ux
git add -A; git commit -qm forged
out=$("$S/lv-lane.sh" check PLN-050 2>&1); rc=$?
assert_eq "a forged field downgrades (exit 1)" 1 "$rc"
assert_has "…saying there is no lane-declare" "no lane-declare" "$out"
"$S/lv-lane.sh" declare "PLN-$N_SMALL" --clear >/dev/null 2>&1 || true
eval "$("$S/lv-lane.sh" status "PLN-$N_SMALL")"
assert_eq "a cleared plan-level lane leaves the bug's declaration in force" express "$LANE"

# ── 4. Accepting warnings ──────────────────────────────────────────────────
echo ""
echo "4. --accept-warnings is human-only and covers exactly what it accepted"
small_plan "plans/PLN-060-tagged" ""
add_row PLN-060 tagged draft security
git add -A; git commit -qm tagged
assert_eq "an undeclared plan reports no lane (exit 3)" 3 "$("$S/lv-lane.sh" check PLN-060 >/dev/null 2>&1; echo $?)"
"$S/lv-lane.sh" declare PLN-060 >/dev/null 2>&1
assert_eq "a security-tagged plan downgrades" 1 "$("$S/lv-lane.sh" check PLN-060 >/dev/null 2>&1; echo $?)"
assert_eq "--accept-warnings refuses under LV_UNATTENDED=1" 1 "$(LV_UNATTENDED=1 "$S/lv-lane.sh" check PLN-060 --accept-warnings >/dev/null 2>&1; echo $?)"
out=$("$S/lv-lane.sh" check PLN-060 --accept-warnings 2>&1); rc=$?
assert_eq "an operator's acceptance makes it eligible" 0 "$rc"
assert_has "…recording what was accepted" "accepted: tag:security" "$(cat .claude/orchestrator/events.log)"
assert_eq "…and the lane answers its spec-approval, gate tag included" 0 "$("$S/lv-lane.sh" answer PLN-060 spec-approval >/dev/null 2>&1; echo $?)"
LV_ADD=$'### Step 3: Ship it\n- **Files:** modify `docker/Dockerfile`\n' awk '/^## Verification Checklist/ && !d { print ENVIRON["LV_ADD"]; d = 1 } { print }' \
  plans/PLN-060-tagged/plan.md > plans/PLN-060-tagged/plan.md.tmp && mv plans/PLN-060-tagged/plan.md.tmp plans/PLN-060-tagged/plan.md
out=$("$S/lv-lane.sh" check PLN-060 --no-commit 2>&1); rc=$?
assert_eq "a warning that appears after the acceptance downgrades again" 1 "$rc"
assert_has "…naming only the new one" "docker/Dockerfile" "$out"
assert_not "…not the accepted tag" "tag \`security\`" "$out"
git checkout -q -- plans/PLN-060-tagged/plan.md

# ── 5. Answering gates ─────────────────────────────────────────────────────
echo ""
echo "5. spec-approval and manual-test, answered for a cleared plan"
P="PLN-$N_SMALL"; PD="plans/$P-rename"
before=$(cd "$CLIENT" && bash -c "source '$S/lv-orch-lib.sh'; wf_plan_body_fingerprint $P")
out=$("$S/lv-lane.sh" answer "$P" spec-approval 2>&1); rc=$?
assert_eq "spec-approval answered (exit 0)" 0 "$rc"
assert_has "…logged as express in the autonomy log" "autonomy-use	$P	express: spec-approval answered" "$(cat .claude/orchestrator/events.log)"
sed -i.bak "s/| $P | rename | draft |/| $P | rename | testing |/" plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
git add -A; git commit -qm testing
eval "$("$S/lv-manual-gate.sh" "$P" 2>/dev/null)"
assert_eq "lv-manual-gate does not gate an express plan's eyes criteria" false "$GATE"
assert_eq "…and says the lane is express" express "$LANE"
out=$("$S/lv-lane.sh" answer "$P" manual-test 2>&1); rc=$?
assert_eq "manual-test answered (exit 0)" 0 "$rc"
assert_has "the criterion is ticked in place" "- [x] (eyes:blocking) /print" "$(cat "$PD/plan.md")"
assert_has "…and listed on the post-ship checklist" "## Post-ship checklist" "$(cat "$PD/plan.md")"
assert_eq "the completion guard now lets it complete" 0 \
  "$("$S/lv-registry-update.sh" "$P" testing complete - >/dev/null 2>&1; echo $?)"
after=$(cd "$CLIENT" && bash -c "source '$S/lv-orch-lib.sh'; wf_plan_body_fingerprint $P")
assert_eq "none of the lane's writes changed the review fingerprint" "$before" "$after"
git add -A; git commit -qm complete >/dev/null 2>&1 || true

# ── 6. The push ────────────────────────────────────────────────────────────
echo ""
echo "6. production-push: one push per cleared plan, and nothing else in the batch"
git checkout -q main
printf 'label\n' >> src/app.txt; git add -A; git commit -qm "implement($P-rename): step 1 — label"
git merge -q --no-ff develop -m "release: bring plans" >/dev/null 2>&1
out=$("$S/lv-lane.sh" push-covered 2>&1); rc=$?
assert_eq "a main whose code is all a cleared plan's is covered" 0 "$rc"
out=$("$S/lv-autonomy.sh" production-push 2>&1); rc=$?
assert_eq "lv-autonomy.sh authorizes the push with no standing grant" 0 "$rc"
assert_has "…saying the express lane did it" "express lane" "$out"
assert_has "…counted as a production-push" "production-push authorized by the express lane for $P" "$(cat .claude/orchestrator/events.log)"
git push -q origin main; git fetch -q origin
printf 'more\n' >> src/app.txt; git add -A; git commit -qm "implement($P-rename): a second change"
assert_eq "the plan's one push is spent" 1 "$("$S/lv-lane.sh" push-covered --quiet >/dev/null 2>&1; echo $?)"
git reset -q --hard origin/main
printf 'stray\n' >> src/app.txt; git add -A; git commit -qm "tweak the app"
out=$("$S/lv-lane.sh" push-covered 2>&1); rc=$?
assert_eq "a code commit naming no plan is not covered" 1 "$rc"
assert_has "…and says which" "names no plan" "$out"
assert_eq "lv-autonomy.sh refuses it" 1 "$("$S/lv-autonomy.sh" production-push --check --quiet >/dev/null 2>&1; echo $?)"
git reset -q --hard origin/main
printf 'big\n' >> src/app.txt; git add -A; git commit -qm "implement(PLN-$N_BIG-photo): step 1"
out=$("$S/lv-lane.sh" push-covered 2>&1); rc=$?
assert_eq "a plan outside the lane is not covered" 1 "$rc"
git checkout -q develop

# ── 7. A plan that ends in a hashed section ────────────────────────────────
echo ""
echo "7. The lane's writes leave the fingerprint alone when ## Amendments is last (LVI-032/033)"
eval "$("$S/lv-bug-new.sh" "Retitle the sheet" --lane express 2>/dev/null)"
N_AM=${BUG_ID#*-}; PA="PLN-$N_AM"; PDA="plans/$PA-retitle"
small_plan "$PDA" "> **Bug:** $BUG_ID — Retitle the sheet"
printf '\n## Amendments\n> Append-only. Added by /spec when a plan in active/ or beyond needs a design change.\n> Format: `[date] — description of change and why`\n' >> "$PDA/plan.md"
add_row "$PA" retitle draft "security"
git add -A; git commit -qm "plan ending in amendments"
before=$(bash -c "source '$S/lv-orch-lib.sh'; wf_plan_body_fingerprint $PA")
"$S/lv-lane.sh" answer "$PA" spec-approval >/dev/null 2>&1; rc=$?
assert_eq "a downgrade appends ## Lane after ## Amendments (exit 1)" 1 "$rc"
assert_has "…and the section is there" "## Lane" "$(cat "$PDA/plan.md")"
after=$(bash -c "source '$S/lv-orch-lib.sh'; wf_plan_body_fingerprint $PA")
assert_eq "…without changing the review fingerprint" "$before" "$after"
"$S/lv-lane.sh" check "$PA" --accept-warnings >/dev/null 2>&1
sed -i.bak "s/| $PA | retitle | draft |/| $PA | retitle | testing |/" plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
git add -A; git commit -qm testing >/dev/null 2>&1 || true
"$S/lv-lane.sh" answer "$PA" manual-test >/dev/null 2>&1
assert_has "the post-ship checklist is appended too" "## Post-ship checklist" "$(cat "$PDA/plan.md")"
after=$(bash -c "source '$S/lv-orch-lib.sh'; wf_plan_body_fingerprint $PA")
assert_eq "…and still the fingerprint is unchanged" "$before" "$after"

# ── 8. Text that is plainly not-doing ─────────────────────────────────────
echo ""
echo "8. Negated, relied-on and run-only mentions do not downgrade (LVI-034, LVI-035)"
eval "$("$S/lv-bug-new.sh" "Debug note" --lane express 2>/dev/null)"
N_TX=${BUG_ID#*-}; PT="PLN-$N_TX"; PDT="plans/$PT-note"
mkdir -p "$PDT"
cat > "$PDT/plan.md" <<P
# Debug note

> **ID:** $PT
> **schema_version:** 6
> **Bug:** $BUG_ID — Debug note

## Goal
A dev aid: plain UI, no secrets, cookies or tokens captured.

## Steps

### Step 1: The note
- **Files:** modify \`src/App/Pages/note.html\`
- **What:** the post carries no CSRF field of its own; JSON posts rely on SameSite=Lax as they do today.

### Step 2: Run it
- **Files:** modify \`tests/App.Tests/NoteTests.cs\`
- **What:** run it in the container: \`docker compose -f docker/docker-compose.yml exec web dotnet App.dll note\`.

## Design Decisions
- **Decision:** cookie handling unchanged, SameSite untouched — **Why:** nothing else needs it.

## Review
> **Result:** Approved
P
add_row "$PT" note draft ux
git add -A; git commit -qm "plan with not-doing text"
out=$("$S/lv-lane.sh" check "$PT" --no-commit 2>&1); rc=$?
assert_eq "a plan that only mentions secrets, SameSite and a compose command is eligible" 0 "$rc"
assert_not "…no secrets reason for \"no secrets\"" "secrets:" "$out"
assert_not "…no auth reason for \"rely on SameSite\"" "auth or route policy" "$out"
assert_not "…no build reason for a compose command in a code span" "build/deploy surface" "$out"
git checkout -q -- "$PDT/plan.md"

LV_ADD='- **What:** **Secret stripping:** the store removes every secret value it is handed.' \
  awk '/^### Step 2/ && !d { print ENVIRON["LV_ADD"]; print ""; d = 1 } { print }' "$PDT/plan.md" > "$PDT/plan.md.tmp" && mv "$PDT/plan.md.tmp" "$PDT/plan.md"
out=$("$S/lv-lane.sh" check "$PT" --no-commit 2>&1); rc=$?
assert_eq "a later real match still downgrades, past the negated one" 1 "$rc"
assert_has "…reported on the line that does it" "Secret stripping" "$out"
git checkout -q -- "$PDT/plan.md"

LV_ADD='### Step 3: Compose\n- **Files:** modify `docker/docker-compose.household.yml`\n- **What:** mount the folder.\n' \
  awk '/^## Design Decisions/ && !d { printf "%s\n", ENVIRON["LV_ADD"]; d = 1 } { print }' "$PDT/plan.md" > "$PDT/plan.md.tmp" && mv "$PDT/plan.md.tmp" "$PDT/plan.md"
out=$("$S/lv-lane.sh" check "$PT" --no-commit 2>&1)
assert_eq "a compose file on a Files line is one reason, not two" 1 "$(printf '%s\n' "$out" | grep -c 'build/deploy surface')"
git checkout -q -- "$PDT/plan.md"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
