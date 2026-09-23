#!/usr/bin/env bash
# wf-list-specable.sh
# Outputs work available for /wf-spec, in priority order.
# Reads REGISTRY.md for plans in draft state, plus bugs/open and briefs.
# Exit 0 if any work found, exit 1 if nothing.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

REGISTRY="plans/REGISTRY.md"
found=0

# ── Why an artifact is NOT offered has to be sayable ──────────────────────
#
# Every filter below drops work off the menu. A blocked brief says so on
# stderr; until these two, a claimed or gated one said nothing at all, and the
# two failures that followed were different but had the same shape.
#
# client-d WFI-019: BRF-020 was absent because the daemon had spawned a spec
# worker on it 90s earlier. The attended operator saw an empty worklist, went
# looking for the cause, and ran wf-unclaim.sh on it — deleting the live
# worker's claim. A one-line note would have ended that investigation before
# it started.
#
# client-b WFI-036: the opposite — an artifact offered that should not have
# been. PLN-021 sat in `draft` on an OPEN, unanswered spec-approval gate and
# was listed under `# replanning` anyway. Claiming it and following the menu
# enters Replanning with nothing to triage, and step 6d then re-opens the
# very gate that is already parked. The dispatcher has skipped gated
# artifacts since it had a gate test at all (wf-orchestrate.sh's gate_open);
# the attended menu simply never asked. stderr, not silence, because /wf-attend
# is where that plan actually belongs and the operator needs to be told so.
not_offered() {   # not_offered <id> <reason>
  echo "  ($1 not offered — $2)" >&2
}

# 0 when this artifact is parked on a human decision. Same test the dispatcher
# uses, so the two surfaces cannot disagree about what is dispatchable.
gate_parked() {   # gate_parked <artifact-id>
  "$SELF_DIR/wf-list-gates.sh" "$1" >/dev/null 2>&1
}

# 0 when the artifact should be skipped, having already said why.
skip_with_reason() {   # skip_with_reason <artifact-id> [claim-key]
  local id="$1" claim_key="${2:-$1}"
  if wf_claim_held "$claim_key"; then
    not_offered "$id" "claimed by PID ${WF_CLAIM_PID:-?} ($(wf_human_age "${WF_CLAIM_AGE:-0}") ago), in flight elsewhere"
    return 0
  fi
  if gate_parked "$id"; then
    not_offered "$id" "parked on an open gate — answer it at /wf-attend"
    return 0
  fi
  return 1
}

# --- Plans in draft state ---
#
# Two shapes land here, and until WFI-058 only the first was emitted.
#
#   1. REPLANNING — a plan sent back from verify or test, carrying unchecked
#      findings. The planner reads the findings and writes an Amendment.
#
#   2. NOTHING TO ACT ON — a plan whose plan.md exists and whose findings.md
#      carries no unchecked item. Its review may have run or may not have; the
#      `detail` column says which, from wf-review-status.sh (WFI-174).
#
# The old filter required an unchecked `- [ ]` in findings.md, which is shape 1
# by definition. Shape 2 was therefore emitted by nothing: the state table says
# `draft` means "T2 (wf-spec) acts next", and wf-orchestrate.sh's single-artifact
# path maps draft -> spec unconditionally, but the DAEMON sweep reaches spec
# through this script and so never saw them. client-a sat with 7 such plans —
# one of them, PLN-008, gating five others — while every worker slot but one
# stood idle. A plan can only leave `draft` through a spec run, so a draft this
# script does not emit is a plan the pipeline cannot finish.
#
# No dependency gate here, deliberately. Specifying is a documentation act;
# `ready -> implement` is where deps are enforced (wf-list-implementable.sh),
# and gating spec on them too would forbid planning ahead of the build queue —
# which several already-`ready` plans in the field were written that way.
#
# Both shapes go out under `# replanning` rather than a new section, because
# consumers key on section names: wf-orchestrate.sh's candidates_spec() ignores
# them, but the wf-spec entry menu parses exactly three (`# replanning`,
# `# bugs`, `# briefs`) and would drop rows under a fourth. The `detail` column
# is what tells them apart.
escalated=()
unreviewed=()
while IFS=$'\037' read -r id slug state priority _rest; do
  [ "$state" = "draft" ] || continue
  plan_dir="plans/${id}-${slug}"
  [ -d "$plan_dir" ] || continue

  # Claimed by a live session, or parked on a gate? Not ours to offer — and
  # say which, on stderr. See not_offered above.
  skip_with_reason "${id}-${slug}" && continue

  findings="$plan_dir/findings.md"
  unchecked=$(wf_unchecked_count "$findings")
  if [ "$unchecked" -gt 0 ]; then
    esc_count=$(wf_escalated_count "$findings")
    bhv_count=$(wf_behavior_count "$findings")
    parts=()
    [ "$esc_count" -gt 0 ] && parts+=("$esc_count escalated")
    [ "$bhv_count" -gt 0 ] && parts+=("$bhv_count behavior")
    # NO CATEGORY IS NOT NO WORK.
    #
    # This used to `continue` when parts[] came up empty, which drops the
    # entry without adding it to escalated[] AND without falling through to
    # the unreviewed[] branch below — the plan disappears from the spec role
    # while still holding unchecked findings, and `draft` is a state a plan
    # can only leave through a spec run. client-d's PLN-011 was invisible
    # that way with two live escalations, because both were hard-wrapped and
    # the counter read physical lines (WFI-031). The counter is fixed, but a
    # count is a display detail and must not decide visibility: any unchecked
    # finding is replanning work, whatever it is tagged.
    if [ ${#parts[@]} -eq 0 ]; then parts+=("$unchecked unchecked"); fi
    detail=$(IFS=', '; echo "${parts[*]}")
    escalated+=("${id}-${slug}	${detail} finding(s)	$priority")
    found=1
    continue
  fi

  # No findings to act on. If the plan also has no plan.md, there is nothing to
  # review yet and it belongs to whatever created the row — leave it alone.
  [ -f "$plan_dir/plan.md" ] || continue

  # ── What "unreviewed" means is wf-review-status.sh's to say ─────────────
  #
  # This column used to read `never reviewed` for every draft with no unchecked
  # finding, which is a statement about findings.md and not about the review.
  # client-a had four plans reported that way while wf-review-status.sh
  # answered REVIEW_LOCATION=plan, 'Approved with notes', STALE=false,
  # STAMPED=true for all four — the two surfaces flatly contradicting each
  # other (WFI-174).
  #
  # It under-claims rather than over-claims, so nothing unsafe followed from
  # it. What did follow is waste: wf-spec fans out a review agent for every
  # plan this column says has none, so four current, stamped reviews were
  # queued to be run again — exactly the tokens the review-before-gate
  # ordering exists to save. The verdict of record is one script's answer;
  # ask it rather than inferring one.
  eval "$("$SELF_DIR/wf-review-status.sh" "$id" 2>/dev/null || true)"
  case "${REVIEW_LOCATION:-none}" in
    none) detail="never reviewed" ;;
    *)
      if [ "${REVIEW_STALE:-false}" = "false" ]; then
        detail="reviewed: ${REVIEW_RESULT:-—}"
      else
        detail="review stale (${REVIEW_RESULT:-—})"
      fi ;;
  esac
  unreviewed+=("${id}-${slug}	${detail}	$priority")
  found=1
done < <(wf_registry_rows "$REGISTRY")

if [ ${#escalated[@]} -gt 0 ] || [ ${#unreviewed[@]} -gt 0 ]; then
  echo "# replanning"
  # Escalated first: a plan already through the pipeline once has downstream
  # work waiting on it, and spec runs one at a time.
  #
  # Each loop is guarded on its OWN count. Under `set -u` on the bash 3.2 macOS
  # ships, "${arr[@]}" of an EMPTY array is an unbound variable, not an empty
  # expansion — and the common case here is one list populated and the other
  # not. client-a, with 7 unreviewed drafts and no escalated ones, printed
  # the header and then died on line 109.
  if [ ${#escalated[@]} -gt 0 ]; then
    for entry in "${escalated[@]}"; do
      printf "%s\n" "$entry"
    done
  fi
  if [ ${#unreviewed[@]} -gt 0 ]; then
    for entry in "${unreviewed[@]}"; do
      printf "%s\n" "$entry"
    done
  fi
fi

# ── Blocked: the verb for "known, and not convertible yet" ────────────────
#
# Defined here rather than beside the briefs because BUGS need it too. The
# comment further down explains why a brief cannot leave the specable list on
# its own; client-d WFI-018 is the same dead end reached from the bug side.
# BUG-017's answered needs-input gate said "stays OPEN pending BRF-018, closed
# by whatever that brief decides" — so no plan, so wf-bug-consume.sh never runs,
# so the bug never moves out of bugs/open/, so it is offered on every sweep
# forever. "A bug leaves by MOVING" was true of every bug that CAN move.
#
# Re-opening the answered gate is not the escape (WFI-180/181/182), and neither
# is bugs/triaged/: a triaged bug with an empty Plan: field is re-offered by
# design (WFI-249). wf-brief-block.sh writes and clears the field for both
# kinds.
brief_is_blocked() {
  local brief_md="$1" field
  field=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Blocked:\*\*' "$brief_md" 2>/dev/null \
          | sed -E 's/^.*\*\*Blocked:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)
  # A parenthesised value is template prose, not a blocker — the same defence
  # the Plan: field needs, and for the same reason: a placeholder that reads as
  # a real value hides work instead of describing it.
  case "$field" in
    ""|"("*|*"(none"*|*_none_*|"—") return 1 ;;
    *) printf '%s' "$field"; return 0 ;;
  esac
}

# --- Open bugs ---
bugs_found=0
for bug_md in bugs/open/*/bug.md; do
  [ -f "$bug_md" ] || continue
  # The DECLARED id, not the first BUG-NNN token in the file — see wf_bug_id.
  # This list is where the orchestrator's spec candidates come from, so a
  # misread id here is a worker dispatched at another bug entirely (WFI-176).
  bug_id=$(wf_bug_id "$bug_md")
  # `|| true` on the whole pipeline: under pipefail, a bug.md with no
  # Severity: line makes grep the only nonzero exit in the pipe, so under
  # `set -e` the bare assignment killed the whole script the first time a
  # bug lacking that field ever reached this line (surfaced by BUG-900-dup,
  # a "a bug\n" fixture with no header fields at all, once WFI-249's
  # triaged/ scan started reading it too).
  severity=$({ grep -E "Severity:" "$bug_md" 2>/dev/null | head -1 | sed 's/.*Severity:\*\*[[:space:]]*//' | sed 's/^> //'; } || true)
  title=$(head -1 "$bug_md" | sed 's/^# //')
  [ -n "$bug_id" ] || continue
  # A bug being specced right now is claimed under its number, even though no
  # plan folder exists yet to hold the claim (WFI-004). Offering it anyway is
  # how two spec workers end up on one artifact.
  skip_with_reason "$bug_id" && continue
  # Blocked by a recorded, human-written reason. To stderr, so a human running
  # this sees what is held back and why, while the stdout a dispatcher parses
  # carries only work that can be done.
  if blocked_why=$(brief_is_blocked "$bug_md"); then
    echo "  ($bug_id blocked — $blocked_why)" >&2
    continue
  fi
  if [ $bugs_found -eq 0 ]; then echo "# bugs"; fi
  printf "%s\t%s\t%s\n" "$bug_id" "$severity" "$title"
  bugs_found=1
  found=1
done

# --- Bugs hand-filed straight into triaged/ ────────────────────────────────
#
# `triaged/` is normally reached only by wf-bug-consume.sh, at the moment a
# fix plan exists, and it always writes `> **Plan:** PLN-NNN-slug` into
# bug.md when it does. A bug placed there by hand — modeled on a sibling that
# legitimately lives in triaged/ because it already has a plan — carries no
# such field, and this script used to scan only bugs/open/*/bug.md. The
# result: silently invisible to every sweep, with no error anywhere
# (client-a BUG-270, WFI-249).
#
# So: any triaged bug whose Plan: field is empty, absent, or names a plan
# directory that does not exist is un-specced regardless of which folder it
# sits in, and belongs in the same list as an open bug.
for bug_md in bugs/triaged/*/bug.md; do
  [ -f "$bug_md" ] || continue
  bug_id=$(wf_bug_id "$bug_md")
  [ -n "$bug_id" ] || continue
  plan_field=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Plan:\*\*' "$bug_md" 2>/dev/null \
               | sed -E 's/^.*\*\*Plan:\*\*[[:space:]]*//; s/[[:space:]]*$//; s#/$##' || true)
  case "$plan_field" in
    ""|*"(none"*|*_none_*) ;;
    # `if`, not `[ -d ... ] && continue` — under `set -e` a bare `&&` whose
    # left side is false is the exit status of this whole case arm, and a
    # case statement outside any exempted context aborts the script on that
    # (the rest of bugs/triaged/ and every briefs row after it went unread
    # silently, caught only by tests/client-reports.sh).
    *) if [ -d "plans/$plan_field" ]; then continue; fi ;;
  esac
  # `|| true` on the whole pipeline: under pipefail, a bug.md with no
  # Severity: line makes grep the only nonzero exit in the pipe, so under
  # `set -e` the bare assignment killed the whole script the first time a
  # bug lacking that field ever reached this line (surfaced by BUG-900-dup,
  # a "a bug\n" fixture with no header fields at all, once WFI-249's
  # triaged/ scan started reading it too).
  severity=$({ grep -E "Severity:" "$bug_md" 2>/dev/null | head -1 | sed 's/.*Severity:\*\*[[:space:]]*//' | sed 's/^> //'; } || true)
  title=$(head -1 "$bug_md" | sed 's/^# //')
  skip_with_reason "$bug_id" && continue
  if blocked_why=$(brief_is_blocked "$bug_md"); then
    echo "  ($bug_id blocked — $blocked_why)" >&2
    continue
  fi
  if [ $bugs_found -eq 0 ]; then echo "# bugs"; fi
  printf "%s\t%s\t%s (hand-filed into triaged/, no plan)\n" "$bug_id" "$severity" "$title"
  bugs_found=1
  found=1
done

# --- Decided briefs ---
#
# A BRIEF NEVER LEAVES `## Decided`, SO SOMETHING HAS TO ASK WHETHER IT IS DONE
#
# A bug drops off this list by moving: wf-bug-consume.sh renames open/ →
# triaged/, and the glob above stops finding it. A brief has no such move. It is
# stamped `> **Status:** Planned` with a `> **Plan:**` field, and its INDEX.md
# row stays exactly where it was, under `## Decided`, forever.
#
# So this section offered client-a's BRF-161 on every sweep after its plan
# was written, reviewed, approved by a human and moved to `ready`. The daemon
# spawned a spec worker each time — 19:00, 19:09, 19:11, 20:02, 20:04, 20:06 —
# and each one correctly worked out that there was nothing to do and exited
# (WFI-188, WFI-189, WFI-190). Three of them stopped to file a report about it.
#
# It took three reports to find because of the claim check below: by the time a
# human ran this script by hand, the dispatcher held the claim on 161, so the
# brief was filtered out and the output came back EMPTY. Every report therefore
# concluded, reasonably, that the dispatch had not come from this list at all.
#
# `Status: Planned` alone is not the test. A run that dies between stamping the
# brief and writing the plan would then hide real work forever. The test is
# whether the plan EXISTS: a `> **Plan:**` field naming a directory that is
# there, or — for a brief whose field was never written — wf-plan-id.sh finding
# a plan whose header names this brief. That second call is why --peek had to
# exist first (WFI-175); without it, listing would allocate.
brief_is_planned() {
  local brief_md="$1" brief_id="$2" planned plan_field
  [ -f "$brief_md" ] || return 1

  plan_field=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Plan:\*\*' "$brief_md" 2>/dev/null \
               | sed -E 's/^.*\*\*Plan:\*\*[[:space:]]*//; s/[[:space:]]*$//; s#/$##' || true)
  case "$plan_field" in
    ""|*"(none"*|*_none_*) ;;
    *) [ -d "$plan_field" ] && return 0
       [ -d "plans/$(basename "$plan_field")" ] && return 0 ;;
  esac

  # No usable field. Only worth a subprocess if the brief claims to be planned.
  planned=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Status:\*\*' "$brief_md" 2>/dev/null || true)
  case "$planned" in *[Pp]lanned*) ;; *) return 1 ;; esac
  [ -n "$brief_id" ] && [ "$brief_id" != "—" ] || return 1
  "$SELF_DIR/wf-plan-id.sh" "$brief_id" --peek 2>/dev/null \
    | grep -q "PLAN_ID_RESUME='true'"
}

# A BRIEF THAT CANNOT BE CONVERTED YET NEEDS AN EXIT TOO
#
# brief_is_planned() above covers the brief that already HAS a plan. It says
# nothing about the brief that cannot have one yet, and two kinds cannot:
# one blocked on something in another repo, and one that sequences several
# future plans rather than becoming one (its Plan: field a deliberate
# "(none — …)"). Neither can ever satisfy the plan-exists test, so both were
# offered on every sweep forever. client-b BRF-010 is both at once: a spec
# worker was dispatched onto it, read the brief, the answered gate saying "no
# PLN-010 yet; BRF-010 stays Decided", and the still-open client-d bug it
# waits on — then exited having created nothing, ready to be dispatched again
# a minute later (WFI-009).
#
# `> **Blocked:** <reason>` in the brief's header is the missing verb
# (wf-brief-block.sh writes and clears it). It is not silent: the reason goes
# to stderr, so a human running this sees what is being held back and why,
# while the stdout a dispatcher parses carries only work that can be done.

briefs_found=0
if [ -f "plans/briefs/INDEX.md" ]; then
  in_decided=0
  while IFS= read -r line; do
    case "$line" in
      "## Decided"*) in_decided=1; continue ;;
      "## "*)        in_decided=0; continue ;;
    esac
    if [ $in_decided -eq 1 ] && [[ "$line" == "- ["* ]]; then
      name=$(echo "$line" | sed 's/^\- \[//' | sed 's/\].*//')
      link=$(echo "$line" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
      brief_id=$(echo "$link" | grep -oE 'BRF-[0-9]+' | head -1)
      [ -n "$brief_id" ] || brief_id="—"

      # Already converted? Then it is a record, not a worklist item — see
      # brief_is_planned above. Checked BEFORE the claim test, so that a
      # planned brief reads the same whether or not a worker happens to be
      # holding it at this instant (WFI-188/189/190).
      brief_is_planned "plans/briefs/$link" "$brief_id" && continue

      # Blocked by a recorded, human-written reason — see brief_is_blocked.
      if blocked_why=$(brief_is_blocked "plans/briefs/$link"); then
        echo "$brief_id blocked, not offered: $blocked_why" >&2
        continue
      fi

      # Same claim check as bugs: a brief under spec has no plan folder yet.
      if [ "$brief_id" != "—" ] && skip_with_reason "$brief_id"; then continue; fi
      desc=$(echo "$line" | sed 's/^[^—]*— //')
      if [ $briefs_found -eq 0 ]; then echo "# briefs"; fi
      printf "%s\t%s\t%s\n" "$brief_id" "$name" "$desc"
      briefs_found=1
      found=1
    fi
  done < "plans/briefs/INDEX.md"
fi

exit $((1 - found))
