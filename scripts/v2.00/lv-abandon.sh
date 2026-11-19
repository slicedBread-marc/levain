#!/usr/bin/env bash
# lv-abandon.sh <plan-id> --reason "<why>" [--revive]
#
# Marks a plan as dropped on purpose, from whatever state it is in.
#
# WHY THIS EXISTS
#
# Every state except `complete` means someone still owes work, and `complete`
# means it shipped. Neither says "this was dropped". Left in a working state a
# dropped plan is indistinguishable from a live one: it shows on /lv-tray, the
# orchestrator dispatches a worker at it, and every lv-list-* keeps offering it.
# The two workarounds available before this existed were both lies — leave it
# working and be re-dispatched forever, or mark it `complete` and claim code
# that never shipped.
#
# app drained 11 feature worktrees, dropped six live plans, and had to invent
# the state to record it — then write the reasons into a hand-authored document
# because the registry had nowhere to put them (WFI-008).
#
# `abandoned` is terminal like `complete`, but not successful. That distinction
# is the whole point, and dependents are where it shows: an incomplete
# dependency is *not yet*, an abandoned one is *never*, and only the second
# means the dependent has to be replanned.
#
# --revive returns a plan to `draft`, the only state it may go back to.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

plan_id=""
reason=""
revive=false

while [ $# -gt 0 ]; do
  case "$1" in
    --reason) reason="${2:?--reason requires text}"; shift 2 ;;
    --revive) revive=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)  plan_id="$1"; shift ;;
  esac
done

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

plan_id=$(printf '%s' "$plan_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
if [ -z "$plan_id" ]; then
  echo "Usage: $0 <$LV_PLN-NNN> --reason \"<why>\" [--revive]" >&2
  exit 1
fi


cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

state=$(wf_registry_field "$plan_id" state "$REGISTRY")
[ -n "$state" ] || { echo "Error: $plan_id has no row in $REGISTRY" >&2; exit 1; }

slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
plan_dir="plans/${plan_id}-${slug}"

if [ "$revive" = "true" ]; then
  [ "$state" = "abandoned" ] || { echo "Error: $plan_id is '$state', not abandoned" >&2; exit 1; }
  revive_add=()
  if [ -d "$plan_dir" ]; then
    printf '\n## Revived — %s\n\n%s\n' "$(date +%Y-%m-%d)" "${reason:-Revived for replanning.}" \
      >> "$plan_dir/progress.md"
    revive_add=(--add "$plan_dir/progress.md")
  fi
  # One commit for the row and the reason (see the abandon path below).
  "$SELF_DIR/lv-registry-update.sh" "$plan_id" abandoned draft \
    --commit "abandon($plan_id): revived → draft" "${revive_add[@]+"${revive_add[@]}"}"
  echo "$plan_id revived → draft. Replan before building: the branch may be stale."
  exit 0
fi

if [ "$state" = "abandoned" ]; then
  echo "$plan_id is already abandoned."
  exit 0
fi
if [ "$state" = "complete" ]; then
  echo "Error: $plan_id is complete — it shipped. Abandoning it would erase that." >&2
  exit 1
fi

if [ -z "$reason" ]; then
  echo "Error: --reason is required." >&2
  echo "       The reason is the only thing that survives; without it the row" >&2
  echo "       says a plan stopped and nothing says why." >&2
  exit 1
fi

# Record the reason BEFORE the transition. If the write fails, the plan is
# still in a state someone will look at, rather than terminal and unexplained.
#
# And the reason is committed WITH the row, in the transition's own commit.
# Without --add, lv-registry-update.sh committed REGISTRY.md alone and left
# progress.md modified on the shared develop checkout, where the next worker's
# stash or pathspec commit takes it (a client's LVI-013).
abandon_add=()
if [ -d "$plan_dir" ]; then
  printf '\n## Abandoned — %s\n\n**Was:** %s\n\n%s\n' \
    "$(date +%Y-%m-%d)" "$state" "$reason" >> "$plan_dir/progress.md"
  abandon_add=(--add "$plan_dir/progress.md")
fi

"$SELF_DIR/lv-registry-update.sh" "$plan_id" "$state" abandoned - \
  --commit "abandon($plan_id): $state → abandoned" "${abandon_add[@]+"${abandon_add[@]}"}"

# Dependents are the reason this state exists rather than a deletion. Say so
# now, while the person who made the decision is still here to act on it.
dependents=$(awk -F'|' -v id="$plan_id" -v work_re="^($LV_WORK_RE)-[0-9]+$" '
  function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
  trim($2) ~ work_re {
    n = split(trim($10), d, ",")
    for (i = 1; i <= n; i++) if (trim(d[i]) == id) print trim($2)
  }
' "$REGISTRY" | tr '\n' ' ' | sed 's/ $//')

if [ -n "$dependents" ]; then
  echo
  echo "WARNING: $dependents depend(s) on $plan_id, which will never complete." >&2
  echo "         Amend or drop the dependency — otherwise those plans stall:" >&2
  for d in $dependents; do
    echo "           scripts/lv-exec.sh lv-set-deps.sh $d <remaining deps or —>" >&2
  done
fi

echo "$plan_id abandoned (was $state). Reason recorded in $plan_dir/progress.md"
