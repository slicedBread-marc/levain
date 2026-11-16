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
#   lv-services.sh log <id> [--path]    follow a detached service's log in a new window
#   lv-services.sh progress <id>        the progress file's facts and detail lines
#   lv-services.sh throttle <id> [show|pause|resume|stop-for-day|set <key> <value>|unset <key>]
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
#       window: true                     # start detached, its output in a log that a new
#                                        # Terminal window follows; the default when stop:
#                                        # is signal or absent
#       checkout: main                   # main (the default) | any
#       health: "http://127.0.0.1:8080/health"   # up while it answers 200-499
#       url: "http://127.0.0.1:8080/"    # what the rack shows and copies on Enter;
#                                        # defaults to health:'s origin
#       compose: "myapp-web"             # or: up while this compose project has containers;
#                                        # "myapp-web/cloudflared" narrows it to one compose service
#       heartbeat: 120                   # a beacon not refreshed for this long is stale
#       needs: "web"                     # ids that must be up before this one starts
#   services_console: "tools/board.sh"   # the project's own board, for what the rack does not do
#
# A service stopped by signal (stop: signal, or no stop:) is the process its start: runs, so
# it starts detached unless the manifest says `window: false` (a launcher that detaches and
# returns). Run in the foreground it held the rack's own terminal until it was killed — every
# one of a client's five such services did (the coordinator's LVI-045).
#
# Detached means: in a session of its own, stdin closed, stdout and stderr to
# $LV_SERVICES_DIR/<project_slug>/<id>.log (the previous run's kept as <id>.log.1), its pid in
# <id>.launch. The window that opens only runs `tail -F` on that log, so a prompt from the
# operator's shell startup blocks the tail, never the service (the coordinator's LVI-049), and
# closing the window stops nothing (`log <id>` reopens it). A launcher therefore cannot read
# the terminal; one that asks a question must take its answer another way. A start that dies
# within LV_SERVICES_SETTLE_SECS (0.5) prints its log's end and exits 8.
#
# Detached starts, progress: and throttle: are explained in docs/services.md.
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
#   <id>\t<state>\t<detail>\t<checkout>\t<branch>\t<commit>\t<since>\t<pid>\t<flags>\t<url>
#     \t<progress>\t<p.age>\t<summary>\t<control>\t<reported>
#
#   state     up | down | stale (heartbeat older than heartbeat:)
#   detail    the health code, `N containers`, or the heartbeat age (`♥12s`)
#   since     seconds since the beacon's up; `-` with no beacon
#   flags     comma-separated: offmain (not main's worktree), behind=N (commits behind main)
#   url       url:, else health:'s scheme://host[:port]/, else `-`
#   progress  ok | stale (updatedAt older than heartbeat:) | undated | missing | unreadable,
#             or `-` with no progress: declared
#   p.age     seconds since the progress file's updatedAt, else `-`
#   summary   the progress file's one-line summary, else `-`
#   control   the control file's state (run | pause | stop-for-day), `run` with no control
#             file, `-` with no throttle: declared
#   reported  the progress file's own `state` (what the service says it is doing), else `-`
#
# Fields are only ever appended: the rack reads them by position. `progress <id>` prints the
# same five, after a `file` line, followed by the progress file's detail lines.
#
# ── PROGRESS AND THROTTLE ──────────────────────────────────────────────────
#
#       progress: "synth.status.json"    # a JSON file the service writes: summary (one line),
#                                        # detail (array of short lines), updatedAt (ISO 8601);
#                                        # relative to $LV_SERVICES_DIR/<project_slug>/
#       throttle:                        # the service honours <id>.control.json beside its
#         rate: 20/hour                  # beacons; these are its defaults, and the keys the
#         budget: 400k tokens/5h         # rack may change (docs/services.md § Throttle)
#
# Exit codes: 0 ok · 1 usage · 2 refused under an agent, or guard found a live service ·
# 3 that checkout is not allowed · 4 no main worktree · 5 a need is not up · 6 already running
# · 7 no such service, or nothing to run · 8 a detached start exited at once · 9 a control file does not parse, or no python3.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

SERVICES_DIR="${LV_SERVICES_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/levain/services}"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }
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
    # Docker not running is a down service, not a failed status: under pipefail a failing
    # `docker ps` would end the whole listing at this service.
    n=$(docker ps -q "${filt[@]}" 2>/dev/null | wc -l | tr -d ' ') || n=0
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

# url_of <id> — where the service is reached: url:, else health:'s origin, else -.
url_of() {
  local u h
  u=$(svc "$1" url)
  if [ -z "$u" ]; then
    h=$(svc "$1" health)
    [[ "$h" =~ ^(https?://[^/?#]+) ]] && u="${BASH_REMATCH[1]}/"
  fi
  printf '%s' "${u:--}"
}

# status_of <id> — the status lines for one service.
status_of() {
  local id="$1" hb now f pid state detail age recs url facts
  hb=$(svc "$id" heartbeat); url=$(url_of "$id")
  now=$(date +%s)
  probe "$id"
  facts=$(facts_line "$id")
  recs=$(live_records "$id")
  if [ -z "$recs" ]; then
    case "$P_STATE" in none) state=down ;; *) state="$P_STATE" ;; esac
    printf '%s\t%s\t%s\t-\t-\t-\t-\t-\t-\t%s\t%s\n' "$id" "$state" "${P_DETAIL:--}" "$url" "$facts"
    return 0
  fi
  while IFS= read -r f; do
    pid=$(rec_get "$f" pid)
    # A detached record outlives what it started; once the probe says down, it is history.
    if [ "$pid" = 0 ] && [ "$P_STATE" = down ]; then
      rm -f "$f"
      printf '%s\tdown\t%s\t-\t-\t-\t-\t-\t-\t%s\t%s\n' "$id" "${P_DETAIL:--}" "$url" "$facts"
      continue
    fi
    state="$P_STATE"; detail="$P_DETAIL"
    if [ "$state" = none ]; then
      state=up
      age=$(( now - $(rec_get "$f" heartbeat) ))
      detail="♥${age}s"
      [ -n "$hb" ] && [ "$age" -gt "$hb" ] && state=stale
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$state" "${detail:--}" \
      "$(rec_get "$f" checkout)" "$(rec_get "$f" branch)" "$(rec_get "$f" commit)" \
      "$(( now - $(rec_get "$f" started) ))" "$pid" \
      "$(flags_for "$(rec_get "$f" checkout)" "$(rec_get "$f" commit)")" "$url" "$facts"
  done <<< "$recs"
}

is_up() { status_of "$1" | cut -f2 | grep -qx up; }

# ── Progress and throttle ───────────────────────────────────────────────────
#
# Both are small JSON files a service shares with the rack, in its project's state dir:
#
#   progress: <file>   the service writes it, the rack reads it (the coordinator's LVI-052)
#   <id>.control.json  the rack writes it, the service reads it (throttle:, LVI-041)
#
# Read and written with python3, which also parses updatedAt's ISO time; without it, progress
# reads as unreadable and a throttle write refuses (exit 9).

# progress_path <id> — the declared progress: file, resolved; nothing when none is declared.
progress_path() {
  local p; p=$(svc "$1" progress)
  [ -n "$p" ] || return 0
  case "$p" in /*) ;; "~/"*) p="$HOME/${p#\~/}" ;; *) p="$(pdir)/$p" ;; esac
  printf '%s' "$p"
}
control_path() { printf '%s/%s.control.json' "$(pdir)" "$1"; }
has_throttle() { [ -n "$(wf_cfg_keys "services.$1.throttle")" ]; }

# json_facts <progress-file|-> <heartbeat|-> <control-file|-> — one TSV line:
#   <progress: ok|stale|undated|missing|unreadable|-> <age secs|-> <summary|-> <control state|->
#   <reported state|->
# then the progress file's detail lines. Never fails: a file that cannot be read says so.
JSON_FACTS_PY='
import json, re, sys, time, datetime
pf, hb, cf = sys.argv[1:4]
def clean(x): return re.sub(r"[\t\r\n]+", " ", str(x)).strip()
def age_of(u):
    if not isinstance(u, str): return None
    t = re.sub(r"Z$", "+00:00", u.strip()); t = re.sub(r"(\.\d{6})\d+", r"\1", t)
    try: dt = datetime.datetime.fromisoformat(t)
    except ValueError: return None
    if dt.tzinfo is None: dt = dt.astimezone()
    return max(0, int(time.time() - dt.timestamp()))
pst, age, summ, rep, detail = "-", "-", "-", "-", []
if pf != "-":
    try:
        with open(pf) as h: d = json.load(h)
        if not isinstance(d, dict): raise ValueError("not an object")
    except FileNotFoundError: pst = "missing"
    except Exception: pst = "unreadable"
    else:
        summ = clean(d.get("summary") or "") or "-"
        rep = clean(d.get("state") or "") or "-"
        a = age_of(d.get("updatedAt"))
        if a is None: pst = "undated"
        else:
            age = str(a)
            pst = "stale" if hb.isdigit() and a > int(hb) else "ok"
        det = d.get("detail")
        if isinstance(det, str): det = [det]
        if isinstance(det, list): detail = [clean(x) for x in det[:100]]
cst = "-"
if cf != "-":
    cst = "run"
    try:
        with open(cf) as h: c = json.load(h)
        if isinstance(c, dict) and c.get("state"): cst = clean(c["state"])
    except FileNotFoundError: pass
    except Exception: cst = "unreadable"
print("\t".join([pst, age, summ, cst, rep]))
for x in detail: print(x)
'
json_facts() {
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\t-\t-\t%s\t-\n' "$([ "$1" = - ] && echo - || echo unreadable)" "$([ "$3" = - ] && echo - || echo unreadable)"
    return 0
  fi
  python3 -c "$JSON_FACTS_PY" "$@" 2>/dev/null || printf 'unreadable\t-\t-\t-\t-\n'
}

# facts_line <id> — the five progress and throttle fields status appends, tab-separated.
facts_line() {
  local pf cf
  pf=$(progress_path "$1"); cf=-
  has_throttle "$1" && cf=$(control_path "$1")
  if [ -z "$pf" ] && [ "$cf" = - ]; then printf -- '-\t-\t-\t-\t-'; return 0; fi
  json_facts "${pf:--}" "$(svc "$1" heartbeat -)" "$cf" | head -1
}

# The throttle vocabulary the library knows the shape of (docs/services.md § Throttle). A key a
# service declares beyond these is passed through as a string, unchecked.
throttle_valid() { # throttle_valid <key> <value>
  case "$1" in
    rate)        [[ "$2" =~ ^[1-9][0-9]*/hour$ ]] ;;
    concurrency) [[ "$2" =~ ^[1-9][0-9]*$ ]] ;;
    budget)      [[ "$2" =~ ^[0-9]+[km]?\ tokens/[1-9][0-9]*h$ ]] ;;
    hours)       [[ "$2" =~ ^[0-9]{1,2}:[0-5][0-9]-[0-9]{1,2}:[0-5][0-9]$ ]] ;;
    ai_share)    [[ "$2" =~ ^[0-9]+(\.[0-9]+)?%$ ]] ;;
    *)           [[ "$2" != *$'\t'* && "$2" != *$'\n'* && -n "$2" ]] ;;
  esac
}

# control_write <file> <key=value | -key>... — merge into the control file through a rename,
# keeping every field it does not name, and stamp updatedAt (UTC). Refuses a file that does not
# parse rather than overwrite what someone wrote by hand.
CONTROL_WRITE_PY='
import json, os, re, sys, tempfile, datetime
path, edits = sys.argv[1], sys.argv[2:]
try:
    with open(path) as h: d = json.load(h)
    if not isinstance(d, dict): raise ValueError("not an object")
except FileNotFoundError: d = {}
except Exception as e:
    sys.stderr.write("lv-services: %s does not parse (%s); fix or remove it\n" % (path, e)); sys.exit(9)
for op in edits:
    if op.startswith("-"): d.pop(op[1:], None); continue
    k, v = op.split("=", 1)
    d[k] = int(v) if re.fullmatch(r"[0-9]+", v) else v
d["updatedAt"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=os.path.basename(path) + ".")
with os.fdopen(fd, "w") as h: json.dump(d, h); h.write("\n")
os.replace(tmp, path)
'
control_write() {
  command -v python3 >/dev/null 2>&1 || die 9 "writing a control file needs python3"
  python3 -c "$CONTROL_WRITE_PY" "$@"
}

# throttle <id> [show | pause | resume | stop-for-day | set <key> <value> | unset <key>]
throttle() {
  local id="${1:-}" action="${2:-show}" key="${3:-}" val="${4:-}" cf k v src
  [ -n "$id" ] || usage 1
  has_svc "$id" || die 7 "no service '$id' in levain.yml services:"
  has_throttle "$id" || die 7 "$id declares no throttle:"
  cf=$(control_path "$id")
  case "$action" in
    show)
      command -v python3 >/dev/null 2>&1 || die 9 "reading a control file needs python3"
      printf 'control\t%s\n' "$cf"
      # state first, then each declared key: the control file's value, else the manifest's.
      while IFS= read -r k; do [ -n "$k" ] && printf '%s\t%s\n' "$k" "$(svc "$id" "throttle.$k")"; done \
        <<< "$(wf_cfg_keys "services.$id.throttle")" | python3 -c '
import json, sys
cf = sys.argv[1]
try:
    with open(cf) as h: c = json.load(h)
    if not isinstance(c, dict): c = {}
except Exception: c = {}
print("state\t%s\t%s" % (c.get("state", "run"), "control" if "state" in c else "default"))
decl = [l.rstrip("\n").split("\t", 1) for l in sys.stdin if "\t" in l]
for k, v in decl:
    print("%s\t%s\tcontrol" % (k, c[k]) if k in c else "%s\t%s\tmanifest" % (k, v))
names = [k for k, _ in decl]
for k in c:
    if k not in names and k not in ("state", "updatedAt"): print("%s\t%s\tcontrol" % (k, c[k]))
if "updatedAt" in c: print("updatedAt\t%s\tcontrol" % c["updatedAt"])
' "$cf"
      return 0 ;;
    pause|stop-for-day)
      control_write "$cf" "state=$action"
      printf '%s: %s (%s)\n' "$id" "$action" "$cf" ;;
    resume)
      refuse_agent "resume"
      control_write "$cf" "state=run"
      printf '%s: resumed (%s)\n' "$id" "$cf" ;;
    set)
      refuse_agent "set"
      [ -n "$key" ] && [ -n "$val" ] || usage 1
      [ "$key" != state ] && [ "$key" != updatedAt ] || die 1 "use pause, resume or stop-for-day for state"
      wf_cfg_keys "services.$id.throttle" | grep -qxF -- "$key" \
        || die 1 "$id's throttle: declares no '$key' (declared: $(wf_cfg_keys "services.$id.throttle" | tr '\n' ' '))"
      throttle_valid "$key" "$val" || die 1 "'$val' is not a valid $key (docs/services.md § Throttle)"
      control_write "$cf" "$key=$val"
      printf '%s: %s = %s (%s)\n' "$id" "$key" "$val" "$cf" ;;
    unset)
      refuse_agent "unset"
      [ -n "$key" ] || usage 1
      control_write "$cf" "-$key"
      printf '%s: %s back to the manifest'"'"'s (%s)\n' "$id" "$key" "$cf" ;;
    *) usage 1 ;;
  esac
}

# progress <id> — the progress file's facts, then its detail lines.
progress() {
  local id="${1:-}" pf cf=-
  [ -n "$id" ] || usage 1
  has_svc "$id" || die 7 "no service '$id' in levain.yml services:"
  pf=$(progress_path "$id")
  has_throttle "$id" && cf=$(control_path "$id")
  [ -n "$pf" ] || [ "$cf" != - ] || die 7 "$id declares no progress: or throttle:"
  printf 'file\t%s\n' "${pf:--}"
  json_facts "${pf:--}" "$(svc "$id" heartbeat -)" "$cf"
}

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
  running=$(launch_pid "$id") && die 6 "$id is already running (detached, pid $running); stop it first"
  if wants_window "$id"; then
    detach "$id" "$co" "$cmd"
  else
    (cd "$co" && bash -c "$cmd")
  fi
}

# log_of <id> — where a detached start writes the service's stdout and stderr.
log_of() { printf '%s/%s.log' "$(pdir)" "$1"; }
launch_of() { printf '%s/%s.launch' "$(pdir)" "$1"; }

# launch_detached <dir> <command> <log> — <command> from <dir> in a session of its own, stdin
# closed, stdout and stderr appended to <log>. Prints its pid. setsid(1) where there is one;
# macOS has none, so perl's POSIX::setsid, which it ships; nohup when neither is there.
launch_detached() {
  (
    cd "$1" || exit 1
    if command -v setsid >/dev/null 2>&1; then
      setsid bash -c "$2" </dev/null >>"$3" 2>&1 &
    elif command -v perl >/dev/null 2>&1; then
      perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!\n"' bash -c "$2" </dev/null >>"$3" 2>&1 &
    else
      nohup bash -c "$2" </dev/null >>"$3" 2>&1 &
    fi
    printf '%s\n' "$!"
  )
}

# detach <id> <checkout> <command> — start a long-running service detached from any terminal,
# then open a window that only follows its log. The command used to be typed into a fresh
# interactive shell, whose startup prompt (oh-my-zsh's update question) ate the line, and the
# service never started (the coordinator's LVI-049). A prompt now blocks the tail, not the
# service. The pid is recorded in <id>.launch so stop: signal reaches it even before, or
# without, the launcher's own beacon.
detach() {
  local id="$1" co="$2" cmd="$3" log pid
  log=$(log_of "$id")
  mkdir -p "$(pdir)"
  [ -f "$log" ] && mv -f "$log" "$log.1"
  printf '── %s started %s from %s ──\n' "$id" "$(date '+%Y-%m-%d %H:%M:%S')" "$co" > "$log"
  pid=$(launch_detached "$co" "$cmd" "$log")
  rec_write "$(launch_of "$id")" "service=$id" "pid=$pid" "checkout=$co" "log=$log" "started=$(date +%s)"
  sleep "${LV_SERVICES_SETTLE_SECS:-0.5}"
  if ! pid_alive "$pid"; then
    rm -f "$(launch_of "$id")"
    printf 'lv-services: %s exited at once; the end of its log (%s):\n' "$id" "$log" >&2
    tail -n 20 "$log" >&2
    exit 8
  fi
  open_window "$co" "tail -n 200 -F $(printf '%q' "$log")" \
    || printf '%s: no window opened; follow it with: tail -F %s\n' "$id" "$log"
  printf '%s: started detached (pid %s), from %s; a new window follows %s\n' "$id" "$pid" "$co" "$log"
}

# launch_pid <id> — the pid a detached start recorded, while it lives; a dead one's record goes.
launch_pid() {
  local f pid; f=$(launch_of "$1")
  [ -f "$f" ] || return 1
  pid=$(rec_get "$f" pid)
  if pid_alive "$pid"; then printf '%s' "$pid"; else rm -f "$f"; return 1; fi
}

# log_window <id> [--path] — follow a detached service's log again in a new window (closing
# that window never stopped the service), or print where the log is.
log_window() {
  local id="" path=false log
  while [ $# -gt 0 ]; do
    case "$1" in --path) path=true; shift ;; -*) usage 1 ;; *) id="$1"; shift ;; esac
  done
  [ -n "$id" ] || usage 1
  has_svc "$id" || die 7 "no service '$id' in levain.yml services:"
  log=$(log_of "$id")
  if $path; then printf '%s\n' "$log"; return 0; fi
  refuse_agent "log"
  [ -f "$log" ] || die 7 "$id has no log yet (only a detached start writes one)"
  open_window "$(pdir)" "tail -n 200 -F $(printf '%q' "$log")"
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
    # The beacons' pids, and the pid a detached start recorded: never a window's shell.
    local sent=" " lp
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      pid=$(rec_get "$f" pid)
      [ "$pid" = 0 ] && continue
      kill -TERM "$pid" 2>/dev/null && { n=$((n + 1)); sent="$sent$pid "; }
      rm -f "$f"
    done <<< "$(live_records "$id")"
    if lp=$(launch_pid "$id"); then
      case "$sent" in *" $lp "*) ;; *) kill -TERM "$lp" 2>/dev/null && n=$((n + 1)) ;; esac
      rm -f "$(launch_of "$id")"
    fi
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
  log) shift; log_window "$@" ;;
  progress) shift; progress "$@" ;;
  throttle) shift; throttle "$@" ;;
  beacon) shift; beacon "$@" ;;
  -h|--help) usage 0 ;;
  *) usage 1 ;;
esac
