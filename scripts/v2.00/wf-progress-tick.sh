#!/usr/bin/env bash
# wf-progress-tick.sh <plan-id-or-name> <step-number> [description] [--blocked]
#
# Ticks `Step N` in the plan's progress.md `## Steps` checklist and appends the
# matching `## Log` line. One call per completed step, from wf-implement.
#
#   wf-progress-tick.sh PLN-041 3 "wire the export command"
#   wf-progress-tick.sh PLN-041 4 "blocked on missing migration" --blocked
#
# Why this exists: the checklist used to sit at "1 of 11" while the branch was
# at step 9, because only the Log was ever written. Nothing recorded forward
# progress, so the orchestrator could not tell a resume from a retry and parked
# healthy long plans as `stuck`. The checklist is now the progress signal —
# wf-progress-count.sh reads it and the orchestrator resets the attempt budget
# whenever it climbs.
#
# Always anchored to the develop root, so it is safe to call from a feature
# worktree (where `plans/` does not exist).
#
# Exit 0 on success, 1 on error. A step already ticked is not an error —
# re-running is a no-op on the checklist and still logs.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"
# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"

raw_id="${1:-}"
step="${2:-}"
shift 2 2>/dev/null || true

desc=""
status="done"
while [ $# -gt 0 ]; do
  case "$1" in
    --blocked) status="blocked"; shift ;;
    *) desc="$1"; shift ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE 'PLN-[0-9]+' || true)
if [ -z "$plan_id" ] || ! printf '%s' "$step" | grep -qE '^[0-9]+$'; then
  echo "Usage: $0 <plan-id-or-name> <step-number> [description] [--blocked]" >&2
  exit 1
fi

ROOT="$(wf_develop_root)"
REGISTRY="$ROOT/plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

row=$(grep "^| $plan_id |" "$REGISTRY" | head -1 || true)
[ -n "$row" ] || { echo "Error: $plan_id not found in registry" >&2; exit 1; }
slug=$(printf '%s' "$row" | awk -F'|' '{print $3}' | xargs)
progress="$ROOT/plans/${plan_id}-${slug}/progress.md"
[ -f "$progress" ] || { echo "Error: $progress not found" >&2; exit 1; }

wf_lock_acquire "plan-$plan_id"

today=$(date +%Y-%m-%d)

# ── Tick the checklist row ────────────────────────────────────────────────
# Matches "- [ ] Step N:" and "- [ ] Step N " inside `## Steps` only, so a Log
# line mentioning the same step number is never rewritten.
#
# A step the checklist has never heard of is APPENDED rather than dropped.
# progress.md's checklist is written once, when implementation starts; an
# amendment that adds Steps 6-9 grows plan.md's `## Steps` and leaves this file
# behind. client-a's PLN-030 then ticked 6, 7, 8 and 9 and was told each time
# "checklist now 5/5" — the four newest steps had no row to tick, so the one
# signal the orchestrator reads for forward progress sat frozen at the
# pre-amendment total for the whole second half of the plan (WFI-111).
#
# Appending here rather than in the amendment path is deliberate: the tick is
# the moment the step is known to be real, and this is the only call every
# completed step must make.
if [ "$status" = "done" ]; then
  awk -v want="$step" -v desc="$desc" '
    /^## Steps/ { in_steps = 1; print; next }
    /^## / {
      # Leaving the Steps section — if the wanted step was never seen, it is a
      # step an amendment added. Append it, ticked, after the last checklist
      # row rather than after the blank line that ends the section.
      if (in_steps && !hit) { print rowfor(); appended = 1 }
      in_steps = 0
      flush_held()
    }
    # Blank lines inside Steps are held: they are either mid-section spacing
    # (replayed as-is) or the gap before the next heading (replayed after the
    # appended row).
    in_steps && /^[[:space:]]*$/ { held[++nheld] = $0; next }
    in_steps { flush_held() }
    in_steps && /^[[:space:]]*-[[:space:]]*\[[[:space:]xX]*\][[:space:]]*[Ss]tep[[:space:]]+[0-9]+/ {
      line = $0
      n = line
      sub(/^[^0-9]*/, "", n)
      sub(/[^0-9].*$/, "", n)
      if (n + 0 == want + 0) {
        # Matching an already-ticked row too is what makes a re-run a no-op
        # instead of appending a second copy of the same step.
        hit = 1
        sub(/\[[[:space:]]*\]/, "[x]", line)
        print line
        next
      }
    }
    { print }
    END {
      # Steps was the final section in the file — same append, no closing `## `
      # ever arrived to trigger it above.
      if (in_steps && !hit && !appended) print rowfor()
      flush_held()
    }
    function rowfor(   s) {
      s = "- [x] Step " want
      if (desc != "") s = s ": " desc
      return s
    }
    function flush_held(   i) {
      for (i = 1; i <= nheld; i++) print held[i]
      nheld = 0
    }
  ' "$progress" > "$progress.tmp" && mv "$progress.tmp" "$progress"
fi

# ── Append the log line ───────────────────────────────────────────────────
entry="[$today] Step $step — $status"
[ -n "$desc" ] && entry="$entry ($desc)"

if grep -q "^## Log" "$progress"; then
  printf '%s\n' "$entry" >> "$progress"
else
  printf '\n## Log\n%s\n' "$entry" >> "$progress"
fi

# ── Make the tick durable ─────────────────────────────────────────────────
#
# progress.md lives on the develop root and used to sit dirty for the whole
# implementation, waiting for Phase 3 to commit it. It does not survive there:
# any other worker's `git stash push --include-untracked` takes every dirty
# file in that working tree with it. client-a watched a 2/6 checklist revert
# to 0/6 mid-run with nothing in the session having touched it (WFI-064) — and
# the checklist is the forward-progress signal the attempt budget reads, so a
# silent revert reads to the orchestrator as a worker accomplishing nothing.
#
# One tick, one commit. Cheap, ugly in the log, and impossible to lose.
# Run from the develop root: this script is called from inside feature
# worktrees, where `plans/` is sparse-excluded and the commit would land on the
# feature branch — or, more likely, match nothing and quietly do nothing.
if ! ( cd "$ROOT" && "$SELF_DIR/wf-commit.sh" "progress($plan_id): step $step $status" \
        --add "plans/${plan_id}-${slug}/progress.md" ); then
  echo "wf-progress-tick: the tick is written but could not be committed" >&2
fi

count=$("$SELF_DIR/wf-progress-count.sh" "$plan_id")
echo "Progress: $plan_id step $step $status — checklist now $count"
