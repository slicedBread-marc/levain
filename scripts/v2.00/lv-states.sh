#!/usr/bin/env bash
# lv-states.sh — the workflow state set. Sourced, never executed.
#
# WHY THIS EXISTS
#
# The set was written out literally in lv-registry-update.sh (which REJECTS
# anything outside it) and again in lv-registry-audit.sh (which REPORTS
# anything outside it). Two independent copies of the same authority is a
# standing invitation to the worst possible failure here: the audit green-
# lighting rows the writer will refuse, or passing rows the writer would.
#
# There is a third, structurally different copy in lv-orchestrate.sh — a
# state → role `case`. That one cannot merge into this list because it maps
# each state to behaviour rather than membership, but it must stay in step:
# a state this file calls valid and the orchestrator does not know is a plan
# that hard-fails the dispatcher with "unknown state". `wf_state_is_terminal`
# exists so the orchestrator can ask rather than re-list.

# Order is the pipeline's order, then the terminals.
#
# `testing` and `accept` are the two halves of one stage, acceptance: the
# automated half (/lv-test, attended or not) and the human half (/lv-accept,
# attended only). `accept` exists only for a plan whose automated half left
# something no machine can settle — lv-registry-update.sh refuses
# `testing -> accept` otherwise. docs/proposals/accept-state.md.
LV_STATES="draft ready active verify testing accept complete rolled-back abandoned"

# Terminal states: no worker acts on them, and no lv-list-* offers them.
# `complete` shipped; `rolled-back` was reverted; `abandoned` was dropped on
# purpose. The distinction matters to dependents — see docs/abandoned-plans.md.
LV_TERMINAL_STATES="complete rolled-back abandoned"

wf_state_is_valid() {
  case " $LV_STATES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

wf_state_is_terminal() {
  case " $LV_TERMINAL_STATES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# wf_state_label <state> — what a person reads for a stored state.
#
# Acceptance is one stage on every surface a person reads, shown as two
# flavours: `testing` reads `accept:auto`, `accept` reads `accept:manual`. The
# stored values stay as they are — renaming `testing` would rewrite every
# client's live registry and history, and a `|` would split REGISTRY.md's
# table row besides.
#
# DISPLAY ONLY. A grep for `accept` finds the manual flavour alone while the
# label `accept` means both, so a script or skill that matched on a label
# would act on the wrong half. Match stored values, exactly; tests/accept-state.sh
# fails on a script in scripts/v2.00 that matches on a label (a case pattern or
# a comparison) outside this function. Prose and section titles may say them.
wf_state_label() {
  case "$1" in
    testing) printf 'accept:auto' ;;
    accept)  printf 'accept:manual' ;;
    *)       printf '%s' "$1" ;;
  esac
}
