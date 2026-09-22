#!/usr/bin/env bash
# wf-stage-start.sh [--minutes N] [--port N] [--tree <path>]
#
# Brings the release branch up in a local staging container, waits for health,
# and RETURNS. The auto-stop runs detached.
#
# Output (eval-friendly): STAGE_PORT, STAGE_URL, STAGE_PROJECT, STAGE_TREE,
#                         STAGE_DEADLINE, STAGE_ALREADY
# Exit 0 up and healthy (or already up), 1 compose failed, 2 no health within
# the wait, 3 no compose file.
#
# ── Why this does not count down in the foreground ────────────────────────
#
# The script this replaces (hand-written in one client, absent from the other
# eight) ended in a 60-minute `for … sleep 1` countdown, and /wf-stage told the
# agent to run it and then "when 60 minutes elapse — container auto-stops".
# Read literally that is an instruction to sit in a blocking call for an hour.
# An agent doing so produces no output, and the harness kills whatever is still
# running when a worker stops — the WFI-012 shape, one hour wide. So the timer
# is detached here and the caller gets its deadline back as a value.
#
# ── Why the project name is not a constant ────────────────────────────────
#
# The original hardcoded `--project-name app-staging`. Nine clients share one
# Docker daemon; two of them staging at once with the same project name is the
# collision `project_slug` exists in claude-workflow.yml to prevent, and the
# second `up` adopts the first one's containers rather than failing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SCRIPT_DIR/wf-orch-lib.sh"

minutes=""
port=""
tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --minutes) minutes="${2:-}"; shift 2 ;;
    --port)    port="${2:-}";    shift 2 ;;
    --tree)    tree="${2:-}";    shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

[ -n "$minutes" ] || minutes=$(wf_cfg staging.minutes 60)
[ -n "$port" ]    || port=$(wf_cfg staging.port 8081)
compose_file=$(wf_cfg staging.composeFile "docker/docker-compose.yml")
health_path=$(wf_cfg staging.healthPath "/health")
slug=$(wf_cfg project_slug "$(basename "$(pwd)")")
project="${slug}-staging"

# ── Which tree gets staged ────────────────────────────────────────────────
#
# `release` lives in its own pinned worktree as of the release-worktree split
# (docs/release-worktrees.md), so the old `wf-branch-check.sh release` run from
# the shared develop checkout fails by construction — the shared tree is never
# on `release` any more. Stage the pinned worktree when it is there; fall back
# to the current tree, and say which was used either way.
if [ -z "$tree" ]; then
  if [ -d "release-branches/release" ]; then
    tree="release-branches/release"
  else
    tree="."
  fi
fi

cd "$tree"

if [ ! -f "$compose_file" ]; then
  echo "wf-stage-start: no compose file at $tree/$compose_file" >&2
  echo "      Set staging.composeFile in claude-workflow.yml if this project keeps it elsewhere." >&2
  exit 3
fi

staged_branch=$(git branch --show-current 2>/dev/null || echo "?")

STATE_DIR="$(wf_orch_dir)/staging"
mkdir -p "$STATE_DIR"
deadline_file="$STATE_DIR/$project.deadline"
pid_file="$STATE_DIR/$project.watchdog"

# ── Already running ───────────────────────────────────────────────────────
#
# An empty case the old skill had no row for. Re-running `up` on a live stack
# is not harmful, but silently restarting a tester's environment mid-session is,
# and so is resetting a deadline they are working against without saying so.
running=$(docker compose -f "$compose_file" -p "$project" ps -q 2>/dev/null | wc -l | tr -d ' ')
if [ "$running" != "0" ]; then
  existing_deadline=$(cat "$deadline_file" 2>/dev/null || echo "")
  wf_emit STAGE_PORT "$port"
  wf_emit STAGE_URL "http://localhost:$port"
  wf_emit STAGE_PROJECT "$project"
  wf_emit STAGE_TREE "$tree"
  wf_emit STAGE_DEADLINE "$existing_deadline"
  wf_emit STAGE_ALREADY "true"
  echo "wf-stage-start: $project is already up — left running, deadline unchanged (${existing_deadline:-unknown})." >&2
  echo "      Stop it first with wf-stage-stop.sh if you want a fresh build." >&2
  exit 0
fi

echo "wf-stage-start: staging $staged_branch from $tree on port $port as $project" >&2

if ! STAGE_PORT="$port" docker compose -f "$compose_file" -p "$project" up --build -d >&2; then
  echo "wf-stage-start: compose failed — nothing is staged" >&2
  exit 1
fi

# ── Health ────────────────────────────────────────────────────────────────
healthy=false
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:$port$health_path" >/dev/null 2>&1; then
    healthy=true
    break
  fi
  sleep 1
done

deadline=$(date -u -v+"${minutes}"M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
           || date -u -d "+${minutes} minutes" +"%Y-%m-%dT%H:%M:%SZ")
printf '%s\n' "$deadline" > "$deadline_file"

# ── Detached auto-stop ────────────────────────────────────────────────────
#
# nohup + </dev/null so it outlives this shell and never inherits a terminal.
# It re-reads the deadline file before acting: a stop that already happened
# removes the file, and the watchdog then exits rather than tearing down a
# stack somebody has since started on purpose.
nohup bash -c "
  sleep $((minutes * 60))
  [ -f '$deadline_file' ] || exit 0
  cd '$(pwd)' || exit 0
  docker compose -f '$compose_file' -p '$project' down -v
  rm -f '$deadline_file' '$pid_file'
" >/dev/null 2>&1 </dev/null &
printf '%s\n' "$!" > "$pid_file"

wf_emit STAGE_PORT "$port"
wf_emit STAGE_URL "http://localhost:$port"
wf_emit STAGE_PROJECT "$project"
wf_emit STAGE_TREE "$tree"
wf_emit STAGE_DEADLINE "$deadline"
wf_emit STAGE_ALREADY "false"

if $healthy; then
  echo "wf-stage-start: healthy at http://localhost:$port — auto-stops at $deadline" >&2
  exit 0
fi

echo "wf-stage-start: container started but $health_path did not respond within 30s." >&2
echo "      It is still running and still auto-stops at $deadline. Check:" >&2
echo "        docker compose -f $compose_file -p $project logs --tail 50" >&2
echo "      Set staging.healthPath in claude-workflow.yml if this app's probe is elsewhere." >&2
exit 2
