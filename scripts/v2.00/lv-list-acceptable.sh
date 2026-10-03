#!/usr/bin/env bash
# lv-list-acceptable.sh [<plan-id>]
# Outputs plans waiting on a human's acceptance (accept:manual) by reading
# REGISTRY.md. This is /lv-accept's entry list, the counterpart of
# lv-list-testable.sh for the automated half.
#
# Eligible:
#   state `accept`                       shape `accept`
#   state `testing` with an OPEN         shape `legacy` — how a plan waited for
#     manual-test gate                   a human before the accept state existed.
#                                        /lv-accept moves it to `accept` first.
#
# Format per line (stdout): <plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>\t<shape>
# Stderr summary: ACCEPTABLE: N, TOTAL: N, and CLAIMED: rows like lv-list-testable.sh
#
# With <plan-id>, only that plan is considered (exit 1 if it is not eligible).
#
# Deps are NOT a reason to withhold a plan here. A dependency that has not
# shipped blocks this plan's merge, which /lv-test's ship exit already checks;
# it does not stop a person judging what is on the screen.
#
# Exit 0 if any acceptable found, exit 1 if none.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

only=""
if [ -n "${1:-}" ]; then
  only=$(printf '%s' "$1" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
  [ -n "$only" ] || { echo "lv-list-acceptable: not a plan id: $1" >&2; exit 2; }
fi

rows=$(wf_registry_rows "$REGISTRY")

acceptable=0
total=0
claimed_plans=()

while IFS=$'\037' read -r id slug state priority branch _updated _wf _tags _deps; do
  [ -z "$only" ] || [ "$id" = "$only" ] || continue
  case "$state" in
    accept)  shape="accept" ;;
    testing)
      # Only with the gate open — an ordinary testing plan is the tester's.
      gname=$(wf_gate_field "$(wf_gate_file "$id" 2>/dev/null || true)" GATE_NAME 2>/dev/null || true)
      [ "$gname" = "manual-test" ] || continue
      shape="legacy"
      ;;
    *) continue ;;
  esac
  total=$((total + 1))

  plan_dir="plans/${id}-${slug}"
  [ -d "$plan_dir" ] || continue

  if wf_claim_held "${id}-${slug}"; then
    claimed_plans+=("${id}-${slug}:${LV_CLAIM_AGE}")
    continue
  fi

  plan_name="${id}-${slug}"
  goal=$(wf_goal_text "$plan_dir/plan.md")

  worktree="feature-branches/${plan_name}"
  [ -d "$worktree" ] || worktree=""

  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$plan_name" "$worktree" "$branch" "$goal" "$priority" "$shape"
  acceptable=$((acceptable + 1))
done <<< "$rows"

cat >&2 <<EOF
ACCEPTABLE: $acceptable
TOTAL: $total
EOF

if [ "${#claimed_plans[@]}" -gt 0 ]; then
  echo "CLAIMED:" >&2
  for entry in "${claimed_plans[@]}"; do
    plan="${entry%%:*}"
    age="${entry##*:}"
    mins=$(( age / 60 ))
    echo "  $plan (claimed ${mins}m ago)" >&2
  done
fi

exit $((acceptable > 0 ? 0 : 1))
