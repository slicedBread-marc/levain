#!/usr/bin/env bash
# lv-defer-criterion.sh — the producer for plans/deferred-criteria.md.
#
#   lv-defer-criterion.sh <plan-id> <tag> "<criterion>" [--prereq <text>] [--note <text>] [--no-commit]
#   lv-defer-criterion.sh --list [prereq-filter]
#   lv-defer-criterion.sh --consume <DC-NNN> <plan-id> [--no-commit]
#   lv-defer-criterion.sh --satisfy <DC-NNN> [--evidence <text>] [--no-commit]
#   lv-defer-criterion.sh --amend <DC-NNN> [--criterion <text>] [--prereq <text>] [--note <text>] [--no-commit]
#
# A CRITERION'S TEXT IS NOT FINAL WHEN IT IS WRITTEN
#
# --consume and --satisfy record how a row ENDED. Neither can fix what it SAYS,
# and this file tells its reader not to hand-edit it — so a criterion later
# found incomplete had no correct way to be corrected at all.
#
# client-a's DC-048: an operator established that the criterion is only
# observable with nothing intercepting traffic, and asked for that precondition
# to be stated in the criterion, so that a future failure to reproduce reads as
# "check for a proxy" rather than as a regression. The only options were to
# hand-edit a file that forbids it, or to satisfy and re-defer under a new ID,
# breaking every reference to the old one. It went into --satisfy --evidence
# instead — which preserves the words but files them under the outcome, where
# someone who has not yet run the criterion does not see them (WFI-158).
#
# --amend rewrites the text fields in place and keeps the ID, which is the
# whole point: the ID is what other plans and issues already cite.
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
# `lv-spec` step 1a has read this file since schema v5. lv-test could write it,
# but only by hand and only down one narrow path — the user had to say the
# prerequisite feature was not built yet. Across 16 plans of a real program the
# file never came into existence. This makes the write mechanical and gives the
# two commoner reasons (external, soak) a way in.
#
# Tags:
#   external   needs a real third-party system, credentials, or a physical act
#   soak       needs real elapsed calendar time
#   unbuilt    the prerequisite feature does not exist yet (the lv-test path)
#
# eyes:* never defers — a subjective check either blocks the merge or files a
# cosmetic bug. See lv-test.
#
# Prereq defaults: `first-real-use` (external), `next-cycle` (soak), `—`
# (unbuilt). It may also be a plan ID (`PLN-041`) or a date (`2026-09-01`).
#
# Exit 0 on success, 1 on error.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"
# shellcheck source=lv-lock.sh
source "$(dirname "$0")/lv-lock.sh"

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
  lv_id_render << 'HEADER'
# Deferred Criteria

> Manual criteria that no gate could ever satisfy — they need a real external
> system, real credentials, a physical act, or real elapsed calendar time.
> Their plan shipped without them; they wait here for a plan that touches the
> same surface.
>
> Also holds criteria skipped because the prerequisite feature was not built
> yet (tag `unbuilt`).
>
> Written by `lv-defer-criterion.sh` (from `/lv-test`). Read by `/lv-spec`
> step 1a, which offers matching rows when a new plan is drafted.
> Do not hand-edit — use the script so IDs stay unique.
>
> Status is `open` until one of two things ends it:
> `--consume <DC-NNN> <plan-id>` — a later plan adopted it as an acceptance
> criterion, and will check it there.
> `--satisfy <DC-NNN> --evidence "<what proved it>"` — the real use happened
> and the criterion is true. No plan involved.
>
> To correct or qualify what a row SAYS without ending it — a precondition
> discovered later, a criterion found incomplete — use
> `--amend <DC-NNN> --criterion "<new text>"` (also `--prereq`, `--note`).
> It keeps the ID, because the ID is what other plans already cite.

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

# ── A criterion is one line of prose, and that is enforceable ─────────────
#
# THE SHELL RUNS THE PLAN'S BACKTICKS BEFORE THIS SCRIPT EVER SEES THEM
#
# Plan criteria routinely contain backticked commands — that is how a planner
# writes "run `scripts/drive-sync.sh pull` and confirm the refusal". A caller
# that passes such a criterion inside DOUBLE quotes has already lost: the shell
# command-substitutes every backtick pair before argv is built, so what arrives
# here is the *output* of running the plan's own commands, with the backticked
# text replaced by nothing.
#
# client-a's WFI-194 is that, exactly. An unattended tester deferring a
# criterion for PLN-179 double-quoted it; the shell executed a real drive-sync
# pull against a mounted physical volume, and DC-119 was written containing
# ~2.5KB of rsync itemisation with the paths substituted to empty — "against
# the real volume at , with  appended on the Mac". The row was wrong, and the
# row was the *lesser* half: an unattended worker executed an unreviewed
# command with its full privileges as a side effect of recording a deferral.
#
# This script cannot un-run that; substitution happens in the caller. What it
# can do is refuse to accept the result, so the damage is loud instead of
# committed. Two shapes catch it without guessing at content:
#
#   - a criterion arriving with embedded newlines. Every criterion is one line;
#     command output almost never is. `tr -d '\n'` used to glue those lines
#     into a single row silently, which is precisely why nobody noticed.
#   - a criterion far longer than prose. 500 characters is several sentences.
#
# And the affordance that makes the right thing easy: `-` reads the criterion
# from stdin, where no shell quoting exists to get wrong. Callers passing text
# they did not write should prefer it; single quotes are the minimum.
CRITERION_MAX=500

read_criterion_stdin() {
  # A single `-` means "the text is on stdin" — heredoc, pipe, file. Nothing in
  # between for the shell to expand.
  cat
}

check_criterion() {
  # $1 = the text, $2 = what to call it in the error
  local text="$1" what="$2"
  # `case`, not `grep -q $'\n'`: a grep pattern containing a newline is two
  # patterns, and both halves are empty, so that form matches every string.
  if [ "$text" != "${text%$'\n'*}" ]; then
    echo "Error: $what arrived with embedded newlines." >&2
    echo "       A criterion is one line. Multi-line text here almost always means the" >&2
    echo "       shell command-substituted backticks in the criterion and handed over the" >&2
    echo "       OUTPUT of running them (WFI-194) — which also means those commands RAN." >&2
    echo "       Pass the criterion in SINGLE quotes, or pass '-' and give it on stdin." >&2
    return 1
  fi
  if [ "${#text}" -gt "$CRITERION_MAX" ]; then
    echo "Error: $what is ${#text} characters — over the $CRITERION_MAX-character limit." >&2
    echo "       Criteria are a sentence or two. This length usually means backticks in" >&2
    echo "       the criterion were command-substituted by the caller's shell (WFI-194)." >&2
    echo "       Pass the criterion in SINGLE quotes, or pass '-' and give it on stdin." >&2
    return 1
  fi
  return 0
}

# ── Modes ─────────────────────────────────────────────────────────────────

# The other place a caller looks for the verb list. It used to name only the
# add form, so anyone who reached it while trying to close a row learned that
# closing a row was not supported (WFI-152).
usage() {
  lv_id_render >&2 << 'USAGE'
Usage:
  lv-defer-criterion.sh <plan-id> <external|soak|unbuilt> '<criterion>' [--prereq <text>] [--note <text>] [--no-commit]
      Defer a criterion its plan cannot satisfy, and tick it off in plan.md.

      QUOTE THE CRITERION WITH SINGLE QUOTES. Criteria contain backticked
      commands; inside double quotes the shell RUNS them before this script
      sees anything (WFI-194). Better still, pass '-' and give the text on
      stdin, where there is no quoting to get wrong:

        lv-defer-criterion.sh PLN-179 external - <<'CRIT'
        Confirm `scripts/drive-sync.sh pull` refuses on divergence
        CRIT

  lv-defer-criterion.sh --list [prereq-filter]
      Open rows, tab-separated: ID, criterion, tag, from-plan, prereq, note.

  lv-defer-criterion.sh --consume <DC-NNN> <plan-id> [--no-commit]
      A later plan adopted the criterion; that plan will check it.

  lv-defer-criterion.sh --satisfy <DC-NNN> [--evidence "<proof>"] [--no-commit]
      The real use happened and the criterion is true. No plan involved.
      This is the ordinary ending for an (external) criterion — do not reach
      for --consume, which records future work on a plan that will not do it.

  lv-defer-criterion.sh --amend <DC-NNN> [--criterion "<text>"] [--prereq "<text>"]
                                         [--note "<text>"] [--no-commit]
      Correct or qualify what the row SAYS, keeping its ID and status. For a
      precondition found later, or a criterion found incomplete. At least one
      of --criterion / --prereq / --note is required.
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
    awk -F'|' -v dc_re="^[|] ($LV_DC_RE)-" -v want="$filter" '
      $0 ~ dc_re {
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
  --amend)
    dc="${2:?--amend requires a $LV_DC-NNN}"
    shift 2
    new_criterion=""; new_prereq=""; new_note=""; do_commit=true
    set_criterion=false; set_prereq=false; set_note=false
    while [ $# -gt 0 ]; do
      case "$1" in
        --criterion) new_criterion="${2:?--criterion requires a value}"; set_criterion=true; shift 2 ;;
        --prereq)    new_prereq="${2:?--prereq requires a value}";       set_prereq=true;    shift 2 ;;
        --note)      new_note="${2:?--note requires a value}";           set_note=true;      shift 2 ;;
        --no-commit) do_commit=false; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
      esac
    done

    if ! $set_criterion && ! $set_prereq && ! $set_note; then
      echo "Error: --amend needs at least one of --criterion, --prereq, --note" >&2
      usage
      exit 1
    fi

    [ -f "$FILE" ] || { echo "Error: $FILE not found" >&2; exit 1; }
    grep -q "^| $dc |" "$FILE" || { echo "Error: $dc has no row in $FILE" >&2; exit 1; }

    # `--criterion -` reads from stdin, so text full of backticks never passes
    # through a shell word at all. See the header.
    if $set_criterion && [ "$new_criterion" = "-" ]; then
      new_criterion=$(read_criterion_stdin)
    fi
    if $set_criterion; then
      check_criterion "$new_criterion" "--criterion" || exit 1
    fi

    # Same sanitising as the add path: this is free text going into a markdown
    # table, and a pipe would silently add a column.
    new_criterion=$(printf '%s' "$new_criterion" | tr '|' '/' | tr -d '\n')
    new_prereq=$(printf '%s'    "$new_prereq"    | tr '|' '/' | tr -d '\n')
    new_note=$(printf '%s'      "$new_note"      | tr '|' '/' | tr -d '\n')

    wf_lock_acquire deferred-criteria
    sync_header

    # Amending a row that has already ended is legal but worth saying out loud
    # — the reader of a consumed row is the plan that adopted it, and its words
    # changing under them is exactly the kind of thing to be told about.
    was_status=$(awk -F'|' -v dc_re="^[|] ($LV_DC_RE)-" -v dc="$dc" '{ id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if ($0 ~ dc_re && id == dc) { s = $9; gsub(/^[ \t]+|[ \t]+$/, "", s); print s; exit } }' "$FILE")
    [ "$was_status" = "open" ] || echo "Note: $dc is '$was_status', not open — amending its text anyway" >&2

    before=$(grep "^| $dc |" "$FILE" | head -1)
    LV_C="$new_criterion" LV_P="$new_prereq" LV_N="$new_note" \
    awk -F'|' -v dc_re="^[|] ($LV_DC_RE)-" -v dc="$dc" -v sc="$set_criterion" -v sp="$set_prereq" -v sn="$set_note" '
      BEGIN { OFS = "|" }   # ENVIRON, not -v: -v expands \n and \\ in the value
      {
        id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
        if ($0 ~ dc_re && id == dc) {
          if (sc == "true") $3 = " " ENVIRON["LV_C"] " "
          if (sp == "true") $6 = " " ENVIRON["LV_P"] " "
          if (sn == "true") $7 = " " ENVIRON["LV_N"] " "
        }
        print
      }
    ' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"

    echo "Amended $dc"
    echo "  was: $before"
    echo "  now: $(grep "^| $dc |" "$FILE" | head -1)"

    # Committed here for the same reason every other write path is (WFI-144):
    # the caller's exit pathspec cannot name a file this script chose, and a
    # row left dirty on the shared develop checkout is carried off by whichever
    # concurrent worker commits next (WFI-140).
    if $do_commit; then
      if ! (cd "$ROOT" && "$SELF_DIR/lv-commit.sh" "docs($dc): criterion amended" --add "plans/deferred-criteria.md"); then
        echo "  lv-defer-criterion: $dc is amended but could not be committed —" >&2
        echo "  commit plans/deferred-criteria.md before another worker does" >&2
      fi
    fi
    exit 0
    ;;
  --consume|--satisfy)
    mode="$1"
    dc="${2:?$1 requires a $LV_DC-NNN}"
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

    was=$(awk -F'|' -v dc_re="^[|] ($LV_DC_RE)-" -v dc="$dc" '{ id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
      if ($0 ~ dc_re && id == dc) { s = $9; gsub(/^[ \t]+|[ \t]+$/, "", s); print s; exit } }' "$FILE")
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
    LV_DC_STATUS="$status" awk -F'|' -v dc_re="^[|] ($LV_DC_RE)-" -v dc="$dc" 'BEGIN { OFS="|"; st = ENVIRON["LV_DC_STATUS"] }
      {
        id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
        if ($0 ~ dc_re && id == dc) { $9 = " " st " " }
        print
      }
    ' "$FILE" > "$FILE.tmp" && mv "$FILE.tmp" "$FILE"
    echo "Deferred criterion $dc → $status"

    # Committed here, for the same reason the add path is (WFI-144): this is
    # the only path that writes the file, the caller's exit pathspec may not
    # name it, and a row left dirty on the shared develop checkout is carried
    # off by whichever concurrent worker commits next (WFI-140).
    if $do_commit; then
      if ! (cd "$ROOT" && "$SELF_DIR/lv-commit.sh" "$msg" --add "plans/deferred-criteria.md"); then
        echo "  lv-defer-criterion: $dc is updated but could not be committed —" >&2
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

plan_id=$(printf '%s' "$raw_id" | grep -oE "($LV_PLN_RE)-[0-9]+" || true)
if [ -z "$plan_id" ] || [ -z "$criterion" ]; then
  usage
  exit 1
fi

# `-` means the criterion is on stdin, where the shell has nothing to expand.
[ "$criterion" = "-" ] && criterion=$(read_criterion_stdin)
check_criterion "$criterion" "the criterion" || exit 1

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

# ── Already deferred? ─────────────────────────────────────────────────────
#
# This file is a work list handed to a person, and two rows saying the same
# thing are two items that are one. client-a's DC-051 and DC-053 are
# byte-identical criterion text deferred twice from the same plan (PLN-090);
# the script took the second without a word (WFI-158).
#
# The answer is not to refuse. A duplicate means the criterion is ALREADY
# deferred, and refusing would leave the caller's plan.md box unticked — an
# unticked box reads as "silently dropped", the exact thing the checkoff below
# exists to prevent. So the existing ID is reused: no new row, the checkoff
# still happens, and the caller is told which ID it landed under.
#
# Matched on a normalised copy — emphasis markers stripped, whitespace
# collapsed, case folded — for the same reason the checkoff matcher normalises
# (WFI-137): the text arriving here is usually the plan's line retyped without
# its backticks. Only `open` rows count. A criterion that was satisfied or
# consumed and comes back is genuinely new work, and gets a new ID.
dup=$(LV_CRIT="$criterion" awk -F'|' -v dc_re="^[|] ($LV_DC_RE)-" '
  function norm(s) {
    gsub(/[`*_]/, "", s); gsub(/[[:space:]]+/, " ", s); gsub(/^ | $/, "", s)
    return tolower(s)
  }
  BEGIN { want = norm(ENVIRON["LV_CRIT"]) }
  $0 ~ dc_re {
    status = $9; gsub(/^[ \t]+|[ \t]+$/, "", status)
    if (status != "open") next
    if (norm($3) == want) {
      id = $2; from = $5
      gsub(/^[ \t]+|[ \t]+$/, "", id); gsub(/^[ \t]+|[ \t]+$/, "", from)
      print id "\t" from
      exit
    }
  }
' "$FILE")

if [ -n "$dup" ]; then
  next="${dup%%$'\t'*}"
  dup_from="${dup#*$'\t'}"
  echo "Already deferred as $next (from $dup_from) — reusing that row, no new ID." >&2
  echo "  If this is genuinely a second, different criterion, reword it so the two" >&2
  echo "  can be told apart on the work list. To correct the existing wording:" >&2
  echo "    lv-defer-criterion.sh --amend $next --criterion \"<text>\"" >&2
  echo "Deferred: $next ($tag, prereq $prereq) from $plan_id — existing row"
else
  # Next DC id. `10#` forces base 10 — a zero-padded "008" is not octal here.
  last=$(grep -oE "^\| ($LV_DC_RE)-[0-9]+" "$FILE" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || true)
  next=$(printf '%s-%03d' "$LV_DC" "$(( 10#${last:-0} + 1 ))")

  printf '| %s | %s | %s | %s | %s | %s | %s | open |\n' \
    "$next" "$criterion" "$tag" "$plan_id" "$prereq" "$note" "$(date +%Y-%m-%d)" >> "$FILE"

  echo "Deferred: $next ($tag, prereq $prereq) from $plan_id"
fi

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
eval "$("$(dirname "$0")/lv-plan-info.sh" "$plan_id" 2>/dev/null)" || true
plan_file="$ROOT/${PLAN_DIR:-}/plan.md"
ticked=false

# Already ticked against this same DC — the reuse path above found the row, so
# the plan very likely already carries the checkoff from the first deferral.
# Running the matcher anyway would find no UNCHECKED line and print ACTION
# REQUIRED at a plan that is already correct.
if [ -n "${PLAN_DIR:-}" ] && [ -f "$plan_file" ] && grep -q "deferred as $next\b" "$plan_file"; then
  echo "  already ticked in $PLAN_DIR/plan.md as $next — nothing to do"
elif [ -n "${PLAN_DIR:-}" ] && [ -f "$plan_file" ]; then
  # ENVIRON, not -v: awk expands escape sequences in a -v assignment, so a
  # criterion naming a Windows path (`D:\git\...`) loses its backslashes and
  # then matches nothing. ENVIRON hands the bytes over untouched.
  if LV_CRIT="$criterion" awk -v dc="$next" '
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
      BEGIN { done = 0; crit = ENVIRON["LV_CRIT"]; ncrit = norm(crit) }
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
# `/lv-test`'s exit pathspec names `plans/deferred-criteria.md` and never that
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
# Same conclusion as lv-bug-close.sh and lv-bug-consume.sh (WFI-106, WFI-112,
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
  if ! (cd "$ROOT" && "$SELF_DIR/lv-commit.sh" \
        "test($plan_id): $next deferred ($tag)" --add "${commit_paths[@]}"); then
    echo "  lv-defer-criterion: the deferral is written but could not be committed —" >&2
    echo "  commit $both before another worker does" >&2
  fi
fi
