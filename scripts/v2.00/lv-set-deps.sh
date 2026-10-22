#!/usr/bin/env bash
# lv-set-deps.sh <plan-id> <deps>
# Sets the Deps column (10th) for a plan in REGISTRY.md.
# Deps are comma-separated plan IDs, or the ID of a bug or brief filed here and
# not specced yet. Use "—" to clear.
#
# Examples:
#   lv-set-deps.sh PLN-004 PLN-001
#   lv-set-deps.sh PLN-004 PLN-001,PLN-003
#   lv-set-deps.sh PLN-004 BUG-081
#   lv-set-deps.sh PLN-004 client-d:BRF-009
#   lv-set-deps.sh PLN-004 PLN-001,client-d:BRF-009
#   lv-set-deps.sh PLN-004 —
#
# A DEPENDENCY IN ANOTHER REPO
#
# `<project>:<ARTIFACT-ID>` names an artifact in a project declared under
# `dependencies:` in this project's levain.yml — the same key
# lv-dep-bug.sh files through, and the same local checkout.
#
# client-b WFI-015: PLN-011 was blocked on client-d's BRF-009 / BUG-011 and
# there was nowhere to record it. This script took plan IDs only, and
# `lv-list-tags.sh --gating` offered `security`, which would have been a false
# label. So the only thing keeping the daemon off the plan was a lv-claim.sh
# lease — explicitly documented as stealable by any session that judges it
# stale. The plan sat in `draft`, a dispatchable state, with a live daemon
# (pid 84870) that would have replanned it against copper tokens that do not
# exist yet.
#
# It is checked, not merely declared. wf_external_dep_state reads the other
# project's own REGISTRY.md and bugs/closed/, by NUMBER — BRF-009, PLN-009 and
# a closed BUG-009 are the same artifact under the ID system — so the block
# lifts by itself when the work lands over there. A marker that only a human
# could clear would be the same stall in a different column.
#
# Validation here is of the PROJECT, not the artifact: a dependency may
# legitimately be on work that has not been filed yet. A project name that
# matches no `dependencies:` entry is a typo, and a typo that blocks forever is
# indistinguishable from the bug this fixes.

set -euo pipefail

# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
deps="${2:-}"

plan_id=$(echo "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || echo "$raw_id")

if [ -z "$plan_id" ] || [ -z "$deps" ]; then
  echo "Usage: $0 <plan-id> <deps>" >&2
  exit 1
fi

[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

if ! grep -q "^| $plan_id |" "$REGISTRY"; then
  echo "Error: $plan_id not found in registry" >&2
  exit 1
fi

# Validate deps (skip for clear). A local dep must have a row here; an
# external one must name a declared dependency project.
if [ "$deps" != "—" ]; then
  IFS=',' read -ra dep_list <<< "$deps"
  for dep in "${dep_list[@]}"; do
    dep=$(echo "$dep" | xargs)
    if wf_is_external_dep "$dep"; then
      proj="${dep%%:*}"
      if ! wf_dep_project_path "$proj" >/dev/null; then
        echo "Error: '$dep' names project '$proj', which is not in dependencies:" >&2
        configured=$(wf_cfg_list dependencies | sed 's/:.*//' | paste -sd, - 2>/dev/null || true)
        if [ -n "$configured" ]; then
          echo "  Declared dependencies: $configured" >&2
        else
          echo "  No 'dependencies:' key in levain.yml. Add one:" >&2
          echo "    dependencies:" >&2
          echo "      - \"$proj:/absolute/path/to/$proj\"" >&2
        fi
        echo "  A project name that matches nothing blocks this plan forever," >&2
        echo "  which is the failure this exists to fix (client-b WFI-015)." >&2
        exit 1
      fi
      # Any ID shape: the other project names its artifacts by its own ID map.
      if ! [[ "$dep" =~ :[A-Z]{1,5}-[0-9]+$ ]]; then
        echo "Error: '$dep' — external deps are <project>:<ID>, e.g. <project>:$LV_PLN-NNN" >&2; exit 1
      fi
      continue
    fi
    # A bug or brief filed here but not specced yet has no row. It keeps its
    # number when it becomes a plan, and wf_state_of reads it through the PLN
    # alias, so it blocks as `—` until then and lifts when the plan completes.
    # Refusing it left a plan nowhere to record the bug it waits on
    # (a client's LVI-022, LVI-007).
    if ! grep -q "^| $dep |" "$REGISTRY" &&
       ! compgen -G "bugs/*/$dep-*" >/dev/null && [ ! -e "bugs/open/$dep" ] &&
       ! compgen -G "plans/briefs/$dep-*" >/dev/null; then
      echo "Error: dependency '$dep' not found in registry, bugs/ or plans/briefs/" >&2
      exit 1
    fi
  done
fi

# Read-modify-write from here down.
wf_lock_acquire registry

# Writes the Deps column, upgrading a pre-v5 row that has no Tags/Deps columns
# on the way past. Both of those rules live in wf_registry_set_field.
wf_registry_set_field "$plan_id" deps "$deps" "$REGISTRY"

wf_registry_commit "registry($plan_id): deps → $deps"

echo "$plan_id: deps → $deps"
