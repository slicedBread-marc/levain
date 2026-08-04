#!/usr/bin/env bash
# wf-review-status.sh <PLN-NNN>
#
# Answers one question: is the review verdict on this plan a verdict on the
# plan as it stands right now?
#
# WHY THIS EXISTS
#
# The spec-approval gate asks a human "approve this reviewed plan?", and every
# skill downstream treats the presence of a verdict as proof one was obtained.
# Two ways that goes wrong, both observed together in client-a (WFI-046):
#
#   1. WRONG PLACE. The verdict of record is `plan.md` `## Review`. A replan
#      session wrote it to `findings.md` under `## Spec Review` instead —
#      plausible, because the reviewer legitimately copies actionable items
#      into findings.md. wf-attend looked only at plan.md, found the template
#      placeholder, and would have told the operator to file a harness fault
#      and re-run a review that already existed one file over.
#
#   2. WRONG VERSION. Both recorded verdicts were `Blocked` on the
#      PRE-amendment plan. The amendment then resolved every finding and the
#      plan went to the gate — so a plan carrying six resolved Criticals sat at
#      an approval gate with no independent verdict on the resolutions. The
#      verdict was real, auditable, and about a document that no longer existed.
#
# A stale verdict is worse than a missing one: missing is visible, stale reads
# as done. So this reports both facts mechanically instead of leaving them to a
# reader's eye.
#
# Output (eval-friendly):
#   REVIEW_LOCATION=plan|findings|none
#   REVIEW_RESULT='Approved with notes'   (empty when none)
#   REVIEW_DATE=2026-08-03                (empty when undated)
#   AMENDMENT_DATE=2026-08-04             (empty when never amended)
#   REVIEW_STALE=true|false|unknown       (true = amended since the verdict)
#   REVIEW_STAMPED=true|false             (the verdict names the text it judged)
#
# When the review carries a `Plan-Hash:` stamp (wf-review-stamp.sh), staleness
# is decided by comparing that hash with the plan as it stands — a true/false
# answer, whatever the dates say.
#
# Without a stamp it falls back to dates. REVIEW_STALE is then true when the
# amendment is newer, or when the review carries no date at all — a verdict
# nobody dated cannot be shown to postdate anything. It is `unknown` when the
# two share a date, which day-granular timestamps cannot order; anything other
# than `false` wants a human's eye. `unknown` is why the stamp exists
# (WFI-069): wf-spec's replanning gate requires `false`, and a same-day replan
# could never produce one.
#
# Exit 0 always. This reports; the caller decides.

set -euo pipefail

plan_id="${1:-}"
if ! printf '%s' "$plan_id" | grep -qE '^PLN-[0-9]+'; then
  echo "Usage: $0 <PLN-NNN>" >&2
  exit 1
fi
plan_id=$(printf '%s' "$plan_id" | grep -oE '^PLN-[0-9]+')

# Registry work is develop-root work: the main worktree is always the first one
# git lists, and plans/ exists only there. Written inline, as the other
# non-orchestrator scripts do — deliberately NOT named wf_develop_root, which
# is wf-orch-lib.sh's function with a different fallback contract.
ROOT=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || true
[ -n "$ROOT" ] || ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")

plan_dir=""
for d in "$ROOT"/plans/${plan_id}-*/; do
  [ -d "$d" ] && { plan_dir="${d%/}"; break; }
done

# Single-quoted with embedded quotes escaped, because callers run this through
# `eval` (wf-attend step 1, wf-spec step 6). Reviewer prose is full of
# apostrophes — "it's", "the reviewer's call" — and an unescaped one closes the
# quote early, runs the next word as a command, and loses every variable
# emitted after it. Same failure as BUG-094, which is why wf-plan-info.sh
# escapes identically.
emit_one() {
  printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}

emit() {
  emit_one REVIEW_LOCATION "${1:-none}"
  emit_one REVIEW_RESULT   "${2:-}"
  emit_one REVIEW_DATE     "${3:-}"
  emit_one AMENDMENT_DATE  "${4:-}"
  emit_one REVIEW_STALE    "${5:-false}"
  emit_one REVIEW_STAMPED  "${6:-false}"
}

if [ -z "$plan_dir" ]; then
  emit none "" "" "" false false
  exit 0
fi

plan_file="$plan_dir/plan.md"
findings_file="$plan_dir/findings.md"

# Body of a `## <name>` section. Matched by PREFIX, not equality: findings.md dates its sections in the
# heading itself (`## Spec Review — 2026-08-03`), so an equality test finds
# nothing at all there.
section_body() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 0
  awk -v want="$heading" '
    /^## / {
      name = $0; sub(/^## [ \t]*/, "", name)
      sub(/[ \t]+$/, "", name)
      inside = (index(name, want) == 1) ? 1 : 0
      next
    }
    inside { print }
  ' "$file"
}

# A review's `Result:` line, wherever it sits in the section AND wherever it
# sits in the line. Both spellings are in the field: the template writes
# `**Result:** Approved` on its own line, and the prose form a replan session
# produced buries it mid-sentence ("...review run at the spec-approval gate.
# Result: Blocked"). Anchoring at line start finds the first and silently
# misses the second, which is the same failure as not looking at all.
#
# The LAST Result line, not the first: a plan that went several rounds records
# every one, and the verdict that matters is the most recent. Trimmed at the
# first em-dash so a gate question carries "Approved with notes" rather than a
# paragraph of reviewer commentary.
# Real verdict lines: any line naming a Result, minus the template's own,
# which is recognisable by listing every verdict at once.
result_lines() {
  printf '%s\n' "$1" \
    | { grep -iE 'result:' || true; } \
    | { grep -v 'Approved | Approved with notes | Blocked' || true; }
}

result_of() {
  result_lines "$1" | tail -1 \
    | sed -E 's/.*[Rr]esult:[ \t]*//; s/\*+//g; s/[ \t]*—.*$//; s/^[ \t]+//; s/[ \t]+$//'
}

# The LATEST date in a block: a multi-round record carries one per round, and
# the current verdict is the newest.
latest_date_of() {
  printf '%s\n' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -r | head -1 || true
}

review_location=none
review_body=""

# 1. The place the verdict belongs.
#
# "Filled" is decided by the presence of a real `Result:` line, NOT by whether
# the section is blockquoted. That distinction matters: the shipped template
# and wf-spec's own example both write the record AS blockquote lines
# (`> **Result:** Approved with notes`), so treating every `>` line as
# scaffolding reports a correctly-filed review as missing — which is precisely
# the false "harness fault" this script exists to prevent. Caught against
# client-a's PLN-018, whose two rounds are recorded exactly as documented.
#
# The template's own line is excluded by its shape: it is a menu of every
# possible verdict (`Approved | Approved with notes | Blocked`), and a real one
# names exactly one.
body=$(section_body "$plan_file" "Review")
if [ -n "$(result_lines "$body")" ]; then
  review_location=plan
  review_body="$body"
else
  # 2. Where a replan session has been observed to put it instead. Reading it
  #    here is not an endorsement — it stops wf-attend declaring a fault over a
  #    review that exists, and lets the caller say where it actually is.
  for heading in "Spec Review" "Review"; do
    body=$(section_body "$findings_file" "$heading")
    if printf '%s\n' "$body" | grep -qiE 'result:'; then
      review_location=findings
      review_body="$body"
      break
    fi
  done
fi

review_result=""
review_date=""
if [ "$review_location" != "none" ]; then
  review_result=$(result_of "$review_body")
  review_date=$(latest_date_of "$review_body")
  # findings.md dates its sections in the HEADING ("## Spec Review — 2026-08-03"),
  # which section_body does not return. Read it from the heading rather than
  # splicing it into the body — result_of reads that same body.
  if [ -z "$review_date" ] && [ "$review_location" = "findings" ]; then
    review_date=$(latest_date_of "$({ grep -iE '^## (Spec )?Review' "$findings_file" || true; })")
  fi
fi

amendment_body=$(section_body "$plan_file" "Amendments")
amendment_unquoted=$(printf '%s\n' "$amendment_body" | { grep -vE '^[ \t]*>' || true; })
amendment_date=$(latest_date_of "$amendment_unquoted")

# Three answers, not two. Dates are day-granular, and a plan reviewed and
# amended on the SAME day is the ordinary case — review, findings, amendment,
# re-review all inside one session. Calling that stale would force a pointless
# re-review nearly every time; calling it current would wave through the exact
# ordering WFI-046 is about. So it reports `unknown` and lets the operator look.
stale=false
if [ "$review_location" != "none" ] && [ -n "$amendment_date" ]; then
  if [ -z "$review_date" ]; then
    stale=true
  elif [ "$review_date" = "$amendment_date" ]; then
    stale=unknown
  elif [ "$(printf '%s\n%s\n' "$review_date" "$amendment_date" | sort | tail -1)" = "$amendment_date" ]; then
    stale=true
  fi
fi

# A stamp outranks the dates entirely: it names the text that was judged, so
# "has the plan changed since?" stops being a question about calendars.
stamped=false
if [ "$review_location" != "none" ]; then
  stamp=$(printf '%s\n' "$review_body" \
          | { grep -m1 -iE 'plan-hash:' || true; } \
          | sed -E 's/.*[Pp]lan-[Hh]ash:[ \t]*//; s/\*+//g; s/[ \t]*<!--.*$//; s/[^0-9a-fA-F]//g')
  if [ -n "$stamp" ]; then
    stamped=true
    # shellcheck source=wf-orch-lib.sh
    source "$(dirname "$0")/wf-orch-lib.sh"
    now_fp=$(wf_plan_body_fingerprint "$plan_id")
    if [ -n "$now_fp" ]; then
      if [ "$stamp" = "$now_fp" ]; then stale=false; else stale=true; fi
    fi
  fi
fi

emit "$review_location" "$review_result" "$review_date" "$amendment_date" "$stale" "$stamped"
