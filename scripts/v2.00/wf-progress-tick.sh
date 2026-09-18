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
# A step label is whatever the checklist writes after `Step`: a number (3), a
# sub-lettered step (1a, 1a-i, 12b-iv), or an amendment's step, which /wf-spec
# writes prefixed by the amendment and dotted — `Step A1.1` … `Step A1.8`.
# It must contain a digit and may not end on a separator; everything else is
# the plan's own convention, and this script's job is to tick the row the plan
# actually wrote, not to impose a numbering scheme on it.
#
# The old grammar demanded a leading digit and no dots, so every amendment step
# was a usage error and client-a's PLN-281 ticked eight rows of progress.md
# by hand — on the one file whose checklist the orchestrator reads as forward
# progress, and whose per-tick commit is what makes it survive a stash
# (WFI-263).
if [ -z "$plan_id" ] || ! printf '%s' "$step" | grep -qE '^[A-Za-z]*[0-9][0-9A-Za-z]*([.-][0-9A-Za-z]+)*$'; then
  echo "Usage: $0 <plan-id-or-name> <step-label> [description] [--blocked]" >&2
  echo "  <step-label> is the whole label the checklist writes after 'Step':" >&2
  echo "  3, a sub-lettered step such as 1a or 1a-iii, or an amendment's A1.1" >&2
  exit 1
fi

ROOT="$(wf_develop_root)"
REGISTRY="$ROOT/plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
[ -n "$slug" ] || { echo "Error: $plan_id not found in registry" >&2; exit 1; }
progress="$ROOT/plans/${plan_id}-${slug}/progress.md"
[ -f "$progress" ] || { echo "Error: $progress not found" >&2; exit 1; }

wf_lock_acquire "plan-$plan_id"

today=$(date +%Y-%m-%d)

# ── The section has to exist before a row can be appended to it ───────────
#
# Every fallback below — the whole-label match, the append-if-missing that
# WFI-111 added — runs inside `## Steps`, and all of them are reached by an awk
# rule that sets `in_steps` on seeing that heading. A progress.md with no such
# heading therefore never enters any of them, including the one whose whole
# purpose is to handle a row that is not there.
#
# client-a's PLN-249 (WFI-217) was written with only a `## Log` section.
# `wf-progress-tick.sh PLN-249 1` appended its log line as designed, reported
# "checklist now 0/0", and the tick landed nowhere at all — on the one signal
# the orchestrator reads to tell a resume from a stall, so a plan being built
# normally looked like a worker accomplishing nothing.
#
# /wf-spec writes this section (plans/TEMPLATE.md), so its absence is a defect
# upstream of here. That is not a reason to drop the tick: the section is
# cheap to create, the alternative is silence, and the note on stderr is what
# makes the upstream defect visible instead of absorbed.
if ! grep -q '^## Steps' "$progress"; then
  echo "wf-progress-tick: $progress has no '## Steps' section — creating one." >&2
  echo "  Its checklist is the forward-progress signal the orchestrator reads; without it" >&2
  echo "  every tick lands nowhere and the plan reads as stalled (WFI-217). /wf-spec writes" >&2
  echo "  this section from plans/TEMPLATE.md, so a plan missing it was specced incompletely." >&2
  # Before `## Log` when there is one — the checklist is the state and the log
  # is the history, and TEMPLATE.md orders them that way.
  awk '
    !done && /^## Log/ { print "## Steps"; print ""; done = 1 }
    { print }
    END { if (!done) { print ""; print "## Steps"; print "" } }
  ' "$progress" > "$progress.tmp" && mv "$progress.tmp" "$progress"
fi

# ── Which row does this label mean? ───────────────────────────────────────
#
# The label is matched WHOLE. It used to be reduced to its leading digits —
# strip everything before the first digit, then everything from the first
# non-digit on — so a checklist written as `Step 1a-i` … `Step 1a-v`, `Step 1b`
# collapsed to six rows all keyed `1`, and one `wf-progress-tick.sh PLN-016 1`
# ticked every one of them. Among them was a soak window explicitly not the
# builder's to satisfy, ticked weeks before it could close (client-a
# WFI-115). A tick is a claim about one step and may only touch the row it
# names.
#
# A label that matches no row is normally an amendment's new step and gets
# appended (WFI-111, below). But when rows exist that this label is a PREFIX of
# — `1` against `1a-i` — that is a caller naming a family instead of a step.
# Appending `- [x] Step 1` next to `Step 1a-i` would answer a caller bug by
# corrupting the one checklist the orchestrator reads for forward progress, so
# this exits instead, naming the rows it could have meant.
step_label_scan=$(awk -v want="$step" '
  # The label is everything after `Step `, up to the first character that
  # cannot be part of one. Taken from the first DIGIT instead, an amendment
  # row — `Step A1.1` — lost its `A` and then stopped at the dot, so all eight
  # of PLN-281`s A1.x rows read as the label `1` (WFI-263).
  # Anchored on the checkbox, and LEFTMOST: a description is free to contain
  # the word "step" itself ("Step A1.1: amendment A-1 step one"), and reading
  # from the last one would take the label from the prose.
  function steplabel(line,   n) {
    if (!match(line, /\][[:space:]]*[Ss]tep[[:space:]]+/)) return ""
    n = substr(line, RSTART + RLENGTH)
    sub(/[^0-9A-Za-z.-].*$/, "", n)   # digits, letters, dots and hyphens
    sub(/[.-]+$/, "", n)              # a trailing separator is punctuation
    if (n !~ /[0-9]/) return ""       # a label without a digit is prose
    return n
  }
  /^## Steps/ { in_steps = 1; next }
  /^## /      { in_steps = 0 }
  !in_steps   { next }
  /^[[:space:]]*-[[:space:]]*\[[[:space:]xX]*\][[:space:]]*[Ss]tep[[:space:]]+[0-9A-Za-z]/ {
    n = steplabel($0); if (n == "") next
    ln = tolower(n); lw = tolower(want)
    if (ln == lw) { exact = 1; next }
    # A prefix only counts as the same family when what follows is not another
    # digit — otherwise `1` would claim `12`.
    if (substr(ln, 1, length(lw)) == lw && substr(ln, length(lw) + 1) !~ /^[0-9]/) {
      family = family " " n
    }
  }
  END { print (exact ? "exact" : "none"); print family }
' "$progress")

if [ "$(printf '%s\n' "$step_label_scan" | head -1)" != "exact" ]; then
  family=$(printf '%s\n' "$step_label_scan" | sed -n '2p' | xargs || true)
  if [ -n "$family" ]; then
    wf_lock_release "plan-$plan_id" 2>/dev/null || true
    echo "Error: $plan_id has no 'Step $step' row — its checklist sub-letters that step as: $family" >&2
    echo "       Name one of those exactly (e.g. $0 $plan_id ${family%% *} \"...\"); each is ticked on its own." >&2
    exit 1
  fi
fi

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
    in_steps && /^[[:space:]]*-[[:space:]]*\[[[:space:]xX]*\][[:space:]]*[Ss]tep[[:space:]]+[0-9A-Za-z]/ {
      line = $0
      # Whole-label match — see the WFI-115 note above. `1` ticks `Step 1`,
      # never `Step 1a-i` and never `Step 12`. Read from after `Step`, not from
      # the first digit, so an amendment row keeps its prefix and its dots
      # (`A1.1`, WFI-263).
      # Leftmost, anchored on the checkbox — a description may say "step" too.
      n = ""
      if (match(line, /\][[:space:]]*[Ss]tep[[:space:]]+/)) {
        n = substr(line, RSTART + RLENGTH)
        sub(/[^0-9A-Za-z.-].*$/, "", n)
        sub(/[.-]+$/, "", n)
      }
      if (n ~ /[0-9]/ && tolower(n) == tolower(want)) {
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
