#!/usr/bin/env bash
# lv-rack-drill.test.sh — exercise the cell drill-down against a stub
# client, never against a real project.
#
#   tests/rack/drill.test.sh
#
# The drill-down is a TUI: it owns the screen and reads single keypresses, so
# it cannot be tested by running the board and piping input at it. Instead the
# tool is SOURCED with LV_RACK_LIB=1 — which loads every function and
# stops before drawing anything — and the functions are then called directly
# with a keystroke script on stdin.
#
# The fixture is one fake client whose scripts/wf-exec.sh answers the two
# calls the browser makes: `wf-board-drill.sh row running` (a list with one
# `list` item) and `wf-board-drill.sh worker ...` (a list with one `log` item
# pointing at a real file). That covers the whole contract — a level that
# descends, and a leaf that opens a file — without a harness, a registry or a
# worker.
#
# Exit 0 if every assertion passes, 1 otherwise.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOARD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}/lv-rack.sh"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/wf-drill-test.XXXXXX")"
cleanup() { rm -rf "$FIX"; }
trap cleanup EXIT

fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }
says() { # says <label> <haystack-file> <needle>
  if grep -qF "$3" "$2"; then ok "$1"; else bad "$1 — expected to find: $3"; fi
}

# ── Fixture: one client, one stub harness ───────────────────────────────
CLIENT="$FIX/alpha"
mkdir -p "$CLIENT/scripts" "$CLIENT/.claude/orchestrator/logs"
LOGFILE="$CLIENT/.claude/orchestrator/logs/PLN-001-implement-20260917-120000.log"
printf 'worker line one\nworker line two\nTHE-LAST-LINE\n' > "$LOGFILE"

cat > "$CLIENT/scripts/wf-exec.sh" <<STUB
#!/usr/bin/env bash
# Stub dispatcher: only the drill calls lv-rack actually makes.
[ "\$1" = "wf-board-drill.sh" ] || exit 2
shift
case "\$1 \${2:-}" in
  "row running")
    printf 'implement   PLN-001    3m  pid 999\tlist\tworker 1-implement PLN-001\n' ;;
  "worker 1-implement")
    printf 'live log — PLN-001-implement-20260917-120000.log\tlog\t$LOGFILE\n' ;;
  "row gates")
    exit 1 ;;
  *) echo "stub: no such node \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$CLIENT/scripts/wf-exec.sh"

# ── Load the tool's functions without drawing a board ────────────────────
LV_RACK_LIB=1
# Each run gets its own cache, so a test never reads a level another run (or
# the operator's own board) left behind — and never writes into theirs.
LV_BOARD_CACHE="$FIX/cache"
export LV_RACK_LIB LV_BOARD_CACHE
# shellcheck source=../bin/lv-rack
source "$BOARD"

# Stand in for what collect() would have filled: one project, all metrics.
names=("alpha"); paths=("$CLIENT"); statuses=("ok")
f_daemon=("off"); f_running=("1")
f_gates=("0"); f_gates_stuck=("0"); f_gates_blocked=("0")
f_draft=("0"); f_ready=("0"); f_active=("1"); f_verify=("0"); f_testing=("0")
f_complete=("7"); f_abandoned=("0")
f_registry=("clean"); f_attn=(""); f_release=("-"); f_deploy=("-")
f_ideas=("2"); f_ideas_drift=("0"); f_ts=("$(date +%s)")

echo "lv-rack drill-down"

# ── 1. The rows menu is built from the numbers already on screen ────────
OUT="$FIX/rows.txt"
drill_rows_lines 0 > "$OUT"
says "rows menu lists every grid row"      "$OUT" "running    1"
says "rows menu carries the next argv"     "$OUT" "row running"
says "rows menu shows the registry column" "$OUT" "registry   clean"
if [ "$(grep -c . "$OUT")" = "${#ROW_LABELS[@]}" ]; then
  ok "rows menu has one line per ROW_LABELS entry"
else
  bad "rows menu line count ($(grep -c . "$OUT")) != ROW_LABELS (${#ROW_LABELS[@]})"
fi

# ── 2. Enter descends: row → worker → log, and Esc pops back out ─────────
# Keys: enter (open the one worker), enter (open its log), esc (leave the
# pager), esc (back to the row), esc (back out of the browser entirely).
OUT="$FIX/browse.txt"
printf '\n\n\x1b\x1b\x1b' | drill_browse 0 "running" "row running" > "$OUT" 2>&1
says "level 1 lists the running worker"  "$OUT" "implement   PLN-001"
says "level 2 offers the live log"       "$OUT" "live log —"
says "the log's own content is shown"    "$OUT" "THE-LAST-LINE"
says "the pager offers follow for a log" "$OUT" "f follow"
says "breadcrumb names the project"      "$OUT" "alpha"

# ── 3. An empty node says so rather than showing a blank pane ───────────
OUT="$FIX/empty.txt"
printf '\x1b' | drill_browse 0 "gates" "row gates" > "$OUT" 2>&1
says "an empty row says nothing is there" "$OUT" "nothing here right now"

# ── 4. A client whose harness is too old to know the node ───────────────
OUT="$FIX/old.txt"
printf '\x1b' | drill_browse 0 "ideas" "row ideas" > "$OUT" 2>&1
says "an unknown node reports the harness" "$OUT" "needs a newer harness"

# ── 5. The cell cursor highlights exactly one cell ───────────────────────
sel_idx=0; sel_row=1     # ROW_LABELS[1] = running
if sel_cell "running" 0 && ! sel_cell "gates" 0; then
  ok "sel_cell matches only the selected row"
else
  bad "sel_cell matched the wrong cell"
fi
sel_idx=""; sel_row=""
if ! sel_cell "running" 0; then
  ok "sel_cell is off when no cursor is set (piped board)"
else
  bad "sel_cell highlighted a cell with no cursor"
fi

# ── 6. Age buckets: the tint is a function of the snapshot's own time ────
# Not of when the screen was last painted — a repaint of four-minute-old
# numbers has to stay dark grey, and an unknown age has to read as old rather
# than as fresh, which is the only direction in which being wrong is safe.
NOW=$(date +%s)
check_bucket() { # <label> <expected> <ts>
  local got; got=$(age_bucket "$3" "$NOW")
  if [ "$got" = "$2" ]; then ok "$1"; else bad "$1 — expected bucket $2, got $got"; fi
}
check_bucket "just collected is fresh"          0 "$NOW"
check_bucket "under 30s is still fresh"         0 "$((NOW - 29))"
check_bucket "past 30s starts aging"            1 "$((NOW - 31))"
check_bucket "past 45s is stale"                2 "$((NOW - 46))"
check_bucket "minutes old is stale"             2 "$((NOW - 600))"
check_bucket "a missing timestamp reads as old" 2 "0"
check_bucket "an unparseable one reads as old"  2 "not-a-time"
# The test runs with stdout redirected, which is the board's own no-colour
# path — so what there is to check here is that it emits no escapes at all.
# A --plain or piped board that leaked a tint would corrupt every consumer
# that reads this output as text.
if [ -n "$AGE0" ]; then
  if [ "$(age_color "$NOW" "$NOW")" != "$(age_color "$((NOW - 600))" "$NOW")" ]; then
    ok "fresh and stale are drawn differently"
  else
    bad "fresh and stale render in the same colour"
  fi
elif [ -z "$(age_color "$NOW" "$NOW")$(age_color 0 "$NOW")" ]; then
  ok "a colourless board emits no tint escapes"
else
  bad "a colourless board still emitted a tint escape"
fi

# ── 7. The grid snapshot round-trips, escaping and all ──────────────────
# Project names and gate prose come off a client verbatim; a quote or a
# backslash in one of them must not be able to corrupt the cache (and with
# it every later cold start), which is why jq writes this file rather than
# printf.
if $HAVE_JQ; then
  names=("alpha" 'he said "hi"\back'); paths=("$CLIENT" "$FIX/b")
  statuses=("ok" "ok"); f_daemon=("off" "running"); f_running=("1" "0")
  f_gates=("0" "2"); f_gates_stuck=("0" "1"); f_gates_blocked=("0" "0")
  f_draft=("0" "0"); f_ready=("0" "0"); f_active=("1" "0"); f_verify=("0" "0")
  f_testing=("0" "0"); f_complete=("7" "3"); f_abandoned=("0" "0")
  f_registry=("clean" "clean"); f_attn=("" "12!,13"); f_release=("-" "4")
  f_deploy=("-" "0"); f_ideas=("2" "0"); f_ideas_drift=("0" "0")
  f_ts=("$((NOW - 5))" "$((NOW - 400))")
  snapshot_save

  names=(); paths=(); statuses=(); f_ts=()
  if snapshot_load; then
    ok "a saved grid loads back"
  else
    bad "a saved grid would not load back"
  fi
  [ "${#names[@]}" = "2" ] && ok "both projects survive the round trip" \
                           || bad "round trip returned ${#names[@]} projects"
  [ "${names[1]}" = 'he said "hi"\back' ] && ok "quotes and backslashes survive" \
                           || bad "name came back as [${names[1]:-}]"
  [ "${f_attn[1]}" = "12!,13" ] && ok "the attn field survives" \
                           || bad "attn came back as [${f_attn[1]:-}]"
  [ "${f_attn[0]}" = "" ] && ok "an empty field stays empty, not shifted" \
                           || bad "empty attn came back as [${f_attn[0]:-}]"
  [ "${f_ts[0]}" = "$((NOW - 5))" ] && ok "each project keeps its own collection time" \
                           || bad "ts came back as [${f_ts[0]:-}]"
  # The point of storing the time: a snapshot paints instantly AND paints its
  # real age, so a cold start is never mistaken for live numbers.
  [ "$(age_bucket "${f_ts[1]}" "$NOW")" = "2" ] && ok "a restored old column is still old" \
                           || bad "a 400s-old restored column did not read as stale"
else
  ok "no jq — snapshot tests skipped, board falls back to collecting"
fi

# ── 8. A revisited level paints from its cache, not from the client ─────
# Restore the single-project fixture, then make the stub refuse every call
# after the first. A level already visited must still show its items.
names=("alpha"); paths=("$CLIENT"); statuses=("ok")
f_daemon=("off"); f_running=("1"); f_gates=("0"); f_gates_stuck=("0"); f_gates_blocked=("0")
f_draft=("0"); f_ready=("0"); f_active=("1"); f_verify=("0"); f_testing=("0")
f_complete=("7"); f_abandoned=("0"); f_registry=("clean"); f_attn=("")
f_release=("-"); f_deploy=("-"); f_ideas=("2"); f_ideas_drift=("0"); f_ts=("$NOW")

if $HAVE_JQ; then
  CACHED=$(node_cache_file "$CLIENT" "row running")
  [ -s "$CACHED" ] && ok "visiting a level wrote its cache" \
                   || bad "no cache written for 'row running'"

  mv "$CLIENT/scripts/wf-exec.sh" "$FIX/wf-exec.sh.real"
  cat > "$CLIENT/scripts/wf-exec.sh" <<'DEAD'
#!/usr/bin/env bash
echo "wf-exec.sh: client is unreachable" >&2
exit 2
DEAD
  chmod +x "$CLIENT/scripts/wf-exec.sh"

  OUT="$FIX/cached.txt"
  printf '\x1b' | drill_browse 0 "running" "row running" > "$OUT" 2>&1
  says "a cached level still lists its items"   "$OUT" "implement   PLN-001"
  says "and says how old what it is showing is" "$OUT" "ago"

  mv -f "$FIX/wf-exec.sh.real" "$CLIENT/scripts/wf-exec.sh"
else
  ok "no jq — level cache tests skipped"
fi

# ── 9. An explicit refresh is the one thing that ignores the cache ──────
if $HAVE_JQ; then
  CACHED=$(node_cache_file "$CLIENT" "row running")
  printf 'r\x1b\x1b' | drill_browse 0 "running" "row running" > "$FIX/refreshed.txt" 2>&1
  says "r re-fetches rather than re-showing" "$FIX/refreshed.txt" "implement   PLN-001"
fi

# ── 10. A quiet keyboard is not a closed one ────────────────────────────
# Every polled screen (the drill browser, the file pager) leaves on key_eof.
# bash 3.2 — what macOS ships — reports a `read -t` expiry with the SAME
# exit 1 it reports EOF with, so taking that at face value made each poll
# tick read as a closed stdin: the level you had just opened was replaced by
# a full repaint of the grid one second later. Held-open-but-silent stdin
# must therefore read as a timeout, and a genuinely closed one still as EOF
# (or the same loops spin forever on it).
KFIFO="$FIX/quiet"
mkfifo "$KFIFO"
( exec 9>"$KFIFO"; sleep 6 ) &
holder=$!
quiet_eof=no
for _ in 1 2 3 4; do
  read_key qk 1 < "$KFIFO"
  [ "$key_rc" -eq 0 ] && continue          # a stray byte: not what's under test
  $key_eof && quiet_eof=yes
done
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
[ "$quiet_eof" = "no" ] && ok "a silent but open stdin polls rather than reading as EOF" \
                        || bad "an expired poll was reported as EOF — sub-screens bail to the board"

closed_eof=no
for _ in 1 2 3 4 5; do
  read_key qk 1 < /dev/null
  $key_eof && { closed_eof=yes; break; }
done
[ "$closed_eof" = "yes" ] && ok "a closed stdin still reports EOF" \
                          || bad "EOF went undetected — a polled screen would spin forever"

echo
if [ "$fails" -eq 0 ]; then
  echo "all assertions passed"
  exit 0
fi
echo "$fails assertion(s) failed"
exit 1
