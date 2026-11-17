#!/usr/bin/env bash
# lv-test-id-next.sh [--count N] [--prefix T] [--dir tests]
#
# What is the next free test id, and what range does this plan get?
#
# A project that numbers its tests in one flat sequence — `T70`, `T71`, … ,
# matched by `--test-name-pattern '^T70:'` and listed in each plan's `## Tests`
# table — needs every planner to agree on where that sequence has got to.
# lv-spec's instruction was "continue from the highest existing id", and the
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
# NOT A COUNTER, DELIBERATELY. lv-counter-next.sh keeps artifact numbers in
# REGISTRY.md because an artifact is created once and the number must survive
# the artifact being renamed, moved, or converted. A test id is different: the
# plan.md that reserves it IS the record, it is written by the same commit, and
# a plan that is abandoned takes its ids out of circulation with it. A separate
# counter would need its own reconciliation with the two places the ids already
# are, and WFI-011's lesson about `lv-plan-id.sh` applies — a counter that can
# drift from the artifacts hands out a number that is already in use.
#
# A max is not a reservation, and this does not pretend otherwise: two planners
# asking in the same second get the same answer. The window is the gap between
# asking and committing plan.md, seconds rather than the days WFI-010 reports,
# and lv-spec's review gate reads the range back. `--verify` is how it checks.
#
# NOT EVERY PROJECT NUMBERS FLAT, AND THE ANSWER IS WRONG IF IT DOES NOT.
#
# Everything above assumes ONE sequence shared by the whole project. A project
# can instead number per plan — PLN-001 has T1-T7, PLN-002 has T1-T5, and the
# ids only mean anything next to their plan. That is a legitimate convention
# and this script cannot infer it from a max: to a flat reading, eleven plans
# each holding T1-T7 look like ten collisions on every id.
#
# client-b WFI-024. PLN-001 through PLN-014 number per plan; PLN-015 was the
# first to number flat. `--verify T1-T7` for a PLN-014 replan exited 3 with ~70
# collisions across ten sibling plans and five landed test files, and advised
# "Renumber from T37" — seven ids already written and green on the plan's own
# branch, cited by the test counts in its findings.md, renumbered to fix
# nothing. The advice was loudest exactly where obeying it cost most: a plan
# mid-fix-cycle with its tests already landed.
#
# So the convention is DECLARED, in `testIds.scope`, and defaults to the flat
# reading that was always assumed:
#
#   flat       one sequence for the project. Every plan and every landed test
#              is in scope, and a repeat is a collision. The default.
#   per-plan   each plan numbers from 1. Only the named plan is in scope; a
#              sibling holding the same id is the convention working, not a
#              collision. Needs `--plan` (or LV_VERIFY_SELF) to know which.
#
# An undeclared project that plainly is not flat gets told so rather than
# advised wrongly, at the one moment it matters: a `--verify` about to say
# "renumber". Four or more DIFFERENT plans holding ids in the verified range is
# not what a flat collision looks like — WFI-010, the collision this script
# exists to stop, was two other plans and the test files — it is what per-plan
# numbering looks like. Said alongside the collisions, never instead of them.
#
#   --count N     also print a contiguous range of N ids starting at the next
#   --prefix T    the letter the ids carry (default: `testIds.prefix`, then `T`)
#   --dir tests   where landed tests live (default: `testIds.dir`, then `tests`)
#   --scope S     `flat` or `per-plan` (default: `testIds.scope`, then `flat`)
#   --plan ID     the plan asking, for `per-plan` scope and for the --verify
#                 self-discount (default: `LV_VERIFY_SELF`)
#   --verify A-B  is the range A..B (e.g. `T75-T82`) still free? Exit 0 if so,
#                 exit 3 and name every collision if not. For a review gate.
#                 Under `per-plan` the question is narrower and so is the
#                 answer: does the NAMED PLAN already use an id in that range.
#
# Output (eval-friendly):
#   TEST_ID_PREFIX='T'
#   TEST_ID_SCOPE='flat'
#   TEST_ID_HIGHEST='82'          0 when the project has no test ids yet
#   TEST_ID_HIGHEST_FROM='plans/PLN-010-idea-threads/plan.md'
#   TEST_ID_NEXT='T83'
#   TEST_ID_RANGE='T83-T90'       only with --count
#
# Exit 0 on success, 1 on usage error, 3 on a --verify collision.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$(wf_develop_root)"   # plans/* is develop-root work — see lv-orch-lib.sh

count=0
prefix=""
test_dir=""
verify=""
scope=""
plan_id=""

while [ $# -gt 0 ]; do
  case "$1" in
    --count)  count="${2:?--count requires a number}"; shift 2 ;;
    --prefix) prefix="${2:?--prefix requires a letter}"; shift 2 ;;
    --dir)    test_dir="${2:?--dir requires a path}"; shift 2 ;;
    --scope)  scope="${2:?--scope requires flat or per-plan}"; shift 2 ;;
    --plan)   plan_id="${2:?--plan requires a plan id}"; shift 2 ;;
    --verify) verify="${2:?--verify requires a range like T75-T82}"; shift 2 ;;
    *) echo "Usage: $0 [--count N] [--prefix T] [--dir tests] [--scope flat|per-plan] [--plan $LV_PLN-NNN] [--verify ${LV_T}75-${LV_T}82]" >&2; exit 1 ;;
  esac
done

case "$count" in
  ''|*[!0-9]*) echo "Error: --count takes a number, got '$count'" >&2; exit 1 ;;
esac

# The ID map answers ids.test, then the older testIds.prefix, then T.
[ -n "$prefix" ]   || prefix="$LV_T"   # the ID map (lv-ids.sh, via lv-orch-lib.sh)
[ -n "$test_dir" ] || test_dir=$("$SELF_DIR/lv-config-get.sh" testIds.dir tests 2>/dev/null || echo tests)
[ -n "$scope" ]    || scope=$("$SELF_DIR/lv-config-get.sh" testIds.scope flat 2>/dev/null || echo flat)
[ -n "$prefix" ]   || prefix=T
[ -n "$test_dir" ] || test_dir=tests
[ -n "$scope" ]    || scope=flat

case "$scope" in
  flat|per-plan) ;;
  *) echo "Error: --scope takes 'flat' or 'per-plan', not '$scope'" >&2; exit 1 ;;
esac

# The plan asking. Under `per-plan` it is what defines scope at all, so its
# absence is a usage error rather than a silent project-wide read.
[ -n "$plan_id" ] || plan_id="${LV_VERIFY_SELF:-}"
if [ "$scope" = "per-plan" ] && [ -z "$plan_id" ]; then
  echo "Error: scope is 'per-plan', so the answer depends on WHICH plan is asking." >&2
  echo "       Name it: --plan $LV_PLN-NNN (or set LV_VERIFY_SELF)." >&2
  exit 1
fi

# One id per line, prefixed by where it was found, so the answer can say which
# file is holding the ceiling — the planner's next question every time.
# Reserved ids in one plan.md: a table row whose FIRST cell is the id. Prose
# mentioning T75 elsewhere is a reference, not a reservation, and counting it
# would let a plan raise the ceiling by discussing its neighbours.
#
# The cell is read through its markdown. An amendment that adds a test writes
# the row in bold — `| **T110** | **New.** … |` — which is the same reservation
# as `| T110 | … |` and was read as neither: `**T110**` does not match the id
# pattern, so the ceiling stopped at T109 and the next planner was handed T110,
# already spoken for. client-d WFI-017, on a replan, which is exactly when the
# reservation lives in an amendment and `tests/` cannot answer either — the
# test file defining it exists only on the feature branch. Emphasis and code
# ticks are formatting; strip them before matching.
#
# An amendment can also reserve an id as a list item that OPENS with it —
# `- **T669** (new, Unit/Integration): …` — with no table row at all. That was
# read as prose, so PLN-118 was handed T669-T670 while an active plan's A-1
# held T669 and its branch already defined the test; only the spec review
# caught it (a client's LVI-051). A list item whose first token is the id is a
# reservation; an id later in the item is still a reference. A bullet naming an
# id the same plan's table already holds is not counted again, so per-plan
# scope's duplicate-row check does not fire on an amendment restating a row.
plan_ids() {
  LC_ALL=C awk -F'|' -v f="$1" -v px="$2" '
    function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
    function unmark(x) { gsub(/[*_`]/, "", x); return x }
    NF >= 3 {
      cell = trim(unmark(trim($2)))
      if (cell ~ "^" px "[0-9]+$") { print f ":" cell; row[cell] = 1 }
      next
    }
    /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/ {
      item = $0
      sub(/^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]+/, "", item)
      item = unmark(item)
      if (match(item, "^" px "[0-9]+") && substr(item, RLENGTH + 1, 1) !~ /[[:alnum:]-]/) {
        id = substr(item, 1, RLENGTH)
        if (!(id in bullet)) { bullet[id] = 1; order[++nb] = id }
      }
    }
    END { for (i = 1; i <= nb; i++) if (!(order[i] in row)) print f ":" order[i] }
  ' "$1"
}

# One id per line, prefixed by where it was found, so the answer can say which
# file is holding the ceiling — the planner's next question every time.
ids_found() {
  if [ "$scope" = "per-plan" ]; then
    # Only the asking plan. Its own plan.md is the complete record of the ids
    # it holds — under this convention a landed test file cannot be attributed
    # to a plan by its id, because every plan's ids start at 1.
    for plan_md in plans/${plan_id}-*/plan.md plans/${plan_id}/plan.md; do
      [ -f "$plan_md" ] || continue
      plan_ids "$plan_md" "$prefix"
    done
    return 0
  fi
  # Landed tests. Any occurrence of the id as a whole word: a
  # `--test-name-pattern '^T75:'`, a `describe('T75: …')`, a filename.
  if [ -d "$test_dir" ]; then
    grep -rIoHE "\\b${prefix}[0-9]+\\b" "$test_dir" 2>/dev/null || true
    # A file named for its id carries it whether or not the text repeats it.
    find "$test_dir" -type f 2>/dev/null \
      | grep -E "/${prefix}[0-9]+[^/]*$" \
      | sed -E "s#^(.*/)(${prefix}[0-9]+).*#\\1\\2:\\2#" || true
  fi
  # Reserved ids: the tables of every plan, in any state. Plans live on develop
  # and are committed by the planner before the gate, so a draft's reservation
  # is visible here the moment it exists — the property `tests/` can never have.
  for plan_md in plans/*/plan.md; do
    [ -f "$plan_md" ] || continue
    plan_ids "$plan_md" "$prefix"
  done
}

# Is a flat reading the wrong reading? Answered from the collisions themselves,
# at the only moment it changes what a worker should do — a `--verify` that is
# about to say "renumber".
#
# The shape that means per-plan numbering is MANY sibling plans holding the
# same low ids. A flat-sequence collision is a couple of near-simultaneous
# drafts landing on one range: WFI-010, the collision this script exists to
# stop, was two other plans and the test files. WFI-024 was ten. Four distinct
# sibling plans cannot independently pick the same range by accident; they are
# each numbering from 1.
#
# Deliberately NOT checked on the plain output path. A project that began
# per-plan and converted to flat — client-d did, at T70 — keeps its early
# plans' T1 rows forever, and the flat answer for it is right. Warning there
# would fire on every call, permanently, about a convention the project has
# already left.
flat_reading_suspect() {
  # <clash list on stdin>. Counts distinct plan.md sources among the clashes.
  local n
  n=$(grep -oE 'plans/[^/]+/plan\.md' | sort -u | wc -l | tr -d ' ')
  [ "${n:-0}" -ge 4 ]
}

per_plan_advice() {
  echo "  BUT: $1 different plans hold ids in that range, which is not what a flat-sequence" >&2
  echo "  collision looks like — it is what PER-PLAN numbering looks like. If each plan here" >&2
  echo "  numbers its own tests from ${prefix}1, renumbering is the wrong move and this check is" >&2
  echo "  answering a question the project does not ask (client-b WFI-024). Declare the" >&2
  echo "  convention in levain.yml and re-run:" >&2
  echo "    testIds:" >&2
  echo "      scope: per-plan" >&2
  return 0
}

found=$(ids_found)

highest=0
highest_from=""
if [ -n "$found" ]; then
  read -r highest highest_from <<<"$(printf '%s\n' "$found" | LC_ALL=C awk -F: -v px="$prefix" '
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
  if [ "$scope" = "per-plan" ]; then
    # Under this convention there is no shared sequence to collide with, so
    # "is this range free" has no project-wide meaning: a sibling plan holding
    # ${prefix}1 is the convention working, and the asking plan holding it is
    # the asking plan's own table, which the caller just wrote. Both are the
    # flat reading's answer to a question this project does not ask.
    #
    # What IS worth catching is the one collision the convention admits: the
    # same id on two rows of ONE plan. A duplicate there is undetectable by
    # any other means — the test command `--test-name-pattern '^T5:'` matches
    # both, and the plan's own test count reads right.
    dupes=$(printf '%s\n' "$found" | LC_ALL=C awk -F: -v px="$prefix" -v lo="$lo" -v hi="$hi" '
      { id = $NF; sub("^" px, "", id); n = id + 0
        if (n >= lo && n <= hi) seen[n]++ }
      END { for (n in seen) if (seen[n] > 1) print px n "\t" seen[n] " rows" }
    ' | sort -u)
    if [ -n "$dupes" ]; then
      echo "Error: $plan_id reserves the same id on more than one row:" >&2
      printf '%s\n' "$dupes" | sed 's/^/  /' >&2
      echo "  Scope is per-plan, so ids are unique WITHIN a plan and nowhere else." >&2
      echo "  Continue $plan_id's own sequence from ${prefix}$((highest + 1))." >&2
      exit 3
    fi
    exit 0
  fi
  # The plan being verified holds its own ids — a range is free if nothing
  # OUTSIDE the asking plan claims it. The caller is a review gate reading a
  # plan that has already written its table, so its own rows must not count as
  # collisions with itself; --plan / LV_VERIFY_SELF names the plan to discount.
  self="$plan_id"
  clashes=$(printf '%s\n' "$found" | LC_ALL=C awk -F: -v px="$prefix" -v lo="$lo" -v hi="$hi" -v self="$self" '
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
    # Said AFTER the collisions and after the advice, because when this fires
    # the advice above is the wrong instruction — the reader needs the list,
    # what it would normally mean, and why it may mean nothing here.
    if printf '%s\n' "$clashes" | flat_reading_suspect; then
      per_plan_advice "$(printf '%s\n' "$clashes" | grep -oE 'plans/[^/]+/plan\.md' | sort -u | wc -l | tr -d ' ')"
    fi
    exit 3
  fi
  exit 0
fi

wf_emit TEST_ID_PREFIX      "$prefix"
wf_emit TEST_ID_SCOPE       "$scope"
wf_emit TEST_ID_HIGHEST     "$highest"
wf_emit TEST_ID_HIGHEST_FROM "$highest_from"
wf_emit TEST_ID_NEXT        "${prefix}$((highest + 1))"
if [ "$count" -gt 0 ]; then
  wf_emit TEST_ID_RANGE "${prefix}$((highest + 1))-${prefix}$((highest + count))"
fi
