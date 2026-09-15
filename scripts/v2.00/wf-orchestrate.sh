#!/usr/bin/env bash
# wf-orchestrate.sh — the workflow dispatcher.
#
# Routing is pure bash: REGISTRY state maps to a role by table, and only the
# workers cost tokens. The orchestrator itself never calls a model.
#
# MODES
#   --sweep                one pass: dispatch everything eligible, exit
#   --daemon               sweep / sleep / repeat until stopped
#   --stop                 stop a running daemon (workers finish on their own)
#   --kill-all             stop the daemon AND terminate every live worker
#   --daemon-status        exit 0 if a daemon is live, 1 otherwise (read-only)
#   <ID> [--until STATE]   drive ONE artifact as far through the pipeline as
#                          it will go, in the foreground. This is the hook for
#                          an agent in another repo.
#
# OPTIONS
#   --dry-run     report what would be spawned; spawn nothing
#   --json        machine-readable result (drive-one mode)
#   --interval N  daemon sweep interval, overriding config
#   --force       ignore orchestrator.enabled: false
#
# DRIVE-ONE EXIT CODES — the contract for external callers:
#   0    reached the target state
#   20   blocked on a human decision; the gate is on stdout / in --json
#   30   no progress: the worker ran but the state did not change
#   40   the plan is abandoned: terminal, and not successfully. Distinct from 0
#        so an external driver can tell "shipped" from "dropped on purpose"
#   41   a healthy worker for this role is already running and outlasted the
#        wait. NOT a fault — re-drive once it exits. Distinct from 30 so a
#        caller does not read a concurrent run as a stalled plan.
#   1    error (bad artifact, worker failure, orchestrator disabled)
#
# DAEMON EXIT CODES:
#   0    stopped on request (--stop, SIGTERM, Ctrl-C)
#   4    stood down: launches kept dying before their workers started, so the
#        fault is in this process. Start a fresh daemon. No attempts were
#        charged to any artifact.
#
# The dispatcher skips an artifact when ANY of these hold:
#   · a gate is open on it            · its deps are not complete
#   · another session holds its claim · its role is at max_concurrent
#   · it is over its attempt budget   · the hourly spawn budget is spent
#   · release/deploy only: no standing grant covers the promotion

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

REGISTRY="plans/REGISTRY.md"

# ── Arguments ─────────────────────────────────────────────────────────────
mode=""
target=""
until_state=""
dry_run=false
as_json=false
interval_override=""
force=false

while [ $# -gt 0 ]; do
  case "$1" in
    --sweep)    mode="sweep"; shift ;;
    --daemon)   mode="daemon"; shift ;;
    --stop)     mode="stop"; shift ;;
    --kill-all) mode="kill-all"; shift ;;
    --daemon-status) mode="daemon-status"; shift ;;
    --until)    until_state="${2:?--until requires a state}"; shift 2 ;;
    --interval) interval_override="${2:?--interval requires seconds}"; shift 2 ;;
    --dry-run)  dry_run=true; shift ;;
    --json)     as_json=true; shift ;;
    --force)    force=true; shift ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)         echo "Unknown option: $1" >&2; exit 1 ;;
    *)          target="$1"; mode="${mode:-drive}"; shift ;;
  esac
done

[ -n "$mode" ] || { sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

ROOT="$(wf_develop_root)"
ORCH="$(wf_orch_dir)"
mkdir -p "$ORCH/attempts"
cd "$ROOT"

# ── Config ────────────────────────────────────────────────────────────────
cfg_enabled=$(wf_cfg orchestrator.enabled false)
cfg_interval="${interval_override:-$(wf_cfg orchestrator.sweep_interval 60)}"
cfg_max_attempts=$(wf_cfg orchestrator.max_attempts_per_plan 3)
cfg_max_spawns=$(wf_cfg orchestrator.max_spawns_per_hour 20)
cfg_max_launch_fails=$(wf_cfg orchestrator.max_launch_failures 3)

cfg_consistency=$(wf_cfg orchestrator.consistency_pass true)

# --dry-run must leave NO trace. An events.log carrying `sweep — spawned 1`
# from a preview is indistinguishable, when read back, from a real dispatch —
# there is no matching spawn event, pidfile or process to contradict it.
if $dry_run; then
  wf_event() { :; }
fi

# Read with the rest of the config, once, rather than re-parsing
# claude-workflow.yml per role on every sweep of a daemon that never exits.
cfg_cap_spec=$(wf_cfg orchestrator.max_concurrent.spec 1)
cfg_cap_implement=$(wf_cfg orchestrator.max_concurrent.implement 2)
cfg_cap_verify=$(wf_cfg orchestrator.max_concurrent.verify 2)
cfg_cap_test=$(wf_cfg orchestrator.max_concurrent.test 1)
cfg_cap_consistency=$(wf_cfg orchestrator.max_concurrent.consistency 1)
# release/deploy are singletons by construction — one promotion pipeline, one
# worktree each (release-branches/release, release-branches/main) — so this is
# fixed rather than a claude-workflow.yml knob. A higher cap would be a
# footgun the per-role claim (RELEASE/DEPLOY) doesn't protect against: it
# stops two CONCURRENT release runs, not two the dispatcher was told to allow.
cfg_cap_release=1
cfg_cap_deploy=1

# Indirect lookup, not a case arm per role: the five cfg_cap_* reads above are
# the only place role names are enumerated, so adding a role means adding one
# read instead of a read AND a matching case line that silently returns empty
# if it's missed.
max_concurrent() {
  local var="cfg_cap_$1"
  printf '%s' "${!var:-}"
}

require_enabled() {
  # --dry-run is a pure read — no worker, no gate, nothing written to
  # events.log (see the --dry-run contract above) — so it carries none of the
  # risk `enabled: false` guards against. Docs and the claude-workflow.yml
  # comment both tell a client to preview with `--sweep --dry-run` BEFORE
  # flipping the flag on; requiring --force to do that made the documented
  # preview path unsatisfiable without also granting the thing it exists to
  # let you evaluate first (client-b WFI-002).
  if $dry_run; then return 0; fi
  if [ "$cfg_enabled" != "true" ] && ! $force; then
    echo "wf-orchestrate: disabled (set orchestrator.enabled: true in claude-workflow.yml, or pass --force)" >&2
    return 1
  fi
  return 0
}

# ── State helpers ─────────────────────────────────────────────────────────

# RELEASE / DEPLOY are the two fixed pipeline-stage literals — release and
# deploy are batches across plans, not one artifact, so they carry a fixed
# name instead of a counter-allocated number (see wf_claim_dir).
bare_id() {
  case "$1" in
    RELEASE|DEPLOY) printf '%s' "$1" ;;
    *) printf '%s' "$1" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true ;;
  esac
}

# Plan state from the registry, empty if the plan has no row.
plan_state() {
  local id="$1"
  [ -f "$REGISTRY" ] || return 0
  wf_registry_field "$id" state "$REGISTRY"
}

# Full plan name (PLN-NNN-slug) for an ID.
plan_name_of() {
  local id="$1" slug
  slug=$(wf_registry_field "$id" slug "$REGISTRY")
  [ -n "$slug" ] && printf '%s-%s' "$id" "$slug" || printf '%s' "$id"
}

gate_open()  { "$SELF_DIR/wf-list-gates.sh" "$1" >/dev/null 2>&1; }
gate_line()  { "$SELF_DIR/wf-list-gates.sh" "$1" 2>/dev/null; }

# Live worker count for a role, across all artifacts.
role_running() {
  local role="$1" n=0 pf pid
  for pf in "$ORCH/logs"/*-"$role".pid; do
    [ -f "$pf" ] || continue
    pid=$(cat "$pf" 2>/dev/null || echo "")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      n=$((n + 1))
    else
      rm -f "$pf"          # reap dead workers as we go
    fi
  done
  printf '%s' "$n"
}

# Attempt budget — the loop breaker. A plan bouncing active⇄verify forever
# burns tokens silently; after N implement spawns it parks as `stuck` instead.
attempts_get() { cat "$ORCH/attempts/$1.$2" 2>/dev/null || echo 0; }
attempts_bump() {
  local n; n=$(( $(attempts_get "$1" "$2") + 1 ))
  echo "$n" > "$ORCH/attempts/$1.$2"
}
attempts_reset() { rm -f "$ORCH/attempts/$1".* 2>/dev/null || true; }

# Launch failures — the OTHER loop breaker, and it counts the daemon rather
# than the plan. When a launch dies before its worker starts (wf-spawn.sh
# rc=3), nothing about the artifact is wrong and retrying a different one will
# not help: the fault travels with this process. client-a's daemon spent
# 70 minutes in that state, failing every dispatch across four artifacts while
# reporting healthy (WFI-232). Consecutive failures across ANY artifact are
# counted here, and the daemon stands down rather than draining its queue into
# skips. A single successful spawn clears it — a one-off is not a broken
# daemon.
launch_fails_get() { cat "$ORCH/launch-fails" 2>/dev/null || echo 0; }
launch_fails_bump() { echo $(( $(launch_fails_get) + 1 )) > "$ORCH/launch-fails"; }
launch_fails_reset() { rm -f "$ORCH/launch-fails" 2>/dev/null || true; }

# Forward progress — what makes the attempt budget mean something.
#
# The budget counts worker LAUNCHES. Without this, a clean resume of an 11-step
# plan bumps the same counter as a genuine active⇄verify thrash, so long plans
# park as `stuck` with nothing wrong and the only workaround is raising the cap
# until the loop breaker no longer breaks loops.
#
# The signature is (registry state, ticked steps). Either moving means the last
# launch accomplished something, so the budget resets and `max_attempts_per_plan`
# reads as what it claims to be: N launches with NO forward progress.
progress_sig() {
  local id="$1" st cnt con="-"
  # RELEASE/DEPLOY have no registry row or step checklist to read — the
  # default path below would return the SAME signature on every dispatch, so
  # the attempt budget would never reset and three lifetime releases would
  # permanently trip `stuck`, no matter how many succeeded in between. The
  # branch each promotes IS the forward-progress signal: it only moves on an
  # actual successful promotion, so a gate or a failure (which move nothing)
  # still counts against the budget as intended, and a real success resets it.
  case "$id" in
    RELEASE) printf 'release:%s' "$(git rev-parse release 2>/dev/null || echo none)"; return 0 ;;
    DEPLOY)  printf 'deploy:%s'  "$(git rev-parse main    2>/dev/null || echo none)"; return 0 ;;
  esac
  st=$(plan_state "$id")
  cnt=$("$SELF_DIR/wf-progress-count.sh" "$id" 2>/dev/null || echo "0/0")
  # A finished consistency pass moves nothing else — the plan stays `ready` —
  # so it has to appear here or a successful pass reads as a stalled worker.
  "$SELF_DIR/wf-list-consistency.sh" "$id" >/dev/null 2>&1 && con="c"
  printf '%s:%s:%s' "${st:-none}" "$cnt" "$con"
}

# Resets the attempt budget when the plan has moved since the last check.
progress_check() {
  local id="$1" sig prev file
  mkdir -p "$ORCH/progress"
  file="$ORCH/progress/$id"
  sig=$(progress_sig "$id")
  prev=$(cat "$file" 2>/dev/null || echo "")
  if [ -n "$prev" ] && [ "$sig" != "$prev" ]; then
    attempts_reset "$id"
    wf_event progress "$id" "forward progress $prev → $sig — attempt budget reset"
  fi
  printf '%s' "$sig" > "$file"
}

# Hourly spawn budget. Bucketed by hour rather than parsed from events.log so
# it stays portable (no date arithmetic).
spawn_budget_left() {
  local bucket count
  bucket="$ORCH/spawns-$(date +%Y%m%d%H)"
  count=$(cat "$bucket" 2>/dev/null || echo 0)
  printf '%s' "$(( cfg_max_spawns - count ))"
}
spawn_budget_bump() {
  local bucket; bucket="$ORCH/spawns-$(date +%Y%m%d%H)"
  echo "$(( $(cat "$bucket" 2>/dev/null || echo 0) + 1 ))" > "$bucket"
  # Drop buckets older than today so the dir does not grow forever.
  find "$ORCH" -maxdepth 1 -name 'spawns-*' -mtime +1 -delete 2>/dev/null || true
}

# ── Dispatch ──────────────────────────────────────────────────────────────

# Why a skip is latched rather than logged.
#
# Every skip reason is a STANDING condition, not an event: a gate stays open,
# a role stays at cap, an exhausted budget stays exhausted. Logging one line
# per candidate per sweep therefore records the same fact once per interval
# forever — 1,583 identical `skip PLN-002 spec: gate open` lines in 26 hours in
# one measured run, 4,747 lines in the file. This is the same unbounded-growth
# defect the sweep-line latch fixed, one level down: silencing the summary while
# every line it summarised still fires just moves the noise.
#
# skip_note writes only when the reason for a (role, artifact) pair first
# appears or CHANGES, so a transition is always visible and a steady state is
# silent. skip_clear drops the latch the moment the pair dispatches, so a plan
# that is gated, freed and gated again is reported both times.
# skip_note <role> <artifact-id> <reason> [event-kind]
# Sets WF_SKIP_WAS_NEW so a caller can gate its own console output on the same
# latch. Returning a status would be the natural way to say it, but every call
# below is a bare statement and this script runs under `set -e` — a `return 1`
# meaning "not news" would kill the sweep.
WF_SKIP_WAS_NEW=false
skip_note() {
  local role="$1" id="$2" reason="$3" kind="${4:-skip}" file prev
  WF_SKIP_WAS_NEW=false
  # A preview must leave no trace — latch files included (see --dry-run above).
  $dry_run && return 0
  mkdir -p "$ORCH/skips"
  file="$ORCH/skips/${role}.${id}"
  prev=$(cat "$file" 2>/dev/null || echo "")
  [ "$reason" = "$prev" ] && return 0
  printf '%s' "$reason" > "$file"
  WF_SKIP_WAS_NEW=true
  wf_event "$kind" "$id" "$role: $reason"
}

skip_clear() {
  $dry_run && return 0
  rm -f "$ORCH/skips/${1}.${2}" 2>/dev/null || true
}

# ── Preflight: is the shared checkout ours to use? ────────────────────────
#
# Every develop-side worker — spec, test, consistency, and the setup half of
# implement — runs in the MAIN worktree. The daemon does not own that worktree;
# a human working interactively parks it on whatever branch they like, and
# nothing about being dispatched makes a worker notice.
#
# client-a's WFI-123, one daemon and one interactive /wf-release session in
# the same repo: workers took the human's checked-out `fix/BUG-039-…` as their
# working branch, stacked four PLN-038 commits on a hand-made commit there, and
# then switched the shared working directory to develop mid-session. Per-worker
# guards cannot fix this — by the time a worker runs, the damage is a commit
# away — so the dispatcher declines instead. A branch is not a lock, but
# "develop is checked out" is a sound proxy for "no human is mid-something",
# and the cost of being wrong is a paused daemon rather than a rewritten ref.
#
# The test was "is this one of the pipeline's own branches?", which allowed
# release and main on the reasoning that a release or a deploy legitimately
# parks the root there. client-a's WFI-135 is that reasoning failing: the
# registry is a file, `plans/REGISTRY.md`, and on release it is whatever
# release last merged. PLN-051 read `active` there while develop had it
# `complete`, and within three minutes the daemon dispatched two wf-implement
# workers at a finished plan. Nothing raced — the state machine was swapped
# out from under the dispatcher by a documented step of another skill, and
# every plan whose state moved since the last release sync was exposed the
# same way for as long as the checkout stayed off develop.
#
# So the test is now "is the registry I am about to read develop's?", and only
# develop answers yes. release, main and feature/* each carry their own older
# copy; a branch this pipeline never created belongs to a human session
# (WFI-123). All four mean: dispatch nothing this sweep.
#
# It clears itself: the next sweep after the checkout returns to develop
# dispatches normally.
#
# `/wf-release` and `/wf-deploy` no longer park the shared checkout on
# `release`/`main` at all — each pins its branch to its own persistent
# worktree instead (`wf-worktree-pin.sh`, docs/release-worktrees.md), so a
# release or a deploy no longer costs a pause here. This function is
# unchanged and still guards the remaining case: a human (or a
# not-yet-migrated skill) parking the shared checkout somewhere other than
# develop by hand.
checkout_available() {
  local root branch
  root=$(wf_develop_root)
  branch=$(git -C "$root" branch --show-current 2>/dev/null || true)
  [ "$branch" = "develop" ] && return 0

  # Before develop exists there is no second copy of the registry to be stale
  # against — the branch in front of us IS the registry. A greenfield client
  # would otherwise sit paused forever waiting for a branch the pipeline has
  # not created yet.
  if ! git -C "$root" rev-parse --verify --quiet refs/heads/develop >/dev/null 2>&1; then
    case "$branch" in main|master|release) return 0 ;; esac
  fi

  local why
  case "$branch" in
    release|main|master|feature/*)
      why="main worktree is on '$branch' — plans/REGISTRY.md there is that branch's older copy, not develop's, so every state it reports may be stale (WFI-135)" ;;
    "")
      why="main worktree is on a detached HEAD — no branch owns plans/REGISTRY.md, so nothing it reports can be trusted" ;;
    *)
      why="main worktree is on '$branch' — not a pipeline branch, so another session owns it" ;;
  esac

  skip_note "orchestrator" "—" "$why; dispatching nothing" blocked
  echo "$(wf_now)  paused — $why"
  return 1
}

# dispatch <role> <artifact> — run every skip rule, then spawn.
# Returns 0 if a worker was spawned, 1 if skipped.
dispatch() {
  local role="$1" artifact="$2"
  local id; id=$(bare_id "$artifact")

  if gate_open "$id"; then
    skip_note "$role" "$id" "gate open"
    return 1
  fi

  # Don't dispatch a promotion nothing can authorize.
  #
  # `release` and `deploy` are the only roles whose worker consults a standing
  # grant before doing its job. When that grant doesn't cover the action — the
  # default `mode: attended`, an expired grant, a spent daily ceiling — the
  # worker's whole run is: refuse, open an approval gate, unclaim, exit. The
  # dispatcher can know that in advance, and spawning anyway is not free:
  #
  #   · It burns a worker, an hourly spawn slot and an attempt, and reopens a
  #     gate a human has often just answered. client-d and client-c on
  #     2026-09-15 spawned 34 release/deploy workers between them; 26 of the 37
  #     autonomy questions those asked were refusals, and 17 parked gates.
  #   · A refused worker is structurally the one most likely to go off-script
  #     and promote anyway. WFI-004, WFI-005, WFI-007, WFI-032 and WFI-034 are
  #     five incidents, and every one of them is a worker that had just been
  #     refused. wf-guard-promote.sh contains that class mechanically; not
  #     launching the worker removes the occasion for it.
  #
  # `--check` and not the plain form: the ceiling counts `autonomy-use` lines,
  # so asking the recording way would spend the very budget the worker then
  # needs, and stamp the log with a decision no skill ever acted on. The worker
  # still asks for real when it runs — this is a pre-flight, not the decision.
  #
  # Exit 2 (a malformed grant) skips too, carrying the parse error as the
  # reason: every consumer treats 2 as stop, and a broken file is not a thing a
  # worker can fix. Only `deploy` is checked for the deploy role, never
  # `production-push` — step 14 not being granted is the designed default, not
  # a blocked state, and a deploy with no push grant is still a useful deploy.
  case "$role" in
    release|deploy)
      local arc=0 awhy
      awhy=$("$SELF_DIR/wf-autonomy.sh" "$role" --check 2>&1 >/dev/null) || arc=$?
      if [ "$arc" -ne 0 ]; then
        awhy=$(printf '%s' "$awhy" | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//')
        [ -n "$awhy" ] || awhy="wf-autonomy.sh exited $arc without a reason"
        # The reason text is what skip_note latches on, so this stays silent
        # while the situation holds and speaks again the moment it changes —
        # a grant written, an expiry passed, a ceiling rolling over at UTC
        # midnight.
        skip_note "$role" "$id" "not authorized unattended — $awhy" autonomy
        return 1
      fi
      ;;
  esac

  # Did anything move since we last looked? If so the budget starts over.
  progress_check "$id"

  local attempts; attempts=$(attempts_get "$id" "$role")
  if [ "$attempts" -ge "$cfg_max_attempts" ]; then
    # Opening the gate is a real mutation — a preview must not do it either.
    # No second `gate_open` test here: the check at the top of dispatch()
    # already returned for every artifact that has one, and asking again costs
    # another full wf-list-gates.sh run per parked plan per tick.
    if ! $dry_run; then
      "$SELF_DIR/wf-gate-open.sh" "$artifact" stuck \
        "$role has run $attempts times with no forward progress — neither the registry state nor the progress.md step checklist moved. Needs a human look." \
        --skill "wf-$role" >/dev/null 2>&1 || true
    fi
    skip_note "$role" "$id" "$attempts attempts without progress, parked" stuck
    return 1
  fi

  if [ "$(spawn_budget_left)" -le 0 ]; then
    skip_note "$role" "$id" "hourly spawn budget exhausted ($cfg_max_spawns)" budget
    return 1
  fi

  # Past every guard — whatever was holding this pair back no longer is, so the
  # next time one does, it is news again.
  skip_clear "$role" "$id"

  # A preview that skips half the guards is not a preview.
  #
  # This printed "would spawn" and returned, so the checks that live inside
  # wf-spawn.sh — already-running, and the last-moment re-read of the registry
  # row — were never consulted. `--sweep --dry-run` said "would spawn: spec
  # BRF-081" while every real sweep refused it, and the human comparing the two
  # concluded the dispatcher was fine and looked elsewhere (client-a's
  # WFI-160). wf-spawn.sh has had its own --dry-run since it was written;
  # delegating to it makes the preview run the same code the sweep does, and
  # anything it declines is reported as declined.
  if $dry_run; then
    local drc=0 dout
    # The reason, not a pointer to it.
    #
    # This threw wf-spawn's output away and told the operator to "re-run it
    # directly to see why" — asking them to spawn a worker to learn something
    # the dispatcher had just computed and discarded. The live sweep prints the
    # real line ("BRF-189 was already specced as PLN-189, now complete") from
    # the same call, so the preview had the answer in hand (WFI-216).
    dout=$("$SELF_DIR/wf-spawn.sh" "$role" "$artifact" --dry-run 2>&1) || drc=$?
    if [ "$drc" -ne 0 ]; then
      echo "  would SKIP: $role $artifact (rc=$drc)"
      printf '%s\n' "$dout" | sed 's/^/      /'
      return 1
    fi
    echo "  would spawn: $role $artifact"
    return 0
  fi

  # A refusal wf-spawn.sh makes is a STANDING condition like every other skip,
  # and it was the one reason that reached here unlatched. `skip_clear` above
  # runs BEFORE the spawn, so a permanent refusal — "BRF-189 was already
  # specced as PLN-189, now complete; spec does not act on that state" — was
  # re-derived, re-printed and re-logged on every 60s sweep, forever, for a
  # condition that can never change. Same unbounded-growth defect the latch
  # exists to prevent, one step further down the path (WFI-216).
  #
  # So the refusal text is what the latch keys on, and wf-spawn's own output is
  # relayed only when it is news. It is captured rather than inherited for
  # exactly that reason; a successful spawn still writes straight through.
  local rc=0 out
  out=$("$SELF_DIR/wf-spawn.sh" "$role" "$artifact" 2>&1) || rc=$?
  # Capturing is safe: wf-spawn.sh's background worker redirects its own stdout
  # and stderr to a log file before detaching, so nothing inherits this
  # substitution's pipe and holds it open.
  if [ "$rc" -eq 0 ]; then
    if [ -n "$out" ]; then printf '%s\n' "$out"; fi
    attempts_bump "$id" "$role"; spawn_budget_bump
    launch_fails_reset
    return 0
  fi

  local reason
  reason=$(printf '%s' "$out" | tr '\n' ' ' | sed 's/[[:space:]]\{2,\}/ /g; s/[[:space:]]*$//')
  [ -n "$reason" ] || reason="wf-spawn declined with no explanation"
  # rc=2 is "already running", which is not an error; rc=3 is a launch that
  # died before the worker started — also not the artifact's fault, and
  # deliberately NOT an attempt: charging one to a plan nothing ran on is how
  # a `stuck` gate comes to assert a worker made no progress when no worker
  # existed (WFI-231). Anything else is a real spawn error.
  if [ "$rc" -eq 2 ]; then
    skip_note "$role" "$id" "$reason"
  elif [ "$rc" -eq 3 ]; then
    launch_fails_bump
    skip_note "$role" "$id" "launch failed before the worker started (no attempt charged): $reason" error
  else
    skip_note "$role" "$id" "spawn failed rc=$rc: $reason" error
  fi
  if $WF_SKIP_WAS_NEW && [ -n "$out" ]; then printf '%s\n' "$out"; fi
  return 1
}

# ── Candidate lists, per role ─────────────────────────────────────────────
# Each emits bare artifact names, one per line, already filtered for the
# states that role can act on. The wf-list-*.sh scripts remain the single
# source of eligibility truth (docs/eligibility.md) — we only parse them.

candidates_verify() {
  "$SELF_DIR/wf-list-verify.sh" 2>/dev/null | awk -F'\t' 'NF { print $1 }' || true
}

candidates_test() {
  # Field 6 carries "blocked:<deps>" when deps are unmet — those are not ours.
  "$SELF_DIR/wf-list-testable.sh" 2>/dev/null \
    | awk -F'\t' 'NF && $6 !~ /^blocked:/ { print $1 }' || true
}

candidates_consistency() {
  [ "$cfg_consistency" = "true" ] || return 0
  "$SELF_DIR/wf-list-consistency.sh" 2>/dev/null | awk -F'\t' 'NF { print $1 }' || true
}

candidates_implement() {
  # Types: new | resume | fix are actionable; processing (claimed elsewhere)
  # and blocked (deps) are not.
  local pending
  pending=$(candidates_consistency)

  "$SELF_DIR/wf-list-implementable.sh" 2>/dev/null \
    | awk -F'\t' '$1 == "new" || $1 == "resume" || $1 == "fix" { print $2 }' \
    | while IFS= read -r name; do
        # A plan still owing a consistency pass is not implementable yet —
        # building it first is what turns a cheap amendment into a migration.
        printf '%s\n' "$pending" | grep -qx "$name" && continue
        printf '%s\n' "$name"
      done || true
}

candidates_release() {
  "$SELF_DIR/wf-list-release.sh" 2>/dev/null || true
}

candidates_deploy() {
  "$SELF_DIR/wf-list-deploy.sh" 2>/dev/null || true
}

candidates_spec() {
  # Sectioned output: "# replanning" rows are plan names, "# bugs" and
  # "# briefs" rows lead with BUG-NNN / BRF-NNN.
  "$SELF_DIR/wf-list-specable.sh" 2>/dev/null | awk -F'\t' '
    /^# / { next }
    NF && $1 != "—" { print $1 }
  ' || true
}

# ── Sweep ─────────────────────────────────────────────────────────────────
# Order matters: drain the furthest-along work first so WIP does not pile up
# behind a queue of freshly specced plans.
# `release`/`deploy` sit ahead of everything else: they are logically PAST
# `complete` — a plan that finished testing days ago and is sitting on develop
# is further along than one just reaching verify. Only dispatched when a
# standing grant actually covers them — dispatch() asks wf-autonomy.sh
# --check first and skips otherwise, so the approval gate is parked by a human
# running the skill attended, not by a worker spawned only to be refused. See
# docs/autonomy.md and skills/wf-release, wf-deploy's "Unattended mode".
# `consistency` sits ahead of `implement`: a cross-plan contradiction caught
# while both plans are still documents is an amendment; caught after one is
# built, it is a migration.
SWEEP_ROLES="release deploy verify test consistency implement spec"

# sweep() reports its count in SWEPT, not on stdout.
#
# It used to `printf '%s' "$spawned"` and be called as `n=$(sweep)`. Everything
# dispatch() and wf-spawn.sh printed landed inside that substitution too, so a
# sweep that actually dispatched something returned the spawn message with the
# count glued on the end, and the daemon's `[ "$n" -gt 0 ]` failed every time
# with "integer expression expected" — the one branch that reports progress was
# unreachable precisely when there was progress to report. An out-of-band
# result channel makes that class of bug impossible rather than fixing one case.
SWEPT=0

sweep() {
  local spawned=0 role cap running artifact

  # Nothing is dispatchable into a checkout somebody else is standing in.
  if ! checkout_available; then
    SWEPT=0
    return 0
  fi
  skip_clear "orchestrator" "—"

  for role in $SWEEP_ROLES; do
    cap=$(max_concurrent "$role")
    running=$(role_running "$role")
    # Latched on the same principle as the per-artifact skips: "at cap" is a
    # standing condition. The reason carries the counts, so a change in how
    # full the role is still surfaces.
    if [ "$running" -ge "$cap" ]; then
      skip_note "$role" cap "at cap ($running/$cap)"
      continue
    fi
    skip_clear "$role" cap

    while IFS= read -r artifact; do
      [ -n "$artifact" ] || continue
      [ "$running" -ge "$cap" ] && break
      if dispatch "$role" "$artifact"; then
        running=$((running + 1))
        spawned=$((spawned + 1))
      fi
    done < <("candidates_$role")
  done

  # Only a sweep that did something is worth an event. A daemon writes one
  # sweep per interval whether or not anything moved, so at the shipped 60s
  # this was ~1,440 identical `spawned 0` lines a day — 146 KB in one measured
  # run — whose entire content was "a human has not looked yet".
  if [ "$spawned" -gt 0 ]; then
    wf_event sweep "—" "spawned $spawned"
  fi
  SWEPT=$spawned
}

# A daemon that sweeps, spawns nothing and has no workers live is not idle —
# it is STALLED. Every candidate is behind a gate or an unmet dep, and nothing
# will change until a human acts. Say so once, name what is responsible, and
# stay quiet until the situation actually changes. Total stall is the one
# condition worth notifying on: unambiguous, never self-correcting, and every
# minute spent in it is wasted wall-clock.
stall_note() {
  local gates sig prev file
  file="$ORCH/stalled"
  gates=$("$SELF_DIR/wf-list-gates.sh" 2>/dev/null \
          | awk -F'\t' '{ printf "%s(%s, blocking %s) ", $1, $2, $6 }' || true)
  sig="${gates:-none}"
  prev=$(cat "$file" 2>/dev/null || echo "")
  [ "$sig" = "$prev" ] && return 0
  printf '%s' "$sig" > "$file"
  if [ -n "$gates" ]; then
    wf_event stalled "—" "nothing dispatchable; every candidate is gated or dep-blocked behind: $gates"
    echo "$(wf_now)  STALLED — waiting on: $gates"
  else
    wf_event stalled "—" "nothing dispatchable and no gates open — the pipeline is empty or complete"
    echo "$(wf_now)  idle — nothing to dispatch"
  fi
}

# Live workers across every role.
workers_live() {
  local role n=0
  for role in $SWEEP_ROLES; do n=$(( n + $(role_running "$role") )); done
  printf '%s' "$n"
}

# ── Modes ─────────────────────────────────────────────────────────────────

DAEMON_PID="$ORCH/daemon.pid"

case "$mode" in

  daemon-status)
    # Read-only, no lock, no `require_enabled` — a caller asking "is anyone
    # dispatching right now" needs an answer regardless of the config flag,
    # and must never mutate anything to get it. Same pidfile check wf-board.sh
    # renders; kept here too rather than only in wf-board's output because a
    # SKILL.md step needs an exit code, not a rendered table (client-c
    # WFI-033: wf-attend told a human to run a promotion by hand right after
    # closing the gate the daemon was itself waiting on, and the daemon won
    # the race every time).
    if [ -f "$DAEMON_PID" ]; then
      dpid=$(cat "$DAEMON_PID" 2>/dev/null || echo "")
      if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
        echo "running (pid $dpid)"
        exit 0
      fi
    fi
    echo "not running"
    exit 1
    ;;

  sweep)
    require_enabled || exit 1
    sweep
    if $dry_run; then
      echo "sweep: $SWEPT worker(s) would be dispatched (dry run — nothing spawned, nothing logged)"
    else
      echo "sweep: $SWEPT worker(s) dispatched"
    fi
    exit 0
    ;;

  daemon)
    require_enabled || exit 1
    if [ -f "$DAEMON_PID" ]; then
      old=$(cat "$DAEMON_PID" 2>/dev/null || echo "")
      if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
        echo "wf-orchestrate: daemon already running (PID $old)" >&2
        exit 1
      fi
      rm -f "$DAEMON_PID"
    fi
    echo $$ > "$DAEMON_PID"

    # Clearing the trap first is what stops the handler running twice: on
    # SIGTERM it fires for TERM, and its own `exit 0` then fires it again
    # through EXIT — two "stopped" events, and two attempts to delete a pidfile
    # that by then may belong to a replacement daemon.
    #
    # The ownership test is the other half. An unconditional `rm -f` from an
    # outgoing daemon deletes its successor's pidfile, after which wf-board
    # reports "daemon: off" while the successor is still sweeping and the next
    # --stop finds nothing to stop.
    daemon_exit_rc=0
    daemon_shutdown() {
      trap - INT TERM EXIT
      if [ "$(cat "$DAEMON_PID" 2>/dev/null || echo "")" = "$$" ]; then
        rm -f "$DAEMON_PID"
      fi
      wf_event daemon "—" "stopped"
      exit "$daemon_exit_rc"
    }
    trap daemon_shutdown INT TERM EXIT

    wf_event daemon "—" "started (interval ${cfg_interval}s)"
    echo "wf-orchestrate: daemon up, sweeping every ${cfg_interval}s. Ctrl-C or --stop to end."
    echo "wf-orchestrate: config is read once, at startup — restart to pick up claude-workflow.yml changes."
    while true; do
      sweep
      if [ "$SWEPT" -gt 0 ]; then
        echo "$(wf_now)  dispatched $SWEPT"
        rm -f "$ORCH/stalled"          # next stall is a fresh one, announce it
      elif [ "$(workers_live)" -eq 0 ]; then
        stall_note
      else
        rm -f "$ORCH/stalled"          # work is in flight; not stalled
      fi
      # A daemon that can no longer launch anything should say so and stop,
      # not keep sweeping. Every dispatch it makes in that state is a skip
      # against an artifact that has nothing wrong with it, and the operator
      # reading `wf-board` sees a daemon that is up and a queue that never
      # moves (WFI-232). Standing down is recoverable — restarting the daemon
      # is what fixed it — and a non-zero exit lets a supervisor do that.
      lf=$(launch_fails_get)
      if [ "$lf" -ge "$cfg_max_launch_fails" ]; then
        echo "wf-orchestrate: $lf consecutive launches died before their worker started." >&2
        echo "wf-orchestrate: the fault is in this process, not in any artifact — no attempts were charged." >&2
        echo "wf-orchestrate: standing down. Start a fresh daemon; if it recurs immediately, read the newest log in $ORCH/logs." >&2
        wf_event daemon "—" "stood down after $lf consecutive launch failures"
        launch_fails_reset
        daemon_exit_rc=4
        exit 4
      fi
      # Backgrounded so the trap fires now rather than whenever the interval
      # happens to elapse. Bash defers a trap until a FOREGROUND child returns,
      # so a plain `sleep 60` kept the daemon alive for up to a full interval
      # after --stop reported it dead — long enough to overlap its replacement.
      sleep "$cfg_interval" &
      wait $! || true
    done
    ;;

  stop|kill-all)
    if [ -f "$DAEMON_PID" ]; then
      pid=$(cat "$DAEMON_PID" 2>/dev/null || echo "")
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null || true
        # Wait for it to actually go. Printing "stopped" the instant SIGTERM is
        # delivered is a lie the caller acts on — it starts a replacement, and
        # for a while two daemons sweep the same registry.
        waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 15 ]; do
          sleep 1
          waited=$((waited + 1))
        done
        if kill -0 "$pid" 2>/dev/null; then
          kill -9 "$pid" 2>/dev/null || true
          echo "daemon killed (PID $pid — no exit ${waited}s after SIGTERM)"
        else
          echo "daemon stopped (PID $pid)"
        fi
      else
        echo "daemon not running (clearing stale pidfile)"
      fi
      # The daemon's own trap removes the pidfile when it owns it. Only clear
      # what is left over, and only if it is still the pid we just stopped.
      if [ "$(cat "$DAEMON_PID" 2>/dev/null || echo "")" = "$pid" ]; then
        rm -f "$DAEMON_PID"
      fi
    else
      echo "daemon not running"
    fi
    if [ "$mode" = "kill-all" ]; then
      for pf in "$ORCH/logs"/*.pid; do
        [ -f "$pf" ] || continue
        wpid=$(cat "$pf" 2>/dev/null || echo "")
        if [ -n "$wpid" ] && kill -0 "$wpid" 2>/dev/null; then
          kill "$wpid" 2>/dev/null && echo "  killed worker PID $wpid ($(basename "$pf" .pid))"
        fi
        rm -f "$pf"
      done
      wf_event daemon "—" "kill-all"
    fi
    exit 0
    ;;

  drive)
    require_enabled || exit 1

    # Same rule as a sweep, but fatal rather than latched: an external caller
    # driving one plan gets an answer, not a silent pause (WFI-123).
    if ! checkout_available >/dev/null; then
      echo "Error: the main worktree is not on develop — another session owns this" >&2
      echo "       checkout. Driving a plan into it would move refs out from under" >&2
      echo "       them (WFI-123). Retry once it is back on develop." >&2
      exit 1
    fi

    id=$(bare_id "$target")
    [ -n "$id" ] || { echo "Error: '$target' is not a PLN/BUG/BRF id" >&2; exit 1; }

    # A BUG/BRF inherits its number when specced (BUG-094 → PLN-094), so the
    # plan we end up driving is predictable from the source ID.
    num="${id#*-}"
    pln_id="PLN-$num"

    steps=()
    result=""
    gate_info=""
    iterations=0
    MAX_ITERATIONS=12
    # How long to wait for a peer worker on the same role before handing the
    # decision back to the caller. Long enough for a normal verify or test run,
    # short enough that a wedged worker does not hold a driver forever.
    ORCH_PEER_WAIT=$(wf_cfg orchestrator.peer_wait_seconds 900)

    while :; do
      iterations=$((iterations + 1))
      if [ "$iterations" -gt "$MAX_ITERATIONS" ]; then
        result="no-progress"; break
      fi

      state=$(plan_state "$pln_id")
      artifact=$(plan_name_of "$pln_id")

      # No plan row yet → this is still a bug or brief awaiting a spec.
      if [ -z "$state" ]; then
        role="spec"; artifact="$target"
      else
        case "$state" in
          draft)          role="spec" ;;
          ready)
            # Owe a cross-plan check? Do it before anything is built.
            if [ "$cfg_consistency" = "true" ] && "$SELF_DIR/wf-list-consistency.sh" "$pln_id" >/dev/null 2>&1; then
              role="consistency"
            else
              role="implement"
            fi
            ;;
          active)         role="implement" ;;
          verify)         role="verify" ;;
          testing)        role="test" ;;
          complete)       result="done"; break ;;
          # Terminal like complete, but not successful. Dispatching a worker at
          # a plan someone deliberately dropped is the exact re-dispatch loop
          # `abandoned` exists to end (WFI-008). `rolled-back` has been a
          # documented state since v4 and was never routed here — it fell
          # through to "unknown state" and exit 1, the same hard failure
          # `abandoned` produced. Both are terminal; neither is a fault in
          # the plan.
          abandoned|rolled-back) result="abandoned"; break ;;
          *) echo "Error: unknown state '$state' for $pln_id" >&2; exit 1 ;;
        esac
      fi

      # Reached the caller's target?
      if [ -n "$until_state" ] && [ "$state" = "$until_state" ]; then
        result="done"; break
      fi

      # Parked before we even start.
      probe_id="$pln_id"; [ -z "$state" ] && probe_id="$id"
      if gate_open "$probe_id"; then
        gate_info=$(gate_line "$probe_id"); result="blocked-on-human"; break
      fi

      $as_json || echo "→ $role  ($artifact${state:+, state=$state})"

      if $dry_run; then
        steps+=("$role:dry-run")
        result="done"; break
      fi

      sig_before=$(progress_sig "$pln_id")

      rc=0
      "$SELF_DIR/wf-spawn.sh" "$role" "$artifact" --foreground || rc=$?
      attempts_bump "$pln_id" "$role"
      steps+=("$role:rc=$rc")

      if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
        result="error"; break
      fi

      # rc=2 is "a worker for this role is ALREADY running". Treating it like a
      # completed launch is what produced a bogus exit 30: the implementer
      # spawns its own verify agent on the way out, this loop reaches verify a
      # moment later, is turned away, sees no state change (because the real
      # verify is still running, healthily) and reports "worker ran, state did
      # not change — something is wrong with the plan or the skill". Nothing was
      # wrong, and a caller obeying the documented contract would misdiagnose
      # it; worse, a retry burns one of max_attempts_per_plan for a non-fault
      # (client-c WFI-002).
      #
      # The right response to "someone else is doing this" is to wait for them.
      if [ "$rc" -eq 2 ]; then
        # Two shapes of "someone else is doing this": a worker of this role
        # (pidfile, keyed on the artifact number), or any session holding the
        # plan's claim. Wait on whichever is live — with neither, a bare
        # `break` here spins the whole loop at full speed until MAX_ITERATIONS.
        wait_pidfile="$(wf_orch_dir)/logs/${pln_id#*-}-${role}.pid"
        wait_claimfile="$(wf_claim_dir "$artifact")/.wf-claim"
        waited=0
        while [ "$waited" -lt "$ORCH_PEER_WAIT" ]; do
          other_pid=$(cat "$wait_pidfile" 2>/dev/null || echo "")
          [ -n "$other_pid" ] || other_pid=$(sed -n '2p' "$wait_claimfile" 2>/dev/null || echo "")
          [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null || break
          sleep 5
          waited=$((waited + 5))
        done
        if [ "$waited" -ge "$ORCH_PEER_WAIT" ]; then
          $as_json || echo "  ($role for $artifact still running after ${waited}s — leaving it to finish)"
          result="peer-running"; break
        fi
        $as_json || echo "  (waited ${waited}s for an already-running $role)"
        continue   # re-read the state that worker just wrote
      fi

      # Did the worker park instead of progressing?
      if gate_open "$pln_id" || gate_open "$id"; then
        probe_id="$pln_id"; gate_open "$pln_id" || probe_id="$id"
        gate_info=$(gate_line "$probe_id"); result="blocked-on-human"; break
      fi

      # A worker that ticked steps but did not change state is still advancing
      # a long plan — keep driving it. Only a launch that moved NOTHING (state
      # and step checklist both unchanged) counts as no-progress.
      if [ "$(progress_sig "$pln_id")" = "$sig_before" ]; then
        result="no-progress"; break
      fi
      attempts_reset "$pln_id"
    done

    final_state=$(plan_state "$pln_id")
    [ -n "$final_state" ] || final_state="none"

    if $as_json; then
      printf '{\n'
      printf '  "artifact": "%s",\n' "$target"
      printf '  "plan": "%s",\n' "$pln_id"
      printf '  "state": "%s",\n' "$final_state"
      printf '  "result": "%s",\n' "$result"
      if [ -n "$gate_info" ]; then
        printf '  "gate": { "name": "%s", "question": "%s", "context": "%s" },\n' \
          "$(printf '%s' "$gate_info" | cut -f2)" \
          "$(printf '%s' "$gate_info" | cut -f4 | sed 's/"/\\"/g')" \
          "$(printf '%s' "$gate_info" | cut -f5)"
      fi
      # What a caller may do NEXT without a person, and until when.
      #
      # An external driver reading exit 20 knows only "a human owns this". It
      # cannot tell "nobody has authorized anything here" from "the promotions
      # after complete are authorized until the 16th" — and those call for
      # opposite behaviour: one waits for a person, the other carries on into
      # /wf-release. Reporting the posture is what lets exit 20 stay a hard
      # stop while still telling the caller where the ceiling actually is.
      printf '  "autonomy": { "mode": "%s", "covers": "%s", "expires": "%s" },\n' \
        "$(wf_cfg orchestrator.autonomy.mode attended)" \
        "$(wf_cfg_list orchestrator.autonomy.standing_for | tr '\n' ' ' | sed 's/ $//')" \
        "$(wf_cfg orchestrator.autonomy.expires_on '')"
      printf '  "steps": ['
      first=true
      for s in "${steps[@]+"${steps[@]}"}"; do
        $first || printf ', '
        printf '"%s"' "$s"; first=false
      done
      printf ']\n}\n'
    else
      echo
      case "$result" in
        done)             echo "✓ $pln_id → $final_state" ;;
        blocked-on-human) echo "⏸ $pln_id → $final_state — GATE: $(printf '%s' "$gate_info" | cut -f2): $(printf '%s' "$gate_info" | cut -f4)" ;;
        no-progress)      echo "⏹ $pln_id → $final_state — no progress" ;;
        error)            echo "✗ $pln_id → $final_state — worker error" ;;
      esac
    fi

    [ "$result" = "done" ] && attempts_reset "$pln_id"

    case "$result" in
      done)             exit 0 ;;
      blocked-on-human) exit 20 ;;
      abandoned)        echo "$pln_id was abandoned — nothing to drive." >&2; exit 40 ;;
      peer-running)     echo "$pln_id: a $role worker is already running — re-drive when it exits." >&2; exit 41 ;;
      no-progress)      exit 30 ;;
      *)                exit 1 ;;
    esac
    ;;
esac
