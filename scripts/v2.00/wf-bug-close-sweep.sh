#!/usr/bin/env bash
# wf-bug-close-sweep.sh [--apply]
#
# Finds bugs sitting in bugs/triaged/ whose linked plan is already `complete`
# in the registry, but which were never actually closed.
#
# WHY THIS EXISTS
#
# wf-deploy's "Close linked bugs" step only ever looks at the plans a SINGLE
# deploy run just carried — it reads each one's `plan.md` for a `**Bug:**`
# field and closes it. That is right for the common case, but it has no way
# to catch a bug whose link was never acted on at the time: the step didn't
# exist yet when the plan completed, an earlier deploy skipped it on error,
# or the bug was linked by `wf-bug-consume.sh` after its plan had already
# shipped. Once that window passes, nothing sweeps back over it — client-c
# ended up with BUG-011 and BUG-012 sitting in `bugs/triaged/` moved there
# ("consumed by PLN-011...") while PLN-011 and PLN-012 had been `complete` in
# the registry for a full deploy cycle each, with no commit anywhere closing
# either (WFI-017).
#
# This is the general check, run over every triaged bug rather than one
# deploy's batch, so it also catches drift `/wf-deploy`'s scoped step cannot
# see by construction. Read-only by default, matching this repo's own
# check-profiles.sh / sweep-issues.sh: report what's inconsistent, apply only
# on request.
#
# stdout (no --apply): one line per orphaned bug —
#   <bug-id>\t<plan-id>\t<bug-dir>
# stderr: a one-line count.
#
# --apply: also runs `wf-bug-close.sh <bug-id> <plan-id>` for each one found.
#
# Exit 0 whether or not anything was found (this is a report, not a pass/fail
# check) — 1 only on a real error (no develop root, no registry).

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

apply=false
case "${1:-}" in
  --apply) apply=true ;;
  "") ;;
  *) echo "Usage: $0 [--apply]" >&2; exit 1 ;;
esac

ROOT="$(wf_develop_root)"
REGISTRY="$ROOT/plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

cd "$ROOT"

found=0
for bug_md in bugs/triaged/*/bug.md; do
  [ -f "$bug_md" ] || continue

  status=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Status:\*\*' "$bug_md" 2>/dev/null || true)
  case "$status" in *[Cc]losed*) continue ;; esac

  plan_field=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Plan:\*\*' "$bug_md" 2>/dev/null \
               | sed -E 's/^.*\*\*Plan:\*\*[ \t]*//; s/[ \t]*$//; s#/$##' || true)
  case "$plan_field" in ""|*"(none"*|*_none_*) continue ;; esac

  plan_id=$(printf '%s' "$plan_field" | grep -oE '^PLN-[0-9]+' || true)
  [ -n "$plan_id" ] || continue

  state=$(wf_registry_field "$plan_id" state "$REGISTRY")
  [ "$state" = "complete" ] || continue

  bug_id=$(wf_bug_id "$bug_md")
  [ -n "$bug_id" ] || continue
  bug_dir=$(dirname "$bug_md")

  printf '%s\t%s\t%s\n' "$bug_id" "$plan_id" "$bug_dir"
  found=$((found + 1))

  if $apply; then
    "$SELF_DIR/wf-bug-close.sh" "$bug_id" "$plan_field" >&2 || \
      echo "wf-bug-close-sweep: wf-bug-close.sh failed for $bug_id / $plan_field — left open" >&2
  fi
done

echo "ORPHANED: $found" >&2
exit 0
