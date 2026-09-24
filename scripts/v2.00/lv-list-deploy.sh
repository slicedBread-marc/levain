#!/usr/bin/env bash
# lv-list-deploy.sh — eligibility check for the `deploy` role (docs/eligibility.md).
#
# Prints DEPLOY (and exits 0) iff the local `main` branch exists and `release`
# has at least one commit it doesn't. Prints nothing (exits 1) otherwise.
#
# Why this is a safe signal: /lv-release only pushes the `release` branch
# AFTER its local E2E run passes (the push-after-test ordering fixed alongside
# this feature — see skills/lv-release/SKILL.md). So "release is ahead of main"
# means "these commits passed E2E", for both attended and unattended runs, with
# no separate marker file needed.
#
# That holds only while the local ref and the pushed one agree, which is why
# the unpushed-commit check below is part of the signal and not a nicety.
# client-b WFI-007: /lv-release fast-forwarded LOCAL release onto develop,
# E2E failed, and the run exited without resetting it. Nothing was pushed — and
# this check read the local ref, counted 30 commits, and dispatched a deploy
# worker that opened a deploy-approval gate over a batch whose suite was red.
# /lv-release now rolls that merge back (lv-release-rollback.sh), but a worker
# killed mid-run, or an older client, still leaves the ref ahead. So: commits
# on local `release` that `origin/release` has never seen are, by construction,
# commits `/lv-release` did not push — i.e. commits that did not pass. They are
# not deployable and this says so, rather than trusting one skill's exit path
# to be the only guard (coordinator WFI-002).
#
# THREE THINGS MAKE A DEPLOY A CANDIDATE, NOT ONE
#
# `main..release` answers "is there anything to promote", and it answers it
# against the LOCAL main ref — which a half-finished deploy has already moved.
#
# client-a WFI-265: a DEPLOY worker merged origin/release into local main,
# armed the guard, wrote one line to its log and exited without pushing. Its
# own unpushed merge commit put local main ahead of local release, so
# `main..release` was empty, this script exited 1, and DEPLOY was never a
# candidate again. Entry into /lv-deploy is what runs `--recover`, and
# candidacy is what gates entry — so the recovery path sat behind the door the
# failure had locked. The daemon spawned nothing for 22 hours with 34 approved
# commits undeployed and origin/main untouched; `--sweep --dry-run` printed no
# deploy line at all, so the stall was invisible. It recovered by coincidence,
# when an unrelated RELEASE worker advanced local release past local main.
#
# So two more conditions, each meaning "local main is not what is deployed":
#
#   armed guard   lv-deploy-guard.sh says a merge into main is provisional. An
#                 armed marker means the tip is unverified BY DEFINITION and
#                 must never be read as deployed. Its own header says every
#                 entry into /lv-deploy runs --recover; this is what gets a
#                 worker to that entry.
#   unpushed main commits on local main that origin/main has never seen. A
#                 promotion that did not reach origin did not happen —
#                 "deployed" and "locally merged" are different facts and this
#                 script conflated them.
#
# The `main..release` comparison stays local and stays primary: origin/main can
# be stale in a way local main cannot, and a candidacy check that loops on a
# stale ref costs a dispatch every sweep.
#
# Local-ref only, deliberately cheap — this is a candidacy check for the
# dispatcher, not a source of truth. /lv-deploy itself re-verifies before
# doing anything.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

cd "$(wf_develop_root)"

git rev-parse --verify --quiet main >/dev/null 2>&1 || exit 1

# Unpushed local commits on `release` = commits /lv-release did not push =
# commits that did not pass E2E. Only checked when the remote ref exists at
# all; a project with no `origin/release` has nothing to compare against and
# is left to the rest of the pipeline.
if git rev-parse --verify --quiet origin/release >/dev/null 2>&1; then
  [ -z "$(git rev-list origin/release..release -1 2>/dev/null)" ] || exit 1
fi

if [ -n "$(git rev-list main..release -1 2>/dev/null)" ]; then
  echo "DEPLOY"
  exit 0
fi

# A provisional tip is not a deployed one.
if [ -x "$SELF_DIR/lv-deploy-guard.sh" ] \
   && "$SELF_DIR/lv-deploy-guard.sh" --status >/dev/null 2>&1; then
  echo "DEPLOY"
  exit 0
fi

# Merged locally, never pushed — the promotion is unfinished, not done.
#
# Unless a human already said "don't push this" at the `production-push` gate
# for this exact tip. /lv-deploy step 14 asks that question when it holds no
# standing grant, and an `approve` is what the next dispatch acts on — but a
# `reject` leaves main unpushed on purpose, and a dispatch would only open the
# same question again (coordinator WFI-008). A new tip on main is a new question.
if git rev-parse --verify --quiet origin/main >/dev/null 2>&1; then
  if [ -n "$(git rev-list origin/main..main -1 2>/dev/null)" ]; then
    push_rec=$(wf_gate_resolved_file DEPLOY production-push 2>/dev/null || true)
    if [ -n "$push_rec" ] && [ -f "$push_rec" ] \
       && [ "$(wf_gate_field "$push_rec" GATE_DECISION)" = "reject" ] \
       && [ "$(wf_gate_field "$push_rec" GATE_PROMOTE_TIP)" = "$(git rev-parse main)" ]; then
      exit 1
    fi
    echo "DEPLOY"
    exit 0
  fi
fi

exit 1
