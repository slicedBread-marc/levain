#!/usr/bin/env bash
# wf-unclaim.sh <plan-name>
# Releases a claim on a plan. Safe to call even if no claim exists.
#
# Releasing is also a TRIGGER. wf-spawn.sh refuses to launch a successor while
# the plan is still claimed, and the claim it most often meets is the outgoing
# worker's own: the exit contract is commit the transition, close the gate,
# unclaim — so the post-commit hook that wants to start verify always fires
# while implement still holds the plan (WFI-086, WFI-091). Rather than decline,
# wf-spawn.sh leaves a marker in .claude/orchestrator/pending/ and this script
# serves it, here, at the one moment every guard can answer honestly.

set -euo pipefail

plan_name="${1:?Usage: wf-unclaim.sh <plan-name>}"

# A release is idempotent, so it cannot tell a plan that was never claimed from
# a plan whose name was mistyped — both report success. That is fine for the
# first case and dangerous for the second: "Released PLN-2O6" reads as done
# while the real claim on PLN-206 stays held, and the next worker is refused by
# a guard nobody is looking at any more (WFI-206). So the one thing that IS
# checkable — that the argument is shaped like an artifact ID at all — is
# checked here. It catches every flag typo and every letter-for-digit slip.
if ! printf '%s' "$plan_name" | grep -qE '^(PLN|BUG|BRF)-[0-9]+'; then
  echo "Usage: wf-unclaim.sh <plan-name>" >&2
  echo "Error: '$plan_name' is not an artifact ID — expected PLN-NNN, BUG-NNN or BRF-NNN, optionally followed by -<slug>." >&2
  exit 2
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

# Always resolve to the develop root (first worktree) so unclaim works
# regardless of whether this runs from develop or a feature worktree. Both
# locations are removed: the canonical number-keyed claim, and any pre-v5.6
# claim left in the plan folder by a worker that started before the upgrade.
develop_root="$(wf_develop_root)"
if claim_dir=$(wf_claim_dir "$plan_name"); then
  rm -f "$claim_dir/.wf-claim"
fi
rm -f "$develop_root/plans/${plan_name}/.wf-claim"
echo "Released $plan_name"

# ── Flush any spawn deferred behind that claim ────────────────────────────
#
# Keyed on the artifact NUMBER, the same identity wf-spawn.sh guards on: the
# counter is global and one piece of work has two names on its way through spec
# (BUG-022 → PLN-022), so a name-keyed queue would miss its own marker.
num=$(printf '%s' "$plan_name" | grep -oE '(PLN|BUG|BRF)-[0-9]+' | head -1 | sed 's/.*-//')
[ -n "$num" ] || exit 0

pending_dir="$(wf_orch_dir)/pending"
[ -d "$pending_dir" ] || exit 0

shopt -s nullglob
for marker in "$pending_dir/${num}-"*.spawn; do
  IFS=$'\t' read -r role artifact model_override < "$marker" || true
  rm -f "$marker"
  [ -n "${role:-}" ] && [ -n "${artifact:-}" ] || continue
  echo "wf-unclaim: claim released — serving deferred $role spawn for $artifact" >&2
  # Never fatal. The daemon's sweep is the safety net behind this nudge, and a
  # release that fails because the work already moved on is not an error.
  if [ -n "${model_override:-}" ]; then
    "$SELF_DIR/wf-spawn.sh" "$role" "$artifact" --model "$model_override" || true
  else
    "$SELF_DIR/wf-spawn.sh" "$role" "$artifact" || true
  fi
done
