#!/usr/bin/env bash
# wf-list-specable.sh
# Outputs work available for /wf-spec, in priority order.
# Reads REGISTRY.md for plans in draft state, plus bugs/open and briefs.
# Exit 0 if any work found, exit 1 if nothing.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

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
#   2. NEVER REVIEWED — a plan whose plan.md exists but whose review gate has
#      never run. Its findings.md is empty, because nothing has yet had an
#      opinion about it.
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
  unreviewed+=("${id}-${slug}	never reviewed	$priority")
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
  bug_id=$(grep -oE 'BUG-[0-9]+' "$bug_md" 2>/dev/null | head -1)
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
