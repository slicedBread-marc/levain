#!/usr/bin/env bash
# start.sh — the front door (LVI-015): README's quick start hands off to
# START.md, START.md to one prompt per rung under install/, and every command,
# skill and doc those prompts name exists in the tree they ship with. An
# install ends by pointing at the first brainstorm; a coordinator's lists its
# three skills. The README carries the home page's tagline, rung names and link (LVI-016).
# Working through recorded issues has its own prompt, which points upstream (LVI-018).
#
# Usage: ./tests/start.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1" "no [$3]"; fi; }

cd "$REPO_ROOT" || exit 1
PROMPTS="START.md install/*.md"
ALL="README.md $PROMPTS"

echo "start.sh"
echo "================"

echo
echo "1. The chain: README → START.md → install/"
has "README's quick start is the prompt" "$(cat README.md)" "read ~/levain/START.md and set me up"
has "README states the platform"          "$(cat README.md)" "built and tested on macOS"
# LVI-016: the README matches the home page — its tagline, the rung names, one link out.
has "README carries the tagline"            "$(cat README.md)" "From developer to CEO."
has "README names the ladder"               "$(cat README.md)" "manual → attended → overseer"
has "START.md names the same ladder"        "$(cat START.md)" "manual → attended → overseer"
has "README clones the public repository"  "$(cat README.md)" "git clone https://github.com/slicedBread-marc/levain.git ~/levain"
assert_eq "README links the home page once" "1" "$(grep -c 'https://slicedbread.ca/levain' README.md)"
# LVI-018: a user can work through their own workflow issues, and knows where upstream is.
has "README's issue section hands off to the prompt" "$(cat README.md)" "go through my workflow issues"
has "the issues prompt names the public repository" "$(cat install/issues.md)" "https://github.com/slicedBread-marc/levain"
has "the issues prompt fixes on local/fixes"         "$(cat install/issues.md)" "local/fixes"
has "and upgrades rebase it forward"                 "$(cat install/upgrade.md)" "local/fixes"
has "nothing goes upstream without a yes"            "$(cat install/issues.md)" "Nothing goes out without their yes"
# shellcheck disable=SC2086
assert_eq "rung 2 is 'attended', never 'the daemon'" "" "$(grep -liE 'rung 2(:|,)? the daemon|2\. daemon' $ALL)"
want="attended first-brainstorm issues overseer pack preflight project upgrade vision"
assert_eq "one prompt per step" "$want" "$(ls install | sed 's/\.md$//' | sort | tr '\n' ' ' | sed 's/ $//')"
# shellcheck disable=SC2086
missing=$(grep -ohE 'install/[a-z-]+\.md' $ALL | sort -u | while read -r f; do [ -f "$f" ] || echo "$f"; done)
assert_eq "every install/ prompt named exists" "" "$missing"
unlinked=$(for f in install/*.md; do grep -q "$(basename "$f")" START.md || echo "$f"; done)
assert_eq "START.md reaches every prompt" "" "$unlinked"
orphan=$(for f in install/*.md; do grep -q '\[START.md\](../START.md)' "$f" || echo "$f"; done)
assert_eq "every prompt points back at START.md" "" "$orphan"

echo
echo "2. Everything they name exists"
# shellcheck disable=SC2086
missing=$(grep -ohE '\blv-[a-z-]+\.sh\b' $ALL | sort -u | while read -r s; do
  [ -f "scripts/v2.00/$s" ] || [ -f "scripts/$s" ] || echo "$s"; done)
assert_eq "every lv-*.sh named is a script" "" "$missing"
# shellcheck disable=SC2086
missing=$(grep -ohE '(^|[^a-z0-9.-])/lv-[a-z-]+' $ALL | sed 's#.*/##' | sort -u | while read -r s; do
  [ -f "skills/$s/SKILL.md" ] || echo "/$s"; done)
assert_eq "every /lv-* named is a skill" "" "$missing"
# shellcheck disable=SC2086
missing=$(grep -ohE 'docs/[a-z-]+\.md' $ALL | sort -u | while read -r d; do [ -f "$d" ] || echo "$d"; done)
assert_eq "every docs/ page named exists" "" "$missing"
missing=$(grep -ohE 'hooks.default/[a-z-]+|lv-hook.sh [a-z-]+' $PROMPTS 2>/dev/null \
  | sed -E 's#.*[/ ]##' | grep -v '^<' | sort -u | while read -r h; do
  [ -f "scripts/v2.00/hooks.default/$h" ] || echo "$h"; done)
assert_eq "every hook named has a default" "" "$missing"
# shellcheck disable=SC2086
for f in $PROMPTS; do grep -qE '/Users/|~/dev/' "$f" && bad "$f names no personal path"; done
ok "no prompt names a personal path"

echo
echo "3. Where an install leaves you"
mk() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" commit -q --allow-empty -m init; }
mk "$T/app"
printf 'build_command: "true"\ntest_command: "true"\nproject_slug: "app"\nsource_dirs:\n  - "src/"\n' > "$T/app/levain.yml"
out=$(LV_PACKS="" LV_INSTALL_NO_COMMIT=1 bash install.sh "$T/app" </dev/null 2>&1)
has "a client install points at the first brainstorm" "$out" "/lv-brainstorm <what you want to build or fix>"
has "and at START.md for the rungs above"            "$out" "START.md"
mk "$T/coord"
printf 'role: "coordinator"\nproject_slug: "coord"\ncoordinates:\n  - "app:%s"\n' "$T/app" > "$T/coord/levain.yml"
out=$(LV_PACKS="" LV_INSTALL_NO_COMMIT=1 bash install.sh "$T/coord" </dev/null 2>&1)
for s in /lv-rack /lv-dep-notify /lv-vision; do has "a coordinator install lists $s" "$out" "$s"; done

echo
echo "4. The config's old name (claude-workflow.yml, before 14.7.0)"
mk "$T/old"
printf 'build_command: "true"\ntest_command: "true"\nproject_slug: "old"\n' > "$T/old/claude-workflow.yml"
git -C "$T/old" add -A && git -C "$T/old" commit -qm cfg
( cd "$T/old" && git switch -q -c develop )
LV_PACKS="" bash install.sh "$T/old" </dev/null >/dev/null 2>&1
assert_eq "install renames it to levain.yml" "levain.yml:no" \
  "$(cd "$T/old" && ls levain.yml):$([ -e "$T/old/claude-workflow.yml" ] && echo yes || echo no)"
assert_eq "and commits both sides of the rename" "" "$(git -C "$T/old" status --porcelain -- levain.yml claude-workflow.yml)"
assert_eq "the commit deletes the old name" "D" \
  "$(git -C "$T/old" show --name-status --format= HEAD -- claude-workflow.yml | cut -c1)"
mkdir -p "$T/untracked" && printf 'project_slug: "u"\n' > "$T/untracked/claude-workflow.yml"
LV_PACKS="" LV_INSTALL_NO_COMMIT=1 bash install.sh "$T/untracked" </dev/null >/dev/null 2>&1
assert_eq "an untracked one is moved" "yes" "$([ -f "$T/untracked/levain.yml" ] && echo yes || echo no)"
# A feature branch cut before the rename still has only the old file.
mk "$T/branch"; printf 'project_slug: "from-old-name"\n' > "$T/branch/claude-workflow.yml"
assert_eq "config reads fall back to the old name" "from-old-name" \
  "$(cd "$T/branch" && bash "$REPO_ROOT/scripts/v2.00/lv-config-get.sh" project_slug 2>/dev/null)"
assert_eq "so does the hook dispatcher's packs: list" "$T/branch-pack" \
  "$(printf 'packs:\n  - "%s"\n' "$T/branch-pack" >> "$T/branch/claude-workflow.yml"; mkdir -p "$T/branch-pack/hooks"; : > "$T/branch-pack/hooks/activity-log";
     CLAUDE_PROJECT_DIR="$T/branch" LV_PACKS="" bash scripts/v2.00/lv-hook.sh --which activity-log | awk -F'\t' '$1=="pack"{print $2}' | head -1 | sed 's#/hooks/.*##')"

echo
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
