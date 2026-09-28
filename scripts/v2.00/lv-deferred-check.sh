#!/usr/bin/env bash
# lv-deferred-check.sh <plan-id> [plan-id...]
# lv-deferred-check.sh --range <git-log revision args...>
#
# --range reads the batch itself: every argument after it goes to
# `git log --format=%s`, and each commit contributes the FIRST plan id in its
# subject — the plan the commit is about. Any later id is a mention, not a
# member: `spec(PLN-041-…): record PLN-032 production policy step applied`
# is a PLN-041 commit. Grepping every id out of the subjects (what both
# skills did before) pulled PLN-032 into a batch it was not in, and an
# unattended /lv-release gated staging on three of PLN-032's production-only
# criteria (a client's LVI-037).
#
# Surfaces open deferred criteria (plans/deferred-criteria.md) that belong to
# plans about to be promoted to production.
#
# WHY THIS EXISTS
#
# A deferred criterion (`external` / `soak` / `unbuilt`) is written when a
# plan completes without it — that is the designed case, and most rows are
# harmless: a soak period, a future integration test. But nothing distinguishes
# those from a criterion whose "external system" is a hard runtime dependency
# that makes the app crash without it. client-c's PLN-004 shipped DC-014
# ("production OIDC certificates required as host secrets") through
# /lv-deploy with nobody having read plans/deferred-criteria.md at all — the
# app crash-looped in production for ~31 minutes until a manual rollback
# (WFI-011).
#
# This does not try to classify which deferred criteria are dangerous — that
# judgment call belongs to whoever is about to push. It only makes sure the
# open ones tied to the plans being promoted are read out loud before that
# happens, the same way step 2/3 of /lv-release and /lv-deploy already show
# the commit list before asking for confirmation.
#
# Exit 0: no plan ids given, or no open rows for any of the given plans
#         (nothing to show), including a --range with no plan commits.
#         Both callers (/lv-release, /lv-deploy) build
#         the plan-id list via `git log ... | grep -oE 'PLN-[0-9]+'` on a
#         commit range that is known non-empty but can still contain zero
#         PLN-tagged commits — a release range whose only commit has no
#         plan id in its subject, say. That is a legitimate "nothing to
#         check" outcome, not a caller error (client-f's WFI-011: the empty
#         command substitution used to hit the usage-error exit 2 below,
#         which neither call site handled).
# Exit 1: at least one open row found — printed to stdout, one per line.
# Exit 2: --range with no revision args, or git log refused them.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

if [ "${1:-}" = "--range" ]; then
  shift
  [ "$#" -ge 1 ] || { echo "lv-deferred-check.sh: --range needs git log revision args" >&2; exit 2; }
  subjects=$(git log --format=%s "$@") || { echo "lv-deferred-check.sh: git log $* failed" >&2; exit 2; }
  ids=()
  while IFS= read -r id; do
    [ -n "$id" ] && ids+=("$id")
  done < <(printf '%s\n' "$subjects" | while IFS= read -r subj; do
             printf '%s\n' "$subj" | grep -oE "($LV_PLN_RE)-[0-9]+" | head -1 || true
           done | sort -u)
  set -- ${ids[@]+"${ids[@]}"}
fi

if [ "$#" -lt 1 ]; then
  exit 0
fi

FILE="$(wf_develop_root)/plans/deferred-criteria.md"
[ -f "$FILE" ] || exit 0

found=0
for raw in "$@"; do
  plan_id=$(printf '%s' "$raw" | grep -oE "($LV_PLN_RE)-[0-9]+" | head -1 || true)
  [ -n "$plan_id" ] || continue
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    found=1
    printf '%s\n' "$line"
  done < <(awk -F'|' -v plan="$plan_id" -v dc_re="^[|] ($LV_DC_RE)-" '
    $0 ~ dc_re {
      id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
      from = $5; gsub(/^[ \t]+|[ \t]+$/, "", from)
      status = $9; gsub(/^[ \t]+|[ \t]+$/, "", status)
      crit = $3; gsub(/^[ \t]+|[ \t]+$/, "", crit)
      if (from == plan && status == "open") print id " (" plan "): " crit
    }' "$FILE")
done

[ "$found" -eq 0 ] && exit 0
exit 1
