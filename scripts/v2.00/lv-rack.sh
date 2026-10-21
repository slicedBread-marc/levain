#!/usr/bin/env bash
# lv-rack.sh — the workflow board for every harness-enabled project, as one grid.
# The overseer rung (LVI-014): run it from a coordinator, through its
# scripts/lv-exec.sh, or /lv-rack.
#
#   lv-rack.sh [--watch [seconds]] [--plain] [--all] [--include-dormant]
#   lv-rack.sh --stop-all        stop every live daemon, remembering which
#   lv-rack.sh --resume          start again exactly the ones --stop-all stopped
#   lv-rack.sh --list-daemons    print live daemons; exit 3 if there are any
#   lv-rack.sh --dormant         list every project, on or dormant
#   lv-rack.sh --sleep <name>    make a project dormant: no column, no scan
#   lv-rack.sh --wake <name>     put a dormant project back on the board
#   lv-rack.sh --services        every project's services: state, checkout, how long up
#
# --watch repaints only the rows that changed, not the whole screen — no
# flicker.
#
# Projects are sorted by recent activity — the latest of a git commit or an
# orchestrator event — before rendering, most active first, so a project
# that's gone quiet sinks on its own instead of needing manual pruning from
# the registry. Only as many as fit the terminal's width (MAX_COLS) are
# drawn by default; --all shows
# every deployed client. Either way the interactive project picker
# (menu_loop — reached via 'm' in --watch, or automatically after a plain
# run) always lists every project regardless of the cap, so a quiet one is
# still one keypress away.
#
# Walks the project registry (the project-registry hook; see below) and runs
# each client's own
# `lv-tray.sh --fields`: one machine-readable line of counts, no colour, no
# prose. Those lines become columns in a fixed-height table — metric rows,
# one column per project — so the whole portfolio fits on one screen
# regardless of terminal height, unlike stacking each project's own block
# vertically (which is what this replaced: five ~13-line blocks scroll a
# normal terminal well before the fifth one renders).
#
# A `stuck`/`spec-stuck` gate — a plan that hit its attempt budget with no
# forward progress — is a stall, not an ordinary decision waiting on a
# human. It is called out in red on the GATES row and in the project's own
# header, since it is the one state on this board that does not resolve by
# waiting.
#
# The ATTN row names up to 2 of the gated plans per project (most-blocking
# and oldest first), with a "(+N)" tail for the rest — enough to act on
# without opening a terminal there first.
#
# The RELEASE row is plans complete on `develop` that have never been
# carried through /lv-release — no REGISTRY state shows this, since a plan
# reads `complete` the moment its PR merges to develop, whether /lv-release
# ran yesterday or has never run at all. The DEPLOY row is plans staged on
# `release` but not yet promoted to `main` — validated by /lv-release's E2E
# and just waiting on /lv-deploy. Both yellow when non-zero, same as an
# unanswered gate; a dash means the project has no release/main branch
# split at all, not "nothing pending".
#
# The IDEAS row is briefs still sitting at `## Idea` / `## Exploring` in a
# project's plans/briefs/INDEX.md — thinking that was started and never
# carried to a decision. `Decided` is not counted: that brainstorm finished,
# and it is already visible as specable work and then as `draft`. A `+N` tail
# means N brief files have no row in that index at all (run
# `lv-brainstorm-reindex.sh` in that project); a brief deliberately set aside
# with `lv-brief-park.sh` is in neither number.
#
# A client with no harness installed (no scripts/lv-exec.sh) or too old to
# know --fields is shown as a dashed column rather than skipped silently.
#
# Interactive when run without --watch in a real terminal: after the board,
# a numbered menu picks a project, then a submenu acts on it — toggle its
# orchestrator daemon, run one sweep, kill everything live, tail its recent
# events, list what's gated, open the drill-down below, or stop/resume every
# daemon in the portfolio (the same pair as --stop-all/--resume, and as the
# picker's own 's'/'R', offered here because this is where a daemon gets
# turned on and off). --watch and any
# non-interactive invocation (piped, cron, `lv-rack --plain` redirected
# to a file) skip the menu — it only ever shows when both stdin and stdout
# are a TTY.
#
# ── Drilling into a cell ────────────────────────────────────────────────
#
# Under --watch the arrow keys move a cell cursor (left/right across
# projects, up/down through the metric rows) and Enter opens the cell:
# `project-a / running` lists the three live workers, one of those opens
# its plan, its files and its logs, and a log opens in a pager that can
# FOLLOW a worker still writing it. Esc bubbles back up one level at a time,
# m returns to the board in one key from any depth. `a` is the old project action menu, still one
# keypress away, and `d` starts or stops the highlighted project's daemon
# outright — Enter used to open that menu before the drill-down took the key,
# so the toggle keeps a key of its own rather than living two levels down.
# `s` and `R` stop and resume every daemon in the portfolio.
#
# Those four action keys — d, a, s, R — mean the same thing at EVERY level:
# inside a drill list, inside the project action menu, and inside the pager
# reading a live worker's log, all through board_action_key. A level used to
# be the one place you could not act on what it was about (the daemon row's
# own drill listed the daemon's logs with no way to stop it), and noticing
# from three levels down that a daemon should be off meant Esc, Esc, Esc, d.
# A drill level re-fetches itself after an action, since the numbers behind
# it are exactly what just changed.
#
# Every level but the first is one call to that project's own
# `scripts/lv-exec.sh lv-tray-drill.sh`, whose list lines carry the argv of
# the next call. So the coordinator holds no model of what a plan or a gate or a log is:
# a new kind of thing to open is added in the library and appears here with
# no change to this file, exactly like --fields and the grid.
#
# ── Answering from the board ────────────────────────────────────────────
#
# `t` (attend) at any drill level starts an interactive Claude session in
# that project on `/lv-attend <ID>`, where <ID> is the plan, bug or brief the
# highlighted line points at (else the one the level is about). The board
# steps aside while the session runs and comes back where it was when it
# exits. No id in sight means `/lv-attend` on the whole queue. On the release
# or deploy row (or its drill), `t` starts `/lv-release` or `/lv-deploy`
# instead — those skills answer their own RELEASE/DEPLOY gate, so a plan id
# from the list would attend the wrong thing; the project menu offers both
# too. This is the
# first step toward answering the pipeline from a UI; scoping the session to that one plan is the library's side (WFI-007).
# WF_ATTEND_CMD replaces `claude` so the tests never start a real session.
#
# ── Snapshots, and how old what you are looking at is ──────────────────
#
# Every level of this — the grid and each drill level — is a SNAPSHOT with a
# time on it, cached as JSON under the coordinator's .claude/orchestrator/board-cache/,
# and the cache is always painted FIRST. Walking back out of a drill used to
# re-collect the whole portfolio before it would redraw (a few seconds of
# shelling into every client), which made Esc feel like a wall; now popping a
# level, leaving the browser, and reopening a level you have already seen all
# repaint instantly from the snapshot, and the fetch that refreshes it runs
# behind the frame you are already reading.
#
# Since a shown frame can therefore be old, its AGE is drawn rather than
# assumed: each project column is tinted by how long ago THAT project's
# numbers were collected — white ≤30s, grey ≤45s, dark grey beyond. The tint
# is keyed on the snapshot's own timestamp, never on when the screen was last
# painted, so a repaint of stale data stays grey instead of lying about being
# fresh. With the poll at 60s the third shade is exactly the window between a
# refresh falling due and its results landing.
#
# Alert colours win over the tint: a stuck gate stays red and a waiting one
# stays yellow at any age. The tint says "how sure are we", not "what is it".
#
# Polling continues while you are inside the drill-down and inside a file
# view (board_tick), so what you come back to is current without a blocking
# reload. Without jq the cache is simply skipped — the board still works,
# it just re-collects on a cold start like it used to.
#
# Reading the board is read-only; the menu is not — starting or killing a
# daemon, sweeping, or killing workers all change what that project's harness
# is doing unattended, all routed through that project's own
# scripts/lv-exec.sh so the versioned dispatch stays intact.
#
# Exit 0 for the board and the menu. --list-daemons exits 3 when at least one
# daemon is live, and --stop-all exits 3 when one would not stop, so a deploy
# script can branch on it.
#
# ── Suspend and resume, portfolio-wide ──────────────────────────────────
#
# Deploying a new harness version rewrites every client's scripts/v*/ while
# that client's daemon may be mid-sweep, re-reading lv-orchestrate.sh and its
# libraries out of the directory being rewritten. The 8.6.0 deploy on
# 2026-09-16 ran with one client's daemon live and came through clean — that is
# luck, not a guarantee, and the failure it risks (a sweep reading a
# half-written script folder) surfaces as confusing behaviour an hour later
# rather than as an error at the time.
#
# --stop-all records which projects had a live daemon and then stops each.
# --resume starts exactly those again and clears the record. The record is the
# whole point: stopping everything is easy, putting it back the way it was is
# what nobody does by hand, so daemons quietly stay off for days after a
# deploy and the pipeline looks idle when it is merely switched off.
#
# The record is the coordinator's own state, not any one client's — "which
# daemons were running across the portfolio" is a coordinator fact — so it lives in its
# gitignored .claude/orchestrator/. Client logs still go to the client, the
# same as toggle_daemon already does.
#
# ── Dormant projects (LVI-027) ──────────────────────────────────────────
#
# A parked or retiring project still cost a full lv-tray.sh --fields on every
# refresh and still took a column, because every registered project was
# scanned. `z` under --watch (or `z` in the picker) opens a list of every
# project with an on/off toggle; --sleep/--wake/--dormant do the same from a
# script. A dormant project is neither scanned nor drawn.
#
# A project with a live daemon is always on, whatever its toggle, and cannot
# be put to sleep while it runs: hiding a pipeline that is dispatching work is
# how a stuck gate goes unseen for a week. --include-dormant is the snapshot
# that shows everything; --all keeps meaning "every column that is scanned",
# so `--plain --all` (what /lv-rack summarises) leaves parked projects out.
# The daemon checks — --list-daemons,
# --stop-all, --resume — never honour the hide: they read the pidfiles of
# every registered project, since a stray daemon in a hidden project is the
# one a deploy most needs to find.
#
# The dormant set is the coordinator's own state, beside the suspend record:
# one project path per line in .claude/orchestrator/dormant.
#
# ── Updating the portfolio from the board (LVI-026) ─────────────────────
#
# The `harness` row is each client's .claude/workflow-version against the
# library's VERSION (the library found through the coordinator's
# .claude/workflow-source), yellow when they differ. `U` runs the library's
# deploy-all.sh from the board and refreshes afterwards. It refuses, and says
# why, when LIBRARY-LOCK.md is held (another session is mid-edit, and deploy
# would publish its half-edit to every client), when the library's tracked
# tree is dirty (a deploy ships what is on disk, not what is committed), and
# when the library's own suite is red. A green suite is the approval: no
# prompt follows it. The suite is the one CONTRIBUTING.md names, every
# tests/*.sh; LV_RACK_SUITE replaces it (tests, or a faster local gate).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The ID prefixes (LV_PLN, LV_WORK_RE). The board spans projects, so it reads
# the coordinator's map; the library defaults are always accepted anyway.
# shellcheck source=lv-ids.sh
. "$HERE/lv-ids.sh"
# The coordinator this board belongs to: its state (the suspend record, the
# snapshot cache) lives in that project's gitignored .claude/orchestrator/.
# Run through its scripts/lv-exec.sh from inside the project, which is how
# lv-exec.sh finds it. LV_COORD_DIR tells THIS script which project is the
# coordinator. It does not tell lv-exec.sh anything: the board runs every
# client's lv-exec.sh with LV_COORD_DIR still set, so the dispatcher must
# ignore it (LVI-022). A shim elsewhere on PATH therefore cds into the
# coordinator before it execs lv-exec.sh, and sets LV_COORD_DIR as well.
COORD_DIR="${LV_COORD_DIR:-${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
# LV_DEPLOYMENTS / LV_SUSPEND_STATE are a test seam, unset in normal use (the
# WF_ names from before 14.0.0 are still read).
# Without them the only way to exercise stop/resume is to stop real daemons on
# real clients, which is exactly the thing you want proven before you trust it.
DEPLOYMENTS="${LV_DEPLOYMENTS:-${WF_DEPLOYMENTS:-}}"
SUSPEND_STATE="${LV_SUSPEND_STATE:-${WF_SUSPEND_STATE:-$COORD_DIR/.claude/orchestrator/daemons-suspended}}"
DORMANT_STATE="${LV_DORMANT_STATE:-$COORD_DIR/.claude/orchestrator/dormant}"
# The library this coordinator deploys from: the harness row's reference
# version, and the deploy-all.sh behind `U`. LV_LIBRARY_DIR is the test seam.
LIB_DIR="${LV_LIBRARY_DIR:-}"
[ -z "$LIB_DIR" ] && [ -f "$COORD_DIR/.claude/workflow-source" ] && LIB_DIR=$(head -1 "$COORD_DIR/.claude/workflow-source")
# The blind sweep's state — pid, result, logs, held fixes (lv-library-sweep.sh,
# LVI-031). LV_SWEEP_STATE is the test seam.
SWEEP_STATE="${LV_SWEEP_STATE:-$COORD_DIR/.claude/orchestrator/library-sweep}"

# The snapshot cache — see "Snapshots" below. The coordinator's own state, like
# the suspend record: "what the portfolio last looked like" is a coordinator
# fact, not any one client's. LV_BOARD_CACHE (or WF_BOARD_CACHE) is the test seam.
CACHE_DIR="${LV_BOARD_CACHE:-${WF_BOARD_CACHE:-$COORD_DIR/.claude/orchestrator/board-cache}}"
GRID_SNAPSHOT="$CACHE_DIR/grid.json"

# The project list comes from the project-registry hook (LVI-013): the owner's
# pack when one answers it, else the library's deployments.txt (named by the
# coordinator's .claude/workflow-source), else the coordinator's own
# `coordinates:` list. Written once per run into the cache, so every reader
# below keeps reading a plain file. A failing hook leaves no file, and the
# board says it found no registry rather than drawing a wrong one.
if [ -z "$DEPLOYMENTS" ]; then
  DEPLOYMENTS="$CACHE_DIR/registry.txt"
  _lib=""; [ -f "$COORD_DIR/.claude/workflow-source" ] && _lib=$(head -1 "$COORD_DIR/.claude/workflow-source")
  mkdir -p "$CACHE_DIR" 2>/dev/null
  CLAUDE_PROJECT_DIR="$COORD_DIR" LV_LIBRARY="$_lib" "$HERE/lv-hook.sh" project-registry \
    </dev/null > "$DEPLOYMENTS.tmp" 2>/dev/null \
    && mv -f "$DEPLOYMENTS.tmp" "$DEPLOYMENTS" || rm -f "$DEPLOYMENTS" "$DEPLOYMENTS.tmp"
  unset _lib
fi
HAVE_JQ=false; command -v jq >/dev/null 2>&1 && HAVE_JQ=true

# A coordinator runs no pipeline and has no lv-tray.sh, so it is never a
# column. A registry lists it all the same when it names every install (the
# one deploy-all reads does), this board's own coordinator included.
is_coordinator() {
  local cfg; lv_config_into cfg "$1"
  grep -qsE '^role:[[:space:]]*"?coordinator"?[[:space:]]*$' "$cfg"
}

# A client's harness, on either side of the 14.0.0 rename. hx_resolve <dir>
# <lv-script> sets HX_EXEC and HX_NAME: lv-exec.sh by the lv- name, or a 13.x
# client's wf-exec.sh by the name the script had there. It fails when the
# client has no harness. hx <lv-script> [args] runs it from the client's dir.
# During the cutover the rack drives both kinds at once, so nothing below
# names a wf- script directly.
hx_resolve() {
  if [ -x "$1/scripts/lv-exec.sh" ]; then HX_EXEC=scripts/lv-exec.sh; HX_NAME="$2"
  elif [ -x "$1/scripts/wf-exec.sh" ]; then
    HX_EXEC=scripts/wf-exec.sh
    case "$2" in
      lv-tray.sh)       HX_NAME=wf-board.sh ;;
      lv-tray-drill.sh) HX_NAME=wf-board-drill.sh ;;
      *)                HX_NAME="wf-${2#lv-}" ;;
    esac
  else return 1; fi
}
hx() { local s="$1"; shift; hx_resolve . "$s" || return 127; "$HX_EXEC" "$HX_NAME" "$@"; }
has_harness() { hx_resolve "$1" lv-exec.sh; }

mode=""
mode_arg=""
watch_mode=false
watch_secs=60
plain=false
show_all=false
include_dormant=false
# How many project columns fit across the terminal — recomputed by
# compute_shown from the current width, so a wide terminal shows more of the
# portfolio and a resize is picked up on the next refresh.
MAX_COLS=4

usage() { sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) watch_mode=true
             if [ "${2:-}" ] && [ "${2#-}" = "${2}" ]; then watch_secs="$2"; shift; fi
             shift ;;
    --plain) plain=true; shift ;;
    --all) show_all=true; shift ;;
    --include-dormant) include_dormant=true; shift ;;
    --stop-all) mode="stop-all"; shift ;;
    --resume) mode="resume"; shift ;;
    --list-daemons) mode="list-daemons"; shift ;;
    --dormant) mode="dormant"; shift ;;
    --services) mode="services"; shift ;;
    --sleep|--wake)
      [ -n "${2:-}" ] || { echo "lv-rack: $1 needs a project name" >&2; usage 1; }
      mode="${1#--}"; mode_arg="$2"; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "lv-rack: unknown argument '$1'" >&2; usage 1 ;;
  esac
done

if $plain || [ ! -t 1 ]; then
  B=""; DIM=""; R=""; GRN=""; YEL=""; RED=""; CYN=""; REV=""
  AGE0=""; AGE1=""; AGE2=""
else
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YEL=$'\033[33m'; RED=$'\033[31m'; CYN=$'\033[36m'; REV=$'\033[7m'
  # The three ages of a number: just-collected, going stale, and old enough
  # that a refresh is already due or in flight. Bright white → white → bright
  # black, which every 256-colour terminal renders as a genuine descent into
  # the background rather than three shades you have to squint at.
  AGE0=$'\033[97m'; AGE1=$'\033[37m'; AGE2=$'\033[90m'
fi

# Age bucket boundaries, in seconds since THAT column was collected. The
# third bucket is deliberately open-ended: at the default 60s poll it is the
# window between a refresh falling due and its results landing, so a column
# sitting in dark grey is the visible answer to "is this thing still running".
AGE_FRESH=30
AGE_MID=45

# sel_idx: the project column highlighted in hybrid --watch (arrow-key
# selection). Empty everywhere else, including plain --watch and the
# non-interactive board — render_text's header loop only compares against
# it, never requires it, so an empty string is a safe "no highlight" value
# under `set -u`. interactive_watch mirrors the same TTY check the plain
# menu already gated on, just readable from inside the --watch loop too.
sel_idx=""
interactive_watch=false

# sel_name — the project sel_idx currently points at, remembered by NAME so a
# refresh that re-sorts the columns can put the cursor back on the same
# project rather than on whatever slid into that slot. Kept in step by
# set_sel_idx, which is how the cursor is moved everywhere below.
sel_name=""

# sel_row: which metric ROW the cell cursor is on, as an index into
# ROW_LABELS. Together with sel_idx it names one CELL — "project-a /
# running" — which is what Enter drills into. Empty in every non-interactive
# mode, exactly like sel_idx, so the same render path serves a piped board.
#
# ROW_LABELS is the grid's rows in the order render_text prints them, and it
# is also the metric vocabulary lv-tray-drill.sh routes on (`row <metric>`).
# One list, so a row added to the grid and a row you can open are the same
# thing by construction — the alternative is a board with a cell nothing
# happens on and no way to tell which.
ROW_LABELS=(daemon running gates attn ideas draft ready active verify testing
            accept complete abandoned release deploy registry)
sel_row=""

# key_eof: set by read_key when stdin is closed rather than merely quiet. Every
# keyboard loop here treats "no key" as "try again", which is correct for a
# timeout and an infinite spin for EOF.
key_eof=false
# eof_streak: consecutive timed reads that came back as exit 1 without
# spending their timeout — see read_key, where a closed stdin is told apart
# from a bash 3.2 `-t` expiry by exactly this run.
eof_streak=0

# win_start/win_end/shown_n: the sliding window of columns the grid
# actually draws — [win_start, win_end) into the activity-sorted arrays,
# shown_n = win_end - win_start. Set by compute_shown, read by render_text
# and by the hybrid --watch key handler so both agree on which columns are
# on-screen. win_start persists across frames (unlike shown_n/win_end,
# which compute_shown derives fresh each time) so arrow keys can slide it
# one column at a time rather than jumping whole pages.
win_start=0
win_end=0
shown_n=0

# Background refresh state (hybrid --watch only). A full collect_all()
# shells out to every client's lv-tray.sh --fields — real subprocess
# work that can take a few seconds — so it now runs in a backgrounded
# subshell that serializes its findings to refresh_file, while the main
# loop keeps polling read_key on a short timeout. That's what makes arrow
# navigation instant even mid-refresh: moving sel_idx and repainting only
# ever touches the arrays already in memory, never waits on the fetch.
# refreshing/spin_i drive the header glyph so there's still a visible
# "working" signal, without the ticking clock that used to rewrite the
# header (and read as a bounce) on every single redraw.
refresh_pid=""
refresh_file=""
refreshing=false
# Set by skill_session when a Claude session hands the terminal back, along
# with to_main below, so every level it can be started from unwinds; then
# resume_board turns it into a fresh collect: the session moved plans, so the
# level it was opened from is stale — usually emptied.
back_to_board=false
# Set by `m` on any screen below the board, and by skill_session. Every level
# returns at once on it instead of one level up, which is Esc's job; the board
# (or, without --watch, the picker) is where it stops and is cleared. q quits,
# and only on the main screen: it used to mean "back to the board" one level
# down and "quit" on the board itself.
to_main=false
spin_i=0
SPIN_FRAMES=("⏳" "⌛")
IDLE_GLYPH="·"
POLL_SECS=1
next_refresh_at=0

# ── Gather ──────────────────────────────────────────────────────────────
# Bash 3.2 (macOS default) has no associative arrays, so each metric gets
# its own indexed array, all kept in step by project position.
names=(); paths=(); statuses=()
f_daemon=(); f_running=()
f_gates=(); f_gates_stuck=(); f_gates_blocked=()
f_draft=(); f_ready=(); f_active=(); f_verify=(); f_testing=(); f_complete=(); f_abandoned=()
f_registry=(); f_attn=(); f_release=(); f_deploy=(); f_ideas=(); f_ideas_drift=(); f_accept=(); f_claims=()
# f_ts: when THIS project's numbers were collected, per project rather than
# per frame. A collect walks every client in turn and a menu action re-fetches
# exactly one, so "the frame's age" is several different ages — and the column
# that was just refreshed is precisely the one you want to see go white again.
f_ts=()

# fetch_one <project_path> — one project's status line, as a single
# 0x1f-separated record (status first, then the same fields lv-tray.sh
# --fields reports, "-"/0 for anything not "ok") — 0x1f rather than a tab
# because `attn` is legitimately empty when nothing is gated, and a tab is
# IFS whitespace: `read -ra` collapses a run of it and silently drops the
# empty field, one short of what apply_record expects (same convention
# wf_registry_rows uses, per lv-orch-lib.sh, for the same reason). Factored
# out of collect() so the interactive menu can re-fetch just the one
# project it acted on (toggle_daemon → refresh_one) without re-querying
# all five.
fetch_one() {
  local project_path="$1" status line
  if [ ! -d "$project_path" ]; then
    status="missing"
  elif ! has_harness "$project_path"; then
    status="noharness"
  elif line=$(cd "$project_path" && hx lv-tray.sh --fields 2>/dev/null) && [ -n "$line" ]; then
    status="ok"
  else
    status="failed"
  fi

  if [ "$status" != "ok" ]; then
    printf '%s\x1f-\x1f-\x1f-\x1f0\x1f0\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f-\x1f%s\n' "$status" "$(date +%s)"
    return 0
  fi

  local tok key val
  local daemon="-" running=0 gates=0 gates_stuck=0 gates_blocked=0
  local draft=0 ready=0 active=0 verify=0 testing=0 accept=0 complete=0 abandoned=0 registry="-" attn="" release="-" deploy="-"
  local ideas=0 ideas_drift=0 claims=""
  IFS=$'\t' read -ra _toks <<< "$line"
  for tok in "${_toks[@]}"; do
    key="${tok%%=*}"; val="${tok#*=}"
    case "$key" in
      daemon)       daemon="$val" ;;
      running)      running="$val" ;;
      gates)        gates="$val" ;;
      gates_stuck)  gates_stuck="$val" ;;
      gates_blocked) gates_blocked="$val" ;;
      draft)        draft="$val" ;;
      ready)        ready="$val" ;;
      active)       active="$val" ;;
      verify)       verify="$val" ;;
      testing)      testing="$val" ;;
      # accept:manual. An older client emits no key; the 0 default stands.
      accept)       accept="$val" ;;
      complete)     complete="$val" ;;
      abandoned)    abandoned="$val" ;;
      registry)     registry="$val" ;;
      attn)         attn="$val" ;;
      release_pending) release="$val" ;;
      deploy_pending) deploy="$val" ;;
      # Briefs still at Idea/Exploring — thinking that was started and never
      # carried to a decision — plus the count of brief files missing from
      # INDEX.md. A client on an older harness emits neither key; the 0
      # defaults above stand in, so a mixed-version portfolio shows a row of
      # zeros rather than a broken grid.
      brainstorms)       ideas="$val" ;;
      brainstorms_drift) ideas_drift="$val" ;;
      # Live claims held by an attended session (lv-tray.sh). An older client
      # emits no key; empty stands in and the board shows no work in hand.
      claims)       claims="$val" ;;
    esac
  done
  # The collection time is the LAST field, so a record written by an older
  # copy of this script (or read out of a stale snapshot) is simply one field
  # short and defaults, rather than shifting every field along by one. Claims
  # ride AFTER it for the same reason: a record without them is one field
  # short, and the timestamp stays where every older reader looks for it.
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$status" "$daemon" "$running" "$gates" "$gates_stuck" "$gates_blocked" \
    "$draft" "$ready" "$active" "$verify" "$testing" "$complete" "$abandoned" \
    "$registry" "$attn" "$release" "$deploy" "$ideas" "$ideas_drift" "$accept" "$(date +%s)" "$claims"
}

# apply_record <record> <append|index> — write a fetch_one record into the
# f_* arrays, either appended (initial collect) or at one index (refresh
# after a menu action). Keeps the two call sites from drifting apart.
apply_record() {
  local rec="$1" where="$2"
  local -a f; IFS=$'\x1f' read -ra f <<< "$rec"
  if [ "$where" = "append" ]; then
    statuses+=("${f[0]}")
    f_daemon+=("${f[1]}"); f_running+=("${f[2]}")
    f_gates+=("${f[3]}"); f_gates_stuck+=("${f[4]}"); f_gates_blocked+=("${f[5]}")
    f_draft+=("${f[6]}"); f_ready+=("${f[7]}"); f_active+=("${f[8]}"); f_verify+=("${f[9]}")
    f_testing+=("${f[10]}"); f_complete+=("${f[11]}"); f_abandoned+=("${f[12]}")
    f_registry+=("${f[13]}"); f_attn+=("${f[14]}"); f_release+=("${f[15]}"); f_deploy+=("${f[16]}")
    # `:-0`: a record written by an older copy of this script, or read back
    # mid-upgrade, is two fields short — default rather than leave a hole the
    # render reads as an empty cell.
    f_ideas+=("${f[17]:-0}"); f_ideas_drift+=("${f[18]:-0}")
    f_accept+=("${f[19]:-0}")
    f_ts+=("${f[20]:-0}")
    f_claims+=("${f[21]:-}")
  else
    local idx="$where"
    statuses[$idx]="${f[0]}"
    f_daemon[$idx]="${f[1]}"; f_running[$idx]="${f[2]}"
    f_gates[$idx]="${f[3]}"; f_gates_stuck[$idx]="${f[4]}"; f_gates_blocked[$idx]="${f[5]}"
    f_draft[$idx]="${f[6]}"; f_ready[$idx]="${f[7]}"; f_active[$idx]="${f[8]}"; f_verify[$idx]="${f[9]}"
    f_testing[$idx]="${f[10]}"; f_complete[$idx]="${f[11]}"; f_abandoned[$idx]="${f[12]}"
    f_registry[$idx]="${f[13]}"; f_attn[$idx]="${f[14]}"; f_release[$idx]="${f[15]}"; f_deploy[$idx]="${f[16]}"
    f_ideas[$idx]="${f[17]:-0}"; f_ideas_drift[$idx]="${f[18]:-0}"
    f_accept[$idx]="${f[19]:-0}"
    f_ts[$idx]="${f[20]:-0}"
    f_claims[$idx]="${f[21]:-}"
  fi
}

# gate_in_hand <attn-token> <claims> — 0 when a session is working the gate
# right now. A plan's gate is in hand when its number is claimed. RELEASE and
# DEPLOY are one promotion: a deploy gate ("the release tip failed the deploy
# suite") is answered by a new /lv-release as much as by /lv-deploy, so a claim
# on either puts a gate on either in hand.
gate_in_hand() {
  local tok="${1%\~}" claims=",${2:-},"
  tok="${tok%!}"
  [ "$claims" = ",," ] && return 1
  case "$tok" in
    RELEASE|DEPLOY) [[ "$claims" == *,RELEASE,* || "$claims" == *,DEPLOY,* ]] ;;
    ''|*[!0-9]*) return 1 ;;
    *) [[ "$claims" == *",$((10#$tok)),"* ]] ;;
  esac
}

# project_record <index> — the arrays turned back into one fetch_one record.
# The inverse of apply_record, and the only thing that has to change in step
# with it; the snapshot writer below serialises through this rather than
# naming all twenty fields a second time.
project_record() {
  local i="$1"
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s' \
    "${statuses[$i]}" "${f_daemon[$i]}" "${f_running[$i]}" \
    "${f_gates[$i]}" "${f_gates_stuck[$i]}" "${f_gates_blocked[$i]}" \
    "${f_draft[$i]}" "${f_ready[$i]}" "${f_active[$i]}" "${f_verify[$i]}" \
    "${f_testing[$i]}" "${f_complete[$i]}" "${f_abandoned[$i]}" \
    "${f_registry[$i]}" "${f_attn[$i]}" "${f_release[$i]}" "${f_deploy[$i]}" \
    "${f_ideas[$i]}" "${f_ideas_drift[$i]}" "${f_accept[$i]:-0}" "${f_ts[$i]:-0}" "${f_claims[$i]:-}"
}

# refresh_one <index> — re-fetch and overwrite just that project's fields.
refresh_one() {
  apply_record "$(fetch_one "${paths[$1]}")" "$1"
}

# activity_ts <project_path> — unix epoch of the most recent signal seen
# for this project: its latest git commit, or its orchestrator's last
# event (by that file's mtime — cheaper than parsing the ISO timestamp
# inside it, and the mtime already tracks the most recent line appended).
# 0 when neither exists, so a client with no git history and no
# orchestrator activity yet sorts last rather than erroring.
activity_ts() {
  local path="$1" ts=0 t
  if [ -d "$path/.git" ]; then
    t=$(cd "$path" && git log -1 --format=%ct 2>/dev/null)
    [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt "$ts" ] && ts="$t"
  fi
  local ev="$path/.claude/orchestrator/events.log"
  if [ -f "$ev" ]; then
    t=$(stat -f %m "$ev" 2>/dev/null || stat -c %Y "$ev" 2>/dev/null)
    [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -gt "$ts" ] && ts="$t"
  fi
  printf '%s' "$ts"
}

# sort_projects_by_activity — reorder every project-keyed array by
# activity_ts descending (ties broken by original registry order,
# so repeated --watch refreshes don't jitter). Bash 3.2 has no sort
# builtin for parallel arrays, so route "activity<TAB>index" lines through
# the real `sort` and rebuild each array from the order that comes back.
sort_projects_by_activity() {
  local n="${#names[@]}"
  [ "$n" -le 1 ] && return
  local i order idx
  local -a acts=()
  for i in "${!names[@]}"; do acts+=("$(activity_ts "${paths[$i]}")"); done
  order=$(for i in "${!names[@]}"; do printf '%s\t%s\n' "${acts[$i]}" "$i"; done \
    | sort -t $'\t' -k1,1nr -k2,2n | cut -f2)
  local -a o_names=() o_paths=() o_statuses=()
  local -a o_daemon=() o_running=()
  local -a o_gates=() o_gates_stuck=() o_gates_blocked=()
  local -a o_draft=() o_ready=() o_active=() o_verify=() o_testing=() o_complete=() o_abandoned=()
  local -a o_registry=() o_attn=() o_release=() o_deploy=() o_ideas=() o_ideas_drift=() o_accept=() o_ts=() o_claims=()
  while IFS= read -r idx; do
    o_names+=("${names[$idx]}"); o_paths+=("${paths[$idx]}"); o_statuses+=("${statuses[$idx]}")
    o_daemon+=("${f_daemon[$idx]}"); o_running+=("${f_running[$idx]}")
    o_gates+=("${f_gates[$idx]}"); o_gates_stuck+=("${f_gates_stuck[$idx]}"); o_gates_blocked+=("${f_gates_blocked[$idx]}")
    o_draft+=("${f_draft[$idx]}"); o_ready+=("${f_ready[$idx]}"); o_active+=("${f_active[$idx]}"); o_verify+=("${f_verify[$idx]}")
    o_testing+=("${f_testing[$idx]}"); o_complete+=("${f_complete[$idx]}"); o_abandoned+=("${f_abandoned[$idx]}")
    o_registry+=("${f_registry[$idx]}"); o_attn+=("${f_attn[$idx]}"); o_release+=("${f_release[$idx]}"); o_deploy+=("${f_deploy[$idx]}")
    o_ideas+=("${f_ideas[$idx]}"); o_ideas_drift+=("${f_ideas_drift[$idx]}")
    o_accept+=("${f_accept[$idx]:-0}")
    o_ts+=("${f_ts[$idx]:-0}")
    o_claims+=("${f_claims[$idx]:-}")
  done <<< "$order"
  names=("${o_names[@]}"); paths=("${o_paths[@]}"); statuses=("${o_statuses[@]}")
  f_daemon=("${o_daemon[@]}"); f_running=("${o_running[@]}")
  f_gates=("${o_gates[@]}"); f_gates_stuck=("${o_gates_stuck[@]}"); f_gates_blocked=("${o_gates_blocked[@]}")
  f_draft=("${o_draft[@]}"); f_ready=("${o_ready[@]}"); f_active=("${o_active[@]}"); f_verify=("${o_verify[@]}")
  f_testing=("${o_testing[@]}"); f_complete=("${o_complete[@]}"); f_abandoned=("${o_abandoned[@]}")
  f_registry=("${o_registry[@]}"); f_attn=("${o_attn[@]}"); f_release=("${o_release[@]}"); f_deploy=("${o_deploy[@]}")
  f_ideas=("${o_ideas[@]}"); f_ideas_drift=("${o_ideas_drift[@]}")
  f_accept=("${o_accept[@]}")
  f_ts=("${o_ts[@]}")
  f_claims=("${o_claims[@]}")
}

# fit_cols — MAX_COLS from the terminal width: the 11-column row label, then
# as many cells as fit at the width render_text will give them (the longest
# project name, at least 10, plus a space). The attn cell can widen a column
# past that, which is why one cell of slack is left over.
fit_cols() {
  local w cw=10 n
  w=$(term_cols)
  for n in ${names[@]+"${names[@]}"}; do [ "${#n}" -gt "$cw" ] && cw="${#n}"; done
  cw=$((cw + 1))
  MAX_COLS=$(( (w - 11 - cw) / cw ))
  [ "$MAX_COLS" -lt 1 ] && MAX_COLS=1
}

# compute_shown — recomputes win_end/shown_n from win_start: everyone
# under --all (window pinned at the start), else a MAX_COLS-wide window
# starting at win_start. Clamps win_start itself in case the roster
# shrank (or --all was just turned off) and the old offset no longer
# fits. Computed once per collect rather than inline twice, since
# render_text and the hybrid --watch key handler both need to agree on
# where the window sits.
compute_shown() {
  local total_n="${#names[@]}"
  fit_cols
  if $show_all; then
    win_start=0
    shown_n="$total_n"
  else
    local max_start=$(( total_n - MAX_COLS ))
    [ "$max_start" -lt 0 ] && max_start=0
    [ "$win_start" -gt "$max_start" ] && win_start="$max_start"
    [ "$win_start" -lt 0 ] && win_start=0
    shown_n=$(( total_n - win_start ))
    [ "$shown_n" -gt "$MAX_COLS" ] && shown_n="$MAX_COLS"
  fi
  win_end=$(( win_start + shown_n ))

  # A refresh can shrink the roster out from under an in-progress
  # highlight/window (a client dropped from the registry mid-session);
  # re-clamp sel_idx into whatever window survived rather than leaving it
  # pointing past the end.
  if [ -n "$sel_idx" ]; then
    local last=$(( total_n - 1 )); [ "$last" -lt 0 ] && last=0
    [ "$sel_idx" -gt "$last" ] && sel_idx="$last"
    [ "$sel_idx" -lt "$win_start" ] && sel_idx="$win_start"
    [ "$sel_idx" -gt "$((win_end - 1))" ] && sel_idx=$((win_end - 1))
  fi
}

collect() {
  local project_path name
  while IFS= read -r project_path; do
    [ -n "$project_path" ] || continue
    name=$(basename "$project_path")
    names+=("$name"); paths+=("$project_path")
    apply_record "$(fetch_one "$project_path")" "append"
  done <<< "$(scan_projects)"
  sort_projects_by_activity
}

# ── Snapshots ───────────────────────────────────────────────────────────
#
# The grid and every drill level are cached as JSON so a frame can be painted
# before anything is fetched. jq does both the reading and the writing: every
# field here is free text off a client (a project name, a gate's prose, a
# brief's blurb) and hand-rolled JSON escaping is the kind of thing that works
# until the day a quote or a backslash lands in it. No jq, no cache — and
# every call site treats a failed load as a cold start, which is exactly what
# this was before the cache existed.

# snapshot_save — the arrays as they stand, atomically. Called after a
# collect, never on the interactive path, so a failure costs a cold start on
# the next run and nothing else.
snapshot_save() {
  $HAVE_JQ || return 0
  [ "${#names[@]}" -gt 0 ] || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  local tmp i
  tmp=$(mktemp "$CACHE_DIR/.grid.XXXXXX" 2>/dev/null) || return 0
  if for i in "${!names[@]}"; do
       printf '%s\x1f%s\x1f%s\n' "${names[$i]}" "${paths[$i]}" "$(project_record "$i")"
     done | jq -R -s --argjson now "$(date +%s)" '
       {schema: 1, saved_at: $now,
        projects: (split("\n") | map(select(length > 0)) | map(split("\u001f")) | map({
          name: .[0], path: .[1], status: .[2], daemon: .[3], running: .[4],
          gates: .[5], gates_stuck: .[6], gates_blocked: .[7],
          draft: .[8], ready: .[9], active: .[10], verify: .[11], testing: .[12],
          complete: .[13], abandoned: .[14], registry: .[15], attn: .[16],
          release: .[17], deploy: .[18], ideas: .[19], ideas_drift: .[20],
          accept: .[21],
          fetched_at: ((.[22] | tonumber?) // 0),
          claims: (.[23] // "")
        }))}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$GRID_SNAPSHOT" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# snapshot_load — fill the arrays from the last saved grid. Returns 1 for
# anything that isn't a usable snapshot (no jq, no file, a truncated write, a
# schema this copy doesn't know) so the caller falls back to collecting.
#
# The per-project fetched_at comes back with it, which is the point: a
# snapshot from four minutes ago paints instantly AND paints dark grey, so the
# first frame of a cold start is never mistaken for live numbers.
snapshot_load() {
  $HAVE_JQ || return 1
  [ -s "$GRID_SNAPSHOT" ] || return 1
  local rows
  rows=$(jq -r 'select(.schema == 1) | .projects[]? |
      [.name, .path, .status, .daemon, .running, .gates, .gates_stuck, .gates_blocked,
       .draft, .ready, .active, .verify, .testing, .complete, .abandoned,
       .registry, .attn, .release, .deploy, .ideas, .ideas_drift,
       (.accept // "0"),
       (.fetched_at | tostring),
       (.claims // "")]
      | map(. // "") | join("\u001f")' "$GRID_SNAPSHOT" 2>/dev/null) || return 1
  [ -n "$rows" ] || return 1

  names=(); paths=(); statuses=()
  f_daemon=(); f_running=()
  f_gates=(); f_gates_stuck=(); f_gates_blocked=()
  f_draft=(); f_ready=(); f_active=(); f_verify=(); f_testing=(); f_complete=(); f_abandoned=()
  f_registry=(); f_attn=(); f_release=(); f_deploy=(); f_ideas=(); f_ideas_drift=(); f_accept=(); f_ts=(); f_claims=()
  local line rec
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    local -a f; IFS=$'\x1f' read -ra f <<< "$line"
    [ "${#f[@]}" -ge 3 ] || continue
    names+=("${f[0]}"); paths+=("${f[1]}")
    rec=$(printf '%s' "$line" | cut -d$'\x1f' -f3-)
    apply_record "$rec" "append"
  done <<< "$rows"
  [ "${#names[@]}" -gt 0 ]
}

# node_cache_file <project_path> <argv> — where one drill level's last answer
# lives. Keyed on both, since the same argv means different things in
# different projects. The hash is for a safe filename, not for secrecy.
node_cache_file() {
  local key
  key=$(printf '%s\x1f%s' "$1" "$2" | shasum 2>/dev/null | cut -c1-16)
  [ -n "$key" ] || key="unkeyed"
  printf '%s/node-%s.json' "$CACHE_DIR" "$key"
}

# node_cache_save <project_path> <argv> <rc> <output> — one drill level. The
# exit status is cached alongside the lines because it carries meaning the
# lines cannot: rc 1 is "nothing here right now", which looks identical to an
# empty answer from a fetch that failed outright.
node_cache_save() {
  $HAVE_JQ || return 0
  mkdir -p "$CACHE_DIR" 2>/dev/null || return 0
  local file tmp
  file=$(node_cache_file "$1" "$2")
  tmp=$(mktemp "$CACHE_DIR/.node.XXXXXX" 2>/dev/null) || return 0
  if printf '%s' "$4" | jq -R -s \
       --argjson now "$(date +%s)" --argjson rc "$3" \
       --arg project "$1" --arg argv "$2" '
       {schema: 1, project: $project, argv: $argv, fetched_at: $now, rc: $rc,
        lines: (split("\n") | map(select(length > 0)))}' > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
  return 0
}

# node_cache_load <project_path> <argv> — prints "<fetched_at>\x1f<rc>" as its
# first line and the cached display lines after it; returns 1 when there is no
# usable cache. One stream rather than three lookups, because each one is a
# jq fork and this sits between a keypress and a repaint.
node_cache_load() {
  $HAVE_JQ || return 1
  local file; file=$(node_cache_file "$1" "$2")
  [ -s "$file" ] || return 1
  jq -r 'select(.schema == 1) |
         ((.fetched_at | tostring) + "\u001f" + (.rc | tostring)),
         (.lines[]?)' "$file" 2>/dev/null
}

# ── Age ─────────────────────────────────────────────────────────────────

# age_bucket <collected-at> [now] — 0 fresh, 1 going stale, 2 old. A
# timestamp of 0, or one that didn't parse (a record from before this
# existed, a snapshot field that failed to read), is bucket 2: unknown age is
# old age, never fresh — the one direction in which being wrong is harmless.
age_bucket() {
  local ts="${1:-0}" now="${2:-}" age
  case "$ts" in ''|*[!0-9]*) printf '2'; return 0 ;; esac
  [ "$ts" -gt 0 ] || { printf '2'; return 0; }
  [ -n "$now" ] || now=$(date +%s)
  age=$(( now - ts ))
  if   [ "$age" -le "$AGE_FRESH" ]; then printf '0'
  elif [ "$age" -le "$AGE_MID" ];   then printf '1'
  else                                   printf '2'
  fi
}

# age_color <collected-at> [now] — the tint for that bucket.
age_color() {
  case "$(age_bucket "$1" "${2:-}")" in
    0) printf '%s' "$AGE0" ;;
    1) printf '%s' "$AGE1" ;;
    *) printf '%s' "$AGE2" ;;
  esac
}

# age_signature — one token summarising every visible column's bucket, so the
# poll loop can repaint when a column CHANGES shade rather than once a second
# forever. Without it the grid redraws sixty times a minute to show the same
# numbers in the same colour.
age_signature() {
  local now i sig=""
  now=$(date +%s)
  for ((i = win_start; i < win_end; i++)); do
    sig="$sig$(age_bucket "${f_ts[$i]:-0}" "$now")"
  done
  printf '%s' "$sig"
}

# newest_visible_ts — the most recent collection time among the columns
# actually on screen. That, not the oldest, is what the header reports: it is
# the answer to "how current is the best thing here", and a single
# unreachable project stuck at ts 0 must not make the whole board read as
# ancient.
newest_visible_ts() {
  local i newest=0
  for ((i = win_start; i < win_end; i++)); do
    case "${f_ts[$i]:-0}" in ''|*[!0-9]*) continue ;; esac
    [ "${f_ts[$i]}" -gt "$newest" ] && newest="${f_ts[$i]}"
  done
  printf '%s' "$newest"
}

# head_age_phrase — the header's age, in words rather than a ticking count.
# Deliberately coarse: it changes at the same boundaries the tint does (and
# then once a minute), so the header is not a second-by-second clock
# rewriting itself under the eye — which is the bounce this board already
# avoided once by taking the timestamp out of --watch.
head_age_phrase() {
  local ts age
  ts=$(newest_visible_ts)
  [ "$ts" -gt 0 ] || { printf 'no data yet'; return; }
  age=$(( $(date +%s) - ts )); [ "$age" -lt 0 ] && age=0
  if   [ "$age" -le "$AGE_FRESH" ]; then printf 'fresh'
  elif [ "$age" -le "$AGE_MID" ];   then printf 'aging'
  elif [ "$age" -lt 120 ];          then printf 'stale'
  else                                   printf '%sm old' "$(( age / 60 ))"
  fi
}

# age_phrase <collected-at> — "12s ago" / "3m ago", for a heading. The grid
# tints; a drill level has one timestamp for the whole pane and says it.
age_phrase() {
  local ts="${1:-0}" now age
  case "$ts" in ''|*[!0-9]*) printf 'age unknown'; return ;; esac
  [ "$ts" -gt 0 ] || { printf 'age unknown'; return; }
  now=$(date +%s); age=$(( now - ts ))
  [ "$age" -lt 0 ] && age=0
  if   [ "$age" -lt 60 ];   then printf '%ss ago' "$age"
  elif [ "$age" -lt 3600 ]; then printf '%sm ago' "$(( age / 60 ))"
  else                           printf '%sh ago' "$(( age / 3600 ))"
  fi
}

# cell <width> <value> [colour] — right-align value in width, colour applied
# outside the padding so escape bytes never throw off alignment.
cell() {
  local w="$1" v="$2" c="${3:-}"
  printf ' %s%*s%s' "$c" "$w" "$v" "$R"
}

# set_sel_idx <index> — move the column cursor, keeping the remembered name
# in step. Every cursor move goes through here so there is exactly one place
# the two can fall out of sync.
set_sel_idx() {
  sel_idx="$1"
  if [ -n "$sel_idx" ] && [ "$sel_idx" -lt "${#names[@]}" ] 2>/dev/null; then
    sel_name="${names[$sel_idx]}"
  else
    sel_name=""
  fi
}

# sel_cell <row-label> <column-index> — true when that cell is the one the
# cursor is on. Both halves have to be set: the non-interactive board leaves
# them empty and must render with nothing highlighted.
sel_cell() {
  [ -n "$sel_row" ] && [ -n "$sel_idx" ] || return 1
  [ "${ROW_LABELS[$sel_row]}" = "$1" ] && [ "$sel_idx" = "$2" ]
}

# row_label <label> — the row's name in the left gutter, bold on the row the
# cursor is on. The cell reverse-video alone is easy to lose track of on a
# wide grid; the lit row name says which metric you are about to open even
# when the highlighted column is off at the far right.
row_label() {
  # The two acceptance rows read as one stage with two flavours, the same as
  # /lv-tray's `accept:auto` / `accept:manual` — abbreviated, because the
  # label column is nine wide. ROW_LABELS keeps the stored state names: they
  # are the drill vocabulary (`row testing`, `row accept`).
  local shown="$1"
  case "$1" in testing) shown="acc:auto" ;; accept) shown="acc:man" ;; esac
  if [ -n "$sel_row" ] && [ "${ROW_LABELS[$sel_row]}" = "$1" ]; then
    printf '  %s%-9s%s' "$B" "$shown" "$R"
  else
    printf '  %-9s' "$shown"
  fi
}

collect_all() {
  names=(); paths=(); statuses=()
  f_daemon=(); f_running=()
  f_gates=(); f_gates_stuck=(); f_gates_blocked=()
  f_draft=(); f_ready=(); f_active=(); f_verify=(); f_testing=(); f_complete=(); f_abandoned=()
  f_registry=(); f_attn=(); f_release=(); f_deploy=(); f_ideas=(); f_ideas_drift=(); f_accept=(); f_ts=(); f_claims=()
  collect
  SVC_KEY=(); SVC_VAL=()
  snapshot_save
  refresh_library_count
}

# start_refresh_async — kick off one collect() worth of work in a
# backgrounded subshell, writing "name<0x1e>path<0x1e>fetch_one-record"
# lines to refresh_file rather than touching the parent's arrays (a
# background job can't write back into this shell's variables). A no-op
# if one is already in flight, so the poll loop can call it freely.
start_refresh_async() {
  $refreshing && return
  refresh_file=$(mktemp "${TMPDIR:-/tmp}/lv-rack.XXXXXX")
  (
    project_path=""
    while IFS= read -r project_path; do
      [ -n "$project_path" ] || continue
      printf '%s\x1e%s\x1e%s\n' "$(basename "$project_path")" "$project_path" "$(fetch_one "$project_path")"
    done <<< "$(scan_projects)"
    refresh_library_count
  ) >"$refresh_file" 2>/dev/null &
  refresh_pid=$!
  refreshing=true
}

# refresh_ready — true once the background job from start_refresh_async
# has exited. kill -0 on our own background PID is a plain liveness check,
# not a signal delivery.
refresh_ready() {
  [ -n "$refresh_pid" ] || return 1
  ! kill -0 "$refresh_pid" 2>/dev/null
}

# finish_refresh — reap the background job, load refresh_file into the
# real arrays (same shape collect() builds by hand), sort and cap exactly
# as a synchronous collect_all would, then clear the in-flight state.
finish_refresh() {
  wait "$refresh_pid" 2>/dev/null
  names=(); paths=(); statuses=()
  f_daemon=(); f_running=()
  f_gates=(); f_gates_stuck=(); f_gates_blocked=()
  f_draft=(); f_ready=(); f_active=(); f_verify=(); f_testing=(); f_complete=(); f_abandoned=()
  f_registry=(); f_attn=(); f_release=(); f_deploy=(); f_ideas=(); f_ideas_drift=(); f_accept=(); f_ts=(); f_claims=()
  if [ -f "$refresh_file" ]; then
    local name path rec
    while IFS=$'\x1e' read -r name path rec; do
      [ -n "$name" ] || continue
      names+=("$name"); paths+=("$path")
      apply_record "$rec" "append"
    done < "$refresh_file"
    rm -f "$refresh_file"
  fi
  sort_projects_by_activity
  # The cursor follows the PROJECT, not the slot. Refreshes now land while
  # the board is being read (and while a drill level is open on top of it),
  # and the sort is by activity — so an unattended refresh can reorder the
  # columns under a stationary cursor and silently point it at a different
  # project than the one you were about to open.
  if [ -n "$sel_idx" ] && [ -n "$sel_name" ]; then
    local s
    for s in "${!names[@]}"; do
      if [ "${names[$s]}" = "$sel_name" ]; then sel_idx="$s"; break; fi
    done
    # Keep the re-found column on screen: it may have moved out of the
    # window entirely, in which case the window follows it.
    if ! $show_all; then
      [ "$sel_idx" -lt "$win_start" ] && win_start="$sel_idx"
      [ "$sel_idx" -ge "$((win_start + MAX_COLS))" ] && win_start=$(( sel_idx - MAX_COLS + 1 ))
      [ "$win_start" -lt 0 ] && win_start=0
    fi
  fi
  compute_shown
  refresh_pid=""; refresh_file=""; refreshing=false
  SVC_KEY=(); SVC_VAL=()
  snapshot_save
}

# board_tick — one turn of the grid's own polling, callable from anywhere
# that is sitting on a keyboard: the board's poll loop, the drill browser,
# the file viewer. That is what makes "poll consistently" true rather than
# "poll while the board happens to be the thing on screen" — spend two
# minutes reading a worker's log and the board behind it is current when you
# come back, with no blocking reload on the way out.
#
# Returns 0 when it absorbed a completed refresh (the arrays just changed, so
# a caller showing the grid should repaint), 1 otherwise.
board_tick() {
  $interactive_watch || return 1
  if $refreshing; then
    refresh_ready || return 1
    finish_refresh
    next_refresh_at=$(( $(date +%s) + watch_secs ))
    return 0
  fi
  [ "$(date +%s)" -ge "$next_refresh_at" ] && start_refresh_async
  return 1
}

# render_text — print the board from whatever the arrays currently hold
# (populated by collect_all or by finish_refresh). Split out of the old
# render() so the array-populating step can run outside any command
# substitution: `x=$(fn)` forks a subshell, and array writes made inside
# it never reach the parent shell. Hybrid --watch needs the real
# names/paths arrays back in the TOP-LEVEL shell (to act on a keypress
# against the right project) while still capturing the printed text for
# render_frame's line diff — so callers populate the arrays directly,
# then capture render_text alone.
render_text() {
  local total_n="${#names[@]}"
  local head="${B}PORTFOLIO BOARD${R}"
  if $watch_mode; then
    # No ticking clock here: with --watch this line repaints every poll
    # tick, and a second-by-second timestamp read as a bounce rather than
    # a heartbeat. The column range plus a glyph that only animates while
    # refreshing is actually happening carries the same "is this live"
    # signal without the flicker. It's a range rather than "page N/M"
    # because the window slides one column at a time (arrow keys), so it
    # generally won't sit on a page boundary.
    local glyph="$IDLE_GLYPH"
    $refreshing && glyph="${SPIN_FRAMES[$spin_i]}"
    if $show_all || [ "$total_n" -le "$MAX_COLS" ]; then
      head+="  ${DIM}${glyph}${R}"
    else
      head+="  ${DIM}cols $((win_start + 1))-${win_end} of ${total_n}  ${glyph}${R}"
    fi
    head+="  ${DIM}$(head_age_phrase)${R}"
  else
    head+="  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${R}"
    if [ "$total_n" -gt "$shown_n" ]; then
      head+="  ${DIM}showing $shown_n of $total_n by activity — --all for full${R}"
    fi
  fi
  printf '%s\n' "$head"

  if [ ! -f "$DEPLOYMENTS" ]; then
    printf '  %sno project registry — the project-registry hook failed (lv-hook.sh --which project-registry)%s\n' "$DIM" "$R"
    return
  fi
  if [ "${#names[@]}" -eq 0 ]; then
    printf '  %sthe project registry is empty%s\n' "$DIM" "$R"
    return
  fi

  local i n cw=10
  for ((i = win_start; i < win_end; i++)); do
    n="${names[$i]}"
    [ "${#n}" -gt "$cw" ] && cw="${#n}"
  done

  # The age tint, once per COLUMN rather than once per cell: `date` is a fork,
  # and this grid is fifteen rows deep. One `now` for the whole frame is also
  # the more truthful reading — every cell in a column was collected by the
  # same fetch_one, so they cannot honestly be different ages.
  local now_ts; now_ts=$(date +%s)
  local -a col_age=()
  for ((i = win_start; i < win_end; i++)); do
    col_age[$i]=$(age_color "${f_ts[$i]:-0}" "$now_ts")
  done

  # Precompute the "needs attention" cell text so its width counts toward
  # the shared column width too — otherwise a project with several gated
  # plans would overrun into the next column instead of wrapping the count
  # into a "(+N)" tail. Indexed by absolute position (not appended) since
  # the window no longer always starts at 0 — the ATTN row below reads
  # these back by that same absolute i.
  local -a f_attn_disp=() f_attn_color=()
  for ((i = win_start; i < win_end; i++)); do
    if [ "${statuses[$i]}" != "ok" ] || [ -z "${f_attn[$i]}" ] || [ "${f_attn[$i]}" = "-" ]; then
      f_attn_disp[$i]="-"; f_attn_color[$i]="$DIM"
      continue
    fi
    local raw="${f_attn[$i]}"
    local -a ids; IFS=',' read -ra ids <<< "$raw"
    local total="${#ids[@]}" shown="" k tok in_hand=0
    local shown_count=$total; [ "$shown_count" -gt 2 ] && shown_count=2
    for ((k = 0; k < shown_count; k++)); do
      tok="${ids[$k]%\~}"; tok="${tok%!}"
      # A single plan gets room to spell out "PLN-" in full; with two shown,
      # bare numbers keep the cell from crowding out its neighbours. RELEASE
      # and DEPLOY are the orchestrator's fixed stage-gate literals (see
      # lv-orchestrate.sh bare_id()), not plan numbers — render them bare
      # either way (WFI-002, client-g).
      case "$tok" in
        RELEASE|DEPLOY) ;;
        *) [ "$shown_count" -eq 1 ] && tok="$LV_PLN-$tok" ;;
      esac
      # `*` is in hand: a session holds this gate's claim right now, so it
      # is being answered, not waiting. See gate_in_hand.
      if gate_in_hand "${ids[$k]}" "${f_claims[$i]:-}"; then
        tok="$tok*"; in_hand=$((in_hand + 1))
      fi
      [ -n "$shown" ] && shown="$shown, $tok" || shown="$tok"
    done
    [ "$total" -gt 2 ] && shown="$shown (+$((total - 2)))"
    # `~` is a collision: a plan at spec-approval whose upstream or
    # directives moved after it was asked (LVI-033). It is marked in the cell,
    # not just coloured, because red already means stuck.
    [[ "$raw" == *\~* ]] && shown="$shown ~"
    f_attn_disp[$i]="$shown"
    if [[ "$raw" == *!* || "$raw" == *\~* ]]; then f_attn_color[$i]="$RED"
    elif [ "$in_hand" -eq "$total" ]; then f_attn_color[$i]="$CYN"
    else f_attn_color[$i]="$YEL"; fi
    [ "${#shown}" -gt "$cw" ] && cw="${#shown}"
  done
  cw=$((cw + 1))

  # ── Header row ────────────────────────────────────────────────────────
  printf '%-11s' ""
  for ((i = win_start; i < win_end; i++)); do
    # The project's own name carries its column's age, so the tint is
    # readable even on a row whose cells are all alert-coloured.
    local hc="${B}${col_age[$i]}"
    [ "${statuses[$i]}" = "ok" ] && [ "${f_gates_stuck[$i]}" -gt 0 ] 2>/dev/null && hc="${B}${RED}"
    [ -n "$sel_idx" ] && [ "$sel_idx" = "$i" ] && hc="${hc}${REV}"
    cell "$cw" "${names[$i]}" "$hc"
  done
  printf '\n'

  # row <label> <array-name> [row-colour-fn-name]
  row() {
    local label="$1" arrname="$2"
    row_label "$label"
    local i val ref
    for ((i = win_start; i < win_end; i++)); do
      # By absolute index, never through a copy: "${arr[@]}" drops indices,
      # so a row filled only at the window's positions (f_daemon_disp) came
      # back renumbered from 0 — another project's value, or an unbound-
      # variable abort once the window had scrolled right (LVI-029).
      ref="${arrname}[$i]"; val="${!ref:-}"
      # An unreachable project stays dim at any age — there is no number
      # there to be fresh or stale about. Everything else is tinted by when
      # its column was collected.
      local c="$DIM"
      [ "${statuses[$i]}" = "ok" ] && c="${col_age[$i]}"
      sel_cell "$label" "$i" && c="${c}${REV}"
      cell "$cw" "$val" "$c"
    done
    printf '\n'
  }

  # The daemon's state reads as what it is doing, not as "running" — that
  # word sat right beside the `running` row label and read as a count of it.
  # f_daemon keeps the raw value (off/running/stale) the toggle logic tests.
  local -a f_daemon_disp=()
  for ((i = win_start; i < win_end; i++)); do
    case "${f_daemon[$i]}" in
      running) if [ "${f_running[$i]:-0}" -gt 0 ] 2>/dev/null; then
                 f_daemon_disp[$i]="cooking"; else f_daemon_disp[$i]="idle"; fi ;;
      *)       f_daemon_disp[$i]="${f_daemon[$i]}" ;;
    esac
  done
  row "daemon" f_daemon_disp

  # SERVICES: what the project declares under `services:`, and how many have a live beacon
  # (`v` lists them). Green while anything runs, so a bridge left up is seen from the grid.
  row_label "services"
  for ((i = win_start; i < win_end; i++)); do
    local ssel=""; sel_cell "services" "$i" && ssel="$REV"
    local sdecl sup; read -r sdecl sup <<< "$(sv_counts "${paths[$i]}")"
    if [ "${sdecl:-0}" -eq 0 ] && [ "${sup:-0}" -eq 0 ]; then cell "$cw" "-" "${DIM}${ssel}"
    elif [ "${sup:-0}" -gt 0 ]; then cell "$cw" "$sup/$sdecl up" "${B}${GRN}${ssel}"
    else cell "$cw" "$sdecl" "${col_age[$i]}${ssel}"; fi
  done
  printf '\n'

  # RUNNING: the daemon's workers, then — in cyan — what attended sessions
  # hold claims on (`0 +RELEASE`). Without the second half a human mid-
  # /lv-release left the column reading idle beside a gate that their own
  # session was answering.
  row_label "running"
  for ((i = win_start; i < win_end; i++)); do
    local rsel=""; sel_cell "running" "$i" && rsel="$REV"
    local rn="${f_running[$i]}" rc="${f_claims[$i]:-}"
    if [ "${statuses[$i]}" != "ok" ]; then
      cell "$cw" "$rn" "${DIM}${rsel}"
    elif [ -n "$rc" ]; then
      local -a cl; IFS=',' read -ra cl <<< "$rc"
      local ctxt="+${cl[0]}"
      [ "${#cl[@]}" -gt 1 ] && ctxt="$ctxt +$((${#cl[@]} - 1))"
      cell "$cw" "$rn $ctxt" "${CYN}${rsel}"
    else
      cell "$cw" "$rn" "${col_age[$i]}${rsel}"
    fi
  done
  printf '\n'

  # GATES gets its own logic: stuck count in red, otherwise dim/plain.
  row_label "gates"
  for ((i = win_start; i < win_end; i++)); do
    local gsel=""; sel_cell "gates" "$i" && gsel="$REV"
    if [ "${statuses[$i]}" != "ok" ]; then
      cell "$cw" "-" "${DIM}${gsel}"; continue
    fi
    local g="${f_gates[$i]}" gs="${f_gates_stuck[$i]}"
    if [ "$gs" -gt 0 ] 2>/dev/null; then
      cell "$cw" "${g}(${gs}!)" "${RED}${gsel}"
    elif [ "$g" -gt 0 ] 2>/dev/null; then
      cell "$cw" "$g" "${YEL}${gsel}"
    else
      cell "$cw" "$g" "${col_age[$i]}${gsel}"
    fi
  done
  printf '\n'

  # ATTN: up to 2 gated plan IDs per project, oldest/most-blocking first
  # (same order lv-list-gates.sh already sorted them in), "(+N)" for the
  # rest. Red if any of them is stuck, yellow otherwise — a plain decision
  # waiting on a human, not a stall.
  row_label "attn"
  for ((i = win_start; i < win_end; i++)); do
    local asel=""; sel_cell "attn" "$i" && asel="$REV"
    cell "$cw" "${f_attn_disp[$i]}" "${f_attn_color[$i]}${asel}"
  done
  printf '\n\n'

  # IDEAS: briefs still at `## Idea` / `## Exploring` — thinking started and
  # never carried to a decision. It sits above `draft` because that is where
  # it sits in the pipeline: a brief has no REGISTRY row until it becomes a
  # plan, so nothing else on this grid can show it, and an idea captured
  # months ago is the one thing here that never announces itself. A `+N` tail
  # counts brief files with no INDEX.md row at all (lv-brainstorm-reindex.sh
  # is the repair); parked briefs are in neither number.
  row_label "ideas"
  for ((i = win_start; i < win_end; i++)); do
    local iv="${f_ideas[$i]}" idr="${f_ideas_drift[$i]}"
    local isel=""; sel_cell "ideas" "$i" && isel="$REV"
    if [ "${statuses[$i]}" != "ok" ]; then
      cell "$cw" "-" "${DIM}${isel}"
    elif [ "${idr:-0}" -gt 0 ] 2>/dev/null; then
      cell "$cw" "${iv}+${idr}" "${YEL}${isel}"
    elif [ "${iv:-0}" -gt 0 ] 2>/dev/null; then
      cell "$cw" "$iv" "${col_age[$i]}${isel}"
    else
      cell "$cw" "${iv:-0}" "${DIM}${isel}"
    fi
  done
  printf '\n'

  row "draft" f_draft
  row "ready" f_ready
  row "active" f_active
  row "verify" f_verify
  row "testing" f_testing
  row "accept" f_accept
  row "complete" f_complete
  row "abandoned" f_abandoned

  # RELEASE: plans complete on `develop` but never carried through
  # /lv-release — the gap no REGISTRY state can show, since `complete`
  # looks identical whether release ran yesterday or never. Yellow when
  # non-zero, same treatment as DEPLOY below.
  row_label "release"
  for ((i = win_start; i < win_end; i++)); do
    local rv="${f_release[$i]}"
    local rsel=""; sel_cell "release" "$i" && rsel="$REV"
    if [ "${statuses[$i]}" != "ok" ] || [ "$rv" = "-" ]; then
      cell "$cw" "-" "${DIM}${rsel}"
    elif [ "$rv" -gt 0 ] 2>/dev/null; then
      cell "$cw" "$rv" "${YEL}${rsel}"
    else
      cell "$cw" "$rv" "${DIM}${rsel}"
    fi
  done
  printf '\n'

  # DEPLOY: plans on `release` but not yet on `main` — staged for
  # /lv-deploy. Yellow when non-zero (it's waiting on a human action, same
  # as a gate), dim at zero, "-" for a project with no release/main split.
  row_label "deploy"
  for ((i = win_start; i < win_end; i++)); do
    local dv="${f_deploy[$i]}"
    local dsel=""; sel_cell "deploy" "$i" && dsel="$REV"
    if [ "${statuses[$i]}" != "ok" ] || [ "$dv" = "-" ]; then
      cell "$cw" "-" "${DIM}${dsel}"
    elif [ "$dv" -gt 0 ] 2>/dev/null; then
      cell "$cw" "$dv" "${YEL}${dsel}"
    else
      cell "$cw" "$dv" "${DIM}${dsel}"
    fi
  done
  printf '\n\n'

  # REGISTRY: dirty count in yellow (a disagreement, not a stall — red is
  # reserved for stuck gates).
  row_label "registry"
  for ((i = win_start; i < win_end; i++)); do
    local qsel=""; sel_cell "registry" "$i" && qsel="$REV"
    if [ "${statuses[$i]}" != "ok" ]; then
      cell "$cw" "-" "${DIM}${qsel}"; continue
    fi
    local rg="${f_registry[$i]}"
    if [ "$rg" = "clean" ]; then
      cell "$cw" "clean" "${DIM}${qsel}"
    else
      cell "$cw" "$rg" "${YEL}${qsel}"
    fi
  done
  printf '\n'

  # HARNESS: the client's installed version against the library's (LVI-026).
  # Read off the stamp here rather than fetched, so it is current on every
  # frame without waiting on a refresh. Yellow when it differs — `U` deploys. Not in
  # ROW_LABELS: there is nothing behind it for lv-tray-drill.sh to open.
  local lib_v="" hv=""
  [ -n "$LIB_DIR" ] && read_stamp lib_v "$LIB_DIR/VERSION"
  row_label "harness"
  for ((i = win_start; i < win_end; i++)); do
    read_stamp hv "${paths[$i]}/.claude/workflow-version"
    if [ -z "$hv" ]; then cell "$cw" "-" "$DIM"
    elif [ -n "$lib_v" ] && [ "$hv" != "$lib_v" ]; then cell "$cw" "$hv" "$YEL"
    else cell "$cw" "$hv" "$DIM"; fi
  done
  printf '\n'
  [ -n "$lib_v" ] && printf '%-11s%slibrary %s%s%s\n' "" "$DIM" "$lib_v" "$(library_sweep_line)" "$R"

  # ── Legend for anything not "ok" ─────────────────────────────────────
  local any_bad=false
  for ((i = win_start; i < win_end; i++)); do
    [ "${statuses[$i]}" = "ok" ] || any_bad=true
  done
  if $any_bad; then
    printf '\n'
    for ((i = win_start; i < win_end; i++)); do
      case "${statuses[$i]}" in
        missing)   printf '  %s%-12s missing directory%s\n' "$DIM" "${names[$i]}" "$R" ;;
        noharness) printf '  %s%-12s harness not installed%s\n' "$DIM" "${names[$i]}" "$R" ;;
        failed)    printf '  %s%-12s board failed — run lv-tray.sh --fields there to see why%s\n' "$DIM" "${names[$i]}" "$R" ;;
      esac
    done
  fi
}

# read_stamp <var> <file> — the file's first line into <var>, empty when it
# is missing. Sets a variable rather than printing: render_text reads one
# client stamp per column per frame, and $(...) would fork for each.
read_stamp() {
  local __v=""
  [ -f "$2" ] && IFS= read -r __v < "$2"
  printf -v "$1" '%s' "$__v"
}
# library_version — the library's VERSION, or nothing when the coordinator
# names no library.
library_version() {
  local v=""
  [ -n "$LIB_DIR" ] && read_stamp v "$LIB_DIR/VERSION"
  printf '%s' "$v"
}

# ── The blind sweep (LVI-031) ───────────────────────────────────────────
#
# The library line carries the number of open client issues (sweep-issues.sh
# --count, summed), refreshed with the board rather than every frame, and the
# state of a blind sweep: `sweeping…` while one runs, its one result line
# after. `W` starts one through lv-library-sweep.sh, detached, so the board
# keeps running. The script holds the lock, runs the session under the
# permission baseline, and decides the deploy itself; a fix to a guard file is
# committed and "held for review" until the operator presses `U`.

# refresh_library_count — the summed count into $SWEEP_STATE/lvis, or the file
# removed when there is no answer. Runs inside the background refresh, so it
# writes a file: a subshell cannot set the board's variables.
refresh_library_count() {
  [ -n "$LIB_DIR" ] && [ -x "$HERE/lv-library-sweep.sh" ] || return 0
  mkdir -p "$SWEEP_STATE" 2>/dev/null || return 0
  local n
  if n=$("$HERE/lv-library-sweep.sh" count "$LIB_DIR" 2>/dev/null) && [ -n "$n" ]; then
    printf '%s\n' "$n" > "$SWEEP_STATE/lvis"
  else
    rm -f "$SWEEP_STATE/lvis"
  fi
}

# library_sweep_line — " · N open issues · sweeping…" or "… · sweep: <result>",
# from files only: render_text calls it every frame.
library_sweep_line() {
  local n="" pid="" res=""
  read_stamp n "$SWEEP_STATE/lvis"
  [ -n "$n" ] && printf ' · %s open issue%s' "$n" "$([ "$n" = 1 ] || printf s)"
  read_stamp pid "$SWEEP_STATE/pid"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    printf ' · sweeping…'
  else
    read_stamp res "$SWEEP_STATE/result"
    [ -n "$res" ] && printf ' · sweep: %s' "$res"
  fi
  return 0
}

# sweep_library — `W`: start a blind sweep. Exit 0 started, 3 refused (the
# script names why: no issues, lock held, a sweep already running, a dirty
# tree, no baseline guard).
sweep_library() {
  if [ -z "$LIB_DIR" ] || [ ! -x "$HERE/lv-library-sweep.sh" ]; then
    printf '  %sno library to sweep — .claude/workflow-source names none, or lv-library-sweep.sh is missing%s\n' "$YEL" "$R"
    return 3
  fi
  printf '%sBLIND SWEEP%s  %s%s — top 3 open client issues, oldest first%s\n\n' "$B" "$R" "$DIM" "$LIB_DIR" "$R"
  local out rc
  out=$("$HERE/lv-library-sweep.sh" start "$LIB_DIR" "$SWEEP_STATE" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then printf '  %s%s%s\n' "$GRN" "$out" "$R"
  else printf '  %s%s%s\n' "$RED" "$out" "$R"; fi
  return "$rc"
}

# deploy_library — `U`: run the library's deploy-all.sh, after the checks that
# make an unattended deploy safe to start from a board. Exit 0 deployed, 3
# refused (the reason is printed), otherwise deploy-all.sh's own exit.
deploy_library() {
  local rc
  if [ -z "$LIB_DIR" ] || [ ! -x "$LIB_DIR/deploy-all.sh" ]; then
    printf '  %sno library to deploy from — .claude/workflow-source names none with a deploy-all.sh%s\n' "$YEL" "$R"
    return 3
  fi
  printf '%sUPDATE THE PORTFOLIO%s  %s%s → version %s%s\n\n' "$B" "$R" "$DIM" "$LIB_DIR" "$(library_version)" "$R"
  # The lock first: a session holding it is mid-edit, and this would publish
  # that half-edit into every client. Any holder refuses, stale included —
  # a stale lock names work that may be half-applied, which is the operator's
  # call (lock.sh --steal), not the board's.
  if [ -x "$LIB_DIR/lock.sh" ]; then
    (cd "$LIB_DIR" && ./lock.sh status >/dev/null 2>&1); rc=$?
    if [ "$rc" -ne 0 ]; then
      printf '  %srefused — LIBRARY-LOCK.md is held:%s\n' "$RED" "$R"
      (cd "$LIB_DIR" && ./lock.sh status 2>&1) | sed 's/^/    /'
      return 3
    fi
  fi
  # A deploy ships what is on disk, not what is committed.
  if [ -n "$(git -C "$LIB_DIR" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    printf '  %srefused — the library has uncommitted changes:%s\n' "$RED" "$R"
    git -C "$LIB_DIR" status --short --untracked-files=no 2>/dev/null | sed 's/^/    /'
    return 3
  fi
  printf '  running the library suite...\n'
  if ! run_library_suite; then
    printf '  %srefused — the suite is red; nothing was deployed%s\n' "$RED" "$R"
    return 3
  fi
  printf '  suite green — deploying\n\n'
  (cd "$LIB_DIR" && ./deploy-all.sh) 2>&1 | sed 's/^/  /'
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    printf '\n  %sdeployed %s%s\n' "$GRN" "$(library_version)" "$R"
    # A blind sweep held for review left its fixes pending: this deploy is
    # the review, so they are resolved now (LVI-031).
    if [ -s "$SWEEP_STATE/pending" ] && [ -x "$HERE/lv-library-sweep.sh" ]; then
      "$HERE/lv-library-sweep.sh" resolve-pending "$LIB_DIR" "$SWEEP_STATE" 2>&1 | sed 's/^/  /'
    fi
  else printf '\n  %sdeploy-all.sh exited %s%s\n' "$RED" "$rc" "$R"; fi
  return "$rc"
}

# run_library_suite — every tests/*.sh in the library, naming each failure.
# LV_RACK_SUITE, when set, is run instead (a command line, from the library).
run_library_suite() {
  if [ -n "${LV_RACK_SUITE:-}" ]; then
    (cd "$LIB_DIR" && bash -c "$LV_RACK_SUITE") >/dev/null 2>&1
    return
  fi
  local t red=0
  for t in "$LIB_DIR"/tests/*.sh; do
    [ -f "$t" ] || continue
    if ! (cd "$LIB_DIR" && bash "$t") >/dev/null 2>&1; then
      printf '    %sFAILED %s%s\n' "$RED" "${t#$LIB_DIR/}" "$R"; red=1
    fi
  done
  return "$red"
}

# render — collect + print, for the two call sites that need both and
# neither one wrapped in a subshell (the initial non-watch board, and
# menu_loop's own redraws).
render() {
  collect_all
  compute_shown
  render_text
}

# render_frame — repaint only the rows that changed since the last frame,
# from whatever is currently in the arrays. Deliberately does NOT collect
# — the caller decides when a fetch is needed (a timer tick) versus when
# the existing data just needs to be redrawn (an arrow key, a spinner
# tick), which is what keeps navigation instant even while a background
# refresh is running. A full `\033[2J` clear-then-redraw blanks the whole
# terminal for one tick before the new content lands, which is what reads
# as flicker — most rows in a portfolio grid are unchanged between
# refreshes, so redrawing all of them every tick is mostly wasted motion
# anyway. Instead: render into a string, diff it line-by-line (one grid
# row per line) against the previous frame, and only move the cursor and
# repaint lines whose text actually differs. A frame shorter than the last
# (a project dropped from the "not ok" legend, say) still needs its
# leftover tail blanked.
prev_lines=()
render_frame() {
  local content; content=$(render_text)
  local -a new_lines=()
  local line
  while IFS= read -r line; do new_lines+=("$line"); done <<< "$content"
  new_lines+=("")
  if $interactive_watch; then
    # The legend is the three shades themselves, drawn in the shades they
    # name: "fresh → aging → stale" spelled out in white, grey and dark grey
    # explains the tint in less space than a sentence about it would.
    new_lines+=("$(printf '%s%ss poll — %sfresh%s %s→ aging%s %s→ stale%s%s — arrows move the cell, enter opens it, d %s %s, a acts on it, 1-%d project, m all %d, s/R all daemons, z on/dormant, v services, q quit%s' \
      "$DIM" "$watch_secs" \
      "$AGE0" "$R" "$AGE1" "$R" "$AGE2" "$R" "$DIM" \
      "$([ "${f_daemon[$sel_idx]}" = "running" ] && echo "stops" || echo "starts")" \
      "${names[$sel_idx]}" "$shown_n" "${#names[@]}" "$R")")
  else
    new_lines+=("$(printf '%srefreshing every %ss — Ctrl-C to stop%s' "$DIM" "$watch_secs" "$R")")
  fi

  local i row new_n="${#new_lines[@]}" prev_n="${#prev_lines[@]}"
  for ((i = 0; i < new_n; i++)); do
    row=$((i + 1))
    if [ "$i" -ge "$prev_n" ] || [ "${new_lines[$i]}" != "${prev_lines[$i]}" ]; then
      printf '\033[%d;1H\033[K%s' "$row" "${new_lines[$i]}"
    fi
  done
  if [ "$prev_n" -gt "$new_n" ]; then
    for ((i = new_n; i < prev_n; i++)); do
      printf '\033[%d;1H\033[K' "$((i + 1))"
    done
  fi
  prev_lines=("${new_lines[@]}")
}

# toggle_daemon <index> — start or stop that project's orchestrator daemon,
# through its own lv-exec.sh so the versioned dispatch stays intact, then
# refresh that project's own fields. `--daemon` never returns on its own
# (it sweeps forever), so starting it backgrounds via nohup with its
# stdout/stderr kept in the client's own orchestrator logs, the same place
# every worker log already lives — nowhere in this repo, on purpose,
# since lv-rack is a viewer/dispatcher, not a place client state
# belongs. A short sleep gives it time to either write daemon.pid or fail
# fast (already running, orchestrator.enabled: false) before we re-check.
toggle_daemon() {
  local i="$1" log=""
  local path="${paths[$i]}" name="${names[$i]}"
  if [ "${f_daemon[$i]}" = "running" ]; then
    echo "  stopping daemon for ${name}..."
    (cd "$path" && hx lv-orchestrate.sh --stop)
  else
    local logdir="$path/.claude/orchestrator/logs"
    mkdir -p "$logdir"
    log="$logdir/daemon.out"
    echo "  starting daemon for ${name}..."
    (cd "$path" && hx_resolve . lv-orchestrate.sh && nohup "$HX_EXEC" "$HX_NAME" --daemon >>"$log" 2>&1 &)
    sleep 1
  fi
  refresh_one "$i"
  if [ "${f_daemon[$i]}" = "running" ]; then
    echo "  ${name}: daemon running"
  elif [ -n "$log" ]; then
    echo "  ${name}: daemon off — check ${log#$path/} for why"
  else
    echo "  ${name}: daemon off"
  fi
}

# daemon_toggle_screen <index> — the whole screen behind the `d` key: name the
# project, toggle its daemon (or say why it can't be), and leave the result on
# screen. Does not wait for a keypress and does not restore the caller's
# screen, because the callers differ on both: the grid redraws itself through
# resume_board, a drill level repaints its own pane.
daemon_toggle_screen() {
  local i="$1"
  printf '\033[2J\033[H'
  printf '%s%s%s  %s%s%s\n\n' "$B" "${names[$i]}" "$R" "$DIM" "${paths[$i]}" "$R"
  if [ "${statuses[$i]}" = "ok" ]; then
    toggle_daemon "$i"
  else
    printf '  status: %s — orchestrator unreachable\n' "${statuses[$i]}"
  fi
}

# sweep_now <index> — one foreground `lv-orchestrate.sh --sweep`: dispatch
# everything eligible right now and return, no daemon left running. Same
# require_enabled gate as the daemon, same reason a disabled project just
# prints why and does nothing.
sweep_now() {
  local i="$1"
  local path="${paths[$i]}" name="${names[$i]}"
  echo "  sweeping ${name}..."
  (cd "$path" && hx lv-orchestrate.sh --sweep)
  refresh_one "$i"
}

# kill_all <index> — daemon down AND every live worker terminated. The one
# action here that can cut off in-progress work rather than just stop new
# work from starting, so it asks first.
kill_all() {
  local i="$1" confirm
  local path="${paths[$i]}" name="${names[$i]}"
  printf '  kill the daemon AND every live worker for %s? [y/N] ' "$name"
  IFS= read -r confirm
  case "$confirm" in
    y|Y) ;;
    *) echo "  cancelled"; return ;;
  esac
  (cd "$path" && hx lv-orchestrate.sh --kill-all)
  refresh_one "$i"
}

# tail_events <index> — that project's last 15 events.log lines, same
# columns lv-tray.sh's own EVENTS section uses (time, type, artifact, msg),
# read directly rather than through lv-exec.sh since it's a plain file, not
# a versioned script.
tail_events() {
  local i="$1"
  local path="${paths[$i]}" name="${names[$i]}"
  local log="$path/.claude/orchestrator/events.log"
  printf '\n%s%s — last events%s\n' "$B" "$name" "$R"
  if [ -s "$log" ]; then
    tail -15 "$log" | while IFS=$'\t' read -r ets etype eart emsg; do
      printf '  %s%s%s  %-11s %-11s %s\n' "$DIM" "${ets#*T}" "$R" "$etype" "$eart" "$emsg"
    done
  else
    printf '  %sno events yet%s\n' "$DIM" "$R"
  fi
}

# show_gates <index> — that project's /lv-attend queue: what's gated, on
# whom, and how much it's blocking. Same source lv-list-gates.sh feeds the
# full (non---fields) lv-tray.sh GATES section, called through lv-exec.sh
# since it's a versioned script.
show_gates() {
  local i="$1" gates
  local path="${paths[$i]}" name="${names[$i]}"
  printf '\n%s%s — gated plans%s\n' "$B" "$name" "$R"
  gates=$(cd "$path" && hx lv-list-gates.sh 2>/dev/null || true)
  if [ -z "$gates" ]; then
    printf '  %snone — nothing is waiting on you%s\n' "$DIM" "$R"
    return
  fi
  printf '%s\n' "$gates" | while IFS=$'\t' read -r gid gname gage gq gctx gblk gstate gfit gqfit; do
    [ -n "$gid" ] || continue
    local c="$YEL"
    [[ "$gname" == *stuck* ]] && c="$RED"
    printf '  %s%-14s%s %-11s %s%s\n' "$c" "$gname" "$R" "$gid" "$gq" "$R"
    if [ "${gblk:-0}" -gt 0 ] 2>/dev/null; then
      printf '    %s(blocking %s other plan(s))%s\n' "$DIM" "$gblk" "$R"
    fi
    [ "$gfit" = "mismatch" ] && printf '    %s(state is now %s — this gate no longer fits)%s\n' "$DIM" "$gstate" "$R"
    [ "$gqfit" = "moved" ] && printf '    %s(collision: its upstream or directives moved since this was asked — do not approve)%s\n' "$RED" "$R"
  done
}

# read_key <var> [timeout] — one keypress into <var>, resolving a 3-byte
# arrow escape (ESC [ A/B/C/D) into a single comparable token. The second
# read has to be short (not 0, or a lone ESC/Alt-key press hangs forever)
# but long enough that the two trailing bytes — which the terminal always
# sends back-to-back with the first — are never mistaken for "no more
# input coming". Sets `key_rc` to the first read's exit status: 0 for a
# real keypress, nonzero for a `-t` timeout, so callers can tell "Enter" (rc 0,
# empty key) apart from "nothing pressed before the clock ran out" (rc
# nonzero, key also empty) — the empty string is otherwise identical.
read_key() {
  local __var="$1" __timeout="${2:-}" __k="" __rest="" __t0=0 __elapsed=0
  if [ -n "$__timeout" ]; then
    __t0=$(date +%s)
    IFS= read -rs -t "$__timeout" -n 1 __k
    key_rc=$?
    __elapsed=$(( $(date +%s) - __t0 ))
  else
    IFS= read -rs -n 1 __k
    key_rc=$?
  fi
  # EOF is not a timeout, and the difference matters in both directions.
  #
  # A caller that loops on "no key yet" spins forever on a closed stdin
  # (`< /dev/null`, or a test driving the browser from a pipe), burning a
  # core and never returning. But calling an expiry EOF is worse, because
  # every polled screen bails out on it: the drill browser and the file
  # pager each `return` on key_eof, so one second after opening a level it
  # was replaced by a full repaint of the grid — the sub-screen bounced back
  # to the board on the very first poll tick.
  #
  # bash 4+ reports a -t expiry as >128 and EOF as 1, which tells them apart
  # exactly. bash 3.2 — what macOS ships, and what this runs under — reports
  # BOTH as 1. So an exit 1 from a TIMED read is classified by how long the
  # read actually took: an expiry waits the timeout out, a closed stdin
  # returns instantly. Whole-second clocks make a single instant-looking
  # expiry possible right on a second boundary, so only a RUN of instant
  # ones is called EOF — a closed stdin returns instantly forever, while a
  # boundary misread costs one extra poll and nothing else.
  key_eof=false
  if [ "$key_rc" -eq 1 ]; then
    if [ -z "$__timeout" ]; then
      key_eof=true
    elif [ "$__elapsed" -lt "$__timeout" ]; then
      eof_streak=$(( eof_streak + 1 ))
      [ "$eof_streak" -ge 3 ] && key_eof=true
    else
      eof_streak=0
    fi
  else
    eof_streak=0
  fi
  if [ "$key_rc" -eq 0 ] && [ "$__k" = $'\x1b' ]; then
    # macOS ships bash 3.2, whose `read -t` only accepts whole seconds — a
    # fractional value like 0.05 is a hard error ("invalid timeout
    # specification"), not a shorter wait. That error skips the read
    # entirely, leaving the arrow's trailing "[A"/"[B"/"[C"/"[D" bytes
    # unconsumed in the input buffer, where they get misread as bogus
    # keypresses on every subsequent read_key call from here on — a
    # keyboard that silently goes stale two bytes at a time. 1 whole
    # second is still effectively instant for a real arrow key, since the
    # terminal writes both trailing bytes in the same burst as the ESC;
    # it only shows up as a wait for a genuine lone Escape press.
    IFS= read -rs -t 1 -n 2 __rest
    __k+="$__rest"
  fi
  printf -v "$__var" '%s' "$__k"
}

# ── Drill-down: what is behind a number ─────────────────────────────────
#
# The grid answers "project-a has 3 running and 2 gates". Everything under
# that used to mean opening a terminal in the project and knowing which script
# to run. Enter on a CELL now opens it: the row's items, then one item's
# files, then the log a worker is writing right now. Esc bubbles back up one
# level at a time.
#
# The coordinator knows none of that structure and must not: each level is one call to
# that project's own scripts/lv-exec.sh lv-tray-drill.sh, whose list lines
# carry the argv of the next call (`<display>\t<kind>\t<target>`; see that
# script's header). So a new kind of thing to drill into is added in the
# library, deployed to clients, and appears here with no change to this file
# — the same division of labour as --fields and the grid itself.

# The terminal's size, read from the terminal itself. Every caller runs these
# inside $(...), where stdout is a pipe; `tput cols 2>/dev/null` there has no
# tty on stdout or stderr and answers terminfo's default, 80x24, whatever the
# window really is — which held the board to three or four columns on any
# screen. `stty size` asks the tty directly: /dev/tty first, then stdin or
# stderr when either is one. LV_RACK_COLS / LV_RACK_ROWS override, for tests.
term_size() {
  local s=""
  s=$(stty size 2>/dev/null </dev/tty) || s=""
  [ -z "$s" ] && [ -t 0 ] && s=$(stty size 2>/dev/null)
  [ -z "$s" ] && [ -t 2 ] && s=$(stty size <&2 2>/dev/null)
  case "$s" in [1-9]*' '[1-9]*) printf '%s' "$s" ;; *) return 1 ;; esac
}
term_rows() {
  [ -n "${LV_RACK_ROWS:-}" ] && { echo "$LV_RACK_ROWS"; return; }
  local s; s=$(term_size) && { echo "${s% *}"; return; }
  tput lines 2>/dev/null || echo 30
}
term_cols() {
  [ -n "${LV_RACK_COLS:-}" ] && { echo "$LV_RACK_COLS"; return; }
  local s; s=$(term_size) && { echo "${s#* }"; return; }
  tput cols 2>/dev/null || echo 100
}

# view_file <heading> <path> <followable> [project_path]
#
# A pager for one file — a worker's log, a plan's progress.md, a gate. Reads
# the window it draws with sed rather than slurping the file: a long
# implement log is megabytes, and this repaints on every keypress.
#
# A log opens at the END and can be FOLLOWED (`f`) — that is the whole point
# of drilling this far, to watch a live worker write. Follow polls rather than
# holding `tail -f` open, so the same keyboard handling works for it as for
# every other view and Esc gets out immediately.
# The fourth argument is the project this file belongs to, carried only so the
# board's own action keys (d/a/s/R) work here too — reading a worker's log is
# the commonest place to decide that its daemon should be off.
view_file() {
  local heading="$1" path="$2" followable="$3" ppath="${4:-}"
  local top=0 follow=false key total h w last_total=-1 repaint=true

  h=$(( $(term_rows) - 5 )); [ "$h" -lt 5 ] && h=5
  w=$(term_cols)
  total=$(wc -l < "$path" 2>/dev/null | tr -d ' '); [ -n "$total" ] || total=0
  # A log's useful end is its end; a document's is its beginning.
  if [ "$followable" = "yes" ]; then
    top=$(( total - h )); [ "$top" -lt 0 ] && top=0
  fi

  while true; do
    if $repaint; then
      printf '\033[2J\033[H'
      printf '%s%s%s\n' "$B" "$heading" "$R"
      printf '%s%s%s\n\n' "$DIM" "$path" "$R"
      if [ -s "$path" ]; then
        sed -n "$((top + 1)),$((top + h))p" "$path" 2>/dev/null | cut -c "1-$w"
      else
        printf '  %s(empty)%s\n' "$DIM" "$R"
      fi
      printf '\n%s' "$DIM"
      if $follow; then
        printf 'following — any key stops   %s-%s of %s' "$((top + 1))" "$((top + h))" "$total"
      elif [ "$followable" = "yes" ]; then
        printf '↑/↓ scroll, g top, G end, f follow, d daemon, esc back, m main   %s-%s of %s' \
          "$((top + 1))" "$((top + h))" "$total"
      else
        printf '↑/↓ scroll, g top, G end, d daemon, esc back, m main   %s-%s of %s' \
          "$((top + 1))" "$((top + h))" "$total"
      fi
      printf '%s\n' "$R"
      repaint=false
    fi

    if $follow; then
      read_key key 1
      $key_eof && return
      if [ "$key_rc" -eq 0 ]; then follow=false; repaint=true; continue; fi
      board_tick >/dev/null
      last_total="$total"
      total=$(wc -l < "$path" 2>/dev/null | tr -d ' '); [ -n "$total" ] || total=0
      if [ "$total" != "$last_total" ]; then
        top=$(( total - h )); [ "$top" -lt 0 ] && top=0
        repaint=true
      fi
      continue
    fi

    # Polled rather than blocking, so the portfolio behind this file keeps
    # refreshing while it is being read. Reading a worker's log for two
    # minutes used to freeze every other project's numbers at whatever they
    # were when the file was opened, and the board you came back to was that
    # old — and then had to re-collect before it would draw at all.
    read_key key 1
    $key_eof && return
    if [ "$key_rc" -ne 0 ]; then board_tick >/dev/null; continue; fi
    case "$key" in
      $'\x1b[A'|k) [ "$top" -gt 0 ] && { top=$((top - 1)); repaint=true; } ;;
      $'\x1b[B'|j) [ "$((top + h))" -lt "$total" ] && { top=$((top + 1)); repaint=true; } ;;
      $'\x1b[D'|$'\x1b'|b|B) return ;;
      ' ')  [ "$((top + h))" -lt "$total" ] && { top=$((top + h)); repaint=true; } ;;
      g)    top=0; repaint=true ;;
      G)    top=$(( total - h )); [ "$top" -lt 0 ] && top=0; repaint=true ;;
      f|F)  if [ "$followable" = "yes" ]; then
              follow=true
              total=$(wc -l < "$path" 2>/dev/null | tr -d ' '); [ -n "$total" ] || total=0
              top=$(( total - h )); [ "$top" -lt 0 ] && top=0
              repaint=true
            fi ;;
      ''|$'\n') repaint=true ;;
      m|M) to_main=true; return ;;
      *) board_action_key "$key" "$ppath" && repaint=true; $to_main && return ;;
    esac
  done
}

# drill_fetch <project_path> <argv...> — one level, from the project's own
# harness. stdout is whatever lv-tray-drill.sh printed; the exit status is
# its own (1 = this node is empty, 2 = this harness doesn't know the node),
# which the browser reports rather than showing an empty pane.
#
# Keyed on the PATH rather than an array index, because the arrays now move
# under the browser: board_tick refreshes the portfolio while a level is open,
# and the activity sort can put a different project at index 3 than the one
# the browser was opened on.
drill_fetch() {
  local path="$1"; shift
  ( cd "$path" && hx lv-tray-drill.sh "$@" 2>&1 )
}

# idx_of_path <project_path> — where that project sits in the arrays right
# now, or "" if a refresh dropped it. The browser holds a path for the life of
# a visit and re-resolves the index whenever it needs live numbers.
idx_of_path() {
  local p="$1" i
  for i in "${!paths[@]}"; do
    [ "${paths[$i]}" = "$p" ] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# ── One drill level, fetched behind the frame you are reading ───────────
#
# A level is fetched in the background and its answer cached, the same shape
# the grid's own refresh already had. The visible consequence: a level you
# have opened before paints from its snapshot the instant you arrive, and the
# fetch that confirms it lands underneath a screen you are already reading.
node_pid=""
node_out=""
node_argv=""
node_rc=0
node_text=""

# node_job_cancel — drop an in-flight level fetch. Called when leaving a
# level, because its answer is about to be irrelevant and its temp files
# would otherwise outlive the visit.
node_job_cancel() {
  if [ -n "$node_pid" ]; then
    kill "$node_pid" 2>/dev/null
    wait "$node_pid" 2>/dev/null
  fi
  [ -n "$node_out" ] && rm -f "$node_out" "$node_out.rc" 2>/dev/null
  node_pid=""; node_out=""; node_argv=""
}

# node_job_start <project_path> <argv> — fetch one level in the background.
# The exit status is written to a sibling file because it is meaning, not
# noise: rc 1 ("nothing here right now") and a failed call both produce no
# lines at all, and the difference is the whole message.
node_job_start() {
  node_job_cancel
  node_out=$(mktemp "${TMPDIR:-/tmp}/lv-drill-node.XXXXXX" 2>/dev/null) || { node_out=""; return 1; }
  node_argv="$2"
  local p="$1" a="$2" f="$node_out"
  (
    # Deliberate word splitting: the target field IS an argv.
    # shellcheck disable=SC2086
    out=$(cd "$p" && hx lv-tray-drill.sh $a 2>&1); rc=$?
    printf '%s' "$out" > "$f"
    printf '%s' "$rc" > "$f.rc"
  ) >/dev/null 2>&1 &
  node_pid=$!
  return 0
}

# node_job_ready — has the background level fetch finished?
node_job_ready() {
  [ -n "$node_pid" ] || return 1
  ! kill -0 "$node_pid" 2>/dev/null
}

# node_job_finish — reap it into node_rc/node_text. A missing or unreadable
# status file is treated as rc 2 (unknown node), the same as a harness that
# could not answer: never as 0, which would render a failure as an empty list.
node_job_finish() {
  wait "$node_pid" 2>/dev/null
  node_text=""; node_rc=2
  if [ -n "$node_out" ]; then
    [ -f "$node_out" ] && node_text=$(cat "$node_out" 2>/dev/null)
    [ -f "$node_out.rc" ] && node_rc=$(cat "$node_out.rc" 2>/dev/null)
    rm -f "$node_out" "$node_out.rc" 2>/dev/null
  fi
  case "$node_rc" in ''|*[!0-9]*) node_rc=2 ;; esac
  node_pid=""; node_out=""
}

# parse_items <text> — the three-field lines into the browser's arrays. Items
# come only from a SUCCESSFUL call; the caller enforces that, because a
# failure's output is prose on stderr and prose has no tabs in it, so parsing
# it anyway yields exactly one item with an empty kind — an error rendered as
# something to select, with nothing saying anything went wrong.
d_disp=(); d_kind=(); d_targ=()
parse_items() {
  d_disp=(); d_kind=(); d_targ=()
  local d k t
  while IFS=$'\t' read -r d k t; do
    [ -n "$d" ] || continue
    d_disp+=("$d"); d_kind+=("$k"); d_targ+=("$t")
  done <<< "$1"
}

# drill_rows_lines <index> — the "which row?" level, built here rather than
# in the client: it is a menu of the grid's own rows with the numbers already
# on screen, so it needs the arrays this script holds and nothing the client
# knows. Same line format as lv-tray-drill.sh, so the browser below cannot
# tell the two apart.
drill_rows_lines() {
  local i="$1" label val
  for label in "${ROW_LABELS[@]}"; do
    case "$label" in
      daemon)   val="${f_daemon[$i]}" ;;
      running)  val="${f_running[$i]}" ;;
      gates)    val="${f_gates[$i]}"
                [ "${f_gates_stuck[$i]:-0}" -gt 0 ] 2>/dev/null && val="$val (${f_gates_stuck[$i]} stuck)" ;;
      attn)     val="${f_attn[$i]:--}" ;;
      ideas)    val="${f_ideas[$i]}"
                [ "${f_ideas_drift[$i]:-0}" -gt 0 ] 2>/dev/null && val="$val (+${f_ideas_drift[$i]} not indexed)" ;;
      draft)    val="${f_draft[$i]}" ;;
      ready)    val="${f_ready[$i]}" ;;
      active)   val="${f_active[$i]}" ;;
      verify)   val="${f_verify[$i]}" ;;
      testing)  val="${f_testing[$i]}" ;;
      accept)   val="${f_accept[$i]:-0}" ;;
      complete) val="${f_complete[$i]}" ;;
      abandoned) val="${f_abandoned[$i]}" ;;
      release)  val="${f_release[$i]}" ;;
      deploy)   val="${f_deploy[$i]}" ;;
      registry) val="${f_registry[$i]}" ;;
      *)        val="" ;;
    esac
    printf '%-10s %s\t%s\t%s\n' "$label" "$val" "list" "row $label"
  done
}

# drill_browse <index> <title> <argv> — the browser itself. Keeps a stack of
# levels: Enter on a `list` item pushes the argv it carries, Esc pops, and an
# empty stack returns to the board. A `log`/`file` item opens the pager above;
# a `text` item is fetched and shown the same way, through a temp file, so
# every leaf has one implementation instead of three.
#
# Every level is cache-first: whatever that level said last time is on screen
# before the fetch that refreshes it has even started, and the pane says how
# old it is. Only a level never visited before blocks, and only the once.
drill_browse() {
  local dpath="${paths[$1]}" dname="${names[$1]}"
  local -a st_title=("$2") st_argv=("$3") st_sel=(0)
  local body_file; body_file=$(mktemp "${TMPDIR:-/tmp}/lv-drill.XXXXXX")

  while [ "${#st_argv[@]}" -gt 0 ]; do
    local depth=$(( ${#st_argv[@]} - 1 ))
    local argv="${st_argv[$depth]}"
    local rc=0 out="" level_ts=0 is_rows=false
    local ridx=""

    d_disp=(); d_kind=(); d_targ=()

    if [ "$argv" = "@rows" ]; then
      # The rows level is this script's own grid data, so it has no fetch and
      # no cache of its own: it is exactly as fresh as the column it is built
      # from, and board_tick keeps that current underneath.
      is_rows=true
      if ridx=$(idx_of_path "$dpath"); then
        out=$(drill_rows_lines "$ridx"); rc=0; level_ts="${f_ts[$ridx]:-0}"
        parse_items "$out"
      else
        rc=2; out="$dname is no longer in the project registry"
      fi
    else
      # Cache first. Its first line carries the timestamp and the exit status
      # the lines were produced with; everything after it is the lines.
      local cached
      if cached=$(node_cache_load "$dpath" "$argv") && [ -n "$cached" ]; then
        local head_line; head_line=$(printf '%s' "$cached" | head -1)
        level_ts=$(printf '%s' "$head_line" | cut -d$'\x1f' -f1)
        rc=$(printf '%s' "$head_line" | cut -d$'\x1f' -f2)
        case "$level_ts" in ''|*[!0-9]*) level_ts=0 ;; esac
        case "$rc" in ''|*[!0-9]*) rc=2 ;; esac
        out=$(printf '%s' "$cached" | tail -n +2)
        [ "$rc" -eq 0 ] && parse_items "$out"
      fi
      node_job_start "$dpath" "$argv"
      # Nothing cached: there is no frame to read while it loads, so wait for
      # this one — but say so, since a cold level on a slow client is a
      # couple of seconds of otherwise blank screen.
      if [ "${#d_disp[@]}" -eq 0 ] && [ "$level_ts" -eq 0 ]; then
        printf '\033[2J\033[H'
        printf '%s%s — %s%s\n\n' "$B" "$dname" "${st_title[$depth]}" "$R"
        printf '  %sloading…%s\n' "$DIM" "$R"
        if [ -n "$node_pid" ]; then
          while ! node_job_ready; do board_tick >/dev/null; sleep 1; done
          node_job_finish
        else
          # No temp file to hand the background job, so do it in the
          # foreground rather than wait on a job that was never started.
          # shellcheck disable=SC2086
          node_text=$(drill_fetch "$dpath" $argv); node_rc=$?
        fi
        node_cache_save "$dpath" "$argv" "$node_rc" "$node_text"
        rc="$node_rc"; out="$node_text"; level_ts=$(date +%s)
        [ "$rc" -eq 0 ] && parse_items "$out"
      fi
    fi

    local n="${#d_disp[@]}" sel="${st_sel[$depth]}"
    [ "$n" -gt 0 ] && [ "$sel" -ge "$n" ] && sel=$((n - 1))
    local redraw=true key age_sig="" new_sig="" stage=""

    while true; do
      if $redraw; then
        n="${#d_disp[@]}"
        [ "$n" -gt 0 ] && [ "$sel" -ge "$n" ] && sel=$((n - 1))
        [ "$sel" -lt 0 ] && sel=0
        local h=$(( $(term_rows) - 7 )); [ "$h" -lt 5 ] && h=5
        local w; w=$(term_cols)
        printf '\033[2J\033[H'
        # Breadcrumb: the project, then every level down to here, so you can
        # see how deep you are without popping back out to find out. The age
        # rides on the end of it — this pane may be a cached answer from
        # minutes ago, and it says so rather than looking live.
        local crumb="${B}${dname}${R}" lvl
        for ((lvl = 0; lvl < ${#st_title[@]}; lvl++)); do
          crumb="$crumb ${DIM}›${R} ${st_title[$lvl]}"
        done
        local tint; tint=$(age_color "$level_ts")
        crumb="$crumb   ${tint}$(age_phrase "$level_ts")${R}"
        [ -n "$node_pid" ] && crumb="$crumb ${DIM}⌛${R}"
        printf '%s\n\n' "$crumb"

        if [ "$n" -eq 0 ]; then
          # Either the node is legitimately empty (rc 1 — no running workers,
          # no open gates) or this client's harness is older than the drill
          # script (rc 2, or lv-exec.sh's own complaint). Either way the
          # answer is a message, not a blank pane you have to guess at.
          if [ "$rc" -eq 1 ]; then
            printf '  %snothing here right now%s\n' "$DIM" "$R"
          else
            printf '%s\n' "$out" | head -10 | sed 's/^/  /'
            printf '\n  %sif this says lv-tray-drill.sh is unknown, that client needs a newer harness%s\n' "$DIM" "$R"
          fi
        else
          local view_top=0
          [ "$sel" -ge "$h" ] && view_top=$(( sel - h + 1 ))
          local a
          for ((a = view_top; a < n && a < view_top + h; a++)); do
            local marker="  " style=""
            case "${d_kind[$a]}" in
              list) marker=" ›" ;;
              log)  marker=" ▸"; style="$GRN" ;;
              file|text) marker=" ·" ;;
              *)    marker="  "; style="$DIM" ;;
            esac
            if [ "$a" -eq "$sel" ]; then
              printf '%s%s %s%s\n' "$REV" "$marker" "${d_disp[$a]:0:$((w - 4))}" "$R"
            else
              printf '%s%s %s%s\n' "$style" "$marker" "${d_disp[$a]:0:$((w - 4))}" "$R"
            fi
          done
          [ "$n" -gt "$h" ] && printf '\n  %s%s of %s%s\n' "$DIM" "$((sel + 1))" "$n" "$R"
        fi
        stage=$(level_stage "$argv")
        $is_rows && [ -z "$stage" ] && [ "$n" -gt 0 ] && stage=$(level_stage "${d_targ[$sel]:-}")
        printf '\n%s↑/↓ move, enter open, esc back, r refresh, t %s, d daemon, a actions, m main%s\n' \
          "$DIM" "$([ -n "$stage" ] && echo "/lv-$stage" || echo attend)" "$R"
        redraw=false
        age_sig=$(age_bucket "$level_ts")
      fi

      # A one-second poll rather than a blocking read: it is what lets a
      # background level fetch land under the frame, keeps the portfolio
      # behind this screen refreshing (board_tick), and lets the pane's own
      # age darken while you look at it.
      read_key key 1
      # stdin closed — leave rather than spin on an EOF that will not change.
      if $key_eof; then node_job_cancel; st_title=(); st_argv=(); st_sel=(); break; fi
      if [ "$key_rc" -ne 0 ]; then
        board_tick >/dev/null
        if node_job_ready; then
          node_job_finish
          node_cache_save "$dpath" "$argv" "$node_rc" "$node_text"
          rc="$node_rc"; out="$node_text"; level_ts=$(date +%s)
          d_disp=(); d_kind=(); d_targ=()
          [ "$rc" -eq 0 ] && parse_items "$out"
          redraw=true
          continue
        fi
        if $is_rows && ridx=$(idx_of_path "$dpath"); then
          # The rows level is a view of the grid, and the grid just may have
          # moved underneath it.
          local fresh; fresh=$(drill_rows_lines "$ridx")
          if [ "$fresh" != "$out" ] || [ "${f_ts[$ridx]:-0}" != "$level_ts" ]; then
            out="$fresh"; level_ts="${f_ts[$ridx]:-0}"
            parse_items "$out"; redraw=true; continue
          fi
        fi
        new_sig=$(age_bucket "$level_ts")
        [ "$new_sig" != "$age_sig" ] && redraw=true
        continue
      fi
      case "$key" in
        $'\x1b[A'|k) [ "$n" -gt 0 ] && sel=$(( (sel - 1 + n) % n )); redraw=true ;;
        $'\x1b[B'|j) [ "$n" -gt 0 ] && sel=$(( (sel + 1) % n )); redraw=true ;;
        r)
          # An explicit refresh skips the cache — it is the one case where
          # "what it said last time" is precisely not the answer wanted.
          # Lowercase only: `R` is resume-the-stopped-daemons everywhere else
          # on this board, and a key cannot mean two things one level apart.
          st_sel[$depth]="$sel"
          node_job_cancel
          if $is_rows; then
            board_tick >/dev/null
          else
            rm -f "$(node_cache_file "$dpath" "$argv")" 2>/dev/null
          fi
          break ;;
        $'\x1b[D'|$'\x1b'|b|B)
          st_sel[$depth]="$sel"
          node_job_cancel
          unset 'st_title[$depth]' 'st_argv[$depth]' 'st_sel[$depth]'
          break ;;
        m|M)
          node_job_cancel
          to_main=true
          break ;;
        ''|$'\n'|$'\x1b[C')
          [ "$n" -gt 0 ] || { redraw=true; continue; }
          st_sel[$depth]="$sel"
          case "${d_kind[$sel]}" in
            list)
              node_job_cancel
              st_title+=("${d_disp[$sel]}"); st_argv+=("${d_targ[$sel]}"); st_sel+=(0)
              break ;;
            log)  view_file "${dname} — ${d_disp[$sel]}" "${d_targ[$sel]}" yes "$dpath"; redraw=true ;;
            file) view_file "${dname} — ${d_disp[$sel]}" "${d_targ[$sel]}" no "$dpath";  redraw=true ;;
            text)
              # shellcheck disable=SC2086
              drill_fetch "$dpath" ${d_targ[$sel]} > "$body_file" 2>&1
              view_file "${dname} — ${d_disp[$sel]}" "$body_file" no "$dpath"
              redraw=true ;;
            *) : ;;
          esac ;;
        t|T)
          st_sel[$depth]="$sel"
          node_job_cancel
          # A release or deploy level is ABOUT the promotion, not the plans it
          # lists, so `t` runs the promotion skill itself: /lv-release or
          # /lv-deploy answers its own RELEASE/DEPLOY gate, where /lv-attend
          # only answers one already open (coordinator LVI-021).
          if [ -n "$stage" ]; then
            skill_session "$dpath" "lv-$stage"
          else
            attend_session "$dpath" "$(attend_id "${d_targ[$sel]:-}" "$argv" "${st_argv[*]}")"
          fi
          # Answering a gate moves the plan, so what this level lists is stale.
          $is_rows || rm -f "$(node_cache_file "$dpath" "$argv")" 2>/dev/null
          break ;;
        *)
          if board_action_key "$key" "$dpath"; then
            # An action changed what this level is a view of — a daemon just
            # started has workers this list does not list yet — so leave the
            # level and come back to it cache-free, exactly as `r` does,
            # rather than repainting the answer from before the action.
            st_sel[$depth]="$sel"
            node_job_cancel
            $is_rows || rm -f "$(node_cache_file "$dpath" "$argv")" 2>/dev/null
            break
          fi ;;
      esac
      # m in a log opened from here, or in the project menu (a).
      if $to_main; then node_job_cancel; break; fi
    done
    # m, or a Claude session run from here, directly (t) or from the project
    # menu (a): leave every level, not just this one.
    if $to_main; then st_title=(); st_argv=(); st_sel=(); fi
  done
  node_job_cancel
  rm -f "$body_file"
}

# refresh_all_fields — re-fetch every project's numbers in place. Unlike
# collect_all this does NOT rebuild or re-sort the arrays, so the caller's
# index keeps pointing at the project it was pointing at — which is the whole
# reason it exists: a portfolio-wide action run from inside project_menu must
# not shuffle the menu out from under itself.
refresh_all_fields() {
  local k
  for k in "${!names[@]}"; do refresh_one "$k"; done
}

# pm_action <index> <action> — run one project_menu action. Split out of the
# menu so the arrow-driven Enter and the digit shortcut dispatch through the
# same table instead of two hand-kept copies that drift apart (they did: the
# digits were a literal 1-6 that would not have grown with the list).
pm_action() {
  local i="$1"
  case "$2" in
    0) toggle_daemon "$i" ;;
    1) sweep_now "$i" ;;
    2) kill_all "$i" ;;
    3) tail_events "$i" ;;
    4) show_gates "$i" ;;
    5) drill_browse "$i" "rows" "@rows" ;;
    # Portfolio-wide, not this project — the same pair the picker offers on
    # 's'/'R', repeated here because this menu is where a daemon gets turned
    # on and off, and "now stop the rest of them" is the next thought.
    # Both touch every project's daemon, so every column's numbers are stale
    # afterwards, not just this one's.
    6) suspend_all; refresh_all_fields ;;
    7) resume_suspended; refresh_all_fields ;;
    # Start a promotion by hand (coordinator LVI-021). The skill claims RELEASE or
    # DEPLOY first, so a daemon already running it makes the session stand
    # down rather than race it. Both move plans, so the numbers are stale.
    8) skill_session "${paths[$i]}" lv-release; refresh_one "$i" ;;
    9) skill_session "${paths[$i]}" lv-deploy;  refresh_one "$i" ;;
  esac
}

# project_menu <index> — act on one project: toggle its daemon, run one
# sweep, kill everything live, tail its events, or list what's gated, plus
# the portfolio-wide stop-all/resume pair.
# Up/Down (or j/k) move a highlighted action, Enter runs it; the digit
# still runs that action directly, for muscle memory from before this was
# arrow-driven.
project_menu() {
  local i="$1" key sub=0
  local -a actions=(
    "toggle daemon" "run one sweep now" "kill daemon + all live workers"
    "tail recent events" "list gated plans"
    "open rows, items and logs"
    "stop ALL daemons (whole portfolio)" "resume the daemons that were stopped"
    "start /lv-release" "start /lv-deploy"
  )
  local n_actions="${#actions[@]}"
  while true; do
    printf '\033[2J\033[H'
    printf '%s%s%s  %s%s%s\n' "$B" "${names[$i]}" "$R" "$DIM" "${paths[$i]}" "$R"
    if [ "${statuses[$i]}" != "ok" ]; then
      printf '  status: %s — orchestrator unreachable\n' "${statuses[$i]}"
      printf '  b) back   m) main\n'
      read_key key
      $key_eof && return
      [ "$key_rc" -eq 0 ] || continue
      case "$key" in ''|b|B|$'\x1b') return ;; m|M) to_main=true; return ;; esac
      continue
    fi

    actions[0]="$([ "${f_daemon[$i]}" = "running" ] && echo "stop daemon" || echo "start daemon")"
    printf '  daemon: %s   running: %s   gates: %s\n\n' \
      "${f_daemon[$i]}" "${f_running[$i]}" "${f_gates[$i]}"
    local a
    for a in "${!actions[@]}"; do
      if [ "$a" -eq "$sub" ]; then
        printf '  %s> %d) %s%s\n' "$REV" "$(( (a + 1) % 10 ))" "${actions[$a]}" "$R"
      else
        printf '    %d) %s\n' "$(( (a + 1) % 10 ))" "${actions[$a]}"
      fi
    done
    printf '  b) back   m) main\n\n  arrows + enter, a digit, b or m   %s(d daemon, s stop all, R resume — same keys as the board)%s\n' \
      "$DIM" "$R"

    read_key key
    $key_eof && return
    [ "$key_rc" -eq 0 ] || continue
    case "$key" in
      $'\x1b[A') sub=$(( (sub - 1 + n_actions) % n_actions )) ;;
      $'\x1b[B') sub=$(( (sub + 1) % n_actions )) ;;
      ''|$'\n')
        # The browser paints and clears its own screens, so it is the one
        # action that must NOT be followed by a "press any key" prompt on
        # top of the menu it already redrew.
        pm_action "$i" "$sub"
        $to_main && return
        # 5, 8 and 9 hand the screen to something that ends on its own prompt.
        case "$sub" in 5|8|9) continue ;; esac
        printf '\n  (press any key to continue) '; read_key key ;;
      [0-9])
        # 0 is the tenth action, the way a keyboard's digit row reads.
        local pick=$(( key == 0 ? 9 : key - 1 ))
        [ "$pick" -lt "$n_actions" ] || continue
        pm_action "$i" "$pick"
        $to_main && return
        case "$pick" in 5|8|9) continue ;; esac
        printf '\n  (press any key to continue) '; read_key key ;;
      b|B|$'\x1b') return ;;
      m|M) to_main=true; return ;;
      # The board's own action letters, on the numbered actions that already do
      # the same thing: `d` is action 1, `s`/`R` are 7 and 8. `a` is not one of
      # them — this IS the action menu — so it falls through to nothing rather
      # than opening a second copy of itself.
      d|D) pm_action "$i" 0; printf '\n  (press any key to continue) '; read_key key ;;
      s|S) pm_action "$i" 6; printf '\n  (press any key to continue) '; read_key key ;;
      R)   pm_action "$i" 7; printf '\n  (press any key to continue) '; read_key key ;;
      *) : ;;
    esac
  done
}

# board_action_key <key> <project_path> — the grid's own action keys, honoured
# at every level below it.
#
# The grid offers `d` (toggle that project's daemon), `a` (its action menu) and
# the portfolio-wide `s`/`R` pair. Those used to exist only on the grid, so
# noticing from two levels down a drill that a daemon should be off meant
# Esc, Esc, d — and the actions a level is *about* were the ones you could not
# reach from it: the daemon row's own drill listed the daemon's logs and had no
# way to stop it. Every level that reads a keyboard routes through here first,
# so the keys mean the same thing wherever they are pressed.
#
# Takes the project's PATH, not an array index, for the same reason
# drill_browse does: a background refresh re-sorts the arrays underneath an
# open level, and the index that was right when the level opened is not
# necessarily right now.
#
# Returns 0 when it handled the key — the caller should assume the screen is
# gone and repaint — and 1 when the key is not one of these.
# level_stage <argv> — `release` or `deploy` when a drill argv is that grid
# row, empty otherwise. The two rows are the promotions, and the keys that act
# on a promotion (t) need to know they are on one.
level_stage() {
  case "${1:-}" in
    "row release") echo release ;;
    "row deploy")  echo deploy ;;
  esac
}

# attend_id <text...> — the first plan, bug or brief id in the text, if any.
attend_id() {
  printf '%s\n' "$*" | grep -oE "($LV_WORK_RE)-[0-9]+" | head -1
}

# skill_session <path> <lv-skill> [<arg>] — hand the terminal to an
# interactive Claude session in that project on /<lv-skill> (its wf- name on a
# 13.x client), and take it back when it exits.
skill_session() {
  local path="$1" skill="$2" arg="${3:-}" k
  local cmd="${LV_ATTEND_CMD:-${WF_ATTEND_CMD:-claude}}"
  printf '\033[?25h\033[2J\033[H'
  printf '%s/%s%s %s%s\n\n' "$B" "$skill" "$R" "$(basename "$path")" "${arg:+ — $arg}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf '  %s%s not found on PATH%s\n' "$DIM" "$cmd" "$R"
  else
    [ -d "$path/.claude/skills/$skill" ] || skill="wf-${skill#lv-}"
    ( cd "$path" && "$cmd" "/$skill${arg:+ $arg}" ) || true
  fi
  printf '\n  (press any key to return to the board) '; read_key k
  back_to_board=true; to_main=true
}

# attend_session <path> [<ID>] — skill_session on /lv-attend.
attend_session() { skill_session "$1" lv-attend "${2:-}"; }

board_action_key() {
  local key="$1" path="${2:-}" i="" k
  case "$key" in
    d|D|a|A|s|S|R) ;;
    *) return 1 ;;
  esac
  printf '\033[?25h'
  case "$key" in
    d|D|a|A)
      if i=$(idx_of_path "$path"); then
        case "$key" in
          d|D) daemon_toggle_screen "$i"
               printf '\n  (press any key to continue) '; read_key k ;;
          # The menu paints and clears its own screens and ends on `b`, so it
          # needs no prompt of its own on top of them.
          a|A) project_menu "$i" ;;
        esac
      else
        printf '\033[2J\033[H  %sthat project is no longer in the project registry%s\n' "$DIM" "$R"
        printf '\n  (press any key to continue) '; read_key k
      fi ;;
    s|S) printf '\033[2J\033[H'; suspend_all; refresh_all_fields
         printf '\n  (press any key to continue) '; read_key k ;;
    R)   printf '\033[2J\033[H'; resume_suspended; refresh_all_fields
         printf '\n  (press any key to continue) '; read_key k ;;
  esac
  return 0
}

# menu_loop — top-level "pick a project" prompt. Only reached when both
# stdin and stdout are a real terminal (see the call site below): a piped
# or redirected invocation gets the board and exits, same as before this
# existed.
menu_loop() {
  local choice i
  while true; do
    printf '\n%sselect a project%s (1-%d), %sr%s refresh, %ss%s stop all daemons, %sR%s resume, %sz%s on/dormant, %sv%s services, %sU%s deploy library, %sW%s sweep library, %s%s%s %s:\n' \
      "$B" "$R" "${#names[@]}" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" "$B" "$R" \
      "$B" "$($watch_mode && echo m || echo q)" "$R" "$($watch_mode && echo main || echo quit)"
    for i in "${!names[@]}"; do
      printf '  %d) %s\n' "$((i + 1))" "${names[$i]}"
    done
    printf '> '
    IFS= read -r choice || break
    case "$choice" in
      '') break ;;
      # Under --watch this picker is a screen below the board, so it leaves
      # on m like the rest; without --watch it IS the main screen, and q quits.
      m|M) $watch_mode && break; echo "  not a valid choice" ;;
      q|Q) $watch_mode && { echo "  not a valid choice"; continue; }; break ;;
      r) printf '\033[2J\033[H'; render ;;
      s) suspend_all; printf '\n  (press enter to continue) '; IFS= read -r _
         printf '\033[2J\033[H'; render ;;
      R) resume_suspended; printf '\n  (press enter to continue) '; IFS= read -r _
         printf '\033[2J\033[H'; render ;;
      z) dormant_screen
         if $to_main; then $watch_mode && break; to_main=false; fi
         printf '\033[2J\033[H'; render ;;
      v) services_screen
         if $to_main; then $watch_mode && break; to_main=false; fi
         printf '\033[2J\033[H'; render ;;
      U) printf '\033[2J\033[H'; deploy_library; printf '\n  (press enter to continue) '; IFS= read -r _
         printf '\033[2J\033[H'; render ;;
      W) printf '\033[2J\033[H'; sweep_library; printf '\n  (press enter to continue) '; IFS= read -r _
         printf '\033[2J\033[H'; render ;;
      *)
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#names[@]}" ]; then
          project_menu "$((choice - 1))"
          # Under --watch the board is the main screen, so m and a finished
          # Claude session go back to it; without --watch this picker is the
          # main screen, and render below already collects fresh.
          if $to_main; then
            $watch_mode && break
            to_main=false; back_to_board=false
          fi
          printf '\033[2J\033[H'; render
        else
          echo "  not a valid choice"
        fi
        ;;
    esac
  done
}

# reload_now — a synchronous, blocking collect_all + render. Used for the
# cases where fresh data is actually expected before continuing (right
# after a menu action changed something) rather than merely convenient —
# unlike the poll loop below, there is no stale frame worth showing here.
reload_now() {
  # Any background refresh in flight is now stale AND in the way: its results
  # are older than the collect below, and leaving `refreshing` true means the
  # poll loop never starts another one — the board silently stops updating
  # from here on. Long pauses make that easy to hit (a log open in the
  # drill-down for a minute), so the in-flight job is dropped, not awaited.
  if [ -n "$refresh_pid" ]; then
    kill "$refresh_pid" 2>/dev/null
    wait "$refresh_pid" 2>/dev/null
    [ -n "$refresh_file" ] && rm -f "$refresh_file"
    refresh_pid=""; refresh_file=""; refreshing=false
  fi
  collect_all
  compute_shown
  next_refresh_at=$(( $(date +%s) + watch_secs ))
  render_frame
}

# resume_board — come back to the grid from something that owned the screen
# (the drill browser, the project menu, the project picker). Repaints from the
# snapshot already in memory and asks for a refresh on the next tick; it does
# NOT collect.
#
# This is the whole difference between Esc feeling instant and Esc feeling
# like a wall. reload_now shells into every client before it will draw
# anything, which is seconds of blank screen for data that is, at worst, one
# poll old — and while the browser was open, board_tick has very likely
# refreshed it already. The cases that genuinely need fresh numbers before
# continuing (a menu action that just changed something) call refresh_one for
# the one project they touched, which is immediate and exact.
#
# Back from a Claude session it is a real refresh, not just a request: a
# collect already in flight started before the session moved anything, so it
# is dropped (as reload_now does) and next_refresh_at=0 starts a new one on
# the first tick, behind the repainted grid.
resume_board() {
  to_main=false
  if $back_to_board; then
    back_to_board=false
    if [ -n "$refresh_pid" ]; then
      kill "$refresh_pid" 2>/dev/null
      wait "$refresh_pid" 2>/dev/null
      [ -n "$refresh_file" ] && rm -f "$refresh_file"
      refresh_pid=""; refresh_file=""; refreshing=false
    fi
  fi
  printf '\033[2J\033[?25l'
  prev_lines=()
  compute_shown
  next_refresh_at=0
  render_frame
}

# ── Suspend / resume every daemon ───────────────────────────────────────

# each_project — project paths from the registry, one per line. collect()
# reads the same file, but suspend/resume has to work when a client's
# lv-tray.sh cannot run at all, so it takes the list directly and never
# shells into a client just to find out what is deployed.
each_project() {
  [ -f "$DEPLOYMENTS" ] || return 0
  local p
  while IFS= read -r p || [ -n "$p" ]; do
    [[ -z "$p" || "$p" == \#* ]] && continue
    is_coordinator "$p" && continue
    printf '%s\n' "$p"
  done < "$DEPLOYMENTS"
}

# scan_projects — the projects the grid collects: each_project minus the
# dormant ones, except a dormant project whose daemon is live (always on) and
# everything under --include-dormant. collect() and the background refresh both read this,
# so the hide is one rule, not two loops that can drift.
scan_projects() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if ! $include_dormant && is_dormant "$p" && ! daemon_alive "$p"; then continue; fi
    printf '%s\n' "$p"
  done <<< "$(each_project)"
}

# is_dormant <project_path> — is it in the coordinator's dormant set?
is_dormant() { [ -f "$DORMANT_STATE" ] && grep -qxF -- "$1" "$DORMANT_STATE"; }

# resolve_project <name|path> — the registry path it names, by exact path or
# by basename. Fails (and prints nothing) for anything not in the registry,
# so --sleep cannot record a typo that then silently matches nothing.
resolve_project() {
  local want="$1" p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if [ "$p" = "$want" ] || [ "$(basename "$p")" = "$want" ]; then printf '%s\n' "$p"; return 0; fi
  done <<< "$(each_project)"
  return 1
}

# set_dormant <project_path> <on|off> — put a project to sleep or wake it.
# Sleeping is refused (exit 3) while its daemon is live: a running pipeline is
# always on. Written through a temp-and-rename, like the suspend record.
set_dormant() {
  local p="$1" want="$2" tmp
  if [ "$want" = on ] && daemon_alive "$p"; then
    printf '  %s: daemon running — always on; stop it first\n' "$(basename "$p")"
    return 3
  fi
  mkdir -p "$(dirname "$DORMANT_STATE")" 2>/dev/null || true
  tmp=$(mktemp "${TMPDIR:-/tmp}/lv-rack-dormant.XXXXXX") || return 1
  [ -f "$DORMANT_STATE" ] && grep -vxF -- "$p" "$DORMANT_STATE" > "$tmp"
  [ "$want" = on ] && printf '%s\n' "$p" >> "$tmp"
  if [ -s "$tmp" ]; then sort -u "$tmp" > "$DORMANT_STATE"; else rm -f "$DORMANT_STATE"; fi
  rm -f "$tmp"
  if [ "$want" = on ]; then printf '  %s: dormant\n' "$(basename "$p")"
  else printf '  %s: on\n' "$(basename "$p")"; fi
}

# stop_and_sleep <project_path> — stop its daemon, wait for the pidfile to clear, then
# make it dormant. A daemon that will not stop leaves the project on and says so.
stop_and_sleep() {
  local p="$1"
  if has_harness "$p"; then (cd "$p" && hx lv-orchestrate.sh --stop >/dev/null 2>&1) || true; fi
  if ! wait_until_stopped "$p"; then
    printf '  %s%s: daemon still live — left on%s\n' "$RED" "$(basename "$p")" "$R"
    return 3
  fi
  set_dormant "$p" on
}

# dormant_state <project_path> — what the toggle list shows for it: `always on`
# (daemon live), `dormant`, or `on`.
dormant_state() {
  if daemon_alive "$1"; then echo "always on"
  elif is_dormant "$1"; then echo "dormant"
  else echo "on"; fi
}

# list_dormant — every registered project and its state, for --dormant.
list_dormant() {
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    printf '%-24s %s\n' "$(basename "$p")" "$(dormant_state "$p")"
  done <<< "$(each_project)"
}

# dormant_screen — the list behind `z`: every registered project, Up/Down to
# move, Space or Enter to toggle, Esc to leave, m for the main screen. Returns 0 when something
# changed, so the caller knows the grid's column set is now wrong.
dormant_screen() {
  local -a ps=(); local p key sel=0 changed=1 msg="" k st c
  while IFS= read -r p; do [ -n "$p" ] && ps+=("$p"); done <<< "$(each_project)"
  if [ "${#ps[@]}" -eq 0 ]; then
    printf '\033[2J\033[H  %sthe project registry is empty%s\n' "$DIM" "$R"
    printf '\n  (press any key to continue) '; read_key key
    return 1
  fi
  while true; do
    printf '\033[2J\033[H%sPROJECTS ON THE BOARD%s  %s↑↓ move · space toggle · esc back · m main%s\n\n' "$B" "$R" "$DIM" "$R"
    for k in "${!ps[@]}"; do
      st=$(dormant_state "${ps[$k]}")
      case "$st" in on) c="$GRN" ;; dormant) c="$DIM" ;; *) c="$YEL" ;; esac
      if [ "$k" -eq "$sel" ]; then printf '  %s> %-24s%s %s%s%s\n' "$REV" "$(basename "${ps[$k]}")" "$R" "$c" "$st" "$R"
      else printf '    %-24s %s%s%s\n' "$(basename "${ps[$k]}")" "$c" "$st" "$R"; fi
    done
    [ -n "$msg" ] && printf '\n%s\n' "$msg"
    msg=""
    read_key key
    $key_eof && break
    case "$key" in
      $'\x1b[A'|k) sel=$(( (sel - 1 + ${#ps[@]}) % ${#ps[@]} )) ;;
      $'\x1b[B'|j) sel=$(( (sel + 1) % ${#ps[@]} )) ;;
      ' '|''|$'\n')
        p="${ps[$sel]}"
        # Putting a project to sleep while its daemon runs is refused, so offer the stop
        # here rather than send the operator to the grid's `d` and back.
        if ! is_dormant "$p" && daemon_alive "$p"; then
          printf '\n  %s: daemon running — stop it and make it dormant? [y/N] ' "$(basename "$p")"
          read_key key
          case "$key" in
            y|Y) printf '\n  stopping %s…\n' "$(basename "$p")"; msg=$(stop_and_sleep "$p") ;;
            *)   msg="  $(basename "$p"): left on" ;;
          esac
        elif is_dormant "$p"; then msg=$(set_dormant "$p" off); else msg=$(set_dormant "$p" on); fi
        # set_dormant's refusal is an answer, not a change.
        [ "$(dormant_state "$p")" = "always on" ] || changed=0 ;;
      $'\x1b') break ;;
      m|M) to_main=true; break ;;
    esac
  done
  return "$changed"
}

# ── Services: what each project runs on this machine ────────────────────
#
# A project declares its long-running things (a web container and its tunnel, a worker
# watching a folder) under `services:` in levain.yml, and its launchers leave a beacon while
# they run (lv-services.sh). `v` on the board, or --services, lists every project's, with the
# checkout each one runs from: a worker started from a feature worktree shows as that branch,
# flagged, instead of as nothing. Like the grid, every fact comes from one call to the
# project's own `lv-services.sh status`; this file knows no service by name.

# sv_counts <project_path> — "<declared> <up>": how many services its levain.yml declares, and
# how many distinct ones have a live beacon. The board asks on every frame, so the declared
# count and the beacon directory are read once per collect (SVC_KEY/SVC_VAL), and the up count
# is builtins only: a glob and kill -0, no probe. A detached record (pid 0) counts as up until
# `v` or --services probes it and removes it.
SVC_KEY=(); SVC_VAL=()
sv_counts() {
  local p="$1" k v="" decl dir f pid id seen=" " up=0
  for k in "${!SVC_KEY[@]}"; do [ "${SVC_KEY[$k]}" = "$p" ] && { v="${SVC_VAL[$k]}"; break; }; done
  if [ -z "$v" ]; then
    v=$(awk -v base="$(basename "$p")" '
        /^project_slug:/ { s=$0; sub(/^project_slug:[ \t]*/, "", s); gsub(/["\047]/, "", s); sub(/[ \t]*#.*$/, "", s); slug=s }
        /^[^ #]/ { insv = ($0 ~ /^services:[ \t]*$/) ; next }
        insv && /^  [A-Za-z0-9_-]+:/ { n++ }
        END { if (slug == "") slug = base; printf "%d\t%s", n, slug }' "$p/levain.yml" 2>/dev/null)
    [ -n "$v" ] || v="0"$'\t'"$(basename "$p")"
    SVC_KEY+=("$p"); SVC_VAL+=("$v")
  fi
  decl="${v%%$'\t'*}"
  dir="${LV_SERVICES_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/levain/services}/${v#*$'\t'}"
  for f in "$dir"/*.rec; do
    [ -e "$f" ] || continue
    f="${f##*/}"; f="${f%.rec}"; pid="${f##*.}"; id="${f%.*}"
    case "$seen" in *" $id "*) continue ;; esac
    if [ "$pid" = 0 ] || kill -0 "$pid" 2>/dev/null; then up=$((up + 1)); seen="$seen$id "; fi
  done
  printf '%s %s\n' "$decl" "$up"
}

sv_reset() { SV_P=(); SV_NAME=(); SV_ID=(); SV_STATE=(); SV_DETAIL=(); SV_CO=(); SV_BRANCH=(); SV_COMMIT=(); SV_SINCE=(); SV_FLAGS=(); }

sv_collect() {
  local p out id st de co br cm si pid fl
  sv_reset
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    has_harness "$p" || continue
    out=$(cd "$p" && hx lv-services.sh status 2>/dev/null) || continue
    while IFS=$'\t' read -r id st de co br cm si pid fl; do
      [ -n "$id" ] || continue
      SV_P+=("$p"); SV_NAME+=("$(basename "$p")"); SV_ID+=("$id"); SV_STATE+=("$st"); SV_DETAIL+=("$de")
      SV_CO+=("$co"); SV_BRANCH+=("$br"); SV_COMMIT+=("$cm"); SV_SINCE+=("$si"); SV_FLAGS+=("$fl")
    done <<< "$out"
  done <<< "$(each_project)"
}

sv_age() {
  local s="$1"
  case "$s" in ''|-) echo - ;; *)
    if [ "$s" -lt 60 ]; then echo "${s}s"; elif [ "$s" -lt 3600 ]; then echo "$((s / 60))m"
    elif [ "$s" -lt 86400 ]; then echo "$((s / 3600))h"; else echo "$((s / 86400))d"; fi ;;
  esac
}

# sv_where <i> — main @commit, or the branch it runs from, flagged.
sv_where() {
  local i="$1" fl="${SV_FLAGS[$1]}" w behind=""
  [ "${SV_CO[$i]}" = - ] && { echo -; return; }
  case ",$fl," in *,offmain,*) w="${SV_BRANCH[$i]#feature/} ⚠" ;; *) w="main @${SV_COMMIT[$i]}" ;; esac
  case ",$fl," in *,behind=*) behind="${fl##*behind=}"; behind="${behind%%,*}"; w="$w, behind $behind" ;; esac
  echo "$w"
}

sv_color() {
  case "$1" in up) printf '%s' "$GRN" ;; stale) printf '%s' "$YEL" ;; *) printf '%s' "$DIM" ;; esac
}

sv_line() { # sv_line <i> <selected:true|false>
  local i="$1" c state
  c=$(sv_color "${SV_STATE[$i]}")
  state="${SV_STATE[$i]} ${SV_DETAIL[$i]}"; [ "${SV_DETAIL[$i]}" = - ] && state="${SV_STATE[$i]}"
  if $2; then printf '  %s> %-16s %-12s%s %s%-14s%s %-34s %s\n' "$REV" "${SV_NAME[$i]}" "${SV_ID[$i]}" "$R" "$c" "$state" "$R" "$(sv_where "$i")" "$(sv_age "${SV_SINCE[$i]}")"
  else printf '    %-16s %-12s %s%-14s%s %-34s %s\n' "${SV_NAME[$i]}" "${SV_ID[$i]}" "$c" "$state" "$R" "$(sv_where "$i")" "$(sv_age "${SV_SINCE[$i]}")"; fi
}

sv_table() {
  local i
  if [ "${#SV_ID[@]}" -eq 0 ]; then
    printf '  %sno project declares services: in levain.yml%s\n' "$DIM" "$R"; return 0
  fi
  printf '    %s%-16s %-12s %-14s %-34s %s%s\n' "$B" PROJECT SERVICE STATE CHECKOUT SINCE "$R"
  for i in "${!SV_ID[@]}"; do sv_line "$i" false; done
}

# sv_run <i> <lv-services args...> — one action, in that project, then wait for a key.
sv_run() {
  local i="$1" k; shift
  printf '\033[2J\033[H'
  (cd "${SV_P[$i]}" && hx lv-services.sh "$@") || true
  printf '\n  (press any key to continue) '; read_key k
}

# sv_pick_worktree <i> — choose a checkout, then start from it.
sv_pick_worktree() {
  local i="$1" line n choice; local -a wts=()
  while IFS= read -r line; do [ -n "$line" ] && wts+=("$line"); done \
    <<< "$(cd "${SV_P[$i]}" && hx lv-services.sh worktrees 2>/dev/null)"
  printf '\033[2J\033[H%sSTART %s / %s FROM%s\n\n' "$B" "${SV_NAME[$i]}" "${SV_ID[$i]}" "$R"
  for n in "${!wts[@]}"; do printf '  %d) %-28s %s\n' "$((n + 1))" "${wts[$n]#*$'\t'}" "${wts[$n]%%$'\t'*}"; done
  printf '\n  number, or enter to cancel: '
  printf '\033[?25h'; IFS= read -r choice || return 0
  [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#wts[@]}" ] || return 0
  sv_run "$i" start "${SV_ID[$i]}" --checkout "${wts[$((choice - 1))]%%$'\t'*}"
}

# services_screen — the list behind `v`. ↑↓ move, u start from main, w start from a worktree,
# x stop, o the project's own console, r refresh, esc back, m main.
services_screen() {
  local key sel=0 i n
  printf '\033[2J\033[H  %scollecting services…%s\n' "$DIM" "$R"
  sv_collect
  while true; do
    n="${#SV_ID[@]}"
    printf '\033[2J\033[H%sSERVICES%s  %s↑↓ move · u start · w start from a worktree · x stop · o console · r refresh · esc back · m main%s\n\n' "$B" "$R" "$DIM" "$R"
    if [ "$n" -eq 0 ]; then
      printf '  %sno project declares services: in levain.yml%s\n' "$DIM" "$R"
    else
      printf '    %s%-16s %-12s %-14s %-34s %s%s\n' "$B" PROJECT SERVICE STATE CHECKOUT SINCE "$R"
      [ "$sel" -lt "$n" ] || sel=0
      for i in "${!SV_ID[@]}"; do if [ "$i" -eq "$sel" ]; then sv_line "$i" true; else sv_line "$i" false; fi; done
    fi
    read_key key
    $key_eof && break
    case "$key" in
      $'\x1b[A'|k) [ "$n" -gt 0 ] && sel=$(( (sel - 1 + n) % n )) ;;
      $'\x1b[B'|j) [ "$n" -gt 0 ] && sel=$(( (sel + 1) % n )) ;;
      u|U) [ "$n" -gt 0 ] && { sv_run "$sel" start "${SV_ID[$sel]}"; sv_collect; } ;;
      w|W) [ "$n" -gt 0 ] && { sv_pick_worktree "$sel"; sv_collect; } ;;
      x|X) [ "$n" -gt 0 ] && { sv_run "$sel" stop "${SV_ID[$sel]}"; sv_collect; } ;;
      o|O) [ "$n" -gt 0 ] && sv_run "$sel" console ;;
      r) printf '\033[2J\033[H  %scollecting services…%s\n' "$DIM" "$R"; sv_collect ;;
      $'\x1b') break ;;
      m|M) to_main=true; break ;;
    esac
  done
  return 0
}

# daemon_alive <project_path> — is that client's orchestrator daemon live?
# Reads the pidfile rather than asking lv-tray.sh --fields, because this has
# to stay truthful for a client whose harness is broken, half-deployed, or too
# old to know --fields — exactly the cases where a stray daemon is most likely
# and least visible. `kill -0` is a liveness probe, not a signal delivery.
daemon_alive() {
  local pidfile="$1/.claude/orchestrator/daemon.pid" pid
  [ -f "$pidfile" ] || return 1
  pid=$(cat "$pidfile" 2>/dev/null || echo "")
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

# wait_until_stopped <project_path> — poll for up to 15s. `--stop` signals the
# daemon and lets it finish the sweep it is already in, so the pidfile does not
# clear instantly. Returning early would report a stop that has not happened —
# precisely the false "safe to deploy now" this feature exists to prevent.
wait_until_stopped() {
  local path="$1" i
  for ((i = 0; i < 15; i++)); do
    daemon_alive "$path" || return 0
    sleep 1
  done
  ! daemon_alive "$path"
}

# list_daemons — live daemons, one path per line. Exit 3 when there is at
# least one, so `lv-rack --list-daemons || stop-them-first` reads
# correctly from a deploy script.
list_daemons() {
  local p n=0
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    if daemon_alive "$p"; then printf '%s\n' "$p"; n=$((n + 1)); fi
  done <<< "$(each_project)"
  [ "$n" -gt 0 ] && return 3
  return 0
}

# suspend_all — stop every live daemon, recording which ones so --resume can
# put exactly those back.
suspend_all() {
  local p name failed=0 stopped=0 tmp remembered=0
  mkdir -p "$(dirname "$SUSPEND_STATE")" 2>/dev/null || true
  tmp=$(mktemp "${TMPDIR:-/tmp}/lv-rack-suspend.XXXXXX") || return 1
  # Union, never overwrite. A second --stop-all — a retried deploy, or a
  # second session — finds nothing running and would rewrite the record as
  # empty, silently turning --resume into a no-op that leaves every daemon off.
  [ -f "$SUSPEND_STATE" ] && cat "$SUSPEND_STATE" >> "$tmp"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    daemon_alive "$p" || continue
    name=$(basename "$p")
    printf '  stopping %s\n' "$name"
    printf '%s\n' "$p" >> "$tmp"
    if has_harness "$p"; then
      (cd "$p" && hx lv-orchestrate.sh --stop >/dev/null 2>&1) || true
    fi
    if wait_until_stopped "$p"; then
      stopped=$((stopped + 1))
    else
      printf '  %s%s: still live — do NOT deploy over it%s\n' "$RED" "$name" "$R"
      failed=$((failed + 1))
    fi
  done <<< "$(each_project)"
  sort -u "$tmp" > "$SUSPEND_STATE" 2>/dev/null
  rm -f "$tmp"
  # An empty record is worse than no record: a file called daemons-suspended
  # sitting there says something is suspended, and you have to open it to find
  # out otherwise. Nothing stopped, nothing remembered, no file.
  [ -s "$SUSPEND_STATE" ] || rm -f "$SUSPEND_STATE"
  if [ -f "$SUSPEND_STATE" ]; then
    remembered=$(grep -c . "$SUSPEND_STATE" 2>/dev/null)
    [[ "$remembered" =~ ^[0-9]+$ ]] || remembered=0
  fi
  if [ "$stopped" -eq 0 ] && [ "$failed" -eq 0 ]; then
    printf '  no daemons were running'
    [ "$remembered" -gt 0 ] && printf ' (%s still recorded for --resume)' "$remembered"
    printf '\n'
    return 0
  fi
  printf '  stopped %s, %s recorded for --resume\n' "$stopped" "$remembered"
  [ "$failed" -gt 0 ] && return 3
  return 0
}

# resume_suspended — start exactly what suspend_all stopped, then clear the
# record. Anything that fails to come back stays recorded, so a later --resume
# retries it instead of losing it.
resume_suspended() {
  if [ ! -s "$SUSPEND_STATE" ]; then
    printf '  nothing recorded — no daemons to resume\n'
    return 0
  fi
  local p name started=0 failed=0 tmp logdir
  tmp=$(mktemp "${TMPDIR:-/tmp}/lv-rack-resume.XXXXXX") || return 1
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    name=$(basename "$p")
    if daemon_alive "$p"; then
      printf '  %s already running\n' "$name"
      started=$((started + 1))
      continue
    fi
    if ! has_harness "$p"; then
      printf '  %s%s: no harness — left recorded%s\n' "$YEL" "$name" "$R"
      printf '%s\n' "$p" >> "$tmp"
      failed=$((failed + 1))
      continue
    fi
    logdir="$p/.claude/orchestrator/logs"
    mkdir -p "$logdir" 2>/dev/null || true
    printf '  starting %s\n' "$name"
    (cd "$p" && hx_resolve . lv-orchestrate.sh && nohup "$HX_EXEC" "$HX_NAME" --daemon >>"$logdir/daemon.out" 2>&1 &)
    sleep 2
    if daemon_alive "$p"; then
      started=$((started + 1))
    else
      # Usually orchestrator.enabled: false, which is an answer rather than a
      # fault — but it WAS running when --stop-all found it, so say so and keep
      # it recorded rather than dropping it silently.
      printf '  %s%s: did not start — see .claude/orchestrator/logs/daemon.out%s\n' "$YEL" "$name" "$R"
      printf '%s\n' "$p" >> "$tmp"
      failed=$((failed + 1))
    fi
  done < "$SUSPEND_STATE"
  if [ -s "$tmp" ]; then
    sort -u "$tmp" > "$SUSPEND_STATE"
  else
    rm -f "$SUSPEND_STATE"
  fi
  rm -f "$tmp"
  printf '  started %s, %s left recorded\n' "$started" "$failed"
  [ "$failed" -gt 0 ] && return 3
  return 0
}

# LV_RACK_LIB=1 + `source` loads the functions and stops here, without
# drawing a board. A TUI cannot be exercised by running it: the drill-down
# owns the screen and reads single keypresses, so the test drives the
# functions directly with keys on stdin (tests/rack.sh).
# Same seam-not-a-feature status as LV_DEPLOYMENTS above.
if [ -n "${LV_RACK_LIB:-${WF_BOARD_ALL_LIB:-}}" ]; then
  return 0 2>/dev/null || exit 0
fi

case "$mode" in
  stop-all)     suspend_all; exit $? ;;
  resume)       resume_suspended; exit $? ;;
  list-daemons) list_daemons; exit $? ;;
  dormant)      list_dormant; exit 0 ;;
  services)     sv_collect; sv_table; exit 0 ;;
  sleep|wake)
    target=$(resolve_project "$mode_arg") || { echo "lv-rack: '$mode_arg' is not in the project registry" >&2; exit 1; }
    if [ "$mode" = sleep ]; then set_dormant "$target" on; else set_dormant "$target" off; fi
    exit $? ;;
esac

if $watch_mode; then
  trap 'printf "\033[?25h\n"; [ -n "$refresh_pid" ] && kill "$refresh_pid" 2>/dev/null; exit 0' INT TERM
  printf '\033[2J\033[?25l'

  # Hybrid mode: still auto-refreshes, but a keypress acts without waiting
  # out the interval. Only offered when stdin/stdout are a real TTY — a
  # piped or cron'd --watch keeps the old sleep-only behaviour untouched.
  [ -t 0 ] && [ -t 1 ] && interactive_watch=true
  if $interactive_watch; then sel_idx=0; sel_row=0; fi

  if ! $interactive_watch; then
    # No keyboard to stay responsive for, so there's nothing an async
    # refresh buys here — same synchronous collect-then-sleep as before.
    while true; do
      collect_all; compute_shown
      render_frame
      sleep "$watch_secs"
    done
  fi

  # Interactive. The first frame comes from the last session's snapshot when
  # there is one — instantly, and tinted dark grey so it is plainly old — and
  # the collect that replaces it runs behind it. Only a genuinely cold start
  # (no cache, or no jq) blocks on a collect before drawing anything.
  #
  # After that every refresh runs in the background via start_refresh_async
  # while this loop polls read_key on POLL_SECS. That poll is what keeps
  # arrow keys, digits and the spinner responsive even while a refresh —
  # several seconds of shelling out to every client's lv-tray.sh — is in
  # flight: navigating and repainting only ever touch the arrays in memory.
  if snapshot_load; then
    compute_shown
    set_sel_idx "$sel_idx"
    next_refresh_at=0
    render_frame
  else
    reload_now
  fi
  set_sel_idx "$sel_idx"
  age_sig=$(age_signature)

  while true; do
    now=$(date +%s)
    if ! $refreshing && [ "$now" -ge "$next_refresh_at" ]; then
      start_refresh_async
    fi

    key=""
    read_key key "$POLL_SECS"
    if [ "$key_rc" -ne 0 ]; then
      # Timeout tick, no key pressed. Repaint when there is a reason to: a
      # refresh is in flight (spinner), one just landed (new numbers), or a
      # column crossed an age boundary and has to change shade. Anything
      # else would be a blank diff against an identical frame, once a
      # second, forever.
      repaint_tick=false
      if $refreshing; then
        if refresh_ready; then
          finish_refresh
          next_refresh_at=$(( $(date +%s) + watch_secs ))
        else
          spin_i=$(( (spin_i + 1) % ${#SPIN_FRAMES[@]} ))
        fi
        repaint_tick=true
      fi
      new_sig=$(age_signature)
      if [ "$new_sig" != "$age_sig" ]; then age_sig="$new_sig"; repaint_tick=true; fi
      $repaint_tick && render_frame
      continue
    fi

    case "$key" in
      $'\x1b[C')                        # right — slide the window one column once the highlight runs past its right edge
        total_n="${#names[@]}"
        if [ "$sel_idx" -lt "$((total_n - 1))" ]; then
          set_sel_idx $((sel_idx + 1))
          if [ "$sel_idx" -ge "$win_end" ]; then
            win_start=$((win_start + 1)); win_end=$((win_start + shown_n))
          fi
        fi
        render_frame ;;
      $'\x1b[D')                        # left — same, sliding back once the highlight runs past the left edge
        if [ "$sel_idx" -gt 0 ]; then
          set_sel_idx $((sel_idx - 1))
          if [ "$sel_idx" -lt "$win_start" ]; then
            win_start=$((win_start - 1)); win_end=$((win_start + shown_n))
          fi
        fi
        render_frame ;;
      $'\x1b[A')                        # up — previous metric row
        sel_row=$(( (sel_row - 1 + ${#ROW_LABELS[@]}) % ${#ROW_LABELS[@]} ))
        render_frame ;;
      $'\x1b[B')                        # down — next metric row
        sel_row=$(( (sel_row + 1) % ${#ROW_LABELS[@]} ))
        render_frame ;;
      ''|$'\n')                         # enter — open the highlighted CELL
        printf '\033[?25h'
        drill_browse "$sel_idx" "${ROW_LABELS[$sel_row]}" "row ${ROW_LABELS[$sel_row]}"
        resume_board
        age_sig=$(age_signature)
        ;;
      a|A)                              # act on the highlighted project
        printf '\033[?25h'
        project_menu "$sel_idx"
        resume_board
        age_sig=$(age_signature)
        ;;
      d|D)                              # start/stop the highlighted project's daemon, without the menu
        # Enter on the daemon row opens that row's logs, which is the right
        # thing to read but not the thing you most often want to DO. The
        # toggle used to be one Enter away (this grid's Enter opened the
        # project menu before the drill-down took that key), so it gets its
        # own key rather than living only two levels down.
        # Shared with every level below this one through board_action_key, so
        # `d` on a drill level or in a log does exactly what `d` does here.
        printf '\033[?25h'
        daemon_toggle_screen "$sel_idx"
        printf '\n  (press any key to continue) '; read_key key
        resume_board
        age_sig=$(age_signature)
        ;;
      [1-9])                           # digit — the Nth column currently on screen, not an absolute index
        rel=$((key - 1))
        if [ "$rel" -lt "$shown_n" ]; then
          idx=$((win_start + rel))
          set_sel_idx "$idx"
          printf '\033[?25h'
          project_menu "$idx"
          resume_board
          age_sig=$(age_signature)
        fi
        ;;
      m|M)
        printf '\033[?25h'
        menu_loop
        resume_board
        age_sig=$(age_signature)
        ;;
      s|S|R)                            # stop / resume every daemon in the portfolio
        # The same pair the project picker and the action menu offer. It was
        # reachable from both of those and not from the board they are opened
        # from, which is backwards: every level speaks the same keys.
        board_action_key "$key" "${paths[$sel_idx]}"
        resume_board
        age_sig=$(age_signature)
        ;;
      z|Z)                              # which projects are on the board (LVI-027)
        printf '\033[?25h'
        # A change alters which columns exist, so refresh at once rather than
        # at the next interval; the old columns stay until it lands.
        dormant_screen && next_refresh_at=0
        resume_board
        age_sig=$(age_signature)
        ;;
      v|V)                              # every project's services, and where each runs from
        printf '\033[?25h'
        services_screen
        resume_board
        age_sig=$(age_signature)
        ;;
      U)                                # deploy the library to every client (LVI-026)
        printf '\033[?25h\033[2J\033[H'
        deploy_library
        printf '\n  (press any key to continue) '; read_key key
        resume_board
        age_sig=$(age_signature)
        ;;
      W)                                # blind library sweep, detached (LVI-031)
        printf '\033[?25h\033[2J\033[H'
        sweep_library
        printf '\n  (press any key to continue) '; read_key key
        resume_board
        age_sig=$(age_signature)
        ;;
      q|Q)
        [ -n "$refresh_pid" ] && kill "$refresh_pid" 2>/dev/null
        printf '\033[?25h\n'
        exit 0
        ;;
    esac
  done
else
  render
  if [ -t 0 ] && [ -t 1 ]; then
    menu_loop
  fi
fi
exit 0
