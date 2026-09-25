#!/usr/bin/env bash
# lv-review-guard.sh <PLN-NNN> --record | --check
#
# Did the review agent write to the plan it was asked to review?
#
# WHY THIS EXISTS
#
# The architecture review is a SECOND OPINION. Its whole value is that
# something other than the session holding the pen looked at the plan, and the
# session then decides what to record. client-b WFI-017 and WFI-018 are the
# two halves of what happens when the reviewer holds the pen instead:
#
#   WFI-017. The agent wrote its own `## Review` block into plan.md, ran
#   lv-review-stamp.sh itself, and edited a Tests-table row. The findings it
#   wrote to the file (3 notes) were not the findings it handed back in its
#   response (4 notes, disjoint). Two review results for one round, one of them
#   already stamped into the file as the record. It also labelled its block
#   "(unattended, round 1 of 3)" in an attended session, because an agent has
#   no way to know which path spawned it.
#
#   WFI-018. The agent wrote "Approved with notes (0 Critical)" into plan.md,
#   stamped it, and that verdict became the spec-approval gate's question text.
#   An independent read-only review of the same plan returned Blocked on a
#   Critical: a restore rehearsal that would have replicated a scratch database
#   into the LIVE production replica path. The human was shown "Approved with
#   notes" as the thing to approve.
#
# The prompt now says REPORT ONLY and the agent is spawned with a read-only
# tool profile, which is the actual fix. This is the check that the fix held —
# because the failure it guards against is SILENT. A verdict in plan.md looks
# identical whoever wrote it, and WFI-018 was caught by a re-review that
# happened to be run by hand. Nothing in the pipeline would have caught it.
#
# WHAT IS WATCHED
#
# plan.md and findings.md, whole-file, raw. Not wf_plan_body_fingerprint: that
# deliberately excludes `## Review`, which is precisely the section a review
# agent writes to. The question here is "did any byte move", not "did the
# specification change".
#
# Output (eval-friendly, on both modes):
#   REVIEW_GUARD=clean|touched|unrecorded
#   REVIEW_GUARD_TOUCHED='plan.md findings.md'   files whose hash moved
#   REVIEW_GUARD_DIRTY_AT_RECORD=true|false      (--record) a watched file had
#                                                uncommitted edits — commit them
#                                                first (see CONCURRENT below)
#   REVIEW_GUARD_CONCURRENT=true|false           (--check) HEAD's reflog moved
#                                                during the round: a stash, reset
#                                                or merge by another worker on
#                                                this shared checkout, which can
#                                                move an uncommitted plan.md by
#                                                itself (a client's LVI-005 — the
#                                                reviewer was blamed for it)
#   REVIEW_GUARD_REVERTABLE=true|false           every touched file was clean in
#                                                git at --record, so
#                                                `git checkout --` restores what
#                                                the session had. false means
#                                                the session's OWN uncommitted
#                                                edits are in there too and a
#                                                revert would take them with it.
#
# Exit 0 clean, 3 touched, 1 no such plan. `unrecorded` (--check with no
# --record before it) exits 0: a guard that was never armed is not evidence of
# anything, and failing the review over it would be worse than the miss.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

raw_id="${1:?Usage: $0 <$LV_PLN-NNN> --record|--check}"
mode="${2:?Usage: $0 <$LV_PLN-NNN> --record|--check}"

plan_id=$(printf '%s' "$raw_id" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <$LV_PLN-NNN> --record|--check" >&2; exit 1; }

case "$mode" in
  --record|--check) ;;
  *) echo "Unknown mode: $mode (expected --record or --check)" >&2; exit 1 ;;
esac

ROOT="$(wf_develop_root)"
slug=$(wf_registry_field "$plan_id" slug "$ROOT/plans/REGISTRY.md")
if [ -z "$slug" ]; then
  echo "$plan_id: no REGISTRY row — nothing to guard" >&2
  exit 1
fi
PLAN_DIR="$ROOT/plans/${plan_id}-${slug}"
[ -d "$PLAN_DIR" ] || { echo "$plan_id: no plan folder at $PLAN_DIR" >&2; exit 1; }

WATCHED="plan.md findings.md"

# hash_of <file> → sha1, or the literal `absent`. A file the agent CREATES is a
# write too, so "missing" has to be a recordable value rather than empty.
hash_of() {
  [ -f "$1" ] || { printf 'absent'; return 0; }
  shasum "$1" 2>/dev/null | awk '{print $1}'
}

# dirty_at_record <file> → true when git already had uncommitted changes for it.
# Decides REVIEW_GUARD_REVERTABLE: a revert is only safe on a file whose only
# changes are the agent's.
dirty_of() {
  local rel="${1#"$ROOT"/}"
  if [ -n "$(cd "$ROOT" && git status --porcelain -- "$rel" 2>/dev/null)" ]; then
    printf 'true'
  else
    printf 'false'
  fi
}

STATE_DIR="$(wf_orch_dir)/review-guard"
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/$plan_id"

# reflog_since <epoch> → HEAD reflog entries written at or after it, one per
# line. The reflog's own time (%gd under --date=unix), not the commit's: a
# stash's `reset: moving to HEAD` points at an old commit.
reflog_since() {
  (cd "$ROOT" && git reflog --date=unix --format='%gd %gs' HEAD 2>/dev/null) \
    | awk -v t="$1" '{ ts = $1; gsub(/[^0-9]/, "", ts); if (ts + 0 >= t + 0) print }'
}

if [ "$mode" = "--record" ]; then
  dirty_any=false
  for name in $WATCHED; do
    [ "$(dirty_of "$PLAN_DIR/$name")" = true ] && dirty_any=true
  done
  {
    wf_emit GUARD_PLAN "$plan_id"
    wf_emit GUARD_AT   "$(wf_now)"
    wf_emit GUARD_EPOCH "$(date +%s)"
    for name in $WATCHED; do
      key=$(printf '%s' "$name" | tr '.a-z' '_A-Z')
      wf_emit "GUARD_HASH_$key"  "$(hash_of "$PLAN_DIR/$name")"
      wf_emit "GUARD_DIRTY_$key" "$(dirty_of "$PLAN_DIR/$name")"
    done
  } > "$STATE"
  wf_emit REVIEW_GUARD clean
  wf_emit REVIEW_GUARD_TOUCHED ""
  wf_emit REVIEW_GUARD_REVERTABLE true
  wf_emit REVIEW_GUARD_DIRTY_AT_RECORD "$dirty_any"
  echo "$plan_id: review guard armed on $WATCHED" >&2
  if $dirty_any; then
    echo "$plan_id: WARNING — the plan has uncommitted edits. Commit them before the review: on a shared" >&2
    echo "  checkout a concurrent stash or merge can move them mid-round (LVI-005)." >&2
  fi
  exit 0
fi

if [ ! -f "$STATE" ]; then
  wf_emit REVIEW_GUARD unrecorded
  wf_emit REVIEW_GUARD_TOUCHED ""
  wf_emit REVIEW_GUARD_REVERTABLE false
  echo "$plan_id: review guard was never armed — --record before spawning the reviewer" >&2
  exit 0
fi

touched=""
revertable=true
for name in $WATCHED; do
  key=$(printf '%s' "$name" | tr '.a-z' '_A-Z')
  was=$(wf_gate_field "$STATE" "GUARD_HASH_$key")
  now=$(hash_of "$PLAN_DIR/$name")
  [ "$was" = "$now" ] && continue
  touched="${touched:+$touched }$name"
  [ "$(wf_gate_field "$STATE" "GUARD_DIRTY_$key")" = "true" ] && revertable=false
done

if [ -z "$touched" ]; then
  wf_emit REVIEW_GUARD clean
  wf_emit REVIEW_GUARD_TOUCHED ""
  wf_emit REVIEW_GUARD_REVERTABLE true
  exit 0
fi

since=$(wf_gate_field "$STATE" GUARD_EPOCH)
concurrent=false
moves=""
[ -n "$since" ] && moves=$(reflog_since "$since")
[ -n "$moves" ] && concurrent=true

wf_emit REVIEW_GUARD touched
wf_emit REVIEW_GUARD_TOUCHED "$touched"
wf_emit REVIEW_GUARD_REVERTABLE "$revertable"
wf_emit REVIEW_GUARD_CONCURRENT "$concurrent"
if $concurrent; then
  {
    echo "$plan_id: $touched changed during the review, AND HEAD moved in this checkout meanwhile —"
    printf '%s\n' "$moves" | sed 's/^/    /'
    echo "  A stash, reset or merge by another worker can move uncommitted plan text by itself, so"
    echo "  this may not be the reviewer's write. Compare with the committed revision"
    echo "  (git diff HEAD -- plans/${plan_id}-${slug}/) before blaming the agent; if what the reviewer"
    echo "  read cannot be known, run the round again. Commit the revision before --record next time."
  } >&2
  exit 3
fi
{
  echo "$plan_id: the review agent WROTE to the plan it was reviewing — $touched"
  echo "  A review is a second opinion, not an edit. Whatever it wrote is now"
  echo "  competing with the verdict it handed back, and they have been observed"
  echo "  to disagree (client-b WFI-017)."
  if [ "$revertable" = "true" ]; then
    echo "  Discard the agent's writes, then record the verdict from its RESPONSE yourself:"
    for name in $touched; do
      echo "    git checkout -- plans/${plan_id}-${slug}/$name"
    done
  else
    echo "  NOT safely revertable: at least one of those files already carried your own"
    echo "  uncommitted edits, so a checkout would take them too. Read the diff and"
    echo "  remove the agent's block by hand."
  fi
  echo "  Then file it: scripts/lv-exec.sh lv-issue.sh lv-spec \"review agent wrote to $touched\" ..."
} >&2
exit 3
