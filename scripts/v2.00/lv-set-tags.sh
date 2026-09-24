#!/usr/bin/env bash
# lv-set-tags.sh <plan-id> <tags>
# Sets the Tags column (9th) for a plan in REGISTRY.md.
# Tags are comma-separated, no spaces. Use "—" to clear.
#
# The vocabulary is the project's own — whatever plans already carry, plus
# anything declared in claude-workflow.yml (`tags:`, `specApproval.gateTags`).
# See lv-list-tags.sh. A name outside it is a WARNING, not an error: this
# script used to hardcode `security arcade admin lessons ux infra e2e bugfix`
# and reject everything else, so a project whose gating tag was `contract`
# could not assign the one tag that gates. Refusing an unknown tag makes the
# first legitimate use of any new name impossible, which is a worse failure
# than a typo that shows up in `lv-list-tags.sh` with a count of 1.
#
# Examples:
#   lv-set-tags.sh PLN-004 security
#   lv-set-tags.sh PLN-004 security,admin
#   lv-set-tags.sh PLN-004 —

set -euo pipefail

# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

raw_id="${1:-}"
tags="${2:-}"

plan_id=$(echo "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || echo "$raw_id")

if [ -z "$plan_id" ] || [ -z "$tags" ]; then
  echo "Usage: $0 <plan-id> <tags>" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

# Normalize: strip all whitespace so the registry never holds "a, b" (comma-space).
if [ "$tags" != "—" ]; then
  tags=$(printf '%s' "$tags" | tr -d '[:space:]')
fi

if ! grep -q "^| $plan_id |" "$REGISTRY"; then
  echo "Error: $plan_id not found in registry" >&2
  exit 1
fi

# Flag names outside the project's vocabulary — before taking the lock, since
# lv-list-tags.sh reads the registry too.
if [ "$tags" != "—" ]; then
  known=$("$SELF_DIR/lv-list-tags.sh" 2>/dev/null | cut -f1 || true)
  unknown=""
  IFS=',' read -ra tag_list <<< "$tags"
  for tag in "${tag_list[@]}"; do
    tag=$(echo "$tag" | xargs)
    [ -n "$tag" ] || continue
    printf '%s\n' "$known" | grep -qx "$tag" || unknown="$unknown $tag"
  done
  if [ -n "$unknown" ]; then
    echo "Note: new tag(s) for this project:$unknown" >&2
    if [ -n "$known" ]; then
      echo "      In use: $(printf '%s\n' "$known" | paste -sd, - | sed 's/,/, /g')" >&2
    fi
    echo "      Assigned anyway. Check it is not a typo — a misspelt tag that" >&2
    echo "      should have matched specApproval.gateTags silently skips a gate." >&2
  fi
fi

# Read-modify-write from here down.
wf_lock_acquire registry

# Writes the Tags column, upgrading a pre-v5 row that has no Tags/Deps columns
# on the way past. Both of those rules live in wf_registry_set_field.
wf_registry_set_field "$plan_id" tags "$tags" "$REGISTRY"

wf_registry_commit "registry($plan_id): tags → $tags"

echo "$plan_id: tags → $tags"
