#!/usr/bin/env bash
# sweep-issues.sh — collect workflow-harness problems reported by every client.
#
# Clients file process bugs into their own WORKFLOW-ISSUES.md as they hit them
# (scripts/wf-exec.sh wf-issue.sh). This walks deployments.txt, gathers the open
# ones, and prints them grouped by project so they can be fixed HERE — in the
# library — rather than worked around individually in each client.
#
#   ./sweep-issues.sh              open issues, grouped by client
#   ./sweep-issues.sh --all        include already-resolved entries
#   ./sweep-issues.sh --count      one "<client>: <n>" line per project
#   ./sweep-issues.sh --resolve WFI-003 --client app "fixed in v2.6.0"
#
# Exit 0 if any open issues were found, 1 if every client is clean — so
# `./sweep-issues.sh >/dev/null && echo "work to do"` reads correctly.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")" && pwd)"
# WF_DEPLOYMENTS points at an alternate client list — used by the test suite so
# it never has to touch the real deployments.txt.
DEPLOYMENTS="${WF_DEPLOYMENTS:-$LIB_ROOT/deployments.txt}"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
[ -t 1 ] || { GREEN=''; YELLOW=''; BOLD=''; DIM=''; NC=''; }

[ -f "$DEPLOYMENTS" ] || { echo "sweep-issues.sh: no deployments.txt" >&2; exit 1; }

mode="list"
show_all=false
resolve_id=""
resolve_client=""
resolve_note="resolved"

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     show_all=true; shift ;;
    --count)   mode="count"; shift ;;
    --resolve) mode="resolve"; resolve_id="${2:?--resolve requires WFI-NNN}"; shift 2 ;;
    --client)  resolve_client="${2:?--client requires a name}"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         resolve_note="$1"; shift ;;
  esac
done

# open_entries <WORKFLOW-ISSUES.md> — the entries whose status is open, whole.
#
# An entry's status is its OWN `**Status:**` line: the first one that starts a
# line inside that entry. Not any occurrence anywhere in it.
#
# Reporters paste evidence into the Actual block, and the most natural evidence
# for a workflow issue is a diff of WORKFLOW-ISSUES.md itself. client-a's
# WFI-065 carries one, so its body holds `+**Status:** open` three times — and
# the listing, which matched anywhere in the entry, printed that RESOLVED issue
# under a client with nothing open. The count never agreed, because it anchored
# to the line start, so one run printed an issue and then said "no open
# workflow issues" directly underneath it.
#
# Both callers now read this, so there is one rule and nothing left to disagree.
open_entries() {
  awk -v RS='\n## ' '
    NR > 1 {
      n = split($0, line, "\n")
      for (i = 1; i <= n; i++)
        if (line[i] ~ /^\*\*Status:\*\*/) {
          if (line[i] ~ /^\*\*Status:\*\* *open/) print "## " $0
          break
        }
    }
  ' "$1"
}

total=0
clients=0

while IFS= read -r client; do
  [ -n "$client" ] || continue
  case "$client" in \#*) continue ;; esac
  [ -d "$client" ] || { echo -e "${YELLOW}  skip: $client (not found)${NC}" >&2; continue; }

  name=$(basename "$client")
  issues="$client/WORKFLOW-ISSUES.md"
  clients=$((clients + 1))

  open_body=""
  [ -f "$issues" ] && open_body=$(open_entries "$issues")
  # Count what would be PRINTED. These used to be two rules — a grep here and
  # an awk below — and they disagreed the moment an entry's body contained the
  # word they both looked for (see open_entries).
  n=$(printf '%s' "$open_body" | grep -c '^## ' || true)
  n=${n:-0}

  case "$mode" in
    count)
      printf '%s: %s\n' "$name" "$n"
      ;;

    resolve)
      if [ -n "$resolve_client" ] && [ "$resolve_client" != "$name" ]; then continue; fi
      [ -f "$issues" ] || continue
      grep -q "^## $resolve_id " "$issues" 2>/dev/null || continue
      # Resolve through the client's own script so the format stays owned by
      # one place, and the client's version of it is the one that runs.
      #
      # Report what it actually said, not what we asked for: an entry resolved
      # earlier is left alone, and a caller sweeping a batch needs to see which
      # of its IDs were already on the record rather than a uniform "resolved".
      out=$( cd "$client" && ./scripts/wf-exec.sh wf-issue.sh --resolve "$resolve_id" "$resolve_note" 2>&1 )
      case "$out" in
        *"not overwriting"*) echo -e "${YELLOW}  $name: $out${NC}" ;;
        *)                   echo -e "${GREEN}  $name: $resolve_id resolved${NC}" ;;
      esac
      ;;

    list)
      # An entry's status is its OWN `**Status:**` line — the first one that
      # starts a line inside the record — not any occurrence anywhere in it.
      #
      # Reporters paste evidence into the Actual block, and the most natural
      # evidence for a workflow issue is a diff of WORKFLOW-ISSUES.md itself.
      # client-a's WFI-065 carries one, so its body contains `+**Status:**
      # open` three times; an unanchored match read the entry as open and the
      # sweep printed a RESOLVED issue under a client that had none. The count
      # above never agreed — it anchors — so the same run said "no open
      # workflow issues" directly below the issue it had just printed.
      if $show_all; then
        body=$([ -f "$issues" ] && awk -v RS='\n## ' 'NR > 1 { print "## " $0 }' "$issues" || true)
      else
        body="$open_body"
      fi
      if [ -n "$body" ]; then
        echo -e "\n${BOLD}══ $name ${NC}${DIM}($client)${NC}"
        printf '%s\n' "$body"
      fi
      ;;
  esac

  total=$((total + n))
done < "$DEPLOYMENTS"

if [ "$mode" = "list" ]; then
  echo
  if [ "$total" -gt 0 ]; then
    echo -e "${YELLOW}${total} open workflow issue(s) across ${clients} client(s).${NC}"
    echo "Fix them in this library, then:"
    echo "  ./deploy-all.sh"
    echo "  ./sweep-issues.sh --resolve WFI-NNN --client <name> \"fixed in vX.Y.Z\""
  else
    echo -e "${GREEN}No open workflow issues across ${clients} client(s).${NC}"
  fi
fi

[ "$total" -gt 0 ]
