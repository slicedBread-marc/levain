#!/usr/bin/env bash
# wf-spawn.sh <role> <artifact> [options]
#
# Launches ONE unattended worker: a headless `claude -p` session running a
# workflow skill against a single artifact, with WF_UNATTENDED=1 set so the
# skill takes its [AUTO] defaults and opens gates instead of asking questions.
#
# This is the single spawn path. The post-commit verify hook and the
# orchestrator daemon both call it, which is what stops them double-launching
# the same plan — the pidfile guard lives here, not in each caller.
#
#   role      spec | implement | verify | test | consistency
#   artifact  PLN-NNN[-slug], or BUG-NNN / BRF-NNN for the spec role
#
# Options:
#   --foreground   run inline and block (drive-one mode); default is nohup+disown
#   --dry-run      print what would be launched, change nothing
#   --model NAME   override the configured model tier for this role
#
# Model tiers come from claude-workflow.yml → orchestrator.models.<role>,
# defaulting to the pipeline's standing assignment: spec=opus (judgment),
# implement=sonnet, verify=sonnet, test=haiku (guided).
#
# Exit codes:
#   0   spawned (background) or worker succeeded (foreground)
#   1   bad usage / worker failed
#   2   already running for this artifact+role — not an error, nothing to do

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

role="${1:-}"
artifact="${2:-}"
shift 2 2>/dev/null || true

foreground=false
dry_run=false
model_override=""

while [ $# -gt 0 ]; do
  case "$1" in
    --foreground) foreground=true; shift ;;
    --dry-run)    dry_run=true; shift ;;
    --model)      model_override="${2:?--model requires a name}"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

case "$role" in
  spec|implement|verify|test|consistency) ;;
  *) echo "Usage: $0 <spec|implement|verify|test|consistency> <artifact> [--foreground] [--dry-run] [--model NAME]" >&2; exit 1 ;;
esac

id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
[ -n "$id" ] || { echo "Error: '$artifact' is not a PLN/BUG/BRF id" >&2; exit 1; }

# The artifact NUMBER, which is what identity actually turns on: the counter is
# global and a bug keeps its number when it becomes a plan (BUG-022 → PLN-022).
num="${id#*-}"

ROOT="$(wf_develop_root)"
ORCH="$(wf_orch_dir)"

# ── Scrub git's hook environment ──────────────────────────────────────────
#
# The post-commit hook is one of the two callers, and git exports its own
# plumbing into every hook: GIT_INDEX_FILE, GIT_DIR, GIT_PREFIX, GIT_AUTHOR_*,
# GIT_EDITOR. A worker launched from there inherits all of it and carries it
# into a DIFFERENT worktree, where `GIT_INDEX_FILE=.git/index` resolves against
# a `.git` that is a file, not a directory — so every git command it runs dies
# with "index file open failed: Not a directory" (client-a WFI-071, which
# cost a verify run until someone thought to check the environment).
#
# These variables are meaningful only inside the hook that set them. Nothing
# downstream of a spawn wants any of them.
unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE GIT_PREFIX GIT_EDITOR \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
      GIT_QUARANTINE_PATH GIT_REFLOG_ACTION GIT_EXEC_PATH \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE \
      GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE 2>/dev/null || true

# ── Scrub inherited lock ownership ────────────────────────────────────────
#
# wf-lock.sh marks a held lock by exporting WF_LOCK_HELD_<NAME>=1, and reads it
# back to stay re-entrant: a child that acquires a lock its parent already holds
# is a no-op rather than a deadlock. That is right for a child doing the
# parent's work, and exactly wrong for a worker that outlives it.
#
# The post-commit hook fires from INSIDE wf-commit.sh, which holds `registry`
# and `commit` for the length of the commit. A worker launched down that path
# inherits both marks and never releases them, because it never took them —
# so every registry write it makes for the rest of its run silently skips the
# lock that exists to serialize it against the other live workers.
#
# A spawned worker owns nothing it did not acquire itself.
while IFS='=' read -r var _; do
  case "$var" in WF_LOCK_HELD_*) unset "$var" 2>/dev/null || true ;; esac
done < <(env)

# ── Default model per role ────────────────────────────────────────────────
default_model() {
  case "$1" in
    spec)        echo "opus" ;;
    implement)   echo "sonnet" ;;
    verify)      echo "sonnet" ;;
    test)        echo "haiku" ;;
    consistency) echo "sonnet" ;;
  esac
}
model="${model_override:-$(wf_cfg "orchestrator.models.$role" "$(default_model "$role")")}"

# ── Already-running guard ─────────────────────────────────────────────────
#
# Keyed on the NUMBER, not the artifact name. It used to be
# "${artifact}-${role}.pid", which reads as one guard per worker and is really
# one guard per NAME — and the same work has two names on its way through spec.
# client-a's WFI-067: `BUG-022-csp-blocks-inline-styles` (still listed by
# wf-list-specable.sh, because the open→triaged move had not committed) and
# `PLN-022-csp-style-src` (in draft) were both offered, took different pidfiles,
# and two wf-spec workers reviewed and approved the same plan at once. One wrote
# its verdict on top of the other's, leaving plan.md with two contradicting
# `## Review` blocks.
pidfile="$ORCH/logs/${num}-${role}.pid"
# Adopt a pre-v5.1 pidfile so an upgrade mid-flight does not double-launch.
legacy_pidfile="$ORCH/logs/${artifact}-${role}.pid"
[ -f "$legacy_pidfile" ] && [ ! -f "$pidfile" ] && mv "$legacy_pidfile" "$pidfile" 2>/dev/null || true
if [ -f "$pidfile" ]; then
  old_pid=$(cat "$pidfile" 2>/dev/null || echo "")
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "wf-spawn: $role already running for $id (PID $old_pid)" >&2
    exit 2
  fi
  # `--dry-run` says it changes nothing, and reaping a dead worker's pidfile is
  # a change. Everything below is guarded the same way, so the dispatcher's own
  # preview can delegate here and get the real answer without side effects
  # (WFI-160).
  $dry_run || rm -f "$pidfile"
fi

# ── Claim before the worker starts, not after ─────────────────────────────
#
# A skill that claims partway through its own run leaves a window between "the
# dispatcher decided this artifact was free" and "the worker said so", and both
# WFI-067 workers started inside that window. The claim belongs to whoever hands
# out the work. Attended sessions claim through wf-claim.sh the same way, so an
# attended /wf-test and the daemon now contend for one file instead of racing.
#
# The claim keys on the artifact NUMBER rather than the plan folder, so a spec
# worker dispatched onto a BRF/BUG — which has no plan folder until it writes
# one — is claimed from spawn like every other role (client-c WFI-004).
claim_dir=$(wf_claim_dir "$artifact")
if wf_claim_held "$artifact"; then
  holder=$(sed -n '2p' "$WF_CLAIM_HELD_DIR/.wf-claim" 2>/dev/null || true)

  # ── Our own claim: queue, do not decline ────────────────────────────────
  #
  # The post-commit verify hook fires from inside the implementer's own
  # wf-commit.sh, and the implementer's exit order is fixed by contract:
  # commit the transition, THEN close the gate, THEN unclaim (docs/guard-
  # ordering.md, WFI-079). So at the instant the hook runs, the claim is always
  # still held — by us. The guard below then read that as "somebody else is
  # working this" and declined, every single time, for the exact sequence the
  # skill mandates. The hook's inline spawn was structurally dead: client-a
  # filed it twice, on two different plans, with the same PID-is-me message
  # (WFI-086, WFI-091).
  #
  # Spawning anyway is worse than declining: the successor's claim would be
  # written now and deleted seconds later by the implementer's own unclaim,
  # leaving a live worker on an unclaimed plan for the daemon to double-book.
  #
  # So the trigger moves to where it belongs — the release. Queue the intent
  # here; wf-unclaim.sh flushes the queue the moment the claim comes down, by
  # which point every guard can answer honestly.
  if wf_claim_mine "$WF_CLAIM_HELD_DIR"; then
    if ! $dry_run; then
      mkdir -p "$ORCH/pending"
      printf '%s\t%s\t%s\n' "$role" "$artifact" "$model_override" \
        > "$ORCH/pending/${num}-${role}.spawn"
      wf_event queue "$id" "$role deferred until the claim is released"
    fi
    echo "wf-spawn: $artifact still holds this session's own claim — $role queued until it is released" >&2
    exit 2
  fi

  echo "wf-spawn: $artifact is claimed by a live session (PID ${holder:-?}) — not spawning $role" >&2
  exit 2
fi

# A queued spawn for this exact role is being served right now; drop the marker
# so the release path does not launch a second one.
$dry_run || rm -f "$ORCH/pending/${num}-${role}.spawn" 2>/dev/null || true

# ── Re-read the state, here, at the last possible moment ──────────────────
#
# The dispatcher decided this artifact was eligible from a candidate list built
# earlier in the sweep, and eligibility is a claim about the registry AT THAT
# INSTANT. Between the two, a session that is exiting can move the plan: it
# drops the gate, drops the claim, and only then commits the transition. Read
# in that window the plan is ungated, unclaimed, and still carrying its old
# state — every guard above says go, and the state they are guarding is stale.
#
# client-a ran exactly that (WFI-079): a gate closed at 15:32:33Z, a sweep
# spawned a tester at 15:32:35Z, `testing → draft` committed at 15:32:38Z. The
# tester re-ran the whole e2e scope and opened a fresh `manual-test` gate on a
# plan that had been in draft with five unaddressed findings for four minutes —
# and that false gate then blocked the plan from reaching a planner at all.
#
# Skills fix their half by committing the transition before releasing either
# guard. This is the other half: read the row one more time with the launch
# decision already made, and refuse a role the state no longer supports. It
# narrows the window from "one sweep interval" to "the microseconds between
# this grep and exec", which is as close to closed as a check-then-act gets.
#
# Exit 2, not 1: nothing is wrong. The work moved on, and both callers already
# read 2 as "not mine to do" (the dispatcher skips, drive-one re-reads and
# routes to the role the new state actually calls for).
#
# ONLY FOR A PLN. The lookup used to be `grep "^| PLN-$num |"` for any artifact
# — it took the numeric part of whatever it was given and read it as a plan.
#
# That is not what a number means here. A number identifies one artifact across
# the types it passes through (BUG-096 → PLN-096), but wf-plan-id.sh reallocates
# when the inherited number is already taken (WFI-011), so `PLN-081` and
# `BRF-081` are routinely two unrelated things.
#
# client-a's WFI-160: BRF-081, a brand-new brief with no registry row at all,
# was looked up as PLN-081 — an unrelated plan completed the day before. The
# guard read `complete`, refused the spawn, and logged `spec: state moved to
# 'complete' before launch`, a transition that never happened. The brief was
# permanently undispatchable: every sweep re-ran the same lookup and got the
# same answer. BUG-098 and BUG-099 dispatched on that same sweep only because
# PLN-098 and PLN-099 happened to be sitting at `draft`.
#
# So the guard now asks about the artifact it was actually given. For a bug or
# a brief there is no plan row to be stale, and the comment below has always
# said abstaining is the right answer — it just never got the chance.
registry="$ROOT/plans/REGISTRY.md"
cur_state=""
if [ -f "$registry" ] && [ "${id%%-*}" = "PLN" ]; then
  cur_state=$(grep "^| PLN-$num |" "$registry" 2>/dev/null | head -1 | awk -F'|' '{print $4}' | xargs || true)
fi

# An empty state means there is no plan row yet — a bug or brief on its way to
# a first spec. That is legitimate work for every caller, so the guard abstains
# rather than inventing a rule for a row it cannot see.
if [ -n "$cur_state" ]; then
  case "$role" in
    spec)        allowed="draft" ;;
    implement)   allowed="ready active" ;;
    verify)      allowed="verify" ;;
    test)        allowed="testing" ;;
    consistency) allowed="ready" ;;
  esac
  if ! printf '%s\n' $allowed | grep -qx "$cur_state"; then
    echo "wf-spawn: PLN-$num is '$cur_state' — $role does not act on that state; not spawning" >&2
    wf_event skip "$id" "$role: state moved to '$cur_state' before launch"
    exit 2
  fi
fi

# ── Worker prompt ─────────────────────────────────────────────────────────
# Skills live at .claude/skills/wf-<role>/SKILL.md on a client checkout.
read -r -d '' prompt <<PROMPT || true
You are running UNATTENDED as part of the workflow orchestrator. WF_UNATTENDED=1 is set in your environment. There is no human reading your output — a question you ask will hang the pipeline.

Read .claude/skills/wf-${role}/SKILL.md in full, INCLUDING its "Unattended mode" section, then execute it for ${id} (full artifact name: ${artifact}).

Follow the Unattended mode rules exactly:
- Skip any work-selection menu; ${id} is your assigned artifact.
- Resolve [AUTO] prompts to their documented defaults.
- For anything marked [GATE], or anything you would otherwise ask a human, run scripts/wf-exec.sh wf-gate-open.sh with a clear question and then exit cleanly. Never guess.
PROMPT

if $dry_run; then
  echo "DRY-RUN spawn: role=$role artifact=$artifact model=$model foreground=$foreground"
  exit 0
fi

ts=$(date +%Y%m%d-%H%M%S)
log="$ORCH/logs/${artifact}-${role}-${ts}.log"

# ── Foreground: block, stream, propagate the worker's status ──────────────
if $foreground; then
  wf_event spawn "$id" "$role ($model) foreground"
  echo $$ > "$pidfile"
  wf_claim_write "$claim_dir" $$
  set +e
  # WF_CLAIM_PID names the claim we just took out FOR this worker, so its own
  # "is this plan free?" check recognises the claim as its own (WFI-073/075).
  ( cd "$ROOT" && WF_UNATTENDED=1 WF_ROLE="$role" WF_ARTIFACT="$artifact" WF_CLAIM_PID=$$ \
      claude -p --model "$model" --dangerously-skip-permissions "$prompt" ) 2>&1 | tee "$log"
  rc=${PIPESTATUS[0]}
  set -e
  rm -f "$pidfile"
  # Release what we claimed, however the worker ended. A claim outliving its
  # worker parks the artifact until the TTL expires or someone notices.
  rm -f "$claim_dir/.wf-claim"
  wf_event exit "$id" "$role rc=$rc"
  exit "$rc"
fi

# ── Background: detach, record the PID, clean up the pidfile on exit ──────
# The prompt goes through the environment rather than the command string —
# it is multi-line and would need three levels of quoting otherwise.
export WF_PROMPT="$prompt"
export WF_UNATTENDED=1 WF_ROLE="$role" WF_ARTIFACT="$artifact"
event_sh="$(cd "$(dirname "$0")" && pwd)/wf-event.sh"

claimfile="$claim_dir/.wf-claim"

# $$ inside the bash -c is the PID this shell records as $! below, which is the
# same PID wf_claim_write stamps on the claim — so the worker can name its own
# claim rather than standing down against it (WFI-073/075).
nohup bash -c "
    cd '$ROOT'
    export WF_CLAIM_PID=\$\$
    claude -p --model '$model' --dangerously-skip-permissions \"\$WF_PROMPT\"
    rc=\$?
    rm -f '$pidfile'
    [ -n '$claimfile' ] && rm -f '$claimfile'
    '$event_sh' exit '$id' \"$role rc=\$rc\"
" > "$log" 2>&1 &

worker_pid=$!
echo "$worker_pid" > "$pidfile"
# The claim names the worker, so it dies with the worker rather than with the
# shell that launched it.
wf_claim_write "$claim_dir" "$worker_pid"
disown "$worker_pid" 2>/dev/null || true

wf_event spawn "$id" "$role ($model) pid $worker_pid"
echo "wf-spawn: $role/$artifact on $model — PID $worker_pid, log $log"
