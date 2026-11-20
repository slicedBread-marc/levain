#!/usr/bin/env bash
# sweep.test.sh — LVI-031: the blind library sweep behind the board's `W`.
#
#   tests/rack/sweep.test.sh
#
# The library, its sweep-issues.sh and deploy-all.sh are fixtures, and
# LV_SWEEP_CLAUDE is a stand-in that commits a fix and reports it: no real
# session is ever started, and nothing here reads the operator's portfolio.
# lock.sh is the real one, copied into the fixture library.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail
# No real pack: a hook here must never reach the operator's publisher.
export LV_PACKS=

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
SWEEP="$SCRIPTS/lv-library-sweep.sh"
BOARD="$SCRIPTS/lv-rack.sh"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/lv-rack-sweep.XXXXXX")" && pwd -P)"
LIVE=""
cleanup() { [ -n "$LIVE" ] && { kill "$LIVE"; wait "$LIVE"; } 2>/dev/null; rm -rf "$FIX"; return 0; }
trap cleanup EXIT

fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — want [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 — [$3] not in [$2]" ;; esac; }

LIB="$FIX/lib"; STATE="$FIX/state"
export CALLS="$FIX/calls.log"

# ── Fixture library ─────────────────────────────────────────────────────
new_lib() {
  rm -rf "$LIB" "$STATE"; : > "$CALLS"
  mkdir -p "$LIB/tests" "$STATE"
  printf '1.0.0\n' > "$LIB/VERSION"
  cp "$REPO_ROOT/lock.sh" "$LIB/lock.sh"
  cat > "$LIB/sweep-issues.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --count) echo "count $*" >> "$CALLS"; printf 'alpha: %s\nbeta: 0\n' "${STUB_COUNT:-2}" ;;
  --resolve) echo "resolve $2 $4 $5" >> "$CALLS" ;;
  --note) echo "note $2 $4 $5" >> "$CALLS" ;;
  --left) [ -n "${STUB_LEFT:-}" ] && printf '%s\n' "$STUB_LEFT" ;;
esac
STUB
  printf '#!/usr/bin/env bash\necho deployed >> "$CALLS"\n' > "$LIB/deploy-all.sh"
  chmod +x "$LIB"/*.sh
  git -C "$LIB" init -q
  printf 'LIBRARY-LOCK.md\n' > "$LIB/.git/info/exclude"
  git -C "$LIB" add -A && git -C "$LIB" -c user.name=t -c user.email=t@t commit -qm init
}

# The stand-in session: records how it was started, checks the lock is its
# own, commits a change to $STUB_TOUCH, and reports it the way the prompt asks.
cat > "$FIX/claude" <<'STUB'
#!/usr/bin/env bash
{ echo "claude unattended=${LV_UNATTENDED:-} $*" | head -c 200; echo; } >> "$CALLS"
./lock.sh status >/dev/null 2>&1; echo "lock-status $?" >> "$CALLS"
for a in "$@"; do case "$a" in *--upstream*NEVER*|*NEVER\ pass\ --upstream*) echo "told-no-upstream" >> "$CALLS" ;; esac; done
for a in "$@"; do case "$a" in *"./sweep-issues.sh --sweepable"*) echo "told-sweepable" >> "$CALLS" ;; esac; done
for a in "$@"; do case "$a" in *"SWEEP_LEFT <issue-id> <client> <needs-operator|not-library|unsure>"*) echo "told-class" >> "$CALLS" ;; esac; done
[ -n "${STUB_TOUCH:-}" ] || { echo "nothing to do"; [ -n "${STUB_LEFT_LINES:-}" ] && printf '%s\n' "$STUB_LEFT_LINES"; exit 0; }
mkdir -p "$(dirname "$STUB_TOUCH")"; echo fix >> "$STUB_TOUCH"
git add -A && git -c user.name=t -c user.email=t@t commit -qm "fix(x): LVI-001"
echo "SWEEP_FIXED LVI-001 alpha $(git rev-parse --short HEAD)"
echo "SWEEP_FIXED LVI-009 alpha $(git rev-parse --short HEAD~1)"
[ -n "${STUB_LEFT_LINES:-}" ] && printf '%s\n' "$STUB_LEFT_LINES"
STUB
chmod +x "$FIX/claude"
export LV_SWEEP_CLAUDE="$FIX/claude" LV_RACK_SUITE="exit 0"

echo "── count ──"
new_lib
ck "the open issues of every client, summed" "$("$SWEEP" count "$LIB")" "2"
has "counting only the ones a sweep may take" "$(grep '^count' "$CALLS")" "--count --sweepable"

echo "── a sweep that fixes, deploys and resolves ──"
STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "it exits 0" "$rc" "0"
has "the session runs unattended, unprompted, under the baseline settings" \
  "$(grep '^claude' "$CALLS")" "unattended=1 -p --dangerously-skip-permissions --settings $STATE/settings.json"
ck "the lock is the session's own while it runs" "$(grep '^lock-status' "$CALLS")" "lock-status 2"
ck "it is told never to read the upstream list" "$(grep -c told-no-upstream "$CALLS")" "1"
ck "the settings name the baseline guard, failing closed" \
  "$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1]))["hooks"]["PreToolUse"][0]; print(c["matcher"], "lv-guard-baseline.sh" in c["hooks"][0]["command"], c["hooks"][0]["command"].endswith("exit 2"))' "$STATE/settings.json")" \
  "* True True"
ck "a green suite deploys" "$(grep -c '^deployed' "$CALLS")" "1"
has "the fix is resolved against its commit" "$(grep '^resolve' "$CALLS")" "resolve LVI-001 alpha fixed in v1.0.0"
ck "a fix citing a commit from before the sweep is not resolved" "$(grep -c 'resolve LVI-009' "$CALLS")" "0"
has "the result line" "$(cat "$STATE/result")" "fixed 1 · left 2 · deployed v1.0.0"
ck "the lock is released" "$([ -f "$LIB/LIBRARY-LOCK.md" ] && echo held || echo free)" "free"
ck "no pid is left behind" "$([ -f "$STATE/pid" ] && echo yes || echo no)" "no"
ck "nothing is left pending" "$([ -f "$STATE/pending" ] && echo yes || echo no)" "no"

echo "── what a sweep leaves is written onto the issue (LVI-051) ──"
new_lib
STUB_LEFT_LINES="$(printf '%s\n' \
  'SWEEP_LEFT LVI-041 coord needs-operator Should the rack page or the skill own it?' \
  'SWEEP_LEFT LVI-041 coord needs-operator Should the rack page or the skill own it?' \
  'SWEEP_LEFT LVI-002 gamma not-library the csproj pins a missing SDK' \
  'SWEEP_LEFT LVI-007 beta could not reproduce' \
  'SWEEP_LEFT LVI-001 alpha unsure fixed after all')" \
  "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "the session is told to list with --sweepable" "$(grep -c told-sweepable "$CALLS")" "1"
ck "and to give each left fault a class" "$(grep -c told-class "$CALLS")" "1"
ck "a needs-operator fault is noted with its question" \
  "$(grep -c '^note LVI-041 coord needs-operator: Should the rack page or the skill own it?$' "$CALLS")" "1"
ck "a not-library fault keeps its class" "$(grep -c '^note LVI-002 gamma not-library: the csproj pins a missing SDK$' "$CALLS")" "1"
ck "a line with no known class is noted as unsure" "$(grep -c '^note LVI-007 beta unsure: could not reproduce$' "$CALLS")" "1"
ck "each issue and client is noted once" "$(grep -c '^note' "$CALLS")" "4"
new_lib
STUB_LEFT_LINES='SWEEP_LEFT LVI-001 alpha unsure half of it' STUB_TOUCH=scripts/v2.00/lv-foo.sh \
  "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "an issue the same sweep fixed for that client is not noted" "$(grep -c '^note' "$CALLS")" "0"
STUB_LEFT="$(printf 'coord\tLVI-041\tneeds-operator\t2026-11-16T00:00:00Z\tWhich?\ngamma\tLVI-002\tnot-library\t2026-11-16T00:00:00Z\tcsproj')"
export STUB_LEFT
ck "left lists what waits on an answer" "$("$SWEEP" left "$LIB" | cut -f2 | tr '\n' ' ')" "LVI-041 LVI-002 "
ck "decide counts the needs-operator ones" "$("$SWEEP" decide "$LIB")" "1"

echo "── a fix to a guard file is committed, never deployed ──"
new_lib
STUB_TOUCH=deploy-all.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "no deploy" "$(grep -c '^deployed' "$CALLS")" "0"
ck "no resolve" "$(grep -c '^resolve' "$CALLS")" "0"
has "the board is told to hold it for review" "$(cat "$STATE/result")" "held for review — guard files changed: deploy-all.sh"
ck "the fix waits in pending" "$(cut -f1,2 "$STATE/pending")" "LVI-001	alpha"
"$SWEEP" resolve-pending "$LIB" "$STATE" >/dev/null 2>&1
has "the operator's deploy resolves it" "$(grep '^resolve' "$CALLS")" "resolve LVI-001 alpha"
ck "and empties pending" "$([ -f "$STATE/pending" ] && echo yes || echo no)" "no"

echo "── a red suite holds ──"
new_lib
LV_RACK_SUITE="exit 1" STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "no deploy" "$(grep -c '^deployed' "$CALLS")" "0"
has "held for review" "$(cat "$STATE/result")" "held for review — the suite is red"

echo "── a red suite keeps what failed (LVI-061) ──"
new_lib
printf 'echo "  ok   fine"\n' > "$LIB/tests/a.sh"
printf 'echo "  ok   one"; printf "  \\033[31m✗\\033[0m the thing broke\\n"; echo "  FAIL other thing"; exit 1\n' > "$LIB/tests/b.sh"
printf 'echo "no markers here"; echo "last words"; exit 2\n' > "$LIB/tests/c.sh"
git -C "$LIB" add -A && git -C "$LIB" -c user.name=t -c user.email=t@t commit -qm tests
mkdir -p "$STATE/logs"; printf '%s\n' "$STATE/logs/R.log" > "$STATE/latest"
out=$(LV_RACK_SUITE= STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" 2>&1)
has "still held" "$(cat "$STATE/result")" "held for review — the suite is red"
has "the red test is named" "$out" "FAILED tests/b.sh"
has "with its ✗ line, colour stripped" "$out" "    | ✗ the thing broke"
has "and its FAIL line" "$out" "    | FAIL other thing"
case "$out" in *"| ok   one"*) bad "a passing line is not quoted" ;; *) ok "a passing line is not quoted" ;; esac
has "a red test with no marks shows its last lines" "$out" "    | last words"
case "$out" in *"FAILED tests/a.sh"*) bad "a green test is not named" ;; *) ok "a green test is not named" ;; esac
has "the full output is kept beside the run's log" "$(cat "$STATE/logs/R.suite/b.out" 2>/dev/null)" "the thing broke"
ck "for every test, green ones too" "$(ls "$STATE/logs/R.suite" 2>/dev/null | tr '\n' ' ')" "a.out b.out c.out "
has "and the run log says where" "$out" "(full output: $STATE/logs/R.suite/b.out)"

echo "── refusals ──"
new_lib
STUB_COUNT=0 "$SWEEP" start "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "no open issues: refused" "$rc" "3"
echo dirty >> "$LIB/VERSION"
out=$("$SWEEP" start "$LIB" "$STATE" 2>&1); rc=$?
ck "a dirty library: refused" "$rc" "3"
has "and says why" "$out" "uncommitted changes"
git -C "$LIB" checkout -q VERSION
sleep 600 & LIVE=$!
(cd "$LIB" && LV_SESSION_PID="$LIVE" ./lock.sh take other "mid-edit" >/dev/null 2>&1)
out=$("$SWEEP" start "$LIB" "$STATE" 2>&1); rc=$?
ck "a held lock: refused" "$rc" "3"
has "and says why" "$out" "LIBRARY-LOCK.md is held"
ck "no session was started" "$(grep -c '^claude' "$CALLS")" "0"
rm -f "$LIB/LIBRARY-LOCK.md"
LV_SWEEP_CLAUDE="$FIX/no-such-claude" "$SWEEP" start "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "no claude on PATH: refused" "$rc" "3"
printf '%s\n' "$LIVE" > "$STATE/pid"
out=$("$SWEEP" start "$LIB" "$STATE" 2>&1); rc=$?
ck "one sweep at a time" "$rc:$(printf '%s' "$out" | grep -c 'already running')" "3:1"
rm -f "$STATE/pid"

echo "── start detaches, and the board reads it ──"
new_lib
STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" start "$LIB" "$STATE" >/dev/null 2>&1; rc=$?
ck "start returns at once" "$rc" "0"
for _ in $(seq 1 50); do [ -f "$STATE/result" ] && break; sleep 0.2; done
has "the detached run finishes on its own" "$(cat "$STATE/result" 2>/dev/null)" "deployed v1.0.0"
has "and its log is where latest says" "$(cat "$(cat "$STATE/latest")")" "== result: fixed 1"

export LV_SWEEP_STATE="$STATE" LV_LIBRARY_DIR="$LIB" LV_RACK_LIB=1
export LV_DEPLOYMENTS="$FIX/deployments.txt" LV_BOARD_CACHE="$FIX/cache"
: > "$LV_DEPLOYMENTS"
# shellcheck disable=SC1090
source "$BOARD"
refresh_library_count
has "the library line offers to heal the count" "$(library_sweep_line)" "heal (2)"
has "and the last result" "$(library_sweep_line)" "last sweep: fixed 1 · left 2 · deployed v1.0.0"
ck "the refresh records how many need the operator" "$(cat "$STATE/decide")" "1"
has "the line shows decide (N) first" "$(library_sweep_line)" " · decide (1) · heal (2) · last sweep:"
has "selected, the cursor is on decide" "$(library_sweep_line SEL)" " · SELdecide (1)"
out=$(decide_list)
has "the listing names the id, client and question" "$out" "LVI-041  coord  left 2026-11-16
      Which?"
has "the other classes are listed apart" "$out" "also left, waiting on an answer:
  LVI-002  gamma  not-library — csproj"
has "and it says how to answer" "$out" "Answer under the **Sweep:** line"
case "$out" in *"LVI-002  gamma  left"*) bad "a not-library issue is not a decision" ;; *) ok "a not-library issue is not a decision" ;; esac
out=$(LV_SWEEP_STATE="$STATE" LV_LIBRARY_DIR="$LIB" LV_RACK_LIB= bash "$BOARD" --decide 2>&1)
has "--decide prints the same listing" "$out" "DECIDE  1 issue(s)"
has "with the question" "$out" "Which?"
unset STUB_LEFT; refresh_library_count
case "$(library_sweep_line)" in *decide*) bad "nothing left: no decide" ;; *) ok "nothing left: no decide" ;; esac
has "and decide_list says so" "$(decide_list)" "nothing waits on a decision"
printf '%s\n' "$LIVE" > "$STATE/pid"
has "a live sweep reads as hearts" "$(library_sweep_line)" "♡♡♡"
heart_i=2
has "which fill a tick at a time" "$(library_sweep_line)" "♥♥♡"
case "$(library_sweep_line)" in *"heal ("*) bad "no heal offer while one runs" ;; *) ok "no heal offer while one runs" ;; esac
rm -f "$STATE/pid"; heart_i=0

echo "── restart required ──"
COORD_DIR="$FIX/coord"; mkdir -p "$COORD_DIR/.claude"
printf '1.0.0\n' > "$COORD_DIR/.claude/workflow-version"; BOARD_V=1.0.0
case "$(library_sweep_line)" in *restart*) bad "same version: no restart" ;; *) ok "same version: no restart" ;; esac
printf '1.0.1\n' > "$COORD_DIR/.claude/workflow-version"
has "a newer deploy: restart required" "$(library_sweep_line)" "restart required"
case "$(library_sweep_line)" in *"heal ("*) bad "restart comes before heal" ;; *) ok "restart comes before heal" ;; esac
BOARD_V=1.0.1

echo "── settings and auto-heal ──"
RACK_SETTINGS="$FIX/rack-settings"
ck "unset reads empty" "$(setting_get auto_heal)" ""
setting_set auto_heal on; setting_set other x; setting_set auto_heal off
ck "set rewrites one key" "$(setting_get auto_heal):$(setting_get other):$(grep -c . "$RACK_SETTINGS")" "off:x:2"
case "$(library_sweep_line)" in *auto-heal*) bad "off: not on the line" ;; *) ok "off: not on the line" ;; esac
# A stand-in sweep script: records starts, never runs anything.
mkdir -p "$FIX/here"
printf '#!/usr/bin/env bash\necho "start $*" >> "%s"\n' "$CALLS" > "$FIX/here/lv-library-sweep.sh"
chmod +x "$FIX/here/lv-library-sweep.sh"
REAL_HERE="$HERE"; HERE="$FIX/here"; : > "$CALLS"; rm -f "$STATE/auto-last"
maybe_auto_heal
ck "off: never starts" "$(grep -c '^start' "$CALLS")" "0"
setting_set auto_heal on
has "on: shown on the line" "$(library_sweep_line)" "auto-heal"
maybe_auto_heal
ck "on, issues open: starts one" "$(grep -c '^start' "$CALLS")" "1"
maybe_auto_heal
ck "inside the cool-down: no second" "$(grep -c '^start' "$CALLS")" "1"
printf '1 2\n' > "$STATE/auto-last"; printf 'fixed 0 · left 2\n' > "$STATE/result"
maybe_auto_heal
ck "fixed nothing, same count: no retry" "$(grep -c '^start' "$CALLS")" "1"
printf '3\n' > "$STATE/lvis"
maybe_auto_heal
ck "the count moved: retries" "$(grep -c '^start' "$CALLS")" "2"
printf '1 3\n' > "$STATE/auto-last"; printf 'fixed 1 · left 3 · held for review — x\n' > "$STATE/result"
maybe_auto_heal
ck "held for review: never" "$(grep -c '^start' "$CALLS")" "2"
has "and the line still reports the hold" "$(library_sweep_line)" "held for review"
# The held fixes went out by a later deploy (by hand, or U): the hold is history (LVI-053).
touch -t 202601010000 "$STATE/result"; touch "$COORD_DIR/.claude/workflow-version"
case "$(library_sweep_line)" in *"held for review"*) bad "a deploy after the hold: line drops it" ;; *) ok "a deploy after the hold: line drops it" ;; esac
printf '1 3\n' > "$STATE/auto-last"
maybe_auto_heal
ck "and auto-heal is no longer held off" "$(grep -c '^start' "$CALLS")" "3"
printf '0\n' > "$STATE/lvis"; rm -f "$STATE/result" "$STATE/auto-last"
maybe_auto_heal
ck "nothing open: never" "$(grep -c '^start' "$CALLS")" "3"
HERE="$REAL_HERE"

echo "── publish after a deploy ──"
new_lib
LV_SWEEP_PUBLISH='echo pub >> "$CALLS"' STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "a deploy publishes" "$(grep -c '^pub' "$CALLS")" "1"
has "and says so" "$(cat "$STATE/result")" "deployed v1.0.0 · published"
new_lib
LV_SWEEP_PUBLISH='exit 1' STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
has "a failed publish is a note, the deploy stands" "$(cat "$STATE/result")" "deployed v1.0.0 · publish failed (exit 1)"
new_lib
LV_SWEEP_PUBLISH='exit 3' STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "no publisher: nothing said" "$(sed 's/.*deployed v1.0.0//' "$STATE/result")" ""
new_lib
LV_SWEEP_PUBLISH='echo pub >> "$CALLS"' LV_RACK_SUITE="exit 1" STUB_TOUCH=scripts/v2.00/lv-foo.sh "$SWEEP" run "$LIB" "$STATE" >/dev/null 2>&1
ck "a held sweep never publishes" "$(grep -c '^pub' "$CALLS")" "0"
LV_PACKS= out=$("$SCRIPTS/lv-hook.sh" library-publish "$LIB" 2>&1); rc=$?
ck "the default publisher publishes nothing" "$rc" "3"

[ "$fails" -eq 0 ] && { echo "all passed"; exit 0; }
echo "$fails failed"; exit 1
