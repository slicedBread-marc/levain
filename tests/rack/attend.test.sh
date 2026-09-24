#!/usr/bin/env bash
# lv-rack-attend.test.sh — `t` at a drill level starts /wf-attend.
#
#   tests/rack/attend.test.sh
#
# The first step toward answering the pipeline from a UI: from the plan a
# drill level is about, `t` hands the terminal to a Claude session in that
# project on `/wf-attend <ID>` and takes it back when the session exits.
# LV_ATTEND_CMD points at a stub that records its cwd and argv, so no real
# session starts. Same sourcing technique as the other board tests.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/wf-attend-test.XXXXXX")" && pwd -P)"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
says() { if grep -qF "$3" "$2"; then ok "$1"; else bad "$1 — expected: $3"; fi; }

CLIENT="$FIX/alpha"
mkdir -p "$CLIENT/scripts"
cat > "$CLIENT/scripts/wf-exec.sh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "wf-board-drill.sh" ] || exit 0
shift
case "$1 ${2:-}" in
  "row gates")        printf 'PLN-042 spec-approval\tlist\tgate PLN-042\n' ;;
  "gate PLN-042")     printf 'gate file\tnone\t-\n' ;;
  "row ideas")        printf 'nothing gated\tnone\t-\n' ;;
  *) echo "stub: no such node $*" >&2; exit 2 ;;
esac
STUB
chmod +x "$CLIENT/scripts/wf-exec.sh"

ATTEND_LOG="$FIX/attend.log"
cat > "$FIX/fake-claude" <<STUB
#!/usr/bin/env bash
printf '%s|%s\n' "\$(pwd -P)" "\$*" >> "$ATTEND_LOG"
STUB
chmod +x "$FIX/fake-claude"
export LV_ATTEND_CMD="$FIX/fake-claude"

LV_RACK_LIB=1
LV_BOARD_CACHE="$FIX/cache"
export LV_RACK_LIB LV_BOARD_CACHE
# shellcheck source=../bin/lv-rack
source "$BOARD"
DEPLOYMENTS="$FIX/deployments.txt"
printf '%s\n' "$CLIENT" > "$DEPLOYMENTS"
refresh_one() { :; }

seed() {
  names=("alpha"); paths=("$CLIENT"); statuses=("ok")
  f_daemon=("off"); f_running=("0")
  f_gates=("1"); f_gates_stuck=("0"); f_gates_blocked=("0")
  f_draft=("1"); f_ready=("0"); f_active=("0"); f_verify=("0"); f_testing=("0")
  f_complete=("0"); f_abandoned=("0")
  f_registry=("clean"); f_attn=(""); f_release=("-"); f_deploy=("-")
  f_ideas=("0"); f_ideas_drift=("0"); f_ts=("$(date +%s)")
  rm -rf "$LV_BOARD_CACHE"; : > "$ATTEND_LOG"
}

echo "lv-rack attend key"

# 1. On a list line that points at a plan, t attends that plan.
# Keys: t (attend), space (dismiss the return prompt), esc (leave the level).
seed
printf 't \x1b' | drill_browse 0 "gates" "row gates" > "$FIX/list.txt" 2>&1
says "t runs /wf-attend on the highlighted plan" "$ATTEND_LOG" "|/wf-attend PLN-042"
says "in that project's directory"               "$ATTEND_LOG" "$CLIENT|"
says "the level advertises the key"              "$FIX/list.txt" "t attend"

# 2. On a level ABOUT a plan whose lines carry no id, t uses the level's id.
seed
printf 't \x1b' | drill_browse 0 "PLN-042" "gate PLN-042" > "$FIX/gate.txt" 2>&1
says "t on a plan's own level attends that plan" "$ATTEND_LOG" "|/wf-attend PLN-042"

# 3. No id anywhere: the whole queue.
seed
printf 't \x1b' | drill_browse 0 "ideas" "row ideas" > "$FIX/none.txt" 2>&1
if grep -qx "$CLIENT|/wf-attend" "$ATTEND_LOG"; then ok "no id attends the whole queue"
else bad "no id — expected a bare /wf-attend, got: $(cat "$ATTEND_LOG")"; fi

# 4. A missing claude binary is reported, not crashed on.
seed
LV_ATTEND_CMD="$FIX/does-not-exist"
printf 't \x1b' | drill_browse 0 "gates" "row gates" > "$FIX/missing.txt" 2>&1
says "a missing claude is reported" "$FIX/missing.txt" "not found on PATH"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
