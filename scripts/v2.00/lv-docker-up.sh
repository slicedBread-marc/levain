#!/usr/bin/env bash
# lv-docker-up.sh [plan-folder-name] [--tunnel]
# Starts a Docker container for a feature branch plan.
# If no plan folder given, derives from current branch name.
#
# A project with no docker/docker-compose.yml runs natively instead: its
# local_deploy_command (else local_start_command) from levain.yml, in the
# background, with FEATURE_PORT and PORT exported — the command must listen on
# that port. Stopped by lv-docker-down.sh. See "No Docker" below.
# Sets up port, project name, builds, waits for health, and provisions the
# test account the acceptance criteria will need.
#
#   --tunnel   also publish the container at a public HTTPS URL, for criteria
#              that need a real device. See "Device testing" below.
#
# Output: FEATURE_PORT, COMPOSE_PROJECT_NAME, TEST_ACCOUNT, PUBLIC_URL
#         (eval-friendly)
# Exit 0 on healthy, 1 on timeout or a failed start, 3 no compose file and no
# local start command to use instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=lv-orch-lib.sh
source "$SCRIPT_DIR/lv-orch-lib.sh"

plan_folder=""
want_tunnel=false
while [ $# -gt 0 ]; do
  case "$1" in
    --tunnel) want_tunnel=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  plan_folder="$1"; shift ;;
  esac
done

if [ -z "$plan_folder" ]; then
  branch=$(git branch --show-current)
  plan_folder=$(echo "$branch" | sed 's|feature/||')
fi

eval "$("$SCRIPT_DIR/lv-plan-port.sh" "$plan_folder")"

echo "FEATURE_PORT=$FEATURE_PORT"
echo "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME"

# `eval "$(lv-docker-up.sh)" && …` takes eval's status, which is the status of
# the last line it evaluated: an `X=value` that always succeeds. So a failed
# start read as up, and the chain went on to test nothing (a client's
# LVI-037/039/041). On any failure the last line on stdout is `(exit N)`,
# which makes the eval itself fail with this script's code.
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "(exit $rc)"; exit "$rc"' EXIT

# port_holder — who is listening on FEATURE_PORT, or nothing. The port is
# 8100 + the plan's number in every project, so another project's plan of the
# same number (or a server it left running) can hold it. Compose then fails
# with "Ports are not available", and a native start answers /health from
# the wrong app. Name the holder rather than leave the tester to guess.
port_holder() {
  command -v lsof >/dev/null 2>&1 || return 0
  local pid cmd cwd
  for pid in $(lsof -nP -iTCP:"$FEATURE_PORT" -sTCP:LISTEN -t 2>/dev/null | sort -u | head -3); do
    cmd=$(ps -o command= -p "$pid" 2>/dev/null | cut -c1-100)
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    printf 'PID %s: %s%s\n' "$pid" "$cmd" "${cwd:+ (in $cwd)}"
  done
}
port_refuse() {
  echo "lv-docker-up: port $FEATURE_PORT is already in use, so this plan's app cannot start on it:" >&2
  printf '%s\n' "$1" | sed 's/^/      /' >&2
  echo "      The port is 8100 + the plan number in every project, so another project's plan" >&2
  echo "      of the same number collides. Stop that process if it is a leftover; it is not" >&2
  echo "      this plan's to kill if it belongs to another project's live work." >&2
  exit 1
}

# ASP.NET Core (and similar) host filtering rejects any request whose Host
# header isn't in AllowedHosts — the tunnel origin and a LAN IP alike, since
# neither is 'localhost' nor a production hostname. A tunnel is pointless if
# the app 400s every request that reaches it through it, so --tunnel asks
# for a permissive value here. A project's docker-compose.yml opts in with
# e.g. `environment: - AllowedHosts=${FEATURE_ALLOWED_HOSTS:-}` (WFI-007).
if $want_tunnel; then
  FEATURE_ALLOWED_HOSTS="*"
else
  FEATURE_ALLOWED_HOSTS=""
fi

# ── No Docker ─────────────────────────────────────────────────────────────
#
# This used to assume docker/docker-compose.yml unconditionally. A client with
# no Docker at all — levain.yml's local_start_command a plain `dotnet run` —
# had its unattended tester fail the compose step, skip every browser
# criterion, and open a manual-test gate whose remedy was "set up Docker"
# (a client's LVI-002). The command the project already declared for local
# runs is the one to use. It is eval'd in the worktree, in its own process
# group (so `dotnet run`'s child app dies with it), logging to APP_LOG.
native_pidfile="${TMPDIR:-/tmp}/lv-app-$COMPOSE_PROJECT_NAME.pid"
if [ ! -f docker/docker-compose.yml ]; then
  start_cmd=$(wf_cfg local_deploy_command "")
  [ -n "$start_cmd" ] || start_cmd=$(wf_cfg local_start_command "")
  case "$start_cmd" in
    "")
      echo "lv-docker-up: no docker/docker-compose.yml and no local_start_command in levain.yml — nothing to start." >&2
      echo "      Set local_start_command to what runs the app on \$FEATURE_PORT, e.g." >&2
      echo "      \"dotnet run --project src/App --urls http://localhost:\$FEATURE_PORT\"" >&2
      exit 3 ;;
    *docker\ compose*|*docker-compose*)
      echo "lv-docker-up: levain.yml's start command runs compose, but this tree has no docker/docker-compose.yml." >&2
      echo "      Either the branch predates the compose file, or the command is wrong for this project." >&2
      exit 3 ;;
  esac
  # A restart (after an edit) replaces the previous run, never stacks on it.
  "$SCRIPT_DIR/lv-docker-down.sh" "$plan_folder" --native-only >/dev/null 2>&1 || true
  holder=$(port_holder)
  [ -z "$holder" ] || port_refuse "$holder"
  app_log="${TMPDIR:-/tmp}/lv-app-$COMPOSE_PROJECT_NAME.log"
  : > "$app_log"
  echo "lv-docker-up: no compose file — starting natively: $start_cmd" >&2
  FEATURE_PORT=$FEATURE_PORT PORT=$FEATURE_PORT FEATURE_ALLOWED_HOSTS=$FEATURE_ALLOWED_HOSTS \
    nohup perl -e 'setpgrp(0, 0); exec "bash", "-c", $ARGV[0]' "$start_cmd" >>"$app_log" 2>&1 </dev/null &
  echo $! > "$native_pidfile"
  wf_emit APP_LOG "$app_log"

  # A native start may compile first, so it gets longer than a container.
  wait_s=$(wf_cfg localStartWait 120)
  healthy=false
  for _ in $(seq 1 "$wait_s"); do
    if curl -s "http://localhost:$FEATURE_PORT/health" >/dev/null 2>&1; then healthy=true; break; fi
    kill -0 "$(cat "$native_pidfile")" 2>/dev/null || break
    sleep 1
  done
  if ! $healthy; then
    echo "lv-docker-up: the app did not answer http://localhost:$FEATURE_PORT/health — last lines of $app_log:" >&2
    tail -20 "$app_log" | sed 's/^/      /' >&2
    echo "      The command must listen on \$FEATURE_PORT (exported, and as PORT) and serve /health." >&2
    "$SCRIPT_DIR/lv-docker-down.sh" "$plan_folder" --native-only >/dev/null 2>&1 || true
    exit 1
  fi
  echo "✓ App is ready at http://localhost:$FEATURE_PORT" >&2
fi

# Start the container (stderr so eval callers only get KEY=VALUE on stdout)
#
# ── Self-healing on 'no space left on device' ──────────────────────────────
#
# Docker Desktop's VM disk is a fixed cap shared by every concurrent build the
# orchestrator dispatches across active plans, independent of host disk space
# — so a build here can fail transiently under pipeline concurrency and clear
# up again by the time anyone looks. Without this, that ENOSPC went straight
# to a needs-input gate parked for a human, twice on the same project within a
# day, each time fixed by hand with nothing more than `docker system prune -f`
# (client-e's WFI-019). So: on that specific failure, prune once and retry,
# bounded, before surfacing anything.
#
# `dockerRetry.maxAttempts` in levain.yml overrides the default (2);
# the default keeps a client that has never set it self-healing from day one.
max_attempts=$(wf_cfg dockerRetry.maxAttempts 2)
attempt=1
# Our own containers from an earlier run hold the port legitimately: compose
# replaces them. Anything else holding it makes `up` fail on the bind.
if [ -f docker/docker-compose.yml ] \
   && [ -z "$(docker ps -q --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME" 2>/dev/null)" ]; then
  holder=$(port_holder)
  [ -z "$holder" ] || port_refuse "$holder"
fi
while [ -f docker/docker-compose.yml ]; do
  if compose_out=$(FEATURE_PORT=$FEATURE_PORT FEATURE_ALLOWED_HOSTS=$FEATURE_ALLOWED_HOSTS docker compose \
       -f docker/docker-compose.yml \
       -p "$COMPOSE_PROJECT_NAME" \
       up --build -d 2>&1); then
    printf '%s\n' "$compose_out" >&2
    break
  fi
  printf '%s\n' "$compose_out" >&2
  case "$compose_out" in
    *"no space left on device"*)
      if [ "$attempt" -ge "$max_attempts" ]; then
        echo "lv-docker-up: 'no space left on device' persisted after $attempt attempt(s) — pruning did not recover enough room" >&2
        exit 1
      fi
      echo "lv-docker-up: 'no space left on device' — pruning and retrying ($attempt/$max_attempts)" >&2
      docker system prune -f >&2 || true
      docker builder prune -f >&2 || true
      attempt=$((attempt + 1))
      ;;
    *) exit 1 ;;
  esac
done

# Wait for health (the native path waited already)
[ -f docker/docker-compose.yml ] && "$SCRIPT_DIR/lv-wait-healthy.sh" >&2

# ── Test account ──────────────────────────────────────────────────────────
#
# A fresh container is empty by design, and an app worth testing usually
# refuses to invent a default login for one — correctly, since a seeded default
# password on any reachable host is a standing compromise. The consequence
# landed on the tester: client-a's WFI-072 handed a human a URL for a
# container with no account and no way to make one from the UI, and every
# criterion behind the login was unreachable. Nothing in the skill, the plan or
# this script's output mentioned it. The suspicion the reporter raised is the
# expensive part — earlier runs almost certainly recorded criteria as passed or
# skipped that nobody could have executed.
#
# So provisioning is part of bringing the app up, not a thing the tester is
# expected to reverse-engineer from Program.cs. Both keys are optional: a
# project with no login sets neither and nothing changes.
#
#   test_account_command: eval'd here with FEATURE_PORT and
#                         COMPOSE_PROJECT_NAME exported. Must be idempotent —
#                         it runs on every container start.
#   test_account_note:    what the tester needs in order to sign in, e.g.
#                         "sign in with dev@example.com / <password>". Read
#                         with wf_cfg_text, so a `|` block scalar works — a
#                         sign-in recipe is prose and is routinely several
#                         paragraphs. client-b wrote fifteen lines there and
#                         wf_cfg answered empty, so a tester opened a
#                         needs-input gate asking what the file already said,
#                         for the third time (WFI-021). The COMMAND stays
#                         single-line: WFI-016 is what happens when a block
#                         opener is run as a command.
account_cmd=$(wf_cfg test_account_command "")
account_note=$(wf_cfg_text test_account_note "")

if [ -n "$account_cmd" ]; then
  export FEATURE_PORT COMPOSE_PROJECT_NAME
  if eval "$account_cmd" >&2; then
    :
  else
    echo "lv-docker-up: test_account_command failed — the app is up but may have no account to sign in as" >&2
  fi
fi

wf_emit TEST_ACCOUNT "$account_note"

if [ -n "$account_note" ]; then
  # Printed on its own lines: the note may be a multi-line recipe, and the
  # author's line breaks are its formatting.
  printf 'lv-docker-up: test account —\n%s\n' "$account_note" >&2
elif [ -n "$account_cmd" ]; then
  echo "lv-docker-up: test account provisioned (set test_account_note in levain.yml to print the credentials here)" >&2
fi

# ── Device testing ────────────────────────────────────────────────────────
#
# The container publishes plain HTTP on a local port, which is right for
# everything a browser on this machine can test and wrong for everything a
# phone can.
#
# The reason is not reachability — a LAN IP is reachable. It is that a session
# cookie set with `Secure` is stored on `http://localhost`, which browsers
# treat as a trustworthy origin, and silently DROPPED on `http://<lan-ip>`,
# which they do not. So the phone POSTs the login, gets HTTP 200, discards the
# cookie, reloads unauthenticated, and shows no error anywhere. client-a's
# PLN-006 criterion 9 (one-handed phone usability) was untestable for exactly
# this reason and was only completed by hand-rolling a cloudflared tunnel
# outside the harness (WFI-113). Every `#### Manual` criterion that needs a
# real device sits behind this.
#
# --tunnel puts an HTTPS origin in front of the same container, so `Secure`
# cookies are stored and the criterion is reachable. It is opt-in: it publishes
# a development build to a public URL, which is a deliberate act.
#
#   tunnel_command: from levain.yml. Runs with FEATURE_PORT exported
#                   and must print a URL on stdout or stderr. Defaults to a
#                   cloudflared quick tunnel, which needs no account.
if $want_tunnel; then
  # The permissive AllowedHosts value set above only reaches the app if the
  # project's own compose file passes it through (WFI-007's opt-in line).
  # Without it, --tunnel used to report a device URL that 400ed on every
  # request with no warning anywhere — the tester had to root-cause ASP.NET
  # host filtering by hand (client-f's WFI-010). This is a static check, not
  # proof the app enforces host filtering at all (it may not, e.g. non-.NET
  # stacks), so it warns rather than blocking the tunnel.
  if [ -f docker/docker-compose.yml ] && ! grep -q 'FEATURE_ALLOWED_HOSTS' docker/docker-compose.yml; then
    echo "lv-docker-up: docker/docker-compose.yml has no FEATURE_ALLOWED_HOSTS passthrough — if the app enforces host" >&2
    echo "      filtering (e.g. ASP.NET's AllowedHosts), the tunnel origin will 400 on every request. Add e.g." >&2
    echo "      'environment: - AllowedHosts=\${FEATURE_ALLOWED_HOSTS:-}' to docker/docker-compose.yml to opt in (WFI-007)." >&2
  fi

  tunnel_cmd=$(wf_cfg tunnel_command "cloudflared tunnel --url http://localhost:\$FEATURE_PORT")
  tunnel_bin=$(printf '%s' "$tunnel_cmd" | awk '{print $1}')

  if ! command -v "$tunnel_bin" >/dev/null 2>&1; then
    echo "lv-docker-up: --tunnel needs '$tunnel_bin', which is not installed." >&2
    echo "      Install it (macOS: brew install cloudflared), or set tunnel_command in levain.yml." >&2
    echo "      Without it, device criteria cannot be tested: a Secure cookie is dropped on http://<lan-ip>," >&2
    echo "      so the phone signs in, gets a 200, and reloads logged out with no error shown (WFI-113)." >&2
    wf_emit PUBLIC_URL ""
  else
    tunnel_log="${TMPDIR:-/tmp}/wf-tunnel-$COMPOSE_PROJECT_NAME.log"
    tunnel_pidfile="${TMPDIR:-/tmp}/wf-tunnel-$COMPOSE_PROJECT_NAME.pid"
    : > "$tunnel_log"
    export FEATURE_PORT
    nohup bash -c "$tunnel_cmd" >>"$tunnel_log" 2>&1 </dev/null &
    echo $! > "$tunnel_pidfile"

    # Quick tunnels print their hostname a second or two after start.
    #
    # The exclusion below must anchor on the whole host, not do a plain
    # substring match: cloudflared also prints a Terms-of-Service link to
    # cloudflare.com itself before the tunnel URL, and a naive
    # `grep -v 'cloudflare.com'` matches that AND the real tunnel host,
    # because "trycloudflare.com" contains "cloudflare.com" as a substring.
    # That silently discarded every quick-tunnel URL and made this loop
    # report "no URL within 30s" even though the URL was in the log the
    # whole time (WFI-005, WFI-006).
    public_url=""
    for _ in $(seq 1 30); do
      public_url=$(grep -oE 'https://[a-zA-Z0-9.-]+\.[a-z]+' "$tunnel_log" 2>/dev/null \
                     | grep -vE '^https://([a-zA-Z0-9-]+\.)*(cloudflare|argotunnel)\.com$' \
                     | head -1 || true)
      [ -n "$public_url" ] && break
      sleep 1
    done

    if [ -n "$public_url" ]; then
      echo "lv-docker-up: device URL — $public_url (HTTPS, so Secure cookies work; tunnel log: $tunnel_log)" >&2
    else
      echo "lv-docker-up: tunnel started but printed no URL within 30s — see $tunnel_log" >&2
    fi
    wf_emit PUBLIC_URL "$public_url"
  fi
else
  wf_emit PUBLIC_URL ""
fi
