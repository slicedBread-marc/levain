#!/usr/bin/env bash
# wf-plan-id.sh <source-id>
#
# Decides the plan ID for the brief or bug being specced, and says why.
#
# THE RULE, AND WHERE IT BREAKS
#
# A plan inherits its number from the source artifact: BRF-041 → PLN-041,
# BUG-043 → PLN-043. The number was allocated when the brief or bug was
# created, so allocating a second one would burn an ID and break the link
# between the two names for one piece of work.
#
# That rule assumes the inherited number is free, and it is not always. In
# client-e, BRF-091 would have inherited PLN-091 — already allocated to an
# unrelated, completed plan with a folder on disk. wf-spec forbids the counter
# and gives no collision procedure, so the only two moves available were
# overwriting a completed plan or departing from the documented rule (WFI-011).
#
# So the rule gets an exception with a defined shape: inherit when free,
# allocate when taken, and say which happened. Both branches are legal; a
# silent overwrite is not.
#
# THE THIRD CASE: THE NUMBER IS HELD BY THIS SAME WORK
#
# "Taken" was read as "taken by SOMEBODY ELSE", and that is not the only way a
# folder gets there. A spec run writes plans/PLN-039-.../plan.md, reviews it,
# and dies before the REGISTRY row or the commit. Redispatched on the same bug,
# the collision check finds the folder its own previous attempt left behind and
# allocates PLN-040 — so following the documented instruction literally creates
# a SECOND plan for one bug and orphans the reviewed one (client-a WFI-121).
#
# A crashed unattended run is routine, so a plan folder derived from the very
# artifact being specced is a RESUME, not a collision. It is recognised by
# plan.md's header FIELD naming that artifact: `> **Bug:** BUG-039` or
# `> **Brief:** ... BRF-041`. Nobody else's plan says that in a field — though
# plenty say it in prose, which is why prose does not count (WFI-168).
#
# THE ANSWER IS ONLY TRUE AT THE MOMENT IT IS GIVEN
#
# Every branch below reads the registry and the plans/ directory as they are
# right now. A spec run asks this question early, then explores the codebase,
# drafts a goal and waits on the user — minutes in which another session can
# create the very folder that would have changed the answer.
#
# client-a watched exactly that on BUG-075: two sessions both got
# `PLAN_ID=PLN-075, COLLISION=, RESUME=false`, seconds apart and both correct,
# and both drafted a plan under that number with different slugs. The duplicate
# reached HEAD, and wf-registry-add.sh's refusal — the last backstop, after the
# folder is written and committed — was the only thing that caught it (WFI-147).
#
# So the answer is not durable and callers must not treat it as one: ask again
# immediately before creating the folder, which is the moment the ID is actually
# taken. The call is cheap and idempotent, and the second answer is the one that
# has seen the other session's work. `/wf-spec` step 5 does this.
#
# Idempotent is a promise this script had to be made to keep. The collision
# branch used to allocate on EVERY call, so the documented double-call burned a
# number each time and the two answers disagreed (WFI-177). A reallocation is
# now reserved against the source artifact and re-used — see the bottom of this
# file.
#
# --peek answers without taking anything: no allocation, no reservation, no
# claim follow. For a human or a diagnostic asking "what would this say?", which
# before had no read-only form and cost an artifact number to ask (WFI-175).
#
# Output (eval-friendly):
#   PLAN_ID='PLN-091'          the ID to use
#   PLAN_NUM='091'
#   PLAN_ID_INHERITED=true     false when the number was taken and reallocated
#   PLAN_ID_COLLISION='...'    what held the inherited number (empty if free)
#   PLAN_ID_RESUME=true        the folder is this same artifact's own, from an
#                              earlier attempt — keep the number, keep the work
#   PLAN_ID_DIR='plans/...'    on resume, the folder to continue in. Its slug is
#                              the earlier attempt's, which is rarely the one
#                              this run would have chosen — write there anyway,
#                              it owns the REGISTRY row (empty when not a resume)
#
# A RESUME MAY CARRY A DIFFERENT NUMBER. `PLAN_ID_RESUME=true` with
# `PLAN_ID_INHERITED=false` means the earlier attempt had itself collided and
# wrote under a reallocated number — the folder is still this artifact's, and
# PLAN_ID names the number to keep using. Read PLAN_ID, never the source's own
# number, when creating or committing anything.
#
# Exit 0 on success, 1 on bad usage or an unusable registry.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

src=""
peek=false
while [ $# -gt 0 ]; do
  case "$1" in
    --peek|--dry-run) peek=true; shift ;;
    -*) echo "Error: unknown option '$1'" >&2
        echo "Usage: $0 <BRF-NNN|BUG-NNN|PLN-NNN> [--peek]" >&2; exit 1 ;;
    *)  [ -z "$src" ] || { echo "Usage: $0 <BRF-NNN|BUG-NNN|PLN-NNN> [--peek]" >&2; exit 1; }
        src="$1"; shift ;;
  esac
done
[ -n "$src" ] || { echo "Usage: $0 <BRF-NNN|BUG-NNN|PLN-NNN> [--peek]" >&2; exit 1; }

id=$(printf '%s' "$src" | grep -oE '^(PLN|BUG|BRF)-[0-9]+' || true)
[ -n "$id" ] || { echo "Error: '$src' is not a PLN/BUG/BRF id" >&2; exit 1; }

cd "$(wf_develop_root)"
REGISTRY="plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 1; }

num="${id#*-}"
prefix="${id%%-*}"

# ── The claim has to follow the number ────────────────────────────────────
#
# "Claims key on the artifact number, so BRF-002 and the PLN-002 it becomes are
# one claim" is the contract, and it holds right up until this script hands back
# a DIFFERENT number. Then the session's claim on 081 covers nothing that
# matters, and the plan it is writing under 101 is unclaimed.
#
# client-a's WFI-161: the moment wf-registry-add.sh committed the PLN-101
# draft row — deliberately early, per WFI-140 — the daemon saw a dispatchable
# draft with no claim and spawned a SECOND spec worker onto the plan the first
# session was still writing. It was caught by wf-guard-write.sh refusing the
# first session's next edit, which is the last line of defence, not the
# intended one. On a 60s sweep, any plan taking over a minute to write hits
# this window.
#
# So the claim is extended here, at the point the number changes, to the same
# session that holds the source. Not moved: the source claim is still this
# session's and still true. Silent and best-effort — an unclaimed caller (an
# attended session that never claimed, a preview) gets no claim invented for it.
wf_claim_follow() {
  local new_id="$1" src_dir new_dir holder
  src_dir=$(wf_claim_dir "$id" 2>/dev/null) || return 0
  wf_claim_live "$src_dir" 2>/dev/null || return 0
  wf_claim_mine "$src_dir" 2>/dev/null || return 0
  new_dir=$(wf_claim_dir "$new_id" 2>/dev/null) || return 0
  # Somebody already holds the new number — that is a real conflict and not
  # this script's to resolve. Leave it; the caller's next write is refused by
  # wf-guard-write.sh with a message naming the holder.
  ! wf_claim_live "$new_dir" 2>/dev/null || return 0
  holder=$(sed -n '2p' "$src_dir/.wf-claim" 2>/dev/null | tr -cd '0-9')
  wf_claim_write "$new_dir" "${holder:-}" 2>/dev/null || return 0
  wf_event claim-follow "$id" "claim extended to $new_id — the number was reallocated (WFI-161)"
}

# Already a plan: nothing to decide.
if [ "$prefix" = "PLN" ]; then
  wf_emit PLAN_ID           "$id"
  wf_emit PLAN_NUM          "$num"
  wf_emit PLAN_ID_INHERITED "true"
  wf_emit PLAN_ID_COLLISION ""
  wf_emit PLAN_ID_RESUME    "false"
  wf_emit PLAN_ID_DIR       ""
  wf_emit PLAN_ID_CLAIMED_BY    "${blocked_id:-}"
  wf_emit PLAN_ID_CLAIMED_STATE "${blocked_id_state:-}"
  exit 0
fi

# Taken means either half is taken — a registry row without a folder is a plan
# mid-creation, and a folder without a row is a plan whose row was lost. Either
# one is somebody else's number.
collision=""
if grep -q "^| PLN-${num} |" "$REGISTRY" 2>/dev/null; then
  collision="REGISTRY row PLN-${num}"
fi
existing_dir=$(ls -d "plans/PLN-${num}-"* 2>/dev/null | head -1 || true)
if [ -n "$existing_dir" ]; then
  collision="${collision:+$collision, }folder $existing_dir"
fi

# A number is unique across ALL types, not just among plans.
#
# This asked "is PLN-${num} taken?" and stopped, so a BRF or BUG holding the
# same number — a different artifact, other work, somebody else's — was
# invisible and the inherit went ahead. client-a ended up with BRF-210
# ("make the guarded path the easy one", held at Exploring) and PLN-210
# (publish-path-reports-elision, inherited from BUG-210 and long since
# complete) as unrelated artifacts sharing one number. Claims key on the
# number, so claiming either silently locked both, and `--list` resolved the
# brief's claim to the plan's name (WFI-215).
#
# The SOURCE is exempt: BUG-210 legitimately holds 210 when it is BUG-210 being
# specced, and that is the whole inheritance rule. Every other type is a
# collision, and the reallocation branch below already knows what to do with
# one — it allocates a fresh number and says so.
#
# wf_artifacts_with_number is the one definition of "in use", shared with
# wf-claim.sh — see its header for why there must be only one.
while read -r other where; do
  [ -n "$other" ] || continue
  [ "$other" = "$prefix" ] && continue        # the source's own number
  [ "$other" = "PLN" ] && continue            # covered by the two checks above
  collision="${collision:+$collision, }$where"
done <<< "$(wf_artifacts_with_number "$num")"

if [ -z "$collision" ]; then
  wf_emit PLAN_ID           "PLN-${num}"
  wf_emit PLAN_NUM          "$num"
  wf_emit PLAN_ID_INHERITED "true"
  wf_emit PLAN_ID_COLLISION ""
  wf_emit PLAN_ID_RESUME    "false"
  wf_emit PLAN_ID_DIR       ""
  wf_emit PLAN_ID_CLAIMED_BY    "${blocked_id:-}"
  wf_emit PLAN_ID_CLAIMED_STATE "${blocked_id_state:-}"
  exit 0
fi

# Held by this same artifact's own earlier attempt? Then it is not a collision.
#
# The evidence is a header FIELD, not header prose. TEMPLATE.md writes
# `> **Bug:** BUG-NNN — …` and `> **Brief:** briefs/BRF-NNN-….md`; those lines
# state what the plan is FOR, and nothing else in the document does.
#
# The old test read every line before the first `##` heading, which is the same
# block but is not the same thing — the block also holds whatever a previous
# session wrote there in prose. client-a's WFI-168: PLN-137 carried
# `> **Duplicate risk:** this plan was drafted under a dispatch naming
# **BUG-137**. Commit 671983e renumbered that artifact to **BUG-136**…` — a note
# whose entire purpose was to record that the plan is NOT BUG-137's. It matched
# on the bare number, so BUG-137 was answered RESUME=true onto a parked,
# gated duplicate; obeying that would have written BUG-137's fix plan over a
# document awaiting a human decision and reused its REGISTRY row and tags.
#
# A note explaining a renumber is exactly the text a renumbered-away plan
# carries, so the false match is not an edge case — it is the documented one.
#
# Fields are matched wherever they sit: TEMPLATE.md puts them in the header
# block, and wf-spec's bug link-back step has been observed writing them under
# `## Goal`. Both are the field; neither is prose.
#
# AND IT IS THE FIELD'S VALUE, NOT THE FIELD'S LINE
#
# Narrowing from "the header block" to "the header fields" was not enough,
# because a field line is not all field: TEMPLATE.md writes
# `> **Bug:** BUG-NNN — <title>`, and the title is free text on the same line.
# A bug titled after another bug — which is how every follow-up is titled, and
# the whole substance of WFI-176 one file over — puts a second artifact ID on
# the line, and matching anywhere in it reads that as a claim.
#
# So the value is the FIRST id token after the `:**` marker, and only that is
# compared. `> **Bug:** BUG-141 — BUG-131's console encoding fix…` claims
# BUG-141 and says nothing about BUG-131. `> **Brief:** briefs/BRF-041-x.md`
# claims BRF-041.
#
# claims_this <plan-dir> — 0 if that plan's fields name the artifact being
# specced. The one test, used for both searches below.
claims_this() {
  [ -f "$1/plan.md" ] || return 1
  awk -v want="$id" '
    /^[ \t]*>?[ \t]*\*\*(Bug|Brief|Source|From):\*\*/ {
      line = $0
      sub(/^.*:\*\*/, "", line)              # everything after the field marker
      if (match(line, /(PLN|BUG|BRF)-[0-9]+/)) {
        if (substr(line, RSTART, RLENGTH) == want) { found = 1; exit }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$1/plan.md" 2>/dev/null
}

# ── A resume target has to be a plan still being drafted ──────────────────
#
# `claims_this` answers "does this folder name the artifact being specced". For
# a brief that sequences SEVERAL plans, every one of them answers yes forever:
# the header field names the brief, and nothing in it names the move. So the
# second, third and fourth moves of a brief all resolve onto the FIRST move's
# folder — and that folder is finished work.
#
# client-b' BRF-010 says so in its own Plan field: "(none — this brief
# sequences several future plans, not one)". Move 4 was answered
# PLAN_ID_RESUME=true, PLAN_ID_DIR=plans/PLN-010-animation-lab — move 1,
# complete since the previous day. Following step 5 literally ("Continue in
# $PLAN_ID_DIR, whatever slug it carries") overwrites a completed plan's
# plan.md, findings.md and progress.md (WFI-016).
#
# A plan being drafted is the only thing a spec session can continue. Draft, or
# no registry row at all — a folder mid-creation, which is WFI-169's case and
# still this artifact's to finish. Every other state means the plan left
# drafting: `ready` and `active` have a builder on them, `testing` has a tester,
# `complete` and `abandoned` are terminal. Writing into any of those is not
# resuming a draft, it is overwriting somebody else's plan, and the number is
# cheaper than the document.
#
# This does not settle which plan a later move SHOULD land in — nothing here
# can, while the only evidence is a brief ID every move shares. It settles that
# the answer is never a plan that has moved on.
resumable_plan() {
  local pid st
  pid=$(basename "$1" | grep -oE '^PLN-[0-9]+' || true)
  [ -n "$pid" ] || return 1
  st=$(wf_registry_field "$pid" state "$REGISTRY" 2>/dev/null || true)
  case "$st" in
    ""|draft) return 0 ;;
    *) blocked_state="$st"; return 1 ;;
  esac
}

# Named by the note below when a candidate was passed over for its state.
#
# PASSED OVER IS NOT INVISIBLE. A plan that names this artifact and has left
# draft is the answer to a different question, and something already asks it:
# wf-spawn.sh refuses to spawn a spec worker for a brief whose plan is past
# draft, and finds that plan through this script (client-a WFI-188). Report
# it as PLAN_ID_CLAIMED_BY/PLAN_ID_CLAIMED_STATE rather than as a resume, so
# the guard keeps its evidence and the caller still never writes into it.
blocked_state=""
blocked_dirs=""
blocked_id=""
blocked_id_state=""
note_blocked() {
  local pid
  pid=$(basename "$1" | grep -oE '^PLN-[0-9]+' || true)
  blocked_dirs="${blocked_dirs:+$blocked_dirs, }$1 ($blocked_state)"
  if [ -z "$blocked_id" ]; then
    blocked_id="$pid"
    blocked_id_state="$blocked_state"
  fi
  wf_event id-resume-blocked "$id" "$1 names $id but is $blocked_state — not a resume target (WFI-016)"
}

if [ -n "$existing_dir" ] && claims_this "$existing_dir" && ! resumable_plan "$existing_dir"; then
  note_blocked "$existing_dir"
elif [ -n "$existing_dir" ] && claims_this "$existing_dir"; then
  wf_event id-resume "$id" "PLN-${num} folder $existing_dir is this artifact's own — resuming, not reallocating"
  wf_emit PLAN_ID           "PLN-${num}"
  wf_emit PLAN_NUM          "$num"
  wf_emit PLAN_ID_INHERITED "true"
  wf_emit PLAN_ID_COLLISION ""
  wf_emit PLAN_ID_RESUME    "true"
  wf_emit PLAN_ID_DIR       "$existing_dir"
  wf_emit PLAN_ID_CLAIMED_BY    "${blocked_id:-}"
  wf_emit PLAN_ID_CLAIMED_STATE "${blocked_id_state:-}"
  exit 0
fi

# ── The resume whose number is not the inherited one ──────────────────────
#
# The search above only ever looked under the INHERITED number. But the attempt
# it is looking for is, by definition, one that already ran this script — and if
# that attempt hit the collision branch, it wrote its plan under a REALLOCATED
# number. Nothing looked there, so a resume was undetectable for exactly the
# plans that had collided, and the collision branch ran again.
#
# client-a's WFI-162: BRF-081's inherited PLN-081 was taken, so the first
# attempt wrote plans/PLN-101-headless-support-bundle/. The next dispatch of
# BRF-081 found PLN-081 taken, looked no further, and allocated PLN-102 —
# burning a counter increment and, but for the orchestrator naming PLN-101 in
# the dispatch, about to create a second plan for one brief. Every re-dispatch
# would have burned another.
#
# The header evidence does not depend on the number matching. So: before
# allocating, ask every plan folder whether it is this artifact's.
#
# Sorted, so "the first match" is the lowest number — deterministic, and the
# earliest attempt is the one that owns any REGISTRY row.
resume_dir=""
resume_extra=""
while IFS= read -r d; do
  [ -n "$d" ] || continue
  claims_this "$d" || continue
  if ! resumable_plan "$d"; then
    note_blocked "$d"
    continue
  fi
  if [ -z "$resume_dir" ]; then
    resume_dir="$d"
  else
    resume_extra="${resume_extra:+$resume_extra, }$d"
  fi
done < <(ls -d plans/PLN-[0-9]*/ 2>/dev/null | sed 's:/$::' | sort || true)

if [ -n "$resume_dir" ]; then
  resume_id=$(basename "$resume_dir" | grep -oE '^PLN-[0-9]+')
  resume_num="${resume_id#*-}"

  # More than one folder naming this source is a real duplicate, and picking
  # one is better than making a third. Say so where the skill will report it.
  note=""
  if [ -n "$resume_extra" ]; then
    note="also claimed by $resume_extra — DUPLICATE PLANS FOR $id, needs a human"
    wf_event id-duplicate "$id" "$resume_dir and $resume_extra all name $id in their header"
  fi

  wf_event id-resume "$id" "$resume_dir names $id in its header — resuming there under $resume_id, not allocating"
  $peek || wf_claim_follow "$resume_id"
  wf_emit PLAN_ID           "$resume_id"
  wf_emit PLAN_NUM          "$resume_num"
  wf_emit PLAN_ID_INHERITED "false"
  wf_emit PLAN_ID_COLLISION "$note"
  wf_emit PLAN_ID_RESUME    "true"
  wf_emit PLAN_ID_DIR       "$resume_dir"
  wf_emit PLAN_ID_CLAIMED_BY    "${blocked_id:-}"
  wf_emit PLAN_ID_CLAIMED_STATE "${blocked_id_state:-}"
  exit 0
fi

# ── The reallocation is remembered, because the question is asked twice ───
#
# This script is documented as a query — "decides the plan ID and says why" —
# and wf-spec is told to call it TWICE for exactly the right reason: the answer
# is only true at the moment it is given, and step 3 is minutes of exploration
# and drafting away from step 5 (WFI-147). Every other branch above is a pure
# read and answers the same thing twice. This one allocated.
#
# So the documented double-call burned a number every time the first call hit a
# collision, and the two calls DISAGREED. client-a's BUG-137: step 3 answered
# PLN-144, step 5 answered PLN-145 with the identical collision string and
# nothing changed in between. PLN-144 exists nowhere — no row, no folder — and
# the counter is permanently one higher (WFI-177). A single diagnostic call did
# the same thing (WFI-175), and an abandoned reallocation is how client-a
# ended up with an empty, untracked plans/PLN-136-…/ that the next run then
# treated as somebody else's number (WFI-169).
#
# A reallocation is therefore reserved against the SOURCE artifact and re-used.
# The reservation is advisory, never authoritative: it is honoured only while
# the number is still free or still holds this artifact's own unfinished folder,
# and a number somebody else has since taken drops it and allocates afresh.
#
# It lives beside the claims rather than in the registry: it records what a
# session was told, not a state of the pipeline, and nothing outside the machine
# that gave the answer has any use for it.
reserve_dir="$(wf_orch_dir)/id-reservations"
reserve_file="$reserve_dir/$id"
new_id=""

if [ -f "$reserve_file" ]; then
  reserved=$(grep -oE '^PLN-[0-9]+' "$reserve_file" 2>/dev/null | head -1 || true)
  if [ -n "$reserved" ]; then
    reserved_dir=$(ls -d "plans/${reserved}-"* 2>/dev/null | head -1 || true)
    if [ -z "$reserved_dir" ]; then
      # Still free — the same answer as last time is the honest one.
      new_id="$reserved"
      wf_event id-reserved "$id" "re-using the reservation $reserved rather than allocating again (WFI-177)"
    elif { claims_this "$reserved_dir" && resumable_plan "$reserved_dir"; } || [ ! -f "$reserved_dir/plan.md" ]; then
      # This artifact's own earlier attempt, possibly one that got no further
      # than mkdir. Continue in it rather than leaving it orphaned (WFI-169).
      resume_num="${reserved#*-}"
      wf_event id-resume "$id" "$reserved_dir is this artifact's reserved folder — resuming there"
      $peek || wf_claim_follow "$reserved"
      wf_emit PLAN_ID           "$reserved"
      wf_emit PLAN_NUM          "$resume_num"
      wf_emit PLAN_ID_INHERITED "false"
      wf_emit PLAN_ID_COLLISION "$collision"
      wf_emit PLAN_ID_RESUME    "true"
      wf_emit PLAN_ID_DIR       "$reserved_dir"
  wf_emit PLAN_ID_CLAIMED_BY    "${blocked_id:-}"
  wf_emit PLAN_ID_CLAIMED_STATE "${blocked_id_state:-}"
      exit 0
    else
      wf_event id-reservation-lost "$id" "$reserved was reserved for $id but $reserved_dir now belongs to another artifact — allocating again"
      $peek || rm -f "$reserve_file"
    fi
  fi
fi

# Whatever was passed over for its state belongs in the answer, not only in the
# event log. The caller is about to be told the number was reallocated, and
# "PLN-010 names this brief but is complete" is the difference between a
# reallocation that looks arbitrary and one a human can check in a second.
if [ -n "$blocked_dirs" ]; then
  collision="${collision:+$collision; }already-claimed by $blocked_dirs — not resumable (WFI-016)"
fi

# Nothing reserved, or the reservation was lost. Allocate a fresh number —
# wf-counter-next.sh advances past anything already in use, so this cannot land
# on a second collision — and record that the link between source number and
# plan number was broken deliberately.
if [ -z "$new_id" ]; then
  if $peek; then
    # A peek never takes. The number reported is the one the next real call
    # would take and reserve, which is all a diagnostic caller wants to know.
    new_id=$("$SELF_DIR/wf-counter-next.sh" PLN --peek)
  else
    new_id=$("$SELF_DIR/wf-counter-next.sh" PLN)
    mkdir -p "$reserve_dir"
    printf '%s\n' "$new_id" > "$reserve_file"
  fi
fi
new_num="${new_id#*-}"

wf_event id-collision "$id" "PLN-${num} taken ($collision) — allocated $new_id"
$peek || wf_claim_follow "$new_id"

wf_emit PLAN_ID           "$new_id"
wf_emit PLAN_NUM          "$new_num"
wf_emit PLAN_ID_INHERITED "false"
wf_emit PLAN_ID_COLLISION "$collision"
wf_emit PLAN_ID_RESUME    "false"
wf_emit PLAN_ID_DIR       ""
  wf_emit PLAN_ID_CLAIMED_BY    "${blocked_id:-}"
  wf_emit PLAN_ID_CLAIMED_STATE "${blocked_id_state:-}"
