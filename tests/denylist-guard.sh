#!/usr/bin/env bash
# tests/denylist-guard.sh — check-denylist.sh keeps listed names out of the tree
# and out of what a push would publish, and never prints the list itself.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T" && git init -q -b main && git config user.email t@example.com && git config user.name t
cp "$HERE/check-denylist.sh" . && printf '.denylist\n' > .gitignore
git add -A && git commit -qm "init" && base=$(git rev-parse HEAD)
G=./check-denylist.sh

$G >/dev/null 2>&1;                      check "no list: passes"                    0 $?
$G --require-list >/dev/null 2>&1;       check "no list + --require-list: refuses"  2 $?

printf '# comment\nzebra-corp\n' > .denylist
$G --require-list >/dev/null 2>&1;       check "clean tree passes"                  0 $?

echo "made for Zebra-Corp" > a.txt && git add a.txt
out=$($G 2>&1); rc=$?
check "listed name in a tracked file fails"   1 $rc
case "$out" in *a.txt:1*) ok "reports file:line" ;; *) bad "reports file:line" ;; esac
case "$out" in *ebra*) bad "never prints the matched text" ;; *) ok "never prints the matched text" ;; esac
git rm -q --cached a.txt && rm a.txt

echo "fine" > b.txt && git add b.txt && git commit -qm "work for zebra-corp" && tip=$(git rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | $G --pre-push >/dev/null 2>&1
check "listed name in a pushed commit message fails" 1 $?

git reset -q --hard "$base" && echo "x" > c.txt && git add c.txt && git commit -qm "clean" && tip=$(git rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | $G --pre-push >/dev/null 2>&1
check "a clean push passes" 0 $?

echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
