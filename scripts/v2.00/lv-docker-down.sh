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

# The native run: its whole process group, so `dotnet run`'s child app goes too.
native_pidfile="${TMPDIR:-/tmp}/lv-app-$COMPOSE_PROJECT_NAME.pid"
if [ -f "$native_pidfile" ]; then
  pid=$(tr -d '[:space:]' < "$native_pidfile")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -KILL -- "-$pid" 2>/dev/null || true
    echo "App $COMPOSE_PROJECT_NAME stopped"
  fi
  rm -f "$native_pidfile"
fi
$native_only && exit 0

docker compose -f docker/docker-compose.yml \
  -p "$COMPOSE_PROJECT_NAME" \
  down -v 2>/dev/null || true

docker ps -a --filter "name=$COMPOSE_PROJECT_NAME" \
  --format "{{.ID}}" | xargs -r docker rm -f 2>/dev/null || true

echo "Container $COMPOSE_PROJECT_NAME stopped"
