#!/usr/bin/env bash
# skill-help.sh — the help structure from the skill audit (LVI-012): every skill
# answers help/--help from a ## Usage block in its own file, every moved name is
# an alias that says where it went, and lv-skills.sh indexes all of them.
#
# Usage: ./tests/skill-help.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SKILLS="$REPO_ROOT/skills"
GEN="$REPO_ROOT/scripts/v2.00/lv-skills.sh"
PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }

is_alias() { grep -qE '^description: "?Alias:' "$1"; }

echo "skill-help.sh"
echo "================"

echo
echo "1. Every skill carries its own usage"
no_usage="" no_line=""
for f in "$SKILLS"/*/SKILL.md; do
  n=$(basename "$(dirname "$f")")
  is_alias "$f" && continue
  grep -q '^## Usage[[:space:]]*$' "$f" || no_usage="$no_usage $n"
  grep -q '^\*\*`help` / `--help`:\*\*' "$f" || no_line="$no_line $n"
done
assert_eq "every skill has a ## Usage block"          "" "$no_usage"
assert_eq "every skill answers help / --help"         "" "$no_line"
assert_eq "the generator's --check agrees"            "0" \
  "$(bash "$GEN" --dir "$SKILLS" --check >/dev/null 2>&1; echo $?)"

echo
echo "2. Moved names keep working"
for old in lv-stage-stop lv-status lv-info lv-debug; do
  f="$SKILLS/$old/SKILL.md"
  if [ ! -f "$f" ]; then bad "$old still exists" "no $f"; continue; fi
  if is_alias "$f"; then ok "$old is an alias"; else bad "$old is an alias" "description does not start Alias:"; fi
  grep -qE 'now /lv-' "$f" && ok "$old names where it went" || bad "$old names where it went"
done

assert_eq "an alias description is quoted (a bare 'Alias:' is invalid YAML)" "" \
  "$(grep -l '^description: Alias:' "$SKILLS"/*/SKILL.md 2>/dev/null)"

echo
echo "3. The index"
out=$(bash "$GEN" --dir "$SKILLS")
missing=""
for f in "$SKILLS"/*/SKILL.md; do
  n=$(basename "$(dirname "$f")")
  printf '%s\n' "$out" | grep -q "/$n " || missing="$missing $n"
done
assert_eq "lists every skill and alias"               "" "$missing"
assert_eq "aliases sit under Moved, not Skills"       "lv-stage-stop" \
  "$(printf '%s\n' "$out" | sed -n '/^Moved/,$p' | grep -o 'lv-stage-stop' | head -1)"
assert_eq "--full prints usage blocks"                "true" \
  "$(full=$(bash "$GEN" --dir "$SKILLS" --full); printf '%s\n' "$full" | grep -q '^── /lv-stage ──' && echo true || echo false)"

mkdir -p "$TEST_DIR/s/lv-x" "$TEST_DIR/s/lv-y"
printf -- '---\nname: lv-x\ndescription: Does x. More.\n---\n\n## Usage\n\n```text\n/lv-x go\n```\n' > "$TEST_DIR/s/lv-x/SKILL.md"
printf -- '---\nname: lv-y\ndescription: Does y.\n---\n\nno usage\n' > "$TEST_DIR/s/lv-y/SKILL.md"
assert_eq "--check fails on a skill with no usage"   "1" \
  "$(bash "$GEN" --dir "$TEST_DIR/s" --check >/dev/null 2>&1; echo $?)"
assert_eq "--check names it"                          "true" \
  "$(chk=$(bash "$GEN" --dir "$TEST_DIR/s" --check 2>&1); printf '%s\n' "$chk" | grep -q 'lv-y' && echo true || echo false)"
assert_eq "one sentence per line"                     "  /lv-x             Does x." \
  "$(bash "$GEN" --dir "$TEST_DIR/s" | grep '/lv-x')"
assert_eq "a missing directory is an error"           "1" \
  "$(bash "$GEN" --dir "$TEST_DIR/nope" >/dev/null 2>&1; echo $?)"

echo
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
