#!/usr/bin/env bash
# lv-test-tree.sh <plan-name>
#
# Asserts that the caller is standing in that plan's feature worktree, and
# prints a one-line provenance stamp for the result it is about to record:
#
#   TREE feature-branches/PLN-051-admin-mint-machine-names @ feature/PLN-051-admin-mint-machine-names 8f31c0a (2026-08-14T16:41:03Z)
#
# Run it in the SAME shell invocation as the test command:
#
#   cd /abs/path/to/feature-branches/PLN-NNN-slug \
#     && ../../scripts/lv-exec.sh lv-test-tree.sh PLN-NNN-slug \
#     && dotnet test …
#
# Exit 0 when the CWD is the plan's worktree, 1 when it is anywhere else — so
# `&&` stops before a single test runs in the wrong tree.
#
# WHY
#
# A test result is a measurement of one working tree, and nothing in the output
# of `dotnet test` says which. client-a's WFI-132: an unattended tester
# recorded "Total: 1120, Passed: 1114, Failed: 6" against PLN-051 and opened a
# gate saying the implementation "appears incomplete". The feature tree holds
# 1123 tests — the plan adds 3 — so 1120 is develop, which does not carry the
# fix. Verify's own run of the same plan, ten minutes earlier and in the right
# tree, was 1123 passed / 0 failed. A human was sent to hunt a defect that did
# not exist; the inverse — a real failure measured in the wrong tree and read
# as a pass — is the same bug with worse consequences.
#
# Three skills already warn about this in prose (WFI-094, WFI-098, WFI-105).
# Prose did not hold. This is the same instruction as a precondition.
#
# Exit 0 on success, 1 when standing in the wrong tree, 2 on bad input.

set -euo pipefail

# shellcheck source=lv-ids.sh
source "$(dirname "$0")/lv-ids.sh"   # the ID prefix map: LV_PLN_RE and kin

plan_name="${1:-}"

if ! printf '%s' "$plan_name" | grep -qE "^($LV_PLN_RE)-[0-9]+-[a-z0-9-]+$"; then
  echo "lv-test-tree.sh: invalid plan name '$plan_name' — must match $LV_PLN-NNN-slug" >&2
  exit 2
fi

here=$(pwd -P)
main_root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || true
[ -n "$main_root" ] || main_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$here")
main_root=$(cd "$main_root" 2>/dev/null && pwd -P)

want="$main_root/feature-branches/$plan_name"
branch=$(git branch --show-current 2>/dev/null || true)

if [ "$here" != "$want" ]; then
  echo "lv-test-tree.sh: WRONG TREE — refusing to let a run be attributed to $plan_name." >&2
  echo "  standing in : $here" >&2
  echo "  expected    : $want" >&2
  if [ "$here" = "$main_root" ]; then
    echo "  This is the main worktree. Its tests measure develop, which does not carry" >&2
    echo "  this plan's work — a result from here is about a different tree (WFI-132)." >&2
  fi
  if [ ! -d "$want" ]; then
    echo "  That worktree does not exist. The plan may not have been implemented yet;" >&2
    echo "  do not substitute a run from somewhere else." >&2
  fi
  echo "  Fix: cd $want && <re-run the command>" >&2
  exit 1
fi

# In the right directory, but is it the right branch? A worktree can be moved
# off its own branch, and then the path says one thing and the code is another.
if [ -n "$branch" ] && [ "$branch" != "feature/$plan_name" ]; then
  echo "lv-test-tree.sh: this worktree is on '$branch', not 'feature/$plan_name'." >&2
  echo "  The path says $plan_name and the code is somebody else's. Fix the branch first." >&2
  exit 1
fi

printf 'TREE %s @ %s %s (%s)\n' \
  "feature-branches/$plan_name" \
  "${branch:-detached HEAD}" \
  "$(git rev-parse --short HEAD 2>/dev/null || echo '?')" \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
