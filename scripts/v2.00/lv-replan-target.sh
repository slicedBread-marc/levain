#!/usr/bin/env bash
# lv-replan-target.sh <plan-id> [--apply] [--note "text"]
#
# Resolves the state a replanned plan should return to, and optionally writes
# it.
#
#   no worktree   → ready    the builder runs Phase 1 and builds it fresh
#   live worktree → active   the builder resumes its FIX CYCLE
#   …and nothing  → testing  the bounce is answered; hand it back to the tester
#
# WHY THIS IS NOT ALWAYS `ready`
#
# lv-implement's exit runs `lv-registry-update.sh <id> active verify`. That
# from_state guard is deliberate — it is what stops two workers racing the same
# row — but it means the state a replan lands in has to match the exit contract
# of the path the builder will actually take.
#
# A plan sent back to `draft` for a replan keeps its branch and worktree. The
# dispatcher already knows this: lv-list-implementable.sh reports ready+worktree
# as `resume`, not `new`. Writing `ready` anyway put the plan one state below
# where its own builder's exit expected it, so the exit silently no-opped: the
# work was done and committed, the registry still said `ready`, and lv-verify
# then refused to run because it could not match `verify` either. Nothing
# errored loudly; the plan simply stopped moving with completed work on the
# branch.
#
# THE THIRD ANSWER: A BOUNCE WITH NOTHING TO BUILD
#
# A human test files a behavior finding, the plan goes back to `draft`, and the
# replan concludes the finding does not reproduce — the tester was standing in
# the wrong worktree, the criterion was misread, the bug was somebody else's.
# There is now no builder work outstanding, and neither of the two answers
# above fits: `active` dispatches a builder onto an empty work list and re-runs
# a full scoped verify against a tip that already passed it clean. client-a's
# WFI-096 parked at a `needs-input` gate rather than guess, and that gate then
# blocked eight dependent plans until a human authorised `draft → testing` by
# hand — an edge the state machine did not define.
#
# It is defined here, and narrowly. All five must hold:
#   - a live worktree (there is something built to hand back);
#   - the newest findings section is a tester's — `## Human Test`, `## Acceptance`
#     or `## Human Acceptance` (the bounce came
#     from the tester, not from verify — a verify bounce has code to answer);
#   - every finding in the file is checked off (nothing is outstanding);
#   - progress.md's `## Steps` checklist is complete, or absent;
#   - plan.md has gained no amendment since the branch last committed,
#     other than one that declares `**Build:** none` (LVI-038).
# Anything less falls through to the ready/active rules, unchanged.
#
# THE FIFTH CONDITION: THE OTHER FOUR CAN BE SATISFIED BY THE PREVIOUS CYCLE
#
# The first four are all readings of state that a completed build leaves
# behind, and a replan does not reset any of them. client-b' PLN-014
# (WFI-027): the replan's amendments A-1 and A-2 added a per-join participant
# token across nine call sites, two columns on an existing migration, a
# re-entry path and two new tests — none of it written — and this script
# answered `testing`. Every mechanical condition held, because the Steps boxes
# and the Build & Tests boxes had been ticked against the PRE-amendment tree,
# and ticking the two findings the amendments RESOLVED removed the last
# outstanding signal. Ticking a finding an amendment answered is
# indistinguishable from ticking one that did not reproduce — and that
# difference is the whole distance between this script's second answer and its
# third.
#
# So the fifth condition asks the question the other four cannot: did the plan
# grow an amendment that the built tree predates? The anchor is the branch's
# own newest non-merge commit — whatever the builder last wrote — compared
# against the count of amendment headings in plan.md at that moment and now.
# Headings, not diff lines, so a ticked checkbox or a review stamp is not
# mistaken for new work (the WFI-005 lesson). Not lv-goal-delta.sh's
# AMENDMENTS_NEW, though it counts the same headings: that one is a diff
# against HEAD, so it answers "uncommitted", and by the time a replan reaches
# this script lv-spec has already committed the plan.
#
# Where the answer is in doubt it is `active`, deliberately. A builder
# dispatched onto an empty work list costs one run; a tester handed a plan
# whose newest amendments have no implementation is asked to verify something
# that was never built.
#
# --note "text"  Passed straight through to lv-registry-update.sh, which writes
# it to the plan's progress.md under `## Notes`, in the same commit and under
# the same lock as the transition itself.
#
# lv-attend's gate-working rules say: "If the decision changes why the plan is
# where it is, say so with --note". That rule is not scoped to new plans, but
# the replan path had no way to obey it — lv-spec step 7 mandates this script
# for a replan, and this script took only `--apply`. So a replan's reason
# existed solely in the gate resolution ledger, which nobody reading
# progress.md ever sees, and client-d's PLN-005 landed `draft to ready` with
# REGISTRY.md alone (WFI-008). The reason a replan chose its target is exactly
# the kind a later reader cannot reconstruct: the target is derived from the
# worktree and the findings, and none of that survives the branch's deletion.
#
# stdout: the target state.  With --apply, also performs the transition.
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REGISTRY="plans/REGISTRY.md"

raw_id="${1:-}"
apply=false
note=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=true; shift ;;
    --note)  note="${2:?--note requires text}"; shift 2 ;;
    *)       echo "Usage: $0 <$LV_PLN-NNN> [--apply] [--note \"text\"]" >&2; exit 1 ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <$LV_PLN-NNN> [--apply] [--note \"text\"]" >&2; exit 1; }
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

state=$(wf_registry_field "$plan_id" state "$REGISTRY")
[ -n "$state" ] || { echo "Error: $plan_id has no registry row" >&2; exit 1; }

slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
branch=$(wf_registry_field "$plan_id" branch "$REGISTRY")

# Amendment HEADINGS in a plan.md, read from stdin. The id is `A`, an optional
# separator and a number, or the word `Amendment` and a number, optionally
# behind a bracketed date — the three heading styles lv-goal-delta.sh learned
# the hard way (WFI-051, WFI-201, WFI-230). Headings only: a bullet in prose
# that cites A-1 is a reference, not an amendment.
#
# An amendment that declares `**Build:** none` is not counted. A sub-heading
# inside an amendment (`#### A-1.1 …`) belongs to it and shares its
# declaration. A client's PLN-058 A-1 only rewrote two Chrome-Assisted
# criteria on a built, tested plan. lv-spec's gate question said `testing`,
# and this script said `active` because a heading had appeared, so the plan
# was sent through a builder cycle with nothing to build (LVI-038). Only the
# planner knows whether an amendment needs code, so it says so on a line this
# can read. A missing line means "it might", which is the safe default.
amendment_headings() {
  awk '
    function close_block() { if (inb && !bex) total += bcount; inb = 0 }
    /^#+[[:space:]]/ {
      lvl = match($0, /[^#]/) - 1
      if (inb && lvl <= blvl) close_block()
      if ($0 ~ /^#+[[:space:]]*(\[[^]]*\])?[[:space:]]*([^A-Za-z]*A[-_ ]?[0-9]+([^0-9]|$)|[Aa]mendment[[:space:]]+A?[-_ ]?[0-9]+)/) {
        if (!inb) { inb = 1; blvl = lvl; bcount = 0; bex = 0 }
        bcount++
      }
      next
    }
    inb && tolower($0) ~ /^[[:space:]]*\*\*build:?\*\*:?[[:space:]]*none/ { bex = 1 }
    END { close_block(); print total + 0 }
  '
}

target="ready"
if [ -n "$branch" ] && [ "$branch" != "—" ]; then
  if git worktree list --porcelain 2>/dev/null \
     | awk '/^branch /{ sub(/^branch refs\/heads\//, ""); print }' \
     | grep -qx "$branch"; then
    target="active"
  fi
fi

# The headings a tester's findings section is written under. `## Human Test` is
# the original spelling; /lv-test writes `## Acceptance — <date>` and
# /lv-accept `## Human Acceptance — <date>`, and a worker has written
# `## Acceptance Testing — <date>`. Matching only the first meant no bounce from
# either skill could ever be answered with `testing` (a client's LVI-028).
TESTER_HEADS='Human Test|Human Acceptance|Acceptance([ \t]+Testing)?[ \t]*(—|-|$)'

# The bounce-with-nothing-to-build case. Only ever narrows `active` — a plan
# with no worktree has a whole build ahead of it whatever its findings say.
if [ "$target" = "active" ]; then
  plan_dir="plans/${plan_id}-${slug}"
  findings="$plan_dir/findings.md"
  progress="$plan_dir/progress.md"
  plan_md="$plan_dir/plan.md"
  if [ -f "$findings" ] \
     && ! grep -q '^- \[ \]' "$findings" \
     && [ "$(grep -E "^## ($TESTER_HEADS|Verify|Implement|Consistency)" "$findings" \
             | tail -1 | grep -cE "^## ($TESTER_HEADS)")" = "1" ]; then
    steps_open=0
    if [ -f "$progress" ]; then
      steps_open=$(awk '
        /^## Steps/ { inside = 1; next }
        /^## /      { inside = 0 }
        inside && /^- \[ \]/ { n++ }
        END { print n + 0 }
      ' "$progress")
    fi
    # plan.md's own Verification Checklist, EXCLUDING Human Test Criteria —
    # those are the tester's to check off, and that is the whole reason this
    # branch is about to hand the plan back to them. Build & Tests, Code
    # Quality and Regression Scope are the builder's, same as progress.md's
    # Steps checklist above, and an amendment can add an unchecked item to
    # any of them (a plan.md edit, not a findings.md one) without this
    # narrowing ever seeing it — client-e's PLN-104 routed draft -> testing
    # with Amendment A-1's new Code Quality item still unchecked (WFI-021).
    plan_open=0
    if [ -f "$plan_md" ]; then
      plan_open=$(awk '
        /^## Verification Checklist/ { inside = 1; next }
        /^## / && inside          { inside = 0 }
        inside && /^### Human Test Criteria/ { human = 1; next }
        inside && /^### /         { human = 0 }
        inside && !human && /^- \[ \]/ { n++ }
        END { print n + 0 }
      ' "$plan_md")
    fi
    # Amendments the built tree predates — see THE FIFTH CONDITION above.
    # `--no-merges` so a develop merge into the branch does not read as build
    # work; `@<epoch>` is a date git's approxidate parser accepts.
    amend_new=0
    if [ -f "$plan_md" ]; then
      tip_ct=$(git log -1 --no-merges --format=%ct "$branch" 2>/dev/null || true)
      if [ -n "$tip_ct" ]; then
        was_sha=$(git rev-list -1 --before="@$tip_ct" HEAD -- "$plan_md" 2>/dev/null || true)
        now_n=$(amendment_headings < "$plan_md")
        was_n=0
        if [ -n "$was_sha" ]; then
          was_n=$(git show "$was_sha:$plan_md" 2>/dev/null | amendment_headings || true)
        fi
        if [ "${now_n:-0}" -gt "${was_n:-0}" ]; then
          amend_new=$(( now_n - was_n ))
        fi
      fi
    fi
    if [ "$amend_new" != "0" ]; then
      echo "$plan_id: $amend_new amendment(s) added since $branch last committed — there is" >&2
      echo "  work outstanding, so this is not a bounce with nothing to build (WFI-027)." >&2
    elif [ "$steps_open" = "0" ] && [ "$plan_open" = "0" ]; then
      target="testing"
    fi
  fi
fi

printf '%s\n' "$target"

if $apply; then
  if [ "$state" = "$target" ]; then
    echo "$plan_id is already $target — nothing to do" >&2
    exit 0
  fi

  # ── A gate-tagged plan does not leave draft on a stale approval ─────────
  #
  # lv-spec's new-plan exit states the rule plainly: "GATE_STALE=true -> the
  # plan changed after the approval. Gate again." The Replanning path had no
  # such check anywhere — its only gate is lv-goal-delta.sh, which asks whether
  # scope SHRANK — and this script is what it calls to move the plan.
  #
  # client-a's PLN-110 (WFI-178): tagged `contract`, the project's sole
  # gateTag. A replan widened Step 10 from 2 documents to 10 and added a test,
  # then reached here and was transitioned draft -> ready and committed.
  # Immediately afterwards lv-gate-status.sh reported GATE_ANSWERED=false,
  # GATE_STALE=true — so a plan whose approved scope had materially widened sat
  # `ready` and dispatchable, and the correction meant reverting a transition a
  # script had already committed, which is exactly the judgement call the
  # unattended rules exist to avoid.
  #
  # lv-registry-update.sh's own guard could not catch it: it refuses
  # draft -> ready without a review OF RECORD, and a fresh review of record
  # existed. The review says the plan is sound. The gate asks whether a human
  # accepts what it now promises. They are different questions.
  #
  # Refusal rather than silent gating: this script does not know the question
  # text, and a gate opened with a machine-written one is how a human ends up
  # answering something they were never asked (WFI-182). The caller opens it.
  # Self-clearing — once the human's answer is recorded the check passes.
  if [ "$target" = "ready" ] || [ "$target" = "active" ]; then
    tags=$(wf_registry_field "$plan_id" tags "$REGISTRY")
    gating=$("$SELF_DIR/lv-list-tags.sh" --gating 2>/dev/null || true)
    hit=""
    if [ -n "$gating" ] && [ -n "$tags" ] && [ "$tags" != "—" ]; then
      for t in $(printf '%s' "$tags" | tr ',' ' '); do
        printf '%s\n' "$gating" | grep -qx "$t" && { hit="$t"; break; }
      done
    fi
    why_gated="carries the gating tag '$hit'"
    # specApproval.mode=gate gates every plan, tagged or not: a spec may be
    # written unattended but never approved unattended. The check above only
    # read tags, so in gate mode an untagged plan with no spec-approval of
    # record went straight to ready on a replan (LVI-035).
    if [ -z "$hit" ] && [ "$(wf_cfg specApproval.mode verdict)" = "gate" ]; then
      hit="specApproval.mode=gate"
      why_gated="is in a project with specApproval.mode=gate"
    fi
    # The express lane answers this approval when a human accepted the gating
    # tag with `lv-lane.sh check --accept-warnings` and the AMENDED plan still
    # passes — status re-checks the text as it now reads, so a replan that
    # widened scope past the limits is refused here like any other (LVI-025).
    LANE=none
    if [ -n "$hit" ]; then
      eval "$("$SELF_DIR/lv-lane.sh" status "$plan_id" 2>/dev/null || true)"
    fi
    if [ -n "$hit" ] && [ "$LANE" = express ]; then
      echo "$plan_id $why_gated; the express lane answers its spec-approval (accepted: ${LANE_ACCEPTED:-—})." >&2
    elif [ -n "$hit" ]; then
      eval "$("$SELF_DIR/lv-gate-status.sh" "$plan_id" spec-approval 2>/dev/null || true)"
      if [ "${GATE_ANSWERED:-false}" != "true" ] || [ "${GATE_STALE:-false}" = "true" ]; then
        why="unanswered"
        [ "${GATE_STALE:-false}" = "true" ] && why="stale — the plan changed after it"
        echo "Error: $plan_id $why_gated, and its spec-approval is $why." >&2
        echo "  Not transitioning $state -> $target. The plan changed after the approval, so the" >&2
        echo "  approval is for a document that no longer says what it said (WFI-178)." >&2
        echo "  Open spec-approval with the amended scope in the question, then run this again:" >&2
        echo "    lv-gate-open.sh $plan_id spec-approval \"<what changed> — approve?\" --skill lv-spec" >&2
        exit 2
      fi
    fi
  fi

  update_args=("$plan_id" "$state" "$target")
  [ -n "$note" ] && update_args+=(--note "$note")
  "$SELF_DIR/lv-registry-update.sh" "${update_args[@]}"
fi
