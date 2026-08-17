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

  # Claimed by a live session? Not ours to offer.
  wf_claim_held "${id}-${slug}" && continue

  findings="$plan_dir/findings.md"
  if [ -f "$findings" ] && grep -q '^\- \[ \]' "$findings" 2>/dev/null; then
    esc_count=$(grep -c "ESCALATED" "$findings" 2>/dev/null || true)
    bhv_count=$(grep -c "Behavior" "$findings" 2>/dev/null || true)
    parts=()
    [ "$esc_count" -gt 0 ] && parts+=("$esc_count escalated")
    [ "$bhv_count" -gt 0 ] && parts+=("$bhv_count behavior")
    if [ ${#parts[@]} -gt 0 ]; then
      detail=$(IFS=', '; echo "${parts[*]}")
      escalated+=("${id}-${slug}	${detail} finding(s)	$priority")
      found=1
    fi
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

# --- Open bugs ---
bugs_found=0
for bug_md in bugs/open/*/bug.md; do
  [ -f "$bug_md" ] || continue
  # The DECLARED id, not the first BUG-NNN token in the file — see wf_bug_id.
  # This list is where the orchestrator's spec candidates come from, so a
  # misread id here is a worker dispatched at another bug entirely (WFI-176).
  bug_id=$(wf_bug_id "$bug_md")
  severity=$(grep -E "Severity:" "$bug_md" 2>/dev/null | head -1 | sed 's/.*Severity:\*\*[[:space:]]*//' | sed 's/^> //')
  title=$(head -1 "$bug_md" | sed 's/^# //')
  [ -n "$bug_id" ] || continue
  # A bug being specced right now is claimed under its number, even though no
  # plan folder exists yet to hold the claim (WFI-004). Offering it anyway is
  # how two spec workers end up on one artifact.
  wf_claim_held "$bug_id" && continue
  if [ $bugs_found -eq 0 ]; then echo "# bugs"; fi
  printf "%s\t%s\t%s\n" "$bug_id" "$severity" "$title"
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
               | sed -E 's/^.*\*\*Plan:\*\*[ \t]*//; s/[ \t]*$//; s#/$##' || true)
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

briefs_found=0
if [ -f "plans/briefs/INDEX.md" ]; then
  in_decided=0
  while IFS= read -r line; do
    if echo "$line" | grep -q "^## Decided"; then
      in_decided=1; continue
    fi
    if echo "$line" | grep -q "^## "; then
      in_decided=0; continue
    fi
    if [ $in_decided -eq 1 ] && echo "$line" | grep -q "^\- \["; then
      name=$(echo "$line" | sed 's/^\- \[//' | sed 's/\].*//')
      link=$(echo "$line" | grep -oE '\([^)]+\)' | head -1 | tr -d '()')
      brief_id=$(echo "$link" | grep -oE 'BRF-[0-9]+' | head -1)
      [ -n "$brief_id" ] || brief_id="—"

      # Already converted? Then it is a record, not a worklist item — see
      # brief_is_planned above. Checked BEFORE the claim test, so that a
      # planned brief reads the same whether or not a worker happens to be
      # holding it at this instant (WFI-188/189/190).
      brief_is_planned "plans/briefs/$link" "$brief_id" && continue

      # Same claim check as bugs: a brief under spec has no plan folder yet.
      if [ "$brief_id" != "—" ] && wf_claim_held "$brief_id"; then continue; fi
      desc=$(echo "$line" | sed 's/^[^—]*— //')
      if [ $briefs_found -eq 0 ]; then echo "# briefs"; fi
      printf "%s\t%s\t%s\n" "$brief_id" "$name" "$desc"
      briefs_found=1
      found=1
    fi
  done < "plans/briefs/INDEX.md"
fi

exit $((1 - found))
