#!/usr/bin/env bash
# lv-check-deps.sh <plan-id>
# Checks whether all dependencies for a plan are complete.
#
# Reads the Deps column ($10) from REGISTRY.md for the given plan.
# Output:
#   CLEAR                           — no deps or all deps complete
#   BLOCKED <dep1>,<dep2>           — one or more deps not complete
#   DEAD <dep>                      — a dep is abandoned; it will never complete
#   EXTERNAL <project:ID>,…         — blocked on another repo's work, and on
#                                     nothing here (client-b WFI-015). Reported
#                                     apart from BLOCKED because the answer is
#                                     different: nothing in this pipeline moves
#                                     it, and the dependent is correctly parked
#                                     rather than late. Mixed with a local
#                                     block it reports BLOCKED, which is the
#                                     nearer truth — there is work here to do.
#
# Exit 0 always (caller checks stdout).

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
plan_id=$(echo "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || echo "$raw_id")

if [ -z "$plan_id" ]; then
  echo "Usage: $0 <plan-id>" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "CLEAR"; exit 0; }

deps=$(wf_registry_field "$plan_id" deps "$REGISTRY")
[ -n "$deps" ] && [ "$deps" != "—" ] || { echo "CLEAR"; exit 0; }

# An incomplete dependency is "not yet"; an abandoned one is "never". Reported
# identically they are not the same situation at all — waiting resolves the
# first and can only stall on the second, which is why an abandoned dep used to
# block its dependents forever with no way to clear it (WFI-008).
blocking=""
dead=""
external=""
IFS=',' read -ra dep_list <<< "$deps"
for dep_id in "${dep_list[@]}"; do
  dep_id=$(echo "$dep_id" | xargs)
  # Another repo's artifact. Resolved through that project's own registry and
  # closed bugs, so this clears itself when the work lands there rather than
  # waiting for someone to remember to edit a column (client-b WFI-015).
  if wf_is_external_dep "$dep_id"; then
    wf_external_dep_state "$dep_id"      # two returns, so no $( ) — see the lib
    ext_state="$LV_EXTERNAL_DEP_STATE"
    detail="$LV_EXTERNAL_DEP_DETAIL"
    # An `if`, not `&&`: a false test as the last command of a case branch
    # makes the branch exit 1 and `set -e` kills the script.
    if [ "$ext_state" = "complete" ]; then
      if [ "$detail" = "abandoned" ]; then dead="${dead:+$dead,}$dep_id"; fi
    else
      external="${external:+$external,}$dep_id ($detail)"
    fi
    continue
  fi
  dep_state=$(wf_registry_field "$dep_id" state "$REGISTRY")
  case "$dep_state" in
    complete) ;;
    abandoned) [ -n "$dead" ] && dead="$dead,$dep_id" || dead="$dep_id" ;;
    *) [ -n "$blocking" ] && blocking="$blocking,$dep_id" || blocking="$dep_id" ;;
  esac
done

if [ -n "$dead" ]; then
  echo "DEAD $dead"
  echo "lv-check-deps.sh: $dead abandoned — will never complete. Amend or drop the dependency:" >&2
  echo "  scripts/lv-exec.sh lv-set-deps.sh $plan_id <remaining deps or —>" >&2
  exit 0
fi

if [ -n "$blocking" ]; then
  # A local block outranks an external one: there is work in THIS pipeline
  # that has to happen either way, and BLOCKED is what every caller already
  # routes on. The external refs are still named, on stderr, so the reader is
  # not surprised later.
  echo "BLOCKED $blocking"
  [ -n "$external" ] && echo "lv-check-deps.sh: also waiting on $external" >&2
  exit 0
fi

if [ -n "$external" ]; then
  echo "EXTERNAL $external"
  echo "lv-check-deps.sh: $plan_id is parked on another project's work — nothing here moves it." >&2
  echo "  It clears by itself when that artifact completes; nothing to edit." >&2
  echo "  File the work there if it has not been:" >&2
  echo "    scripts/lv-exec.sh lv-dep-bug.sh --host <project> \"<what you need>\" --kind request" >&2
  exit 0
fi

echo "CLEAR"
