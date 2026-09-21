#!/usr/bin/env bash
# wf-test-id-next.sh [--count N] [--prefix T] [--dir tests]
#
# What is the next free test id, and what range does this plan get?
#
# A project that numbers its tests in one flat sequence — `T70`, `T71`, … ,
# matched by `--test-name-pattern '^T70:'` and listed in each plan's `## Tests`
# table — needs every planner to agree on where that sequence has got to.
# wf-spec's instruction was "continue from the highest existing id", and the
# planner read that off `tests/`. That is the whole bug: `tests/` holds the ids
# that have LANDED. An id reserved by a plan still in draft is in the plan's
# own Tests table and nowhere else, so it is invisible to exactly the question
# that must not miss it.
#
# client-d WFI-010, three plans on one range. PLN-011 took T70-T74 and merged
# them. PLN-010 drafted T70-T77 and was renumbered by hand at its gate to
# T75-T82. Then PLN-009, drafted the same day, stated "highest existing is T69"
# — true of `tests/` at that moment, and wrong by thirteen — and claimed
# T70-T77: five ids already on develop and three held by a live draft. 19
# references in the plan body needed renumbering. It was the second collision
# of the class in one day; the first had also been fixed by hand.
#
# So the highest id is read from BOTH places: the test files, and every
# `## Tests` table under `plans/`. Plans live on develop and are committed by
# the planner before the gate, so a draft's reservation is visible here the
# moment it exists — which is the property `tests/` alone can never have.
#
# NOT A COUNTER, DELIBERATELY. wf-counter-next.sh keeps artifact numbers in
# REGISTRY.md because an artifact is created once and the number must survive
# the artifact being renamed, moved, or converted. A test id is different: the
# plan.md that reserves it IS the record, it is written by the same commit, and
# a plan that is abandoned takes its ids out of circulation with it. A separate
# counter would need its own reconciliation with the two places the ids already
# are, and WFI-011's lesson about `wf-plan-id.sh` applies — a counter that can
# drift from the artifacts hands out a number that is already in use.
#
# A max is not a reservation, and this does not pretend otherwise: two planners
# asking in the same second get the same answer. The window is the gap between
# asking and committing plan.md, seconds rather than the days WFI-010 reports,
# and wf-spec's review gate reads the range back. `--verify` is how it checks.
#
#   --count N     also print a contiguous range of N ids starting at the next
#   --prefix T    the letter the ids carry (default: `testIds.prefix`, then `T`)
#   --dir tests   where landed tests live (default: `testIds.dir`, then `tests`)
#   --verify A-B  is the range A..B (e.g. `T75-T82`) still free? Exit 0 if so,
#                 exit 3 and name every collision if not. For a review gate.
#
# Output (eval-friendly):
#   TEST_ID_PREFIX='T'
#   TEST_ID_HIGHEST='82'          0 when the project has no test ids yet
#   TEST_ID_HIGHEST_FROM='plans/PLN-010-idea-threads/plan.md'
#   TEST_ID_NEXT='T83'
#   TEST_ID_RANGE='T83-T90'       only with --count
#
# Exit 0 on success, 1 on usage error, 3 on a --verify collision.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see wf-orch-lib.sh

count=0
prefix=""
test_dir=""
verify=""

while [ $# -gt 0 ]; do
  case "$1" in
    --count)  count="${2:?--count requires a number}"; shift 2 ;;
    --prefix) prefix="${2:?--prefix requires a letter}"; shift 2 ;;
    --dir)    test_dir="${2:?--dir requires a path}"; shift 2 ;;
    --verify) verify="${2:?--verify requires a range like T75-T82}"; shift 2 ;;
    *) echo "Usage: $0 [--count N] [--prefix T] [--dir tests] [--verify T75-T82]" >&2; exit 1 ;;
  esac
done

case "$count" in
  ''|*[!0-9]*) echo "Error: --count takes a number, got '$count'" >&2; exit 1 ;;
esac

[ -n "$prefix" ]   || prefix=$("$SELF_DIR/wf-config-get.sh" testIds.prefix T 2>/dev/null || echo T)
[ -n "$test_dir" ] || test_dir=$("$SELF_DIR/wf-config-get.sh" testIds.dir tests 2>/dev/null || echo tests)
[ -n "$prefix" ]   || prefix=T
[ -n "$test_dir" ] || test_dir=tests

# One id per line, prefixed by where it was found, so the answer can say which
# file is holding the ceiling — the planner's next question every time.
ids_found() {
  # Landed tests. Any occurrence of the id as a whole word: a
  # `--test-name-pattern '^T75:'`, a `describe('T75: …')`, a filename.
  if [ -d "$test_dir" ]; then
    grep -rIoHE "\\b${prefix}[0-9]+\\b" "$test_dir" 2>/dev/null || true
    # A file named for its id carries it whether or not the text repeats it.
    find "$test_dir" -type f 2>/dev/null \
      | grep -E "/${prefix}[0-9]+[^/]*$" \
      | sed -E "s#^(.*/)(${prefix}[0-9]+).*#\\1\\2:\\2#" || true
  fi
  # Reserved ids: the `## Tests` table of every plan, in any state. A row
  # whose FIRST cell is the id — prose mentioning T75 elsewhere in a plan is a
  # reference, not a reservation, and counting it would let a plan raise the
  # ceiling by discussing its neighbours.
  for plan_md in plans/*/plan.md; do
    [ -f "$plan_md" ] || continue
    awk -F'|' -v f="$plan_md" -v px="$prefix" '
      function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
      NF >= 3 {
        cell = trim($2)
        if (cell ~ "^" px "[0-9]+$") print f ":" cell
      }
    ' "$plan_md"
  done
}

found=$(ids_found)

highest=0
highest_from=""
if [ -n "$found" ]; then
  read -r highest highest_from <<<"$(printf '%s\n' "$found" | awk -F: -v px="$prefix" '
    {
      id = $NF
      sub("^" px, "", id)
      n = id + 0
      if (n > best) { best = n; from = $1 }
    }
    END { print best + 0, from }
  ')"
fi

if [ -n "$verify" ]; then
  lo=$(printf '%s' "$verify" | sed -E "s/^${prefix}?([0-9]+).*/\\1/")
  hi=$(printf '%s' "$verify" | sed -E "s/.*[^0-9]([0-9]+)$/\\1/")
  case "$lo$hi" in
    ''|*[!0-9]*) echo "Error: --verify takes a range like ${prefix}75-${prefix}82" >&2; exit 1 ;;
  esac
  [ "$hi" -ge "$lo" ] || { echo "Error: --verify range runs backwards: $verify" >&2; exit 1; }
  # The plan being verified holds its own ids — a range is free if nothing
  # OUTSIDE the asking plan claims it. The caller is a review gate reading a
  # plan that has already written its table, so its own rows must not count as
  # collisions with itself; WF_VERIFY_SELF names the plan to discount.
  self="${WF_VERIFY_SELF:-}"
  clashes=$(printf '%s\n' "$found" | awk -F: -v px="$prefix" -v lo="$lo" -v hi="$hi" -v self="$self" '
    {
      id = $NF; sub("^" px, "", id); n = id + 0
      if (n < lo || n > hi) next
      if (self != "" && index($1, self) > 0) next
      print px n "\t" $1
    }
  ' | sort -u)
  if [ -n "$clashes" ]; then
    echo "Error: ${prefix}${lo}-${prefix}${hi} is not free — these ids are already claimed:" >&2
    printf '%s\n' "$clashes" | sed 's/^/  /' >&2
    echo "  Renumber from ${prefix}$((highest + 1)) (client-d WFI-010)." >&2
    exit 3
  fi
  exit 0
fi

wf_emit TEST_ID_PREFIX      "$prefix"
wf_emit TEST_ID_HIGHEST     "$highest"
wf_emit TEST_ID_HIGHEST_FROM "$highest_from"
wf_emit TEST_ID_NEXT        "${prefix}$((highest + 1))"
if [ "$count" -gt 0 ]; then
  wf_emit TEST_ID_RANGE "${prefix}$((highest + 1))-${prefix}$((highest + count))"
fi
