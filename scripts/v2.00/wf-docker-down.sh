#!/usr/bin/env bash
# wf-docker-down.sh [plan-folder-name]
# Tears down the Docker container for a feature branch plan.
# If no plan folder given, derives from current branch name.
#
# Exit 0 always (cleanup is best-effort).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

plan_folder="${1:-}"
if [ -z "$plan_folder" ]; then
  branch=$(git branch --show-current 2>/dev/null || echo "")
  plan_folder=$(echo "$branch" | sed 's|feature/||')
fi

if [ -z "$plan_folder" ]; then
  echo "Warning: could not determine plan folder" >&2
  exit 0
fi

eval "$("$SCRIPT_DIR/wf-plan-port.sh" "$plan_folder")" 2>/dev/null || true

if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
  echo "Warning: could not determine COMPOSE_PROJECT_NAME for $plan_folder" >&2
  exit 0
fi

# Kill the device tunnel first, if wf-docker-up.sh --tunnel started one. A
# quick tunnel outliving its container is a public URL pointing at nothing, or
# worse, at whatever binds that port next.
tunnel_pidfile="${TMPDIR:-/tmp}/wf-tunnel-$COMPOSE_PROJECT_NAME.pid"
if [ -f "$tunnel_pidfile" ]; then
  tunnel_pid=$(tr -d '[:space:]' < "$tunnel_pidfile")
  if [ -n "$tunnel_pid" ] && kill -0 "$tunnel_pid" 2>/dev/null; then
    kill "$tunnel_pid" 2>/dev/null || true
    echo "Device tunnel for $COMPOSE_PROJECT_NAME stopped"
  fi
  rm -f "$tunnel_pidfile"
fi

docker compose -f docker/docker-compose.yml \
  -p "$COMPOSE_PROJECT_NAME" \
  down -v 2>/dev/null || true

docker ps -a --filter "name=$COMPOSE_PROJECT_NAME" \
  --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true

echo "Container $COMPOSE_PROJECT_NAME stopped"
