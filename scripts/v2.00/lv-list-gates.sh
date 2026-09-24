#!/usr/bin/env bash
# lv-list-gates.sh [artifact-id]
#
# Lists artifacts parked on a human decision — the /lv-attend work queue.
#
# With an artifact ID: exit 0 if that artifact has an open gate (and print it),
# exit 1 if not. This is the dispatcher's "should I skip this one?" test.
#
# stdout, one per line, tab-separated:
#   <id>\t<gate-name>\t<age>\t<question>\t<context>\t<blocking>\t<state>\t<fit>\t<qfit>
#
# <state> is the artifact's current REGISTRY state, and <fit> is `ok` or
# `mismatch` — whether a gate by that name can still be acted on from there.
#
# <qfit> is `current` or `stale`: whether the QUESTION still describes the plan.
# A question is a claim of fact composed when the gate opened — a verdict, a
# round count, a test tally — and the plan can move while the gate is parked,
# because re-running lv-gate-open.sh on an open gate leaves it as is by design.
# client-b WFI-018: round 1 opened spec-approval carrying "Approved with notes
# (0 Critical)"; round 2 then rewrote the plan around a Critical an independent
# review had found, and the parked question still read "Approved with notes".
# Two different columns for two different failures — <fit> says the gate has
# outlived its state, <qfit> says the text has outlived its plan — and a row
# can be `ok` and `stale` at once, which is exactly WFI-018's row.
#
# Appended as a NINTH field rather than folded into <fit>, because every caller
# in the tree reads these rows with `cut -f<n>` for n ≤ 8 and a new column at
# the end costs them nothing.
#
# A gate outlives the state it was opened in. client-a's WFI-082: a
# `manual-test` gate left behind by an earlier bug sat on a plan that had since
# gone back to `draft` with five unaddressed findings. The queue presented it as
# actionable, /lv-attend's manual-test row sent the attendant to /lv-test, and
# /lv-test cannot run on a draft plan — a dead end with nothing in the output
# saying so. The join is reported, not enforced: a stale gate still needs a
# human to close it, so suppressing it would hide the only thing that can.
#
# <blocking> is the number of OTHER incomplete plans that cannot start until
# this gate is answered — the transitive closure over the Deps column.
#
# Ordered by <blocking> descending, then by age. A pure FIFO ordering is
# uncorrelated with what a gate actually costs: on a dependency chain the cost
# of a gate is not the minute it takes to answer, it is that minute times the
# size of the closure behind it. One gate at the root of a 16-plan chain held
# every other plan for 25 hours while the queue presented it alongside a gate
# blocking nothing. Ties still break oldest-first, so nothing starves.
#
# stderr: GATES: N
#
# Exit 0 if any gate is open, 1 if none.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

query="${1:-}"
gates_dir="$(wf_orch_dir)/gates"
REGISTRY="$(wf_develop_root)/plans/REGISTRY.md"

# One record per line is this script's entire output contract, and GATE_QUESTION
# is free text a skill wrote. lv-spec's scope-reduction question embeds the Goal,
# the After and the Reason as separate PARAGRAPHS, so the record ran to 11 lines:
# the first carried the fields, the other 10 were question text with an empty id,
# and `wc -l` duly reported GATES: 11 for a single open gate. A caller trusting
# the count announces 11 decisions waiting; a caller parsing rows by line gets 10
# phantom gates it cannot look up (WFI-049).
#
# Flattened on READ rather than rejected on write: the gate file keeps the full
# text for anyone opening it, /lv-attend still renders it, and the gates already
# sitting on disk are fixed too — a write-side check would only have stopped the
# next one.
flatten() {
  printf '%s' "$1" | tr '\n\t' '  ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//'
}

# state_of <id> → the artifact's REGISTRY state, or `—` when it has no row yet
# (a bug or brief on its way to a first spec, which is a legitimate gate target).
# wf_state_of (lv-orch-lib.sh) does the PLN-alias fallback and the once-per-
# process memoization; this used to carry its own copy of both.
state_of() { wf_state_of "$1" "$REGISTRY"; }

# gate_fit <gate-name> <state> → ok | mismatch
#
# Only gates whose answer HANDS THE WORK to a specific role are checked, and
# only against the state that role acts on. A gate that any state can answer
# (`needs-input`, `goal-missing`) makes no claim and is always `ok`, as is any
# gate name this table does not know — a new gate is not a stale one.
gate_fit() {
  local want=""
  # A terminal artifact answers no question. Whatever the gate asked, the plan
  # has stopped moving and acting on the answer would restart something already
  # finished — so `complete` and `abandoned` are a mismatch for EVERY gate name,
  # including the ones the table below treats as always-ok.
  #
  # client-a's WFI-126: a `needs-input` gate on PLN-039 was listed state=
  # complete fit=ok. Its question — "land PLN-039 and drive it through the
  # pipeline" — had been answered by the pipeline itself in the 45 minutes after
  # the gate opened: committed, merged, completed, promoted to main. Answering it
  # as written would have re-landed all of it. Only reading git history caught it.
  case "$2" in
    complete|abandoned) printf 'mismatch'; return 0 ;;
  esac
  case "$1" in
    manual-test)                        want="testing" ;;
    spec-approval|spec-stuck|scope-reduction) want="draft" ;;
    consistency-*)                      want="ready" ;;
    *)                                  printf 'ok'; return 0 ;;
  esac
  [ "$2" = "—" ] && { printf 'ok'; return 0; }
  if [ "$2" = "$want" ]; then printf 'ok'; else printf 'mismatch'; fi
}

# question_fit <gate-id> <fp-at-open> → current | stale
#
# `current` when the gate carries no at-open fingerprint (a record written
# before lv-gate-open.sh recorded one, or a gate on RELEASE/DEPLOY and on any
# other artifact with no plan.md) and when the plan cannot be resolved. An
# absent fingerprint is not evidence the question drifted, and flagging every
# such row `stale` would train a reader to ignore the column.
question_fit() {
  local qid="$1" was="$2" now
  [ -n "$was" ] || { printf 'current'; return 0; }
  now=$(wf_plan_body_fingerprint "$qid" 2>/dev/null || true)
  if [ -n "$now" ] && [ "$now" != "$was" ]; then
    printf 'stale'
  else
    printf 'current'
  fi
}

# How many other incomplete plans sit behind each plan in the Deps graph.
# BFS over the reverse-dependency edges; a plan already `complete` is not
# blocked by anything, so it and its own dependents are not counted through it.
#
# Computed once for every plan in the table, not per gate file: this used to
# re-parse the whole registry and re-run its own BFS on every call, and the
# gate loop below calls it once per open gate. On a queue of N gates that was
# N full re-reads of REGISTRY.md rebuilding the identical graph each time.
_blocked_map=""
_blocked_map_built=""
# Built on FIRST USE, not at startup. The dispatcher calls this script once per
# candidate per tick only to ask whether that artifact has a gate open, and
# `wf_gate_file` in the probe below exits before any blocked_by call when it
# has none — so the common answer used to cost a full walk of the registry,
# rebuilding a graph nothing then read.
_ensure_blocked_map() {
  if [ -n "$_blocked_map_built" ]; then return 0; fi
  _blocked_map_built=1
  if [ ! -f "$REGISTRY" ]; then return 0; fi
  _blocked_map=" $(awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    /^\|/ {
      pid = trim($2)
      if (pid == "" || pid == "ID" || pid ~ /^-+$/) next
      ids[++nids] = pid
      state[pid] = trim($4)
      n = split(trim($10), d, ",")
      for (i = 1; i <= n; i++) {
        dep = trim(d[i])
        if (dep != "" && dep != "—") rdeps[dep] = rdeps[dep] "," pid
      }
    }
    END {
      for (j = 1; j <= nids; j++) {
        root = ids[j]
        delete seen
        queue[1] = root; head = 1; tail = 1; count = 0
        while (head <= tail) {
          cur = queue[head++]
          n = split(rdeps[cur], kids, ",")
          for (i = 1; i <= n; i++) {
            k = kids[i]
            if (k == "" || (k in seen) || state[k] == "complete") continue
            seen[k] = 1; count++
            queue[++tail] = k
          }
        }
        printf "%s=%d ", root, count
      }
    }
  ' "$REGISTRY")"
}

blocked_by() {
  _ensure_blocked_map
  local rest="${_blocked_map##* $1=}"
  [ "$rest" = "$_blocked_map" ] && { printf '0'; return 0; }
  printf '%s' "${rest%% *}"
}

# Single-artifact probe
if [ -n "$query" ]; then
  case "$query" in
    RELEASE|DEPLOY) id="$query" ;;
    *) id=$(printf '%s' "$query" | grep -oE "^($LV_WORK_RE)-[0-9]+" || true) ;;
  esac
  [ -n "$id" ] || { echo "Error: '$query' is not a $LV_PLN/$LV_BUG/$LV_BRF id, or RELEASE/DEPLOY" >&2; exit 2; }
  # By NUMBER, not by name: lv-spec opens `spec-approval` on the plan it just
  # wrote, and the dispatcher asks under the brief it dispatched (WFI-187).
  gate_file=$(wf_gate_file "$id") || exit 1
  # shellcheck disable=SC1090
  eval "$(<"$gate_file")"
  gstate=$(state_of "$GATE_ID")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$GATE_ID" "$GATE_NAME" "$GATE_OPENED" "$(flatten "$GATE_QUESTION")" \
    "$(flatten "${GATE_CONTEXT:-—}")" "$(blocked_by "$id")" \
    "$gstate" "$(gate_fit "$GATE_NAME" "$gstate")" \
    "$(question_fit "$GATE_ID" "${GATE_PLAN_BODY_FP_AT_OPEN:-}")"
  exit 0
fi

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

# Warm the map HERE, in this shell. Each iteration below evaluates its gate in
# a subshell, so a first touch from inside one would build the map in that
# subshell and discard it — every gate re-running the identical walk, which is
# the exact cost the map exists to pay once.
_ensure_blocked_map

for gate_file in "$gates_dir"/*.gate; do
  [ -f "$gate_file" ] || continue
  # Gate files are written by wf_emit — every value single-quoted, so this is
  # safe against spaces and shell metacharacters in the question text.
  # Eval in a subshell so one malformed gate can't poison the next.
  (
    # shellcheck disable=SC1090
    eval "$(<"$gate_file")"
    # Blocking count leads, zero-padded, so a plain lexical sort orders by cost
    # first and by opened-timestamp second without a second sort key.
    gstate=$(state_of "$GATE_ID")
    printf '%06d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(blocked_by "$GATE_ID")" "$GATE_OPENED" "$GATE_ID" "$GATE_NAME" \
      "$(flatten "$GATE_QUESTION")" "$(flatten "${GATE_CONTEXT:-—}")" \
      "$gstate" "$(gate_fit "$GATE_NAME" "$gstate")" \
      "$(question_fit "$GATE_ID" "${GATE_PLAN_BODY_FP_AT_OPEN:-}")"
  ) >> "$tmp" 2>/dev/null || true
done

if [ ! -s "$tmp" ]; then
  echo "GATES: 0" >&2
  exit 1
fi

# Costliest first, oldest first within a cost. `sort -r` on the padded count
# reverses the timestamp too, so sort the count descending as its own key and
# leave the ISO-8601 timestamp ascending (lexical = oldest first).
sort -k1,1nr -k2,2 "$tmp" \
  | awk -F'\t' '{ print $3 "\t" $4 "\t" $2 "\t" $5 "\t" $6 "\t" ($1 + 0) "\t" $7 "\t" $8 "\t" $9 }'
# `xargs` is not redundant here: BSD `wc -l < file` pads its count with leading
# spaces, and this line is parsed by callers.
echo "GATES: $(wc -l < "$tmp" | xargs)" >&2
exit 0
