#!/usr/bin/env bash
# throttle.test.sh — a service's throttle: (the coordinator's LVI-041): lv-services.sh writes
# <id>.control.json beside the beacons by merging through a rename, checks each known key's
# shape, refuses what would let a run draw more under an agent, and never overwrites a file it
# cannot parse; status carries the control state; the rack pauses, resumes, stops for the day and
# sets a value from the services screen and its drill.
#
#   tests/rack/throttle.test.sh
#
# Every repo and file is a fixture. Needs python3.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
BOARD="$SCRIPTS/lv-rack.sh"
SVC="$SCRIPTS/lv-services.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-throttle.XXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }

command -v python3 >/dev/null 2>&1 || { echo "throttle: python3 missing, skipped"; exit 0; }

unset CLAUDECODE
export LV_SERVICES_DIR="$FIX/state"

P="$FIX/delta"
git init -q -b main "$P"
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
cat > "$P/levain.yml" <<'YML'
project_slug: "delta"
services:
  runner:
    start: "true"
    heartbeat: 60
    progress: runner.status.json
    throttle:
      rate: 20/hour
      concurrency: 1
      budget: 400k tokens/5h
      hours: "23:00-07:00"
      ai_share: 10%
      lane: slow
  plain:
    start: "true"
YML
CF="$LV_SERVICES_DIR/delta/runner.control.json"
t() { (cd "$P" && "$SVC" throttle "$@"); }
j() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2], "<none>"))' "$CF" "$1"; }
field() { (cd "$P" && "$SVC" status) | awk -F'\t' -v id="$1" '$1==id' | cut -f"$2"; }

echo "── show ──"
out=$(t runner)
ck "with no control file, state is run by default" "$(grep '^state' <<< "$out")" "state	run	default"
ck "and each declared key is the manifest's" "$(grep '^budget' <<< "$out")" "budget	400k tokens/5h	manifest"
ck "status says run while no file exists" "$(field runner 14)" "run"
ck "and - for a service with no throttle:" "$(field plain 14)" "-"
out=$(t plain 2>&1); ck "a service with no throttle: has none to show" "$?" "7"

echo "── writes ──"
t runner pause >/dev/null
ck "pause writes state" "$(j state)" "pause"
ts=$(j updatedAt)
[[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && ok "and stamps updatedAt in UTC" || bad "and stamps updatedAt in UTC — got [$ts]"
ck "the file sits beside the beacons" "$(ls "$LV_SERVICES_DIR/delta")" "runner.control.json"
ck "status carries the control state" "$(field runner 14)" "pause"
t runner set rate 5/hour >/dev/null
ck "set changes one key" "$(j rate)" "5/hour"
ck "and keeps the others" "$(j state)" "pause"
t runner set concurrency 2 >/dev/null
ck "a whole number is written as a number" "$(python3 -c 'import json,sys; print(type(json.load(open(sys.argv[1]))["concurrency"]).__name__)' "$CF")" "int"
t runner set budget "1m tokens/24h" >/dev/null; ck "a budget with a space is one value" "$(j budget)" "1m tokens/24h"
t runner set lane fast >/dev/null; ck "an undeclared-shape key passes through" "$(j lane)" "fast"
ck "show says which values the control file set" "$(t runner | grep '^rate')" "rate	5/hour	control"
python3 - "$CF" <<'PY'
import json, sys; d = json.load(open(sys.argv[1])); d["handWritten"] = "keep me"; json.dump(d, open(sys.argv[1], "w"))
PY
t runner resume >/dev/null
ck "resume sets run" "$(j state)" "run"
ck "and a field written by hand survives" "$(j handWritten)" "keep me"
t runner unset rate >/dev/null
ck "unset drops the key" "$(j rate)" "<none>"
ck "so show falls back to the manifest" "$(t runner | grep '^rate')" "rate	20/hour	manifest"
t runner stop-for-day >/dev/null; ck "stop-for-day" "$(j state)" "stop-for-day"
ls "$LV_SERVICES_DIR/delta" | grep -q '\.control\.json\.' && bad "no temp file is left behind" || ok "no temp file is left behind"

echo "── refusals ──"
for kv in "rate 5/hr" "rate 0/hour" "concurrency x" "budget 400k" "hours 23-07" "ai_share 10"; do
  out=$(t runner set $kv 2>&1); ck "a bad ${kv%% *} ('${kv#* }') is refused" "$?" "1"
done
out=$(t runner set nope 1 2>&1); ck "an undeclared key is refused" "$?" "1"
has "naming what is declared" "$out" "rate concurrency budget hours ai_share lane"
out=$(t runner set state run 2>&1); ck "state is not set by set" "$?" "1"
before=$(cat "$CF")
out=$(CLAUDECODE=1 t runner resume 2>&1); ck "resume refuses under an agent" "$?" "2"
out=$(CLAUDECODE=1 t runner set rate 99/hour 2>&1); ck "set refuses under an agent" "$?" "2"
out=$(CLAUDECODE=1 t runner unset budget 2>&1); ck "unset refuses under an agent" "$?" "2"
ck "and the file is untouched" "$(cat "$CF")" "$before"
out=$(CLAUDECODE=1 t runner pause 2>&1); ck "pause is allowed under an agent: it only slows a run" "$?" "0"
printf '{broken' > "$CF"
out=$(t runner pause 2>&1); ck "a control file that does not parse is refused (exit 9)" "$?" "9"
ck "never overwritten" "$(cat "$CF")" "{broken"
ck "status reads it as unreadable, and still succeeds" "$(field runner 14)" "unreadable"
rm -f "$CF"

echo "── the rack ──"
mkdir -p "$P/scripts"
printf '#!/usr/bin/env bash\nn=$1; shift; exec "%s/$n" "$@"\n' "$SCRIPTS" > "$P/scripts/lv-exec.sh"; chmod +x "$P/scripts/lv-exec.sh"
export LV_DEPLOYMENTS="$FIX/deployments.txt" LV_BOARD_CACHE="$FIX/cache" LV_DORMANT_STATE="$FIX/dormant" LV_RACK_LIB=1
printf '%s\n' "$P" > "$LV_DEPLOYMENTS"
# shellcheck disable=SC1090
source "$BOARD"
sv_collect
out=$(printf 'p\x1b' | services_screen "$P" 2>&1)
ck "p on the list pauses a throttled service" "$(j state)" "pause"
has "and the row says paused" "$out" "⏸ paused"
sv_collect
printf 'p\x1b' | services_screen "$P" >/dev/null 2>&1
ck "p again resumes it" "$(j state)" "run"
out=$(printf 'jp\x1b' | services_screen "$P" 2>&1)
has "p on a service with no throttle: says so" "$out" "declares no throttle:"
sv_collect
out=$(printf 'idb\x1b' | services_screen "$P" 2>&1)
ck "d in the drill stops it for the day" "$(j state)" "stop-for-day"
has "the drill lists the throttle" "$out" "THROTTLE"
has "with each key's source" "$out" "budget         400k tokens/5h (manifest)"
sv_collect
out=$(printf 'is1\n7/hour\nb\x1b' | services_screen "$P" 2>&1)
ck "s in the drill sets a declared key" "$(j rate)" "7/hour"
has "and shows the result" "$out" "rate = 7/hour"
sv_collect
out=$(printf 'is1\n7/hr\nb\x1b' | services_screen "$P" 2>&1)
has "a bad value shows the refusal" "$out" "not a valid rate"
ck "and changes nothing" "$(j rate)" "7/hour"

echo
[ "$fails" -eq 0 ] && { echo "throttle: all passed"; exit 0; }
echo "throttle: $fails failed"; exit 1
