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
#   REVIEW_STALE=true|false               (true = amended since the verdict)
#
# REVIEW_STALE is true only when both dates are known and the amendment is
# newer. An undated review with a dated amendment is also stale — a verdict
# nobody dated cannot be shown to postdate anything.
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
# git lists, and plans/ exists only there.
wf_develop_root() {
  local main
  main=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  if [ -n "$main" ] && [ -d "$main/plans" ]; then printf '%s' "$main"; return 0; fi
  printf '%s' "$PWD"
}
ROOT=$(wf_develop_root)

plan_dir=""
for d in "$ROOT"/plans/${plan_id}-*/; do
  [ -d "$d" ] && { plan_dir="${d%/}"; break; }
done

emit() {
  printf "REVIEW_LOCATION=%s\n" "${1:-none}"
  printf "REVIEW_RESULT='%s'\n" "${2:-}"
  printf "REVIEW_DATE=%s\n" "${3:-}"
  printf "AMENDMENT_DATE=%s\n" "${4:-}"
  printf "REVIEW_STALE=%s\n" "${5:-false}"
}

if [ -z "$plan_dir" ]; then
  emit none "" "" "" false
  exit 0
fi

plan_file="$plan_dir/plan.md"
findings_file="$plan_dir/findings.md"

# Body of a `## <name>` section, with the template's blockquote scaffolding
# stripped. Everything the template ships is quoted with `>`; anything a real
# session writes is not. That is what tells a filled section from a placeholder.
# Matched by PREFIX, not equality: findings.md dates its sections in the
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
result_of() {
  printf '%s\n' "$1" \
    | { grep -iE 'result:' || true; } \
    | head -1 \
    | sed -E 's/.*[Rr]esult:\*{0,2}[ \t]*//' \
    | sed -E 's/[ \t]+$//'
}

first_date_of() {
  printf '%s\n' "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | sort -r | head -1 || true
}

review_location=none
review_body=""

# 1. The place the verdict belongs.
body=$(section_body "$plan_file" "Review")
unquoted=$(printf '%s\n' "$body" | { grep -vE '^[ \t]*>' || true; } | { grep -vE '^[ \t]*$' || true; })
if [ -n "$unquoted" ]; then
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
  # findings.md sections are dated in the heading itself ("## Spec Review — 2026-08-03"),
  # so recover the date from the heading when the body carries none.
  if [ "$review_location" = "findings" ] && [ -z "$(first_date_of "$review_body")" ]; then
    heading_line=$({ grep -iE '^## (Spec )?Review' "$findings_file" || true; } | head -1)
    review_body="$review_body
$heading_line"
  fi
fi

review_result=""
review_date=""
if [ "$review_location" != "none" ]; then
  review_result=$(result_of "$review_body")
  review_date=$(first_date_of "$review_body")
fi

amendment_body=$(section_body "$plan_file" "Amendments")
amendment_unquoted=$(printf '%s\n' "$amendment_body" | { grep -vE '^[ \t]*>' || true; })
amendment_date=$(first_date_of "$amendment_unquoted")

stale=false
if [ "$review_location" != "none" ] && [ -n "$amendment_date" ]; then
  if [ -z "$review_date" ]; then
    stale=true
  elif [ "$(printf '%s\n%s\n' "$review_date" "$amendment_date" | sort | tail -1)" = "$amendment_date" ] &&
       [ "$review_date" != "$amendment_date" ]; then
    stale=true
  fi
fi

emit "$review_location" "$review_result" "$review_date" "$amendment_date" "$stale"
