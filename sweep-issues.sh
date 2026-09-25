#!/usr/bin/env bash
# sweep-issues.sh — collect workflow-harness problems reported by every client.
#
# Clients file process bugs into their own WORKFLOW-ISSUES.md as they hit them
# (scripts/lv-exec.sh lv-issue.sh). This walks deployments.txt, gathers the open
# ones, and prints them grouped by project so they can be fixed HERE — in the
# library — rather than worked around individually in each client.
#
#   ./sweep-issues.sh              open issues, grouped by client
#   ./sweep-issues.sh --all        include already-resolved entries
#   ./sweep-issues.sh --count      one "<client>: <n>" line per project
#   ./sweep-issues.sh --resolve LVI-003 --client app "fixed in v2.6.0"
#   ./sweep-issues.sh --upstream   open issues and PRs on the public repo
#                                  (gh; LV_UPSTREAM_REPO overrides it). Taking
#                                  one in: docs/upstream-intake.md
#
# Exit 0 if any open issues were found, 1 if every client is clean — so
# `./sweep-issues.sh >/dev/null && echo "work to do"` reads correctly.

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

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
[ -t 1 ] || { GREEN=''; YELLOW=''; BOLD=''; DIM=''; NC=''; }

# ── --upstream: what strangers sent (LVI-019) ─────────────────────────────
#
# The clients' WORKFLOW-ISSUES.md files are only this operator's reports. Users
# of the public copy report on GitHub, and nothing listed those, so a public
# issue or PR sat unseen until somebody went looking. It needs no registry,
# so it is answered before the registry is read. Listing only: taking one in
# is a human's read first (docs/upstream-intake.md), never a script's.
if [ "${1:-}" = "--upstream" ]; then
  repo="${LV_UPSTREAM_REPO:-slicedBread-marc/levain}"
  command -v gh >/dev/null 2>&1 || { echo "sweep-issues.sh: --upstream needs the gh CLI" >&2; exit 2; }
  fmt='.[] | "  #\(.number)  \(.title)  — \(.author.login), updated \(.updatedAt[0:10])"'
  issues=$(gh issue list -R "$repo" --state open --limit 100 --json number,title,author,updatedAt --jq "$fmt" 2>&1) \
    || { echo "sweep-issues.sh: gh could not list $repo's issues: $issues" >&2; exit 2; }
  prs=$(gh pr list -R "$repo" --state open --limit 100 --json number,title,author,updatedAt --jq "$fmt" 2>&1) \
    || { echo "sweep-issues.sh: gh could not list $repo's pull requests: $prs" >&2; exit 2; }
  n=0
  if [ -n "$issues" ]; then
    printf "${BOLD}══ %s — issues${NC}\n%s\n\n" "$repo" "$issues"; n=$((n + $(printf '%s\n' "$issues" | wc -l)))
  fi
  if [ -n "$prs" ]; then
    printf "${BOLD}══ %s — pull requests${NC}\n%s\n\n" "$repo" "$prs"; n=$((n + $(printf '%s\n' "$prs" | wc -l)))
  fi
  if [ "$n" -eq 0 ]; then
    printf "${GREEN}Nothing open on %s.${NC}\n" "$repo"; exit 1
  fi
  printf "${YELLOW}%d open on %s.${NC} Read each before anything else, then take it in by\n" "$n" "$repo"
  echo "  docs/upstream-intake.md — never apply one unread."
  exit 0
fi

CLIENT_LIST=$(registry) || { echo "sweep-issues.sh: the project-registry hook failed" >&2; exit 1; }
[ -n "$CLIENT_LIST" ] || { echo "sweep-issues.sh: no projects in the registry (deployments.txt)" >&2; exit 1; }

mode="list"
show_all=false
resolve_id=""
resolve_client=""
resolve_note="resolved"

while [ $# -gt 0 ]; do
  case "$1" in
    --all)     show_all=true; shift ;;
    --count)   mode="count"; shift ;;
    --resolve) mode="resolve"; resolve_id="${2:?--resolve requires LVI-NNN}"; shift 2 ;;
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
      grep -qE "^## [A-Z]{1,5}-${resolve_id#*-} " "$issues" 2>/dev/null || continue
      # Resolve through the client's own script so the format stays owned by
      # one place, and the client's version of it is the one that runs.
      #
      # Report what it actually said, not what we asked for: an entry resolved
      # earlier is left alone, and a caller sweeping a batch needs to see which
      # of its IDs were already on the record rather than a uniform "resolved".
      out=$( cd "$client" && ./scripts/lv-exec.sh lv-issue.sh --resolve "$resolve_id" "$resolve_note" 2>&1 )
      case "$out" in
        *"not overwriting"*) echo -e "${YELLOW}  $name: $out${NC}"; continue ;;
      esac

      # Commit it, here, now. lv-issue.sh deliberately never touches git — the
      # session that FILES an issue is inside that project and commits the file
      # with the rest of its work. A resolve has no such session: this loop is
      # the only thing that ran, it leaves a tracked file dirty in a repo it
      # does not otherwise touch, and then walks away.
      #
      # That is not a cosmetic gap. A resolve written on 2026-08-16 was still
      # sitting unstaged in client-a when that project's own workers merged
      # develop -> release -> main; the merge swept the working tree and nine
      # resolutions vanished with no error anywhere. The library reported them
      # resolved, the client reported them open, and the next sweep re-fixed
      # bugs that were already fixed. Exactly the loss WFI-164 describes, one
      # level up.
      #
      # An explicit pathspec and no branch handling on purpose: a sweep must
      # never move a client's checkout (WFI-157). If WORKFLOW-ISSUES.md is the
      # only path named, whatever branch the client is standing on is where the
      # record lands, which is correct on every branch.
      #
      # Subject, then the note as the BODY. A resolution note is a paragraph —
      # the whole point is that it explains the fix — and putting it after -m
      # as one string makes it all one subject line, which `git log --oneline`
      # then renders as a wall.
      crc=0
      cout=$( cd "$client" \
        && git add WORKFLOW-ISSUES.md \
        && git commit -q -m "chore(workflow): $resolve_id resolved upstream" \
             -m "$resolve_note" -- WORKFLOW-ISSUES.md 2>&1 ) || crc=$?
      if [ "$crc" -eq 0 ]; then
        echo -e "${GREEN}  $name: $resolve_id resolved and committed${NC}"
      else
        echo -e "${YELLOW}  $name: $resolve_id resolved but NOT committed — it will be lost${NC}"
        printf '%s\n' "$cout" | sed 's/^/      /'
      fi
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
done <<< "$CLIENT_LIST"

if [ "$mode" = "list" ]; then
  echo
  if [ "$total" -gt 0 ]; then
    echo -e "${YELLOW}${total} open workflow issue(s) across ${clients} client(s).${NC}"
    echo "Fix them in this library, then:"
    echo "  ./deploy-all.sh"
    echo "  ./sweep-issues.sh --resolve LVI-NNN --client <name> \"fixed in vX.Y.Z\""
  else
    echo -e "${GREEN}No open workflow issues across ${clients} client(s).${NC}"
  fi
fi

[ "$total" -gt 0 ]
