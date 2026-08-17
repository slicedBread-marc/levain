#!/usr/bin/env bash
# wf-rehydrate.sh [--hook session-start|post-compact] [--source <src>]
#
# Re-reads pipeline state from disk and hands it back to the model after the
# conversation it was holding has been thrown away.
#
# WHY THIS EXISTS
#
# Every wf-* skill keeps its state on disk — plans/REGISTRY.md, the plan's
# progress.md, gate files under .claude/orchestrator/. That is what makes the
# harness survivable at all. But surviving is not the same as recovering: after
# a compaction the model is holding a PROSE SUMMARY of what it was doing, and a
# summary is exactly the wrong shape for state. It says "implementing PLN-041"
# with no step count, or worse, repeats a step count that was true four commits
# ago. The next thing the model does is act on it.
#
# Compaction cannot be prevented from inside a skill. A skill is instruction
# text injected into the running conversation; it is not a process, and the
# compaction window (`autoCompactWindow`) is resolved once at session start
# from --autocompact / settings / CLAUDE_CODE_AUTO_COMPACT_WINDOW. Nothing a
# skill or a subagent does can change it — the subagent spawn path copies the
# parent's window verbatim, and no agent frontmatter field overrides it.
#
# So the harness does not fight compaction. It re-establishes ground truth
# immediately afterwards, which is strictly better: the summary is allowed to be
# lossy about state, because state arrives again from the registry.
#
# ── Which hook actually carries context ──────────────────────────────────
#
# PostCompact is the obvious candidate and it is the WRONG ONE. Its handler
# collects each hook's stdout into a `userDisplayMessage` — a line printed to
# the human. It does not read `hookSpecificOutput.additionalContext`, and
# nothing it emits reaches the model.
#
# SessionStart does. It fires with `source: "compact"` as part of rebuilding the
# post-compaction context (alongside CLAUDE.md and the other attachments), and
# its `additionalContext` becomes a `hook_additional_context` attachment in the
# conversation. That is the load-bearing wiring.
#
#   --hook session-start   emit JSON additionalContext  → the model reads it
#   --hook post-compact    emit one plain line          → the human sees it
#
# Both are installed. PostCompact is the receipt, not the mechanism; if you ever
# find yourself moving the state block into it, this comment is why it will
# appear to work in testing (you can see the text) and silently do nothing.
#
# With no --hook, prints the same block as plain text — for a skill that wants
# to re-ground itself mid-run, and for debugging what the hooks will say.
#
# Emits NOTHING when there is no live pipeline state (empty registry, all plans
# terminal, no .plan-ref). A repo between plans should not pay tokens per
# compaction for a block that says "nothing in flight".
#
# Exit 0 always. A hook that fails is a hook that interrupts the user's session
# over bookkeeping; there is no state here worth that.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-states.sh
source "$SELF_DIR/wf-states.sh"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

MODE=""
SOURCE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --hook)   MODE="${2:-}"; shift 2 ;;
    --source) SOURCE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,4p' "$0" >&2; exit 0 ;;
    *) echo "wf-rehydrate.sh: unknown argument '$1'" >&2; exit 0 ;;
  esac
done

# ── Where we are ──────────────────────────────────────────────────────────
# The registry lives on develop. A worker compacting inside a feature worktree
# must still read the real one, not that worktree's sparse-excluded shadow.
#
# Both paths are resolved with `pwd -P`. Without it the CWD/ROOT comparison is
# wrong wherever a symlink sits above the repo — /var vs /private/var on macOS
# is the everyday case — and the whole "is this .plan-ref mine?" guard below
# silently inverts, because every directory looks like a worktree.
CWD=$(pwd -P)
ROOT=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || true
[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || true
[ -n "$ROOT" ] || ROOT="$CWD"
ROOT=$(cd "$ROOT" 2>/dev/null && pwd -P) || ROOT="$CWD"
REGISTRY="$ROOT/plans/REGISTRY.md"
ORCH="$ROOT/.claude/orchestrator"
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || BRANCH=""

# ── stdin: the hook payload ───────────────────────────────────────────────
# Read it whether or not we need it — a hook that leaves stdin unread can hand
# the harness a broken pipe on a large payload. No jq: clients are not required
# to have it, and every other script here is pure bash.
#
# `[ -t 0 ]` is not politeness. A hook always gets a payload on stdin, but this
# script is also run by hand with --hook to see what the hook will say, and a
# bare `cat` on a terminal waits for EOF forever — a wedged shell, and a wedged
# test suite, for a value we only want for its `source` field.
if [ -n "$MODE" ] && [ ! -t 0 ]; then
  HOOK_JSON=$(cat 2>/dev/null || true)
  if [ -z "$SOURCE" ]; then
    SOURCE=$(printf '%s' "$HOOK_JSON" \
      | grep -oE '"(source|trigger)"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed 's/.*"\([^"]*\)"$/\1/') || true
  fi
fi
[ -n "$SOURCE" ] || SOURCE="manual"

# ── Helpers ───────────────────────────────────────────────────────────────

# A registry row, by ID. Columns: ID Slug State Priority Branch Updated WF Tags Deps
registry_row() {
  [ -f "$REGISTRY" ] || return 1
  grep -m1 "^|[[:space:]]*$1[[:space:]]*|" "$REGISTRY" 2>/dev/null
}

field() { printf '%s' "$1" | cut -d'|' -f"$2" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# ── The state block ───────────────────────────────────────────────────────

emit_plan_detail() {
  local id="$1" row slug state priority branch wf tags deps
  local plan_dir plan_md progress goal

  row=$(registry_row "$id") || return 1
  slug=$(field "$row" 3);  state=$(field "$row" 4); priority=$(field "$row" 5)
  branch=$(field "$row" 6); wf=$(field "$row" 8)
  tags=$(field "$row" 9);  deps=$(field "$row" 10)

  plan_dir="$ROOT/plans/${id}-${slug}"
  plan_md="$plan_dir/plan.md"
  progress="$plan_dir/progress.md"

  echo "PLAN:     ${id}-${slug}"
  echo "STATE:    $state        (this is the value in REGISTRY.md right now)"
  [ -n "$priority" ] && echo "PRIORITY: $priority"
  [ -n "$branch" ]   && [ "$branch" != "—" ] && echo "BRANCH:   $branch"
  [ -n "$wf" ]       && [ "$wf" != "—" ] && echo "WF:       $wf"
  [ -n "$tags" ]     && [ "$tags" != "—" ] && echo "TAGS:     $tags"
  [ -n "$deps" ]     && [ "$deps" != "—" ] && echo "DEPS:     $deps"

  goal=$(wf_goal_text "$plan_md")
  [ -n "$goal" ] && echo "GOAL:     $goal"

  # ── Where this plan's commands actually run ──────────────────────────────
  #
  # The working directory does NOT survive a compaction. A skill that told the
  # session to cd into the feature worktree in its entry step, and then says
  # that directory "persists", is describing something the compaction throws
  # away with the rest of the conversation. client-a's WFI-098: after a
  # compaction mid-/wf-test, cwd had silently reverted to the develop root, a
  # relative read of a file that exists only on the feature branch returned
  # "No such file or directory", and a grep for the feature came back empty —
  # which is indistinguishable from the feature being broken. Findings were one
  # step from being written off a directory the session was no longer in.
  #
  # So the path is restated here, absolute, every time state is rehydrated.
  if [ -n "$branch" ] && [ "$branch" != "—" ]; then
    local wt
    wt=$(git -C "$ROOT" worktree list --porcelain 2>/dev/null | awk -v b="refs/heads/$branch" '
      /^worktree /  { p = substr($0, 10) }
      /^branch /    { if ($2 == b) { print p; exit } }
    ') || true
    if [ -n "$wt" ]; then
      echo "WORKTREE: $wt"
      echo "          This plan'\''s code lives THERE, not in $ROOT. Your working"
      echo "          directory did not survive the compaction — re-anchor before"
      echo "          reading or running anything, and prefer absolute paths or"
      echo "          git -C over a bare relative path."
    fi
  fi

  # The live Steps checklist — the v6 forward-progress signal, and the single
  # thing a prose summary is most reliably wrong about. Verbatim, not counted:
  # which step is next matters more than how many are left.
  if [ -f "$progress" ]; then
    local steps
    steps=$(awk '
      /^## Steps([ \t]|$)/ { s = 1; next }
      s && /^## /  { exit }
      s && /^- \[/ { print "  " $0 }
    ' "$progress" 2>/dev/null)
    if [ -n "$steps" ]; then
      echo ""
      echo "STEPS (from progress.md — authoritative):"
      printf '%s\n' "$steps"
    fi
  fi

  # An amendment added after the plan was written is a design change the summary
  # has no reason to have kept. Narrowing a goal post-compaction is the failure
  # this line exists to prevent.
  if [ -f "$plan_md" ]; then
    local amend
    amend=$(awk '
      /^## Amendments([ \t]|$)/ { a = 1; next }
      a && /^## / { exit }
      a && /^\[/  { last = $0; n++ }
      END { if (n) printf "%d amendment(s), latest: %s", n, last }
    ' "$plan_md" 2>/dev/null)
    [ -n "$amend" ] && { echo ""; echo "AMENDMENTS: $amend"; }
  fi

  # An open gate means a human owes an answer. Acting past one is the whole
  # reason gates exist.
  local num gate_file
  # Resolved by number, like the claim below it — a gate opened on the plan is
  # this artifact's gate whichever of its names is in hand (WFI-187).
  gate_file=$(wf_gate_file "$id" || true)
  if [ -f "$gate_file" ]; then
    local gname
    gname=$(grep -m1 "^GATE_NAME=" "$gate_file" 2>/dev/null | sed "s/^GATE_NAME='//; s/'$//") || true
    echo ""
    echo "GATE OPEN: ${gname:-unknown} — a human owes an answer. Do not act past it."
  fi
  # Claims are keyed by artifact NUMBER, unpadded — see wf_claim_dir. 10# strips
  # the padding so PLN-002 and PLN-2 name one claim rather than two.
  num=$(printf '%s' "$id" | grep -oE '[0-9]+$') || true
  if [ -n "$num" ] && [ -f "$ORCH/claims/$((10#$num))/.wf-claim" ]; then
    echo "CLAIMED:  a worker holds a claim on this artifact."
  fi
  return 0
}

emit_pipeline() {
  local found=0 line id slug state priority plan_dir total done_count prog goal
  while IFS= read -r line; do
    id=$(field "$line" 2); slug=$(field "$line" 3)
    state=$(field "$line" 4); priority=$(field "$line" 5)
    [ -n "$id" ] || continue
    wf_state_is_valid "$state" || continue
    wf_state_is_terminal "$state" && continue

    plan_dir="$ROOT/plans/${id}-${slug}"
    prog=""
    if [ -f "$plan_dir/progress.md" ]; then
      # One definition of the count, shared with the board and the
      # orchestrator's progress check — the `## Steps` list only (wf_step_counts).
      counts=$(wf_step_counts "$plan_dir/progress.md")
      [ "${counts#*/}" != "0" ] && prog="step $counts"
    fi
    goal=$(wf_goal_text "$plan_dir/plan.md")
    # The registry writes an em dash for "unset". It is three bytes wide and one
    # column wide, so printf's %-Ns padding is off by two wherever it appears.
    [ "$priority" = "—" ] && priority=""

    if [ "$found" -eq 0 ]; then
      echo "PIPELINE (non-terminal plans, from plans/REGISTRY.md):"
      found=1
    fi
    printf '  %-10s %-9s %-3s %-11s %s\n' \
      "$id" "$state" "${priority:-}" "$prog" "${goal:0:70}"
  done < <(grep "^|" "$REGISTRY" 2>/dev/null | tail -n +3)
  return $((1 - found))
}

# Is this .plan-ref describing THIS session's work, or is it litter?
#
# .plan-ref belongs to a feature worktree. It is not cleaned up when a branch
# merges, so develop roots accumulate one naming the last plan built there —
# three of five clients had one at the time this guard was written, all pointing
# at `complete` plans. Trusting it blindly is worse than having no rehydration
# at all: it hands a session a finished plan as its current work, with a STATE
# line and a step checklist, in a block that says "these values win".
#
# Trusted only when both hold:
#   - the plan is not in a terminal state, and
#   - we are in a linked worktree, OR HEAD is the branch the registry names.
ref_is_live() {
  local id="$1" row state branch_col
  row=$(registry_row "$id") || return 1
  state=$(field "$row" 4)
  wf_state_is_terminal "$state" && return 1
  [ "$CWD" != "$ROOT" ] && return 0
  branch_col=$(field "$row" 6)
  [ -n "$BRANCH" ] && [ "$BRANCH" = "$branch_col" ]
}

build_state() {
  local plan_id="" stale_ref="" had=0

  # A feature worktree names its plan in .plan-ref — one line, the plan ID.
  if [ -f "$CWD/.plan-ref" ]; then
    plan_id=$(head -1 "$CWD/.plan-ref" 2>/dev/null | tr -d '[:space:]') || true
  fi

  # An id that IS in the registry but is not this session's work: drop it and
  # show the pipeline instead. An id the registry does not know at all is a
  # different problem, and emit_plan_detail reports it.
  if [ -n "$plan_id" ] && registry_row "$plan_id" >/dev/null 2>&1 \
     && ! ref_is_live "$plan_id"; then
    stale_ref="$plan_id"
    plan_id=""
  fi

  local stamp; stamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [ -n "$MODE" ]; then
    echo "WORKFLOW STATE — read from disk at ${stamp} after ${SOURCE}."
  else
    echo "WORKFLOW STATE — read from disk at ${stamp}."
  fi
  echo ""
  echo "The conversation above is a summary and is NOT authoritative for pipeline"
  echo "state. Everything below was read from plans/REGISTRY.md and the plan folder"
  echo "at ${stamp}. Where the summary disagrees, these values win."
  echo ""
  # ── Why the precedence is scoped, and why the timestamp is on every line ──
  #
  # This block wins over PROSE. It does not win over a script. A block from an
  # earlier compaction survives into the next summary word for word, carrying a
  # STATE line that was true an hour ago under a sentence saying it wins.
  # client-a's WFI-099: a block reading `PLN-007 draft` sat above a
  # wf-list-gates.sh run that correctly said `testing`, the attendant believed
  # the block, classified an ok-fit gate as stale-by-state, and closed it —
  # which then let the daemon dispatch onto a plan under manual test (WFI-100,
  # WFI-102). The timestamp is what makes the two distinguishable at all.
  echo "This is a SNAPSHOT, not a subscription. It does not outrank anything you"
  echo "ran after ${stamp}, and an older WORKFLOW STATE block above is superseded"
  echo "by this one. Before acting on a state that is more than a few minutes old,"
  echo "re-read it: scripts/wf-exec.sh wf-rehydrate.sh"
  echo ""
  [ -n "$BRANCH" ] && echo "BRANCH:   $BRANCH"
  [ "$CWD" != "$ROOT" ] && echo "CWD:      $CWD"
  [ "$CWD" != "$ROOT" ] && echo "          (feature worktree — registry read from the main worktree)"

  if [ -n "$plan_id" ]; then
    echo ""
    if emit_plan_detail "$plan_id"; then
      had=1
    else
      echo "PLAN:     $plan_id — named by .plan-ref but ABSENT from REGISTRY.md."
      echo "          Do not proceed on it; reconcile first (wf-registry-audit.sh)."
      had=1
    fi
  else
    echo ""
    if emit_pipeline; then had=1; fi
    if [ -n "$stale_ref" ]; then
      echo ""
      echo "NOTE:     .plan-ref here names $stale_ref, which is not this session's"
      echo "          work. Ignored — it is left over from a merged branch."
    fi
  fi

  [ "$had" -eq 1 ] || return 1

  echo ""
  echo "Before acting: re-run the entry grep your skill specifies. Never write"
  echo "REGISTRY.md by hand — transitions go through scripts/wf-exec.sh."
  return 0
}

# ── JSON string escaping (no jq) ──────────────────────────────────────────
# Order matters: backslashes first, or the escapes we add get escaped again.
json_escape() {
  sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' -e $'s/\t/\\\\t/g' \
    | awk 'BEGIN { ORS = "" } { if (NR > 1) printf "\\n"; print }'
}

# ── Output ────────────────────────────────────────────────────────────────

STATE=$(build_state) || STATE=""

case "$MODE" in
  session-start)
    # Nothing in flight — say nothing. Silence costs no tokens.
    [ -n "$STATE" ] || exit 0
    printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}\n' \
      "$(printf '%s' "$STATE" | json_escape)"
    ;;
  post-compact)
    # Stdout here is shown to the HUMAN, not the model. One line, so the
    # transcript records that rehydration happened and what it found.
    if [ -z "$STATE" ]; then
      echo "workflow state: nothing in flight"
    else
      summary=$(printf '%s' "$STATE" | grep -m1 -E '^(PLAN|PIPELINE)' || true)
      count=$(printf '%s' "$STATE" | grep -cE '^  (PLN|BUG|BRF)-' || true)
      if printf '%s' "$summary" | grep -q '^PLAN'; then
        echo "workflow state re-read from REGISTRY.md — ${summary#PLAN:}" | tr -s ' '
      else
        echo "workflow state re-read from REGISTRY.md — ${count} plan(s) in flight"
      fi
    fi
    ;;
  "")
    [ -n "$STATE" ] || { echo "Nothing in flight." >&2; exit 0; }
    printf '%s\n' "$STATE"
    ;;
  *)
    echo "wf-rehydrate.sh: unknown --hook '$MODE' (want session-start or post-compact)" >&2
    ;;
esac

exit 0
