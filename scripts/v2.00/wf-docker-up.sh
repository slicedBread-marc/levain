#!/usr/bin/env bash
# wf-docker-up.sh [plan-folder-name] [--tunnel]
# Starts a Docker container for a feature branch plan.
# If no plan folder given, derives from current branch name.
# Sets up port, project name, builds, waits for health, and provisions the
# test account the acceptance criteria will need.
#
#   --tunnel   also publish the container at a public HTTPS URL, for criteria
#              that need a real device. See "Device testing" below.
#
# Output: FEATURE_PORT, COMPOSE_PROJECT_NAME, TEST_ACCOUNT, PUBLIC_URL
#         (eval-friendly)
# Exit 0 on healthy, 1 on timeout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=wf-orch-lib.sh
source "$SCRIPT_DIR/wf-orch-lib.sh"

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

eval "$("$SCRIPT_DIR/wf-plan-port.sh" "$plan_folder")"

echo "FEATURE_PORT=$FEATURE_PORT"
echo "COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME"

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
# `dockerRetry.maxAttempts` in claude-workflow.yml overrides the default (2);
# the default keeps a client that has never set it self-healing from day one.
max_attempts=$(wf_cfg dockerRetry.maxAttempts 2)
attempt=1
while :; do
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
        echo "wf-docker-up: 'no space left on device' persisted after $attempt attempt(s) — pruning did not recover enough room" >&2
        exit 1
      fi
      echo "wf-docker-up: 'no space left on device' — pruning and retrying ($attempt/$max_attempts)" >&2
      docker system prune -f >&2 || true
      docker builder prune -f >&2 || true
      attempt=$((attempt + 1))
      ;;
    *) exit 1 ;;
  esac
done

# Wait for health
"$SCRIPT_DIR/wf-wait-healthy.sh" >&2

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
#   test_account_note:    one line handed to the tester, e.g.
#                         "sign in with dev@example.com / <password>"
account_cmd=$(wf_cfg test_account_command "")
account_note=$(wf_cfg test_account_note "")

if [ -n "$account_cmd" ]; then
  export FEATURE_PORT COMPOSE_PROJECT_NAME
  if eval "$account_cmd" >&2; then
    :
  else
    echo "wf-docker-up: test_account_command failed — the app is up but may have no account to sign in as" >&2
  fi
fi

wf_emit TEST_ACCOUNT "$account_note"

if [ -n "$account_note" ]; then
  echo "wf-docker-up: test account — $account_note" >&2
elif [ -n "$account_cmd" ]; then
  echo "wf-docker-up: test account provisioned (set test_account_note in claude-workflow.yml to print the credentials here)" >&2
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
#   tunnel_command: from claude-workflow.yml. Runs with FEATURE_PORT exported
#                   and must print a URL on stdout or stderr. Defaults to a
#                   cloudflared quick tunnel, which needs no account.
if $want_tunnel; then
  tunnel_cmd=$(wf_cfg tunnel_command "cloudflared tunnel --url http://localhost:\$FEATURE_PORT")
  tunnel_bin=$(printf '%s' "$tunnel_cmd" | awk '{print $1}')

  if ! command -v "$tunnel_bin" >/dev/null 2>&1; then
    echo "wf-docker-up: --tunnel needs '$tunnel_bin', which is not installed." >&2
    echo "      Install it (macOS: brew install cloudflared), or set tunnel_command in claude-workflow.yml." >&2
    echo "      Without it, device criteria cannot be tested: a Secure cookie is dropped on http://<lan-ip>," >&2
    echo "      so the phone signs in, gets a 200, and reloads logged out with no error shown (WFI-113)." >&2
    wf_emit PUBLIC_URL ""
  else
    tunnel_log="${TMPDIR:-/tmp}/wf-tunnel-$COMPOSE_PROJECT_NAME.log"
    tunnel_pidfile="${TMPDIR:-/tmp}/wf-tunnel-$COMPOSE_PROJECT_NAME.pid"
    : > "$tunnel_log"
    export FEATURE_PORT
    nohup bash -c "$tunnel_cmd" >>"$tunnel_log" 2>&1 &
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
      echo "wf-docker-up: device URL — $public_url (HTTPS, so Secure cookies work; tunnel log: $tunnel_log)" >&2
    else
      echo "wf-docker-up: tunnel started but printed no URL within 30s — see $tunnel_log" >&2
    fi
    wf_emit PUBLIC_URL "$public_url"
  fi
else
  wf_emit PUBLIC_URL ""
fi
