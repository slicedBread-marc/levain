#!/usr/bin/env bash
# lv-spawn.sh <role> <artifact> [options]
#
# Launches ONE unattended worker: a headless `claude -p` session running a
# workflow skill against a single artifact, with LV_UNATTENDED=1 set so the
# skill takes its [AUTO] defaults and opens gates instead of asking questions.
#
# This is the single spawn path. The post-commit verify hook and the
# orchestrator daemon both call it, which is what stops them double-launching
# the same plan — the pidfile guard lives here, not in each caller.
#
#   role      spec | implement | verify | test | consistency | release | deploy
#   artifact  PLN-NNN[-slug], or BUG-NNN / BRF-NNN for the spec role.
#             release/deploy take the fixed literal RELEASE / DEPLOY instead —
#             they promote a batch across plans, not one artifact.
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

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

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
  spec|implement|verify|test|consistency|release|deploy) ;;
  *) echo "Usage: $0 <spec|implement|verify|test|consistency|release|deploy> <artifact> [--foreground] [--dry-run] [--model NAME]" >&2; exit 1 ;;
esac

# release/deploy carry the fixed literal (RELEASE/DEPLOY) as their own id —
# they promote a batch across plans, not one artifact, so there is no
# PLN/BUG/BRF number to extract. Everything below this point (pidfile, claim,
# pending-spawn naming) already works unchanged once id/num are set this way:
# `${id#*-}` on a dash-less string returns the string itself, so num becomes
# RELEASE/DEPLOY too, which reads fine in a filename.
case "$role" in
  release) id="RELEASE" ;;
  deploy)  id="DEPLOY" ;;
  *)
    id=$(printf '%s' "$artifact" | grep -oE "^($LV_WORK_RE)-[0-9]+" || true)
    [ -n "$id" ] || { echo "Error: '$artifact' is not a $LV_PLN/$LV_BUG/$LV_BRF id" >&2; exit 1; }
    ;;
esac
if [ "$role" = "release" ] || [ "$role" = "deploy" ]; then
  [ "$artifact" = "$id" ] || { echo "Error: role '$role' takes artifact '$id', not '$artifact'" >&2; exit 1; }
fi

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
# lv-lock.sh marks a held lock by exporting LV_LOCK_HELD_<NAME>=1, and reads it
# back to stay re-entrant: a child that acquires a lock its parent already holds
# is a no-op rather than a deadlock. That is right for a child doing the
# parent's work, and exactly wrong for a worker that outlives it.
#
# The post-commit hook fires from INSIDE lv-commit.sh, which holds `registry`
# and `commit` for the length of the commit. A worker launched down that path
# inherits both marks and never releases them, because it never took them —
# so every registry write it makes for the rest of its run silently skips the
# lock that exists to serialize it against the other live workers.
#
# A spawned worker owns nothing it did not acquire itself.
while IFS='=' read -r var _; do
  case "$var" in LV_LOCK_HELD_*) unset "$var" 2>/dev/null || true ;; esac
done < <(env)

# ── Default model per role ────────────────────────────────────────────────
default_model() {
  case "$1" in
    spec)        echo "opus" ;;
    implement)   echo "sonnet" ;;
    verify)      echo "sonnet" ;;
    test)        echo "haiku" ;;
    consistency) echo "sonnet" ;;
    release)     echo "haiku" ;;
    deploy)      echo "haiku" ;;
  esac
}
model="${model_override:-$(wf_cfg "orchestrator.models.$role" "$(default_model "$role")")}"

# ── Already-running guard ─────────────────────────────────────────────────
#
# Keyed on the NUMBER, not the artifact name. It used to be
# "${artifact}-${role}.pid", which reads as one guard per worker and is really
# one guard per NAME — and the same work has two names on its way through spec.
# client-a's WFI-067: `BUG-022-csp-blocks-inline-styles` (still listed by
# lv-list-specable.sh, because the open→triaged move had not committed) and
# `PLN-022-csp-style-src` (in draft) were both offered, took different pidfiles,
# and two lv-spec workers reviewed and approved the same plan at once. One wrote
# its verdict on top of the other's, leaving plan.md with two contradicting
# `## Review` blocks.
pidfile="$ORCH/logs/${num}-${role}.pid"
# Adopt a pre-v5.1 pidfile so an upgrade mid-flight does not double-launch.
legacy_pidfile="$ORCH/logs/${artifact}-${role}.pid"
[ -f "$legacy_pidfile" ] && [ ! -f "$pidfile" ] && mv "$legacy_pidfile" "$pidfile" 2>/dev/null || true
if [ -f "$pidfile" ]; then
  old_pid=$(cat "$pidfile" 2>/dev/null || echo "")
  if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
    echo "lv-spawn: $role already running for $id (PID $old_pid)" >&2
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
# out the work. Attended sessions claim through lv-claim.sh the same way, so an
# attended /lv-test and the daemon now contend for one file instead of racing.
#
# The claim keys on the artifact NUMBER rather than the plan folder, so a spec
# worker dispatched onto a BRF/BUG — which has no plan folder until it writes
# one — is claimed from spawn like every other role (client-c WFI-004).
claim_dir=$(wf_claim_dir "$artifact")
if wf_claim_held "$artifact"; then
  holder=$(sed -n '2p' "$LV_CLAIM_HELD_DIR/.wf-claim" 2>/dev/null || true)

  # ── Our own claim: queue, do not decline ────────────────────────────────
  #
  # The post-commit verify hook fires from inside the implementer's own
  # lv-commit.sh, and the implementer's exit order is fixed by contract:
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
  # here; lv-unclaim.sh flushes the queue the moment the claim comes down, by
  # which point every guard can answer honestly.
  if wf_claim_mine "$LV_CLAIM_HELD_DIR"; then
    if ! $dry_run; then
      mkdir -p "$ORCH/pending"
      printf '%s\t%s\t%s\n' "$role" "$artifact" "$model_override" \
        > "$ORCH/pending/${num}-${role}.spawn"
      wf_event queue "$id" "$role deferred until the claim is released"
    fi
    echo "lv-spawn: $artifact still holds this session's own claim — $role queued until it is released" >&2
    echo "          claim at ${LV_CLAIM_HELD_DIR:-?}/.wf-claim" >&2
    exit 2
  fi

  echo "lv-spawn: $artifact is claimed by a live session (PID ${holder:-?}) — not spawning $role" >&2
  # NAME THE PATH. wf_claim_held reads two locations and this message named
  # neither, so a claim at the pre-v5.6 plans/<artifact>/.wf-claim produced a
  # deferral every sweep while lv-claim.sh --list reported "No live claims."
  # client-d WFI-021 spent ten minutes of a stalled daemon on the gap between
  # those two sentences. The path is the whole diagnosis: lv-unclaim.sh clears
  # both, but only once you can see which one is holding.
  echo "          claim at ${LV_CLAIM_HELD_DIR:-?}/.wf-claim" >&2
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
# the types it passes through (BUG-096 → PLN-096), but lv-plan-id.sh reallocates
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
#
# …UNTIL THE BRIEF HAS A PLAN
#
# "There is no plan row" stops being true the moment spec writes one, and after
# that the source artifact has exactly one row that matters — its plan's.
# Abstaining there is how client-a's BRF-161 (WFI-188) got a fresh spec
# worker at 16:0x, minutes after commit 20768695 had moved
# PLN-161-image-tier-wire-budget draft → ready and 4b1d887e had recorded the
# spec-approval resolution. lv-list-specable.sh was empty, the review was
# Approved and unstale, the gate was answered: there was no spec work left. The
# worker read all that, changed nothing and exited — a whole model launch to
# rediscover that the pipeline had already moved on.
#
# The lookup is NOT the WFI-160 mistake repeated. That was arithmetic — take
# the number, assume PLN-<number> — and it was wrong because a reallocated
# number makes BRF-081 and PLN-081 unrelated. This asks lv-plan-id.sh, which
# answers from the plan header naming this artifact, and only acts on
# PLAN_ID_RESUME=true — a plan that says in a field that it is this brief's.
# --peek is what makes it safe to ask: the same call without it allocates
# (WFI-175), so this guard would have burned an artifact number per spawn.
registry="$ROOT/plans/REGISTRY.md"
state_id=""
id_kind=""
if [[ "$id" =~ ^($LV_PLN_RE)- ]]; then id_kind=plan
elif [[ "$id" =~ ^($LV_BUG_RE|$LV_BRF_RE)- ]]; then id_kind=source; fi   # not RELEASE and kin
case "$id_kind" in
  plan) state_id="${id%%-*}-$num" ;;
  source)
    if [ -x "$SELF_DIR/lv-plan-id.sh" ]; then
      peek=$("$SELF_DIR/lv-plan-id.sh" "$id" --peek 2>/dev/null || true)
      if printf '%s' "$peek" | grep -q "PLAN_ID_RESUME='true'"; then
        state_id=$(printf '%s' "$peek" | grep '^PLAN_ID=' | cut -d"'" -f2)
      else
        # A plan that names this artifact and has left `draft` is not offered
        # as a resume — a spec session writing into it would overwrite a plan
        # a builder or tester already has (WFI-016). It is still exactly what
        # this guard is looking for, so it is reported separately rather than
        # dropped: without it, the brief whose plan went `ready` reads as never
        # specced at all and gets another spec worker, which is WFI-188.
        claimed=$(printf '%s' "$peek" | grep '^PLAN_ID_CLAIMED_BY=' | cut -d"'" -f2)
        [ -n "$claimed" ] && state_id="$claimed"
      fi
    fi ;;
esac

cur_state=""
if [ -f "$registry" ] && [ -n "$state_id" ]; then
  cur_state=$(wf_registry_field "$state_id" state "$registry")
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
    # Name the plan that answered, which is not always the artifact asked
    # about: a brief is judged by the state of the plan it became.
    if [ "$state_id" = "$id" ]; then
      echo "lv-spawn: $state_id is '$cur_state' — $role does not act on that state; not spawning" >&2
    else
      echo "lv-spawn: $id was already specced as $state_id, now '$cur_state' — $role does not act on that state; not spawning" >&2
    fi
    wf_event skip "$id" "$role: $state_id state is '$cur_state' before launch"
    exit 2
  fi
fi

# ── Gate guard ────────────────────────────────────────────────────────────
#
# A gate means a human has to decide, and until they have, nothing may be
# dispatched at the artifact. The DISPATCHER already knows that — it lists a
# gate as a standing skip reason (lv-orchestrate.sh) — but the dispatcher is not
# the only way a worker is launched. lv-unclaim.sh serves deferred spawn markers
# the moment a claim drops, and that path never consulted a gate at all.
#
# So the sequence that mattered was: something tries to spawn while the plan is
# claimed, gets deferred to .claude/orchestrator/pending/, the holder then parks
# the plan on a gate and releases its claim — and the release serves the marker,
# launching a worker at a plan that is sitting on an unanswered human decision.
# That is WFI-079's false dispatch reached by a different door: a worker running
# on a decision nobody has made, whose own gate-open then lands on top of the
# one already there.
#
# Checked here rather than in lv-unclaim.sh because this is where every launch
# path converges, and because the same read answers for the dispatcher's own
# calls — redundantly, which is the point: a guard that only one caller performs
# is a guard the next caller forgets.
for gated in "$id" "$state_id"; do
  [ -n "$gated" ] || continue
  if "$SELF_DIR/lv-list-gates.sh" "$gated" >/dev/null 2>&1; then
    echo "lv-spawn: $gated has an open gate — $role is not dispatched until a human answers it; not spawning" >&2
    wf_event skip "$id" "$role: gate open on $gated before launch"
    exit 2
  fi
done

# ── Worker prompt ─────────────────────────────────────────────────────────
# Skills live at .claude/skills/lv-<role>/SKILL.md on a client checkout.
case "$role" in
  release|deploy) target_desc="$id" ;;
  *)              target_desc="$id (full artifact name: ${artifact})" ;;
esac
read -r -d '' prompt <<PROMPT || true
You are running UNATTENDED as part of the workflow orchestrator. LV_UNATTENDED=1 is set in your environment. There is no human reading your output — a question you ask will hang the pipeline.

Read .claude/skills/lv-${role}/SKILL.md in full, INCLUDING its "Unattended mode" section, then execute it for ${target_desc}.

Follow the Unattended mode rules exactly:
- Skip any work-selection menu; ${id} is your assigned artifact.
- Resolve [AUTO] prompts to their documented defaults.
- For anything marked [GATE], or anything you would otherwise ask a human, run scripts/lv-exec.sh lv-gate-open.sh with a clear question and then exit cleanly. Never guess.
- lv-gate-open.sh exiting 3 means that question already has an answer of record, printed with it, and the plan has not changed since. That is not a failure and not a reason to ask it differently: act on the resolution and carry on. A gate re-opened after it was answered comes back re-derived, and the human answers something they were never asked (WFI-180/181/182).
PROMPT

if $dry_run; then
  echo "DRY-RUN spawn: role=$role artifact=$artifact model=$model foreground=$foreground"
  exit 0
fi

ts=$(date +%Y%m%d-%H%M%S)
case "$role" in
  release|deploy) log="$ORCH/logs/${id}-${ts}.log" ;;
  *)              log="$ORCH/logs/${artifact}-${role}-${ts}.log" ;;
esac

# ── Foreground: block, stream, propagate the worker's status ──────────────
if $foreground; then
  wf_event spawn "$id" "$role ($model) foreground"
  echo $$ > "$pidfile"
  wf_claim_write "$claim_dir" $$ "$artifact"
  set +e
  # LV_CLAIM_PID names the claim we just took out FOR this worker, so its own
  # "is this plan free?" check recognises the claim as its own (WFI-073/075).
  ( cd "$ROOT" && LV_UNATTENDED=1 LV_ROLE="$role" LV_ARTIFACT="$artifact" LV_CLAIM_PID=$$ \
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
export LV_PROMPT="$prompt"
export LV_UNATTENDED=1 LV_ROLE="$role" LV_ARTIFACT="$artifact"
# The worker's LAST act is to log its exit, and it runs hours after this line.
# Baking an absolute generation path into that command assumes the path still
# exists when the worker finishes, and a deploy in the meantime makes it not:
# client-a WFI-256 lost a completed implement run's exit event to
# `.../scripts/gen/9.4.0-.../v2.00/lv-event.sh: No such file or directory`,
# because two deploys inside a minute retired the build the worker was launched
# from. So the pinned path is the preference and the dispatcher is the fallback
# — the generation a worker started under, while it is there, and the live
# harness when it is not.
event_sh="$(cd "$(dirname "$0")" && pwd)/lv-event.sh"
event_fallback="$ROOT/scripts/lv-exec.sh"
# Same pinned-then-fallback rule, for the same reason: this runs in the
# worker's exit clause, hours after the launch, possibly across a deploy.
refund_sh="$(cd "$(dirname "$0")" && pwd)/lv-attempt-refund.sh"

claimfile="$claim_dir/.wf-claim"

# $$ inside the bash -c is the PID this shell records as $! below, which is the
# same PID wf_claim_write stamps on the claim — so the worker can name its own
# claim rather than standing down against it (WFI-073/075).
# The started-marker is how the launch tells us `bash -c` actually began. A
# worker that exits quickly and one that never started look identical from the
# outside — same absent process, same PID — and only the marker separates them.
started_marker="$log.started"
rm -f "$started_marker"

nohup bash -c "
    : > '$started_marker'
    cd '$ROOT'
    export LV_CLAIM_PID=\$\$
    claude -p --model '$model' --dangerously-skip-permissions \"\$LV_PROMPT\"
    rc=\$?
    rm -f '$pidfile'
    [ -n '$claimfile' ] && rm -f '$claimfile'
    # Before the exit event, so the refund is on the record above the rc that
    # explains it. The marker check below only proves \`bash -c\` began; a
    # session refused by the API dies after it and looks healthy from outside
    # (client-d WFI-016).
    if [ -x '$refund_sh' ]; then
      '$refund_sh' '$id' '$role' '$log' \"\$rc\" || true
    else
      '$event_fallback' lv-attempt-refund.sh '$id' '$role' '$log' \"\$rc\" || true
    fi
    if [ -x '$event_sh' ]; then
      '$event_sh' exit '$id' \"$role rc=\$rc\"
    else
      '$event_fallback' lv-event.sh exit '$id' \"$role rc=\$rc\"
    fi
" < /dev/null > "$log" 2>&1 &

worker_pid=$!
echo "$worker_pid" > "$pidfile"
# The claim names the worker, so it dies with the worker rather than with the
# shell that launched it.
wf_claim_write "$claim_dir" "$worker_pid" "$artifact"
disown "$worker_pid" 2>/dev/null || true

# ── Did the worker actually start? ────────────────────────────────────────
# A launch can fail BEFORE `claude` ever runs, and the shape that hit
# client-a is nohup refusing to detach: "can't detach from console:
# Inappropriate ioctl for device". It is a property of the LAUNCHING process,
# not of the artifact or the role — once a long-lived daemon starts failing
# this way it fails every dispatch until it is replaced. The old code could
# not tell that from a healthy spawn: it had a PID and exited 0, so the
# orchestrator bumped the attempt counter on six dispatches across four
# artifacts and opened three "stuck" gates whose stated question — a worker
# ran and made no forward progress — was false in every case (WFI-231,
# WFI-232). Nothing ran.
#
# So a launch that dies before the worker starts exits non-zero, which is the
# orchestrator's spawn-failure path: reported once through the skip latch,
# and costing no attempt.
#
# Short-poll rather than one flat `sleep 1`: the marker appears almost
# immediately on every healthy spawn, so a fixed second charged the daemon's
# dispatch loop on every single launch — this pays that cost only on the
# failure path, which is rare by construction.
for _ in $(seq 1 20); do
  [ -f "$started_marker" ] && break
  sleep 0.05
done
if [ ! -f "$started_marker" ] \
   || grep -qi "can't detach from console" "$log" 2>/dev/null; then
  launch_err=$(head -3 "$log" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//')
  rm -f "$pidfile"
  [ -n "$claimfile" ] && rm -f "$claimfile"
  wf_event error "$id" "$role launch failed before the worker started: ${launch_err:-no output}"
  echo "lv-spawn: launch failed before the worker started — ${launch_err:-no output}" >&2
  echo "lv-spawn: nothing ran, so this costs no attempt; the fault is in the launching process, not $artifact." >&2
  exit 3
fi
rm -f "$started_marker"

wf_event spawn "$id" "$role ($model) pid $worker_pid"
echo "lv-spawn: $role/$artifact on $model — PID $worker_pid, log $log"
