#!/usr/bin/env bash
# lv-attempt-refund.sh <id> <role> <log> <rc>
#
# The worker started, and then nothing happened. Give the attempt back.
#
# THE GAP THIS CLOSES
#
# The attempt budget is charged at SPAWN, by the dispatcher, the moment
# lv-spawn.sh returns 0. That is the right moment for the thing it measures —
# N launches with no forward progress — and lv-spawn.sh already refuses to
# charge a launch that died before the worker started: it waits for a marker
# the `bash -c` writes as its first act, and exits 3 when it never appears
# (WFI-231, WFI-232).
#
# But the marker is written BEFORE `claude` runs, so it cannot distinguish a
# worker that started and worked from one that started and died on its first
# API call. client-d WFI-016: three consistency launches for PLN-016 at
# 21:16:44, 21:17:45 and 21:18:46 each produced a 161-byte log holding one
# line — "API Error: 500 Internal server error. This is a server-side issue,
# usually temporary — try again in a moment." The marker existed every time,
# so lv-spawn.sh reported a healthy spawn every time, attempts reached 3, and
# a `stuck` gate opened at 01:19:47Z asserting that consistency had run three
# times with no forward progress. Consistency had not run once. The plan was
# intact and the gate was answered `retry` by hand, with the counter deleted.
#
# WHY HERE
#
# This is the only code that knows. The dispatcher has moved on; the worker's
# own exit clause is the last thing standing that can see both `rc` and what
# the run actually produced. It already runs there, to log the exit event.
#
# WHAT IT WILL NOT REFUND
#
# A worker that ran and failed legitimately keeps its attempt — that is the
# budget working, and a plan that genuinely cannot be built should reach
# `stuck`. So the refund is narrow on purpose, and both halves must hold:
#
#   rc != 0                a successful run is never refunded, however short
#   no session happened    the log matches a transient transport failure AND
#                          is small enough that nothing else can be in it
#
# The size bound is what stops an hour-long run that hit a 500 on its last
# call from reading as a launch that never happened. A real worker's log is
# tens of kilobytes of tool traffic before it reaches any error at all.
#
# Exit 0 always. This is bookkeeping running inside a detached worker's exit
# path; nothing reads its status, and failing loudly here would only corrupt
# the exit event that follows it.

set -uo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

id="${1:-}" role="${2:-}" log="${3:-}" rc="${4:-0}"
[ -n "$id" ] && [ -n "$role" ] || exit 0

# A log larger than this had a session in it, whatever else it also had.
MAX_BYTES=4096

[ "$rc" = "0" ] && exit 0
[ -n "$log" ] && [ -f "$log" ] || exit 0

size=$(wc -c < "$log" 2>/dev/null | tr -d ' ')
[ "${size:-0}" -le "$MAX_BYTES" ] || exit 0

# Transient transport failures: the API refused the session, or the network
# never reached it. Anything the model itself said is out of scope — a refusal,
# a usage error, a bad prompt is a real run with a real answer, and it is
# charged.
grep -qiE 'API Error: (4(08|29)|5[0-9][0-9])|Internal server error|Overloaded|Service Unavailable|Bad Gateway|Gateway Time-?out|fetch failed|socket hang up|ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN' \
  "$log" 2>/dev/null || exit 0

ORCH="$(wf_orch_dir)" || exit 0
file="$ORCH/attempts/$id.$role"
n=$(wf_read1 "$file" 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac
[ "$n" -gt 0 ] || exit 0

n=$((n - 1))
if [ "$n" -gt 0 ]; then
  printf '%s\n' "$n" > "$file" 2>/dev/null || true
else
  rm -f "$file" 2>/dev/null || true
fi

why=$(head -1 "$log" 2>/dev/null | cut -c1-120)
wf_event refund "$id" "$role never reached a session — attempt refunded (now $n): ${why:-no output}" 2>/dev/null || true
exit 0
