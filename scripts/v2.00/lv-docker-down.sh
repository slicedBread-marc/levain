#!/usr/bin/env bash
# lv-docker-down.sh [plan-folder-name] [--native-only]
# Tears down the Docker container for a feature branch plan, and the native
# process lv-docker-up.sh started instead when the tree has no compose file.
# If no plan folder given, derives from current branch name.
#   --native-only   stop the native process only (lv-docker-up.sh's restart)
#
# Exit 0 always (cleanup is best-effort).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

plan_folder="" native_only=false
for a in "$@"; do
  case "$a" in --native-only) native_only=true ;; *) plan_folder="$a" ;; esac
done
if [ -z "$plan_folder" ]; then
  branch=$(git branch --show-current 2>/dev/null || echo "")
  plan_folder=$(echo "$branch" | sed 's|feature/||')
fi

if [ -z "$plan_folder" ]; then
  echo "Warning: could not determine plan folder" >&2
  exit 0
fi

eval "$("$SCRIPT_DIR/lv-plan-port.sh" "$plan_folder")" 2>/dev/null || true

if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
  echo "Warning: could not determine COMPOSE_PROJECT_NAME for $plan_folder" >&2
  exit 0
fi

# Kill the device tunnel first, if lv-docker-up.sh --tunnel started one. A
# quick tunnel outliving its container is a public URL pointing at nothing, or
# worse, at whatever binds that port next.
tunnel_pidfile="${TMPDIR:-/tmp}/wf-tunnel-$COMPOSE_PROJECT_NAME.pid"
if ! $native_only && [ -f "$tunnel_pidfile" ]; then
  tunnel_pid=$(tr -d '[:space:]' < "$tunnel_pidfile")
  if [ -n "$tunnel_pid" ] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
    echo "Device tunnel for $COMPOSE_PROJECT_NAME stopped"
  fi
  rm -f "$tunnel_pidfile"
fi

# The native run: its process group, every descendant, and its port.
# shellcheck source=lv-orch-lib.sh
source "$SCRIPT_DIR/lv-orch-lib.sh"
wf_stop_native "$COMPOSE_PROJECT_NAME" || true
$native_only && exit 0

# A tree with no compose file ran natively, and saying "Container … stopped"
# after the native stop above read as a second success (a client's LVI-027).
if [ -f docker/docker-compose.yml ]; then
  docker compose -f docker/docker-compose.yml \
    -p "$COMPOSE_PROJECT_NAME" \
    down -v 2>/dev/null || true
fi

ids=$(docker ps -a --filter "name=$COMPOSE_PROJECT_NAME" --format "{{.ID}}" 2>/dev/null || true)
[ -z "$ids" ] || printf '%s\n' "$ids" | xargs docker rm -f >/dev/null 2>&1 || true

if [ -f docker/docker-compose.yml ] || [ -n "$ids" ]; then
  echo "Container $COMPOSE_PROJECT_NAME stopped"
fi
