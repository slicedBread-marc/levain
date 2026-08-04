#!/usr/bin/env bash
# wf-manual-gate.sh <plan-id-or-name> [--explain]
#
# Decides whether an unattended /wf-test run should stop for a human.
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
# Gate only when ALL configured conditions hold (claude-workflow.yml):
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
# Output (eval-safe), always exit 0 unless the plan cannot be resolved:
#   GATE='true|false'
#   GATE_REASON='<one line, why>'
#   SURFACE_HIT='<matching path or empty>'
#   plus every MANUAL_* count from wf-manual-lint.sh --counts
#
# --explain adds a human-readable summary on stderr.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

raw_id=""
explain=false
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) explain=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) raw_id="$1"; shift ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE 'PLN-[0-9]+' || true)
[ -n "$plan_id" ] || { echo "Usage: $0 <plan-id-or-name> [--explain]" >&2; exit 2; }

ROOT="$(wf_develop_root)"
REGISTRY="$ROOT/plans/REGISTRY.md"
[ -f "$REGISTRY" ] || { echo "Error: $REGISTRY not found" >&2; exit 2; }
row=$(grep "^| $plan_id |" "$REGISTRY" | head -1 || true)
[ -n "$row" ] || { echo "Error: $plan_id not found in registry" >&2; exit 2; }
slug=$(printf '%s' "$row" | awk -F'|' '{print $3}' | xargs)
plan_name="${plan_id}-${slug}"

# ── Criterion counts (single parser, shared with the lint) ────────────────
eval "$("$(dirname "$0")/wf-manual-lint.sh" "$plan_id" --counts)"

# ── Config ────────────────────────────────────────────────────────────────
# Defaults are pre-P-003 behavior on purpose: a client whose config predates
# this block keeps gating exactly as it did, and only starts surface-gating
# once install.sh backfills the block (or they write it themselves).
cfg_require_surface=$(wf_cfg manualTestGate.requireRenderingSurface false)
cfg_min_eyes=$(wf_cfg manualTestGate.minEyesCriteria 1)
cfg_block_cosmetic=$(wf_cfg manualTestGate.blockOnCosmetic true)

# ── How many open criteria actually count toward gating ───────────────────
open_count="$MANUAL_OPEN_BLOCKING"
if [ "$cfg_block_cosmetic" = "true" ]; then
  open_count=$(( MANUAL_OPEN_BLOCKING + MANUAL_OPEN_COSMETIC ))
fi

# ── Does the diff touch a rendering surface? ──────────────────────────────
# Translate globs to anchored regexes: `/**/` spans zero or more directories,
# a bare `*` stops at a separator.
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
  worktree="$ROOT/feature-branches/$plan_name"
  [ -d "$worktree" ] || worktree="$PWD"
  changed=$(git -C "$worktree" diff --name-only develop...HEAD 2>/dev/null || true)
  if [ -z "$changed" ]; then
    changed=$(git -C "$worktree" diff --name-only HEAD~1 2>/dev/null || true)
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

# ── Decide ────────────────────────────────────────────────────────────────
gate=true
reason=""

if [ "$open_count" -lt "$cfg_min_eyes" ]; then
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
  # wf-manual-lint.sh reads an untagged criterion the v5 way and promotes it to
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
elif [ "$cfg_require_surface" = "true" ] && [ -n "$surfaces" ] && [ -z "$surface_hit" ]; then
  gate=false
  reason="the diff renders nothing to a human — no file matches manualTestGate.renderingSurfaces"
else
  reason="$open_count unresolved eyes criteria"
  [ -n "$surface_hit" ] && reason="$reason; diff touches a rendering surface ($surface_hit)"
  [ -z "$surfaces" ] && reason="$reason; no renderingSurfaces configured, so every plan can gate"
fi

wf_emit GATE         "$gate"
wf_emit GATE_REASON  "$reason"
wf_emit SURFACE_HIT  "$surface_hit"
wf_emit MANUAL_TOTAL         "$MANUAL_TOTAL"
wf_emit MANUAL_OPEN_BLOCKING "$MANUAL_OPEN_BLOCKING"
wf_emit MANUAL_OPEN_COSMETIC "$MANUAL_OPEN_COSMETIC"
wf_emit MANUAL_OPEN_UNTAGGED "${MANUAL_OPEN_UNTAGGED:-0}"
wf_emit MANUAL_EXTERNAL      "$MANUAL_EXTERNAL"
wf_emit MANUAL_SOAK          "$MANUAL_SOAK"
wf_emit MANUAL_SCHEMA        "$MANUAL_SCHEMA"

if $explain; then
  {
    echo "wf-manual-gate: $plan_name → GATE=$gate"
    echo "  reason: $reason"
    echo "  open eyes: blocking=$MANUAL_OPEN_BLOCKING cosmetic=$MANUAL_OPEN_COSMETIC (counted: $open_count, min: $cfg_min_eyes)"
    echo "  never gate: external=$MANUAL_EXTERNAL soak=$MANUAL_SOAK"
    echo "  untagged open: ${MANUAL_OPEN_UNTAGGED:-0} (if >0 the surface rule does not apply)"
    echo "  surface: requireRenderingSurface=$cfg_require_surface hit=${surface_hit:-none}"
  } >&2
fi
