#!/usr/bin/env bash
# lv-plan-context.sh <PLN-ID>
#
# What a plan was decided against, in one read: its own live directives, and
# for every plan in its dependency closure — state, live directives, and the
# answers a human gave on its design gates. Then, when this plan's spec-approval
# was asked or withdrawn, what has moved since (LVI-033).
#
# WHY THIS EXISTS
#
# A decision made on one plan has to reach the plans that depend on it. Before
# this, an answer given at /lv-attend lived in the gate ledger under
# .claude/orchestrator/ — untracked, keyed to the plan it was asked about — and
# a /lv-spec worker on a DEPENDENT plan had no instruction to look there, and
# no way to find it if it did. A client's PLN-028 was respecced against
# PLN-026's draft text after the operator had resolved PLN-026 by removing the
# very allow-list PLN-028 relied on.
#
# lv-spec, its reviewer and lv-consistency read this before they read the
# plans. Directives and answers printed here are input of record: they outrank
# the worker's own reading, exactly as a gate resolution on the plan itself
# does (WFI-181, LVI-032).
#
# Read-only. Exit 0, or 1 when the id names no plan.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

case "${1:-}" in -h|--help|"") wf_usage "$0"; [ -n "${1:-}" ]; exit $? ;; esac
id=$(printf '%s' "$1" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
[ -n "$id" ] && wf_plan_dir "$id" >/dev/null || { echo "lv-plan-context: '$1' names no plan" >&2; exit 1; }

directives() {
  local rows d k st au dt sp tx
  rows=$(wf_directives_live "$1")
  [ -n "$rows" ] || return 0
  while IFS=$'\037' read -r d k st au dt sp tx; do
    printf '  %s %s [%s] — %s, %s\n      %s\n' "$d" "$k" "$st" "$au" "${dt%%T*}" "$tx"
  done <<< "$rows"
}

# answers <id> — the revision-scoped gates answered (or withdrawn) on it.
answers() {
  local id="$1" dir num f base gate q r at w
  dir="$(wf_orch_dir)/gates/resolved"
  [ -d "$dir" ] || return 0
  num=$((10#${id##*-}))
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.log) continue ;; esac
    base=$(basename "$f")
    [[ "$base" =~ ^($LV_WORK_RE)-([0-9]+)\.(.+)$ ]] || continue
    [ "$((10#${BASH_REMATCH[2]}))" = "$num" ] || continue
    gate="${base#*.}"
    wf_gate_revision_scoped "$gate" || continue
    q=$(wf_gate_field "$f" GATE_QUESTION --unescape | tr '\n' ' ')
    r=$(wf_gate_field "$f" GATE_RESOLUTION --unescape | tr '\n' ' ')
    at=$(wf_gate_field "$f" GATE_RESOLVED)
    w=""; [ "$(wf_gate_field "$f" GATE_WITHDRAWN)" = "true" ] && w=" (WITHDRAWN — not an answer)"
    printf '  %s, %s%s\n      asked:  %s\n      answer: %s\n' "$gate" "$at" "$w" "$q" "$r"
  done
}

echo "== $id ($(wf_state_of "$id"))"
d=$(directives "$id")
if [ -n "$d" ]; then echo "Directives on this plan — binding; they outrank your own reading:"; echo "$d"; fi

closure=$("$SELF_DIR/lv-list-closure.sh" "$id" 2>/dev/null || true)
if [ -z "$closure" ]; then
  echo "No dependencies."
else
  while IFS=$'\t' read -r cid _slug cstate; do
    [ -n "$cid" ] || continue
    echo
    echo "== $cid ($cstate) — upstream"
    d=$(directives "$cid"); [ -n "$d" ] && { echo "Directives:"; echo "$d"; }
    a=$(answers "$cid"); [ -n "$a" ] && { echo "Decisions of record:"; echo "$a"; }
  done <<< "$closure"
fi

# What moved since this plan's approval was asked — open, answered or
# withdrawn, whichever is latest.
ctx=""
gf=$(wf_gate_file "$id" || true)
if [ -f "$gf" ] && [ "$(wf_gate_field "$gf" GATE_NAME)" = "spec-approval" ]; then
  ctx=$(wf_gate_field "$gf" GATE_PLAN_CONTEXT_AT_OPEN)
else
  rf=$(wf_gate_resolved_file "$id" spec-approval || true)
  [ -f "$rf" ] && ctx=$(wf_gate_field "$rf" GATE_PLAN_CONTEXT_AT_OPEN)
fi
if [ -n "$ctx" ]; then
  moved=$(wf_context_changed "$ctx" "$(wf_plan_context "$id")")
  echo
  if [ -n "$moved" ]; then
    echo "MOVED since this plan's spec-approval was asked: $moved"
  else
    echo "Nothing above has moved since this plan's spec-approval was asked."
  fi
fi
exit 0
