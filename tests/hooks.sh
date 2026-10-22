#!/usr/bin/env bash
# hooks.sh — the extension-hook dispatcher, lv-hook.sh (LVI-013), tested.
#
#   1. Every default declares a kind, and --list / --which report the layers.
#   2. decide: the first layer wins — project-local, then packs in order, then
#      the default — with args, stdin and exit code passed through.
#   3. observe: every layer runs, a failure never reaches the caller.
#   4. add-deny: the union of every layer; a missing pack, a failing or a
#      non-executable layer refuses (exit 3).
#   5. Where packs come from: levain.yml `packs:`, $LV_PACKS, and
#      ~/.config/levain/packs only when LV_PACKS is unset.
#   6. project-registry: deploy-all/sweep-issues/check-profiles read it, and
#      LV_DEPLOYMENTS (the test seam) wins over a pack.
#   7. install.sh ships lv-hook.sh and hooks.default/ in the build, for a
#      pipeline client and a coordinator; the overseer skills go only to a
#      coordinator (LVI-014).
#   8. overseer-vision finds the owner's vision skill; the spec's template is
#      complete.
#   9. The /lv-vision bootstrap, end to end on a scratch coordinator: fill the
#      template with sample answers, write it where step 3 says, and the result
#      is a skill — no placeholder left, frontmatter that parses, found by the
#      default hook, and the spec it tells Claude to read is installed
#      (LVI-020: this path shipped at 14.8.2 without ever having run).
#  10. dev-port: lv-plan-port.sh takes a pack's port, falls back to 8100 + N
#      only on exit 3, and fails on a refusal or a non-port answer.
#
# Usage: ./tests/hooks.sh        Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
HOOK="$SCRIPTS/lv-hook.sh"
PASS=0
FAIL=0
TEST_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
section() { echo "── $1 ──"; }

PROJ="$TEST_DIR/proj"
mkdir -p "$PROJ"; git -C "$PROJ" init -q
printf 'project_slug: fixture\n' > "$PROJ/levain.yml"
export CLAUDE_PROJECT_DIR="$PROJ"
export LV_PACKS=""
export HOME="$TEST_DIR/home"; mkdir -p "$HOME"

# mkhook <dir> <hook> <body> — an executable hook script
mkhook() { mkdir -p "$1"; printf '#!/usr/bin/env bash\n%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }
A="$TEST_DIR/packA"; B="$TEST_DIR/packB"; LOCAL="$PROJ/.lv-local/hooks"

section "1. defaults and introspection"
for f in "$SCRIPTS/hooks.default/"*; do
  h=$(basename "$f")
  k=$(sed -n 's/^# kind:[ \t]*\([a-z-]*\).*/\1/p' "$f" | head -1)
  case "$k" in decide|observe|add-deny) ok "$h declares kind $k" ;; *) bad "$h declares a kind" "got '$k'" ;; esac
  [ -x "$f" ] || bad "$h is executable"
done
out=$("$HOOK" --list </dev/null)
case "$out" in *"secrets-deny-patterns"*add-deny*default*) ok "--list names each hook, its kind and who answers" ;; *) bad "--list" "$out" ;; esac
"$HOOK" nosuch </dev/null >/dev/null 2>&1; assert_eq "an unknown hook exits 64" "$?" "64"
"$HOOK" ../x </dev/null >/dev/null 2>&1; assert_eq "a path is not a hook name" "$?" "64"
out=$("$HOOK" --help </dev/null); case "$out" in *"project-local"*) ok "--help prints the contract" ;; *) bad "--help" ;; esac

section "2. decide — the first layer wins"
out=$(LV_PACKS= "$HOOK" secrets-deploy k1 app:X </dev/null 2>&1); rc=$?
assert_eq "the default refuses when nothing implements it" "$rc" "3"
case "$out" in *"no secrets tool"*) ok "and says where one comes from" ;; *) bad "and says why" "$out" ;; esac
mkhook "$B/hooks" secrets-deploy 'echo "B $*"; exit 5'
mkhook "$A/hooks" secrets-deploy 'echo "A $*"; read -r x; echo "stdin=$x"'
out=$(printf 'hello\n' | LV_PACKS="$B:$A" "$HOOK" secrets-deploy k1 app:X); rc=$?
assert_eq "the first pack listed wins, with its exit code" "$out|$rc" "B k1 app:X|5"
out=$(printf 'hello\n' | LV_PACKS="$A:$B" "$HOOK" secrets-deploy k1 app:X); rc=$?
assert_eq "args and stdin reach the hook" "$(printf '%s' "$out" | tr '\n' ' ')|$rc" "A k1 app:X stdin=hello|0"
mkhook "$LOCAL" secrets-deploy 'echo local'
assert_eq "project-local beats every pack" "$(LV_PACKS="$A:$B" "$HOOK" secrets-deploy </dev/null)" "local"
out=$(LV_PACKS="$A:$B" "$HOOK" --which secrets-deploy | cut -f1 | tr '\n' ' ')
assert_eq "--which lists the layers in order" "$out" "local pack pack default "
rm -rf "$PROJ/.lv-local"
out=$(LV_PACKS="$TEST_DIR/gone:$A" "$HOOK" secrets-deploy z </dev/null 2>/dev/null | head -1)
assert_eq "a missing pack is skipped for decide" "$out" "A z"

section "3. observe — every layer, never a failure"
mkhook "$A/hooks" activity-log 'echo "A $*" >> "'"$TEST_DIR"'/obs"'
mkhook "$B/hooks" activity-log 'echo "B $*" >> "'"$TEST_DIR"'/obs"; exit 9'
LV_PACKS="$B:$A" "$HOOK" activity-log "did a thing" </dev/null 2>"$TEST_DIR/err"; rc=$?
assert_eq "observe exits 0 even when a layer fails" "$rc" "0"
assert_eq "every layer ran, in order" "$(tr '\n' ' ' < "$TEST_DIR/obs")" "B did a thing A did a thing "
grep -q "exited 9 — ignored" "$TEST_DIR/err" && ok "the failure is reported on stderr" || bad "failure reported" "$(cat "$TEST_DIR/err")"

section "4. add-deny — a union that fails closed"
mkhook "$A/hooks" provider-deny 'printf "command\tr-a\tx\twhy\n"'
mkhook "$B/hooks" provider-deny 'printf "command\tr-b\ty\twhy\n"'
mkhook "$LOCAL" provider-deny 'printf "path\t~/local-secrets\n"'
out=$(LV_PACKS="$A:$B" "$HOOK" provider-deny | cut -f2 | tr '\n' ' ')
assert_eq "every layer's rules, local first" "$out" "~/local-secrets r-a r-b "
rm -rf "$PROJ/.lv-local"
LV_PACKS="$A:$TEST_DIR/gone" "$HOOK" provider-deny >/dev/null 2>&1; assert_eq "a missing pack exits 3" "$?" "3"
mkhook "$B/hooks" provider-deny 'exit 1'
LV_PACKS="$A:$B" "$HOOK" provider-deny >/dev/null 2>&1; assert_eq "a failing layer exits 3" "$?" "3"
chmod -x "$B/hooks/provider-deny"
LV_PACKS="$A:$B" "$HOOK" provider-deny >/dev/null 2>&1; assert_eq "a non-executable layer exits 3" "$?" "3"
rm -f "$B/hooks/provider-deny"
assert_eq "a pack that does not implement it adds nothing" "$(LV_PACKS="$B" "$HOOK" provider-deny)" ""

section "5. where packs come from"
mkhook "$A/hooks" project-registry 'echo from-A'
mkhook "$B/hooks" project-registry 'echo from-B'
mkdir -p "$HOME/.config/levain"; printf '# mine\n%s\n' "$B" > "$HOME/.config/levain/packs"
assert_eq "~/.config/levain/packs when LV_PACKS is unset" "$(env -u LV_PACKS "$HOOK" project-registry </dev/null)" "from-B"
assert_eq "LV_PACKS, set, replaces it" "$(LV_PACKS="$A" "$HOOK" project-registry </dev/null)" "from-A"
assert_eq "LV_PACKS empty means no user pack" "$(LV_PACKS= LV_DEPLOYMENTS=/nonexistent "$HOOK" project-registry </dev/null)" ""
printf 'project_slug: fixture\npacks:\n  - "%s"\nother: 1\n' "$A" > "$PROJ/levain.yml"
assert_eq "the project's packs: list comes before the user's" "$(env -u LV_PACKS "$HOOK" project-registry </dev/null)" "from-A"
printf 'project_slug: fixture\n' > "$PROJ/levain.yml"
printf '%s\n' "~/tilde-pack" > "$HOME/.config/levain/packs"; mkhook "$HOME/tilde-pack/hooks" project-registry 'echo tilde'
assert_eq "a ~/ pack path is expanded" "$(env -u LV_PACKS "$HOOK" project-registry </dev/null)" "tilde"
rm -f "$HOME/.config/levain/packs"

section "6. project-registry and its readers"
LIBC="$TEST_DIR/lib"; mkdir -p "$LIBC"
printf '# comment\n/x/one\n\n  /x/two  \n' > "$LIBC/deployments.txt"
out=$(LV_PACKS= LV_LIBRARY="$LIBC" "$HOOK" project-registry </dev/null | tr '\n' ' ')
assert_eq "the default reads the library's deployments.txt" "$out" "/x/one /x/two "
C1="$TEST_DIR/c1"; mkdir -p "$C1" "$TEST_DIR/c2"
mkhook "$A/hooks" project-registry "echo $C1"
mkhook "$TEST_DIR/packR/hooks" project-registry "printf '%s\n' $C1 $TEST_DIR/c2"
out=$(cd "$REPO_ROOT" && LV_PACKS="$TEST_DIR/packR" bash sweep-issues.sh 2>&1)
case "$out" in *"across 2 client"*) ok "sweep-issues walks the pack's registry" ;; *) bad "sweep-issues walks the pack's registry" "$out" ;; esac
printf '%s\n' "$TEST_DIR/seam-client" > "$TEST_DIR/seam.txt"; mkdir -p "$TEST_DIR/seam-client"
out=$(cd "$REPO_ROOT" && LV_PACKS="$TEST_DIR/packR" LV_DEPLOYMENTS="$TEST_DIR/seam.txt" bash sweep-issues.sh 2>&1)
case "$out" in *"across 1 client"*) ok "LV_DEPLOYMENTS wins over a pack" ;; *) bad "LV_DEPLOYMENTS wins over a pack" "$out" ;; esac
mkhook "$B/hooks" project-registry 'exit 1'
out=$(cd "$REPO_ROOT" && LV_PACKS="$B" bash check-profiles.sh 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "a failing registry stops check-profiles" || bad "a failing registry stops check-profiles" "$out"
out=$(cd "$REPO_ROOT" && LV_PACKS="$B" bash deploy-all.sh 2>&1); rc=$?
case "$rc|$out" in 1*"deploying nowhere"*) ok "and stops deploy-all before it touches anything" ;; *) bad "deploy-all on a failing registry" "rc=$rc $out" ;; esac

# --upstream lists what strangers sent, without a registry (LVI-019). gh is a
# stub that answers from files, so no network and no real repository.
GHB="$TEST_DIR/ghbin"; mkdir -p "$GHB"
cat > "$GHB/gh" <<'GH'
#!/usr/bin/env bash
echo "$*" >> "$GH_LOG"
case "$1" in issue) cat "$GH_ISSUES" ;; pr) cat "$GH_PRS" ;; esac
GH
chmod +x "$GHB/gh"
export GH_LOG="$TEST_DIR/gh.log" GH_ISSUES="$TEST_DIR/gh.issues" GH_PRS="$TEST_DIR/gh.prs"
: > "$GH_ISSUES"; : > "$GH_PRS"
out=$(cd "$REPO_ROOT" && PATH="$GHB:$PATH" LV_PACKS="$B" bash sweep-issues.sh --upstream 2>&1); rc=$?
assert_eq "--upstream, nothing open: exit 1, even with a failing registry" "$rc" "1"
echo '  #7  lv-stage probes the wrong port  — someone, updated 2026-09-24' > "$GH_ISSUES"
echo '  #9  fix the probe  — someone, updated 2026-09-24' > "$GH_PRS"
out=$(cd "$REPO_ROOT" && PATH="$GHB:$PATH" LV_UPSTREAM_REPO=o/r bash sweep-issues.sh --upstream 2>&1); rc=$?
assert_eq "--upstream, work open: exit 0" "$rc" "0"
case "$out" in *"#7"*"#9"*"2 open on o/r"*"upstream-intake.md"*) ok "--upstream lists both, and names the intake routine" ;; *) bad "--upstream output" "$out" ;; esac
grep -q -- "-R o/r --state open" "$GH_LOG" && ok "--upstream asks the repo LV_UPSTREAM_REPO names" || bad "--upstream repo" "$(cat "$GH_LOG")"

section "7. install ships the dispatcher"
for role in pipeline coordinator; do
  C="$TEST_DIR/inst-$role"; mkdir -p "$C"; git -C "$C" init -q
  if [ "$role" = coordinator ]; then printf 'project_slug: coord\nrole: coordinator\n' > "$C/levain.yml"
  else printf 'project_slug: pipe\n' > "$C/levain.yml"; fi
  (cd "$REPO_ROOT" && LV_PACKS= bash install.sh "$C" >"$TEST_DIR/install-$role.log" 2>&1) || true
  b=$(tr -d '[:space:]' < "$C/scripts/current" 2>/dev/null)
  if [ -x "$C/scripts/gen/$b/v2.00/hooks.default/secrets-deny-patterns" ] && [ -x "$C/scripts/gen/$b/v2.00/lv-hook.sh" ]; then
    ok "$role: lv-hook.sh and hooks.default/ are in the build"
  else
    bad "$role: lv-hook.sh and hooks.default/ are in the build" "$(tail -5 "$TEST_DIR/install-$role.log")"
  fi
  out=$(cd "$C" && CLAUDE_PROJECT_DIR="$C" LV_PACKS="$A" scripts/lv-exec.sh lv-hook.sh project-registry </dev/null 2>&1)
  assert_eq "$role: lv-exec.sh reaches a pack through it" "$out" "$C1"
done
# LVI-031: a worker that cd's out of the project runs its hooks from there.
# The session's project is the fallback, never the first choice.
E="$TEST_DIR/elsewhere"; mkdir -p "$E"
out=$(cd "$E" && CLAUDE_PROJECT_DIR="$TEST_DIR/inst-pipeline" LV_PACKS="$A" "$TEST_DIR/inst-pipeline/scripts/lv-exec.sh" lv-hook.sh project-registry </dev/null 2>&1)
assert_eq "lv-exec.sh outside any project falls back to CLAUDE_PROJECT_DIR" "$out" "$C1"
out=$(cd "$E" && env -u CLAUDE_PROJECT_DIR "$TEST_DIR/inst-pipeline/scripts/lv-exec.sh" lv-hook.sh project-registry </dev/null 2>&1); rc=$?
assert_eq "and without it still says it cannot locate a project" "1" "$rc"
P="$TEST_DIR/inst-pipeline"; K="$TEST_DIR/inst-coordinator"
[ ! -d "$P/.claude/skills/lv-rack" ] && [ ! -d "$P/.claude/skills/lv-vision" ] \
  && ok "pipeline: no overseer skills (/lv-rack, /lv-vision)" || bad "pipeline: no overseer skills"
[ -f "$K/.claude/skills/lv-vision/SKILL.md" ] && [ -f "$K/.claude/skills/lv-rack/SKILL.md" ] \
  && ok "coordinator: /lv-rack and /lv-vision" || bad "coordinator: /lv-rack and /lv-vision" "$(ls "$K/.claude/skills")"
[ -f "$K/.claude/docs/vision-spec.md" ] && [ -f "$K/.claude/docs/extension-hooks.md" ] \
  && ok "coordinator: the vision spec and the hooks doc they cite" || bad "coordinator: cited docs" "$(ls "$K/.claude/docs" 2>&1)"
mkdir -p "$P/.claude/skills/lv-vision"; (cd "$REPO_ROOT" && LV_PACKS= bash install.sh "$P" >/dev/null 2>&1)
[ ! -d "$P/.claude/skills/lv-vision" ] && ok "a stale overseer skill in a pipeline client is removed" || bad "a stale overseer skill in a pipeline client is removed"

section "8. overseer-vision"
out=$(cd "$K" && CLAUDE_PROJECT_DIR="$K" LV_PACKS= scripts/lv-exec.sh lv-hook.sh overseer-vision </dev/null 2>/dev/null); rc=$?
assert_eq "no vision skill: exit 3" "$rc" "3"
mkdir -p "$K/.claude/skills/vision"; echo x > "$K/.claude/skills/vision/SKILL.md"
out=$(cd "$K" && CLAUDE_PROJECT_DIR="$K" LV_PACKS= scripts/lv-exec.sh lv-hook.sh overseer-vision </dev/null)
assert_eq "the default finds .claude/skills/vision/SKILL.md" "$out" "$K/.claude/skills/vision/SKILL.md"
mkhook "$A/hooks" overseer-vision 'echo /elsewhere/vision/SKILL.md'
out=$(cd "$K" && CLAUDE_PROJECT_DIR="$K" LV_PACKS="$A" scripts/lv-exec.sh lv-hook.sh overseer-vision </dev/null)
assert_eq "a pack's skill wins" "$out" "/elsewhere/vision/SKILL.md"
(cd "$REPO_ROOT" && LV_PACKS= bash install.sh "$K" >/dev/null 2>&1)
[ -f "$K/.claude/skills/vision/SKILL.md" ] && ok "a redeploy leaves the owner's vision skill alone" || bad "a redeploy leaves the owner's vision skill alone"
spec="$REPO_ROOT/docs/vision-spec.md"
tpl=$(sed -n '/vision-template:begin/,/vision-template:end/p' "$spec")
case "$tpl" in *"name: vision"*"{{FAMILY}}"*) ok "the spec carries a fillable skill template" ;; *) bad "the spec carries a fillable skill template" ;; esac
for ph in $(printf '%s' "$tpl" | grep -oE '\{\{[A-Z_]+\}\}' | sort -u); do
  grep -q "^| \`$ph\`" "$spec" || bad "template placeholder $ph is defined in the spec's table"
done
ok "every template placeholder is defined in the spec's table"

section "9. the /lv-vision bootstrap"
# The interview is Claude's and is not under test; its product is. The sample
# answers are the spec's own Example column, so a placeholder added to the
# table without an example fails here rather than in an owner's interview.
fill_template() {   # fill_template <spec> <out> [<PLACEHOLDER=value> ...] — overrides win
  python3 - "$@" <<'FILL'
import re, sys
spec, out, overrides = sys.argv[1], sys.argv[2], dict(a.split("=", 1) for a in sys.argv[3:])
text = open(spec).read()
answers = {}
for m in re.finditer(r"^\| `\{\{([A-Z_]+)\}\}` \|[^|]*\| (.*?) \|$", text, re.M):
    answers[m.group(1)] = m.group(2).strip().strip('"').replace("`", "")
answers.update(overrides)
tpl = re.search(r"<!-- vision-template:begin -->\n(.*?)<!-- vision-template:end -->", text, re.S).group(1)
open(out, "w").write(re.sub(r"\{\{([A-Z_]+)\}\}", lambda m: answers.get(m.group(1), m.group(0)), tpl))
FILL
}
frontmatter() {     # frontmatter <SKILL.md> — the parsed name, or exit 1
  python3 - "$1" <<'FM'
import sys, yaml
t = open(sys.argv[1]).read()
if not t.startswith("---\n"): sys.exit(1)
d = yaml.safe_load(t.split("---\n", 2)[1])
if not isinstance(d, dict) or not isinstance(d.get("description"), str) or not d["description"]: sys.exit(1)
print(d.get("name", ""))
FM
}
rm -rf "$A/hooks/overseer-vision" "$K/.claude/skills/vision"
V="$K/.claude/skills/vision/SKILL.md"; mkdir -p "$(dirname "$V")"
fill_template "$K/.claude/docs/vision-spec.md" "$V"
left=$(grep -oE '\{\{[A-Z_]+\}\}' "$V" | sort -u | tr '\n' ' ')
assert_eq "the filled skill has no placeholder left" "$left" ""
grep -q "the Acme family of apps" "$V" && ok "and carries the answers" || bad "and carries the answers" "$(head -5 "$V")"
assert_eq "its frontmatter parses, as name: vision" "$(frontmatter "$V")" "vision"
out=$(cd "$K" && CLAUDE_PROJECT_DIR="$K" LV_PACKS= scripts/lv-exec.sh lv-hook.sh overseer-vision </dev/null 2>&1)
assert_eq "the default hook (no pack) prints the generated skill" "$out" "$V"
cites=$(grep -oE '\.claude/docs/[a-z-]+\.md' "$V" | sort -u)
[ -n "$cites" ] || bad "the skill tells Claude which spec to read"
for d in $cites; do
  [ -f "$K/$d" ] && ok "$d, which the skill says to read, is installed" || bad "$d, which the skill says to read, is installed"
done
cp "$V" "$TEST_DIR/v.keep"
(cd "$REPO_ROOT" && LV_PACKS= bash install.sh "$K" >/dev/null 2>&1)
cmp -s "$V" "$TEST_DIR/v.keep" && [ -f "$K/.claude/docs/vision-spec.md" ] \
  && ok "a redeploy keeps the generated skill and the spec it reads" || bad "a redeploy keeps the generated skill and the spec it reads"
# The check above is only worth something if it can fail: an answer that is
# not valid in a plain YAML scalar is exactly what an interview produces.
fill_template "$K/.claude/docs/vision-spec.md" "$TEST_DIR/bad.md" "FAMILY=Acme: the apps"
frontmatter "$TEST_DIR/bad.md" >/dev/null 2>&1 && bad "an answer that breaks the frontmatter is caught" \
  || ok "an answer that breaks the frontmatter is caught"

section "10. dev-port"
D="$TEST_DIR/portpack"
plan_port() { (cd "$P" && CLAUDE_PROJECT_DIR="$P" LV_PACKS="$1" scripts/lv-exec.sh lv-plan-port.sh PLN-004-x </dev/null 2>/dev/null); }
assert_eq "no allocator: 8100 + N" "$(plan_port "" | sed -n 's/^export FEATURE_PORT=//p')" "8104"
mkhook "$D/hooks" dev-port 'echo "$1|$2|$3" > "$(dirname "$0")/args"; echo 42007'
assert_eq "a pack's port wins" "$(plan_port "$D" | sed -n 's/^export FEATURE_PORT=//p')" "42007"
assert_eq "and it is asked with the slug, the plan folder and the worktree" "$(cat "$D/hooks/args")" "pipe|PLN-004-x|$P"
assert_eq "PLAN_ID and the compose name are unchanged" "$(plan_port "$D" | grep -v FEATURE_PORT | tr '\n' ' ')" \
  "export PLAN_ID=4 export COMPOSE_PROJECT_NAME=pipe-pln004 "
mkhook "$D/hooks" dev-port 'exit 3'
assert_eq "a pack with no answer (exit 3) falls back to 8100 + N" "$(plan_port "$D" | sed -n 's/^export FEATURE_PORT=//p')" "8104"
mkhook "$D/hooks" dev-port 'echo "full" >&2; exit 4'
plan_port "$D" >/dev/null; assert_eq "a refusal fails lv-plan-port.sh, with no fallback" "$?" "1"
mkhook "$D/hooks" dev-port 'echo soon'
plan_port "$D" >/dev/null; assert_eq "an answer that is not a port fails it" "$?" "1"

echo ""
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
