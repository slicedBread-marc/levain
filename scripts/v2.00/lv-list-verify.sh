#!/usr/bin/env bash
# lv-list-verify.sh — plans in verify state from REGISTRY.md
# Format: <plan-name>\t<unchecked>\t<escalated>\t<goal>
# Held plans add a field: …\t<goal>\tblocked:<deps>
#
# HELD MEANS NOT DISPATCHED (a client's LVI-064). A verify plan can gain a Deps
# entry after it was built: a needs-input answered "hold until PLN-X lands"
# writes PLN-X there (lv-gate-close.sh --hold-until). Without this field the
# dispatcher sent verify straight back, and the worker re-asked the question it
# had just answered — three times in four minutes on PLN-143. The row stays, so
# the board shows the hold; candidates_verify skips it, as candidates_test
# skips a blocked testing row.
# Exit 0 if any found, exit 1 if none.
set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

while IFS=$'\037' read -r id slug state _priority _branch _updated _wf _tags deps; do
  [ "$state" = "verify" ] || continue

  plan_dir="plans/${id}-${slug}"
  plan_name="${id}-${slug}"

  unchecked=0; escalated=0
  findings="$plan_dir/findings.md"
  if [ -f "$findings" ]; then
    unchecked=$(grep -c '^\- \[ \]' "$findings" 2>/dev/null || true)
    escalated=$(wf_escalated_count "$findings")
  fi

  goal=$(wf_goal_text "$plan_dir/plan.md")

  blocking=$(wf_blocking_deps "$deps" "$REGISTRY" 2>/dev/null) || blocking=""
  if [ -n "$blocking" ]; then
    printf "%s\t%s\t%s\t%s\tblocked:%s\n" "$plan_name" "$unchecked" "$escalated" "$goal" "$blocking"
  else
    printf "%s\t%s\t%s\t%s\n" "$plan_name" "$unchecked" "$escalated" "$goal"
  fi
  found=1
done < <(wf_registry_rows "$REGISTRY")

exit $((1 - found))
