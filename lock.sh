#!/usr/bin/env bash
# lock.sh — one writer at a time in the library.
#
# This repo now has more than one session editing it. A session rooted here
# works it directly; an coordinator session reaches in from ~/dev/coordinator when a harness
# fault it is diagnosing across the portfolio turns out to live in the library.
# Both edit the same scripts/, and the loser of that race finds its work
# half-overwritten, or deploys a tree it never read.
#
# So the repo carries a switch at its top level. LIBRARY-LOCK.md exists while
# somebody is working here and does not exist otherwise — presence IS the
# state, because a file you can see in `ls` is harder to miss than a status
# line inside one. It is gitignored: both sessions are on the same disk, and a
# lock that travels in a commit is a lock that arrives as a merge conflict.
#
#   ./lock.sh status                    who holds it, and whether they're alive
#   ./lock.sh take <holder> "<why>"     take it; refused if somebody live holds it
#   ./lock.sh release                   release the one you took
#   ./lock.sh take <holder> "<why>" --steal
#                                       take it from a holder that is gone
#
# <holder> is a name for the session, not a person: `coordinator` or `library` are the
# two that exist today. It is what the other side reads to know whose work it
# would be walking into.
#
# Exit codes — `status` is meant to be branched on:
#   0  free, or (for take/release) done
#   1  held by another live session
#   2  held by you
#   3  held, but the holding process is gone — stale, see --steal
#   4  usage error
#
# THE LOCK IS ADVISORY AND THAT IS THE POINT
#
# Nothing enforces it. It cannot: the writers are agents and humans with a
# shell, not processes the repo controls. What it does is make a collision
# visible BEFORE it happens, at the one moment either side is cheap to redirect
# — which is the whole of what was missing. An unenforced switch that both
# sides are told to read beats an enforced one neither side can take.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")" && pwd)"
# WF_LOCK_FILE points at an alternate lock — used by the test suite, so testing
# the switch never takes the real one out from under whoever is holding it.
LOCK="${WF_LOCK_FILE:-$LIB_ROOT/LIBRARY-LOCK.md}"

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; DIM='\033[2m'; NC='\033[0m'
[ -t 1 ] || { BOLD=''; GREEN=''; YELLOW=''; RED=''; DIM=''; NC=''; }

usage() {
  cat >&2 <<'USAGE'
lock.sh — one writer at a time in the library.

  ./lock.sh status                          who holds it, and whether they're alive
  ./lock.sh take <holder> "<why>"           take it; refused if somebody live holds it
  ./lock.sh take <holder> "<why>" --steal   take it from a holder that is gone
  ./lock.sh release                         release the one you took

<holder> names the session, not a person — `coordinator` and `library` are the two that
exist today. It is what the other side reads to know whose work it would be
walking into.

Exit: 0 free/done · 1 held by another live session · 2 held by you ·
      3 stale (holder gone) · 4 usage.
USAGE
  exit 4
}

# The session, not the shell that ran us. A tool call is a short-lived bash
# whose PID means nothing a minute later; the session above it is what actually
# holds the work. Same walk wf_session_pid does in the deployed harness.
session_pid() {
  local pid name parent
  if [ -n "${WF_SESSION_PID:-}" ]; then printf '%s' "$WF_SESSION_PID"; return 0; fi
  if [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    printf '%s' "$CLAUDE_PID"; return 0
  fi
  pid=$PPID
  for _ in 1 2 3 4 5; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    [ -n "$name" ] || break
    name=${name##*/}; name=${name#-}
    case "$name" in
      bash|sh|zsh|dash|ksh|fish)
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$parent" ] && [ "$parent" -gt 1 ] 2>/dev/null || break
        pid="$parent" ;;
      *) break ;;
    esac
  done
  printf '%s' "$pid"
}

# IDENTITY, NOT LIVENESS. A PID is reusable, so `kill -0` answering yes does not
# prove the answerer is the session that took the lock — the same reason claims
# carry one (wf_proc_start in wf-orch-lib.sh). Nothing parses the value; it is
# only ever compared against another reading from the same `ps`.
proc_start() {
  [ -n "${1:-}" ] || return 0
  ps -o lstart= -p "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//'
}

field() { grep -m1 "^\*\*$1:\*\* " "$LOCK" 2>/dev/null | sed "s/^\*\*$1:\*\* //"; }
started_field() { grep -m1 '^<!-- pid-start: ' "$LOCK" 2>/dev/null | sed 's/^<!-- pid-start: //; s/ -->$//'; }

# 0 free · 1 held by someone else · 2 held by us · 3 stale
probe() {
  [ -f "$LOCK" ] || return 0
  local pid started now
  pid=$(field "Session PID" | tr -cd '0-9')
  started=$(started_field)
  [ "$pid" = "$(session_pid)" ] && return 2
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null || return 3
  # A recycled PID is somebody else's process wearing the holder's number. With
  # no recorded start time — a lock written by hand — liveness is all we have.
  if [ -n "$started" ]; then
    now=$(proc_start "$pid")
    [ "$now" = "$started" ] || return 3
  fi
  return 1
}

report() {
  local rc=$1
  case "$rc" in
    0) printf "${GREEN}LIBRARY-LOCK: free${NC} — nobody is working the library.\n" ;;
    2) printf "${GREEN}LIBRARY-LOCK: yours${NC} — taken %s for: %s\n" "$(field Since)" "$(field Why)" ;;
    1) printf "${RED}${BOLD}LIBRARY-LOCK: HELD by '%s'${NC} (PID %s, since %s)\n  Why: %s\n  On:  %s @ %s\n\n  ${BOLD}Do not edit scripts/, skills/, templates/, tests/ or run ./deploy-all.sh.${NC}\n  Say so and wait, or ask the operator to have '%s' release it.\n" \
         "$(field Holder)" "$(field 'Session PID')" "$(field Since)" "$(field Why)" "$(field Branch)" "$(field HEAD)" "$(field Holder)" ;;
    3) printf "${YELLOW}LIBRARY-LOCK: STALE${NC} — '%s' took it %s and that session is gone.\n  Why: %s\n\n  Tell the operator before taking it: the work it names may be half-applied.\n  Then: ./lock.sh take <holder> \"<why>\" --steal\n" \
         "$(field Holder)" "$(field Since)" "$(field Why)" ;;
  esac
}

cmd="${1:-status}"

case "$cmd" in
  status|--check|-s)
    probe; rc=$?
    report $rc
    exit $rc
    ;;

  take)
    holder="${2:-}"; why="${3:-}"; steal=false
    case "${4:-}" in --steal) steal=true ;; "") ;; *) usage ;; esac
    [ -n "$holder" ] && [ -n "$why" ] || {
      echo "lock.sh: take needs a holder name and a reason" >&2; usage; }

    probe; rc=$?
    case "$rc" in
      1) report 1 >&2; exit 1 ;;
      3) if ! $steal; then report 3 >&2; exit 3; fi ;;
      2) # Retaking your own lock rewrites the reason rather than refusing:
         # a session's work here moves on, and a lock naming what it was doing
         # an hour ago tells the other side less than nothing.
         : ;;
    esac

    pid=$(session_pid)
    branch=$(git -C "$LIB_ROOT" branch --show-current 2>/dev/null || echo '?')
    head=$(git -C "$LIB_ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')
    tmp="$LOCK.tmp.$$"
    cat > "$tmp" <<EOF
# LIBRARY LOCK — HELD

**Holder:** $holder
**Session PID:** $pid
**Since:** $(date '+%Y-%m-%d %H:%M:%S %z')
**Branch:** $branch
**HEAD:** $head
**Why:** $why

<!-- pid-start: $(proc_start "$pid") -->

While this file exists the library has one writer, and it is not you unless the
holder above names your session. Do not edit \`scripts/\`, \`skills/\`,
\`templates/\`, \`tests/\`, \`install.sh\` or \`deploy-all.sh\`, and do not run
\`./deploy-all.sh\` — a deploy publishes whatever is on disk, including the
holder's half-finished edits, into all nine clients.

Reading, reviewing, sweeping (\`./sweep-issues.sh\`, \`./check-profiles.sh\`) and
filing are always fine. So is anything under \`bugs/\`.

Released with \`./lock.sh release\`. If the holding session is gone, that is a
stale lock — \`./lock.sh status\` says so, and says what to do about it.
EOF
    mv "$tmp" "$LOCK"
    $steal && [ "$rc" = "3" ] && printf "${YELLOW}stole a stale lock${NC}\n"
    printf "${GREEN}LIBRARY-LOCK taken${NC} by '%s' — %s\n" "$holder" "$why"
    printf "${DIM}Release it with ./lock.sh release when you stop working here.${NC}\n"
    exit 0
    ;;

  release)
    probe; rc=$?
    case "$rc" in
      0) echo "lock.sh: nothing to release — the library is not locked."; exit 0 ;;
      1) report 1 >&2
         echo "lock.sh: refusing to release another live session's lock." >&2; exit 1 ;;
    esac
    holder=$(field Holder)
    rm -f "$LOCK"
    printf "${GREEN}LIBRARY-LOCK released${NC} (was '%s').\n" "$holder"
    exit 0
    ;;

  -h|--help|help) usage ;;
  *) echo "lock.sh: unknown command '$cmd'" >&2; usage ;;
esac
