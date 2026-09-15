#!/usr/bin/env bash
# wf-profile.sh [--show|--check]
#
# Reads this project's declared governance tier (`projectProfile.tier` in
# claude-workflow.yml — see docs/project-profile.md) and reports on it.
# `--check` compares it against the knobs it recommends and flags drift.
#
# This script is READ-ONLY. It never writes claude-workflow.yml. The tier is
# a recorded stance — the reason specApproval.mode, manualTestGate, and
# orchestrator.autonomy are set the way they are — not a runtime switch
# anything else in the pipeline consults. Applying a tier (or a tier change)
# to those knobs is a deliberate edit, same as any other config change; ask
# Claude to "apply the <tier> profile" and it edits them by hand, the same
# way a human would, with the rationale comments intact.
#
#   wf-profile.sh --show     tier, reason, who, when
#   wf-profile.sh --check    tier's recommendation vs. the actual knobs
#
# Exit (--check): 0 no drift, 1 drift found, 2 no tier declared or unknown tier.
# Exit (--show):  0 always if a tier is declared, 1 if none is.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

mode="${1:---show}"

tier=$(wf_cfg projectProfile.tier "")
reason=$(wf_cfg projectProfile.reason "")
set_by=$(wf_cfg projectProfile.set_by "")
set_on=$(wf_cfg projectProfile.set_on "")

if [ -z "$tier" ]; then
  echo "No projectProfile declared in claude-workflow.yml." >&2
  echo "See docs/project-profile.md to add one." >&2
  exit "$([ "$mode" = "--check" ] && echo 2 || echo 1)"
fi

case "$mode" in
  --show)
    echo "tier:   $tier"
    echo "reason: ${reason:-(none recorded)}"
    echo "set by: ${set_by:-?} on ${set_on:-?}"
    ;;

  --check)
    case "$tier" in
      pre-launch) want_spec="verdict"; want_cosmetic="false" ;;
      governed)   want_spec="gate";    want_cosmetic="true"  ;;
      *)
        echo "Unknown tier '$tier' — expected pre-launch or governed. See docs/project-profile.md." >&2
        exit 2
        ;;
    esac

    spec_mode=$(wf_cfg specApproval.mode gate)
    block_cosmetic=$(wf_cfg manualTestGate.blockOnCosmetic true)
    autonomy_mode=$(wf_cfg orchestrator.autonomy.mode attended)
    production_url=$(wf_cfg production_url "")
    standing_for=$(wf_cfg_list orchestrator.autonomy.standing_for 2>/dev/null | tr '\n' ',' | sed 's/,$//')

    drift=0

    if [ "$spec_mode" != "$want_spec" ]; then
      echo "DRIFT specApproval.mode: $spec_mode (tier '$tier' recommends $want_spec)"
      drift=1
    fi

    if [ "$block_cosmetic" != "$want_cosmetic" ]; then
      echo "DRIFT manualTestGate.blockOnCosmetic: $block_cosmetic (tier '$tier' recommends $want_cosmetic)"
      drift=1
    fi

    if [ "$tier" = "governed" ] && printf '%s' "$standing_for" | grep -q "production-push"; then
      echo "DRIFT orchestrator.autonomy.standing_for includes production-push under a governed tier — review whether that grant should still stand"
      drift=1
    fi

    # A pre-launch project with a real production_url has somewhere to push
    # to — the recommendation table says "standing, through production-push".
    # A blank production_url (client-i, client-b) means there is nothing
    # to be autonomous about yet, so this check stays silent rather than
    # demanding a grant for a push path that doesn't exist.
    if [ "$tier" = "pre-launch" ] && [ -n "$production_url" ]; then
      if [ "$autonomy_mode" != "standing" ]; then
        echo "DRIFT orchestrator.autonomy.mode: ${autonomy_mode:-(unset)} (tier '$tier' with production_url set recommends standing, through production-push)"
        drift=1
      else
        for want_action in release deploy production-push; do
          if ! printf '%s' "$standing_for" | tr ',' '\n' | grep -qx "$want_action"; then
            echo "DRIFT orchestrator.autonomy.standing_for is missing '$want_action' (tier '$tier' with production_url set recommends release, deploy, production-push)"
            drift=1
          fi
        done
      fi
    fi

    [ "$drift" -eq 0 ] && echo "OK — '$tier' tier, no drift ($set_by, $set_on)"
    exit "$drift"
    ;;

  *)
    echo "Usage: $0 [--show|--check]" >&2
    exit 2
    ;;
esac
