#!/usr/bin/env bash
# lv-services.sh — the long-running things a project runs on the operator's machine: a web
# container and its tunnel, a worker that watches a folder, a dev stack. Declared once in
# levain.yml, broadcast while they run, and listed, started and stopped from the coordinator's
# rack across every project (lv-rack.sh, `v`).
#
#   lv-services.sh list                 the manifest, one TSV line per service
#   lv-services.sh status               one TSV line per running instance (or per service, down)
#   lv-services.sh worktrees            <path>\t<branch>, one per worktree, main's first
#   lv-services.sh start <id> [--checkout <path>]
#   lv-services.sh stop <id>
#   lv-services.sh console              open the project's own console (services_console:)
#   lv-services.sh guard <path>         exit 2 when a live service runs from <path>
#   lv-services.sh beacon up|beat|down <id> (--pid <pid> | --detached)
#
# ── WHY ────────────────────────────────────────────────────────────────────
#
# A client's worker once ran from a feature worktree, and nothing on any board showed it: it
# was found by hand, by pid, before that worktree could be removed. Another client grew its own
# board for the same processes, and the next client to need them had none. The services are
# the project's business; that they are running, and from which checkout, is the overseer's.
#
# ── THE MANIFEST ───────────────────────────────────────────────────────────
#
#   services:
#     web:
#       label: "Web + tunnel"
#       start: "tools/run-web.sh up"     # run from the chosen checkout
#       stop: "tools/run-web.sh down"    # or "signal": TERM to each live beacon's pid
#       window: true                     # start in a new Terminal window (it reads keys);
#                                        # the default when stop: is signal or absent
#       checkout: main                   # main (the default) | any
#       health: "http://127.0.0.1:8080/health"   # up while it answers 200-499
#       compose: "myapp-web"             # or: up while this compose project has containers;
#                                        # "myapp-web/cloudflared" narrows it to one compose service
#       heartbeat: 120                   # a beacon not refreshed for this long is stale
#       needs: "web"                     # ids that must be up before this one starts
#   services_console: "tools/board.sh"   # the project's own board, for what the rack does not do
#
# A service stopped by signal (stop: signal, or no stop:) is the process its start: runs, so
# it starts in a window unless the manifest says `window: false` (a launcher that detaches and
# returns). Run in the foreground it held the rack's own terminal until it was killed — every
# one of a client's five such services did (the coordinator's LVI-045).
#
# A service with no start: is status-only. With no health: or compose:, a service is up while
# a beacon names a live pid. A URL behind a login wall (Cloudflare Access) answers 302 whether
# or not anything runs behind it, so probe what serves it (compose: project/service) instead.
#
# ── THE BEACON ─────────────────────────────────────────────────────────────
#
# A launcher says it is running, from wherever it was started:
#
#   scripts/lv-exec.sh lv-services.sh beacon up worker --pid $$ || true
#   trap 'scripts/lv-exec.sh lv-services.sh beacon down worker --pid $$ || true' EXIT
#   ... and `beacon beat worker --pid $$` from its loop, when the manifest sets heartbeat:
#
# A launcher that hands over to something detached (`docker compose up -d`) says
# `up --detached` first, and its stop says `down --detached`. A record is one small file under
# $LV_SERVICES_DIR/<project_slug>/ (default ~/.local/state/levain/services), written through a
# rename. It holds the pid, the checkout, its branch and commit, and two times. It holds no
# environment and no secret. A record whose pid is dead is removed by the next status.
#
# ── STATUS ─────────────────────────────────────────────────────────────────
#
#   <id>\t<state>\t<detail>\t<checkout>\t<branch>\t<commit>\t<since>\t<pid>\t<flags>
#
#   state   up | down | stale (heartbeat older than heartbeat:)
#   detail  the health code, `N containers`, or the heartbeat age (`♥12s`)
#   since   seconds since the beacon's up; `-` with no beacon
#   flags   comma-separated: offmain (not main's worktree), behind=N (commits behind main)
#
# Exit codes: 0 ok · 1 usage · 2 refused under an agent, or guard found a live service ·
# 3 that checkout is not allowed · 4 no main worktree · 5 a need is not up · 6 already running
# · 7 no such service, or nothing to run.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

SERVICES_DIR="${LV_SERVICES_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/levain/services}"

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
die() { local rc="$1"; shift; echo "lv-services: $*" >&2; exit "$rc"; }

# Starting or stopping runs the project's own launchers, which read keys in the operator's
# terminal and refuse an agent themselves. Refusing here too says so before a window opens.
refuse_agent() {
  [ -z "${CLAUDECODE:-}" ] || die 2 "$1 runs in the operator's own terminal, not under an agent"
}

root() { wf_develop_root; }

slug() {
  local s; s=$(wf_cfg project_slug "")
  [ -n "$s" ] || s=$(basename "$(root)")
  printf '%s' "$s"
}

svc() { wf_cfg "services.$1.$2" "${3:-}"; }
svc_ids() { wf_cfg_keys services; }
has_svc() { svc_ids | grep -qxF -- "$1"; }

# main_worktree — the worktree with main checked out, else nothing (exit 1).
main_worktree() {
  local path="" found="" line
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/main") found="$path" ;;
    esac
  done < <(git -C "$(root)" worktree list --porcelain 2>/dev/null)
  [ -n "$found" ] || return 1
  printf '%s' "$found"
}

list_worktrees() {
  local path="" line main=""
  main=$(main_worktree || true)
  [ -n "$main" ] && printf '%s\tmain\n' "$main"
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/"*)
        [ "$path" = "$main" ] || printf '%s\t%s\n' "$path" "${line#branch refs/heads/}" ;;
      detached) printf '%s\t(detached)\n' "$path" ;;
    esac
  done < <(git -C "$(root)" worktree list --porcelain 2>/dev/null)
}

is_worktree() {
  local want="$1" p
  while IFS=$'\t' read -r p _; do [ "$p" = "$want" ] && return 0; done < <(list_worktrees)
  return 1
}

# ── Records ─────────────────────────────────────────────────────────────────

pdir() { printf '%s/%s' "$SERVICES_DIR" "$(slug)"; }

# rec_get <file> <key>
rec_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

rec_write() { # rec_write <file> <key=value>...
  local f="$1" tmp; shift
  mkdir -p "$(dirname "$f")"
  tmp=$(mktemp "$f.XXXXXX")
  printf '%s\n' "$@" > "$tmp"
  mv -f "$tmp" "$f"
}

pid_alive() { [ "$1" -gt 0 ] 2>/dev/null && kill -0 "$1" 2>/dev/null; }

# live_records <id> — record files for that service whose pid is alive, or detached; a dead
# pid's record is removed on the way.
live_records() {
  local f pid
  for f in "$(pdir)/$1".*.rec; do
    [ -f "$f" ] || continue
    pid=$(rec_get "$f" pid)
    if [ "$pid" = 0 ] || pid_alive "$pid"; then printf '%s\n' "$f"; else rm -f "$f"; fi
  done
}

beacon() {
  local action="${1:-}" id="${2:-}" pid="" detached=false f now co
  shift 2 2>/dev/null || usage 1
  while [ $# -gt 0 ]; do
    case "$1" in
      --pid) pid="${2:-}"; shift 2 ;;
      --detached) detached=true; shift ;;
      *) usage 1 ;;
    esac
  done
  [ -n "$id" ] || usage 1
  if $detached; then pid=0; else [[ "$pid" =~ ^[0-9]+$ ]] || die 1 "beacon needs --pid <pid> or --detached"; fi
  f="$(pdir)/$id.$pid.rec"
  now=$(date +%s)
  case "$action" in
    up)
      co=$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)
      rec_write "$f" "project=$(slug)" "service=$id" "pid=$pid" "checkout=$co" \
        "branch=$(git -C "$co" rev-parse --abbrev-ref HEAD 2>/dev/null || echo -)" \
        "commit=$(git -C "$co" rev-parse --short HEAD 2>/dev/null || echo -)" \
        "started=$now" "heartbeat=$now" ;;
    beat)
      [ -f "$f" ] || die 7 "no beacon for $id pid $pid (beacon up first)"
      rec_write "$f" "$(grep -v '^heartbeat=' "$f")" "heartbeat=$now" ;;
    down) rm -f "$f" ;;
    *) usage 1 ;;
  esac
}

# ── Probes ──────────────────────────────────────────────────────────────────

# probe <id> — sets P_STATE (up|down|none) and P_DETAIL.
probe() {
  local health compose code n
  health=$(svc "$1" health); compose=$(svc "$1" compose)
  P_STATE=none; P_DETAIL=""
  if [ -n "$health" ]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time "${LV_SERVICES_PROBE_SECS:-3}" "$health" 2>/dev/null || true)
    [ -n "$code" ] || code=000
    P_DETAIL="$code"
    if [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ]; then P_STATE=up; else P_STATE=down; fi
  elif [ -n "$compose" ]; then
    local -a filt=(--filter "label=com.docker.compose.project=${compose%%/*}")
    case "$compose" in */*) filt+=(--filter "label=com.docker.compose.service=${compose#*/}") ;; esac
    n=$(docker ps -q "${filt[@]}" 2>/dev/null | wc -l | tr -d ' ')
    P_DETAIL="$n containers"
    if [ "${n:-0}" -gt 0 ]; then P_STATE=up; else P_STATE=down; fi
  fi
}

flags_for() { # flags_for <checkout> <commit>
  local main fl="" behind
  main=$(main_worktree || true)
  [ -n "$main" ] && [ "$1" != "$main" ] && fl="offmain"
  if [ -n "$main" ] && [ "$2" != "-" ] && [ -n "$2" ]; then
    behind=$(git -C "$(root)" rev-list --count "$2..main" 2>/dev/null || echo 0)
    [ "${behind:-0}" -gt 0 ] && fl="${fl:+$fl,}behind=$behind"
  fi
  printf '%s' "${fl:--}"
}

# status_of <id> — the status lines for one service.
status_of() {
  local id="$1" hb now f pid state detail age recs
  hb=$(svc "$id" heartbeat)
  now=$(date +%s)
  probe "$id"
  recs=$(live_records "$id")
  if [ -z "$recs" ]; then
    case "$P_STATE" in none) state=down ;; *) state="$P_STATE" ;; esac
    printf '%s\t%s\t%s\t-\t-\t-\t-\t-\t-\n' "$id" "$state" "${P_DETAIL:--}"
    return 0
  fi
  while IFS= read -r f; do
    pid=$(rec_get "$f" pid)
    # A detached record outlives what it started; once the probe says down, it is history.
    if [ "$pid" = 0 ] && [ "$P_STATE" = down ]; then
      rm -f "$f"
      printf '%s\tdown\t%s\t-\t-\t-\t-\t-\t-\n' "$id" "${P_DETAIL:--}"
      continue
    fi
    state="$P_STATE"; detail="$P_DETAIL"
    if [ "$state" = none ]; then
      state=up
      age=$(( now - $(rec_get "$f" heartbeat) ))
      detail="♥${age}s"
      [ -n "$hb" ] && [ "$age" -gt "$hb" ] && state=stale
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$state" "${detail:--}" \
      "$(rec_get "$f" checkout)" "$(rec_get "$f" branch)" "$(rec_get "$f" commit)" \
      "$(( now - $(rec_get "$f" started) ))" "$pid" \
      "$(flags_for "$(rec_get "$f" checkout)" "$(rec_get "$f" commit)")"
  done <<< "$recs"
}

is_up() { status_of "$1" | cut -f2 | grep -qx up; }

# ── Actions ─────────────────────────────────────────────────────────────────

# open_window <dir> <command> — a new Terminal window running <command> in <dir>.
# LV_SERVICES_OPENER replaces Terminal, so the tests never open one.
open_window() {
  local cmd; cmd="cd $(printf '%q' "$1") && $2"
  if [ -n "${LV_SERVICES_OPENER:-}" ]; then "$LV_SERVICES_OPENER" "$cmd"; return; fi
  osascript -e 'on run argv' -e 'tell application "Terminal" to do script (item 1 of argv)' \
    -e 'end run' "$cmd" >/dev/null
}

# wants_window <id> — `window:` when the manifest sets it; else true for a service stopped by
# signal, whose start: is the long-running process itself.
wants_window() {
  local w stop
  w=$(svc "$1" window)
  case "$w" in
    true) return 0 ;;
    false) return 1 ;;
  esac
  stop=$(svc "$1" stop)
  [ -z "$stop" ] || [ "$stop" = signal ]
}

start() {
  local id="" co="" cmd mode main need running
  while [ $# -gt 0 ]; do
    case "$1" in
      --checkout) co="${2:-}"; shift 2 ;;
      -*) usage 1 ;;
      *) id="$1"; shift ;;
    esac
  done
  [ -n "$id" ] || usage 1
  refuse_agent "start"
  has_svc "$id" || die 7 "no service '$id' in levain.yml services:"
  cmd=$(svc "$id" start)
  [ -n "$cmd" ] || die 7 "$id is status-only (no start:)"
  mode=$(svc "$id" checkout main)
  main=$(main_worktree || true)
  if [ -z "$co" ]; then
    co="$main"
    if [ -z "$co" ]; then
      [ "$mode" = any ] || die 4 "$id runs from main, and no worktree has main checked out"
      co=$(root)
    fi
  else
    co=$(cd "$co" 2>/dev/null && pwd -P) || die 3 "no such checkout: $co"
    is_worktree "$co" || die 3 "$co is not a worktree of this project"
    [ "$mode" = any ] || [ "$co" = "$main" ] || die 3 "$id runs from main only (checkout: main)"
  fi
  for need in $(svc "$id" needs); do
    is_up "$need" || die 5 "$id needs $need, which is not up"
  done
  running=$(status_of "$id" | awk -F'\t' '$2 != "down" { print ($4 == "-" ? "outside the rack" : $4) }' | head -1)
  [ -z "$running" ] || die 6 "$id is already running ($running); stop it first"
  if wants_window "$id"; then
    open_window "$co" "$cmd"
    printf '%s: started in a new window, from %s\n' "$id" "$co"
  else
    (cd "$co" && bash -c "$cmd")
  fi
}

stop() {
  local id="${1:-}" cmd f pid co n=0
  [ -n "$id" ] || usage 1
  refuse_agent "stop"
  has_svc "$id" || die 7 "no service '$id' in levain.yml services:"
  cmd=$(svc "$id" stop)
  # Status-only: nothing here started it, so nothing here stops it (a tunnel sidecar goes
  # down with the service whose launcher brought it up).
  [ -n "$cmd" ] || [ -n "$(svc "$id" start)" ] || die 7 "$id is status-only (no start: or stop:) — stop whatever starts it"
  if [ -z "$cmd" ] || [ "$cmd" = signal ]; then
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      pid=$(rec_get "$f" pid)
      [ "$pid" = 0 ] && continue
      kill -TERM "$pid" 2>/dev/null && n=$((n + 1))
      rm -f "$f"
    done <<< "$(live_records "$id")"
    [ "$n" -gt 0 ] || die 7 "$id: nothing running to signal"
    printf '%s: TERM sent to %s process(es)\n' "$id" "$n"
    return 0
  fi
  # Stop from the checkout it was started from, when a beacon says; else main, else develop.
  co=$(live_records "$id" | head -1 | while IFS= read -r f; do rec_get "$f" checkout; done)
  [ -n "$co" ] && [ -d "$co" ] || co=$(main_worktree || root)
  (cd "$co" && bash -c "$cmd")
  for f in "$(pdir)/$id".0.rec; do rm -f "$f"; done
}

console() {
  local cmd
  refuse_agent "console"
  cmd=$(wf_cfg services_console "")
  [ -n "$cmd" ] || die 7 "no services_console: in levain.yml"
  open_window "$(root)" "$cmd"
}

# guard <path> — any project's live pid beacon running from <path>, or under it. Detached
# records are not counted: what they started no longer runs from the checkout.
guard() {
  local want f pid co hits=""
  [ -n "${1:-}" ] || usage 1
  want=$(cd "$1" 2>/dev/null && pwd -P) || want="$1"
  for f in "$SERVICES_DIR"/*/*.rec; do
    [ -f "$f" ] || continue
    pid=$(rec_get "$f" pid)
    pid_alive "$pid" || continue
    co=$(rec_get "$f" checkout)
    case "$co/" in "$want"/*)
      hits+="  $(rec_get "$f" project) $(rec_get "$f" service), pid $pid, from $co"$'\n' ;;
    esac
  done
  [ -z "$hits" ] && return 0
  printf 'lv-services: a service is running from %s — stop it first:\n%s' "$want" "$hits" >&2
  return 2
}

list() {
  local id
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$(svc "$id" label "$id")" \
      "$([ -n "$(svc "$id" start)" ] && echo start || echo status-only)" \
      "$(svc "$id" checkout main)" "$(svc "$id" needs)"
  done <<< "$(svc_ids)"
}

status() {
  local id
  while IFS= read -r id; do [ -n "$id" ] && status_of "$id"; done <<< "$(svc_ids)"
}

case "${1:-}" in
  list) list ;;
  status) status ;;
  worktrees) list_worktrees ;;
  start) shift; start "$@" ;;
  stop) shift; stop "$@" ;;
  console) console ;;
  guard) shift; guard "$@" ;;
  beacon) shift; beacon "$@" ;;
  -h|--help) usage 0 ;;
  *) usage 1 ;;
esac
