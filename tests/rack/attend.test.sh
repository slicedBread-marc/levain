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
  "row release")      printf 'PLN-003 merged to develop\tlist\tartifact PLN-003\n' ;;
  "row deploy")       printf 'PLN-007 on release\tlist\tartifact PLN-007\n' ;;
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
  to_main=false
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

# 5. coordinator LVI-021: a release or deploy level is about the promotion, not the
# plans it lists. t attended the highlighted plan (PLN-003), and then /lv-attend
# RELEASE — neither of which runs the release. t starts the promotion skill.
seed; LV_ATTEND_CMD="$FIX/fake-claude"
printf 't \x1b' | drill_browse 0 "release" "row release" > "$FIX/rel.txt" 2>&1
says "t in the release drill starts the release skill" "$ATTEND_LOG" "$CLIENT|/wf-release"
if grep -q "|/[lw][vf]-attend\|PLN-003" "$ATTEND_LOG"; then bad "and not /lv-attend or the highlighted plan"
else ok "and not /lv-attend or the highlighted plan"; fi
says "the release level advertises t /lv-release" "$FIX/rel.txt" "t /lv-release"

seed
mkdir -p "$CLIENT/.claude/skills/lv-deploy"
printf 't \x1b' | drill_browse 0 "deploy" "row deploy" > /dev/null 2>&1
says "t in the deploy drill starts /lv-deploy"  "$ATTEND_LOG" "$CLIENT|/lv-deploy"
rm -rf "$CLIENT/.claude"

# 6. Anywhere else t still attends, and says so.
seed
printf 't \x1b' | drill_browse 0 "gates" "row gates" > "$FIX/t-gates.txt" 2>&1
says "t off a promotion still attends" "$ATTEND_LOG" "/wf-attend"
says "and advertises t attend"          "$FIX/t-gates.txt" "t attend"

# 7. On the rows level, the highlighted release/deploy row is the promotion.
seed
ROW_IDX=$(printf '%s\n' "${ROW_LABELS[@]}" | grep -nx release | cut -d: -f1)
: > "$FIX/keys"; for _ in $(seq 2 "$ROW_IDX"); do printf '\x1b[B' >> "$FIX/keys"; done
printf 't \x1b' >> "$FIX/keys"
drill_browse 0 "rows" "@rows" < "$FIX/keys" > /dev/null 2>&1
says "t on the rows level's release row starts the release skill" "$ATTEND_LOG" "|/wf-release"

# 8. When the session exits, the board is the screen it returns to: every
# drill level unwinds, rather than repainting the level it was opened from
# (which the session has usually just emptied). Redirected, not piped, so
# drill_browse runs in this shell and the flag it leaves is visible here.
seed; back_to_board=false
printf '\nt ' > "$FIX/keys"
drill_browse 0 "gates" "row gates" < "$FIX/keys" > "$FIX/unwind.txt" 2>&1
if sed -n '/return to the board/,$p' "$FIX/unwind.txt" | tail -n +2 | grep -q "›"; then
  bad "after the session no drill level is repainted"
else ok "after the session no drill level is repainted"; fi
if $back_to_board; then ok "and the board is told to come back fresh"
else bad "and the board is told to come back fresh"; fi

# 9. The same from the project menu: /lv-release (9) returns to the board,
# not to the menu it was started from.
seed; back_to_board=false
printf '9 ' > "$FIX/keys"
project_menu 0 < "$FIX/keys" > "$FIX/pm.txt" 2>&1
says "the project menu's 9 starts /lv-release" "$ATTEND_LOG" "/wf-release"
if sed -n '/return to the board/,$p' "$FIX/pm.txt" | grep -q "b) back"; then
  bad "after the session the project menu is not repainted"
else ok "after the session the project menu is not repainted"; fi

# 10. resume_board turns the flag into a fresh collect: a refresh in flight
# from before the session is dropped and the next tick starts a new one.
seed
compute_shown() { :; }; render_frame() { :; }
sleep 30 & refresh_pid=$!; refresh_file="$FIX/inflight"; : > "$refresh_file"
refreshing=true; back_to_board=true; next_refresh_at=999
stale_pid=$refresh_pid
resume_board > /dev/null
if kill -0 "$stale_pid" 2>/dev/null; then bad "the stale in-flight refresh is dropped"; kill "$stale_pid"
else ok "the stale in-flight refresh is dropped"; fi
if ! $refreshing && ! $back_to_board && [ "$next_refresh_at" -eq 0 ]; then
  ok "and a new refresh is due on the next tick"
else bad "and a new refresh is due on the next tick (refreshing=$refreshing back=$back_to_board next=$next_refresh_at)"; fi
# With a collector (LVI-048) the board asks it for that refresh instead.
if $USE_COLLECTOR; then
  if [ -e "$LV_BOARD_CACHE/requests/refresh-all" ]; then ok "and the collector is asked for a full refresh"
  else bad "and the collector is asked for a full refresh"; fi
fi

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
