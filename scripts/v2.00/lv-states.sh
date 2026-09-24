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
LV_STATES="draft ready active verify testing complete rolled-back abandoned"

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
