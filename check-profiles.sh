#!/usr/bin/env bash
# check-profiles.sh — governance-tier drift across every client in deployments.txt.
#
# Each client declares a projectProfile.tier (pre-launch | governed) recording
# how much governance its real-world stakes currently justify — see
# docs/project-profile.md. lv-profile.sh --check compares that tier's
# recommendation against the client's actual specApproval.mode,
# manualTestGate.blockOnCosmetic and autonomy scope. This walks every client
# and reports in one place, the same shape as sweep-issues.sh.
#
#   ./check-profiles.sh            tier + drift per client
#   ./check-profiles.sh --count    one "<client>: <tier> <clean|drift|none>" line
#
# Exit 0 if every client is clean, 1 if any client has drift or no declared
# tier. Never edits a client — read-only, like lv-profile.sh itself.

set -uo pipefail

# Pre-14.0.0 environment names: each WF_* still seeds its LV_* counterpart
# unless that is set already, so shell profiles and daemons started before the
# rename keep working.
for _wf in $(compgen -e | grep '^WF_' || true); do
  _lv="LV_${_wf#WF_}"; [ -n "${!_lv+x}" ] || export "$_lv=${!_wf}"
done; unset _wf _lv

LIB_ROOT="$(cd "$(dirname "$0")" && pwd)"
# The client list (LVI-013): the project-registry hook — deployments.txt in
# this library by default, the owner's pack when one implements it.
# LV_DEPLOYMENTS names a file to read instead, and wins over any pack: it is
# the test suite's seam, so a test never walks the real clients.
registry() {
  if [ -n "${LV_DEPLOYMENTS:-}" ]; then
    [ -f "$LV_DEPLOYMENTS" ] || return 0
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$LV_DEPLOYMENTS" | grep -v '^#' | grep -v '^$' || true
  else
    CLAUDE_PROJECT_DIR="$LIB_ROOT" LV_LIBRARY="$LIB_ROOT" "$LIB_ROOT/scripts/v2.00/lv-hook.sh" project-registry </dev/null
  fi
}

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
[ -t 1 ] || { GREEN=''; YELLOW=''; RED=''; BOLD=''; DIM=''; NC=''; }

CLIENT_LIST=$(registry) || { echo "check-profiles.sh: the project-registry hook failed" >&2; exit 1; }
[ -n "$CLIENT_LIST" ] || { echo "check-profiles.sh: no projects in the registry (deployments.txt)" >&2; exit 1; }

mode="list"
[ "${1:-}" = "--count" ] && mode="count"

any_bad=0
clients=0

while IFS= read -r client; do
  [ -n "$client" ] || continue
  case "$client" in \#*) continue ;; esac
  [ -d "$client" ] || { echo -e "${YELLOW}  skip: $client (not found)${NC}" >&2; continue; }

  name=$(basename "$client")

  # Coordinators have no pipeline, so no specApproval, manualTestGate or
  # autonomy scope for a tier to be in step with — and no lv-profile.sh to ask.
  # Counting them as "undeclared" would make this exit 1 forever on a project
  # that cannot be made clean.
  if grep -qE '^role:[[:space:]]*"?coordinator"?' "$client/claude-workflow.yml" 2>/dev/null; then
    [ "$mode" = "count" ] && printf '%s: coordinator n/a\n' "$name"
    [ "$mode" = "list" ] && echo -e "${DIM}== $name — coordinator, no pipeline (skipped) ==${NC}"
    continue
  fi

  clients=$((clients + 1))

  out=$( cd "$client" && ./scripts/lv-exec.sh lv-profile.sh --check 2>&1 )
  rc=$?
  tier=$( cd "$client" && ./scripts/lv-exec.sh lv-profile.sh --show 2>/dev/null | awk -F': *' '/^tier:/ {print $2}' )
  tier="${tier:-none}"

  case "$mode" in
    count)
      if [ "$rc" -eq 0 ]; then status="clean"; elif [ "$rc" -eq 2 ]; then status="undeclared"; else status="drift"; fi
      printf '%s: %s %s\n' "$name" "$tier" "$status"
      ;;
    list)
      if [ "$rc" -eq 0 ]; then
        echo -e "${GREEN}== $name — $tier, clean ==${NC}"
      else
        echo -e "${BOLD}== $name — $tier ==${NC}"
        printf '%s\n' "$out" | sed 's/^/  /'
      fi
      ;;
  esac

  [ "$rc" -eq 0 ] || any_bad=1
done <<< "$CLIENT_LIST"

if [ "$mode" = "list" ]; then
  echo
  if [ "$any_bad" -eq 0 ]; then
    echo -e "${GREEN}No profile drift across ${clients} client(s).${NC}"
  else
    echo -e "${YELLOW}Drift or an undeclared tier found above.${NC} See docs/project-profile.md."
  fi
fi

exit "$any_bad"
