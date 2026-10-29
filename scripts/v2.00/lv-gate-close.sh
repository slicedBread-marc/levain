#!/usr/bin/env bash
# lv-gate-close.sh <artifact-id> [resolution] [--gate <name>] [--only <name>]
#                  [--basis <basis>]
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
# --gate <name>  Record the resolution under this gate name when no gate file
#                is open. A DIFFERENT gate being open is a refusal (exit 5),
#                never an overwrite (WFI-025). This is the backfill path: a
#                decision a human
#                demonstrably made — in a commit message, in findings.md —
#                but which the resolved-gate ledger has no record of, because
#                the gate closed before the ledger existed or was cleared by
#                hand. Without it, lv-gate-status.sh reports GATE_ANSWERED=false
#                and the owning skill re-asks a question already answered in
#                writing (client-a WFI-060, PLN-019's spec approval), and
#                the only workarounds are faking an open gate or overriding the
#                skill's own rule.
#
# --only <name>  Close the open gate ONLY if it is this one. A different gate
#                open is a refusal (exit 5), and no gate open is a no-op — it
#                never backfills, which is what separates it from --gate.
#
#                Without it, this script closes whatever is open, and a skill
#                that means "close MY gate" says exactly the same thing as
#                "close anything". client-b' PLN-010: an attended /lv-test
#                held the claim, an unattended worker opened a `needs-input`
#                gate on the plan asking about a test account, and the tester's
#                exit ran `lv-gate-close.sh PLN-010 "manual test found 1
#                issue(s)"`. That closed the needs-input gate and recorded the
#                test-exit message as the answer to a question about test
#                credentials — a wrong decision of record, in the ledger, that
#                had to be corrected by an appended note (WFI-010).
#
#                A gate is a question, and answering the wrong one is worse
#                than answering none: the question disappears and the record
#                says a human settled it.
#
# --resolves <s> Tick the unchecked finding(s) this answer settles. <s> is a
#                substring matched against the finding text, or the word `all`
#                for every unchecked finding in the plan. Each match is checked
#                off and annotated with the gate that settled it.
#
#                A resolution recorded only as prose leaves the checkbox above
#                it unchecked, and lv-findings-route.sh routes on checkboxes
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
# --decision <d> `approve` or `reject` — the ANSWER, as a value rather than as
#                prose. Only the promotion gates (`release-approval`,
#                `deploy-approval`, `deploy-deferred-criteria`,
#                `production-push`) read it,
#                and for those it is what makes the answer act.
#
#                A resolution is free text, and free text is the one thing no
#                later worker can act on: client-b WFI-005 had a human approve
#                a release twice through /lv-attend, and both times the next
#                unattended /lv-release asked lv-autonomy.sh (which knows only
#                about STANDING grants, not about this answer), was told no, and
#                re-opened the gate it had just been let through. The approval
#                had nowhere to live. `--decision approve` is where it lives:
#                lv-promote-approval.sh reads it back, scoped to the commit set
#                it was given for, and the unattended run proceeds on it.
#
#                Omitting it on a promotion gate closes the gate and records the
#                prose, exactly as before — and authorizes nothing, so the next
#                dispatch asks again. Fail closed: an unrecorded decision is not
#                an approval.
#
#                An `approve` on a promotion gate is checked against the ref
#                ITSELF before it is recorded — see THE BATCH MOVED below.
#
# --express     With `--decision approve` on `spec-approval`: also accept every
#                warning that downgraded the plan's declared express lane, as
#                the person answering (`lv-lane.sh check --accept-warnings`).
#                Attended only. See the block just before the gate file is removed.
#
# --batch-moved-ok
#                Record an `approve` against the CURRENT tip even though the
#                gate was opened against an older one. Only for a caller that
#                has re-derived the batch from the remote refs and is answering
#                about what is actually there — `/lv-attend` does this, and says
#                so in the resolution. Never a way to get past the refusal
#                without looking.
#
# THE BATCH MOVED
#
# A promotion approval is scoped to a commit set: same tip, same promotion. The
# tip is stamped at open, and lv-promote-approval.sh compares it to the tip in
# front of the next worker. When they disagree the answer is discarded and the
# gate re-opens — correct when commits genuinely landed in between, and a trap
# when the gate was opened against a tip that was never current.
#
# client-a WFI-264 is the trap. The gate stamped a four-hour-stale
# origin/release (nothing on the open path fetched, so PR #220's merge was
# invisible), a human approved it, /lv-deploy fetched, the mismatch discarded
# the answer, and the same question re-opened 41 seconds later under the same
# headline — indistinguishable, to the human, from the by-design case. They
# answered the identical question twice.
#
# wf_promote_fetch on the open path closes the hole. This is the second half:
# when an `approve` arrives for a tip that has moved SINCE the question was
# asked, say so HERE — to the person standing at the terminal who can still do
# something about it — rather than recording an approval that is already dead
# and letting a worker discard it silently a minute later. Exit 5, gate left
# exactly as it was.
#
# --basis <b>    WHAT answered this gate. Required when LV_UNATTENDED=1 — see
#                below. The vocabulary is closed and each value is checked:
#
#                  verdict      a recorded review verdict decides it. Verified
#                               against lv-review-status.sh: the plan must carry
#                               an `Approved*` result that is NOT stale.
#                  config       a levain.yml setting decides it. Name
#                               the key in the resolution text.
#                  autonomy     lv-autonomy.sh authorized it. Verified by asking
#                               it, and only `release-approval` and
#                               `deploy-approval` have an action to ask about.
#                  human:<ref>  a human's answer of record exists at <ref>.
#                               Verified to resolve to a commit or a real file.
#                  pre-launch   the project is pre-launch and this gate is one a
#                               worker's recommendation answers there
#                               (wf_self_answers, a client's LVI-034). Verified by
#                               asking it. lv-gate-open.sh --recommend is the
#                               caller; a human checks the answer at the end
#                               state (lv-end-state.sh), not here.
#
# A GATE IS A QUESTION FOR A HUMAN, AND A WORKER MAY NOT ANSWER ITS OWN
#
# client-a's WFI-227. An unattended worker closed PLN-250's `spec-approval`
# gate with the resolution "approved by the assistant under Marc's standing
# 'process them all' instruction, not by Marc" — a sentence that knows no human
# approved it. No such grant existed; `spec-approval` is on lv-autonomy.sh's
# never-grantable list precisely so it cannot be granted. The daemon then
# dispatched an implementer, which was three minutes into the build when the
# human, mid-`/lv-attend`, finally answered the same question.
#
# Nothing in this script asked. It closed whatever it was told to close, and
# the only record of who decided was free text that nothing reads. So the
# question is asked here, mechanically: an unattended caller must name a basis
# from the vocabulary above, and this script checks the basis rather than
# believing it. A worker with no basis parks the gate and stops, which is what
# the gate was for.
#
# Attended callers are unaffected. A human at a terminal IS the basis, and
# `/lv-attend` is where that answer belongs.
#
# --withdraw    The question is MOOT, not answered: what it asked about has
#                moved underneath it (LVI-033). A plan at spec-approval whose
#                upstream plan was re-decided, or which a directive changed, is
#                asking a human to approve a document that no longer covers
#                the decision. The gate goes, and the record says WITHDRAWN:
#                lv-gate-status.sh reports GATE_ANSWERED=false and
#                GATE_WITHDRAWN=true for it, so it can never be read back as an
#                approval, and the resolution text (why it was withdrawn) is
#                what the next /lv-spec reads as its brief. Needs an open gate;
#                never a backfill, never with --decision. No --basis is needed
#                unattended, because nothing is being decided.
#
# Exit 0 on success (idempotent), 1 on usage error,
#        4 when an unattended close has no acceptable basis,
#        5 when an `approve` names a batch the source ref has moved past,
#        6 when a --decision is given and no gate is open to take it.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

artifact=""
resolution=""
forced_gate=""
only_gate=""
basis=""
resolves=""
plan_body_fp_at_open=""
promote_tip=""
covers_push=""
decision=""
batch_moved_ok=false
withdraw=false
express=false
plan_context_at_open=""

while [ $# -gt 0 ]; do
  case "$1" in
    --gate)  forced_gate="${2:?--gate requires a gate name}"; shift 2 ;;
    --only)  only_gate="${2:?--only requires a gate name}"; shift 2 ;;
    --basis) basis="${2:?--basis requires a value}"; shift 2 ;;
    --decision)
      decision="${2:?--decision requires approve or reject}"
      case "$decision" in
        approve|reject) ;;
        *) echo "Error: --decision takes 'approve' or 'reject', not '$decision'" >&2; exit 1 ;;
      esac
      shift 2 ;;
    --resolves) resolves="${2:?--resolves requires a finding substring, or 'all'}"; shift 2 ;;
    --batch-moved-ok) batch_moved_ok=true; shift ;;
    --withdraw) withdraw=true; shift ;;
    --express) express=true; shift ;;
    -*)      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      if [ -z "$artifact" ]; then artifact="$1"; else resolution="$1"; fi
      shift ;;
  esac
done

[ -n "$artifact" ] || { echo "Usage: $0 <artifact-id> [resolution] [--gate <name>] [--only <name>] [--basis <basis>]" >&2; exit 1; }
resolution="${resolution:-resolved}"

if $withdraw && { [ -n "$decision" ] || [ -n "$forced_gate" ]; }; then
  echo "Error: --withdraw records that a question became moot. It cannot carry a --decision," >&2
  echo "       and it cannot backfill (--gate) a question that is not open." >&2
  exit 1
fi

if [ -n "$only_gate" ] && [ -n "$forced_gate" ]; then
  echo "Error: --only and --gate are opposites — --gate records a resolution with no gate open," >&2
  echo "       --only refuses to record one unless that exact gate is open. Pick one." >&2
  exit 1
fi

# Accept PLN-004 / PLN-004-slug, or the fixed pipeline-stage literals
# RELEASE / DEPLOY — see the matching comment in lv-gate-open.sh.
case "$artifact" in
  RELEASE|DEPLOY) id="$artifact" ;;
  *) id=$(printf '%s' "$artifact" | grep -oE "^($LV_WORK_RE)-[0-9]+" || true) ;;
esac
if [ -z "$id" ]; then
  echo "Error: '$artifact' is not a $LV_PLN/$LV_BUG/$LV_BRF id, or RELEASE/DEPLOY" >&2
  exit 1
fi

# By number, so a gate opened under the plan closes when the brief it came from
# is the name in hand (WFI-187).
gate_file=$(wf_gate_file "$id" || true)

# resolve_findings — why it exists is with its call, further down (WFI-233); defined
# so the no-open-gate path can run it too.
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
      # Column-0 unchecked findings only — the same shape lv-findings-route.sh
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
      ( cd "$root" && "$SELF_DIR/lv-commit.sh" \
          "gate($id): $gate_name — $ticked finding(s) checked off as settled" \
          --add "plans/$(basename "$plan_dir")/findings.md" >/dev/null 2>&1 ) || true
    else
      echo "lv-gate-close: --resolves '$resolves' matched no unchecked finding in $findings" >&2
    fi
  fi

  # Whatever is still unchecked is what the next router will route on. Saying so
  # is the difference between a decision that lands and one that gets re-asked.
  left=$(grep -c '^- \[ \]' "$findings" 2>/dev/null || true)
  if [ "${left:-0}" -gt 0 ]; then
    echo "lv-gate-close: $id still has ${left} unchecked finding(s) in findings.md." >&2
    echo "  lv-findings-route.sh routes on those boxes and cannot read your resolution text." >&2
    echo "  If this answer settled any of them: lv-gate-close.sh $id --resolves '<finding text>'" >&2
    echo "  — it ticks them with the gate already closed (WFI-233, WFI-237, LVI-040)." >&2
  fi
}
if [ ! -f "$gate_file" ] && [ -z "$forced_gate" ]; then
  # A human's answer with nowhere to go is not a no-op: it is lost. A client's
  # attend session closed a spec-approval the harness had withdrawn minutes
  # earlier, got exit 0, and the next step refused with "spec-approval is
  # unanswered" (a client's LVI-003). Say so, and fail.
  if [ -n "$decision" ]; then
    echo "Error: $id has no open gate, so this --decision $decision was NOT recorded." >&2
    last=$(ls -t "$(wf_orch_dir)/gates/resolved/"*"$id"* 2>/dev/null | head -1 || true)
    if [ -n "$last" ]; then
      echo "       Its last question ($(wf_gate_field "$last" GATE_NAME)) was closed: $(wf_gate_field "$last" GATE_RESOLUTION | cut -c1-200)" >&2
    fi
    echo "       Re-read what the harness is asking now (lv-gate-status.sh $id) and put that to the human." >&2
    exit 6
  fi
  # The close's own advice is "re-run with --resolves", and that re-run always
  # lands here, after the gate is gone: it printed "no open gate" and ticked
  # nothing (a client's LVI-040). Ticking findings needs no open gate.
  if [ -n "$resolves" ]; then
    last=$(ls -t "$(wf_orch_dir)/gates/resolved/"*"$id"* 2>/dev/null | head -1 || true)
    gate_name=$( [ -n "$last" ] && wf_gate_field "$last" GATE_NAME || true)
    gate_name="${gate_name:-closed gate}"
    resolve_findings || true
    exit 0
  fi
  # Includes --withdraw: a question already gone has nothing left to withdraw.
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
  # Unescaped on the way out. The gate file is SHELL-SOURCED, so lv-gate-open.sh
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
  # And the context the question was asked in — the plans it depends on and
  # its directives (LVI-033). Carried into the record for the same reason.
  plan_context_at_open=$(wf_gate_field "$gate_file" GATE_PLAN_CONTEXT_AT_OPEN)
  # The commit set a promotion gate was asked about — the scope of any approval
  # recorded below. Read here with the rest, because the gate file is gone by
  # the time the record is written.
  promote_tip=$(wf_gate_field "$gate_file" GATE_PROMOTE_TIP)
  covers_push=$(wf_gate_field "$gate_file" GATE_COVERS_PUSH)
else
  gate_name="$forced_gate"
fi

# ── --gate is a BACKFILL, and a backfill over a live gate is a forgery ─────
#
# `--gate X` exists for the case where NO gate file is open and a decision a
# human demonstrably made has no record. Over a live gate it did something else
# entirely: the line below overrides the open gate's real name with the
# caller's, so everything after it — the resolved record, the ledger line, the
# `## Decisions` entry in findings.md — is written under X while carrying the
# OTHER gate's question, and the open file is deleted either way.
#
# client-b WFI-025. A `needs-input` gate was open; lv-spec's replan overwrote
# it with `spec-approval` (which lv-gate-open.sh now refuses); the attendant
# then ran `lv-gate-close.sh PLN-014 "chose option (a)" --gate needs-input`.
# Exit 0. `gates/resolved/PLN-014.needs-input` recorded GATE_NAME='needs-input'
# against GATE_QUESTION='Approve the replan?' — a resolution filed against a
# question it was never given — and findings.md published it as the decision of
# record. Both unanswered questions were gone and lv-list-gates.sh reported
# GATES: 0.
#
# So: a `--gate` that disagrees with what is actually open is refused, with the
# same exit code and the same "nothing was changed" guarantee as `--only`. The
# two flags now answer the same question from opposite ends — `--only` says
# "close MY gate", `--gate` says "record an answer for a gate with no file" —
# and neither can close a question it was not asked.
if [ -n "$forced_gate" ] && [ -f "$gate_file" ] && [ "$gate_name" != "$forced_gate" ]; then
  echo "lv-gate-close: $id has '$gate_name' open, and --gate names '$forced_gate'." >&2
  echo "  --gate is the BACKFILL path, for a decision whose gate file is already gone." >&2
  echo "  Used here it would delete the open question and file this resolution against it" >&2
  echo "  under the wrong name (client-b WFI-025)." >&2
  [ -n "$gate_question" ] && echo "  Open question: $gate_question" >&2
  echo "  To answer what is actually open:  lv-gate-close.sh $id \"<answer>\" --only $gate_name" >&2
  echo "  To backfill '$forced_gate', answer the open gate first." >&2
  wf_event gate-close-refused "$id" "$gate_name open, --gate named $forced_gate (WFI-025)"
  exit 5
fi

[ -n "$forced_gate" ] && gate_name="$forced_gate"

# ── --only: this gate, or none ────────────────────────────────────────────
# Before anything is removed or recorded, so a refusal leaves the gate exactly
# as it was — the same rule the unattended check below follows.
if [ -n "$only_gate" ] && [ "$gate_name" != "$only_gate" ]; then
  echo "lv-gate-close: $id has '$gate_name' open, not '$only_gate' — nothing closed." >&2
  echo "  The caller asked to close its own gate and found somebody else's question parked" >&2
  echo "  on this artifact (WFI-010). Closing it would delete that question and record this" >&2
  echo "  resolution as its answer." >&2
  [ -n "$gate_question" ] && echo "  Open question: $gate_question" >&2
  echo "  Answer it deliberately — /lv-attend, or lv-gate-close.sh $id \"<answer>\" — then retry." >&2
  wf_event gate-close-refused "$id" "$gate_name open, caller asked for $only_gate (WFI-010)"
  exit 5
fi

# ── Who is answering? ─────────────────────────────────────────────────────
#
# Checked BEFORE the gate file is removed, so a refusal leaves the gate exactly
# as it was and the human still owes the same answer. See WFI-227 in the header.
if [ "${LV_UNATTENDED:-0}" = "1" ] && ! $withdraw; then
  refuse_basis() {
    echo "lv-gate-close: refusing to close '$gate_name' on $id — $1" >&2
    echo "  You are running UNATTENDED (LV_UNATTENDED=1). A gate is a question parked for a" >&2
    echo "  human, and a worker may not answer its own (WFI-227). Nothing was closed." >&2
    echo "  Leave the gate open and exit 0; /lv-attend is where this gets answered." >&2
    echo "  If a decision of record DOES exist, name it: --basis verdict | config |" >&2
    echo "  autonomy | human:<commit-sha or file path> | pre-launch" >&2
    wf_event gate-close-refused "$id" "$gate_name: ${basis:-no --basis} — $1"
    exit 4
  }

  case "$basis" in
    "")
      refuse_basis "no --basis given" ;;

    verdict)
      # Not taken on trust: the same staleness question lv-spec's own gating
      # rule asks, asked here, because "a review approved it" is only an answer
      # when the review judged the text that is in front of us now (WFI-046).
      review=$("$SELF_DIR/lv-review-status.sh" "$id" 2>/dev/null || true)
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
        refuse_basis "--basis config with an empty resolution — name the levain.yml key that decides this"
      ;;

    autonomy)
      # Only two gates have an autonomy action behind them. Everything else on
      # lv-autonomy.sh's list is never-grantable BY NAME, and reaching for
      # `autonomy` on one of those is exactly the WFI-227 move.
      # `deploy-deferred-criteria` is deliberately NOT here. A standing `deploy`
      # grant is policy written before these criteria existed, and one of them
      # can be the hard runtime dependency that crash-loops production
      # (client-c DC-014, WFI-011). It needs a human or nothing.
      case "$gate_name" in
        release-approval) auto_action=release ;;
        deploy-approval)  auto_action=deploy ;;
        *) refuse_basis "--basis autonomy, but '$gate_name' has no autonomy action — lv-autonomy.sh --list names the four that do" ;;
      esac
      "$SELF_DIR/lv-autonomy.sh" "$auto_action" --artifact "$id" --quiet \
        || refuse_basis "--basis autonomy, but lv-autonomy.sh refuses '$auto_action' for this project"
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

    pre-launch)
      # The policy WFI-227 found missing, now written down: in a pre-launch
      # project the operator wants the worker's recommendation taken and checked
      # at the end state. Asked, not believed — a governed project, a passed
      # live_from or a gate outside the self-answerable set is refused.
      wf_self_answers "$gate_name" || \
        refuse_basis "--basis pre-launch, but '$gate_name' is not self-answered here (projectProfile.tier/live_from, or not one of: $LV_GATE_SELF_ANSWERABLE)"
      ;;

    *)
      refuse_basis "--basis '$basis' is not in the vocabulary (verdict | config | autonomy | human:<ref> | pre-launch)" ;;
  esac
fi

# ── Is the approval about the batch that is actually there? ───────────────
#
# See THE BATCH MOVED in the header. Checked BEFORE the gate file is removed,
# so a refusal leaves the question exactly where it was and the human can
# answer the real one. Only `approve` is checked: a rejection of a batch that
# has since grown is still a rejection, and refusing it would park a `no`
# nobody asked to revisit.
if [ "$decision" = "approve" ] && [ -n "$promote_tip" ]; then
  wf_promote_fetch "$gate_name"
  now_tip=$(wf_promote_tip "$gate_name" 2>/dev/null || true)
  if [ -n "$now_tip" ] && [ "$now_tip" != "$promote_tip" ]; then
    if $batch_moved_ok; then
      echo "lv-gate-close: '$gate_name' was asked about $(wf_promote_tip_ref "$gate_name") ${promote_tip:0:9}," >&2
      echo "  which is now at ${now_tip:0:9}. Recording the approval against the CURRENT tip on" >&2
      echo "  --batch-moved-ok: the caller says it re-derived the batch and answered about that." >&2
      promote_tip="$now_tip"
    else
      echo "lv-gate-close: refusing to record an approval for a batch that has moved." >&2
      echo "  '$gate_name' on $id was asked about $(wf_promote_tip_ref "$gate_name") at ${promote_tip:0:9}." >&2
      echo "  That ref is now at ${now_tip:0:9}. The commits you were shown are not the commits" >&2
      echo "  that would be promoted, and lv-promote-approval.sh would discard this answer the" >&2
      echo "  moment a worker read it back (client-a WFI-264). Nothing was closed." >&2
      # Named against the same refs the promotion itself reads: develop is
      # local (the skill pushes it), release and main are read from origin.
      case "$gate_name" in
        release-approval) hint_range='develop --not origin/release' ;;
        production-push)  hint_range='main --not origin/main' ;;
        *)                hint_range='origin/release --not origin/main' ;;
      esac
      echo "  Re-derive the batch against the current tip and answer that:" >&2
      echo "    git log --oneline $hint_range" >&2
      echo "  Then close with --batch-moved-ok, or re-run the skill to re-ask the question." >&2
      wf_event gate-close-refused "$id" "$gate_name: approve for ${promote_tip:0:9}, ref now ${now_tip:0:9} — batch moved"
      exit 5
    fi
  fi
fi

# ── --express: one answer approves the plan and accepts its lane's warnings ──
#
# A plan filed `--lane express` and downgraded by lv-lane.sh check reaches
# spec-approval because of those reasons. A client's operator approved one
# (PLN-063), said it should have gone express, and then needed a second step,
# `lv-lane.sh check --accept-warnings`, before its manual test, push and
# deferred criteria stopped asking. `--express` is that second step taken inside
# the answer. It runs before the gate is removed, so a refusal leaves the
# question open.
#
# A human's statement only: refused under LV_UNATTENDED=1 and with any
# --basis, and only on an `approve` of `spec-approval` for a plan that carries
# a declared lane. lv-lane.sh itself refuses an unattended accept too.
if $express; then
  express_refuse() {
    echo "lv-gate-close: --express refused — $1. Nothing was closed." >&2
    exit 1
  }
  [ "${LV_UNATTENDED:-}" = "1" ] && express_refuse "accepting a lane's warnings is a human's statement, and this is an unattended worker"
  [ -z "$basis" ] || express_refuse "it records a human's answer, and --basis $basis names a mechanism"
  [ "$gate_name" = "spec-approval" ] || express_refuse "it answers spec-approval, and the gate here is '$gate_name'"
  [ "$decision" = "approve" ] || express_refuse "it is an approval, and needs --decision approve"
  lane_out=$("$SELF_DIR/lv-lane.sh" status "$id" 2>/dev/null || true)
  printf '%s\n' "$lane_out" | grep -q "^LANE_DECLARED='.\+'" \
    || express_refuse "$id carries no declared express lane"
  if ! "$SELF_DIR/lv-lane.sh" check "$id" --accept-warnings \
         --by "$(git config user.name 2>/dev/null || whoami) (at spec-approval, approve express)" >&2; then
    express_refuse "lv-lane.sh check $id --accept-warnings did not clear the lane"
  fi
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
# the gate closed, the orchestrator re-dispatched lv-spec to action that
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
# Human Test Criteria — which lv-defer-criterion.sh explicitly instructs a
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
#
# wf_state_of, not a raw row grep: a gate opened under BUG-022 is closed
# against the row that is now PLN-022, and only the lib's lookup carries that
# alias fallback.
gate_state=$(wf_state_of "$id")

# The fingerprint of the plan AS THE QUESTION WAS ASKED, carried through from
# the gate file. This close-time record is written after the exit contract's
# commit — close last, always — so `plan_body_fp` above includes anything the
# worker committed between the human answering and this call. Recording only
# that fingerprints post-answer work INTO the approval, which is how a
# contract-tagged plan reached `ready` on an approval given before the
# amendment existed (WFI-198, WFI-178). lv-gate-open.sh judges staleness
# against this one instead when it is present.
if [ -n "$plan_body_fp_at_open" ] && [ -n "$plan_body_fp" ] \
   && [ "$plan_body_fp_at_open" != "$plan_body_fp" ]; then
  echo "  note: $id changed between the question being asked and this close." >&2
  echo "        The answer is recorded against the text the human saw; work committed since is NOT covered by it." >&2
fi

# ── A promotion answered in prose alone authorizes nothing ────────────────
#
# client-b WFI-005: two /lv-attend approvals, two unattended /lv-release runs
# that re-opened the same gate, because nothing they could read said "approved".
# The tip is recorded even on a backfill (`--gate release-approval` with no gate
# file), where the batch being approved can only be the one standing now.
if [ -n "$(wf_promote_tip_ref "$gate_name")" ]; then
  if [ -n "$decision" ] && [ -z "$promote_tip" ]; then
    promote_tip=$(wf_promote_tip "$gate_name" || true)
  fi
  if [ -z "$decision" ]; then
    echo "lv-gate-close: '$gate_name' closed without --decision — the promotion is NOT authorized." >&2
    echo "  The next unattended run reads the decision, not the resolution text, and will ask again." >&2
    echo "  Re-run with --decision approve (or reject) to record the answer where a worker can act on it." >&2
  fi
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
  if $withdraw; then
    wf_emit GATE_RESOLVED_BASIS "withdrawn${basis:+ ($basis)}"
    wf_emit GATE_WITHDRAWN true
  else
    wf_emit GATE_RESOLVED_BASIS "${basis:-human (attended)}"
  fi
  wf_emit GATE_RESOLVED_UNATTENDED "${LV_UNATTENDED:-0}"
  # Not `[ -n … ] && wf_emit …`: as the LAST command in this substitution a
  # false test makes the subshell exit 1, and `set -e` then kills the script
  # before the record is ever written.
  if [ -n "$plan_body_fp_at_open" ]; then
    wf_emit GATE_PLAN_BODY_FP_AT_OPEN "$plan_body_fp_at_open"
  fi
  if [ -n "$plan_context_at_open" ]; then
    wf_emit GATE_PLAN_CONTEXT_AT_OPEN "$plan_context_at_open"
  fi
  # The answer as a VALUE, and the commit set it is an answer about. Both only
  # exist for the promotion gates; everywhere else the prose resolution is the
  # whole record, as it always was.
  if [ -n "$decision" ]; then
    wf_emit GATE_DECISION "$decision"
  fi
  if [ -n "$promote_tip" ]; then
    wf_emit GATE_PROMOTE_TIP "$promote_tip"
  fi
  if [ "${covers_push:-}" = "true" ]; then
    wf_emit GATE_COVERS_PUSH true
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
# lv-gate-open.sh now REFUSES that re-opening, which is what stops the loop.
# This is the other half and the reason it is still worth writing: a worker told
# "already answered" needs to know WHAT was answered in the same place it reads
# everything else about the plan, or it is merely blocked rather than informed.
#
# findings.md, not plan.md: this is a record of something that happened, and the
# plan is a specification. Deliberately no `- [ ]` items — an unchecked box in
# findings.md is what lv-list-specable.sh reads as "this plan needs replanning".
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
    if $withdraw; then
      printf '> **Withdrawn:** the question became moot and was not answered — nothing was approved. Re-spec against the reason above.\n'
    else
      printf '> **Answered by:** %s\n' "${basis:-a human at an attended terminal}"
    fi
    printf '> **State at close:** %s\n' "${gate_state:-—}"
    printf '> Recorded by lv-gate-close.sh. This is the decision of record — act on it rather than re-deriving the question (WFI-181).\n'
  } >> "$findings"

  # Committed here for the same reason wf_registry_commit commits: a decision
  # left dirty on the shared develop root belongs to whoever commits next.
  ( cd "$root" && "$SELF_DIR/lv-commit.sh" \
      "gate($id): $gate_name resolved — recorded in findings" \
      --add "plans/$(basename "$plan_dir")/findings.md" >/dev/null 2>&1 ) \
    || echo "lv-gate-close: the resolution is written to $findings but could not be committed" >&2
}
transcribe_resolution || true

# ── The checkbox has to agree with the answer ─────────────────────────────
#
# lv-findings-route.sh routes on checkboxes and on nothing else. It cannot read
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

if $withdraw; then
  wf_event gate-withdrawn "$id" "$gate_name: $resolution"
  echo "$id: gate '$gate_name' withdrawn — $resolution"
  exit 0
fi
wf_event gate-close "$id" "$gate_name: $resolution"
if [ -n "$forced_gate" ] && [ ! -f "$gate_file" ]; then
  echo "$id: recorded '$gate_name' as answered — $resolution"
else
  echo "$id: gate '$gate_name' closed — $resolution"
fi
