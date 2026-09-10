#!/usr/bin/env bash
# check-profiles.sh — governance-tier drift across every client in deployments.txt.
#
# Each client declares a projectProfile.tier (pre-launch | governed) recording
# how much governance its real-world stakes currently justify — see
# docs/project-profile.md. wf-profile.sh --check compares that tier's
# recommendation against the client's actual specApproval.mode,
# manualTestGate.blockOnCosmetic and autonomy scope. This walks every client
# and reports in one place, the same shape as sweep-issues.sh.
#
#   ./check-profiles.sh            tier + drift per client
#   ./check-profiles.sh --count    one "<client>: <tier> <clean|drift|none>" line
#
# Exit 0 if every client is clean, 1 if any client has drift or no declared
# tier. Never edits a client — read-only, like wf-profile.sh itself.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")" && pwd)"
DEPLOYMENTS="${WF_DEPLOYMENTS:-$LIB_ROOT/deployments.txt}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
[ -t 1 ] || { GREEN=''; YELLOW=''; RED=''; BOLD=''; DIM=''; NC=''; }

[ -f "$DEPLOYMENTS" ] || { echo "check-profiles.sh: no deployments.txt" >&2; exit 1; }

mode="list"
[ "${1:-}" = "--count" ] && mode="count"

any_bad=0
clients=0

while IFS= read -r client; do
  [ -n "$client" ] || continue
  case "$client" in \#*) continue ;; esac
  [ -d "$client" ] || { echo -e "${YELLOW}  skip: $client (not found)${NC}" >&2; continue; }

  name=$(basename "$client")
  clients=$((clients + 1))

  out=$( cd "$client" && ./scripts/wf-exec.sh wf-profile.sh --check 2>&1 )
  rc=$?
  tier=$( cd "$client" && ./scripts/wf-exec.sh wf-profile.sh --show 2>/dev/null | awk -F': ' '/^tier:/ {print $2}' )
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
done < "$DEPLOYMENTS"

if [ "$mode" = "list" ]; then
  echo
  if [ "$any_bad" -eq 0 ]; then
    echo -e "${GREEN}No profile drift across ${clients} client(s).${NC}"
  else
    echo -e "${YELLOW}Drift or an undeclared tier found above.${NC} See docs/project-profile.md."
  fi
fi

exit "$any_bad"
