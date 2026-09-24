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
printf 'project_slug: coord\nrole: coordinator\ncoordinates:\n  - "alpha:/p/alpha"\n  - "beta:/p/beta"\n' > "$C/claude-workflow.yml"
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

echo "── what it is not ──"
if grep -nE '~/dev|/Users/|\bops\b' "$RACK" >/dev/null; then bad "names no owner's paths or coordinator" "$(grep -nE '~/dev|/Users/|\bops\b' "$RACK" | head -3)"
else ok "names no owner's paths or coordinator"; fi

echo ""
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
