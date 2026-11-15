#!/usr/bin/env bash
# ignored-sources.sh — a client's BUG-065: source files a plan wrote under a
# git-ignored folder are found before the plan leaves the builder.
#
#   1. lv-ignored-sources.sh lists a plan's listed and sibling source files that
#      are ignored and untracked; not bin/ output, not a root .env.
#   2. lv-registry-update.sh refuses `active -> verify` while it does, and
#      LV_ALLOW_IGNORED=1 overrides.
#   3. A scoped negation plus a commit clears it; no worktree is exit 3.
#
# Usage: ./tests/ignored-sources.sh
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
CLIENT="$TEST_DIR/client"
P=PLN-070; SLUG=debug-report; BR="feature/$P-$SLUG"; WT="$CLIENT/feature-branches/$P-$SLUG"

git init -q -b develop "$CLIENT"
cd "$CLIENT" || exit 1
git config user.email t@t; git config user.name "Op Erator"
printf 'project_slug: "ignored-test"\n' > levain.yml
mkdir -p "plans/$P-$SLUG" src/App .claude/orchestrator
printf 'class Program {}\n' > src/App/Program.cs
printf '.claude/orchestrator/\nfeature-branches/\n[Dd]ebug/\n[Bb]in/\n.env\nsite/*.html\n' > .gitignore
mkdir -p web site; printf '<p>\n' > web/index.html; printf 'site\n' > site/README.md
cat > "plans/$P-$SLUG/plan.md" <<'PLAN'
# Debug report

## Goal
A debug report.

## Steps

### Step 1: Store
- **Files:** create `src/App/Debug/Store.cs`, `Options.cs`; modify `src/App/Program.cs`, `README.md`.

### Step 2: Page
- **Files:** create `web/index.html`; modify `site/README.md`.
PLAN
printf '# Plan Registry\n\n| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |\n|-|-|-|-|-|-|-|-|-|\n' > plans/REGISTRY.md
printf '| %s | %s | active | — | %s | 2026-10-05 | 15.0.3 | — | — |\n' "$P" "$SLUG" "$BR" >> plans/REGISTRY.md
printf '\n<!-- Counter: 70 -->\n' >> plans/REGISTRY.md
printf 'readme\n' > README.md
git add -A; git commit -qm init
git worktree add -q -b "$BR" "$WT" develop

mkdir -p "$WT/src/App/Debug" "$WT/src/App/bin/Debug"
printf 'class Store {}\n'   > "$WT/src/App/Debug/Store.cs"
printf 'class Options {}\n' > "$WT/src/App/Debug/Options.cs"
printf 'class Setup {}\n'   > "$WT/src/App/Debug/Setup.cs"
printf 'notes\n'            > "$WT/src/App/Debug/notes.txt"
printf 'gen\n'              > "$WT/src/App/bin/Debug/Gen.cs"
printf 'K=v\n'              > "$WT/.env"
printf '<p>gen</p>\n'       > "$WT/site/index.html"

echo "ignored-sources.sh"
echo "=================="

echo ""
echo "1. The plan's ignored sources are listed"
out=$("$S/lv-ignored-sources.sh" "$P" 2>&1); rc=$?
assert_eq "exit 1 while sources are ignored" 1 "$rc"
assert_has "a listed file" "src/App/Debug/Store.cs" "$out"
assert_has "a bare name relative to the listed path's folder" "src/App/Debug/Options.cs" "$out"
assert_has "a sibling the plan did not name, same extension" "src/App/Debug/Setup.cs" "$out"
assert_has "…with the rule that hides it" ".gitignore:3:[Dd]ebug/" "$out"
assert_not "not a sibling of another extension" "notes.txt" "$out"
assert_not "not build output under bin/" "bin/Debug" "$out"
assert_not "not a root .env" ".env" "$out"
assert_not "not a sibling whose extension is listed only in another folder (LVI-044..056)" "site/index.html" "$out"

echo ""
echo "1b. A Files line's quoted code is not a file (a client's LVI-044)"
printf '## Steps\n\n### Step 1\n- **Files:** create `tests/X.Tests/Auth/DevLoginFlowTests.cs` (a `sealed` class, `IDisposable`, namespace `X.Tests.Auth.Dev`, `CookieSecurePolicy.Always`), `Helper.cs`, `Dockerfile`, `.env.example`.\n' > "$TEST_DIR/files-plan.md"
listed=$(bash -c 'source "$1/lv-orch-lib.sh"; wf_plan_files "$2"' _ "$S" "$TEST_DIR/files-plan.md")
assert_has "the path is listed" "tests/X.Tests/Auth/DevLoginFlowTests.cs" "$listed"
assert_has "a bare file name beside it too" "tests/X.Tests/Auth/Helper.cs" "$listed"
assert_has "…and an extensionless Dockerfile" "tests/X.Tests/Auth/Dockerfile" "$listed"
assert_has "…and a dotfile" "tests/X.Tests/Auth/.env.example" "$listed"
assert_not "a keyword is not" "/sealed" "$listed"
assert_not "a type name is not" "/IDisposable" "$listed"
assert_not "a namespace is not" "X.Tests.Auth.Dev" "$listed"
assert_not "an enum value is not" "CookieSecurePolicy.Always" "$listed"

echo ""
echo "2. active -> verify is refused while they are"
out=$("$S/lv-registry-update.sh" "$P" active verify 2>&1); rc=$?
assert_eq "the transition is refused" 1 "$rc"
assert_has "…naming the files" "src/App/Debug/Store.cs" "$out"
assert_has "…and the override" "LV_ALLOW_IGNORED=1" "$out"
assert_has "the row is unchanged" "| $P | $SLUG | active |" "$(cat plans/REGISTRY.md)"

echo ""
echo "3. A scoped negation and a commit clear it"
( cd "$WT" && printf '!src/**/Debug/\n' >> .gitignore && git add -A && git commit -qm "track Debug sources" )
out=$("$S/lv-ignored-sources.sh" "$P" 2>&1); rc=$?
assert_eq "exit 0 once committed" 0 "$rc"
out=$("$S/lv-registry-update.sh" "$P" active verify 2>&1); rc=$?
assert_eq "the transition goes through" 0 "$rc"
assert_has "…and the row moved" "| $P | $SLUG | verify |" "$(cat plans/REGISTRY.md)"

echo ""
echo "4. A registry Branch of — still finds the plan's worktree"
sed -i.bak "s#| $P | $SLUG | verify | — | $BR |#| $P | $SLUG | verify | — | — |#" plans/REGISTRY.md && rm -f plans/REGISTRY.md.bak
assert_has "the Branch column reads —" "| $P | $SLUG | verify | — | — |" "$(cat plans/REGISTRY.md)"
assert_eq "exit 0, not 3: feature/<plan> is checked" 0 "$("$S/lv-ignored-sources.sh" "$P" >/dev/null 2>&1; echo $?)"
assert_eq "…by its full name too" 0 "$("$S/lv-ignored-sources.sh" "$P-$SLUG" >/dev/null 2>&1; echo $?)"

echo ""
echo "5. The harness's own files are never the plan's"
( cd "$WT" && mkdir -p scripts && printf 'scripts/lv-exec.sh\n' >> .gitignore && printf 'x\n' > scripts/lv-exec.sh \
  && printf 'x\n' > scripts/build.sh && git add .gitignore scripts/build.sh && git commit -qm "build script" )
printf '%s\n' '- **Files:** create `scripts/build.sh`.' >> "plans/$P-$SLUG/plan.md"
out=$("$S/lv-ignored-sources.sh" "$P" 2>&1); rc=$?
assert_eq "exit 0 beside an ignored scripts/lv-exec.sh" 0 "$rc"
assert_not "…which is not listed" "lv-exec.sh" "$out"

git worktree remove --force "$WT"
assert_eq "no worktree is exit 3" 3 "$("$S/lv-ignored-sources.sh" "$P" >/dev/null 2>&1; echo $?)"
assert_eq "not a plan ID is exit 2" 2 "$("$S/lv-ignored-sources.sh" nonsense >/dev/null 2>&1; echo $?)"

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
