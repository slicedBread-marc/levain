#!/usr/bin/env bash
# wf-stage-stop.sh [--tree <path>]
#
# Stops the staging stack and cancels its auto-stop watchdog.
#
# Output (eval-friendly): STAGE_PROJECT, STAGE_WAS_RUNNING
# Exit 0 whether or not anything was running — stopping a stopped container is
# the requested end state, not a failure. Exit 1 only if compose itself errored,
# 3 if there is no compose file to act on.
#
# ── Why it reports what it did ────────────────────────────────────────────
#
# The skill this replaces printed "✓ Staging container stopped" unconditionally,
# after a `down -v` that exits 0 on an empty project. So the one message a
# tester got was identical whether they had just torn down a live environment or
# typed the command into a repo where nothing had ever run. `down -v` also
# destroys volumes, which is right for a disposable staging stack and worth
# saying out loud, since the same words in a different script would mean data
# loss.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SCRIPT_DIR/wf-orch-lib.sh"

tree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree) tree="${2:-}"; shift 2 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  echo "Unexpected argument: $1" >&2; exit 1 ;;
  esac
done

compose_file=$(wf_cfg staging.composeFile "docker/docker-compose.yml")
slug=$(wf_cfg project_slug "$(basename "$(pwd)")")
project="${slug}-staging"

if [ -z "$tree" ]; then
  if [ -d "release-branches/release" ]; then
    tree="release-branches/release"
  else
    tree="."
  fi
fi
cd "$tree"

if [ ! -f "$compose_file" ]; then
  echo "wf-stage-stop: no compose file at $tree/$compose_file — nothing this script can stop" >&2
  exit 3
fi

STATE_DIR="$(wf_orch_dir)/staging"
deadline_file="$STATE_DIR/$project.deadline"
pid_file="$STATE_DIR/$project.watchdog"

running=$(docker compose -f "$compose_file" -p "$project" ps -q 2>/dev/null | wc -l | tr -d ' ')

# Remove the deadline first: the watchdog checks for this file before tearing
# anything down, so a later `up` cannot be killed by a timer left over from now.
rm -f "$deadline_file"
if [ -f "$pid_file" ]; then
  kill "$(cat "$pid_file")" 2>/dev/null || true
  rm -f "$pid_file"
fi

if [ "$running" = "0" ]; then
  wf_emit STAGE_PROJECT "$project"
  wf_emit STAGE_WAS_RUNNING "false"
  echo "wf-stage-stop: $project was not running — nothing to stop. Any auto-stop timer is cancelled." >&2
  exit 0
fi

if ! docker compose -f "$compose_file" -p "$project" down -v >&2; then
  echo "wf-stage-stop: compose down failed — the stack may still be up. Check:" >&2
  echo "        docker compose -f $compose_file -p $project ps" >&2
  exit 1
fi

wf_emit STAGE_PROJECT "$project"
wf_emit STAGE_WAS_RUNNING "true"
echo "wf-stage-stop: $project stopped, volumes removed (staging data is disposable by design)." >&2
exit 0
