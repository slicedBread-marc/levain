#!/usr/bin/env bash
# rack.sh — the coordinator's board, lv-rack.sh (moved from a coordinator's
# bin/ into the library in LVI-014), tested.
#
# The board is a TUI; each tests/rack/*.test.sh sources it with LV_RACK_LIB=1
# and drives its functions directly. This runs them all, isolated from the
# owner's real packs and projects, then checks what is new with the move:
#
#   - the project list comes from the project-registry hook — a pack, the
#     library's deployments.txt via .claude/workflow-source, or the
#     coordinator's `coordinates:` list — and LV_DEPLOYMENTS still wins;
#   - the coordinator's state (suspend record, cache) lands in LV_COORD_DIR.
#
# Usage: ./tests/rack.sh        Exit 0 if all pass, 1 on any failure.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
RACK="$SCRIPTS/lv-rack.sh"
PASS=0 FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
export LV_PACKS=""
export LV_COORD_DIR="$T/coord"; mkdir -p "$LV_COORD_DIR"

echo "── the board's own suites ──"
for t in "$REPO_ROOT"/tests/rack/*.test.sh; do
  out=$(LV_TEST_SCRIPT_DIR="$SCRIPTS" bash "$t" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then ok "$(basename "$t")"; else bad "$(basename "$t")" "$(printf '%s' "$out" | grep -E 'FAIL|✗' | head -5)"; fi
done

echo "── where the projects come from ──"
# registry <env...> — the project list the board reads, one line per project
registry() {
  env "$@" LV_RACK_LIB=1 bash -c 'f=$1; set --; source "$f"; cat "$DEPLOYMENTS" 2>/dev/null' _ "$RACK" </dev/null
}
C="$LV_COORD_DIR"
git -C "$C" init -q
printf 'project_slug: coord\nrole: coordinator\ncoordinates:\n  - "alpha:/p/alpha"\n  - "beta:/p/beta"\n' > "$C/levain.yml"
assert_eq "no pack, no library: the coordinator's coordinates: list" "$(registry | tr '\n' ' ')" "/p/alpha /p/beta "
mkdir -p "$T/lib"; printf '/p/one\n# c\n/p/two\n' > "$T/lib/deployments.txt"
mkdir -p "$C/.claude"; printf '%s\n' "$T/lib" > "$C/.claude/workflow-source"
assert_eq "the library's deployments.txt, found through .claude/workflow-source" "$(registry | tr '\n' ' ')" "/p/one /p/two "
mkdir -p "$T/pack/hooks"; printf '#!/usr/bin/env bash\necho /p/from-pack\n' > "$T/pack/hooks/project-registry"; chmod +x "$T/pack/hooks/project-registry"
assert_eq "a pack answers first" "$(registry LV_PACKS="$T/pack" | tr '\n' ' ')" "/p/from-pack "
printf '/p/seam\n' > "$T/seam.txt"
assert_eq "LV_DEPLOYMENTS wins over all of them" "$(registry LV_PACKS="$T/pack" LV_DEPLOYMENTS="$T/seam.txt" | tr '\n' ' ')" "/p/seam "
[ -f "$C/.claude/orchestrator/board-cache/registry.txt" ] && ok "the list is cached in the coordinator's own state" || bad "the list is cached in the coordinator's own state"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T/pack/hooks/project-registry"
out=$(LV_PACKS="$T/pack" bash "$RACK" --plain </dev/null 2>&1)
case "$out" in *"project-registry hook failed"*) ok "a failing registry is said, not drawn as an empty portfolio" ;; *) bad "a failing registry is said" "$out" ;; esac

echo "── coordinators are never columns ──"
# A registry that names every install lists coordinators too, this one included.
mkdir -p "$T/other-coord" "$T/app"
printf 'role: "coordinator"\n' > "$T/other-coord/levain.yml"; printf 'project_slug: app\n' > "$T/app/levain.yml"
printf '%s\n' "$C" "$T/other-coord" "$T/app" > "$T/all.txt"
out=$(LV_DEPLOYMENTS="$T/all.txt" LV_RACK_LIB=1 bash -c 'f=$1; set --; source "$f"; each_project' _ "$RACK" </dev/null)
assert_eq "each_project skips every coordinator" "$out" "$T/app"
out=$(LV_DEPLOYMENTS="$T/all.txt" bash "$RACK" --plain </dev/null 2>&1)
case "$out" in *"board failed"*) bad "a coordinator is not drawn as a failed board" "$out" ;; *) ok "a coordinator is not drawn as a failed board" ;; esac

echo "── what it is not ──"
if grep -nE '~/dev|/Users/|\bops\b' "$RACK" >/dev/null; then bad "names no owner's paths or coordinator" "$(grep -nE '~/dev|/Users/|\bops\b' "$RACK" | head -3)"
else ok "names no owner's paths or coordinator"; fi

echo "── LV_COORD_DIR never moves a client's dispatch (LVI-022) ──"
# The board cds into each client and calls that client's lv-exec.sh with
# LV_COORD_DIR still in its environment. If the dispatcher honoured it, every
# one of those calls would run the coordinator's harness against the client.
# So a shim elsewhere on PATH has to cd into the coordinator itself.
mkproj() {   # mkproj <dir> — a project whose lv-where.sh prints its own name
  mkdir -p "$1/scripts/v2.00"
  cp "$REPO_ROOT/scripts/lv-exec.sh" "$1/scripts/"
  printf '0.00 v2.00\n' > "$1/scripts/version-map.txt"
  printf '#!/usr/bin/env bash\necho %s\n' "$(basename "$1")" > "$1/scripts/v2.00/lv-where.sh"
  chmod +x "$1/scripts/lv-exec.sh" "$1/scripts/v2.00/lv-where.sh"
}
mkproj "$T/xc/coord"; mkproj "$T/xc/client"; mkdir -p "$T/xc/elsewhere"
out=$(cd "$T/xc/client" && LV_COORD_DIR="$T/xc/coord" scripts/lv-exec.sh lv-where.sh 2>&1)
assert_eq "a client's call from the board resolves the client, LV_COORD_DIR set" "$out" "client"
out=$(cd "$T/xc/elsewhere" && LV_COORD_DIR="$T/xc/coord" "$T/xc/coord/scripts/lv-exec.sh" lv-where.sh 2>&1); rc=$?
[ $rc -ne 0 ] && ok "outside any project, LV_COORD_DIR alone does not locate one" || bad "outside any project, LV_COORD_DIR alone does not locate one" "rc=$rc $out"
grep -q 'LV_COORD_DIR names it explicitly' "$RACK" && bad "lv-rack.sh no longer claims lv-exec.sh honours LV_COORD_DIR" \
  || ok "lv-rack.sh no longer claims lv-exec.sh honours LV_COORD_DIR"

echo ""
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
