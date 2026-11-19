#!/usr/bin/env bash
# lv-list-specable.sh
# Outputs work available for /lv-spec, in priority order.
# Reads REGISTRY.md for plans in draft state, plus bugs/open and briefs.
# Exit 0 if any work found, exit 1 if nothing.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

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
# looking for the cause, and ran lv-unclaim.sh on it — deleting the live
# worker's claim. A one-line note would have ended that investigation before
# it started.
#
# client-b WFI-036: the opposite — an artifact offered that should not have
# been. PLN-021 sat in `draft` on an OPEN, unanswered spec-approval gate and
# was listed under `# replanning` anyway. Claiming it and following the menu
# enters Replanning with nothing to triage, and step 6d then re-opens the
# very gate that is already parked. The dispatcher has skipped gated
# artifacts since it had a gate test at all (lv-orchestrate.sh's gate_open);
# the attended menu simply never asked. stderr, not silence, because /lv-attend
# is where that plan actually belongs and the operator needs to be told so.
not_offered() {   # not_offered <id> <reason>
  echo "  ($1 not offered — $2)" >&2
}

# 0 when the artifact should be skipped, having already said why.
skip_with_reason() {   # skip_with_reason <artifact-id> [claim-key]
  local id="$1" claim_key="${2:-$1}"
  if wf_claim_held "$claim_key"; then
    not_offered "$id" "claimed by PID ${LV_CLAIM_HOLDER_PID:-?} ($(wf_human_age "${LV_CLAIM_AGE:-0}") ago), in flight elsewhere"
    return 0
  fi
  return 1
}

# ── A gated artifact is ANNOTATED, not withheld ───────────────────────────
#
# It would be easy to drop a gated row the way a claimed one is dropped. It is
# also wrong, because this list has two audiences and they need opposite
# things from it.
#
#   the dispatcher  reaches spec through this script, applies its OWN gate
#                   test, and logs `skip <id> spec: gate open` — once, as a
#                   standing condition, which is also what lets the `stalled`
#                   event name the gate responsible (client-a WFI-023).
#                   Withhold the row and the daemon reports a pipeline that is
#                   empty for no stated reason.
#   the lv-spec menu renders these rows for a human or an attended worker to
#                   pick from. client-b WFI-036: PLN-021 appeared under
#                   `# replanning` with detail `reviewed: Approved` while it
#                   sat on an OPEN, unanswered spec-approval gate and an empty
#                   findings.md. Following the menu literally claims it and
#                   enters Replanning with nothing to triage; step 6d then
#                   re-opens the gate that is already parked.
#
# So the row stays and the DETAIL COLUMN stops lying. That column exists to
# tell shapes apart, every consumer already reads it, and `GATED(...)` is the
# one fact that decides whether this artifact is anyone's to pick up.
gate_note() {   # gate_note <artifact-id> → "GATED(<name>) …; " or nothing
  local row name
  row=$("$SELF_DIR/lv-list-gates.sh" "$1" 2>/dev/null) || return 0
  [ -n "$row" ] || return 0
  name=$(printf '%s\n' "$row" | head -1 | cut -f2)
  printf 'GATED(%s) — answer at /lv-attend, do not claim; ' "${name:-open gate}"
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
#      `detail` column says which, from lv-review-status.sh (WFI-174).
#
# The old filter required an unchecked `- [ ]` in findings.md, which is shape 1
# by definition. Shape 2 was therefore emitted by nothing: the state table says
# `draft` means "T2 (lv-spec) acts next", and lv-orchestrate.sh's single-artifact
# path maps draft -> spec unconditionally, but the DAEMON sweep reaches spec
# through this script and so never saw them. client-a sat with 7 such plans —
# one of them, PLN-008, gating five others — while every worker slot but one
# stood idle. A plan can only leave `draft` through a spec run, so a draft this
# script does not emit is a plan the pipeline cannot finish.
#
# No dependency gate here, deliberately. Specifying is a documentation act;
# `ready -> implement` is where deps are enforced (lv-list-implementable.sh),
# and gating spec on them too would forbid planning ahead of the build queue —
# which several already-`ready` plans in the field were written that way.
#
# Both shapes go out under `# replanning` rather than a new section, because
# consumers key on section names: lv-orchestrate.sh's candidates_spec() ignores
# them, but the lv-spec entry menu parses exactly three (`# replanning`,
# `# bugs`, `# briefs`) and would drop rows under a fourth. The `detail` column
# is what tells them apart.
# directive_note <plan-id> → why a draft plan is steering work, or nothing
# (LVI-033). An overseer's directive not yet applied, or a spec-approval that
# was WITHDRAWN because what it asked about moved, is a replan brief exactly
# as an escalated finding is — and findings.md carries neither as a checkbox.
directive_note() {
  local id="$1" ids rf note=""
  ids=$(wf_directives_live "$id" | awk -F'\037' '($2 == "constraint" || $2 == "replan") && $3 == "open" { printf "%s%s", s, $1; s = "," }')
  [ -n "$ids" ] && note="directive ${ids} to apply"
  rf=$(wf_gate_resolved_file "$id" spec-approval || true)
  if [ -f "$rf" ] && [ "$(wf_gate_field "$rf" GATE_WITHDRAWN)" = "true" ]; then
    note="${note:+$note, }spec-approval withdrawn"
  fi
  printf '%s' "$note"
}

escalated=()
unreviewed=()
while IFS=$'\037' read -r id slug state priority _rest; do
  [ "$state" = "draft" ] || continue
  plan_dir="plans/${id}-${slug}"
  [ -d "$plan_dir" ] || continue

  # Claimed by a live session, or parked on a gate? Not ours to offer — and
  # say which, on stderr. See not_offered above.
  skip_with_reason "${id}-${slug}" && continue

  dnote=$(directive_note "$id")
  if [ -n "$dnote" ]; then
    escalated+=("${id}-${slug}	$(gate_note "$id")${dnote}	$priority")
    found=1
    continue
  fi

  findings="$plan_dir/findings.md"
  unchecked=$(wf_unchecked_count "$findings")
  if [ "$unchecked" -gt 0 ]; then
    # The one dependency that holds a replan back: a Deps entry with no row
    # yet, i.e. a bug or brief here that has not been specced. The replan is
    # waiting for that plan to exist, and re-offering it sends a spec worker
    # that can only unclaim again, every sweep (a client's LVI-007). It comes
    # back once the dependency has a row; completion is still enforced at
    # implement, per the note above.
    waiting=""
    deps=$(wf_registry_field "$id" deps "$REGISTRY" 2>/dev/null || true)
    if [ -n "$deps" ] && [ "$deps" != "—" ]; then
      for dep in ${deps//,/ }; do
        wf_is_external_dep "$dep" && continue
        [ "$(wf_state_of "$dep" "$REGISTRY")" = "—" ] || continue
        compgen -G "bugs/closed/$dep-*" >/dev/null && continue
        waiting="${waiting:+$waiting, }$dep"
      done
    fi
    if [ -n "$waiting" ]; then
      not_offered "$id" "replan waits on $waiting, not specced yet"
      continue
    fi
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
    escalated+=("${id}-${slug}	$(gate_note "$id")${detail} finding(s)	$priority")
    found=1
    continue
  fi

  # No findings to act on. If the plan also has no plan.md, there is nothing to
  # review yet and it belongs to whatever created the row — leave it alone.
  [ -f "$plan_dir/plan.md" ] || continue

  # ── What "unreviewed" means is lv-review-status.sh's to say ─────────────
  #
  # This column used to read `never reviewed` for every draft with no unchecked
  # finding, which is a statement about findings.md and not about the review.
  # client-a had four plans reported that way while lv-review-status.sh
  # answered REVIEW_LOCATION=plan, 'Approved with notes', STALE=false,
  # STAMPED=true for all four — the two surfaces flatly contradicting each
  # other (WFI-174).
  #
  # It under-claims rather than over-claims, so nothing unsafe followed from
  # it. What did follow is waste: lv-spec fans out a review agent for every
  # plan this column says has none, so four current, stamped reviews were
  # queued to be run again — exactly the tokens the review-before-gate
  # ordering exists to save. The verdict of record is one script's answer;
  # ask it rather than inferring one.
  eval "$("$SELF_DIR/lv-review-status.sh" "$id" 2>/dev/null || true)"
  case "${REVIEW_LOCATION:-none}" in
    none) detail="never reviewed" ;;
    *)
      if [ "${REVIEW_STALE:-false}" = "false" ]; then
        detail="reviewed: ${REVIEW_RESULT:-—}"
      else
        detail="review stale (${REVIEW_RESULT:-—})"
      fi ;;
  esac
  unreviewed+=("${id}-${slug}	$(gate_note "$id")${detail}	$priority")
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
# by whatever that brief decides" — so no plan, so lv-bug-consume.sh never runs,
# so the bug never moves out of bugs/open/, so it is offered on every sweep
# forever. "A bug leaves by MOVING" was true of every bug that CAN move.
#
# Re-opening the answered gate is not the escape (WFI-180/181/182), and neither
# is bugs/triaged/: a triaged bug with an empty Plan: field is re-offered by
# design (WFI-249). lv-brief-block.sh writes and clears the field for both
# kinds.
brief_is_blocked() { wf_brief_blocked "$@"; }   # moved to lv-orch-lib.sh (LVI-027)

# ── Bugs that belong together are offered together (LVI-024) ──────────────
#
# One overseer conversation filed a client's BUG-041..049 inside a few hours;
# BUG-046 reversed the premise of 041 and 043, and 047/048/049 amended
# 041/043/046. This list offered all nine as independent rows, so a spec
# worker could take a target without its correction or a correction without
# its target — BUG-041 became an active plan built on the superseded model
# before its amendment was even filed. The operator stopped the daemon by hand.
#
# Two relations now decide what is offered, both read from the bug headers:
#
#   Group   `> **Group:** <slug>` (lv-bug-group.sh). Open group: no member is
#           offered. Sealed: the lead is offered carrying the members still
#           open, and the others are withheld while the lead is open or its
#           spec run holds the claim. Dissolved or Consumed: independent.
#   Amends  "Amends BUG-NNN" in Links, outside any live group. An amender whose
#           target is still open is withheld and carried by the target — a
#           chain resolves to its root. Target already consumed: the amender
#           is offered alone, its detail naming the target's plan and state, so
#           /lv-spec amends a draft/ready plan (step 2b) and writes a new plan
#           with Deps on one already built.
#
# Withheld rows say why on stderr, like every other filter here; the detail
# column of an offered row says what it carries. The dispatcher needs no rule
# of its own: it dispatches only what this lists, and the claim on the lead's
# number covers the whole pass.
pair_ids=" "
amend_rows=""
for bug_md in bugs/open/*/bug.md; do
  [ -f "$bug_md" ] || continue
  b=$(wf_bug_id "$bug_md" 2>/dev/null); [ -n "$b" ] || continue
  g=$(wf_bug_field "$bug_md" Group)
  if [ -n "$g" ]; then
    case "$(wf_group_field "$g" Status)" in Open|Sealed) continue ;; esac
  fi
  pair_ids+="$b "
  a=$(wf_bug_amends "$bug_md" | paste -sd' ' -)
  [ -n "$a" ] && amend_rows+="$b"$'\t'"$a"$'\n'
done

is_pair_bug() { [[ "$pair_ids" == *" $1 "* ]]; }
is_open_bug() { compgen -G "bugs/open/$1-*/bug.md" >/dev/null || [ -f "bugs/open/$1/bug.md" ]; }
amends_of()   { printf '%s' "$amend_rows" | awk -F'\t' -v b="$1" '$1 == b { print $2 }'; }

# root_of <id> → the open bug at the end of its Amends chain (itself if none).
root_of() {
  local cur="$1" seen=" $1 " nxt t
  while :; do
    nxt=""
    for t in $(amends_of "$cur"); do
      if is_pair_bug "$t" && [[ "$seen" != *" $t "* ]]; then nxt="$t"; break; fi
    done
    [ -n "$nxt" ] || break
    seen+="$nxt "; cur="$nxt"
  done
  printf '%s' "$cur"
}

carried_by() {   # carried_by <root> → the open bugs whose chain ends there, comma-joined
  local b
  for b in $pair_ids; do
    [ "$b" != "$1" ] && [ "$(root_of "$b")" = "$1" ] && printf '%s\n' "$b"
  done | paste -sd, -
}

# intake_skip <bug.md> <id> — exit 0 when withheld (reason already on stderr);
# otherwise sets intake_note to what the row carries.
intake_note=""
intake_skip() {
  local md="$1" id="$2" g lead carried t loc pid pst m lplan carrier
  intake_note=""
  g=$(wf_bug_field "$md" Group)
  if [ -n "$g" ]; then
    case "$(wf_group_field "$g" Status)" in
      Open)
        not_offered "$id" "held in intake group $g, open since $(wf_group_field "$g" Opened | cut -d' ' -f1); lv-bug-group.sh seal $g"
        return 0 ;;
      Sealed)
        lead=$(wf_group_field "$g" Lead)
        # Sealed onto a lead already in a plan still in spec (LVI-026): the
        # open members amend that plan, together, in one run — offered as the
        # lowest-numbered of them carrying the rest.
        lplan=$(wf_group_field "$g" "Lead plan" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
        if [ -n "$lplan" ]; then
          carrier=$(for m in $(wf_group_members "$g"); do is_open_bug "$m" && printf '%s\n' "$m"; done \
                    | sort -t- -k2,2n | head -1)
          if [ "$id" != "$carrier" ]; then
            not_offered "$id" "carried with $carrier, amending $lplan — the lead plan of sealed group $g"
            return 0
          fi
          carried=$(for m in $(wf_group_members "$g"); do
                      [ "$m" != "$id" ] && is_open_bug "$m" && printf '%s\n' "$m"
                    done | paste -sd, -)
          intake_note="GROUP($g) lead $lead is $lplan $(wf_state_of "$lplan"): amend it with this${carried:+ +$carried} — spec together, step 2b (lv-bug-group.sh show $g); "
          return 1
        fi
        if [ "$id" = "$lead" ]; then
          carried=$(for m in $(wf_group_members "$g"); do
                      [ "$m" != "$id" ] && is_open_bug "$m" && printf '%s\n' "$m"
                    done | paste -sd, -)
          intake_note="GROUP($g) ${carried:++$carried — }spec together (lv-bug-group.sh show $g); "
          return 1
        fi
        if [ -n "$lead" ] && wf_group_lead_in_spec "$lead"; then
          not_offered "$id" "carried with $lead, the lead of sealed group $g"
          return 0
        fi
        intake_note="GROUP($g) lead ${lead:-—} already specced; "
        return 1 ;;
      Consumed)
        # Left by the lead's run for a plan of its own (LVI-005): say which
        # plan it depends on, so its spec run sets Deps without re-deriving it.
        lplan=$(wf_group_left "$g" | awk -F'\t' -v b="$id" '$1 == b { print $2; exit }')
        [ -n "$lplan" ] && intake_note="GROUP($g) left for its own plan: Deps $lplan; "
        return 1 ;;
    esac
  fi

  if [ "$(root_of "$id")" != "$id" ]; then
    # A chain whose end is blocked carries this bug into the same wait, and
    # "still open" alone hid that: a client's BUG-057 amended 056 amended 030,
    # 030 was blocked on another bug, and 057 sat unoffered with nothing saying
    # why (LVI-027). Name the block, and the two ways out.
    local chain_block
    chain_block=$(wf_bug_chain_block "$id")
    if [ -n "$chain_block" ]; then
      not_offered "$id" "amends $(root_of "$id"), carried with it — and ${chain_block%%$'\t'*} is blocked (${chain_block#*$'\t'}), so this waits on that block. Unblock it, or drop this bug's Amends link to spec it alone"
    else
      not_offered "$id" "amends $(root_of "$id"), still open — carried with it"
    fi
    return 0
  fi
  for t in $(amends_of "$id"); do
    is_pair_bug "$t" && continue
    if wf_claim_held "$t"; then
      not_offered "$id" "amends $t, whose spec run is in flight — carried with it"
      return 0
    fi
    loc=$(wf_bug_md "$t"); [ -n "$loc" ] || continue
    pid=$(wf_bug_field "${loc#*$'\t'}" Plan | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
    [ -n "$pid" ] || continue
    pst=$(wf_state_of "$pid")
    case "$pst" in
      draft|ready)             intake_note+="amends $t → $pid $pst: amendment (step 2b); " ;;
      complete|abandoned|—|"") ;;
      *)                       intake_note+="amends $t → target $pid $pst: new plan with Deps $pid; " ;;
    esac
  done
  carried=$(carried_by "$id")
  [ -n "$carried" ] && intake_note+="+$carried (amending it) — spec together; "
  return 1
}

# ── A brief folds a bug only by saying so: `> **Folds:**` (LVI-011) ────────
#
# A client's BRF-069 went Decided naming BUG-066 and BUG-068 and reversing
# their design; seven minutes later an unattended spec run drafted BUG-068 to
# the rejected option and took it to ready, and BUG-066 was built the same
# way. This list offered the brief and the bugs as unrelated rows.
#
# The link is an explicit header, never prose. The same brief named BUG-067
# as out of scope, so "names a bug in References or Problem" would have
# withheld a bug nobody meant to fold, and pre-launch workers answer their own
# gates, so a wrong match goes unnoticed. Only the bugs on a Decided or
# Planned brief's Folds line are withheld, with the brief named as the reason;
# the brief's own spec run consumes them `--folded` into its plan.
folded_map=""   # lines: <bug-id>\t<brief-id>\t<brief-status>
for brief_md in plans/briefs/*.md; do
  [ -f "$brief_md" ] || continue
  folds=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Folds:\*\*' "$brief_md" 2>/dev/null \
          | sed -E 's/^.*\*\*Folds:\*\*[[:space:]]*//' || true)
  [ -n "$folds" ] || continue
  bstatus=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Status:\*\*' "$brief_md" 2>/dev/null \
            | sed -E 's/^.*\*\*Status:\*\*[[:space:]]*//; s/[[:space:]].*$//' || true)
  case "$bstatus" in Decided|Planned) ;; *) continue ;; esac
  bid=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*ID:\*\*' "$brief_md" 2>/dev/null | grep -oE "($LV_BRF_RE)-[0-9]+" || true)
  [ -n "$bid" ] || bid=$(basename "$brief_md" | grep -oE "^($LV_BRF_RE)-[0-9]+" || true)
  [ -n "$bid" ] || continue
  for fb in $(printf '%s\n' "$folds" | grep -oE "($LV_BUG_RE)-[0-9]+" || true); do
    folded_map+="$fb"$'\t'"$bid"$'\t'"$bstatus"$'\n'
  done
done

# folded_skip <bug-id> — exit 0 when a brief folds it (reason already on stderr).
folded_skip() {
  local hit
  hit=$(printf '%s' "$folded_map" | awk -F'\t' -v b="$1" '$1 == b { print $2 "\t" $3; exit }')
  [ -n "$hit" ] || return 1
  if [ "${hit#*$'\t'}" = "Planned" ]; then
    not_offered "$1" "folded into ${hit%%$'\t'*}, already planned — consume it there: lv-bug-consume.sh $1 <its plan> --folded"
  else
    not_offered "$1" "folded into ${hit%%$'\t'*}"
  fi
  return 0
}

# folds_note <brief-id> → "folds BUG-a,BUG-b — …; " or nothing
folds_note() {
  local ids
  ids=$(printf '%s' "$folded_map" | awk -F'\t' -v b="$1" '$2 == b { printf "%s%s", s, $1; s = "," }')
  [ -n "$ids" ] && printf 'folds %s — consume each --folded into the plan; ' "$ids"
  return 0
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
  folded_skip "$bug_id" && continue
  # Blocked by a recorded, human-written reason. To stderr, so a human running
  # this sees what is held back and why, while the stdout a dispatcher parses
  # carries only work that can be done.
  if blocked_why=$(brief_is_blocked "$bug_md"); then
    echo "  ($bug_id blocked — $blocked_why)" >&2
    continue
  fi
  intake_skip "$bug_md" "$bug_id" && continue
  if [ $bugs_found -eq 0 ]; then echo "# bugs"; fi
  printf "%s\t%s\t%s%s%s\n" "$bug_id" "$severity" "$(gate_note "$bug_id")" "$intake_note" "$title"
  bugs_found=1
  found=1
done

# --- Bugs hand-filed straight into triaged/ ────────────────────────────────
#
# `triaged/` is normally reached only by lv-bug-consume.sh, at the moment a
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
  folded_skip "$bug_id" && continue
  if blocked_why=$(brief_is_blocked "$bug_md"); then
    echo "  ($bug_id blocked — $blocked_why)" >&2
    continue
  fi
  intake_skip "$bug_md" "$bug_id" && continue
  if [ $bugs_found -eq 0 ]; then echo "# bugs"; fi
  printf "%s\t%s\t%s%s%s (hand-filed into triaged/, no plan)\n" "$bug_id" "$severity" "$(gate_note "$bug_id")" "$intake_note" "$title"
  bugs_found=1
  found=1
done

# --- Decided briefs ---
#
# A BRIEF NEVER LEAVES `## Decided`, SO SOMETHING HAS TO ASK WHETHER IT IS DONE
#
# A bug drops off this list by moving: lv-bug-consume.sh renames open/ →
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
# there, or — for a brief whose field was never written — lv-plan-id.sh finding
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
  "$SELF_DIR/lv-plan-id.sh" "$brief_id" --peek 2>/dev/null \
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
# (lv-brief-block.sh writes and clears it). It is not silent: the reason goes
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
      brief_id=$(echo "$link" | grep -oE "($LV_BRF_RE)-[0-9]+" | head -1)
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
      printf "%s\t%s\t%s%s%s\n" "$brief_id" "$name" "$(gate_note "$brief_id")" "$(folds_note "$brief_id")" "$desc"
      briefs_found=1
      found=1
    fi
  done < "plans/briefs/INDEX.md"
fi

exit $((1 - found))
