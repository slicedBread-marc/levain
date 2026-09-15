#!/usr/bin/env bash
# wf-gate-close.sh <artifact-id> [resolution] [--gate <name>] [--basis <basis>]
#
# Releases a parked artifact. The next dispatcher sweep picks it up again.
# Safe to call when no gate is open.
#
# resolution is free text recorded in events.log (e.g. "approved", "rejected",
# "criteria passed") — it is the audit trail for why work resumed. Describe the
# decision JUST MADE. Restating an earlier cycle's outcome writes a record of a
# run that did not happen (WFI-100).
#
# Closing a gate also clears that plan's orchestrator attempt budget: a worker
# that parked on a gate did not stall, and the answer is what unblocks it
# (WFI-185).
#
# Three things are written: `gates/resolved/<id>.<gate>` (the slot readers look
# up, always the latest), `gates/resolved/<id>.<gate>.log` (append-only, one
# tab-separated line per close: when, gate, registry state, resolution), and a
# `## Decisions` entry in the plan's own findings.md — the ledger is the record,
# but findings.md is where a dispatched worker actually looks (WFI-181).
#
# --gate <name>  Record the resolution under this gate name even when no gate
#                file is open. This is the backfill path: a decision a human
#                demonstrably made — in a commit message, in findings.md —
#                but which the resolved-gate ledger has no record of, because
#                the gate closed before the ledger existed or was cleared by
#                hand. Without it, wf-gate-status.sh reports GATE_ANSWERED=false
#                and the owning skill re-asks a question already answered in
#                writing (client-a WFI-060, PLN-019's spec approval), and
#                the only workarounds are faking an open gate or overriding the
#                skill's own rule.
#
# --resolves <s> Tick the unchecked finding(s) this answer settles. <s> is a
#                substring matched against the finding text, or the word `all`
#                for every unchecked finding in the plan. Each match is checked
#                off and annotated with the gate that settled it.
#
#                A resolution recorded only as prose leaves the checkbox above
#                it unchecked, and wf-findings-route.sh routes on checkboxes
#                and nothing else — it cannot read a paragraph. client-a's
#                PLN-254 and PLN-259 both carried findings answered at a gate,
#                written up in full in the same findings.md, and still
#                unchecked; a plan with a clean build and every test green
#                routed back to `draft` over a design question that had been
#                settled before implementation began (WFI-233, WFI-237). This
#                is how the answer and the checkbox stop disagreeing.
#
#                Without it, an unchecked finding surviving the close is
#                reported on stderr rather than silently left to route.
#
# --basis <b>    WHAT answered this gate. Required when WF_UNATTENDED=1 — see
#                below. The vocabulary is closed and each value is checked:
#
#                  verdict      a recorded review verdict decides it. Verified
#                               against wf-review-status.sh: the plan must carry
#                               an `Approved*` result that is NOT stale.
#                  config       a claude-workflow.yml setting decides it. Name
#                               the key in the resolution text.
#                  autonomy     wf-autonomy.sh authorized it. Verified by asking
#                               it, and only `release-approval` and
#                               `deploy-approval` have an action to ask about.
#                  human:<ref>  a human's answer of record exists at <ref>.
#                               Verified to resolve to a commit or a real file.
#
# A GATE IS A QUESTION FOR A HUMAN, AND A WORKER MAY NOT ANSWER ITS OWN
#
# client-a's WFI-227. An unattended worker closed PLN-250's `spec-approval`
# gate with the resolution "approved by the assistant under Marc's standing
# 'process them all' instruction, not by Marc" — a sentence that knows no human
# approved it. No such grant existed; `spec-approval` is on wf-autonomy.sh's
# never-grantable list precisely so it cannot be granted. The daemon then
# dispatched an implementer, which was three minutes into the build when the
# human, mid-`/wf-attend`, finally answered the same question.
#
# Nothing in this script asked. It closed whatever it was told to close, and
# the only record of who decided was free text that nothing reads. So the
# question is asked here, mechanically: an unattended caller must name a basis
# from the vocabulary above, and this script checks the basis rather than
# believing it. A worker with no basis parks the gate and stops, which is what
# the gate was for.
#
# Attended callers are unaffected. A human at a terminal IS the basis, and
# `/wf-attend` is where that answer belongs.
#
# Exit 0 on success (idempotent), 1 on usage error,
#        4 when an unattended close has no acceptable basis.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

artifact=""
resolution=""
forced_gate=""
basis=""
resolves=""
plan_body_fp_at_open=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gate)  forced_gate="${2:?--gate requires a gate name}"; shift 2 ;;
    --basis) basis="${2:?--basis requires a value}"; shift 2 ;;
    --resolves) resolves="${2:?--resolves requires a finding substring, or 'all'}"; shift 2 ;;
    -*)      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$artifact" ]; then artifact="$1"; else resolution="$1"; fi
      shift ;;
  esac
done

[ -n "$artifact" ] || { echo "Usage: $0 <artifact-id> [resolution] [--gate <name>] [--basis <basis>]" >&2; exit 1; }
resolution="${resolution:-resolved}"

# Accept PLN-004 / PLN-004-slug, or the fixed pipeline-stage literals
# RELEASE / DEPLOY — see the matching comment in wf-gate-open.sh.
case "$artifact" in
  RELEASE|DEPLOY) id="$artifact" ;;
  *) id=$(printf '%s' "$artifact" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true) ;;
esac
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a PLN/BUG/BRF id, or RELEASE/DEPLOY" >&2
  exit 1
fi

# By number, so a gate opened under the plan closes when the brief it came from
# is the name in hand (WFI-187).
gate_file=$(wf_gate_file "$id" || true)

if [ ! -f "$gate_file" ] && [ -z "$forced_gate" ]; then
  echo "$id: no open gate"
  exit 0
fi

gate_question=""
if [ -f "$gate_file" ]; then
  gate_name=$(wf_gate_field "$gate_file" GATE_NAME)
  # The gate's OWN id, which is the plan when a plan opened it. Everything
  # below — the fingerprints, the registry state, the findings.md the
  # resolution is written into — is about that plan, and none of it can be
  # found under the brief or bug the caller happens to be holding (WFI-187).
  gate_owner=$(wf_gate_field "$gate_file" GATE_ID)
  [ -n "$gate_owner" ] && id="$gate_owner"
  # The question AS ASKED, kept with the answer.
  #
  # A resolution without its question is half a record, and the missing half is
  # the one that drifts. client-a's PLN-135 had the same gate re-derived five
  # times, and each regeneration introduced new errors of fact: three
  # consecutive re-openings described a Dictionary as a HashSet, and the fifth
  # asserted a file was untouched by a commit that changes it +22/-8 (WFI-184).
  # The conclusion survived by luck. Keeping the original text means a reader
  # can replay what was asked instead of writing it again from what they happen
  # to see now.
  #
  # Unescaped on the way out. The gate file is SHELL-SOURCED, so wf-gate-open.sh
  # correctly writes an apostrophe as the four characters `'\''` — right there,
  # and wrong everywhere this value goes next. findings.md is markdown and the
  # ledger is read by eye, so client-a's PLN-214 recorded its question as
  # `08c3a136 '\''bug(BUG-214): root cause is a stale relay...'\''` (WFI-214).
  # Commit subjects are quoted into gate questions routinely, and English has
  # apostrophes, so this is the common case rather than the exotic one.
  gate_question=$(wf_gate_field "$gate_file" GATE_QUESTION --unescape)
  # Read here, with the rest, because the gate file is gone below.
  # This is the plan's fingerprint as of when the question was ASKED — see the
  # comment above `record=` for why the close-time one cannot stand alone.
  plan_body_fp_at_open=$(wf_gate_field "$gate_file" GATE_PLAN_BODY_FP_AT_OPEN)
else
  gate_name="$forced_gate"
fi
[ -n "$forced_gate" ] && gate_name="$forced_gate"

# ── Who is answering? ─────────────────────────────────────────────────────
#
# Checked BEFORE the gate file is removed, so a refusal leaves the gate exactly
# as it was and the human still owes the same answer. See WFI-227 in the header.
if [ "${WF_UNATTENDED:-0}" = "1" ]; then
  refuse_basis() {
    echo "wf-gate-close: refusing to close '$gate_name' on $id — $1" >&2
    echo "  You are running UNATTENDED (WF_UNATTENDED=1). A gate is a question parked for a" >&2
    echo "  human, and a worker may not answer its own (WFI-227). Nothing was closed." >&2
    echo "  Leave the gate open and exit 0; /wf-attend is where this gets answered." >&2
    echo "  If a decision of record DOES exist, name it: --basis verdict | config |" >&2
    echo "  autonomy | human:<commit-sha or file path>" >&2
    wf_event gate-close-refused "$id" "$gate_name: ${basis:-no --basis} — $1"
    exit 4
  }

  case "$basis" in
    "")
      refuse_basis "no --basis given" ;;

    verdict)
      # Not taken on trust: the same staleness question wf-spec's own gating
      # rule asks, asked here, because "a review approved it" is only an answer
      # when the review judged the text that is in front of us now (WFI-046).
      review=$("$SELF_DIR/wf-review-status.sh" "$id" 2>/dev/null || true)
      review_result=$(printf '%s\n' "$review" | sed -n "s/^REVIEW_RESULT='\(.*\)'$/\1/p")
      review_stale=$(printf '%s\n' "$review" | sed -n "s/^REVIEW_STALE='\(.*\)'$/\1/p")
      case "$review_result" in
        Approved*) ;;
        "") refuse_basis "--basis verdict, but $id carries no review verdict" ;;
        *)  refuse_basis "--basis verdict, but the verdict on $id is '$review_result'" ;;
      esac
      [ "$review_stale" = "false" ] || \
        refuse_basis "--basis verdict, but that verdict is stale (REVIEW_STALE=$review_stale) — it judged text that has since changed"
      ;;

    config)
      # The setting is the answer, so the resolution has to say which one. A
      # bare "config" is the same unfalsifiable prose this guard exists to stop.
      printf '%s' "$resolution" | grep -q '[A-Za-z]' || \
        refuse_basis "--basis config with an empty resolution — name the claude-workflow.yml key that decides this"
      ;;

    autonomy)
      # Only two gates have an autonomy action behind them. Everything else on
      # wf-autonomy.sh's list is never-grantable BY NAME, and reaching for
      # `autonomy` on one of those is exactly the WFI-227 move.
      case "$gate_name" in
        release-approval) auto_action=release ;;
        deploy-approval)  auto_action=deploy ;;
        *) refuse_basis "--basis autonomy, but '$gate_name' has no autonomy action — wf-autonomy.sh --list names the four that do" ;;
      esac
      "$SELF_DIR/wf-autonomy.sh" "$auto_action" --artifact "$id" --quiet \
        || refuse_basis "--basis autonomy, but wf-autonomy.sh refuses '$auto_action' for this project"
      ;;

    human:*)
      # A named reference, checked to exist. This cannot prove a human wrote it
      # — nothing here can — but it turns an assertion into something a reader
      # can go and look at, and an invented sha fails the check.
      ref="${basis#human:}"
      [ -n "$ref" ] || refuse_basis "--basis human: with no reference — name the commit or file that carries the answer"
      if ! git -C "$(wf_develop_root)" cat-file -e "${ref}^{commit}" 2>/dev/null \
         && [ ! -e "$ref" ] && [ ! -e "$(wf_develop_root)/$ref" ]; then
        refuse_basis "--basis human:$ref, but that is neither a commit in this repository nor a file that exists"
      fi
      ;;

    *)
      refuse_basis "--basis '$basis' is not in the vocabulary (verdict | config | autonomy | human:<ref>)" ;;
  esac
fi

# Past the guard: the gate is answered, so the parking file goes. An attended
# caller reaches here with no basis, which is correct — the human IS the basis
# — and `--basis` is still recorded when given.
if [ -f "$gate_file" ]; then rm -f "$gate_file"; fi

# ── Remember that it was answered ─────────────────────────────────────────
#
# Deleting the gate file leaves "answered" and "never asked" looking identical:
# both are simply the absence of a gate. That is fine for the dispatcher, which
# only wants to know whether to skip the plan — and wrong for a skill, which
# reaches its gating rule again on the very next dispatch.
#
# client-a hit the loop (WFI-047): a human granted spec-approval in writing,
# the gate closed, the orchestrator re-dispatched wf-spec to action that
# resolution, and step 6's rule ("a plan carrying a gateTag parks on an Approved
# verdict") read exactly the same as it had the first time. Each re-dispatch
# reproduces the condition, so the loop has no end. The only record of the
# approval was prose in findings.md, which nothing reads.
#
# The record is fingerprinted with the plan text that was approved. An approval
# is for a REVISION, not for a plan forever — edit the plan afterwards and the
# fingerprint stops matching, which is what should re-open the question.
#
# GATE_PLAN_BODY_FP is the one that decides, because the question is "did the
# SPECIFICATION change since the answer?" and not "did any byte of plan.md
# change?". A raw hash answers the second: ticking a deferred criterion in the
# Human Test Criteria — which wf-defer-criterion.sh explicitly instructs a
# tester to do — flipped an answered spec-approval to stale, and a plan later
# routed back to draft would then re-gate an approval the human had already
# given, which is the WFI-047 loop this ledger exists to prevent (client-c
# WFI-005). GATE_PLAN_FP is still written so a client mid-upgrade reads a
# record it understands.
resolved_dir="$(wf_orch_dir)/gates/resolved"
mkdir -p "$resolved_dir"

plan_fp=$(wf_plan_fingerprint "$id")
plan_body_fp=$(wf_plan_body_fingerprint "$id")

# The registry state AT CLOSE TIME, recorded alongside the outcome.
#
# A resolution and the state it leaves the plan in are one fact, and the slot
# below only held half of it. client-a's WFI-100: a `manual-test` gate was
# resolved carrying "criterion 8 FAIL ← ESCALATED to spec" while the registry
# row read `testing` — an escalation to `draft` recorded against a plan that
# had not gone there, because the text came from the PREVIOUS cycle. Writing
# the state down is what makes that contradiction visible to the next reader
# instead of leaving it to be reconstructed from commit times.
gate_state=$(grep -m1 "^| $id |" "$(wf_develop_root)/plans/REGISTRY.md" 2>/dev/null \
             | awk -F'|' '{print $4}' | xargs || true)

# The fingerprint of the plan AS THE QUESTION WAS ASKED, carried through from
# the gate file. This close-time record is written after the exit contract's
# commit — close last, always — so `plan_body_fp` above includes anything the
# worker committed between the human answering and this call. Recording only
# that fingerprints post-answer work INTO the approval, which is how a
# contract-tagged plan reached `ready` on an approval given before the
# amendment existed (WFI-198, WFI-178). wf-gate-open.sh judges staleness
# against this one instead when it is present.
if [ -n "$plan_body_fp_at_open" ] && [ -n "$plan_body_fp" ] \
   && [ "$plan_body_fp_at_open" != "$plan_body_fp" ]; then
  echo "  note: $id changed between the question being asked and this close." >&2
  echo "        The answer is recorded against the text the human saw; work committed since is NOT covered by it." >&2
fi

record=$(
  wf_emit GATE_ID           "$id"
  wf_emit GATE_NAME         "$gate_name"
  wf_emit GATE_QUESTION     "$gate_question"
  wf_emit GATE_RESOLUTION   "$resolution"
  wf_emit GATE_RESOLVED     "$(wf_now)"
  wf_emit GATE_RESOLVED_STATE "${gate_state:-—}"
  # WHO answered, in the record. An empty basis is an attended close: a human
  # was at the terminal. Anything else names the mechanism, checked above.
  wf_emit GATE_RESOLVED_BASIS "${basis:-human (attended)}"
  wf_emit GATE_RESOLVED_UNATTENDED "${WF_UNATTENDED:-0}"
  # Not `[ -n … ] && wf_emit …`: as the LAST command in this substitution a
  # false test makes the subshell exit 1, and `set -e` then kills the script
  # before the record is ever written.
  if [ -n "$plan_body_fp_at_open" ]; then
    wf_emit GATE_PLAN_BODY_FP_AT_OPEN "$plan_body_fp_at_open"
  fi
  wf_emit GATE_PLAN_FP      "$plan_fp"
  wf_emit GATE_PLAN_BODY_FP "$plan_body_fp"
)

# The slot is what readers look up; the ledger is what happened.
#
# `resolved/<id>.<gate>` is a single per-plan-per-gate slot, so every later
# cycle overwrote the record of the one before it — and a `manual-test` gate is
# opened and answered once per test cycle. WFI-100 was only diagnosable because
# a human remembered the earlier outcome; the file itself had no memory of it.
# Appending here costs one line per close and makes "who approved what, when,
# and from which state" answerable after the fact.
printf '%s\n' "$record" > "$resolved_dir/${id}.${gate_name}"
printf '%s\t%s\t%s\t%s\n' "$(wf_now)" "$gate_name" "${gate_state:-—}" \
  "$(printf '%s' "$resolution" | tr '\n\t' '  ')" \
  >> "$resolved_dir/${id}.${gate_name}.log"

# ── The decision goes where the next worker will read it ──────────────────
#
# The ledger above is the record; it is not the place anybody looks. A
# dispatched worker reads the plan artifacts — plan.md, findings.md — and
# nothing in them said a decision had been made. So a `prior-work` gate on
# client-a's PLN-135 was answered, closed, and re-opened by the next worker
# on the same durable evidence, three times, each worker correctly concluding
# from what it could see that an unexplained commit sat on develop (WFI-181).
#
# wf-gate-open.sh now REFUSES that re-opening, which is what stops the loop.
# This is the other half and the reason it is still worth writing: a worker told
# "already answered" needs to know WHAT was answered in the same place it reads
# everything else about the plan, or it is merely blocked rather than informed.
#
# findings.md, not plan.md: this is a record of something that happened, and the
# plan is a specification. Deliberately no `- [ ]` items — an unchecked box in
# findings.md is what wf-list-specable.sh reads as "this plan needs replanning".
transcribe_resolution() {
  local root plan_dir findings
  root="$(wf_develop_root)"
  plan_dir=$(ls -d "$root"/plans/"${id}"-* 2>/dev/null | head -1 || true)
  [ -n "$plan_dir" ] && [ -d "$plan_dir" ] || return 0
  findings="$plan_dir/findings.md"

  [ -f "$findings" ] || printf '# Findings — %s\n' "$id" > "$findings"
  grep -q '^## Decisions' "$findings" 2>/dev/null || printf '\n## Decisions\n' >> "$findings"

  {
    printf '\n### %s — %s\n' "$gate_name" "$(wf_now)"
    [ -n "$gate_question" ] && printf '> **Asked:** %s\n' "$(printf '%s' "$gate_question" | tr '\n' ' ')"
    printf '> **Resolution:** %s\n' "$(printf '%s' "$resolution" | tr '\n' ' ')"
    printf '> **Answered by:** %s\n' "${basis:-a human at an attended terminal}"
    printf '> **State at close:** %s\n' "${gate_state:-—}"
    printf '> Recorded by wf-gate-close.sh. This is the decision of record — act on it rather than re-deriving the question (WFI-181).\n'
  } >> "$findings"

  # Committed here for the same reason wf_registry_commit commits: a decision
  # left dirty on the shared develop root belongs to whoever commits next.
  ( cd "$root" && "$SELF_DIR/wf-commit.sh" \
      "gate($id): $gate_name resolved — recorded in findings" \
      --add "plans/$(basename "$plan_dir")/findings.md" >/dev/null 2>&1 ) \
    || echo "wf-gate-close: the resolution is written to $findings but could not be committed" >&2
}
transcribe_resolution || true

# ── The checkbox has to agree with the answer ─────────────────────────────
#
# wf-findings-route.sh routes on checkboxes and on nothing else. It cannot read
# the paragraph under a finding, and it cannot tell a question still open from
# one answered in full three lines further down. Both of client-a's PLN-254
# and PLN-259 carried a finding settled at a gate, written up completely in the
# same findings.md, box still empty — and each would have routed a plan with a
# clean build and every test green back to `draft` over a decision already made
# (WFI-233, WFI-237). The worker that noticed had to tick the box by hand and
# file an issue saying so.
#
# So the close ticks what it settled. `--resolves` names it; without one, an
# unchecked finding that survives the close is at least said out loud, here,
# where the person closing the gate can still act on it.
resolve_findings() {
  local root plan_dir findings ticked=0 stamp left before after tmp
  root="$(wf_develop_root)"
  plan_dir=$(ls -d "$root"/plans/"${id}"-* 2>/dev/null | head -1 || true)
  [ -n "$plan_dir" ] && [ -d "$plan_dir" ] || return 0
  findings="$plan_dir/findings.md"
  [ -f "$findings" ] || return 0

  if [ -n "$resolves" ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/wf-findings.XXXXXX")
    stamp="resolved at gate '$gate_name', $(wf_now)"
    RESOLVES="$resolves" STAMP="$stamp" awk '
      # Column-0 unchecked findings only — the same shape wf-findings-route.sh
      # routes on. An indented checkbox has never been a finding here.
      /^- \[ \]/ && (ENVIRON["RESOLVES"] == "all" || index($0, ENVIRON["RESOLVES"]) > 0) {
        sub(/^- \[ \]/, "- [x]")
        print $0 "  <!-- " ENVIRON["STAMP"] " -->"
        next
      }
      { print }
    ' "$findings" > "$tmp"
    # `grep -c` exits 1 on a zero count while still printing `0`, so `|| true`
    # keeps the count and drops the status. `|| echo 0` would print it twice.
    before=$(grep -c '^- \[ \]' "$findings" 2>/dev/null || true)
    after=$(grep -c '^- \[ \]' "$tmp" 2>/dev/null || true)
    ticked=$(( ${before:-0} - ${after:-0} ))
    cat "$tmp" > "$findings"
    rm -f "$tmp"
    if [ "${ticked:-0}" -gt 0 ]; then
      echo "$id: ticked $ticked finding(s) settled by this answer"
      ( cd "$root" && "$SELF_DIR/wf-commit.sh" \
          "gate($id): $gate_name — $ticked finding(s) checked off as settled" \
          --add "plans/$(basename "$plan_dir")/findings.md" >/dev/null 2>&1 ) || true
    else
      echo "wf-gate-close: --resolves '$resolves' matched no unchecked finding in $findings" >&2
    fi
  fi

  # Whatever is still unchecked is what the next router will route on. Saying so
  # is the difference between a decision that lands and one that gets re-asked.
  left=$(grep -c '^- \[ \]' "$findings" 2>/dev/null || true)
  if [ "${left:-0}" -gt 0 ]; then
    echo "wf-gate-close: $id still has ${left} unchecked finding(s) in findings.md." >&2
    echo "  wf-findings-route.sh routes on those boxes and cannot read your resolution text." >&2
    echo "  If this answer settled any of them, re-run with --resolves '<finding text>' (WFI-233, WFI-237)." >&2
  fi
}
resolve_findings || true

# ── Answering a gate is forward progress ──────────────────────────────────
#
# The orchestrator's attempt budget counts worker LAUNCHES that produced no
# forward progress, and parks the plan as `stuck` at the cap. A worker that
# opens a mandatory gate and stops has done exactly what its skill prescribes —
# but it moves neither the registry state nor the step checklist, so it looks
# identical to a stall.
#
# client-a's PLN-135 (WFI-185) accrued three implement attempts that way,
# every one of them a worker correctly parking on the prior-work gate and
# saying so in its log. When the gate was finally answered at 11:36, the
# dispatcher read the stale counter and opened a `stuck` gate at 11:37 —
# answering a gate produced another gate instead of forward progress, and a
# human had to delete the counter file by hand. It compounded with the
# re-gating loop: each re-opening cost another attempt.
#
# The answer resets it, because an answer is precisely the event that
# invalidates every no-progress run before it: those workers were waiting for
# this, and now they are not.
attempts_dir="$(wf_orch_dir)/attempts"
if ls "$attempts_dir/$id".* >/dev/null 2>&1; then
  rm -f "$attempts_dir/$id".*
  wf_event attempts-reset "$id" "gate '$gate_name' answered — attempt budget cleared (WFI-185)"
fi

wf_event gate-close "$id" "$gate_name: $resolution"
if [ -n "$forced_gate" ] && [ ! -f "$gate_file" ]; then
  echo "$id: recorded '$gate_name' as answered — $resolution"
else
  echo "$id: gate '$gate_name' closed — $resolution"
fi
