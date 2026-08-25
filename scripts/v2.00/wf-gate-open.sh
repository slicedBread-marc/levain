#!/usr/bin/env bash
# wf-gate-open.sh <artifact-id> <gate-name> <question> [--context <path>] [--skill <name>]
#
# Parks an artifact on a human decision. An unattended worker calls this INSTEAD
# of asking a question, then exits 0. The dispatcher skips any artifact with an
# open gate, so nothing spins; /wf-attend drains the queue later.
#
# Gate file: <develop-root>/.claude/orchestrator/gates/<ID>.gate
# One file per artifact — concurrent workers would race on appends to a shared
# file, and per-artifact files make "is this one parked?" a single test -f.
#
# Gate names in use. (R) marks the revision-scoped ones — see
# wf_gate_revision_scoped in wf-orch-lib.sh. Their answer holds until the plan's
# specification changes, and re-opening one is refused:
#   spec-approval   (R) spec is drafted AND reviewed, and needs sign-off before
#                   code is written (the review always runs first — see wf-spec)
#   spec-stuck      (R) the review blocked the plan for maxReviewRounds rounds
#   scope-reduction (R) a replan narrows a capability the plan's Goal promises
#   prior-work      (R) code for this plan is already on develop, outside the
#                   pipeline — accept it, or revert it and build per plan.md
#   goal-missing    (R) plan has no concrete goal line
#   migration       (R) plan has pending MIGRATION-NOTES actions
#   consistency-migration (R) wf-consistency found a cross-plan contradiction
#   branch-exists   (R) the feature branch is already there and is not this
#                   plan's to take
#   manual-test     a `#### Manual` acceptance criterion needs human eyes —
#                   asked once per test CYCLE, so never revision-scoped
#   merge-failed    PR could not be merged (conflicts, checks, protection)
#   stuck           plan exceeded its attempt budget
#   needs-input     anything else a worker cannot decide
#   release-approval  an unattended /wf-release found no standing grant for the
#                     develop -> release promotion (wf-autonomy.sh release)
#   deploy-approval   an unattended /wf-deploy found no standing grant for the
#                     release -> main promotion (wf-autonomy.sh deploy)
#
# Re-opening an existing gate is a no-op (keeps the original timestamp), so a
# retried worker doesn't reset the queue position.
#
# A gate that has already been ANSWERED is refused outright — see below.
#
# Exit 0 when a gate is open, 1 on error, 3 when the gate was refused because
# an answer of record already covers this revision of the plan.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

artifact="${1:-}"
gate_name="${2:-}"
question="${3:-}"
shift 3 2>/dev/null || true

context=""
skill=""
force=false
while [ $# -gt 0 ]; do
  case "$1" in
    --context) context="${2:?--context requires a path}"; shift 2 ;;
    --skill)   skill="${2:?--skill requires a name}"; shift 2 ;;
    --force)   force=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$artifact" ] || [ -z "$gate_name" ] || [ -z "$question" ]; then
  echo "Usage: $0 <artifact-id> <gate-name> <question> [--context path] [--skill name]" >&2
  exit 1
fi

# Accept PLN-004 or PLN-004-slug; the gate is keyed by bare ID.
id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a PLN/BUG/BRF id" >&2
  exit 1
fi

# One artifact, one gate — resolved by NUMBER, so opening under BRF-161 finds
# the gate wf-spec opened under PLN-161 rather than writing a second file for
# the same piece of work (WFI-187). When none is open this is the exact name,
# which is where a new one belongs.
gate_file=$(wf_gate_file "$id" || true)

if [ -f "$gate_file" ]; then
  existing=$(grep -m1 "^GATE_NAME=" "$gate_file" | sed "s/^GATE_NAME='//; s/'$//")
  if [ "$existing" = "$gate_name" ]; then
    echo "$id: gate '$gate_name' already open — left as is"
    exit 0
  fi
fi

# ── An answered question is not asked again ───────────────────────────────
#
# Every skill's gating rule is re-evaluated from scratch on every dispatch, and
# the conditions that justify a gate are usually durable facts: the plan carries
# a gateTag, a commit sits on develop touching this plan's files. So the rule
# reads the same the second time, and the worker opens the gate a human just
# closed. wf-gate-status.sh exists to answer this and the skills were told to
# consult it — but a rule the caller must remember is a rule that gets forgotten
# at exactly the moment it matters.
#
# client-a's PLN-135 (WFI-180, WFI-181, WFI-182): a `prior-work` gate
# answered and closed at 11:43:42Z, re-opened at 12:01:45Z with identical
# wording while wf-gate-status.sh still reported GATE_ANSWERED=true and
# GATE_STALE=false. Then a third time, one minute after a close returned 0.
# Then a fourth, thirty minutes after the decision was committed to findings.md,
# by which point the worker had RE-DERIVED the question rather than replaying
# it — offering an option the human had never authorized and describing a
# HashSet that had been a Dictionary since a merge two plans earlier.
#
# That is the cost that makes this a refusal rather than a warning: a re-asked
# question does not come back the same. It comes back re-derived from whatever
# the next worker happens to read, and a human answering it is answering
# something else.
#
# The refusal is scoped to gates whose answer is about the plan as it stands
# (wf_gate_revision_scoped) and lapses the moment the specification changes —
# GATE_STALE=true is a genuinely new question and opens normally. --force is
# for an operator who means it.
if ! $force && wf_gate_revision_scoped "$gate_name"; then
#
# `GATE_ANSWERED_BASIS=revision` is required, not just GATE_ANSWERED: the
# answer must have been checked against a fingerprint that was actually
# compared. `assumed` means one side had none — an old record, a missing file, a
# plan with no REGISTRY row to find it by — and refusing to ask a human on the
# strength of a file that is not there is how a real question goes unasked.
  eval "$("$SELF_DIR/wf-gate-status.sh" "$id" "$gate_name" 2>/dev/null || true)"
  if [ "${GATE_ANSWERED:-false}" = "true" ] && [ "${GATE_STALE:-false}" != "true" ] \
     && [ "${GATE_ANSWERED_BASIS:-none}" = "revision" ]; then
    wf_event gate-refused "$id" "$gate_name: already answered ${GATE_RESOLVED_AT:-} — $question"
    echo "$id: gate '$gate_name' NOT opened — it was answered${GATE_RESOLVED_AT:+ at $GATE_RESOLVED_AT} and the plan has not changed since." >&2
    [ -n "${GATE_QUESTION:-}" ] && echo "  asked:      $GATE_QUESTION" >&2
    echo "  resolution: ${GATE_RESOLUTION:-—}" >&2
    echo "  Act on that answer and carry on. It is the decision of record; do not re-derive the question." >&2
    echo "  If the plan really has moved on, amend it — a changed specification re-opens this gate by itself." >&2
    exit 3
  fi
fi

# ── A cycle-scoped gate that keeps coming back ────────────────────────────
#
# The refusal above only covers revision-scoped gates. `needs-input` and
# `manual-test` are asked once per CYCLE by design, so they must be allowed to
# re-open — and that is exactly how a loop hides. client-a's PLN-204 opened
# the same needs-input question on three consecutive verify cycles (WFI-203,
# WFI-204, WFI-205). Dedup could not catch it: each cycle's wording differs in
# its specifics — a new worktree sha, the same 2300/2300 restated — so a literal
# match sees three different questions where a reader sees one.
#
# Semantic matching is not the answer; guessing that two questions "mean the
# same" is how a genuinely new question gets swallowed. What IS certain is that
# a gate of this name on this artifact has been answered before, and that the
# human draining the queue cannot see it. So the prior answer is carried onto
# the new gate. The question still gets asked — the reader just gets told they
# have answered one like it, and what they said, which is what turns "another
# question" into "this is the third time".
prior_q=""; prior_res=""; prior_at=""
if ! wf_gate_revision_scoped "$gate_name"; then
  prior_file=$(wf_gate_resolved_file "$id" "$gate_name" || true)
  if [ -n "$prior_file" ] && [ -f "$prior_file" ]; then
    prior_q=$(grep -m1   "^GATE_QUESTION="   "$prior_file" | sed "s/^GATE_QUESTION='//; s/'$//" || true)
    prior_res=$(grep -m1 "^GATE_RESOLUTION=" "$prior_file" | sed "s/^GATE_RESOLUTION='//; s/'$//" || true)
    prior_at=$(grep -m1  "^GATE_RESOLVED="   "$prior_file" | sed "s/^GATE_RESOLVED='//; s/'$//" || true)
  fi
fi

{
  wf_emit GATE_ID       "$id"
  wf_emit GATE_ARTIFACT "$artifact"
  wf_emit GATE_NAME     "$gate_name"
  wf_emit GATE_QUESTION "$question"
  wf_emit GATE_CONTEXT  "$context"
  wf_emit GATE_SKILL    "$skill"
  wf_emit GATE_OPENED   "$(wf_now)"
  if [ -n "$prior_res" ]; then
    wf_emit GATE_PRIOR_QUESTION   "$prior_q"
    wf_emit GATE_PRIOR_RESOLUTION "$prior_res"
    wf_emit GATE_PRIOR_AT         "$prior_at"
  fi
} > "$gate_file"

if [ -n "$prior_res" ]; then
  echo "$id: NOTE — a '$gate_name' gate on this artifact was already answered${prior_at:+ at $prior_at}." >&2
  echo "  asked before: ${prior_q:-—}" >&2
  echo "  answered:     $prior_res" >&2
  echo "  If this is the same question in different words, the answer did not stick — say so when you answer, and fix what re-asks it." >&2
fi

wf_event gate-open "$id" "$gate_name: $question"
echo "$id: gate '$gate_name' opened — $question"
