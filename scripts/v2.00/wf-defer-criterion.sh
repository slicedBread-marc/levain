#!/usr/bin/env bash
# wf-defer-criterion.sh — the producer for plans/deferred-criteria.md.
#
#   wf-defer-criterion.sh <plan-id> <tag> "<criterion>" [--prereq <text>] [--note <text>] [--no-commit]
#   wf-defer-criterion.sh --list [prereq-filter]
#   wf-defer-criterion.sh --consume <DC-NNN> <plan-id> [--no-commit]
#   wf-defer-criterion.sh --satisfy <DC-NNN> [--evidence <text>] [--no-commit]
#
# TWO WAYS A DEFERRED CRITERION ENDS, AND ONLY ONE HAD A VERB
#
# `--consume` means another plan adopted the criterion into its acceptance
# criteria — it is now that plan's problem, and it will be checked there.
#
# That is not how an `external` criterion usually ends. An external criterion is
# defined as one satisfiable only at first real use, so the ordinary ending is
# that the real use happens and the criterion turns out to be true, with no plan
# involved at all. client-a's DC-040 ("Deploy to Production Run tests
# completes green on ubuntu-latest") was satisfied outright by a green run, and
# there was no way to say so: recording it as "consumed by PLN-075" would name a
# completed plan as owing future work it will never do. So all 40 DC rows in
# that project sat at `open`, including ones long since true, and the file
# stopped meaning anything (WFI-148).
#
# `--satisfy` is that ending. The evidence goes in the row, because a criterion
# marked satisfied with nothing behind it is worth less than one left open.
#
# The add path COMMITS what it wrote — the DC row and the plan.md checkoff
# together, in one commit. They are two sides of one state change and a caller's
# pathspec cannot name a path this script chose (WFI-144). --no-commit opts out.
#
# An (external) or (soak) criterion cannot be satisfied at gate time by anyone
# — not the agent, not the human standing next to it. Blocking a plan on one
# buys nothing and costs a stop, so the plan completes and the criterion
# travels here, to be picked up by whichever future plan touches that surface.
#
# `wf-spec` step 1a has read this file since schema v5. wf-test could write it,
# but only by hand and only down one narrow path — the user had to say the
# prerequisite feature was not built yet. Across 16 plans of a real program the
# file never came into existence. This makes the write mechanical and gives the
# two commoner reasons (external, soak) a way in.
#
# Tags:
#   external   needs a real third-party system, credentials, or a physical act
#   soak       needs real elapsed calendar time
#   unbuilt    the prerequisite feature does not exist yet (the wf-test path)
#
# eyes:* never defers — a subjective check either blocks the merge or files a
# cosmetic bug. See wf-test.
#
# Prereq defaults: `first-real-use` (external), `next-cycle` (soak), `—`
# (unbuilt). It may also be a plan ID (`PLN-041`) or a date (`2026-09-01`).
#
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=wf-orch-lib.sh
source "$(dirname "$0")/wf-orch-lib.sh"
# shellcheck source=wf-lock.sh
source "$(dirname "$0")/wf-lock.sh"

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(wf_develop_root)"
FILE="$ROOT/plans/deferred-criteria.md"

# The preamble is documentation, and it is the copy an agent actually reads —
# it opens the file to see the rows and takes the header as the contract. It
# was written once, at creation, and never again, so a file created before a
# verb existed documented a tool that no longer matched the script.
#
# client-a's file was created 2026-08-04 and still said only "use the
# script so IDs stay unique". `--satisfy` shipped in 6.10.0 and was deployed
# there, in the script and in both skills — and two hours later a worker with
# two criteria satisfied by a real drive round-trip read that header, concluded
# no such verb existed, declined to hand-edit, and filed WFI-152. The verb was
# on disk the whole time. Stale in-file docs do not read as stale; they read as
# authoritative.
#
# So the header is regenerated on every write path, not just creation. The file
# says do not hand-edit it, which is exactly what makes rewriting it safe.
wf_dc_header() {
  cat << 'HEADER'
# Deferred Criteria

> Manual criteria that no gate could ever satisfy — they need a real external
> system, real credentials, a physical act, or real elapsed calendar time.
> Their plan shipped without them; they wait here for a plan that touches the
> same surface.
>
> Also holds criteria skipped because the prerequisite feature was not built
> yet (tag `unbuilt`).
>
> Written by `wf-defer-criterion.sh` (from `/wf-test`). Read by `/wf-spec`
> step 1a, which offers matching rows when a new plan is drafted.
> Do not hand-edit — use the script so IDs stay unique.
>
> Status is `open` until one of two things ends it:
> `--consume <DC-NNN> <plan-id>` — a later plan adopted it as an acceptance
> criterion, and will check it there.
> `--satisfy <DC-NNN> --evidence "<what proved it>"` — the real use happened
> and the criterion is true. No plan involved.

| ID | Criterion | Tag | From | Prereq | Note | Added | Status |
|-|-|-|-|-|-|-|-|
HEADER
}

ensure_file() {
  [ -f "$FILE" ] && return 0
  mkdir -p "$(dirname "$FILE")"
  wf_dc_header > "$FILE"
}

# Replace whatever preamble the file has with the current one, keeping every
# row. The table's separator line is the boundary: everything through it is
# generated, everything after it is data.
sync_header() {
  [ -f "$FILE" ] || return 0
  local sep current
  sep=$(grep -n '^|-' "$FILE" | head -1 | cut -d: -f1)
  # No separator means no table — a file mid-hand-edit or truncated. Rewriting
  # its preamble could not find the row boundary, so leave it entirely alone.
  [ -n "$sep" ] || return 0
  current=$(sed -n "1,${sep}p" "$FILE")
  [ "$current" = "$(wf_dc_header)" ] && return 0
  { wf_dc_header; sed -n "$((sep + 1)),\$p" "$FILE"; } > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
  echo "  refreshed the header of plans/deferred-criteria.md — it predated the current verbs" >&2
}

# ── Modes ─────────────────────────────────────────────────────────────────

# The other place a caller looks for the verb list. It used to name only the
# add form, so anyone who reached it while trying to close a row learned that
# closing a row was not supported (WFI-152).
usage() {
  cat >&2 << 'USAGE'
Usage:
  wf-defer-criterion.sh <plan-id> <external|soak|unbuilt> "<criterion>" [--prereq <text>] [--note <text>] [--no-commit]
      Defer a criterion its plan cannot satisfy, and tick it off in plan.md.

  wf-defer-criterion.sh --list [prereq-filter]
      Open rows, tab-separated: ID, criterion, tag, from-plan, prereq, note.

  wf-defer-criterion.sh --consume <DC-NNN> <plan-id> [--no-commit]
      A later plan adopted the criterion; that plan will check it.

  wf-defer-criterion.sh --satisfy <DC-NNN> [--evidence "<proof>"] [--no-commit]
      The real use happened and the criterion is true. No plan involved.
      This is the ordinary ending for an (external) criterion — do not reach
      for --consume, which records future work on a plan that will not do it.
USAGE
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list)
    [ -f "$FILE" ] || exit 0
    filter="${2:-}"
    awk -F'|' -v want="$filter" '
      /^\| DC-/ {
        id = $2; crit = $3; tag = $4; from = $5; prereq = $6; note = $7; status = $9
        gsub(/^[ \t]+|[ \t]+$/, "", id);     gsub(/^[ \t]+|[ \t]+$/, "", crit)
        gsub(/^[ \t]+|[ \t]+$/, "", tag);    gsub(/^[ \t]+|[ \t]+$/, "", from)
        gsub(/^[ \t]+|[ \t]+$/, "", prereq); gsub(/^[ \t]+|[ \t]+$/, "", note)
        gsub(/^[ \t]+|[ \t]+$/, "", status)
        if (status != "open") next
        if (want != "" && prereq != want) next
        printf "%s\t%s\t%s\t%s\t%s\t%s\n", id, crit, tag, from, prereq, note
      }
    ' "$FILE"
    exit 0
    ;;
  --consume|--satisfy)
    mode="$1"
    dc="${2:?$1 requires a DC-NNN}"
    shift 2
    into=""
    evidence=""
    do_commit=true
    if [ "$mode" = "--consume" ]; then
      into="${1:?--consume requires the consuming plan id}"; shift
    fi
    while [ $# -gt 0 ]; do
      case "$1" in
        --evidence)  evidence="${2:?--evidence requires a value}"; shift 2 ;;
        --no-commit) do_commit=false; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    [ -f "$FILE" ] || { echo "Error: $FILE not found" >&2; exit 1; }
    # A DC id that is not in the file is a caller mistake, and the awk below
    # would rewrite nothing and report success — the shape that let rows go
    # unrecorded silently. Say it instead.
    grep -q "^| $dc |" "$FILE" || { echo "Error: $dc has no row in $FILE" >&2; exit 1; }

    was=$(awk -F'|' -v dc="$dc" '{ id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if ($0 ~ /^\| DC-/ && id == dc) { s = $9; gsub(/^[ \t]+|[ \t]+$/, "", s); print s; exit } }' "$FILE")
    [ "$was" = "open" ] || echo "Note: $dc was already '$was' — overwriting" >&2

    if [ "$mode" = "--consume" ]; then
      status="consumed by $into"
      msg="spec($into): $dc consumed"
    else
      # Free text into a markdown table: a pipe would silently add a column.
      evidence=$(printf '%s' "$evidence" | tr '|' '/' | tr -d '\n')
      status="satisfied $(date +%Y-%m-%d)${evidence:+ — $evidence}"
      msg="test($dc): satisfied${evidence:+ — $evidence}"
    fi

    wf_lock_acquire deferred-criteria
    sync_header
    WF_DC_STATUS="$status" awk -F'|' -v dc="$dc" 'BEGIN { OFS="|"; st = ENVIRON["WF_DC_STATUS"] }
      {
        id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
        if ($0 ~ /^\| DC-/ && id == dc) { $9 = " " st " " }
        print
      }
    ' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    echo "Deferred criterion $dc → $status"

    # Committed here, for the same reason the add path is (WFI-144): this is
    # the only path that writes the file, the caller's exit pathspec may not
    # name it, and a row left dirty on the shared develop checkout is carried
    # off by whichever concurrent worker commits next (WFI-140).
    if $do_commit; then
      if ! (cd "$ROOT" && "$SELF_DIR/wf-commit.sh" "$msg" --add "plans/deferred-criteria.md"); then
        echo "  wf-defer-criterion: $dc is updated but could not be committed —" >&2
        echo "  commit plans/deferred-criteria.md before another worker does" >&2
      fi
    fi
    exit 0
    ;;
esac

# ── Add ───────────────────────────────────────────────────────────────────

raw_id="${1:-}"
tag="${2:-}"
criterion="${3:-}"
shift 3 2>/dev/null || true

prereq=""
note=""
do_commit=true
while [ $# -gt 0 ]; do
  case "$1" in
    --prereq)    prereq="${2:?--prereq requires a value}"; shift 2 ;;
    --note)      note="${2:?--note requires a value}"; shift 2 ;;
    --no-commit) do_commit=false; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

plan_id=$(printf '%s' "$raw_id" | grep -oE 'PLN-[0-9]+' || true)
if [ -z "$plan_id" ] || [ -z "$criterion" ]; then
  usage
  exit 1
fi

case "$tag" in
  external) [ -n "$prereq" ] || prereq="first-real-use" ;;
  soak)     [ -n "$prereq" ] || prereq="next-cycle" ;;
  unbuilt)  [ -n "$prereq" ] || prereq="—" ;;
  *) echo "Error: tag must be 'external', 'soak' or 'unbuilt' (got '$tag') — eyes:* criteria never defer" >&2; exit 1 ;;
esac

# Pipes would break the table; both fields are free text from a plan or a user.
criterion=$(printf '%s' "$criterion" | tr '|' '/' | tr -d '\n')
note=$(printf '%s' "$note" | tr '|' '/' | tr -d '\n')
[ -n "$note" ] || note="—"

wf_lock_acquire deferred-criteria
ensure_file
sync_header

# Next DC id. `10#` forces base 10 — a zero-padded "008" is not octal here.
last=$(grep -oE '^\| DC-[0-9]+' "$FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)
next=$(printf 'DC-%03d' "$(( 10#${last:-0} + 1 ))")

printf '| %s | %s | %s | %s | %s | %s | %s | open |\n' \
  "$next" "$criterion" "$tag" "$plan_id" "$prereq" "$note" "$(date +%Y-%m-%d)" >> "$FILE"

echo "Deferred: $next ($tag, prereq $prereq) from $plan_id"

# ── Close the loop in the plan itself ─────────────────────────────────────
#
# The row above is the program-wide record. It is not the record a person reads
# when they open the completed plan — there they see the `#### Manual` list, and
# an unchecked box there means BOTH "deferred on purpose" and "silently
# dropped". Those need to stop looking alike: the same ambiguity is what made
# BUG-020/WFI-054 hard to notice, and PLN-018 completed with its deferral
# correctly recorded here and its checkbox untouched (WFI-056).
#
# Best-effort by design. A criterion reworded on the way in still gets its DC
# row; failing the deferral over a text mismatch would trade a bookkeeping gap
# for a pipeline stop.
eval "$("$(dirname "$0")/wf-plan-info.sh" "$plan_id" 2>/dev/null)" || true
plan_file="$ROOT/${PLAN_DIR:-}/plan.md"
ticked=false

if [ -n "${PLAN_DIR:-}" ] && [ -f "$plan_file" ]; then
  # ENVIRON, not -v: awk expands escape sequences in a -v assignment, so a
  # criterion naming a Windows path (`D:\git\...`) loses its backslashes and
  # then matches nothing. ENVIRON hands the bytes over untouched.
  if WF_CRIT="$criterion" awk -v dc="$next" '
      # The criterion reaching this script is nearly always the plan text with
      # its inline markdown stripped — a caller reads `- [ ] (external) run
      # `tool doctor` **and** ...` off the screen and types it back without the
      # backticks. A literal substring match then fails on every criterion a
      # planner formatted, which is most of them (WFI-137). Compare a
      # normalised copy of both sides as the fallback: same characters, minus
      # the emphasis markers and any whitespace the reflow moved.
      function norm(s) {
        gsub(/[`*_]/, "", s)
        gsub(/[[:space:]]+/, " ", s)
        gsub(/^ | $/, "", s)
        return s
      }
      BEGIN { done = 0; crit = ENVIRON["WF_CRIT"]; ncrit = norm(crit) }
      /^####[[:space:]]*Manual/ { in_manual = 1; print; next }
      /^(#|##|###|####)[[:space:]]/ {
        if (in_manual && $0 !~ /^####[[:space:]]*Manual/) in_manual = 0
      }
      {
        # index() not a regex: the criterion is free text and may contain any
        # metacharacter a planner typed.
        if (!done && in_manual && $0 ~ /^[[:space:]]*-[[:space:]]*\[[ ]\]/ &&
            (index($0, crit) > 0 || (ncrit != "" && index(norm($0), ncrit) > 0))) {
          sub(/\[[ ]\]/, "[x]")
          printf "%s — deferred as %s\n", $0, dc
          done = 1
          next
        }
        print
      }
      END { exit (done ? 0 : 1) }
    ' "$plan_file" > "$plan_file.tmp"; then
    mv "$plan_file.tmp" "$plan_file"
    echo "  ticked in $PLAN_DIR/plan.md — deferred as $next"
    ticked=true
  else
    rm -f "$plan_file.tmp"
    echo "  ACTION REQUIRED: no matching unchecked criterion in $PLAN_DIR/plan.md." >&2
    echo "  Edit that file now: change the matching '- [ ]' to '- [x]' and append ' — deferred as $next'." >&2
    echo "  Do not complete the plan with the box still empty — an empty box reads as 'silently dropped'." >&2
    echo "  Unchecked Manual criteria in that file:" >&2
    awk '
      /^####[[:space:]]*Manual/ { in_manual = 1; next }
      /^(#|##|###|####)[[:space:]]/ { if (in_manual) in_manual = 0 }
      in_manual && /^[[:space:]]*-[[:space:]]*\[[ ]\]/ { printf "    %s\n", $0 }
    ' "$plan_file" >&2
  fi
fi

# ── Land both sides together ──────────────────────────────────────────────
#
# A deferral is one state change with two sides: the DC row above, and the
# `[x] … — deferred as DC-NNN` checkoff in plan.md that anyone opening the
# completed plan actually reads. This script wrote both and committed neither,
# leaving them to whatever pathspec the caller happened to name — and
# `/wf-test`'s exit pathspec names `plans/deferred-criteria.md` and never that
# plan's `plan.md`.
#
# So across one 16-plan sweep DC-030..DC-039 were all recorded and committed
# while the checkoffs for six of them sat modified and uncommitted in the
# working tree, on plans that had already reached `complete`. Read from git,
# those plans show the criterion as `[ ]` — a plan that completed with unmet
# criteria, the exact reading the checkoff exists to prevent. Which plans got
# it depended on whether an unrelated stash-restore commit swept the folder,
# so nothing distinguished them (client-a WFI-144).
#
# Same conclusion as wf-bug-close.sh and wf-bug-consume.sh (WFI-106, WFI-112,
# WFI-136): a script that writes two paths commits them itself, because the
# caller's pathspec cannot know about a path this script chose.
#
# Committed from the develop root, since that is where both files live — the
# caller is usually standing in a feature worktree, where neither exists.
if $do_commit; then
  commit_paths=("plans/deferred-criteria.md")
  both="plans/deferred-criteria.md"
  if $ticked; then
    commit_paths+=("${PLAN_DIR}/plan.md")
    both="$both and $PLAN_DIR/plan.md"
  fi
  if ! (cd "$ROOT" && "$SELF_DIR/wf-commit.sh" \
        "test($plan_id): $next deferred ($tag)" --add "${commit_paths[@]}"); then
    echo "  wf-defer-criterion: the deferral is written but could not be committed —" >&2
    echo "  commit $both before another worker does" >&2
  fi
fi
