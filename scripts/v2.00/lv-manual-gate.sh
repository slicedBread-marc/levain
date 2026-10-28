#!/usr/bin/env bash
# lv-manual-gate.sh <plan-id-or-name> [--explain]
#
# Decides whether an unattended /lv-test run should stop for a human.
#
# The old rule was "gate if any `#### Manual` criterion remains". Every plan has
# some, so every plan gated — and the criteria are not evenly distributed. In a
# 16-plan program, the plans that render nothing to a human (CLI-only) had 14 of
# 15 "manual" criteria that were plain shell assertions; the browser-UI plans had
# 12 of 14 that genuinely needed eyes. The correlation is with the SURFACE the
# diff touches, not with how many criteria the planner happened to write.
#
# So: a plan whose diff renders nothing to a human, AND whose open criteria were
# each tagged eyes:* by someone, never stops for a human. Both halves are load-
# bearing — see the untagged branch under "Decide" for what the first half alone
# did to a CLI project.
#
# Gate only when ALL configured conditions hold (levain.yml):
#
#   manualTestGate:
#     requireRenderingSurface: true    # 1. diff touches a rendering surface
#     minEyesCriteria: 1               # 2. >= N unresolved (eyes) criteria
#     blockOnCosmetic: false           # 3. cosmetic alone never gates
#     renderingSurfaces:               # empty => every plan can gate
#       - "src/**/wwwroot/**"
#
# `external` and `soak` criteria never gate under any condition — they cannot be
# satisfied at gate time either, so gating on them buys a stop and nothing else.
#
# Conversely, an unresolved `eyes:blocking` criterion ALWAYS gates: condition 1
# is a claim about what renders, and dismissing a blocking criterion on it leaves
# the plan unable to ship and unable to ask (WFI-129). The surface rule dismisses
# cosmetic criteria only.
#
# Output (eval-safe), always exit 0 unless the plan cannot be resolved:
#   GATE='true|false'
#   GATE_REASON='<one line, why>'
#   SURFACE_HIT='<matching path or empty>'
#   plus every MANUAL_* count from lv-manual-lint.sh --counts, including
#   MANUAL_RESOLVED_RECORD — criteria left unchecked in plan.md that
#   test-progress.md already recorded PASS against this very build, or against
#   an earlier one when no renderingSurfaces path changed in between
#   MANUAL_CARRIED — how many of those came from an earlier build
#   SURFACE_MOVED / SURFACE_MOVED_FROM — when an earlier PASS did NOT carry,
#     the renderingSurfaces path that changed since and the build it passed
#     on. This, not SURFACE_HIT, is what a re-ask names (LVI-021)
#   CHROME_OPEN — unchecked `#### Chrome-Assisted` criteria
#   CHROME_UNRECORDED — how many of those test-progress.md holds no result
#     or reason for (never run, or the record was never written)
#   CHROME_UNTESTED — how many it records as not run, with a reason: a
#     headless ERROR, a disagreement with a prior reading, or
#     `needs: oauth|device|extension|profile`
#   CHROME_EXCUSED — how many carry some other note instead of a run. They
#     count in CHROME_UNRECORDED too: a note is not a result (LVI-030)
#   PROGRESS_INCOMPLETE='true|false' — CHROME_UNRECORDED > 0
#   PROGRESS_MISSING='<criteria, "; "-joined>' — the unrecorded ones
#   PROGRESS_TREE — the build test-progress.md's `TREE` stamp names
#   PROGRESS_TREE_STALE='true|false' — that stamp is not the build here now, so
#     the suite result recorded under it is another build's (LVI-029)
#   PRELAUNCH='true|false' — GATE is false because the project is pre-launch
#     (wf_prelaunch): open eyes criteria go to the post-ship checklist with
#     `lv-lane.sh answer <PLN> manual-test`, for the end-state review
#     (a client's LVI-034). Takes precedence over every rule below the lane.
#   LANE='express|normal|none' — lv-lane.sh's verdict. Under `express`, open
#     `#### Manual` eyes criteria do not gate: /lv-test moves them to the plan's
#     post-ship checklist with `lv-lane.sh answer <PLN> manual-test` (LVI-025).
#     Chrome-Assisted work left unrun or unrecorded still gates — the lane
#     answers the human's question, never the tester's unfinished work.
#
# --explain adds a human-readable summary on stderr.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

raw_id=""
explain=false
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) raw_id="$1"; shift ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE "($LV_PLN_RE)-[0-9]+" || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <plan-id-or-name> [--explain]" >&2; exit 2; }

ROOT="$(wf_develop_root)"
REGISTRY="$ROOT/plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 2; }
slug=$(wf_registry_field "$plan_id" slug "$REGISTRY")
[ -n "$slug" ] || { echo "Error: $plan_id not found in registry" >&2; exit 2; }
plan_name="${plan_id}-${slug}"

# ── Where this plan's work lives ──────────────────────────────────────────
# Resolved once: both the diff below and the test record above it need the
# plan's own worktree, and they must never disagree about which one that is.
worktree=""
if [ -d "$ROOT/feature-branches/$plan_name" ]; then
  worktree="$ROOT/feature-branches/$plan_name"
elif [ "$(git branch --show-current 2>/dev/null || true)" = "feature/$plan_name" ]; then
  worktree="$PWD"
fi

# ── Criteria this build already settled ───────────────────────────────────
#
# lv-test records a PASS in test-progress.md and leaves plan.md's checkbox
# alone; it ticks a box only on a deferral or a cosmetic failure. The counts
# below are parsed out of plan.md. So the two surfaces disagree by construction
# for every criterion that simply PASSED, and a plan whose every criterion had
# been judged and passed gated anyway — client-b' PLN-011 recorded 8 of 8 PASS
# on build e2a923a at 15:32Z and was parked for a human at 15:33Z, with
# GATE_REASON naming an eyes:blocking criterion that was already green (WFI-013).
#
# A row counts only when BOTH hold: the result is PASS, and the build it was
# recorded against is the build standing here now. A PASS on an older build is
# a measurement of a tree that no longer exists, which is the whole reason the
# Build column is in that file.
#
# No worktree means no build to compare against — every row is then unverifiable
# rather than fresh, so nothing is subtracted and the gate behaves as it always
# did. Same reasoning as `diff_known` below: not knowing is not evidence.
resolved_file=""
resolved_args=()
progress_md="$ROOT/plans/$plan_name/test-progress.md"
build_sha=""
[ -n "$worktree" ] && build_sha=$(git -C "$worktree" rev-parse HEAD 2>/dev/null || true)

if [ -f "$progress_md" ] && [ -n "$build_sha" ]; then
  resolved_file=$(mktemp "${TMPDIR:-/tmp}/lv-manual-gate.XXXXXX")
  trap 'rm -f "$resolved_file"' EXIT
  wf_test_progress_passes "$progress_md" "$build_sha" > "$resolved_file"
  if [ -s "$resolved_file" ]; then
    resolved_args=(--resolved "$resolved_file")
  else
    rm -f "$resolved_file"
    resolved_file=""
  fi
fi

# ── Config ────────────────────────────────────────────────────────────────
# Defaults are pre-P-003 behavior on purpose: a client whose config predates
# this block keeps gating exactly as it did, and only starts surface-gating
# once install.sh backfills the block (or they write it themselves).
cfg_require_surface=$(wf_cfg manualTestGate.requireRenderingSurface false)
cfg_min_eyes=$(wf_cfg manualTestGate.minEyesCriteria 1)
cfg_block_cosmetic=$(wf_cfg manualTestGate.blockOnCosmetic true)

# ── Does the diff touch a rendering surface? ──────────────────────────────
# Translate globs to anchored regexes: `/**/` (or a leading `**/`) spans zero
# or more directories, a bare `*` stops at a separator.
#
# The two `**` rules emit PLACEHOLDER bytes, and only the final pair turns
# those into regex. That indirection is the whole point. Substituting the real
# regex up front looks equivalent and is not: `/**/` became `/(.*/)?`, and then
# the very next rule — the one that narrows a lone `*` to `[^/]*` — rewrote the
# `*` inside that freshly-emitted `.*`, yielding `(.[^/]*/)?`. So `src/**/*.razor`
# compiled to `^src/(.[^/]*/)?[^/]*\.razor$`: one optional directory level, and
# that level had to be at least two characters. No wildcard could span
# directories at all, which made `renderingSurfaces` non-functional for every
# real source tree — client-a shipped a plan touching three `.razor` pages
# with the manual gate closed as "the diff renders nothing to a human"
# (WFI-044). A placeholder the `*` rule cannot see is what keeps the passes
# from eating each other.
#
# The escape rule below is split in two for the same class of reason. It was
# written as `[.[\]()+^$]`, which reads as "escape these metacharacters" but is
# not that set: inside a bracket expression a backslash is literal, so the `\]`
# closed the bracket early and the rule matched one of `.[\` followed by the
# literal text `()+^$]`. It therefore never fired on any real input — a silent
# no-op that left every `.` in a glob meaning "any character". Putting `[` last
# and giving `]` its own rule is the portable spelling that actually works.
glob_to_regex() {
  local star_dir star_any
  star_dir=$(printf '\001')   # stands in for `/**/`
  star_any=$(printf '\002')   # stands in for a bare `**`
  printf '%s' "$1" \
    | sed -e 's/[.()+^$[]/\\&/g' -e 's/\]/\\]/g' \
          -e "s#^\*\*/#${star_dir}#" \
          -e "s#/\*\*/#/${star_dir}#g" \
          -e "s/\*\*/${star_any}/g" \
          -e 's/\*/[^\/]*/g' \
          -e "s#${star_dir}#(.*/)?#g" \
          -e "s#${star_any}#.*#g" \
    | sed -e 's/^/^/' -e 's/$/$/'
}

surface_hit=""
diff_known=true
surfaces=$(wf_cfg_list manualTestGate.renderingSurfaces || true)

if [ -n "$surfaces" ]; then
  # Only ever diff THIS plan's branch (`$worktree`, resolved once above). The
  # fallback used to be a bare `$PWD`, which is right when lv-test calls this
  # from inside the worktree and wrong everywhere else: from the develop root
  # it diffs develop's own last commit and reads whatever that touched as
  # "what the plan changed". A registry commit is enough to make an unreadable
  # diff look readable, and the answer this script gives decides whether a
  # human ever looks at the feature.
  changed=""
  if [ -n "$worktree" ]; then
    changed=$(git -C "$worktree" diff --name-only develop...HEAD 2>/dev/null || true)
    if [ -z "$changed" ]; then
      changed=$(git -C "$worktree" diff --name-only HEAD~1 2>/dev/null || true)
    fi
  fi

  # An empty diff here means we could not read one — the plan's worktree is
  # gone, or we are standing on develop. Not knowing what changed is not
  # evidence that nothing renders, so it must not silently skip the gate.
  [ -n "$changed" ] || diff_known=false

  if [ -n "$changed" ]; then
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      re=$(glob_to_regex "$pattern")
      hit=$(printf '%s\n' "$changed" | grep -E "$re" | head -1 || true)
      if [ -n "$hit" ]; then surface_hit="$hit"; break; fi
    done <<< "$surfaces"
  fi
fi

# ── A PASS on an earlier build, when nothing it could see has changed ──────
#
# A PASS counts above only against the build standing here now, so any new
# commit — a release merge touching nothing visual included — re-asks every
# eyes criterion. A client's LVI-006: a release merge brought in storage code
# only, the B&W print criterion lost its PASS, and the gate question the
# worker wrote claimed the build "changed rendering surfaces (preppy-print.css)"
# when git diff touched no CSS at all. The human was re-asked on a false premise.
#
# So an older PASS carries when the diff from its build to this one touches no
# renderingSurfaces path. Only with surfaces configured (none = unknowable) and
# only for a build git can still resolve here; everything else stays unsettled.
carried=0
carried_from=""
# The first earlier PASS that did NOT carry, and the surface path that stopped
# it. SURFACE_HIT is the plan's whole diff against develop — a fine answer to
# "does this plan render anything", and the wrong one to "why is a criterion
# that already passed being asked again". A client's LVI-021 re-gate quoted
# SURFACE_HIT=client/src/index.css, which the plan itself changed and which was
# identical on both builds; the path that actually moved was a .tsx brought in
# by a develop merge.
moved_path=""
moved_from=""
# Unattended, only the committed record carries — the same rule, and the same
# reason, as wf_test_progress_passes (LVI-033).
carry_source() {
  if [ "${LV_UNATTENDED:-0}" = "1" ]; then
    git -C "$(dirname "$progress_md")" show "HEAD:./$(basename "$progress_md")" 2>/dev/null || true
  else
    cat "$progress_md"
  fi
}
if [ -n "$surfaces" ] && [ -n "$build_sha" ] && [ -f "$progress_md" ]; then
  while IFS=$'\t' read -r crit cell; do
    [ -n "$crit" ] || continue
    old=""
    for cand in $(printf '%s' "$cell" | grep -oE '[0-9a-fA-F]{7,40}' || true); do
      full=$(git -C "$worktree" rev-parse --verify --quiet "$cand^{commit}" 2>/dev/null || true)
      [ -n "$full" ] && { old="$full"; break; }
    done
    [ -n "$old" ] && [ "$old" != "$build_sha" ] || continue
    between=$(git -C "$worktree" diff --name-only "$old" "$build_sha" 2>/dev/null) || continue
    moved=""
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      moved=$(printf '%s\n' "$between" | grep -E "$(glob_to_regex "$pattern")" | head -1 || true)
      [ -n "$moved" ] && break
    done <<< "$surfaces"
    if [ -n "$moved" ]; then
      [ -n "$moved_path" ] || { moved_path="$moved"; moved_from="${old:0:7}"; }
      continue
    fi
    if [ -z "$resolved_file" ]; then
      resolved_file=$(mktemp "${TMPDIR:-/tmp}/lv-manual-gate.XXXXXX")
      trap 'rm -f "$resolved_file"' EXIT
      resolved_args=(--resolved "$resolved_file")
    fi
    grep -qxF -- "$crit" "$resolved_file" 2>/dev/null && continue
    printf '%s\n' "$crit" >> "$resolved_file"
    carried=$((carried + 1))
    carried_from="${old:0:7}"
  done < <(awk -F'|' '
    function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
    NF < 6 { next }
    { c = trim($3); b = trim($4); r = toupper(trim($5))
      if (r == "PASS" && c != "" && tolower(c) != "criterion") print c "\t" b }
  ' < <(carry_source))
fi

# ── Criterion counts (single parser, shared with the lint) ────────────────
eval "$("$(dirname "$0")/lv-manual-lint.sh" "$plan_id" --counts ${resolved_args[@]+"${resolved_args[@]}"})"

# ── Chrome-Assisted criteria: were they run at all? ───────────────────────
#
# Everything above counts `#### Manual` criteria, so a gate built only from it
# is silent about Chrome-Assisted work nobody did. A client's LVI-040 (the
# WFI-022 shape again): an unattended tester left all 6 Chrome-Assisted
# criteria of a plan untested, reported writing a test-progress.md that never
# existed, and opened a gate saying "1 eyes:blocking criterion requires human
# verification". The human answering it had no way to know about the other 6.
#
# So account for them here, where the question is decided: an unchecked
# (i.e. not deferred) Chrome-Assisted criterion is settled by a PASS or FAIL
# row in test-progress.md, and is untested-with-a-reason when its row has
# Notes. Anything else — no row, no file, a bare `—` — is unrecorded. Matched
# with the same normalization and 24-character containment rule as the lint.
#
# A PASS or FAIL settles a criterion only for the build it was recorded on: the
# build standing here now, or — for a PASS — an earlier one the Manual rules
# above carried because no rendering surface moved since. A client's PLN-061
# went testing -> accept on 9a0ef6c with every Chrome-Assisted row from
# a98b5d2, a day older and two client-code commits behind; the tester had run
# nothing, and the accept record named a build that was not the one a human
# was about to look at (LVI-029). With no worktree there is no build to compare
# against, and any PASS or FAIL counts, as before.
chrome_out=$(awk -F'|' -v progress="$progress_md" -v sha="$build_sha" -v carried="$resolved_file" '
  function norm(s,   t) {
    t = tolower(s)
    gsub(/[`*_]/, "", t)
    sub(/^[[:space:]]*\([^)]*\)[[:space:]]*/, "", t)
    gsub(/[[:space:]]+/, " ", t)
    sub(/^ /, "", t); sub(/ $/, "", t)
    sub(/[.,;:]+$/, "", t)
    return t
  }
  function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
  # What counts as "a recorded reason it could not run": the ERROR line a
  # headless script printed, a headless reading that disagrees with a prior
  # one, or one of the four things Playwright cannot be (lv-test step 3c).
  # Anything else is the tester explaining why it did not try.
  function reasoned(n,   l) {
    if (n ~ /ERROR/) return 1
    l = tolower(n)
    if (l ~ /headless:? *(pass|fail)/ && l ~ /prior/) return 1
    # A download, an upload or the clipboard is not one of the four, whatever
    # the note calls it: each has a headless verb. LVI-036 from a client wrote
    # "needs: device — file download requires real browser" on all 7 criteria
    # of one plan, and this accepted it; an attended session then ran all 7 to
    # PASS against the same cached browser.
    if (l ~ /needs: *(oauth|device|extension|profile)/) {
      if (l ~ /download|upload|file (input|chooser|picker|dialog)|clipboard|copy|paste/) return 0
      return 1
    }
    return 0
  }
  # The Build cell names the build in hand: any hex run of 7+ characters that
  # is a prefix of it, the same rule as wf_test_progress_passes_of.
  function current(b,   n, i, parts) {
    if (sha == "") return 1
    n = split(b, parts, /[^0-9a-fA-F]+/)
    for (i = 1; i <= n; i++)
      if (length(parts[i]) >= 7 && index(sha, tolower(parts[i])) == 1) return 1
    return 0
  }
  function settled(k) {
    if (RES[k] != "PASS" && RES[k] != "FAIL") return 0
    if (current(BUILD[k])) return 1
    return RES[k] == "PASS" && (k in CARRIED)
  }
  function lookup(nt,   k) {
    if (nt in RES) return nt
    for (k in RES)
      if (length(nt) >= 24 && length(k) >= 24 && (index(k, nt) > 0 || index(nt, k) > 0)) return k
    return ""
  }
  BEGIN {
    while ((getline row < progress) > 0) {
      n = split(row, f, "|")
      if (n < 6) continue
      c = norm(trim(f[3])); if (c == "" || c == "criterion") continue
      RES[c] = toupper(trim(f[5])); NOTE[c] = trim(f[6]); BUILD[c] = trim(f[4])
    }
    if (carried != "")
      while ((getline row < carried) > 0) CARRIED[norm(row)] = 1
  }
  /^####[[:space:]]*Chrome-Assisted/ { in_c = 1; next }
  /^(#|##|###|####)[[:space:]]/ { in_c = 0 }
  !in_c { next }
  /^[[:space:]]*-[[:space:]]*\[ \]/ {
    text = $0; sub(/^[[:space:]]*-[[:space:]]*\[ \][[:space:]]*/, "", text)
    k = lookup(norm(text))
    if (k != "" && settled(k)) print "S\t" text
    else if (k != "" && reasoned(NOTE[k])) print "R\t" text
    else if (k != "" && NOTE[k] != "") print "E\t" text
    else print "U\t" text
  }
' <(wf_live_criteria "$ROOT/plans/$plan_name/plan.md" 2>/dev/null) 2>/dev/null || true)
chrome_open=$(printf '%s\n' "$chrome_out" | grep -c '^[SREU]	' || true)
chrome_untested=$(printf '%s\n' "$chrome_out" | grep -c '^R	' || true)
chrome_excused=$(printf '%s\n' "$chrome_out" | grep -c '^E	' || true)
chrome_unrecorded=$(printf '%s\n' "$chrome_out" | grep -c '^[UE]	' || true)
chrome_missing=$(printf '%s\n' "$chrome_out" | sed -n 's/^[UE]	//p' | cut -c1-80 | paste -sd';' - | sed 's/;/; /g')
chrome_blank=$(printf '%s\n' "$chrome_out" | sed -n 's/^U	//p' | cut -c1-80 | paste -sd';' - | sed 's/;/; /g')
chrome_excuses=$(printf '%s\n' "$chrome_out" | sed -n 's/^E	//p' | cut -c1-80 | paste -sd';' - | sed 's/;/; /g')
chrome_reasoned=$(printf '%s\n' "$chrome_out" | sed -n 's/^R	//p' | cut -c1-80 | paste -sd';' - | sed 's/;/; /g')

# ── How many open criteria actually count toward gating ───────────────────
open_count="$MANUAL_OPEN_BLOCKING"
if [ "$cfg_block_cosmetic" = "true" ]; then
  open_count=$(( MANUAL_OPEN_BLOCKING + MANUAL_OPEN_COSMETIC ))
fi

# ── The express lane ──────────────────────────────────────────────────────
LANE=none; LANE_REASONS=""
eval "$("$(dirname "$0")/lv-lane.sh" status "$plan_id" 2>/dev/null || true)"

# ── Decide ────────────────────────────────────────────────────────────────
gate=true
reason=""
PRELAUNCH=false

if [ "$LANE" = express ] && { [ "$open_count" -gt 0 ] || [ "${MANUAL_OPEN_UNTAGGED:-0}" -gt 0 ]; }; then
  # A human declared this plan safe to ship unseen, and lv-lane.sh has just
  # re-checked the written plan and agrees. Its eyes criteria still matter —
  # they move to a post-ship checklist, they are not dropped.
  gate=false
  reason="express lane: $MANUAL_OPEN_BLOCKING open eyes:blocking criteria go to the post-ship checklist (lv-lane.sh answer $plan_id manual-test); cosmetic ones never block completion"
elif wf_prelaunch && { [ "$open_count" -gt 0 ] || [ "${MANUAL_OPEN_UNTAGGED:-0}" -gt 0 ] || [ "$MANUAL_OPEN_COSMETIC" -gt 0 ]; }; then
  # Pre-launch: human checks run against the end state, not plan by plan
  # (a client's LVI-034). The criteria are not dropped — lv-lane.sh answer moves
  # them to the plan's post-ship checklist, which lv-end-state.sh collects for
  # the review. Cosmetic ones go too, so nothing a person meant to look at is
  # left unchecked and unlisted.
  gate=false
  PRELAUNCH=true
  reason="pre-launch: $MANUAL_OPEN_BLOCKING eyes:blocking, $MANUAL_OPEN_COSMETIC cosmetic and ${MANUAL_OPEN_UNTAGGED:-0} untagged open criteria go to the end-state review (lv-lane.sh answer $plan_id manual-test)"
elif [ "$open_count" -lt "$cfg_min_eyes" ]; then
  gate=false
  reason="$open_count unresolved eyes criteria, below minEyesCriteria=$cfg_min_eyes"
elif [ "$cfg_require_surface" = "true" ] && [ -n "$surfaces" ] && ! $diff_known; then
  reason="could not read the plan's diff (worktree missing?) — gating rather than assuming it renders nothing"
elif [ "$cfg_require_surface" = "true" ] && [ -n "$surfaces" ] && [ "${MANUAL_OPEN_UNTAGGED:-0}" -gt 0 ]; then
  # The surface rule below is an argument about APPEARANCE: if nothing the diff
  # touches can be looked at, a criterion asking someone to look is unsatisfiable
  # and gating buys nothing. That argument holds only for criteria somebody
  # actually tagged eyes:*. It does not hold for a criterion whose tag was
  # ASSUMED — and every pre-v6 plan's criteria are assumed, because
  # lv-manual-lint.sh reads an untagged criterion the v5 way and promotes it to
  # eyes:blocking on its behalf.
  #
  # Combining the two says: this plan renders nothing, and its criteria are all
  # about rendering, therefore none of them matter. For a CLI project the first
  # half is true by construction and the second is never true, so EVERY CLI plan
  # auto-completes EVERY human criterion, permanently and silently. client-a
  # shipped PLN-004 that way in ~40 seconds — five criteria recorded untested,
  # two of them safety assertions ("prints exactly what it will do and stops for
  # confirmation", "leaves <drive>/keys/ empty afterwards" for private key
  # material on a shared drive). Neither has ever executed (WFI-054).
  #
  # An untagged criterion is not evidence of anything visual, so it cannot be
  # dismissed by a fact about visuals. Gate, and say which criteria did it.
  reason="$MANUAL_OPEN_UNTAGGED unresolved criteria carry no reason tag of their own (schema v$MANUAL_SCHEMA) — untagged criteria say nothing about rendering, so a surface miss cannot dismiss them"
elif [ "$cfg_require_surface" = "true" ] && [ -n "$surfaces" ] && [ "$MANUAL_OPEN_BLOCKING" -gt 0 ]; then
  # The surface rule dismisses criteria; a blocking criterion is the one kind it
  # may not dismiss. Where the rule fails open for `eyes:cosmetic` — the plan
  # ships unseen, which is the documented trade — for `eyes:blocking` it fails
  # into a deadlock: an unattended worker cannot judge the criterion, and with no
  # matching surface no gate ever opens, so the plan neither ships nor asks. It
  # just sits in `testing` until the stuck detector notices.
  #
  # client-a's WFI-129: PLN-041's sole criterion was "(eyes:blocking) tool
  # --help — the command list is readable enough", its diff touched src/
  # Tracker.Cli/ only, and renderingSurfaces listed web directories. lv-test ran
  # three times, wrote no test-progress.md, moved neither the registry row nor
  # progress.md, and PLN-041.stuck opened instead.
  #
  # The premise the surface rule rests on — "a human can see this" means a
  # browser — is what breaks. A terminal renders too, and CLI help text is
  # exactly the output only a human can call readable. Rather than ask every
  # client to enumerate its non-web surfaces, blocking criteria gate on their
  # own: somebody tagged this one as needing eyes and blocking release without
  # them, and a fact about file paths does not overrule that.
  reason="$MANUAL_OPEN_BLOCKING unresolved eyes:blocking criteria — a surface miss cannot dismiss a blocking criterion, which would neither ship nor gate"
  [ -n "$surface_hit" ] && reason="$reason; diff touches a rendering surface ($surface_hit)"
elif [ "$cfg_require_surface" = "true" ] && [ -n "$surfaces" ] && [ -z "$surface_hit" ]; then
  gate=false
  reason="the diff renders nothing to a human — no file matches manualTestGate.renderingSurfaces"
else
  reason="$open_count unresolved eyes criteria"
  [ -n "$surface_hit" ] && reason="$reason; diff touches a rendering surface ($surface_hit)"
  [ -z "$surfaces" ] && reason="$reason; no renderingSurfaces configured, so every plan can gate"
fi

# Chrome-Assisted work left undone reaches the human, named — whatever the
# Manual counts decided. An unrecorded one is the tester's own unfinished work
# (lv-test goes back and runs it before asking); one with a recorded reason is
# genuinely the human's. Either way the gate question has to say so (LVI-040).
if [ "$chrome_excused" -gt 0 ]; then
  # LVI-030: an unattended tester wrote "needs browser mode (iframe requires
  # user interaction)" against all 6 criteria of a plan without running one,
  # the gate took the notes as reasons, and an attended re-run passed all 6
  # headlessly in under a minute. A note is not a run.
  gate=true
  reason="$chrome_excused Chrome-Assisted criteria carry a note but no headless result (no ERROR, no disagreement, no needs: oauth|device|extension|profile that a headless verb cannot cover) — run them: $chrome_excuses; $reason"
fi
if [ "$chrome_unrecorded" -gt "$chrome_excused" ]; then
  gate=true
  if [ -f "$progress_md" ]; then
    reason="$((chrome_unrecorded - chrome_excused)) Chrome-Assisted criteria have no result in test-progress.md: $chrome_blank; $reason"
  else
    reason="$chrome_unrecorded Chrome-Assisted criteria have no result — test-progress.md does not exist: $chrome_missing; $reason"
  fi
fi
if [ "$chrome_untested" -gt 0 ] && $PRELAUNCH; then
  # A recorded reason (needs: device, a headless ERROR, a disagreement) is a
  # question for the human — at the end state, while pre-launch.
  reason="$chrome_untested Chrome-Assisted criteria untested go to the end-state review too: $chrome_reasoned; $reason"
elif [ "$chrome_untested" -gt 0 ]; then
  gate=true
  reason="$chrome_untested Chrome-Assisted criteria untested (reason in test-progress.md): $chrome_reasoned; $reason"
fi

# Say it in the reason, not only in the counts. Whoever reads this line is
# deciding whether to believe the verdict, and "3 of them were already passed
# on this build" is the fact that makes a `false` credible and a `true` worth
# a second look.
if [ "${MANUAL_RESOLVED_RECORD:-0}" -gt 0 ]; then
  if [ "$carried" -gt 0 ]; then
    reason="$reason; ${MANUAL_RESOLVED_RECORD} already PASS in test-progress.md ($carried carried from build $carried_from — no renderingSurfaces path changed since)"
  else
    reason="$reason; ${MANUAL_RESOLVED_RECORD} already PASS on this build in test-progress.md"
  fi
fi
if [ -n "$moved_path" ]; then
  reason="$reason; a PASS on build $moved_from did not carry: $moved_path (a renderingSurfaces path) changed between that build and this one"
fi

wf_emit GATE         "$gate"
wf_emit GATE_REASON  "$reason"
wf_emit SURFACE_HIT  "$surface_hit"
wf_emit SURFACE_MOVED      "$moved_path"
wf_emit SURFACE_MOVED_FROM "$moved_from"
wf_emit MANUAL_TOTAL         "$MANUAL_TOTAL"
wf_emit MANUAL_OPEN_BLOCKING "$MANUAL_OPEN_BLOCKING"
wf_emit MANUAL_OPEN_COSMETIC "$MANUAL_OPEN_COSMETIC"
wf_emit MANUAL_OPEN_UNTAGGED "${MANUAL_OPEN_UNTAGGED:-0}"
wf_emit MANUAL_RESOLVED_RECORD "${MANUAL_RESOLVED_RECORD:-0}"
wf_emit MANUAL_CARRIED       "$carried"
wf_emit MANUAL_EXTERNAL      "$MANUAL_EXTERNAL"
wf_emit MANUAL_SOAK          "$MANUAL_SOAK"
wf_emit MANUAL_SCHEMA        "$MANUAL_SCHEMA"
wf_emit CHROME_OPEN          "$chrome_open"
wf_emit CHROME_UNRECORDED    "$chrome_unrecorded"
wf_emit CHROME_UNTESTED      "$chrome_untested"
wf_emit CHROME_EXCUSED       "$chrome_excused"
wf_emit PROGRESS_INCOMPLETE  "$([ "$chrome_unrecorded" -gt 0 ] && echo true || echo false)"
wf_emit PROGRESS_MISSING     "$chrome_missing"

# The build test-progress.md's TREE stamp names, against the build here now.
# /lv-test writes that stamp from lv-test-tree.sh in the same call that starts
# the suite, so a stamp on another build means the suite result under it is
# another build's too (LVI-029). Empty when either side is unknown.
tree_stamp=""
if [ -f "$progress_md" ]; then
  tree_stamp=$(grep -m1 '^TREE ' "$progress_md" 2>/dev/null \
    | grep -oE ' [0-9a-f]{7,40} \(' | tr -d ' (' || true)
fi
tree_stale=false
if [ -n "$tree_stamp" ] && [ -n "$build_sha" ] && [ "${build_sha#"$tree_stamp"}" = "$build_sha" ]; then
  tree_stale=true
fi
wf_emit PROGRESS_TREE        "$tree_stamp"
wf_emit PROGRESS_TREE_STALE  "$tree_stale"
wf_emit LANE                 "$LANE"
wf_emit PRELAUNCH            "$PRELAUNCH"

if $explain; then
  {
    echo "lv-manual-gate: $plan_name → GATE=$gate"
    echo "  reason: $reason"
    echo "  open eyes: blocking=$MANUAL_OPEN_BLOCKING cosmetic=$MANUAL_OPEN_COSMETIC (counted: $open_count, min: $cfg_min_eyes)"
    echo "  never gate: external=$MANUAL_EXTERNAL soak=$MANUAL_SOAK"
    echo "  untagged open: ${MANUAL_OPEN_UNTAGGED:-0} (if >0 the surface rule does not apply)"
    echo "  settled by test-progress.md: ${MANUAL_RESOLVED_RECORD:-0} on build ${build_sha:0:7}${build_sha:+ }${resolved_file:+(record read)}${resolved_file:-(no record read)}"
    echo "  surface: requireRenderingSurface=$cfg_require_surface hit=${surface_hit:-none}"
    echo "  chrome-assisted open: $chrome_open (unrecorded: $chrome_unrecorded, untested with reason: $chrome_untested)"
    echo "  lane: $LANE${LANE_REASONS:+ — $LANE_REASONS}"
  } >&2
fi
