#!/usr/bin/env bash
# lv-profile.sh [--show|--check]
#
# Reads this project's declared governance tier (`projectProfile.tier` in
# levain.yml — see docs/project-profile.md) and reports on it.
# `--check` compares it against the knobs it recommends and flags drift.
#
# This script is READ-ONLY. It never writes levain.yml. The tier is
# a recorded stance — the reason specApproval.mode, manualTestGate, and
# orchestrator.autonomy are set the way they are — and a runtime switch in
# two places until projectProfile.live_from: lv-autonomy.sh lets a pre-launch
# project push to production unattended (LVI-036), and question gates take the
# worker's recommendation, with human checks moved to the end state
# (wf_self_answers, lv-end-state.sh, a client's LVI-034). Applying a tier (or a tier change)
# to those knobs is a deliberate edit, same as any other config change; ask
# Claude to "apply the <tier> profile" and it edits them by hand, the same
# way a human would, with the rationale comments intact.
#
#   lv-profile.sh --show     tier, reason, who, when
#   lv-profile.sh --check    tier's recommendation vs. the actual knobs
#
# Exit (--check): 0 no drift, 1 drift found, 2 no tier declared or unknown tier.
# Exit (--show):  0 always if a tier is declared, 1 if none is.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

mode="${1:---show}"

tier=$(wf_cfg projectProfile.tier "")
reason=$(wf_cfg projectProfile.reason "")
set_by=$(wf_cfg projectProfile.set_by "")
set_on=$(wf_cfg projectProfile.set_on "")
live_from=$(wf_cfg projectProfile.live_from "")
case "$live_from" in null|'~'|Null|NULL) live_from="" ;; esac
today="${LV_AUTONOMY_TODAY:-$(wf_today)}"

if [ -z "$tier" ]; then
  echo "No projectProfile declared in levain.yml." >&2
  echo "See docs/project-profile.md to add one." >&2
  exit "$([ "$mode" = "--check" ] && echo 2 || echo 1)"
fi

case "$mode" in
  --show)
    echo "tier:   $tier"
    echo "reason: ${reason:-(none recorded)}"
    echo "set by: ${set_by:-?} on ${set_on:-?}"
    echo "live:   ${live_from:-(not set — no real users)}"
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

    spec_mode=$(wf_cfg specApproval.mode verdict)
    block_cosmetic=$(wf_cfg manualTestGate.blockOnCosmetic true)
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

    # A pre-launch project no longer needs a standing grant to push: since
    # LVI-036 lv-autonomy.sh authorizes production-push by default until
    # live_from. What drifts now is the date itself — a pre-launch tier whose
    # live_from has passed is a live project still described as having no
    # users. The push is already attended (lv-autonomy.sh stops the default on
    # live_from), but every other knob the tier recommends is still loose.
    if [ -n "$live_from" ] && ! printf '%s' "$live_from" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
      echo "DRIFT projectProfile.live_from: '$live_from' is not YYYY-MM-DD — lv-autonomy.sh refuses every action until it is"
      drift=1
    elif [ "$tier" = "pre-launch" ] && [ -n "$live_from" ] && ! [ "$live_from" \> "$today" ]; then
      echo "DRIFT projectProfile.tier: pre-launch, but live_from $live_from has passed — the project is live; set tier: governed and apply its knobs"
      drift=1
    fi

    [ "$drift" -eq 0 ] && echo "OK — '$tier' tier, no drift ($set_by, $set_on)"
    exit "$drift"
    ;;

  *)
    echo "Usage: $0 [--show|--check]" >&2
    exit 2
    ;;
esac
