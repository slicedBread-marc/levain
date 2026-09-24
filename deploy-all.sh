#!/bin/bash
#
# deploy-all.sh [--stop-daemons] [--force]
#
# Installs this library into every client listed in deployments.txt.
#
# DEPLOYING UNDER A RUNNING DAEMON IS SAFE AS OF v9.0.0
#
# It was not before. install.sh rewrote scripts/v*/ and .claude/skills/lv-*/ in
# place; an orchestrator daemon sweeps out of those same directories every 60s
# and re-reads lv-orchestrate.sh and lv-orch-lib.sh as it goes, so a sweep
# landing inside the write window read a half-replaced script folder. Nothing
# errored at deploy time; what it produced was confusing dispatch behaviour an
# hour later, attributed to anything but the deploy. The 8.3.0 → 8.6.0 deploy
# ran with client-b' daemon live and survived, which was luck (coordinator WFI-003).
#
# So this used to refuse. It no longer needs to: a deploy now builds into
# scripts/gen/<build id>/ — a directory nothing resolves until it is complete —
# and publishes it by rewriting one line in scripts/current. Every other
# generated file is written through a temp-and-rename. A sweep sees either the
# whole old harness or the whole new one. docs/atomic-deploy.md.
#
#   (default)         deploy, daemons and all
#   --stop-daemons    stop them, deploy, then restart exactly the ones that
#                     were stopped. Nothing needs this for the script folder
#                     any more; it remains for a change a daemon caches beyond
#                     it, and for anyone who wants a cold start.
#   --force           accepted, does nothing. It named the old default.
#
# The live-daemon scan below is kept as REPORTING. Knowing which clients were
# dispatching during a deploy is worth a line of output even when it is safe —
# and it stays truthful for a client whose harness is broken, half-deployed or
# too old to answer, because it reads the pidfile rather than asking.
#
set -euo pipefail

# Pre-14.0.0 environment names: each WF_* still seeds its LV_* counterpart
# unless that is set already, so shell profiles and daemons started before the
# rename keep working.
for _wf in $(compgen -e | grep '^WF_' || true); do
  _lv="LV_${_wf#WF_}"; [ -n "${!_lv+x}" ] || export "$_lv=${!_wf}"
done; unset _wf _lv

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENTS_FILE="${LV_DEPLOYMENTS:-$SCRIPT_DIR/deployments.txt}"
VERSION_FILE="$SCRIPT_DIR/VERSION"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

stop_daemons=false
force=false
while [ $# -gt 0 ]; do
    case "$1" in
        --stop-daemons) stop_daemons=true; shift ;;
        --force)        force=true; shift ;;
        -h|--help)      sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "deploy-all.sh: unknown option '$1' — see --help" >&2; exit 1 ;;
    esac
done

current=$(cat "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]' || echo "unknown")

echo "claude-workflow deploy-all"
echo "=========================="
echo ""
echo "Deploying workflow v$current"
echo ""

# ── Live daemons ─────────────────────────────────────────────────────────────

# Read the client list once; every pass below walks the same array.
CLIENTS=()
if [ -f "$DEPLOYMENTS_FILE" ]; then
    while IFS= read -r project_path || [ -n "$project_path" ]; do
        [[ -z "$project_path" || "$project_path" == \#* ]] && continue
        CLIENTS+=("$project_path")
    done < "$DEPLOYMENTS_FILE"
fi

daemon_live() {
    # daemon_live <project_path> — echo the pid and return 0 if one is running.
    local p="$1" pidfile pid
    pidfile="$p/.claude/orchestrator/daemon.pid"
    [ -f "$pidfile" ] || return 1
    pid=$(tr -d '[:space:]' < "$pidfile" 2>/dev/null || echo "")
    [ -n "$pid" ] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    printf '%s' "$pid"
}

LIVE=()
for p in "${CLIENTS[@]+"${CLIENTS[@]}"}"; do
    [ -d "$p" ] || continue
    if pid=$(daemon_live "$p"); then
        LIVE+=("$p")
        echo -e "${YELLOW}daemon live${NC} in $p (PID $pid)"
    fi
done

# A retried deploy must not lose the record: --stop-daemons run twice would
# otherwise find nothing running the second time, rewrite the record empty, and
# turn the restore into a no-op that leaves every daemon off (coordinator WFI-003).
SUSPEND_STATE="${LV_SUSPEND_STATE:-$SCRIPT_DIR/.deploy-suspended-daemons}"

if $force; then
    echo -e "${YELLOW}--force does nothing now — deploying under a live daemon is the default.${NC}"
    echo ""
fi

if [ "${#LIVE[@]}" -gt 0 ]; then
    if $stop_daemons; then
        for p in "${LIVE[@]}"; do
            echo "  stopping daemon in $p"
            (cd "$p" && scripts/lv-exec.sh lv-orchestrate.sh --stop) || \
                echo -e "  ${RED}could not stop the daemon in $p${NC}"
            grep -qxF "$p" "$SUSPEND_STATE" 2>/dev/null || echo "$p" >> "$SUSPEND_STATE"
        done
        echo ""
    else
        # Reported, not refused. Each of these keeps sweeping the build it
        # already resolved, and takes the new one on its next dispatch.
        echo "  ${#LIVE[@]} daemon(s) left running — they pick up the new build on their next sweep."
        echo ""
    fi
fi

# ── Local deployments ────────────────────────────────────────────────────────

if [ "${#CLIENTS[@]}" -eq 0 ]; then
    echo -e "${YELLOW}No deployments.txt found (or it is empty).${NC}"
    echo "Create it with one project path per line:"
    echo "  echo \"/path/to/your/project\" >> deployments.txt"
    echo ""
else
    LOCAL_COUNT=0
    LOCAL_ERRORS=0

    for project_path in "${CLIENTS[@]}"; do
        echo "→ $project_path"

        if [ ! -d "$project_path" ]; then
            echo -e "  ${RED}Directory not found — skipping${NC}"
            ((LOCAL_ERRORS++)) || true
            continue
        fi

        if bash "$SCRIPT_DIR/install.sh" "$project_path"; then
            echo -e "  ${GREEN}Updated to v$current${NC}"
            ((LOCAL_COUNT++)) || true
        else
            echo -e "  ${RED}Failed${NC}"
            ((LOCAL_ERRORS++)) || true
        fi

        echo ""
    done

    echo -e "${GREEN}Local: $LOCAL_COUNT updated${NC}"
    [ "$LOCAL_ERRORS" -gt 0 ] && echo -e "${RED}       $LOCAL_ERRORS failed${NC}"
    echo ""
fi

# ── Restore the daemons this deploy stopped ──────────────────────────────────
#
# Exactly the ones recorded, and only after every client has been written —
# restarting one early would put a fresh daemon back onto a harness the loop
# has not finished replacing.
RESTART_FRAGILE=false
if [ -s "$SUSPEND_STATE" ]; then
    echo "Restarting the daemon(s) this deploy stopped:"
    while IFS= read -r p; do
        [ -n "$p" ] && [ -d "$p" ] || continue
        if daemon_live "$p" >/dev/null; then
            echo "  $p — already running again, left alone"
            continue
        fi
        log="$p/.claude/orchestrator/daemon.log"
        # A new SESSION where one can be had, not just nohup. nohup only blocks
        # SIGHUP; the restarted daemon stays in this script's process group, so
        # whatever tears that group down later takes the daemon with it. Running
        # this deploy from an agent's shell is exactly that case — the daemon
        # restored here was killed nine minutes on, when the tool call that ran
        # the deploy was reaped, long after the check below had passed.
        #
        # THE REDIRECTION AND THE `exec` BELONG TO THE SUBSHELL, NOT THE DAEMON.
        # `( cd … && nohup daemon >>log 2>&1 & )` looks equivalent and is not:
        # the forked subshell does not exit after starting the background job,
        # it lingers for the daemon's whole life holding the fds it inherited —
        # this script's stdout and stderr. Unredirected that is invisible; run
        # `deploy-all.sh | tail`, or from any wrapper that reads our output to
        # EOF, and the reader blocks until the daemon exits. The command
        # returned, and the terminal still hung (measured: a 15s stub daemon
        # held a `| cat` for exactly 15s). Backgrounding the whole subshell
        # with all three descriptors pointed away, and `exec`ing so no shell is
        # left behind at all, is what actually detaches it.
        if command -v setsid >/dev/null 2>&1; then
            ( cd "$p" && exec setsid nohup scripts/lv-exec.sh lv-orchestrate.sh --daemon ) >> "$log" 2>&1 < /dev/null &
        else
            ( cd "$p" && exec nohup scripts/lv-exec.sh lv-orchestrate.sh --daemon ) >> "$log" 2>&1 < /dev/null &
            RESTART_FRAGILE=true
        fi
        # Verify rather than trust: `nohup … &` returns 0 whether or not the
        # daemon survives its own startup checks (a disabled orchestrator, a
        # pidfile it refuses to take over). Reporting "restarted" over a daemon
        # that exited two seconds later is how a portfolio ends up quietly not
        # dispatching.
        sleep 2
        if daemon_live "$p" >/dev/null; then
            echo -e "  ${GREEN}$p — restarted${NC} (log: .claude/orchestrator/daemon.log)"
        else
            echo -e "  ${RED}$p — restart FAILED, it is NOT running; see .claude/orchestrator/daemon.log${NC}"
        fi
    done < "$SUSPEND_STATE"
    rm -f "$SUSPEND_STATE"
    if $RESTART_FRAGILE; then
        echo -e "  ${YELLOW}No setsid on this system: each restarted daemon is still in this${NC}"
        echo -e "  ${YELLOW}script's process group. If you ran this deploy from an agent or a${NC}"
        echo -e "  ${YELLOW}wrapper that reaps its process tree, the daemon dies with it —${NC}"
        echo -e "  ${YELLOW}re-check with 'lv-orchestrate.sh --daemon-status' a few minutes on,${NC}"
        echo -e "  ${YELLOW}and start it from your own terminal if it is gone.${NC}"
    fi
    echo ""
fi

# ── GitHub deployment ─────────────────────────────────────────────────────────
# TODO: not yet implemented
