#!/usr/bin/env bash
# staging.sh — the scripts that bring containers up and take them down:
# lv-stage-start.sh, lv-stage-stop.sh, lv-docker-down.sh, lv-docker-cleanup.sh
# and lv-wait-healthy.sh. None of them had a test before 14.2.x.
#
# A STUB `docker` goes first on PATH. It records every call and keeps a
# "running" marker per compose project, so start/stop/cleanup are exercised
# without a Docker daemon. Health checks are real: a python http.server on a
# free port answers /health, because curl's behaviour is the thing under test.
#
# Usage: ./tests/staging.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  # Any watchdog a test left behind: it would sleep, then call the stub.
  for f in "$TEST_DIR"/*/.claude/orchestrator/staging/*.watchdog; do
    [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
  done
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "no /$3/ in: $2"; fi; }

# Scripts as a client gets them: {{project_slug}} rendered, as install.sh does.
# LV_TEST_SCRIPT_DIR points at another copy, to prove a test fails on old code
# (orchestrator.sh's convention).
SD="$TEST_DIR/scripts"
cp -R "${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}" "$SD"
for f in "$SD"/*.sh; do
  sed -i.bak 's/{{project_slug}}/demo/g' "$f" && rm -f "$f.bak"
done

# ── The docker stub ─────────────────────────────────────────────────────────
mkdir -p "$TEST_DIR/bin" "$TEST_DIR/docker-state"
export DOCKER_LOG="$TEST_DIR/docker.log" DOCKER_STATE="$TEST_DIR/docker-state"
cat > "$TEST_DIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "STAGE_PORT=${STAGE_PORT:-} docker $*" >> "$DOCKER_LOG"
[ "${1:-}" = compose ] || exit 0          # `docker ps -a ...`: nothing extra
shift
project=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f) shift 2 ;;
    -p) project="$2"; shift 2 ;;
    *) break ;;
  esac
done
cmd="${1:-}"
case "$cmd" in
  ls)
    printf '['; sep=""
    for f in "$DOCKER_STATE"/*.up; do
      [ -f "$f" ] || continue
      printf '%s{"Name":"%s","Status":"running(1)"}' "$sep" "$(basename "$f" .up)"; sep=","
    done
    printf ']\n' ;;
  ps)   [ -f "$DOCKER_STATE/$project.up" ] && echo "c0ffee$project" ; exit 0 ;;
  up)   [ -n "${DOCKER_FAIL_UP:-}" ] && { echo "build failed" >&2; exit 1; }
        touch "$DOCKER_STATE/$project.up" ;;
  down) [ -n "${DOCKER_FAIL_DOWN:-}" ] && { echo "daemon unreachable" >&2; exit 1; }
        rm -f "$DOCKER_STATE/$project.up" ;;
esac
exit 0
STUB
chmod +x "$TEST_DIR/bin/docker"
export PATH="$TEST_DIR/bin:$PATH"

free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'; }

serve_health() {   # serve_health <port>: answers GET /health with 200
  mkdir -p "$TEST_DIR/www" && echo ok > "$TEST_DIR/www/health"
  ( cd "$TEST_DIR/www" && exec python3 -m http.server "$1" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  SERVER_PID=$!; disown "$SERVER_PID" 2>/dev/null
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$1/health" >/dev/null 2>&1 && return 0; sleep 0.1; done
  echo "could not start the health server" >&2; return 1
}

new_project() {   # new_project <dir> [slug]: a git repo with a compose file
  mkdir -p "$1/docker" && cd "$1" || exit 1
  git init -q -b develop . && git config user.email t@t && git config user.name T
  printf 'project_slug: "%s"\n' "${2:-demo}" > claude-workflow.yml
  echo "services: {}" > docker/docker-compose.yml
  git add -A && git commit -qm init   # so `develop` exists to switch back to
}

# Runs a stage script; leaves its exit in RC and its stdout (the eval-able
# assignments) applied to this shell, the way the skill evals it.
stage() {
  local out
  out=$("$SD/$1" "${@:2}" 2>"$TEST_DIR/stage.err"); RC=$?
  eval "$out"
}

echo "staging.sh"
echo "================"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "1. lv-stage-start.sh"
P="$TEST_DIR/proj" && new_project "$P"
STATE="$P/.claude/orchestrator/staging"

rm -f docker/docker-compose.yml
stage lv-stage-start.sh
assert_eq "no compose file exits 3"                  "3" "$RC"
has "and names the config key"                        "$(cat "$TEST_DIR/stage.err")" "staging.composeFile"
echo "services: {}" > docker/docker-compose.yml

: > "$DOCKER_LOG"
DOCKER_FAIL_UP=1 stage lv-stage-start.sh --port "$(free_port)"
assert_eq "a failed compose up exits 1"              "1" "$RC"
assert_eq "and leaves no deadline behind"            "false" \
  "$([ -f "$STATE/demo-staging.deadline" ] && echo true || echo false)"

PORT=$(free_port); serve_health "$PORT"
: > "$DOCKER_LOG"
STAGE_URL="" STAGE_ALREADY=""
LV_STAGE_HEALTH_SECONDS=5 stage lv-stage-start.sh --port "$PORT" --minutes 5
assert_eq "healthy start exits 0"                    "0" "$RC"
assert_eq "STAGE_URL is the port asked for"          "http://localhost:$PORT" "$STAGE_URL"
assert_eq "the compose project is <slug>-staging"    "demo-staging" "$STAGE_PROJECT"
assert_eq "STAGE_ALREADY=false on a fresh start"     "false" "$STAGE_ALREADY"
assert_eq "no release worktree: stages the current tree" "." "$STAGE_TREE"
has "compose up ran with --build -d under that project" "$(cat "$DOCKER_LOG")" "compose -f docker/docker-compose.yml -p demo-staging up --build -d"
has "and STAGE_PORT reached compose"                 "$(cat "$DOCKER_LOG")" "^STAGE_PORT=$PORT docker compose .* up"
assert_eq "the deadline is written"                  "$STAGE_DEADLINE" "$(cat "$STATE/demo-staging.deadline" 2>/dev/null)"
has "and is an ISO UTC time"                         "$STAGE_DEADLINE" '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$'
WATCHDOG=$(cat "$STATE/demo-staging.watchdog" 2>/dev/null)
assert_eq "a detached watchdog is running"           "true" \
  "$([ -n "$WATCHDOG" ] && kill -0 "$WATCHDOG" 2>/dev/null && echo true || echo false)"

first_deadline="$STAGE_DEADLINE"
: > "$DOCKER_LOG"
stage lv-stage-start.sh --port "$PORT" --minutes 90
assert_eq "already up: exits 0"                      "0" "$RC"
assert_eq "already up: STAGE_ALREADY=true"           "true" "$STAGE_ALREADY"
assert_eq "already up: the deadline is unchanged"    "$first_deadline" "$STAGE_DEADLINE"
assert_eq "already up: nothing is rebuilt"           "false" \
  "$(grep -q ' up ' "$DOCKER_LOG" && echo true || echo false)"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "2. lv-stage-stop.sh"
: > "$DOCKER_LOG"
stage lv-stage-stop.sh
assert_eq "stopping a live stack exits 0"            "0" "$RC"
assert_eq "STAGE_WAS_RUNNING=true"                   "true" "$STAGE_WAS_RUNNING"
has "it ran down -v on the staging project"          "$(cat "$DOCKER_LOG")" "-p demo-staging down -v"
assert_eq "the deadline is gone"                     "false" \
  "$([ -f "$STATE/demo-staging.deadline" ] && echo true || echo false)"
sleep 0.2
assert_eq "the watchdog is killed"                   "false" \
  "$(kill -0 "$WATCHDOG" 2>/dev/null && echo true || echo false)"

stage lv-stage-stop.sh
assert_eq "stopping nothing still exits 0"           "0" "$RC"
assert_eq "and says nothing was running"             "false" "$STAGE_WAS_RUNNING"

touch "$DOCKER_STATE/demo-staging.up"
DOCKER_FAIL_DOWN=1 stage lv-stage-stop.sh
assert_eq "a failed compose down exits 1"            "1" "$RC"
has "and does not claim a stop"                      "$(cat "$TEST_DIR/stage.err")" "may still be up"
rm -f "$DOCKER_STATE/demo-staging.up"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "3. Health, the watchdog, and where it stages"
DEAD=$(free_port)
LV_STAGE_HEALTH_SECONDS=1 stage lv-stage-start.sh --port "$DEAD" --minutes 5
assert_eq "no health answer exits 2"                 "2" "$RC"
assert_eq "but the stack is reported, not hidden"    "demo-staging" "$STAGE_PROJECT"
has "and the deadline still stands"                  "$STAGE_DEADLINE" 'Z$'
stage lv-stage-stop.sh

: > "$DOCKER_LOG"
LV_STAGE_HEALTH_SECONDS=2 stage lv-stage-start.sh --port "$PORT" --minutes 0
for _ in $(seq 1 30); do grep -q ' down -v' "$DOCKER_LOG" && break; sleep 0.1; done
has "the watchdog tears the stack down at the deadline" "$(cat "$DOCKER_LOG")" "-p demo-staging down -v"
sleep 0.2
assert_eq "and clears its own deadline"              "false" \
  "$([ -f "$STATE/demo-staging.deadline" ] && echo true || echo false)"

mkdir -p release-branches/release/docker && echo "services: {}" > release-branches/release/docker/docker-compose.yml
LV_STAGE_HEALTH_SECONDS=2 stage lv-stage-start.sh --port "$PORT" --minutes 5
assert_eq "the pinned release worktree is staged when present" "release-branches/release" "$STAGE_TREE"
stage lv-stage-stop.sh
assert_eq "and stop finds the same stack there"      "true" "$STAGE_WAS_RUNNING"
rm -rf release-branches

Q="$TEST_DIR/other" && new_project "$Q" other
LV_STAGE_HEALTH_SECONDS=2 stage lv-stage-start.sh --port "$PORT" --minutes 5
assert_eq "another project gets its own compose name" "other-staging" "$STAGE_PROJECT"
stage lv-stage-stop.sh
cd "$P" || exit 1

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "4. lv-docker-cleanup.sh — only finished plans' containers"
cat > plans.tmp <<'REG'
| ID | Slug | State |
|-|-|-|
| PLN-004 | four | testing |
| PLN-008 | eight | complete |
| PLN-009 | nine | complete |
| PLN-010 | ten | testing |
| PLN-011 | eleven | draft |

<!-- Counter: 12 -->
REG
mkdir -p plans && mv plans.tmp plans/REGISTRY.md
rm -f "$DOCKER_STATE"/*.up
for p in demo-pln004 demo-pln008 demo-pln009 demo-pln010 demo-pln011 other-pln008; do
  touch "$DOCKER_STATE/$p.up"
done
: > "$DOCKER_LOG"
out=$("$SD/lv-docker-cleanup.sh" 2>&1); rc=$?
assert_eq "exits 0"                                  "0" "$rc"
up_now=$(cd "$DOCKER_STATE" && ls *.up | sed 's/\.up$//' | tr '\n' ' ')
assert_eq "keeps testing plans (004, 010) and other projects' containers" \
  "demo-pln004 demo-pln010 other-pln008 " "$up_now"
has "removes a finished plan whose number reads as octal (008)" "$out" "Cleaned up demo-pln008"
has "and 009"                                        "$out" "Cleaned up demo-pln009"
has "and a plan back in draft"                       "$out" "Cleaned up demo-pln011"
has "it counts what it removed"                      "$out" "Removed 3 orphaned"

rm -f "$DOCKER_STATE"/*.up
out=$("$SD/lv-docker-cleanup.sh" 2>&1); rc=$?
assert_eq "nothing running: exits 0 quietly"         "0|" "$rc|$out"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "5. lv-docker-down.sh"
touch "$DOCKER_STATE/demo-pln004.up"
sleep 60 & TUNNEL=$!; disown "$TUNNEL" 2>/dev/null
echo "$TUNNEL" > "${TMPDIR:-/tmp}/wf-tunnel-demo-pln004.pid"
out=$("$SD/lv-docker-down.sh" PLN-004-four 2>&1); rc=$?
assert_eq "exits 0"                                  "0" "$rc"
assert_eq "tears down that plan's stack"             "false" \
  "$([ -f "$DOCKER_STATE/demo-pln004.up" ] && echo true || echo false)"
sleep 0.2
assert_eq "kills the device tunnel it started"       "false" \
  "$(kill -0 "$TUNNEL" 2>/dev/null && echo true || echo false)"
assert_eq "and removes the tunnel's pid file"        "false" \
  "$([ -f "${TMPDIR:-/tmp}/wf-tunnel-demo-pln004.pid" ] && echo true || echo false)"

git checkout -q -b feature/PLN-011-eleven
touch "$DOCKER_STATE/demo-pln011.up"
out=$("$SD/lv-docker-down.sh" 2>&1)
assert_eq "with no argument, the plan comes from the branch" "false" \
  "$([ -f "$DOCKER_STATE/demo-pln011.up" ] && echo true || echo false)"
git checkout -q develop
out=$("$SD/lv-docker-down.sh" 2>&1); rc=$?
assert_eq "not on a feature branch: best effort, still exits 0" "0" "$rc"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "6. lv-wait-healthy.sh"
# The feature port is 8100 + the plan number. Pick a plan whose port is free.
n=""; for c in 3 7 13 17 23 29 31 37 41 43; do
  python3 -c "import socket,sys; s=socket.socket(); s.bind(('127.0.0.1',8100+$c))" 2>/dev/null && { n=$c; break; }
done
if [ -z "$n" ]; then
  echo "  - skipped: no free feature port in 8103-8143"
else
  kill "$SERVER_PID" 2>/dev/null; SERVER_PID=""; sleep 0.2
  serve_health $((8100 + n))
  git checkout -q -b "feature/PLN-$(printf '%03d' "$n")-probe"
  out=$("$SD/lv-wait-healthy.sh" 2>&1); rc=$?
  assert_eq "answers at the plan's own port"         "0" "$rc"
  has "and says where"                               "$out" "localhost:$((8100 + n))"
  git checkout -q develop
fi

echo
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
