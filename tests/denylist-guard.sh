#!/usr/bin/env bash
# tests/denylist-guard.sh — check-denylist.sh keeps listed names out of the tree,
# out of what a push would publish and out of the object store, never prints the
# list itself, and takes the list from the publish-denylist hook (a pack), so the
# library never holds it (LVI-017).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0 fail=0
ok()   { echo "  ✓ $1"; pass=$((pass+1)); }
bad()  { echo "  ✗ $1"; fail=$((fail+1)); }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected $2, got $3)"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T" && git init -q -b main && git config user.email t@example.com && git config user.name t
cp "$HERE/check-denylist.sh" . && mkdir -p scripts/v2.00
cp -R "$HERE/scripts/v2.00/lv-hook.sh" "$HERE/scripts/v2.00/hooks.default" scripts/v2.00/
git add -A && git commit -qm "init" && base=$(git rev-parse HEAD)
G=./check-denylist.sh
export LV_PACKS=""                       # no pack: the neutral default adds nothing

$G >/dev/null 2>&1;                      check "no list: passes"                    0 $?
$G --require-list >/dev/null 2>&1;       check "no list + --require-list: refuses"  2 $?

# The list comes from a pack's publish-denylist hook.
P="$T.pack"; mkdir -p "$P/hooks"; trap 'rm -rf "$T" "$P"' EXIT
printf '#!/bin/sh\nprintf "# comment\\nzebra-corp\\n"\n' > "$P/hooks/publish-denylist"; chmod +x "$P/hooks/publish-denylist"
echo "made for Zebra-Corp" > h.txt && git add h.txt
LV_PACKS="$P" $G --require-list >/dev/null 2>&1; check "a pack's list is used"              1 $?
git rm -q --cached h.txt && rm h.txt
LV_PACKS="$P" $G --require-list >/dev/null 2>&1; check "clean tree passes (pack list)"      0 $?
LV_PACKS="$T.gone" $G >/dev/null 2>&1;   check "a listed pack that is missing refuses" 2 $?
case "$(git ls-files)" in *zebra*|*Zebra*) bad "the library side holds no term" ;; *) ok "the library side holds no term" ;; esac

export LV_DENYLIST="$T.list"             # a file instead, for the cases below
printf '# comment\nzebra-corp\n' > "$LV_DENYLIST"
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

# A match early in a commit bigger than a pipe buffer: the matcher used to stop
# at the first hit, the writers upstream died of SIGPIPE, and pipefail turned
# the match into a pass.
git reset -q --hard "$base"
# Removed again by the next commit, so the tree scan is clean and only the
# per-commit scan can catch it.
{ echo "for zebra-corp"; seq 1 200000; } > big.txt && git add big.txt && git commit -qm "big"
git rm -q big.txt && git commit -qm "drop it" && tip=$(git rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | $G --pre-push >/dev/null 2>&1
check "a listed name early in a large commit fails" 1 $?
git reset -q --hard "$base" && git commit -q --allow-empty -m "clean" && git commit -q --allow-empty -m "for zebra-corp" && tip=$(git rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | $G --pre-push >/dev/null 2>&1
check "a listed name in any commit of the range fails" 1 $?

git reset -q --hard "$base" && echo "x" > c.txt && git add c.txt && git commit -qm "clean" && tip=$(git rev-parse HEAD)
printf 'refs/heads/main %s refs/heads/main %s\n' "$tip" "$base" | $G --pre-push >/dev/null 2>&1
check "a clean push passes" 0 $?

# --all-objects: a commit reset away is unreachable, still in the store, and
# would travel with a push from this clone.
git reset -q --hard "$base" && echo "y" > d.txt && git add d.txt && git commit -qm "for zebra-corp"
git reset -q --hard "$base"
$G >/dev/null 2>&1;                      check "tree scan misses an unreachable object" 0 $?
out=$($G --all-objects 2>&1); rc=$?
check "--all-objects finds it"          1 $rc
case "$out" in *" commit"*) ok "reports object id and type" ;; *) bad "reports object id and type" ;; esac
git reflog expire --expire=now --all && git gc -q --prune=now
$G --all-objects >/dev/null 2>&1;        check "--all-objects passes once it is gone" 0 $?
rm -f "$LV_DENYLIST"
unset LV_DENYLIST

# --text / --outbound (LVI-019): what a USER runs before an issue or a PR goes
# public. No pack, no list file: the names are derived from this machine.
R="$T.reg"; mkdir -p "$R/acme-billing" "$R/app"; trap 'rm -rf "$T" "$P" "$R"' EXIT
printf 'project_slug: "zeta-shop"\n' > "$R/acme-billing/levain.yml"
printf '%s\n%s\n' "$R/acme-billing" "$R/app" > "$R/list"
export LV_DEPLOYMENTS="$R/list"
body="$T.body"
printf 'lv-stage probes the wrong port\n' > "$body"
$G --outbound --text "$body" >/dev/null 2>&1;   check "--outbound: a clean issue passes"            0 $?
$G --text "$body" >/dev/null 2>&1;              check "--text with no list: passes"                 0 $?
printf 'ok\nseen in acme-billing today\n' > "$body"
out=$($G --outbound --text "$body" 2>&1); rc=$?
check "--outbound: a registered project's folder name fails" 1 $rc
case "$out" in *"line 2"*) ok "reports the line" ;; *) bad "reports the line ($out)" ;; esac
case "$out" in *acme*) bad "never prints the matched text" ;; *) ok "never prints the matched text" ;; esac
printf 'the zeta-shop compose file\n' | $G --outbound --text - >/dev/null 2>&1
check "--outbound: its project_slug fails, from stdin"         1 $?
printf 'log at %s/dev/x.log\n' "$HOME" | $G --outbound --text - >/dev/null 2>&1
check "--outbound: \$HOME fails"                               1 $?
printf 'git apply failed\n' | $G --outbound --text - >/dev/null 2>&1
check "--outbound: a short project name (app) is not denied"   0 $?
me=$(id -un)
printf 'from %s\n' "$me" | $G --outbound --text - >/dev/null 2>&1; rc=$?
check "--outbound: the login name fails"                       "$([ "${#me}" -ge 3 ] && echo 1 || echo 0)" "$rc"
printf 'x\n' | LV_PACKS="$P" $G --outbound --text - >/dev/null 2>&1
check "--outbound with a pack: still passes clean text"        0 $?
printf 'for zebra-corp\n' | LV_PACKS="$P" $G --outbound --text - >/dev/null 2>&1
check "--outbound with a pack: the pack's names apply too"     1 $?
$G --text "$T.nope" >/dev/null 2>&1;            check "--text on a missing file: usage (2)"         2 $?
unset LV_DEPLOYMENTS

# githooks/commit-msg (LVI-016): the same check at commit time, so a name is
# caught by the session that wrote it rather than by a push hours later.
H="$HERE/githooks/commit-msg"
git reset -q --hard "$base" && mkdir -p githooks && cp "$H" githooks/
export LV_DENYLIST="$T.list"; printf 'zebra-corp\n' > "$LV_DENYLIST"
m="$T.msg"
printf 'fix: a clean message\n# zebra-corp in git'"'"'s template is not the message\n' > "$m"
githooks/commit-msg "$m" >/dev/null 2>&1;       check "commit-msg: clean message passes (comments ignored)" 0 $?
printf 'fix: ported from zebra-corp\n' > "$m"
out=$(githooks/commit-msg "$m" 2>&1); rc=$?
check "commit-msg: a listed name in the message refuses" 1 $rc
case "$out" in *ebra*) bad "commit-msg: never prints the matched text" ;; *) ok "commit-msg: never prints the matched text" ;; esac
printf 'fix: clean\n' > "$m"
echo "zebra-corp" > e.txt && git add e.txt
out=$(githooks/commit-msg "$m" 2>&1); rc=$?
check "commit-msg: a listed name in a staged added line refuses" 1 $rc
case "$out" in *e.txt*) ok "commit-msg: names the file" ;; *) bad "commit-msg: names the file ($out)" ;; esac
git rm -q --cached e.txt && rm e.txt
echo "fine" > e.txt && git add e.txt
githooks/commit-msg "$m" >/dev/null 2>&1;       check "commit-msg: clean staged lines pass" 0 $?
git rm -q --cached e.txt && rm e.txt
unset LV_DENYLIST
githooks/commit-msg "$m" >/dev/null 2>&1;       check "commit-msg: no list passes (a user with no pack)" 0 $?
LV_PACKS="$T.gone" githooks/commit-msg "$m" >/dev/null 2>&1
check "commit-msg: a listed pack that is missing refuses" 1 $?
rm -rf githooks

# githooks/pre-commit + commit-msg together (LVI-040): a refused commit's bump
# is left staged, and the retry must land on the same version, not the next.
git reset -q --hard "$base" && mkdir -p githooks && cp "$HERE/githooks/pre-commit" "$H" githooks/
echo "1.4.2" > VERSION && git add VERSION && git commit -qm "version" --no-verify
git config core.hooksPath githooks
export LV_DENYLIST="$T.list"; printf 'zebra-corp\n' > "$LV_DENYLIST"
echo "work" > w.txt && git add w.txt
LV_BUMP=minor git commit -qm "feat: for zebra-corp" >/dev/null 2>&1; check "pre-commit+commit-msg: a listed name refuses the commit" 1 $?
LV_BUMP=minor git commit -qm "feat: for a client" >/dev/null 2>&1;    check "pre-commit+commit-msg: the reworded retry commits"      0 $?
check "pre-commit+commit-msg: the retry is 1.5.0, not 1.6.0" "1.5.0" "$(git show HEAD:VERSION)"
echo "more" >> w.txt && git add w.txt && git commit -qm "fix: more" >/dev/null 2>&1
check "pre-commit: the next commit counts from HEAD (1.5.1)" "1.5.1" "$(git show HEAD:VERSION)"
git config --unset core.hooksPath; unset LV_DENYLIST
rm -rf githooks

echo "  $pass passed, $fail failed"
[ "$fail" = 0 ]
