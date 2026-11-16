#!/usr/bin/env bash
# progress.test.sh — a service's progress: file (the coordinator's LVI-052): lv-services.sh status
# appends its facts after the url, never before; a missing, unreadable, undated or stale file says
# so and is never an error; `progress <id>` gives the detail lines; the rack shows the summary in
# the row, dim when stale, and its drill lists the detail.
#
#   tests/rack/progress.test.sh
#
# Every repo and file is a fixture. Needs python3 (lv-services.sh reads the JSON with it).
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
BOARD="$SCRIPTS/lv-rack.sh"
SVC="$SCRIPTS/lv-services.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-progress.XXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1 — [$3] in [$2]" ;; *) ok "$1" ;; esac; }

command -v python3 >/dev/null 2>&1 || { echo "progress: python3 missing, skipped"; exit 0; }

unset CLAUDECODE
export LV_SERVICES_DIR="$FIX/state"
export LV_SERVICES_OPENER="$FIX/opener"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$1" >> "%s/opened"\n' "$FIX" > "$LV_SERVICES_OPENER"; chmod +x "$LV_SERVICES_OPENER"

P="$FIX/gamma"
git init -q -b main "$P"
git -C "$P" -c user.email=t@t -c user.name=t commit -q --allow-empty -m one
cat > "$P/levain.yml" <<YML
project_slug: "gamma"
services:
  synth:
    label: "Runner"
    start: "true"
    heartbeat: 60
    progress: synth.status.json
  abs:
    start: "true"
    progress: "$FIX/elsewhere/abs.json"
    url: "http://abs.test/"
  plain:
    start: "true"
YML
D="$LV_SERVICES_DIR/gamma"; mkdir -p "$D" "$FIX/elsewhere"
iso() { python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(seconds=int(sys.argv[1]))).isoformat())' "$1"; }
row() { (cd "$P" && "$SVC" status) | awk -F'\t' -v id="$1" '$1==id'; }
field() { row "$1" | cut -f"$2"; }

echo "── status appends, never reorders ──"
ck "a service with no progress: still has its url 10th" "$(field plain 10)" "-"
ck "and five '-' after it" "$(field plain 11-15)" "-	-	-	-	-"
ck "a url stays the 10th field beside progress" "$(field abs 10)" "http://abs.test/"
ck "no file yet is missing, not an error" "$(field synth 11)" "missing"

echo "── the file's facts ──"
printf '{"state":"running","summary":"pass 3/8 struggler-en, $0.41 of $1.40 (29%%), 12 sessions","detail":["pass 1/8 a: $0.30","pass 2/8 b: $0.35"],"updatedAt":"%s"}\n' "$(iso 5)" > "$D/synth.status.json"
ck "a fresh file is ok" "$(field synth 11)" "ok"
age=$(field synth 12); [ "$age" -ge 0 ] 2>/dev/null && [ "$age" -lt 30 ] && ok "its age is seconds since updatedAt" || bad "its age is seconds since updatedAt — got [$age]"
ck "the summary is the 13th field" "$(field synth 13)" 'pass 3/8 struggler-en, $0.41 of $1.40 (29%), 12 sessions'
ck "the service's own state is the 15th" "$(field synth 15)" "running"
ck "no throttle: leaves the control field '-'" "$(field synth 14)" "-"
printf '{"summary":"old","updatedAt":"%s"}\n' "$(iso 7200)" > "$D/synth.status.json"
ck "updatedAt older than heartbeat: is stale" "$(field synth 11)" "stale"
printf '{"summary":"seven digits","updatedAt":"2099-01-01T00:00:00.1234567+02:00"}\n' > "$D/synth.status.json"
ck "a .NET 7-digit fraction with an offset parses" "$(field synth 11)" "ok"
printf '{"summary":"no time"}\n' > "$D/synth.status.json"
ck "no updatedAt is undated" "$(field synth 11)" "undated"
printf '{"summary":"tab\\there\\nnewline","updatedAt":"%s"}\n' "$(iso 1)" > "$D/synth.status.json"
ck "tabs and newlines in a summary cannot break the TSV" "$(field synth 13)" "tab here newline"
ck "and the url is still where the rack reads it" "$(row synth | awk -F'\t' '{print NF}')" "15"
printf 'not json' > "$D/synth.status.json"
ck "a file that does not parse is unreadable" "$(field synth 11)" "unreadable"
printf '[1,2]' > "$D/synth.status.json"
ck "and so is one that is no object" "$(field synth 11)" "unreadable"
(cd "$P" && "$SVC" status >/dev/null 2>&1); ck "status still exits 0 over it" "$?" "0"
printf '{"summary":"abs ok","updatedAt":"%s"}\n' "$(iso 1)" > "$FIX/elsewhere/abs.json"
ck "an absolute progress: path is read where it says" "$(field abs 13)" "abs ok"

echo "── progress <id> ──"
printf '{"summary":"s","detail":["one","two"],"updatedAt":"%s"}\n' "$(iso 1)" > "$D/synth.status.json"
out=$(cd "$P" && "$SVC" progress synth)
ck "it names the file first" "$(head -1 <<< "$out")" "file	$D/synth.status.json"
ck "then the facts, then each detail line" "$(sed -n '3,$p' <<< "$out" | tr '\n' '|')" "one|two|"
out=$(cd "$P" && "$SVC" progress plain 2>&1); ck "a service with neither has no progress" "$?" "7"

echo "── the rack ──"
mkdir -p "$P/scripts"
printf '#!/usr/bin/env bash\nn=$1; shift; exec "%s/$n" "$@"\n' "$SCRIPTS" > "$P/scripts/lv-exec.sh"; chmod +x "$P/scripts/lv-exec.sh"
O="$FIX/older"; mkdir -p "$O/scripts"
printf 'project_slug: older\nservices:\n  w:\n    start: "true"\n' > "$O/levain.yml"
# An older harness prints ten fields; the rack reads the rest as '-'.
printf '#!/usr/bin/env bash\nprintf "w\\tup\\t-\\t-\\t-\\t-\\t-\\t-\\t-\\thttp://older.test/\\n"\n' > "$O/scripts/lv-exec.sh"; chmod +x "$O/scripts/lv-exec.sh"
export LV_DEPLOYMENTS="$FIX/deployments.txt" LV_BOARD_CACHE="$FIX/cache" LV_DORMANT_STATE="$FIX/dormant" LV_RACK_LIB=1
printf '%s\n' "$P" "$O" > "$LV_DEPLOYMENTS"
# shellcheck disable=SC1090
source "$BOARD"
printf '{"state":"running","summary":"pass 3/8, 12 sessions","detail":["pass 1/8 done","budget 10k of 400k"],"updatedAt":"%s"}\n' "$(iso 2)" > "$D/synth.status.json"
sv_collect
table=$(sv_table)
has "the table has a progress column" "$table" "PROGRESS"
has "the row carries the summary" "$(grep ' synth ' <<< "$table")" "pass 3/8, 12 sessions"
ck "an older harness's row reads as no progress" "$(for i in "${!SV_ID[@]}"; do [ "${SV_ID[$i]}" = w ] && echo "${SV_PST[$i]}${SV_URL[$i]}"; done)" "-http://older.test/"
printf '{"summary":"pass 2/8","updatedAt":"%s"}\n' "$(iso 7200)" > "$D/synth.status.json"
sv_collect "$P"
has "a stale summary says how old it is" "$(sv_table | grep ' synth ')" "pass 2/8 (2h old)"
DIM="<dim>" R="</dim>"
has "and is drawn dim" "$(sv_table | grep ' synth ')" "<dim>pass 2/8 (2h old)</dim>"
DIM="" R=""
rm -f "$D/synth.status.json"; sv_collect "$P"
has "a missing file reads as no progress yet" "$(sv_table | grep ' synth ')" "no progress yet"
plain=false; LV_RACK_COLS=130
printf '{"summary":"%s","updatedAt":"%s"}\n' "$(printf 'x%.0s' {1..60})" "$(iso 1)" > "$D/synth.status.json"
sv_collect "$P"
sv_width() { SV_PW=$(( -(LV_RACK_COLS - 10) )); }
has "on a narrow screen the summary takes a line of its own" "$(sv_table)" "↳ xxxx"
SV_PW=30; sv_width() { :; }
line=$(sv_table | grep ' synth ')
has "a long summary is cut to the width left" "$line" "…"
unset -f sv_width
# shellcheck disable=SC1090
source "$BOARD"

printf '{"state":"running","summary":"pass 3/8","detail":["pass 1/8 done","budget 10k of 400k"],"updatedAt":"%s"}\n' "$(iso 2)" > "$D/synth.status.json"
sv_collect "$P"
out=$(printf 'ib\x1b' | services_screen "$P" 2>&1)
has "i opens the drill" "$out" "PROGRESS"
has "which lists the detail lines" "$out" "budget 10k of 400k"
has "and how old they are" "$out" "s ago"
has "and what the service says it is doing" "$out" "it reports: running"
sv_collect "$P"
out=$(printf '\nb\x1b' | services_screen "$P" 2>&1)
has "enter on a service with progress and no url opens the drill too" "$out" "pass 1/8 done"
out=$(printf 'jji\x1b' | services_screen "$P" 2>&1)
has "i on a service with neither says so" "$out" "declares no progress: or throttle:"
out=$(LV_RACK_LIB= bash "$BOARD" --services --plain </dev/null 2>&1)
has "--services carries the summary for the skill" "$out" "pass 3/8"

echo
[ "$fails" -eq 0 ] && { echo "progress: all passed"; exit 0; }
echo "progress: $fails failed"; exit 1
