#!/usr/bin/env bash
# brief-folds.sh — a Decided brief's `> **Folds:**` header withholds exactly
# the bugs it lists from /lv-spec (a client's LVI-011).
#
#   1. A bug on a Decided brief's Folds line is not offered, and stderr says
#      'folded into BRF-NNN'. The brief's row names what it folds.
#   2. A bug the brief names elsewhere (References, out of scope) is offered.
#   3. A brief that is not Decided or Planned folds nothing.
#   4. A Planned brief still withholds, and says how to consume.
#   5. The skills say how.
#
# Usage: ./tests/brief-folds.sh     Exit 0 if all pass, 1 on any failure.

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
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }
section() { echo "── $1 ──"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LV_UNATTENDED

P="$TEST_DIR/proj"
mkdir -p "$P/plans/briefs" "$P/scripts" "$P/bugs/open" "$P/.claude/orchestrator"
cd "$P" || exit 1
git init -q -b develop
printf 'project_slug: "proj"\n' > levain.yml
printf '.claude/orchestrator/\n' > .gitignore
printf '#!/usr/bin/env bash\nn="$1"; shift; exec "%s/$n" "$@"\n' "$S" > scripts/lv-exec.sh
chmod +x scripts/lv-exec.sh
cat > plans/REGISTRY.md <<'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|

<!-- Counter: 70 -->
SEED
bug() {
  mkdir -p "bugs/open/$1-$2"
  printf '# %s\n\n> **Status:** Open\n> **ID:** %s\n> **Severity:** Medium\n> **Plan:** _(none)_\n\n## Description\nx\n' \
    "$2" "$1" > "bugs/open/$1-$2/bug.md"
}
bug BUG-066 intro-skip
bug BUG-067 copy-tone
bug BUG-068 intro-scroll
# brief <status> [folds]
brief() {
  { printf '# Intro\n\n> **ID:** BRF-069\n> **Status:** %s\n> **Plan:** (none)\n' "$1"
    [ -n "${2:-}" ] && printf '> **Folds:** %s\n' "$2"
    printf '\n## Problem\nBUG-066 and BUG-068 chose a skip button.\n\n## References\nBUG-066, BUG-067 (out of scope), BUG-068\n'
  } > plans/briefs/BRF-069-intro.md
  printf '# Briefs\n\n## Decided\n- [Intro](BRF-069-intro.md) — intro, option D\n\n## Planned\n' > plans/briefs/INDEX.md
}
git add -A >/dev/null; git commit -qm seed

spec_out() { "$S/lv-list-specable.sh" 2>/dev/null; }
spec_err() { "$S/lv-list-specable.sh" 2>&1 >/dev/null; }
row() { spec_out | awk -F'\t' -v id="$1" '$1 == id'; }

section "1. a Folds line withholds exactly what it lists"
brief Decided "BUG-066, BUG-068"
assert_eq "BUG-066 is not offered" "$(row BUG-066)" ""
assert_eq "BUG-068 is not offered" "$(row BUG-068)" ""
has "and says why" "$(spec_err)" "BUG-068 not offered — folded into BRF-069"
has "the brief's row names what it folds" "$(row BRF-069)" "folds BUG-066,BUG-068"

section "2. a bug named elsewhere in the brief is separate work"
has "BUG-067, named out of scope, is offered" "$(row BUG-067)" "BUG-067"

section "3. no Folds line, or not Decided, folds nothing"
brief Decided
has "a Decided brief without the header folds nothing" "$(row BUG-066)" "BUG-066"
hasnt "and its row names no fold" "$(row BRF-069)" "folds"
brief Exploring "BUG-066, BUG-068"
has "an Exploring brief's Folds line withholds nothing" "$(row BUG-068)" "BUG-068"

section "4. a Planned brief still withholds"
brief Planned "BUG-066, BUG-068"
assert_eq "BUG-066 is not offered" "$(row BUG-066)" ""
has "and the way to consume it is named" "$(spec_err)" "lv-bug-consume.sh BUG-066 <its plan> --folded"

section "5. the skills say how"
grep -q '\*\*Folds:\*\*' "$LIB_ROOT/skills/lv-spec/SKILL.md" && ok "lv-spec consumes a brief's folded bugs" || bad "lv-spec consumes a brief's folded bugs"
grep -q '\*\*Folds:\*\*' "$LIB_ROOT/skills/lv-brainstorm/SKILL.md" && ok "lv-brainstorm writes the header" || bad "lv-brainstorm writes the header"
grep -q '\*\*Folds:\*\*' "$LIB_ROOT/templates/plans/briefs/TEMPLATE.md" && ok "the brief template documents it" || bad "the brief template documents it"

echo
echo "brief-folds: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
