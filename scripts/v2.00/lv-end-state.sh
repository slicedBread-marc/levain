#!/usr/bin/env bash
# lv-end-state.sh [--count] [--since <YYYY-MM-DD>]
#
# What a human owes a pre-launch project at its end state (a client's LVI-034).
#
# A pre-launch project does not stop for questions a worker can answer: the
# worker's recommendation closes the gate (lv-gate-open.sh --recommend), and its
# eyes criteria ship onto the plan's post-ship checklist (lv-manual-gate.sh
# PRELAUNCH, lv-lane.sh answer). Both are deferred, not dropped. This lists them
# in one place, for the review that replaces the gates:
#
#   1. DECISIONS   every gate answered by its recommendation — when, which
#                  plan, which gate, what was decided. From the resolved-gate
#                  ledger, so a decision a later close overwrote is still here.
#   2. CHECKLIST   every unticked post-ship checklist item, by plan. Tick it in
#                  plan.md when it holds; file a bug when it does not.
#   3. DEFERRED    how many plans/deferred-criteria.md rows are still open
#                  (external, soak, unbuilt) — lv-deferred-check.sh has them.
#
# Read-only. Exit 0 always, unless the project cannot be found.
#
#   --count          one line: DECISIONS=<n> CHECKLIST=<n> DEFERRED=<n>
#   --since <date>   decisions on or after this UTC date only

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

count_only=false
since=""
while [ $# -gt 0 ]; do
  case "$1" in
    --count) count_only=true; shift ;;
    --since) since="${2:?--since requires YYYY-MM-DD}"; shift 2 ;;
    *) echo "Usage: $0 [--count] [--since YYYY-MM-DD]" >&2; exit 2 ;;
  esac
done

root=$(wf_develop_root)
resolved="$(wf_orch_dir)/gates/resolved"

# <when> TAB <id> TAB <gate> TAB <answer>
decisions=""
if [ -d "$resolved" ]; then
  decisions=$(for f in "$resolved"/*.log; do
    [ -f "$f" ] || continue
    id=$(basename "$f"); id="${id%%.*}"
    grep -F "$LV_SELF_ANSWER_MARK" "$f" | awk -F'\t' -v id="$id" -v since="$since" -v mark="$LV_SELF_ANSWER_MARK: " '
      substr($1, 1, 10) >= since {
        a = $4; i = index(a, mark); if (i) a = substr(a, i + length(mark))
        print $1 "\t" id "\t" $2 "\t" a
      }' || true
  done | sort)
fi

# <plan-dir> TAB <item>
checklist=$(for p in "$root"/plans/*/plan.md; do
  [ -f "$p" ] || continue
  awk -v d="$(basename "$(dirname "$p")")" '
    /^## Post-ship checklist([ \t]|$)/ { f = 1; next }
    /^## / { f = 0 }
    f && /^- \[ \]/ { sub(/^- \[ \] */, ""); print d "\t" $0 }' "$p"
done)

deferred=0
if [ -f "$root/plans/deferred-criteria.md" ]; then
  deferred=$(grep -c '| open |' "$root/plans/deferred-criteria.md" || true)
fi

n_dec=$(printf '%s' "$decisions" | grep -c . || true)
n_chk=$(printf '%s' "$checklist" | grep -c . || true)

if $count_only; then
  echo "DECISIONS=$n_dec CHECKLIST=$n_chk DEFERRED=$deferred"
  exit 0
fi

if wf_prelaunch; then
  echo "End-state review — $(wf_cfg project_slug "$(basename "$root")"), pre-launch"
else
  echo "End-state review — $(wf_cfg project_slug "$(basename "$root")"), NOT pre-launch: nothing new is deferred here; what is listed predates going live"
fi
echo ""

echo "1. Decisions taken on a worker's recommendation ($n_dec)${since:+ since $since}"
if [ "$n_dec" -eq 0 ]; then
  echo "   none"
else
  printf '%s\n' "$decisions" | awk -F'\t' '{ printf "   %s  %-8s %-15s %s\n", substr($1, 1, 16), $2, $3, $4 }'
fi
echo "   Disagree with one? Reopen it with a directive or a bug; the decision stays in the ledger."
echo ""

echo "2. Shipped without eyes — post-ship checklist ($n_chk)"
if [ "$n_chk" -eq 0 ]; then
  echo "   none"
else
  printf '%s\n' "$checklist" | awk -F'\t' '
    $1 != last { print "   " $1; last = $1 }
    { print "     - " $2 }'
fi
echo "   Holds: tick it in that plan.md. Does not: /lv-bug, naming the plan."
echo ""

echo "3. Deferred criteria still open: $deferred (scripts/lv-exec.sh lv-deferred-check.sh)"
