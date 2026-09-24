#!/usr/bin/env bash
# lv-rack-suspend.test.sh — exercise --stop-all / --resume / --list-daemons
# against a throwaway fixture, never against the real portfolio.
#
#   tests/rack/suspend.test.sh
#
# Builds two fake clients under a temp dir: `alpha` with a live stand-in daemon
# (a backgrounded sleep whose pid sits in the usual
# .claude/orchestrator/daemon.pid), and `beta` with none. Each gets a stub
# scripts/wf-exec.sh that honours the two calls lv-rack actually makes —
# `wf-orchestrate.sh --stop` and `--daemon` — so the real code path runs end to
# end without a real harness, a real client, or a real daemon.
#
# LV_DEPLOYMENTS / LV_SUSPEND_STATE point the tool at the fixture. They exist
# for exactly this: otherwise the only way to test stopping daemons is to stop
# real ones on real projects, which is the thing you want proven first.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-test.XXXXXX")"
A0=""; A1=""
cleanup() {
  [ -n "$A0" ] && kill "$A0" 2>/dev/null
  [ -n "$A1" ] && kill "$A1" 2>/dev/null
  rm -rf "$FIX"
  return 0
}
trap cleanup EXIT

pass=0; fail=0
ck() {
  if [ "$2" = "$3" ]; then
    printf '  PASS %s\n' "$1"; pass=$((pass + 1))
  else
    printf '  FAIL %s (want %s, got %s)\n' "$1" "$3" "$2"; fail=$((fail + 1))
  fi
}

# ── Fixture ─────────────────────────────────────────────────────────────
for c in alpha beta; do
  mkdir -p "$FIX/$c/scripts" "$FIX/$c/.claude/orchestrator/logs"
  cat > "$FIX/$c/scripts/wf-exec.sh" <<'STUB'
#!/usr/bin/env bash
# Stands in for a client's scripts/wf-exec.sh. Only the two subcommands
# lv-rack issues are implemented; anything else is a no-op.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIDFILE="$ROOT/.claude/orchestrator/daemon.pid"
case "${2:-}" in
  --stop)
    if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null; rm -f "$PIDFILE"; fi ;;
  --daemon)
    mkdir -p "$(dirname "$PIDFILE")"
    sleep 600 &
    echo $! > "$PIDFILE" ;;
esac
exit 0
STUB
  chmod +x "$FIX/$c/scripts/wf-exec.sh"
done
printf '%s\n%s\n' "$FIX/alpha" "$FIX/beta" > "$FIX/deployments.txt"

sleep 600 &
A0=$!
# disown it: stopping this process is what the test is for, and without this
# the shell announces "Terminated: 15" mid-run, which reads as a failure in an
# otherwise clean pass.
disown "$A0" 2>/dev/null || true
echo "$A0" > "$FIX/alpha/.claude/orchestrator/daemon.pid"

export LV_DEPLOYMENTS="$FIX/deployments.txt"
export LV_SUSPEND_STATE="$FIX/suspended"

# ── Assertions ──────────────────────────────────────────────────────────
echo "syntax"
if bash -n "$BOARD"; then ck "parses" "ok" "ok"; else ck "parses" "bad" "ok"; fi

echo "list-daemons, one live"
out=$("$BOARD" --list-daemons); rc=$?
ck "exit 3 when a daemon is live" "$rc" "3"
ck "alpha listed" "$(printf '%s' "$out" | grep -c alpha)" "1"
ck "beta not listed" "$(printf '%s' "$out" | grep -c beta)" "0"

echo "stop-all"
"$BOARD" --stop-all >/dev/null; rc=$?
ck "exit 0" "$rc" "0"
if kill -0 "$A0" 2>/dev/null; then ck "alpha stopped" "alive" "dead"; else ck "alpha stopped" "dead" "dead"; fi
ck "record has one entry" "$(grep -c . "$LV_SUSPEND_STATE")" "1"
ck "record names alpha" "$(grep -c alpha "$LV_SUSPEND_STATE")" "1"

# The regression this guards: a second --stop-all finds nothing running. If it
# overwrote the record it would erase what the first run remembered, and
# --resume would silently become a no-op that leaves every daemon off.
echo "second stop-all preserves the record"
"$BOARD" --stop-all >/dev/null; rc=$?
ck "exit 0" "$rc" "0"
ck "record still has one entry" "$(grep -c . "$LV_SUSPEND_STATE")" "1"

echo "list-daemons, none live"
out=$("$BOARD" --list-daemons); rc=$?
ck "exit 0 when none live" "$rc" "0"
ck "prints nothing" "$(printf '%s' "$out" | wc -c | tr -d ' ')" "0"

echo "resume"
"$BOARD" --resume >/dev/null; rc=$?
ck "exit 0" "$rc" "0"
sleep 1
A1=$(cat "$FIX/alpha/.claude/orchestrator/daemon.pid" 2>/dev/null || echo "")
ck "pidfile rewritten" "$([ -n "$A1" ] && echo yes || echo no)" "yes"
if kill -0 "$A1" 2>/dev/null; then ck "alpha live again" "alive" "alive"; else ck "alpha live again" "dead" "alive"; fi
ck "a genuinely new process" "$([ "$A1" != "$A0" ] && echo yes || echo no)" "yes"
ck "record cleared" "$([ -f "$LV_SUSPEND_STATE" ] && echo present || echo gone)" "gone"

echo "resume with nothing recorded"
"$BOARD" --resume >/dev/null; rc=$?
ck "idempotent" "$rc" "0"

# Nothing is live at this point, so this is the "stopped nothing" path.
echo "stop-all with nothing running leaves no record behind"
kill "$A1" 2>/dev/null
rm -f "$FIX/alpha/.claude/orchestrator/daemon.pid"
"$BOARD" --stop-all >/dev/null; rc=$?
ck "exit 0" "$rc" "0"
ck "no stray record file" "$([ -f "$LV_SUSPEND_STATE" ] && echo present || echo none)" "none"

echo "a client that was never running is never touched"
ck "beta has no pidfile" "$([ -f "$FIX/beta/.claude/orchestrator/daemon.pid" ] && echo present || echo none)" "none"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
