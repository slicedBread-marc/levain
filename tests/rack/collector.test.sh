#!/usr/bin/env bash
# collector.test.sh — the rack as two processes (LVI-048): `lv-rack.sh
# --collect` keeps board-cache/grid.json and a heartbeat; every board reads it.
#
#   tests/rack/collector.test.sh
#
# Proves: a board starts the collector when there is none; a fresh one is
# reused, and --plain then prints the snapshot without collecting; a refresh
# request file is honoured for that project alone; a stale heartbeat (dead
# collector, or a pid that is no longer one) is replaced; two boards started
# together share one collector; and the collector exits when idle. Runs real
# processes against stub clients, so it waits on a clock; the LV_RACK_* knobs
# keep that to seconds.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"
FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-collector.XXXXXX")" && pwd -P)"
CACHE="$FIX/coord/cache"
HUNG=""

# Every collector this test started, from the log, plus the stand-in process.
cleanup() {
  local p
  if [ -f "$CACHE/collector.log" ]; then
    for p in $(awk '/ start /{print $2}' "$CACHE/collector.log"); do kill "$p" 2>/dev/null; done
  fi
  [ -n "$HUNG" ] && kill "$HUNG" 2>/dev/null
  rm -rf "$FIX"
}
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }

# Two stub clients: lv-tray.sh --fields prints ./fields; every call is logged.
export CALLS="$FIX/calls.log"; : > "$CALLS"
for c in alpha beta; do
  mkdir -p "$FIX/$c/scripts"
  printf 'project_slug: %s\n' "$c" > "$FIX/$c/levain.yml"
  cat > "$FIX/$c/scripts/lv-exec.sh" <<'STUB'
#!/usr/bin/env bash
d="$(cd "$(dirname "$0")/.." && pwd)"
printf '%s %s\n' "$(basename "$d")" "$*" >> "$CALLS"
case "$1" in lv-tray.sh) cat "$d/fields" ;; esac
exit 0
STUB
  chmod +x "$FIX/$c/scripts/lv-exec.sh"
done
fields() { printf 'daemon=off\trunning=%s\tgates=0\tdraft=0\tready=0\tactive=0\tverify=0\ttesting=0\tcomplete=0\tabandoned=0\tregistry=clean\tqueued=7\n' "$2" > "$FIX/$1/fields"; }
fields alpha 1; fields beta 2

mkdir -p "$FIX/coord"
printf '%s\n' "$FIX/alpha" "$FIX/beta" > "$FIX/deployments.txt"
export LV_PACKS="" LV_COORD_DIR="$FIX/coord" LV_BOARD_CACHE="$CACHE"
export LV_DEPLOYMENTS="$FIX/deployments.txt" LV_DORMANT_STATE="$FIX/dormant"
export LV_LIBRARY_DIR="$FIX/nolib" LV_SUSPEND_STATE="$FIX/suspended"
export LV_RACK_COLLECT_SECS=600 LV_RACK_IDLE_SECS=30 LV_RACK_STALE_SECS=4 LV_RACK_WAIT_SECS=20
unset LV_RACK_LIB LV_RACK_COLLECTOR

hb_pid()   { [ -f "$CACHE/collector.hb" ] && awk '{print $1}' "$CACHE/collector.hb"; }
lock_pid() { [ -f "$CACHE/collector.lock/pid" ] && cat "$CACHE/collector.lock/pid"; }
calls_to() { grep -c "^$1 lv-tray.sh" "$CALLS"; }
field_of() { jq -r --arg n "$1" --arg k "$2" '.projects[] | select(.name == $n) | .[$k] | tostring' "$CACHE/grid.json"; }
plain()    { bash "$BOARD" --plain </dev/null 2>&1; }
# until_true <seconds> <command...> — poll a condition, a fifth of a second at a time.
until_true() {
  local n=$(( $1 * 5 )); shift
  while [ "$n" -gt 0 ]; do "$@" && return 0; sleep 0.2; n=$((n - 1)); done
  return 1
}
gone() { ! kill -0 "$1" 2>/dev/null; }

command -v jq >/dev/null 2>&1 || { echo "  skip: no jq, so no collector"; exit 0; }

echo "── a board starts the collector when there is none ──"
out=$(plain)
case "$out" in *alpha*beta*|*beta*alpha*) ok "--plain prints the portfolio" ;; *) bad "--plain prints the portfolio — got: $out" ;; esac
P1=$(hb_pid)
if [ -n "$P1" ] && kill -0 "$P1" 2>/dev/null; then ok "and leaves a live collector behind it"; else bad "and leaves a live collector behind it (hb pid '$P1')"; fi
ck "the lock names the same collector" "$(lock_pid)" "$P1"
ck "it saved the snapshot" "$(jq -r '.schema' "$CACHE/grid.json" 2>/dev/null)" "1"
[ -f "$CACHE/readers/plain-"* ] 2>/dev/null && ok "--plain left a reader record" || bad "--plain left a reader record"
ck "the snapshot carries every --fields key, drawn or not" "$(field_of alpha tray | jq -r .queued)" "7"
ck "and says whether dormant projects were scanned" "$(jq -r '.include_dormant' "$CACHE/grid.json")" "false"

echo "── a fresh collector is reused, and --plain only reads ──"
fields beta 9
before=$(( $(calls_to alpha) + $(calls_to beta) ))
t0=$(date +%s); out=$(plain); t1=$(date +%s)
ck "the same collector answers" "$(hb_pid)" "$P1"
ck "--plain shells into no client" "$(( $(calls_to alpha) + $(calls_to beta) ))" "$before"
[ $((t1 - t0)) -le 2 ] && ok "and is instant ($((t1 - t0))s)" || bad "and is instant — took $((t1 - t0))s"
ck "it prints the snapshot, not a new collect" "$(field_of beta running)" "2"

echo "── a refresh request is honoured, for that project alone ──"
fields alpha 5
beta_ts=$(field_of beta fetched_at); beta_calls=$(calls_to beta)
sleep 1
: > "$CACHE/requests/refresh-alpha@tok1"
if until_true 10 test -e "$CACHE/served/tok1"; then ok "the request is answered (served/tok1)"; else bad "the request is answered (served/tok1)"; fi
[ ! -e "$CACHE/requests/refresh-alpha@tok1" ] && ok "and taken off the queue" || bad "and taken off the queue"
ck "alpha's new number is in the snapshot" "$(field_of alpha running)" "5"
ck "beta was not fetched" "$(calls_to beta)" "$beta_calls"
ck "beta's numbers keep their time" "$(field_of beta fetched_at)" "$beta_ts"
: > "$CACHE/requests/refresh-nosuch@tok2"
until_true 5 test -e "$CACHE/served/tok2" && ok "a request for an unknown project is still answered" || bad "a request for an unknown project is still answered"

echo "── a board's refresh_one goes through the collector ──"
fields beta 4
got=$(LV_RACK_LIB=1 bash -c 'f=$1; set --; source "$f"; reset_fields; snapshot_load; for i in "${!names[@]}"; do [ "${names[$i]}" = beta ] && b=$i; done
  refresh_one "$b"; echo "${f_running[$b]}"' _ "$BOARD" </dev/null 2>/dev/null)
ck "refresh_one(beta) returns the collector's fresh number" "$got" "4"
ck "and every board's snapshot has it" "$(field_of beta running)" "4"
got=$(LV_RACK_LIB=1 bash -c 'f=$1; set --; source "$f"; reset_fields
  ui_tick; a=$?; ui_tick; b=$?; echo "$a $b ${#names[@]}"' _ "$BOARD" </dev/null 2>/dev/null)
ck "a board's tick paints a new snapshot once, then waits for the next" "$got" "0 1 2"

echo "── a stale heartbeat is replaced ──"
kill -9 "$P1" 2>/dev/null; until_true 5 gone "$P1"
ck "a killed collector leaves its heartbeat behind" "$(hb_pid)" "$P1"
plain > /dev/null
P2=$(hb_pid)
if [ -n "$P2" ] && [ "$P2" != "$P1" ] && kill -0 "$P2" 2>/dev/null; then ok "the next board starts a new one"; else bad "the next board starts a new one (old $P1, now '$P2')"; fi
ck "and the lock is the new one's" "$(lock_pid)" "$P2"
# A heartbeat that stopped beating, under a pid that is alive but is not a
# collector (the pid was reused): replaced, and that process left alone.
kill "$P2"; until_true 5 gone "$P2"
sleep 600 & HUNG=$!
mkdir -p "$CACHE/collector.lock"; echo "$HUNG" > "$CACHE/collector.lock/pid"
printf '%s %s %s idle 3\n' "$HUNG" "$(( $(date +%s) - 120 ))" "$(( $(date +%s) - 60 ))" > "$CACHE/collector.hb"
touch -t 202001010000 "$CACHE/collector.lock"
plain > /dev/null
P3=$(hb_pid)
if [ -n "$P3" ] && [ "$P3" != "$HUNG" ] && kill -0 "$P3" 2>/dev/null; then ok "a silent heartbeat under a live non-collector pid is replaced"; else bad "a silent heartbeat under a live non-collector pid is replaced (got '$P3')"; fi
ck "the lock moved to it" "$(lock_pid)" "$P3"
kill -0 "$HUNG" 2>/dev/null && ok "and the process that held the old pid is not signalled" || bad "and the process that held the old pid is not signalled"
kill "$HUNG" 2>/dev/null; wait "$HUNG" 2>/dev/null; HUNG=""

echo "── two boards at once share one collector ──"
kill "$P3"; until_true 5 gone "$P3"
rm -f "$CACHE/collector.hb"
starts_before=$(grep -c ' start ' "$CACHE/collector.log")
plain > "$FIX/b1.out" & b1=$!
plain > "$FIX/b2.out" & b2=$!
wait "$b1" "$b2"
grep -q alpha "$FIX/b1.out" && grep -q alpha "$FIX/b2.out" && ok "both boards print the portfolio" || bad "both boards print the portfolio"
sleep 2   # a loser that claimed first sees the lock move on its next tick
alive=0
for p in $(awk '/ start /{print $2}' "$CACHE/collector.log" | tail -n +"$((starts_before + 1))"); do
  kill -0 "$p" 2>/dev/null && alive=$((alive + 1))
done
ck "one collector is left running" "$alive" "1"
ck "and it is the one the heartbeat and lock name" "$(lock_pid)" "$(hb_pid)"
P4=$(hb_pid)

echo "── the collector exits when nobody reads ──"
kill "$P4"; until_true 5 gone "$P4"
rm -rf "$CACHE/readers"
LV_RACK_IDLE_SECS=2 bash "$BOARD" --collect </dev/null >/dev/null 2>&1 &
C=$!
until_true 5 test -f "$CACHE/collector.hb"
if until_true 10 gone "$C"; then ok "idle past LV_RACK_IDLE_SECS with no reader, it exits"; else bad "idle past LV_RACK_IDLE_SECS with no reader, it exits"; kill "$C" 2>/dev/null; fi
[ ! -e "$CACHE/collector.hb" ] && [ ! -e "$CACHE/collector.lock" ] && ok "and clears its heartbeat and lock" || bad "and clears its heartbeat and lock"
grep -q "idle 2s with no reader" "$CACHE/collector.log" && ok "and says why in its log" || bad "and says why in its log"
# A live board keeps it up past the idle window.
sleep 600 & READER=$!
mkdir -p "$CACHE/readers"; printf 'interval=60 dormant=0\n' > "$CACHE/readers/$READER"
LV_RACK_IDLE_SECS=2 bash "$BOARD" --collect </dev/null >/dev/null 2>&1 &
C=$!
sleep 4
kill -0 "$C" 2>/dev/null && ok "a live reader keeps it running" || bad "a live reader keeps it running"
kill "$READER" 2>/dev/null; wait "$READER" 2>/dev/null
if until_true 10 gone "$C"; then ok "and it exits once that reader is gone"; else bad "and it exits once that reader is gone"; kill "$C" 2>/dev/null; fi

echo "── a second collector stands down ──"
LV_RACK_IDLE_SECS=30 bash "$BOARD" --collect </dev/null >/dev/null 2>&1 &
C=$!
until_true 5 test -f "$CACHE/collector.hb"
LV_RACK_IDLE_SECS=30 bash "$BOARD" --collect </dev/null >/dev/null 2>&1; rc=$?
ck "--collect with a live collector exits 0 at once" "$rc" "0"
ck "and the first keeps the lock" "$(lock_pid)" "$C"
kill "$C" 2>/dev/null

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
