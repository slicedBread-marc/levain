#!/bin/bash
#
# deploy-all.sh [--stop-daemons] [--force]
#
# Installs this library into every client listed in deployments.txt.
#
# A DEPLOY MUST NOT REPLACE THE HARNESS UNDER A RUNNING DAEMON
#
# install.sh rewrites scripts/v*/ and .claude/skills/wf-*/ in place. An
# orchestrator daemon sweeps out of those same directories every 60s and
# re-reads wf-orchestrate.sh and wf-orch-lib.sh as it goes, so a sweep landing
# inside the write window reads a half-replaced script folder. Nothing errors
# at deploy time; what it produces is confusing dispatch behaviour an hour
# later, attributed to anything but the deploy. The 8.3.0 → 8.6.0 deploy ran
# with client-b' daemon live and survived, which is luck, not a guarantee
# (coordinator WFI-003).
#
# So this checks first, using each client's own .claude/orchestrator/daemon.pid
# rather than asking its harness anything — that stays truthful for a client
# whose harness is broken, half-deployed, or too old to answer.
#
#   (default)         refuse while any daemon is live, naming them
#   --stop-daemons    stop them, deploy, then restart exactly the ones that
#                     were stopped
#   --force           deploy anyway, daemons and all. Says what it is doing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOYMENTS_FILE="${WF_DEPLOYMENTS:-$SCRIPT_DIR/deployments.txt}"
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
        -h|--help)      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
SUSPEND_STATE="${WF_SUSPEND_STATE:-$SCRIPT_DIR/.deploy-suspended-daemons}"

if [ "${#LIVE[@]}" -gt 0 ]; then
    if $force; then
        echo -e "${RED}--force: deploying with ${#LIVE[@]} daemon(s) still sweeping.${NC}"
        echo "        A sweep landing mid-write reads a half-replaced script folder."
        echo ""
    elif $stop_daemons; then
        for p in "${LIVE[@]}"; do
            echo "  stopping daemon in $p"
            (cd "$p" && scripts/wf-exec.sh wf-orchestrate.sh --stop) || \
                echo -e "  ${RED}could not stop the daemon in $p${NC}"
            grep -qxF "$p" "$SUSPEND_STATE" 2>/dev/null || echo "$p" >> "$SUSPEND_STATE"
        done
        echo ""
    else
        echo ""
        echo -e "${RED}Refusing to deploy while ${#LIVE[@]} orchestrator daemon(s) are running.${NC}"
        echo "install.sh rewrites the script folder a daemon is sweeping out of; a sweep"
        echo "landing inside that window reads a half-replaced harness (coordinator WFI-003)."
        echo ""
        echo "Either:"
        echo "  ./deploy-all.sh --stop-daemons     stop them, deploy, restart exactly those"
        echo "  ./deploy-all.sh --force            deploy anyway"
        echo "Or stop them yourself:"
        for p in "${LIVE[@]}"; do
            echo "  (cd $p && scripts/wf-exec.sh wf-orchestrate.sh --stop)"
        done
        exit 1
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
        if command -v setsid >/dev/null 2>&1; then
            (cd "$p" && setsid nohup scripts/wf-exec.sh wf-orchestrate.sh --daemon >> "$log" 2>&1 &) || true
        else
            (cd "$p" && nohup scripts/wf-exec.sh wf-orchestrate.sh --daemon >> "$log" 2>&1 &) || true
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
        echo -e "  ${YELLOW}re-check with 'wf-orchestrate.sh --daemon-status' a few minutes on,${NC}"
        echo -e "  ${YELLOW}and start it from your own terminal if it is gone.${NC}"
    fi
    echo ""
fi

# ── GitHub deployment ─────────────────────────────────────────────────────────
# TODO: not yet implemented
