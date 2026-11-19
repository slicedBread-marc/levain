#!/usr/bin/env bash
# lv-orch-lib.sh — shared helpers for the orchestrator. Source it; don't run it.
#
#   source "$(dirname "$0")/lv-orch-lib.sh"
#
# Everything orchestrator-related is anchored to the DEVELOP ROOT, never to the
# current worktree. A worker running in feature/PLN-097-foo must open a gate
# that /lv-attend on develop can see, so gates, events and pidfiles all live
# under <develop-root>/.claude/orchestrator/.
#
# Provides:
#   wf_develop_root                  → absolute path of the first worktree
#   wf_orch_dir                      → <develop-root>/.claude/orchestrator (created)
#   wf_registry_rows [path]          → one trimmed plan row per line (0x1f-separated)
#   wf_registry_field <id> <col>     → one trimmed field of one plan's row
#   wf_state_of <id>                 → one plan's REGISTRY state, PLN-alias aware
#   wf_bug_id <bug.md>               → the bug that file declares itself to be
#   wf_goal_text <plan.md>           → that plan's one-line goal
#   wf_cfg <dotted.path> [default]   → value from levain.yml
#   wf_emit <KEY> <value>            → eval-safe KEY='value' line
#   wf_gate_field <file> <KEY> [--unescape] → one field of a gate file
#   wf_restore_harness               → re-copy the gitignored runtime files after a merge
#   wf_plan_fingerprint <PLN-NNN>    → hash of that plan's plan.md (may be empty)
#   wf_session_pid                   → PID of the long-lived session, not the shell
#   wf_artifacts_with_number <num>   → "<PREFIX> <where>" per artifact using it
#   wf_claim_dir <artifact>          → the directory that holds this artifact's claim
#   wf_claim_write <dir> [pid] [artifact] → write <dir>/.wf-claim
#   wf_proc_start <pid>              → that process's start time, "" if not running
#   wf_claim_live <dir>              → 0 if a live claim holds it; sets LV_CLAIM_AGE
#                                      and LV_CLAIM_OVERDUE
#   wf_claim_mine <dir>              → 0 if that claim is this caller's own
#   wf_claim_held <artifact>         → wf_claim_live against wf_claim_dir + legacy
#   wf_event <type> <artifact> <msg> → append to events.log
#   wf_now                           → ISO-8601 UTC timestamp
#   wf_file_mtime <file>             → mtime as epoch seconds, 0 if unreadable
#   wf_file_size <file>              → size in bytes, 0 if unreadable
#   wf_human_age <seconds>           → that duration as 45s / 12m / 3h20m / 6d
#   wf_worktree_for_branch <branch>  → the worktree holding it, empty if none
#   wf_registry_set_field <id> <col> <value> [reg] → write one column of one row
#   wf_plan_id_for_num <num>         → the plan ID that number has or will have
#
# It also loads the artifact ID prefix map (lv-ids.sh): LV_PLN, LV_PLN_RE,
# LV_WORK_RE and the rest. Match IDs with those, never with a literal PLN.

# ── Paths ─────────────────────────────────────────────────────────────────

#
# Answered once per process. Three forks each time is nothing on its own, and
# this is called from wf_orch_dir, wf_cfg and wf_claim_* — so a single list
# render pays it per plan, per claim check, per config read. The root cannot
# change inside one process (a script that cd's is still in the same repo), so
# the second answer is always the first one. Deliberately NOT exported: a child
# may be running against a different repository.
_WF_DEVELOP_ROOT=""
wf_develop_root() {
  if [ -n "$_WF_DEVELOP_ROOT" ]; then printf '%s' "$_WF_DEVELOP_ROOT"; return 0; fi
  # The first worktree git reports is always the main one (where develop lives).
  local root
  root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || root=""
  # Not a worktree setup — fall back to the repo toplevel, then CWD.
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$root" ] || root="$PWD"
  _WF_DEVELOP_ROOT="$root"
  printf '%s' "$root"
}

# The ID prefix map, read from the develop root's levain.yml — loaded
# here, once wf_develop_root exists, so the map reuses its cached answer.
# shellcheck source=lv-ids.sh
source "$(dirname "${BASH_SOURCE[0]}")/lv-ids.sh"

_WF_ORCH_DIR_MADE=""
wf_orch_dir() {
  local d="$(wf_develop_root)/.claude/orchestrator"
  # pending/: spawns deferred behind the requester's own claim, served by
  # lv-unclaim.sh when it comes down (WFI-086, WFI-091).
  # claims/:  one directory per artifact NUMBER, holding its .wf-claim (WFI-004).
  # Made once per process for the same reason the root is resolved once.
  if [ "$_WF_ORCH_DIR_MADE" != "$d" ]; then
    mkdir -p "$d/gates" "$d/logs" "$d/pending" "$d/claims"
    _WF_ORCH_DIR_MADE="$d"
  fi
  printf '%s' "$d"
}

# ── Registry ──────────────────────────────────────────────────────────────

# wf_registry_rows [registry-path]
# One plan per line, already trimmed, fields separated by US (0x1f):
#   <id> <slug> <state> <priority> <branch> <updated> <wf> <tags> <deps>
#
# NOT tab-separated, and that is not cosmetic. Tab is IFS *whitespace*, so
# `IFS=$'\t' read` collapses a run of tabs into one delimiter — an empty column
# silently shifts every field after it into the wrong variable. Legacy 7-column
# rows have exactly that shape, and they read fine until the day a plan's Tags
# are empty. 0x1f is not whitespace, so each separator delimits one field and
# empty stays empty.
#
# Every list script used to walk the table itself: `grep "^|" | tail -n +3`
# piped into `IFS='|' read`, then three to five `$(echo "$x" | xargs)` calls to
# trim the fields — two forks each, paid on EVERY row before the state filter
# rejects it. On a 70-row registry that is ~0.9s per script, and /lv-tray
# runs eight of them. One awk pass is 0.006s.
#
# It also fixes the fragility that came with positional reads: `IFS='|' read -r
# _ id slug state priority branch _rest` names its columns by position in
# twelve places, so a new registry column silently shifts all twelve. Here it
# shifts one function.
wf_registry_rows() {
  local reg="${1:-$(wf_develop_root)/plans/REGISTRY.md}"
  [ -f "$reg" ] || return 0
  awk -F'|' -v plan_re="^($LV_PLN_RE)-[0-9]+$" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { US = sprintf("%c", 31) }
    {
      id = trim($2)
      if (id !~ plan_re) next                 # header, separator, counter comment
      printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n",
        id, US, trim($3), US, trim($4), US, trim($5), US, trim($6), US,
        trim($7), US, trim($8), US, trim($9), US, trim($10)
    }
  ' "$reg"
}

# wf_registry_field <id> <column> [registry-path]
# One column of one plan's row, trimmed. Empty when the id or the row isn't
# found. Column names: slug state priority branch updated wf tags deps.
#
# wf_registry_rows solved "every row" once so scripts stopped re-walking the
# table themselves; this is that same fix for "one field of one row" — the
# `grep "^| $id |" REGISTRY | head -1 | awk -F'|' '{print $N}' | xargs` idiom
# was hand-rolled at some two dozen call sites, each naming its column by a
# raw field NUMBER, so a registry schema change means auditing every one of
# them by hand instead of updating the index map below once.
wf_registry_field() {
  local id="$1" col="$2" reg="${3:-$(wf_develop_root)/plans/REGISTRY.md}"
  [ -f "$reg" ] || return 0
  awk -F'|' -v id="$id" -v col="$col" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN {
      idx["slug"]=3; idx["state"]=4; idx["priority"]=5; idx["branch"]=6
      idx["updated"]=7; idx["wf"]=8; idx["tags"]=9; idx["deps"]=10
    }
    trim($2) == id { print trim($(idx[col])); exit }
  ' "$reg"
}

# wf_plan_id_for_num <num> — the plan a number names: its registry row or
# folder under whichever plan prefix it was issued with, else the ID it will get
# (the prefix the map issues today). A bug or brief inherits its number when
# specced, so this is how a caller holding BUG-094 names the plan it becomes.
wf_plan_id_for_num() {
  local num="$1" root p d
  root="$(wf_develop_root)"
  for p in $LV_PLN_ALL; do
    if grep -qE "^\| $p-$num \|" "$root/plans/REGISTRY.md" 2>/dev/null; then
      printf '%s' "$p-$num"; return 0
    fi
    for d in "$root/plans/$p-$num"-*/; do
      [ -d "$d" ] && { printf '%s' "$p-$num"; return 0; }
    done
  done
  printf '%s' "$LV_PLN-$num"
}

# wf_registry_set_field <id> <column> <value> [registry-path]
#
# The write half of wf_registry_field, sharing its column-name → index map.
# Four scripts each carried their own awk-to-tmp copy naming the column by raw
# field NUMBER ($5, $9, $10), so the schema change the map exists to absorb
# would have had to be chased through every writer by hand — the very audit
# wf_registry_field was introduced to end, left half-done on the write side.
#
# A pre-v5 row has no Tags or Deps column (10 fields, so NF < 11 with the
# leading and trailing empties). Writing either one to such a row APPENDS
# both — the named column set, the other left `—` — so the table stays
# rectangular. That upgrade was duplicated too, once per column, each copy
# spelling the same append differently.
wf_registry_set_field() {
  local id="$1" col="$2" val="$3" reg="${4:-$(wf_develop_root)/plans/REGISTRY.md}"
  [ -f "$reg" ] || return 1
  awk -F'|' -v OFS='|' -v id="$id" -v col="$col" -v val="$val" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN {
      idx["slug"]=3; idx["state"]=4; idx["priority"]=5; idx["branch"]=6
      idx["updated"]=7; idx["wf"]=8; idx["tags"]=9; idx["deps"]=10
    }
    # Exact ID match: `$2 ~ id` also matches PLN-041 when asked for PLN-04.
    trim($2) == id {
      if (NF < 11 && (col == "tags" || col == "deps")) {
        sub(/[ \t]*$/, "", $0)
        if (col == "tags") print $0 " " val " | — |"
        else               print $0 " — | " val " |"
        next
      }
      $(idx[col]) = " " val " "
    }
    { print }
  ' "$reg" > "$reg.tmp" && mv "$reg.tmp" "$reg"
}

# wf_state_of <id> [registry-path] → the artifact's REGISTRY state, or `—`
# when it has no row yet (a bug or brief on its way to a first spec — a
# legitimate lookup target, not an error).
#
# A bug or brief keeps its number when it becomes a plan (BUG-022 → PLN-022),
# and a caller may be holding the earlier name — a gate opened under BUG-022
# is still open once the row is PLN-022. The PLN-<num> alias is checked as a
# fallback for exactly that.
#
# Memoized per (process, registry-path) like wf_develop_root: this is called
# once per artifact on every board render and, from the dispatcher, twice
# more per candidate, and re-parsing REGISTRY.md on every call was measurable
# on a 70-row table. Three call sites each carried their own copy of this
# map before this existed; only one had the PLN-alias fallback, so the other
# two silently read state `—` for a renamed artifact.
_WF_STATE_MAP=""
_WF_STATE_MAP_REG=""
wf_state_of() {
  local id="$1" reg="${2:-$(wf_develop_root)/plans/REGISTRY.md}" s alt p
  if [ "$_WF_STATE_MAP_REG" != "$reg" ]; then
    _WF_STATE_MAP=""
    if [ -f "$reg" ]; then
      _WF_STATE_MAP=" $(awk -F'|' -v work_re="^($LV_WORK_RE)-[0-9]+$" '
        function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
        { i = trim($2); if (i ~ work_re) printf "%s=%s ", i, trim($4) }
      ' "$reg")"
    fi
    _WF_STATE_MAP_REG="$reg"
  fi
  [ -n "$_WF_STATE_MAP" ] || { printf '—'; return 0; }
  s="${_WF_STATE_MAP##* $id=}"
  [ "$s" != "$_WF_STATE_MAP" ] || s=""
  s="${s%% *}"
  if [ -z "$s" ]; then
    for p in $LV_PLN_ALL; do
      alt="${_WF_STATE_MAP##* $p-${id#*-}=}"
      [ "$alt" = "$_WF_STATE_MAP" ] || { s="${alt%% *}"; break; }
    done
  fi
  printf '%s' "${s:-—}"
}

# wf_blocking_deps <deps-column> [registry-path] → the comma-separated deps
# that are NOT complete, or empty when nothing blocks. Exit 0 when it printed
# something, 1 when the plan is clear — so a caller reads as
# `blocking=$(wf_blocking_deps "$deps") && { ...blocked... }`.
#
# An abandoned dep is labelled `<id> (abandoned)` in the output, because it is
# not late, it is gone, and the plan needs replanning rather than patience
# (WFI-008). That label is the whole reason this cannot be a plain state test:
# it was written once in lv-list-implementable.sh, pasted into
# lv-list-testable.sh, and the two are the same eligibility question asked at
# two pipeline stages — a third stage asking it would have pasted it again.
# wf_dep_project_path <name> → the local checkout path for a dependency
# declared in this project's `dependencies:`, or empty. Same join-on-first-colon
# parse lv-dep-bug.sh uses; factored out once a second caller needed it.
wf_dep_project_path() {
  local want="$1" entry
  local IFS=$' \t\n'   # a caller may be mid-`IFS=,` split of a Deps column
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "${entry%%:*}" = "$want" ] || continue
    printf '%s' "${entry#*:}"
    return 0
  done < <(wf_cfg_list dependencies)
  return 1
}

# wf_external_dep_state <project>:<ARTIFACT-ID>
#
# Sets two globals and prints NOTHING:
#   LV_EXTERNAL_DEP_STATE   complete | pending | unknown
#   LV_EXTERNAL_DEP_DETAIL  a phrase for a human — `PLN-009 testing`,
#                           `abandoned`, `no 'client-d' in dependencies:`
#
# Two returns, so no `$( )`. A subshell would take the detail with it, and the
# detail is half the answer: `BLOCKED client-d:BRF-009` with no reason is the
# dead-end client-b was already in.
#
# A plan can be blocked on work in ANOTHER repo, and until this existed there
# was nowhere to say so. client-b WFI-015: PLN-011 was blocked on client-d's
# BRF-009 / BUG-011. `lv-set-deps.sh` took plan IDs only; `lv-list-tags.sh
# --gating` offered `security`, which would have been a false label; so the one
# thing actually keeping the daemon off the plan was a `lv-claim.sh` lease —
# documented as stealable by any session that judges it stale. The plan sat in
# `draft`, a dispatchable state, with a live daemon that would have replanned it
# against copper tokens that do not exist yet.
#
# The answer is checkable rather than declarative, which is the point: a
# permanently-unmet marker would have to be cleared by hand, and a dependency
# nobody clears is the same stall in a different column. `dependencies:` already
# names a local checkout of the other project, so the other project's own
# registry and closed-bugs folder answer the question directly, and the block
# lifts by itself when the work lands there.
#
# Identity is the NUMBER, per the artifact ID system: BRF-009 becomes PLN-009
# becomes a closed BUG-009. So all three are asked about together, and any one
# of them being finished satisfies the dependency.
#
# `unknown` — no such dependency declared, no local checkout, no registry there
# — is BLOCKING, deliberately. An unresolvable dependency is not a satisfied
# one, and reporting it clear would dispatch exactly the plan the operator
# parked.
#
# `abandoned` comes back as `complete` with the detail `abandoned`. It is the
# one answer patience cannot fix — the dependent needs replanning (WFI-008) —
# so the caller labels it and a human reads it, rather than waiting forever.
LV_EXTERNAL_DEP_STATE=""
LV_EXTERNAL_DEP_DETAIL=""
wf_external_dep_state() {
  local ref="$1" proj num path reg state padded row p their
  local IFS=$' \t\n'   # a caller may be mid-`IFS=,` split of a Deps column
  LV_EXTERNAL_DEP_STATE="unknown"
  LV_EXTERNAL_DEP_DETAIL=""
  proj="${ref%%:*}"
  num=$(printf '%s' "${ref#*:}" | grep -oE '[0-9]+$' || true)
  if [ -z "$proj" ] || [ -z "$num" ]; then
    LV_EXTERNAL_DEP_DETAIL="unparseable"; return 0
  fi
  num=$((10#$num))
  padded=$(printf '%03d' "$num")
  if ! path=$(wf_dep_project_path "$proj"); then
    LV_EXTERNAL_DEP_DETAIL="no '$proj' in dependencies:"; return 0
  fi
  if [ ! -d "$path" ]; then
    LV_EXTERNAL_DEP_DETAIL="$path is not a directory"; return 0
  fi
  reg="$path/plans/REGISTRY.md"
  # The other project names its IDs by its OWN map, so ask it, not ours.
  their=$( cd "$path" 2>/dev/null && bash "$(dirname "${BASH_SOURCE[0]}")/lv-ids.sh" prefixes plan ) || their="PLN"
  # A bug ref is answered by the bug, never by the plan that shares its number:
  # BUG-085's state is not PLN-085's (a client's LVI-036).
  local kind bugp
  kind=$(printf '%s' "${ref#*:}" | sed -E 's/-?[0-9]+$//')
  bugp=$( cd "$path" 2>/dev/null && bash "$(dirname "${BASH_SOURCE[0]}")/lv-ids.sh" prefixes bug ) || bugp="BUG"
  case " $bugp " in *" $kind "*) reg="" ;; esac
  if [ -n "$reg" ] && [ -f "$reg" ]; then
    for p in $their; do
      row="$p-$padded"
      state=$(wf_registry_field "$row" state "$reg" 2>/dev/null || true)
      [ -n "$state" ] && break
    done
    case "$state" in
      complete)
        LV_EXTERNAL_DEP_STATE="complete"; LV_EXTERNAL_DEP_DETAIL="$row complete"; return 0 ;;
      abandoned)
        LV_EXTERNAL_DEP_STATE="complete"; LV_EXTERNAL_DEP_DETAIL="abandoned"; return 0 ;;
      ?*)
        LV_EXTERNAL_DEP_STATE="pending"; LV_EXTERNAL_DEP_DETAIL="$row $state"; return 0 ;;
    esac
  fi
  for p in $bugp; do
    # A bug is a folder (bugs/closed/BUG-085-slug/bug.md) or, in older
    # projects, a file — so no .md on the glob.
    if ls -d "$path"/bugs/closed/"$p"-"$padded"-* >/dev/null 2>&1; then
      LV_EXTERNAL_DEP_STATE="complete"; LV_EXTERNAL_DEP_DETAIL="$p-$padded closed"; return 0
    fi
  done
  if [ -z "$reg" ]; then
    LV_EXTERNAL_DEP_STATE="pending"; LV_EXTERNAL_DEP_DETAIL="${ref#*:} not closed in $proj"; return 0
  fi
  if [ ! -f "$reg" ]; then
    LV_EXTERNAL_DEP_DETAIL="no registry at $path"; return 0
  fi
  LV_EXTERNAL_DEP_STATE="pending"; LV_EXTERNAL_DEP_DETAIL="not started in $proj"
}

# wf_is_external_dep <token> → 0 when it names another project's artifact.
# `client-d:BRF-009`, never a bare `PLN-004`.
wf_is_external_dep() {
  case "$1" in
    *:*) return 0 ;;
    *)   return 1 ;;
  esac
}

wf_blocking_deps() {
  local deps_raw="$1" reg="${2:-}" blocking="" dep_id dep_state
  [ -n "$deps_raw" ] && [ "$deps_raw" != "—" ] || return 1
  local IFS=','
  for dep_id in $deps_raw; do
    dep_id="${dep_id#"${dep_id%%[![:space:]]*}"}"   # trim, without a subprocess
    dep_id="${dep_id%"${dep_id##*[![:space:]]}"}"
    [ -n "$dep_id" ] || continue
    if wf_is_external_dep "$dep_id"; then
      # Another project's artifact (client-b WFI-015). Resolved through that
      # project's own registry, so the block lifts when the work lands there.
      wf_external_dep_state "$dep_id"
      # An `if`, not a `&&` chain: a false test as a standalone list is a
      # `set -e` exit, and every caller here runs under it.
      if [ "$LV_EXTERNAL_DEP_STATE" != "complete" ] || [ "$LV_EXTERNAL_DEP_DETAIL" = "abandoned" ]; then
        blocking="${blocking:+$blocking,}$dep_id ($LV_EXTERNAL_DEP_DETAIL)"
      fi
      continue
    fi
    dep_state=$(wf_state_of "$dep_id" ${reg:+"$reg"})
    [ "$dep_state" = "complete" ] && continue
    # A bug named before it had a plan (lv-set-deps.sh, LVI-022) may be closed
    # without ever getting one. It has no row to read, so ask bugs/closed/.
    if [ "$dep_state" = "—" ]; then
      local _root
      _root=$(dirname "$(dirname "${reg:-$(wf_develop_root)/plans/REGISTRY.md}")")
      if compgen -G "$_root/bugs/closed/$dep_id-*" >/dev/null || [ -e "$_root/bugs/closed/$dep_id" ]; then
        continue
      fi
    fi
    [ "$dep_state" = "abandoned" ] && dep_id="$dep_id (abandoned)"
    blocking="${blocking:+$blocking,}$dep_id"
  done
  [ -n "$blocking" ] || return 1
  printf '%s' "$blocking"
}

# ── Artifacts ─────────────────────────────────────────────────────────────

# wf_bug_id <path/to/bug.md> — which bug that file IS. Empty when undecidable.
#
# A bug declares its identity in one place: the `> **ID:** BUG-NNN` header field
# lv-bug-new.sh writes. Every other BUG-NNN token in the file is a bug it TALKS
# ABOUT — a title, a Links line, a Description citing the report it follows on
# from.
#
# lv-list-specable.sh and lv-list-bugs.sh both used to take the first BUG-NNN
# token anywhere in the file (`grep -oE 'BUG-[0-9]+' | head -1`), and the title
# is three lines above the ID field. client-a's BUG-141 is titled "BUG-131's
# console encoding fix lives in the wrapper script…", so it was listed, claimed
# and dispatched as BUG-131 — a bug closed the day before, with no REGISTRY row.
# The orchestrator drew its spec candidates from that list and spawned a worker
# at the closed bug on every sweep (WFI-170, WFI-171), while BUG-141 itself —
# open, unplanned, real — appeared in no list and could never be specced
# (WFI-173, corrected by WFI-176). Any bug that cites another before declaring
# its own number hits this, and citing one is the normal way to file a
# follow-up.
#
# The folder name is the fallback, not the source: WFI-173 first blamed it, and
# renaming the folder changed nothing, which is what disproved the theory. It is
# still the better guess than a body token when the field is missing, because
# lv-bug-new.sh creates `bugs/<stage>/BUG-NNN-<slug>/` and nothing else does.
#
# A disagreement between the two is reported and the declared field wins: the
# field is what lv-bug-consume.sh and lv-bug-close.sh rewrite, so a folder that
# has drifted from it is a rename nobody finished.
wf_bug_id() {
  local bug_md="$1" declared folder
  [ -f "$bug_md" ] || return 0
  declared=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*ID:\*\*' "$bug_md" 2>/dev/null \
             | grep -oE "($LV_BUG_RE)-[0-9]+" | head -1 || true)
  folder=$(basename "$(dirname "$bug_md")" | grep -oE "^($LV_BUG_RE)-[0-9]+" || true)
  if [ -n "$declared" ] && [ -n "$folder" ] && [ "$declared" != "$folder" ]; then
    echo "wf_bug_id: $bug_md declares $declared but sits in $folder/ — using $declared" >&2
  fi
  printf '%s' "${declared:-$folder}"
}

# ── Intake groups and amendment pairs (LVI-024) ───────────────────────────
#
# Bugs filed as one batch by one conversation, some correcting others, are not
# independent work: a spec worker that takes one without the rest specs a
# premise the next one reverses. A client had BUG-041..049 filed inside a few
# hours, BUG-046 reversing the premise of 041 and 043, and 041 had already
# become an active plan built on the superseded model before the corrections
# landed. The operator had to stop the whole daemon to hold the rest.
#
# A group is bugs/groups/<slug>.md (lv-bug-group.sh writes it); each member
# carries `> **Group:** <slug>` in its header. lv-list-specable.sh reads both:
# an Open group's members are not offered, a Sealed group offers its lead with
# the rest carried. See docs/intake-groups.md.

# wf_bug_field <bug.md> <Field> → a header field's value, trimmed; empty when
# the field is absent or holds a placeholder like `_(none)_` or `—`.
wf_bug_field() {
  local v
  v=$(grep -m1 -E "^[ \t]*>?[ \t]*\*\*$2:\*\*" "$1" 2>/dev/null \
      | sed -E "s/^.*\*\*$2:\*\*[[:space:]]*//; s/[[:space:]]*\$//" || true)
  case "$v" in ""|"("*|*"(none"*|*_none_*|"—"|"-") return 0 ;; esac
  printf '%s' "$v"
}

# wf_bug_md <BUG-ID> → "<stage>\t<path to bug.md>" for open|triaged|closed, or
# nothing. Matches the folder number, then confirms the declared ID.
wf_bug_md() {
  local id="$1" root stage d
  root="$(wf_develop_root)"
  for stage in open triaged closed; do
    for d in "$root"/bugs/$stage/"$id"-*/ "$root"/bugs/$stage/"$id"/; do
      [ -f "$d/bug.md" ] || continue
      [ "$(wf_bug_id "$d/bug.md" 2>/dev/null)" = "$id" ] || continue
      printf '%s\t%s' "$stage" "${d%/}/bug.md"; return 0
    done
  done
}

# wf_bug_amends <bug.md> → the IDs its Links field says it amends, one per
# line ("Amends BUG-041"; "Amended by" is the other direction and not read).
wf_bug_amends() {
  wf_bug_field "$1" Links | grep -oE "Amends[[:space:]]+($LV_BUG_RE)-[0-9]+" \
    | grep -oE "($LV_BUG_RE)-[0-9]+" || true
}

# wf_brief_blocked <brief.md|bug.md> → the recorded reason it is blocked, exit 0;
# exit 1 when it is not. lv-brief-block.sh writes and clears the field.
wf_brief_blocked() {
  local brief_md="$1" field
  # `Blocked by:` is read too. lv-brief-block.sh writes `Blocked:`, but a brief
  # written by hand reaches for the natural phrase — and a client's BRF-008,
  # headed "Blocked by: ... Do not spec until it is met", was dispatched to an
  # unattended spec worker because only the tool's spelling counted (LVI-013).
  field=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Blocked( [Bb]y)?:\*\*' "$brief_md" 2>/dev/null \
          | sed -E 's/^.*\*\*Blocked( [Bb]y)?:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)
  # A parenthesised value is template prose, not a blocker — the same defence
  # the Plan: field needs, and for the same reason: a placeholder that reads as
  # a real value hides work instead of describing it.
  case "$field" in
    ""|"("*|*"(none"*|*_none_*|"—") return 1 ;;
  esac
  # A block on another project's artifact, as lv-brief-block.sh --repo writes
  # it ("BUG-085 (in proj) — why"), lifts when that artifact lands there. It
  # was never re-checked: lv-check-deps.sh printed CLEAR while the bug sat off
  # the specable list until someone ran --clear by hand (a client's LVI-036).
  # Only a state read as complete lifts it; unknown or abandoned still holds.
  local art proj
  if [[ "$field" =~ ^([A-Z]+-[0-9]+)\ \(in\ ([A-Za-z0-9._/-]+)\) ]]; then
    art="${BASH_REMATCH[1]}"; proj="${BASH_REMATCH[2]}"
    wf_external_dep_state "$proj:$art"
    if [ "$LV_EXTERNAL_DEP_STATE" = "complete" ] && [ "$LV_EXTERNAL_DEP_DETAIL" != "abandoned" ]; then
      return 1
    fi
    # A blocker this cannot read can never lift by itself, and said nothing
    # about it: a client's BUG-096 named a project its levain.yml did not
    # declare under dependencies:, so the state read `unknown` on every sweep
    # and the bug sat withheld for 33 days after the blocker closed (a
    # client's LVI-055). Still held — unknown is not complete — but the
    # reason now says why it is not re-checked and what would make it so.
    if [ "$LV_EXTERNAL_DEP_STATE" = "unknown" ]; then
      field="$field [not re-checked: $LV_EXTERNAL_DEP_DETAIL — declare $proj under dependencies: in levain.yml, or --clear by hand]"
    fi
  fi
  # A block on a plan in THIS repo, as `lv-brief-block.sh --on PLN-126` writes
  # it ("PLN-126 — why"), lifts the same way once that plan is complete here.
  # Only the cross-repo form was re-checked, so a same-repo block stayed until
  # someone ran --clear by hand (a client's LVI-058). Abandoned or any other
  # state still holds.
  if [[ "$field" =~ ^(($LV_PLN_RE)-[0-9]+)([[:space:]]|$) ]]; then
    art="${BASH_REMATCH[1]}"
    case "$field" in
      "$art (in "*) ;;   # cross-repo, answered above
      *) [ "$(wf_registry_field "$art" state)" = "complete" ] && return 1 ;;
    esac
  fi
  printf '%s' "$field"; return 0
}

# wf_bug_chain_block <bug-id> → "<id>\t<reason>" for the first OPEN bug further
# along its Amends chain that is blocked; nothing when none is. The chain is
# what lv-list-specable.sh carries an amender with, so a block anywhere along
# it holds the amender too — and only this says so (LVI-027).
wf_bug_chain_block() {
  local cur="$1" seen=" $1 " t loc md why nxt
  while :; do
    nxt=""
    for t in $(loc=$(wf_bug_md "$cur"); [ -n "$loc" ] && wf_bug_amends "${loc#*$'\t'}"); do
      [[ "$seen" == *" $t "* ]] && continue
      loc=$(wf_bug_md "$t"); [ -n "$loc" ] || continue
      [ "${loc%%$'\t'*}" = "open" ] || continue
      md="${loc#*$'\t'}"
      if why=$(wf_brief_blocked "$md"); then
        printf '%s\t%s' "$t" "$why"; return 0
      fi
      nxt="$t"; break
    done
    [ -n "$nxt" ] || return 0
    seen+="$nxt "; cur="$nxt"
  done
}

wf_group_file() { printf '%s/bugs/groups/%s.md' "$(wf_develop_root)" "$1"; }

# wf_group_field <slug> <Field> → a group header field, or empty.
wf_group_field() {
  local f; f="$(wf_group_file "$1")"
  [ -f "$f" ] || return 0
  wf_bug_field "$f" "$2"
}

# wf_group_members <slug> → member IDs, one per line, in the order added.
wf_group_members() {
  local f; f="$(wf_group_file "$1")"
  [ -f "$f" ] || return 0
  awk -v re="^- ($LV_BUG_RE)-[0-9]+" '/^## Members/{m=1;next} /^## /{m=0} m && $0 ~ re { sub(/^- /,""); sub(/[ \t].*/,""); print }' "$f"
}

# wf_group_left <slug> → "<BUG-ID>\t<PLN-ID>" per member the lead's spec run
# left for its own plan (`lv-bug-group.sh leave`), read from the group's
# `## Left for their own plans` section. Such a member does not hold the group
# open, and is not consumed into the plan it was left after (a client's
# LVI-005).
wf_group_left() {
  local f; f="$(wf_group_file "$1")"
  [ -f "$f" ] || return 0
  awk -v re="^- ($LV_BUG_RE)-[0-9]+ after ($LV_PLN_RE)-[0-9]+" '
    /^## Left for their own plans/{m=1;next} /^## /{m=0}
    m && $0 ~ re { sub(/^- /,""); split($0, w, /[ \t]+/); print w[1] "\t" w[3] }' "$f"
}

# wf_group_left_after <BUG-ID> → the plan the bug was left after, if its group
# records it as left for its own plan; empty otherwise.
wf_group_left_after() {
  local loc g
  loc=$(wf_bug_md "$1"); [ -n "$loc" ] || return 0
  g=$(wf_bug_field "${loc#*$'\t'}" Group); [ -n "$g" ] || return 0
  wf_group_left "$g" | awk -F'\t' -v b="$1" '$1 == b { print $2; exit }'
}

# wf_group_lead_in_spec <lead BUG-ID> — 0 when the lead is still open, or a
# spec run on it is in flight: its claim is held AND no plan of its number has
# got past draft. Claims key on the number, so the claim a tester holds on the
# lead's PLN-027 in `testing` is not a spec run — and reading it as one
# withheld a member left for its own plan for exactly as long as the test ran:
# lv-plan-id.sh said go at one step and stop at the next (a client's LVI-005).
wf_group_lead_in_spec() {
  local loc lp st
  loc=$(wf_bug_md "$1")
  [ "${loc%%$'\t'*}" = "open" ] && return 0
  wf_claim_held "$1" || return 1
  # The plan the lead was triaged into, else the one its number inherits.
  lp=$(wf_bug_field "${loc#*$'\t'}" Plan 2>/dev/null | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
  [ -n "$lp" ] || lp=$(wf_plan_id_for_num "${1##*-}")
  st=$( [ -n "$lp" ] && wf_state_of "$lp")
  case "$st" in ""|draft) return 0 ;; esac
  return 1
}

# wf_group_withholds <BUG-ID> — 0, with the reason on stdout, when the bug's
# intake group says it is not to be specced on its own right now: the group is
# Open, or Sealed under another lead still open or being specced. The rule
# lv-list-specable.sh applies when it offers work, asked again at the moment a
# spec run is about to write.
#
# The list is read once, at dispatch. A client's LVI-026: the daemon spawned a
# spec worker on BUG-053 at 00:47:24Z, a coordinator put BUG-053 in an Open
# group 48 seconds later, and the worker drafted and triaged PLN-053 at
# 00:52 — nothing it ran after dispatch read the Group field.
wf_group_withholds() {
  local loc g lead lplan
  loc=$(wf_bug_md "$1"); [ -n "$loc" ] || return 1
  [ "${loc%%$'\t'*}" = "open" ] || return 1
  g=$(wf_bug_field "${loc#*$'\t'}" Group); [ -n "$g" ] || return 1
  case "$(wf_group_field "$g" Status)" in
    Open)
      printf 'in intake group %s, still Open — its members wait for: lv-bug-group.sh seal %s' "$g" "$g"
      return 0 ;;
    Sealed)
      lead=$(wf_group_field "$g" Lead)
      [ -n "$lead" ] && [ "$lead" != "$1" ] || return 1
      lplan=$(wf_group_field "$g" "Lead plan" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
      case "$( [ -n "$lplan" ] && wf_state_of "$lplan")" in
        draft|ready)
          printf 'an amendment to %s, the lead plan of sealed intake group %s (step 2b), not a plan of its own' "$lplan" "$g"
          return 0 ;;
      esac
      if wf_group_lead_in_spec "$lead"; then
        printf 'carried with %s, the lead of sealed intake group %s' "$lead" "$g"
        return 0
      fi ;;
  esac
  return 1
}

# wf_goal_text <plan.md> — the plan's one-line goal, empty if it has none.
#
# The same awk one-liner was pasted into ten scripts, and had already drifted in
# an eleventh. It is the line every menu, board and PR description shows.
wf_goal_text() {
  [ -f "$1" ] || return 0
  awk '/^## Goal([ \t]|$)/{g=1;next} g&&/^#/{exit} g&&NF{sub(/^[[:space:]]+/,"");print;exit}' "$1" 2>/dev/null || true
}

# wf_step_counts <progress.md> — "<checked>/<total>" for the `## Steps` list.
#
# ONE definition of "how far along is this plan", because there were three and
# they disagreed. lv-progress-count.sh counts only inside `## Steps`; the board
# (lv-list-active.sh) and lv-rehydrate.sh each open-coded a whole-file
# `grep -cE '^- \[[ x]\]'`, so every bracketed line in the Log section inflated
# the total. The same plan therefore read as "Step 3/11" to the orchestrator's
# progress check and "Step 3/17" on the board.
wf_step_counts() {
  [ -f "$1" ] || { printf '0/0'; return 0; }
  awk '
    /^## Steps/ { in_steps = 1; next }
    /^## /      { in_steps = 0 }
    !in_steps   { next }
    /^[[:space:]]*-[[:space:]]*\[[xX]\]/         { checked++; total++; next }
    /^[[:space:]]*-[[:space:]]*\[[[:space:]]*\]/ { total++ }
    END { printf "%d/%d", checked + 0, total + 0 }
  ' "$1"
}

# wf_escalated_count <findings.md> — how many UNCHECKED items mention
# ESCALATED. Display-only (worklist counts in lv-list-specable.sh,
# lv-list-verify.sh, lv-list-replanning.sh) — NOT the routing test. A finding
# is free to write the word either as a leading label (`- [ ] ESCALATED:
# ...`, the older convention these lists were built and tested against) or as
# schema.md's trailing tag (`- [ ] ... ← ESCALATED`); either marks it here.
# wf_tagged() in lv-findings-route.sh is the stricter, trailing-tag-only test
# that actually decides whether a plan routes to draft — that one has to
# reject a bare mention, because a finding's prose is allowed to explain why
# a tag does NOT apply. This one only has to stop counting text that was
# never a finding at all.
#
# `grep -c ESCALATED` — the plain substring count three callers each
# open-coded — counted the word anywhere in the file: the schema-convention
# note in the findings.md header, an already-checked ("- [x]") item's own
# hint text. A plan with one live escalation read as "4 escalated
# finding(s)" (WFI-026). Scoped to unchecked checkbox lines only.
# wf_findings_flat <findings.md> — each finding as ONE line, on stdout.
#
# Markdown does not promise that a list item is one line. A block opens at a
# column-0 `- [ ]` / `- [x]` and closes at the next such line, at a heading,
# at a blank line, or at EOF; continuations are appended with a single space.
# An INDENTED checkbox never opens a block — every tag test anchors at `^`,
# and folding a nested item into its parent would push the parent's trailing
# tag off the end of the line and un-tag a finding that was tagged. Closing on
# a blank line is deliberate too: keeping the block open across one folded a
# plain narrative sentence written after the last finding into that finding,
# un-tagging it the same way (client-f WFI-001).
#
# This lived only in lv-findings-route.sh, which is why the ROUTING test read
# wrapped findings correctly while every DISPLAY count did not.
# wf_escalated_count matched `^- \[ \].*ESCALATED` against physical lines, so
# a finding hard-wrapped with its `← ESCALATED` tag on a continuation line
# counted zero. In lv-list-specable.sh that is not a wrong number on a menu:
# an escalated draft with a zero count also scores zero behavior findings, so
# `parts[]` comes up empty and the entry is `continue`d past WITHOUT falling
# through to the unreviewed branch — the plan disappears from the spec role
# entirely while still holding unchecked findings, and a plan can only leave
# `draft` through a spec run (client-d WFI-031).
wf_findings_flat() {
  [ -f "$1" ] || return 0
  awk '
    function flush() { if (open) { print buf; open = 0; buf = "" } }
    /^[[:space:]]*-[[:space:]]*\[[ xX]\]/ {
      flush()
      if ($0 ~ /^- \[[ xX]\]/) { buf = $0; open = 1 }
      next
    }
    /^[[:space:]]*#{1,6}[[:space:]]/ { flush(); next }
    /^[[:space:]]*$/ { flush(); next }
    {
      if (!open) next
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (line != "") buf = buf " " line
    }
    END { flush() }
  ' "$1" 2>/dev/null || true
}

wf_escalated_count() {
  [ -f "$1" ] || { printf '0'; return 0; }
  wf_findings_flat "$1" | grep -cE '^- \[ \].*ESCALATED' || true
}

# wf_unchecked_count <findings.md> — how many UNCHECKED findings there are at
# all, wrapped or not. The denominator lv-list-specable.sh needs: a draft with
# unchecked findings that match no display category is still replanning work,
# and must never be silently dropped from the worklist.
wf_unchecked_count() {
  [ -f "$1" ] || { printf '0'; return 0; }
  wf_findings_flat "$1" | grep -cE '^- \[ \]' || true
}

# wf_behavior_count <findings.md> — unchecked findings mentioning Behavior.
# Scoped to unchecked checkbox lines for the same reason as ESCALATED
# (WFI-026): a bare `grep -c Behavior` counted the findings.md header's own
# schema note and every already-checked item's hint text.
wf_behavior_count() {
  [ -f "$1" ] || { printf '0'; return 0; }
  wf_findings_flat "$1" | grep -cE '^- \[ \].*Behavior' || true
}

wf_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Times a person reads (LVI-037) ──────────────────────────────────────────
#
# Stored and compared stamps stay UTC: wf_now, status files, ledgers, epochs.
# What changes is what a person reads, and the "today" that a person's own
# dates (live_from, an autonomy date, a lane declaration) are compared with.
# A UTC date rolls over at 20:00 EDT, so those dates flipped four hours early.
#
# wf_tz — the zone to show times in: LV_TZ, else levain.yml display.timezone
# (an IANA name such as America/Toronto, so DST is right), else empty, which
# means the machine's own zone. A repainting caller resolves it once with
# `_WF_TZ=$(wf_tz); _WF_TZ_SET=1`, so a frame never re-reads levain.yml.
wf_tz() {
  [ -n "${_WF_TZ_SET:-}" ] && { printf '%s' "${_WF_TZ:-}"; return 0; }
  local z="${LV_TZ:-}"
  [ -n "$z" ] || z=$(wf_cfg display.timezone "" 2>/dev/null)
  case "$z" in null|Null|NULL|'~') z="" ;; esac
  printf '%s' "$z"
}

# wf_today — YYYY-MM-DD in wf_tz.
wf_today() {
  local z; z=$(wf_tz)
  if [ -n "$z" ]; then TZ="$z" date +%Y-%m-%d; else date +%Y-%m-%d; fi
}

# wf_day_window_utc <YYYY-MM-DD> — "<start> <end>": the UTC stamps (wf_now's
# format) of that day's midnight and the next one, in wf_tz. A count of stored
# events "today" has to compare against this window, never against the date
# as a stamp prefix: from 20:00 EDT the local day and the UTC stamps disagree,
# and a prefix match counted nothing, so the daily autonomy ceiling went
# unenforced every evening (15.23.0). Prints nothing when the date cannot be read.
wf_day_window_utc() {
  local d="$1" z next s e
  z=$(wf_tz)
  ( [ -z "$z" ] || export TZ="$z"
    next=$(date -j -v+1d -f '%Y-%m-%d' "$d" +%Y-%m-%d 2>/dev/null || date -d "$d +1 day" +%Y-%m-%d 2>/dev/null) || exit 0
    s=$(date -j -f '%Y-%m-%d %H:%M:%S' "$d 00:00:00" +%s 2>/dev/null || date -d "$d 00:00:00" +%s 2>/dev/null) || exit 0
    e=$(date -j -f '%Y-%m-%d %H:%M:%S' "$next 00:00:00" +%s 2>/dev/null || date -d "$next 00:00:00" +%s 2>/dev/null) || exit 0
    printf '%s %s\n' \
      "$(date -u -r "$s" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$s" +%Y-%m-%dT%H:%M:%SZ)" \
      "$(date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ)" )
}

# wf_show_time [<epoch>|<YYYY-MM-DDTHH:MM:SSZ>] — "2026-10-29 14:05:09 EDT"
# in wf_tz, labelled with the zone; now when given nothing. Anything it cannot
# read is printed back unchanged, so a display never loses a stamp.
wf_show_time() {
  local t="${1:-}" z epoch
  z=$(wf_tz)
  case "$t" in
    '')                          epoch=$(date +%s) ;;
    *[!0-9]*)                    epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null \
                                   || date -u -d "$t" +%s 2>/dev/null) \
                                   || { printf '%s' "$t"; return 0; } ;;
    *)                           epoch="$t" ;;
  esac
  ( [ -z "$z" ] || export TZ="$z"
    date -r "$epoch" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@$epoch" '+%Y-%m-%d %H:%M:%S %Z' ) \
    || printf '%s' "$t"
}

# macOS and GNU stat disagree on the flag for every field; try both. Lived in
# lv-tray.sh and lv-tray-drill.sh as byte-identical copies, and the drill
# renders the same worker rows the board does — so the two had to agree about
# what "3h20m" means, by convention rather than by construction.
wf_file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
wf_file_size()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

wf_human_age() {
  local secs="$1"
  if   [ "$secs" -lt 60 ]    ; then printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]  ; then printf '%dm' "$((secs / 60))"
  elif [ "$secs" -lt 86400 ] ; then printf '%dh%dm' "$((secs / 3600))" "$(((secs % 3600) / 60))"
  else printf '%dd' "$((secs / 86400))"
  fi
}

# wf_worktree_for_branch <branch> — the worktree that has <branch> checked out,
# or empty when no worktree does (the ref may still exist as a bare ref).
#
# Parsing `git worktree list --porcelain` means tracking the `worktree` line
# that PRECEDES the `branch` line, which is the part each hand-rolled copy got
# subtly differently.
wf_worktree_for_branch() {
  local want="refs/heads/$1" wt="" cur=""
  while IFS= read -r line; do
    case "$line" in
      worktree\ *) cur="${line#worktree }" ;;
      branch\ *)   if [ "${line#branch }" = "$want" ]; then wt="$cur"; fi ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null || true)
  printf '%s' "$wt"
}

# wf_read1 <file> [default] — the first line of a one-line file, or the default
# (empty) when it is missing or unreadable. Never fails.
#
# The orchestrator's state is dozens of these: a pidfile, an attempt count, a
# progress signature, a skip latch. `$(cat "$f" 2>/dev/null || echo "")` reads
# them, and on a daemon tick that is a fork per pidfile per role plus one per
# candidate — for files holding a single short token. `read` is a builtin.
# The `|| :` must NOT clear v. Most of these files are written with `printf
# '%s'` and so have no trailing newline, and `read` reports failure at EOF even
# though it has already assigned everything it read. Discarding the value on
# that status makes every latch read as empty and every pidfile as dead.
wf_read1() {
  local v=""
  if [ -f "$1" ]; then
    IFS= read -r v < "$1" 2>/dev/null || :
  fi
  printf '%s' "${v:-${2:-}}"
}

# ── Config ────────────────────────────────────────────────────────────────

# _WF_YSCALAR_AWK — the awk function both config readers use to turn what
# follows a key (or a `- `) into its value. A quoted value ends at its closing
# quote, so a ` #` inside it is text, not a comment: a test_account_note
# holding a CSS selector (`input #Form_FirstName`) was cut at 480 of ~1000
# characters (a client's LVI-011/012/016). Only an unquoted value has a
# trailing comment stripped. Inside double quotes \" is a quote and \\ a
# backslash, as YAML has them: a services start: of "cd \"$HOME/x\" && ..."
# reached the shell with its backslashes and cd failed (the coordinator's
# LVI-046). Any other escape is kept verbatim, backslash and all, so a
# pattern written as "\.ts$" still means what it did. '' inside single
# quotes is one quote.
_WF_YSCALAR_AWK='
  function yscalar(v,    q, i, c, out, n) {
    gsub(/^[ \t]+/, "", v)
    q = substr(v, 1, 1)
    if (q == "\"" || q == "\047") {
      out = ""; n = length(v)
      for (i = 2; i <= n; i++) {
        c = substr(v, i, 1)
        if (q == "\"" && c == "\\" && i < n) {
          c = substr(v, i + 1, 1); i++
          out = out ((c == "\"" || c == "\\") ? c : "\\" c)
          continue
        }
        if (c == q) {
          if (q == "\047" && substr(v, i + 1, 1) == q) { out = out q; i++; continue }
          return out
        }
        out = out c
      }
      return substr(v, 2)
    }
    sub(/[ \t]+#.*$/, "", v)
    gsub(/[ \t]+$/, "", v)
    return v
  }
'

# wf_cfg <dotted.path> [default]
# Reads a scalar from levain.yml. Deliberately does NOT require yq —
# the orchestrator must run on a bare client checkout. Handles the nested
# 2-space-indented scalar shape this config uses; not a general YAML parser.
#
# LV_CFG_ROOT reads another checkout's levain.yml instead of develop's — for a
# value that belongs to the tree being run, not to the pipeline (lv-docker-up's
# start command).
wf_cfg() {
  local path="$1" default="${2:-}" cfg val
  lv_config_into cfg "${LV_CFG_ROOT:-$(wf_develop_root)}"
  if [ ! -f "$cfg" ]; then printf '%s' "$default"; return 0; fi

  val=$(awk -v path="$path" "$_WF_YSCALAR_AWK"'
    BEGIN { n = split(path, want, "."); level = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2
      if (indent > level) next          # inside a subtree we did not match
      if (indent < level) level = indent # popped back out
      key = probe; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)
      if (key != want[level + 1]) next
      if (level == n - 1) {
        rest = probe; sub(/^[^:]*:[ \t]*/, "", rest)
        rest = yscalar(rest)                        # quotes, trailing comment
        # A bare ">" or "|" (optionally with a chomping/indent modifier) is a
        # YAML block-scalar opener, not a value -- this parser is single-line-
        # per-key only (scalars only, see wf_cfg_list) and has no continuation
        # logic. Returning the literal indicator character as if it were the
        # configured value is worse than returning nothing: client-c set
        # test_account_command to a ">" followed by wrapped continuation
        # lines and this silently answered the bare string ">", which then
        # ran verbatim as the account-provisioning command and did nothing,
        # with no error anywhere (WFI-016). So: warn once, loudly, and answer
        # as if the key were unset -- the default the caller passed in
        # applies instead of a one-character command.
        if (rest ~ /^[|>][+-]?[0-9]*$/) {
          print "wf_cfg: " path " uses YAML block-scalar syntax which levain.yml cannot express (scalars only, one line per key) -- flatten it to a single line using a semicolon as the statement separator. Treating it as unset." > "/dev/stderr"
          exit
        }
        print rest; exit
      }
      level++
    }
  ' "$cfg")

  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# wf_cfg_block <dotted.path>
#
# Reads a YAML BLOCK SCALAR — `key: |` or `key: >` followed by an indented body
# — and prints it dedented, newlines intact. Prints nothing when the key is
# absent or its value is an ordinary one-line scalar.
#
# wf_cfg deliberately refuses a block opener: it is a one-line-per-key parser,
# and client-c's WFI-016 was it answering the literal string ">" as though
# that were the configured command, which then ran verbatim and did nothing.
# Warning and treating the key as unset is right for a COMMAND. It is wrong for
# PROSE.
#
# client-b WFI-021: `test_account_note` held a fifteen-line sign-in recipe —
# do not use the container, it cannot complete an OIDC round trip; run on the
# host at :8083 against a local client-c at :8084; named dev accounts; a
# headless /login actions-json recipe. Written as a `|` block, because that is
# what it is. wf_cfg answered empty, so `$TEST_ACCOUNT` was empty, so lv-test
# stopped and opened a needs-input gate asking the question the file already
# answered — for the third time, and a human answered it a third time. The
# durable answer was present and unread. "Flatten it to a single line using a
# semicolon" is sound advice for a shell command and no advice at all for four
# paragraphs of instructions.
#
# `>` is read the same way as `|`: line breaks are preserved rather than
# folded. The consumers of this are notes shown verbatim to a human, where the
# author's line breaks are the formatting, and a folding parser in awk would be
# more code than the distinction is worth here. Chomping indicators (`-`, `+`)
# are accepted and the trailing newline is stripped either way, since every
# caller prints this into a larger message.
wf_cfg_block() {
  local path="$1" cfg
  lv_config_into cfg "$(wf_develop_root)"
  [ -f "$cfg" ] || return 0

  awk -v path="$path" '
    BEGIN { n = split(path, want, "."); level = 0; collecting = 0; body_indent = -1 }
    {
      line = $0; sub(/\r$/, "", line)

      if (collecting) {
        if (line ~ /^[ \t]*$/) { blanks = blanks "\n"; next }
        match(line, /^[ ]*/); ind = RLENGTH
        if (ind <= key_indent) { collecting = 0; exit }
        if (body_indent < 0) body_indent = ind
        printf "%s", blanks; blanks = ""
        print substr(line, body_indent + 1)
        next
      }

      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2
      if (indent > level) next
      if (indent < level) level = indent
      key = probe; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)
      if (key != want[level + 1]) next
      if (level == n - 1) {
        rest = probe; sub(/^[^:]*:[ \t]*/, "", rest)
        gsub(/^[ \t]+|[ \t]+$/, "", rest)
        if (rest !~ /^[|>][+-]?[0-9]*$/) exit    # an ordinary scalar; not ours
        match(line, /^[ ]*/); key_indent = RLENGTH
        collecting = 1; blanks = ""
        next
      }
      level++
    }
  ' "$cfg"
}

# wf_cfg_text <dotted.path> [default]
# One value, however its author wrote it: a one-line scalar through wf_cfg, or
# a block scalar through wf_cfg_block. For a config value that is PROSE for a
# human rather than something a script runs. Never use it for a command — see
# wf_cfg_block's header, and WFI-016.
wf_cfg_text() {
  local path="$1" default="${2:-}" val
  val=$(wf_cfg_block "$path")
  if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
  # wf_cfg warns on stderr for a block opener it cannot read. We have already
  # established there is no block body, so anything it says here is real.
  wf_cfg "$path" "$default"
}

# wf_cfg_list <dotted.path>
# Reads a YAML sequence of scalars, one item per output line:
#
#   manualTestGate:
#     renderingSurfaces:
#       - "src/**/wwwroot/**"      →  src/**/wwwroot/**
#
# Same deliberate limits as wf_cfg: no yq, 2-space indentation, scalars only.
# Prints nothing when the key is absent or the list is empty — callers decide
# what an empty list means.
wf_cfg_list() {
  local path="$1" cfg
  lv_config_into cfg "$(wf_develop_root)"
  [ -f "$cfg" ] || return 0

  awk -v path="$path" "$_WF_YSCALAR_AWK"'
    BEGIN { n = split(path, want, "."); level = 0; collecting = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2

      if (collecting) {
        if (probe ~ /^- /) {
          item = probe; sub(/^-[ \t]*/, "", item)
          item = yscalar(item)
          if (item != "") print item
          next
        }
        exit                      # first non-item line ends the sequence
      }

      if (indent > level) next
      if (indent < level) level = indent
      key = probe; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)
      if (key != want[level + 1]) next
      if (level == n - 1) { collecting = 1; next }
      level++
    }
  ' "$cfg"
}

# wf_cfg_keys <dotted.path>
# The immediate child keys of a mapping, one per line, in file order:
#
#   services:
#     web:            →  web
#       start: …         worker
#     worker:
#
# For config keyed by a name the library cannot know in advance (services:,
# lv-services.sh). Same limits as wf_cfg: no yq, 2-space indentation. Prints
# nothing when the key is absent or holds a scalar.
wf_cfg_keys() {
  local path="$1" cfg
  lv_config_into cfg "$(wf_develop_root)"
  [ -f "$cfg" ] || return 0

  awk -v path="$path" "$_WF_YSCALAR_AWK"'
    BEGIN { n = split(path, want, "."); level = 0; collecting = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2
      key = probe; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)

      if (collecting) {
        if (indent < n) exit
        if (indent == n && probe !~ /^- /) print key
        next
      }

      if (indent > level) next
      if (indent < level) level = indent
      if (key != want[level + 1]) next
      if (level == n - 1) { collecting = 1; next }
      level++
    }
  ' "$cfg"
}

# ── Output ────────────────────────────────────────────────────────────────

# Single-quoted so `eval` survives spaces, semicolons, backticks — the same
# contract lv-plan-info.sh uses (and the reason BUG-094 existed).
wf_emit() {
  printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}

# ── Harness ───────────────────────────────────────────────────────────────

# wf_restore_harness — put the gitignored runtime files back after a merge.
#
# A branch cut before the v5.0.0 untrack commit still TRACKS
# .claude/skills/lv-*, .claude/workflow.md and scripts/lv-exec.sh; merging one
# that has already taken the migration DELETES them from this worktree, and
# they are gitignored afterwards, so nothing puts them back on its own
# (client-c WFI-006). In a feature worktree the main worktree still has
# the files, so copying is enough — and copying is all that is wanted: a
# worktree needs only the three paths lv-worktree-harness.sh delivers,
# because lv-exec.sh resolves scripts/v*/ from the main worktree. Reaching
# into git history there would put a stale TRACKED copy back on a branch that
# no longer wants one.
#
# The main worktree is the case with nowhere to copy from — client-c lost
# the harness outright on the release side (WFI-006) — so only there does the
# lv-harness-restore.sh fallback apply.
#
# Was two byte-identical copies (lv-merge-develop.sh, lv-merge-release.sh);
# a fix to one silently didn't reach the other. Resolved via BASH_SOURCE, not
# the caller's $0: both call sites already used $0 to reach these same
# scripts, which happened to work because both live next to this library, but
# a shared function looking up ITS OWN directory doesn't depend on that
# coincidence holding at every future call site.
wf_restore_harness() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$dir/lv-worktree-harness.sh" . >/dev/null 2>&1 || true
  local main_wt
  main_wt=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  [ -n "$main_wt" ] && [ "$main_wt" = "$(git rev-parse --show-toplevel 2>/dev/null)" ] || return 0
  [ -x scripts/lv-exec.sh ] && [ -f scripts/version-map.txt ] && return 0
  "$dir/lv-harness-restore.sh" >/dev/null 2>&1 || true
}

# ── Plan identity ─────────────────────────────────────────────────────────

# wf_plan_fingerprint <PLN-NNN> → hash of that plan's plan.md, or empty.
#
# Used to scope a gate answer to the plan REVISION it was given for: an
# approval is given to a document, not to an ID forever. Lives here because the
# writer (lv-gate-close.sh) and the reader (lv-gate-status.sh) must agree
# exactly — two copies of this would mean a gate that either re-opens forever
# or never re-opens, with nothing to indicate which.
#
# Empty for a BUG/BRF id, or a plan with no folder yet. Callers treat an empty
# fingerprint as "cannot tell", not as "changed".
wf_plan_fingerprint() {
  local id="$1" root slug plan_md
  root="$(wf_develop_root)"
  slug=$(wf_registry_field "$id" slug "$root/plans/REGISTRY.md")
  [ -n "$slug" ] || return 0
  plan_md="$root/plans/${id}-${slug}/plan.md"
  [ -f "$plan_md" ] || return 0
  shasum "$plan_md" 2>/dev/null | awk '{print $1}' || true
}

# wf_plan_body_fingerprint <PLN-NNN> → hash of that plan MINUS its ## Review
# section, or empty.
#
# What a review is a verdict ON. Dates cannot answer that: a plan reviewed and
# amended on the same day — the ordinary case, since a review, its findings and
# the amendment that answers them all happen in one session — leaves
# lv-review-status.sh unable to order the two, and it says so with
# REVIEW_STALE=unknown. lv-spec's replanning gate then reads "REVIEW_STALE must
# be false", which that plan can never satisfy (client-a WFI-069).
#
# A hash can answer it. The Review section is excluded because recording the
# stamp inside it would change the very thing being hashed.
#
# WHAT ELSE IS EXCLUDED, AND WHY
#
# The question the stamp answers is "did the SPECIFICATION change since the
# verdict?" — not "did any byte of the file change?". Four regions move under
# machine control while the specification stands still, and hashing them made
# the stamp report a spec change that never happened:
#
#   - Checkbox state. lv-implement and lv-verify tick `## Verification
#     Checklist` boxes on every cycle, so REVIEW_STALE flipped to true after
#     each one — and lv-spec's replan gate ("REVIEW_STALE must be false") then
#     charged a full architectural review round to re-approve text that was
#     byte-identical to what was reviewed (client-a WFI-095). Marks are
#     normalised, so ticking a criterion is invisible and ADDING one is not.
#   - `### Goal History`. Owned end-to-end by lv-goal-push.sh / lv-goal-pop.sh
#     and explicitly not hand-editable; a pop resolving a row is bookkeeping,
#     not a design change (WFI-092, WFI-093).
#   - `## Consistency`. The cross-plan pass's own done-marker, written by
#     lv-consistency and by nothing else — the template says in so many words
#     not to write it by hand. It lands on every `ready` plan that declares
#     Deps, and it landed AFTER the review stamp, so the consistency pass
#     invalidated the verdict of every plan it touched without one word of the
#     specification changing (client-a WFI-151). When that pass does change
#     a specification it amends the plan body and `## Amendments`, both still
#     hashed — so a real consistency amendment still reads as stale, and only
#     the bookkeeping line stops doing so.
#   - `## Lane`, `## Post-ship checklist` and the `> **Lane:**` header line.
#     All three are written by lv-lane.sh, after the review, by design: the
#     express lane is checked against the reviewed plan, so hashing its verdict
#     would make every lane check void the review it was checking (LVI-025).
#   - Trailing whitespace, which no reviewer read.
#
# The `## Goal` one-liner stays IN. It is the plan's promise, a scope reduction
# is exactly the kind of change a stale verdict must catch, and the pop that
# rewrites it mechanically is ordered before the stamp for that reason.
wf_plan_body_fingerprint() {
  local id="$1" root slug plan_md
  root="$(wf_develop_root)"
  slug=$(wf_registry_field "$id" slug "$root/plans/REGISTRY.md")
  [ -n "$slug" ] || return 0
  plan_md="$root/plans/${id}-${slug}/plan.md"
  [ -f "$plan_md" ] || return 0
  wf_plan_body_hash < "$plan_md"
}

# wf_plan_body_hash — the body fingerprint above, of whatever plan.md text is
# on stdin. Split out so a caller can fingerprint a plan as it stood at a past
# commit (`git show <sha>:<path> | wf_plan_body_hash`) and compare like with
# like.
wf_plan_body_hash() {
  awk '
    /^## /  { inside = ($0 ~ /^## (Review|Consistency|Lane|Post-ship checklist)([ \t]|$)/) ? 1 : 0 }
    /^### / { hist   = ($0 ~ /^### Goal History([ \t]|$)/) ? 1 : 0 }
    /^## /  { hist = 0 }
    inside || hist { next }
    /^[ \t]*>?[ \t]*\*\*Lane:\*\*/ { next }
    {
      line = $0
      gsub(/\[[xX]\]/, "[ ]", line)     # a ticked box is not a spec change
      sub(/[ \t]+$/, "", line)
      print line
    }
  ' | shasum 2>/dev/null | awk '{print $1}' || true
}

# ── Reading a review verdict ──────────────────────────────────────────────
#
# ONE PARSER, BECAUSE FOUR SCRIPTS TOUCH THIS SECTION
#
# `## Review` is written by hand, by whatever session ran the review, and read
# back by lv-review-status.sh, lv-review-stamp.sh and lv-manual-lint.sh. When
# each carried its own idea of what a verdict looks like, a plan could pass
# every writer and fail the one reader that mattered.
#
# client-a's PLN-209: a prose review section (`### Round 1 — 2026-08-20 —
# **Approved with notes**`, no blockquote, no `Result:` line) was linted clean
# twice, stamped with a Plan-Hash, and then reported by lv-review-status.sh as
# REVIEW_LOCATION='none', REVIEW_STAMPED='false' — the row /lv-attend renders
# as a harness fault, on a plan that had actually been reviewed and approved
# (WFI-207). Three scripts touched the section; only the fourth, read by
# chance, revealed the verdict was invisible.
#
# So the rule lives once, here, and everything that has an opinion about a
# review verdict asks these.

# wf_section_body <file> <heading> → the lines under `## <heading>`
# Matched by PREFIX, not equality: findings.md dates its headings
# (`## Spec Review — 2026-08-03`), so an equality test finds nothing there.
wf_section_body() {
  local file="$1" heading="$2"
  [ -f "$file" ] || return 0
  awk -v want="$heading" '
    /^## / {
      name = $0; sub(/^## [ \t]*/, "", name)
      sub(/[ \t]+$/, "", name)
      inside = (index(name, want) == 1) ? 1 : 0
      next
    }
    inside { print }
  ' "$file"
}

# wf_prelaunch → exit 0 while the project has no real users: projectProfile.tier
# is pre-launch and live_from is absent or still in the future (LVI-036). A
# malformed live_from is NOT pre-launch — the rule only ever loosens on a
# date it can read. Read by lv-lane.sh (a trusted express declaration).
wf_prelaunch() {
  local tier live today
  tier=$(wf_cfg projectProfile.tier "")
  [ "$tier" = "pre-launch" ] || return 1
  live=$(wf_cfg projectProfile.live_from "")
  case "$live" in null|'~'|Null|NULL) live="" ;; esac
  [ -n "$live" ] || return 0
  printf '%s' "$live" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' || return 1
  today="${LV_LANE_TODAY:-$(wf_today)}"
  [ "$live" \> "$today" ]
}

# ── Pre-launch self-answer (a client's LVI-034) ─────────────────────────────
#
# A pre-launch project runs to its end state without stopping for questions a
# worker can answer. The worker names its recommended answer when it opens the
# gate (lv-gate-open.sh --recommend), the gate is closed on that answer at once,
# and a human checks the result against the end state (lv-end-state.sh), not
# plan by plan. a client's PLN-075 sat on a needs-input gate re-asking a ruling
# three minutes old, blocking four plans, with an acceptable default in hand.
#
# Only questions. `stuck` and `spec-stuck` are circuit breakers, not questions —
# self-answering one turns a loop the budget caught into a loop nothing catches.
# Promotion gates have their own surface (lv-autonomy.sh, LVI-036), and
# manual-test is answered by lv-manual-gate.sh deferring eyes criteria to the
# post-ship checklist, because a closed manual-test gate moves no plan.
LV_GATE_SELF_ANSWERABLE="needs-input spec-approval scope-reduction prior-work"
LV_SELF_ANSWER_MARK="self-answered (pre-launch)"

# wf_self_answers <gate-name> → exit 0 when a worker's recommendation stands in
# for a human at this gate in this project. No gate name: is pre-launch
# self-answer on at all.
wf_self_answers() {
  local g
  wf_prelaunch || return 1
  [ -n "${1:-}" ] || return 0
  for g in $LV_GATE_SELF_ANSWERABLE; do
    [ "$g" = "$1" ] && return 0
  done
  return 1
}

# wf_plan_files <plan.md> → one distinct path per line, from the steps'
# `**Files:**` lines. A bare name after a path on the same line is relative to
# that path's directory: "create `src/a/x.ts`, `y.ts`" is src/a/x.ts and
# src/a/y.ts. Read by lv-lane.sh (the size and path checks) and by
# lv-ignored-sources.sh (a source file git will never see).
wf_plan_files() {
  wf_section_body "$1" "Steps" | awk '
    /\*\*Files:\*\*/ {
      dir = ""
      line = $0
      while (match(line, /`[^`]+`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        sub(/^\.\//, "", tok)
        if (tok ~ /[ \t]/) continue
        if (index(tok, "/") > 0) { d = tok; sub(/\/[^\/]*$/, "", d); dir = d }
        else {
          # A bare token is a file only if it is shaped like one. A Files line
          # also quotes the code it touches (`sealed`, `IDisposable`,
          # `CookieSecurePolicy.Always`), and each was listed as a path under
          # the step folder, for the lane to warn about (client LVI-044).
          if (tok !~ /\.[a-z][a-z0-9]*$/ && tok !~ /^\./ && tok !~ /^(Dockerfile|Makefile|Procfile|Gemfile|Rakefile)$/) continue
          if (dir != "") tok = dir "/" tok
        }
        if (!(tok in seen)) { seen[tok] = 1; print tok }
      }
    }'
}

# wf_review_result_lines <body> → the real verdict lines in a review body
#
# A verdict is any line naming a Result — anywhere in the section AND anywhere
# in the line. Both spellings are in the field: the template writes
# `> **Result:** Approved` on its own line, and a replan session has been seen
# to bury it mid-sentence ("...run at the spec-approval gate. Result: Blocked").
# Anchoring at line start finds the first and silently misses the second, which
# is the same failure as not looking at all.
#
# The template's own line is excluded by its shape: it is a menu of every
# possible verdict, and a real one names exactly one.
wf_review_result_lines() {
  printf '%s\n' "$1" \
    | { grep -iE 'result:' || true; } \
    | { grep -v 'Approved | Approved with notes | Blocked' || true; }
}

# wf_review_has_content <body> → 0 if the section holds anything but scaffolding
# Used to tell "no review yet" (fine, it is coming) from "a review was written
# and cannot be read" (a fault). The template's own placeholder menu line and
# the lv-review-stamp comment are scaffolding, not content.
# Is there a REVIEW here, or only the template's placeholder?
#
# The menu line and the stamp hint were filtered; the rest of TEMPLATE.md's
# `## Review` block was not, so a plan.md written verbatim from the template
# the lv-spec skill tells planners to follow counted as "a review is written
# here" and failed lv-manual-lint.sh with `unreadable-review` — every brand-new
# plan failing the pre-review self-lint the skill requires to pass (WFI-236).
#
# The scaffolding is recognisable without knowing its prose: an unfilled block
# stamps the literal `[date]` where a real one carries a date, and its table is
# a bare header with no rows under it. Both are filtered here as well as
# trimmed from the template, because plans already in flight carry the old
# block and a lint that fails them is a lint nobody can act on.
wf_review_has_content() {
  # HTML comments first: the template's guidance lives in one, and a comment is
  # by definition not a verdict. Stripped rather than pattern-matched so the
  # guidance can be reworded without breaking the lint.
  printf '%s\n' "$1" \
    | awk '/<!--/{ c = 1 } !c { print } /-->/{ c = 0 }' \
    | grep -v 'Approved | Approved with notes | Blocked' \
    | grep -v 'lv-review-stamp' \
    | grep -v '\[date\]' \
    | grep -vE '^[[:space:]]*>?[[:space:]]*\|' \
    | grep -vE '^[[:space:]]*>[[:space:]]*(Filled by|Can also be populated)' \
    | grep -qE '[^[:space:]>*_-]'
}

# ── The goal stack ────────────────────────────────────────────────────────
#
# Three scripts read and write `### Goal History` — push, pop, amend — and the
# section is a four-column markdown table inside a file full of other
# four-column markdown tables. Locating it by shape rather than by section is
# how a goal push once prepended its row to `## Tests` (fixed in
# lv-goal-push.sh), and how a pop later wrote `~~E2E~~` into `## Goal` and
# stamped "Resolved" onto a withdrawn Tests row whose last cell happened to be
# an em dash (client-e WFI-013). The pop reported success both times.
#
# So the lookup lives here, once, and every caller scopes to the section.

# wf_goal_history_row <plan.md> → line number of the LAST unresolved Goal
# History row (Resolution still `—`), or empty if the section has none.
wf_goal_history_row() {
  awk '
    /^### Goal History([ \t]|$)/ { hist = 1; next }
    hist && /^#/                 { hist = 0 }
    hist && /^\|/ && /\|[ \t]*—[ \t]*\|[ \t]*$/ { last = NR }
    END { if (last) print last }
  ' "$1"
}

# wf_goal_line <plan.md> → line number of the plan's goal one-liner: the first
# non-blank line under `## Goal`. Empty when there is no goal to replace.
#
# Not "the line after the heading" — a plan whose `## Goal` is followed by a
# blank line would have its goal written into the blank and the old one left
# standing underneath, which reads as two goals to everything downstream.
wf_goal_line() {
  awk '
    /^## Goal([ \t]|$)/ { goal = 1; next }
    goal && /^#/        { exit }
    goal && NF          { print NR; exit }
  ' "$1"
}

# wf_goal_span <plan.md> → "<start> <end>": the line numbers the goal one-liner
# actually occupies. Normally start == end. Empty when there is no goal.
#
# `## Goal` holds ONE line, and every writer here replaces exactly one — which
# is why a goal that arrived as two lines could never be fully replaced again.
# client-a's WFI-154: a sub-goal containing the two characters `\n` was
# expanded to a real newline on the way in, so `## Goal` became two lines; the
# pop that followed rewrote the first and left the second orphaned in the file.
# The orphan began with `## `, so it parsed as a heading inside the plan.
#
# The span is the run of non-blank lines starting at wf_goal_line — blank line
# or EOF ends it. It deliberately does NOT stop at a `#` line: an orphan that
# looks like a heading is precisely what has to be inside the span for a caller
# to see it. Callers decide what to do with a span wider than one line;
# lv-goal-pop.sh replaces it when it is plain text and refuses when it is not,
# because silently deleting something shaped like a heading is the worse error.
wf_goal_span() {
  local start
  start=$(wf_goal_line "$1")
  [ -n "$start" ] || return 0
  awk -v s="$start" '
    NR >= s { if (!NF) { print s, NR - 1; found = 1; exit } }
    END { if (!found) print s, NR }
  ' "$1"
}

# ── Criteria a test record already settled ───────────────────────────────
#
# lv-test records a PASS in test-progress.md and deliberately leaves plan.md's
# checkbox alone — it ticks a box only on a deferral or a cosmetic failure. So
# the two surfaces disagree by construction for every criterion that simply
# passed, and anything counting open criteria out of plan.md counts passed ones
# among them (WFI-013).
#
# Two callers, one parser, because they must never disagree about what the
# record says:
#
#   lv-manual-gate.sh   passes the tip it is standing on. A PASS is a
#                       measurement of one tree, and deciding whether to stop
#                       for a human is a question about THIS build.
#   lv-registry-update.sh  passes nothing. Its question at `testing -> complete`
#                       is weaker and different — was this criterion ever
#                       executed by anyone — and by then the worktree whose sha
#                       would scope the answer is often already gone.
#
# Prints one criterion text per line. No file, no rows, no output, exit 0 —
# "nothing was recorded" is an answer, not an error.
#
# Unattended (LV_UNATTENDED=1), a PASS counts only if the COMMITTED file holds
# it too. Every criterion this set settles is a `#### Manual` one, and an
# unattended worker has no eyes: a PASS it wrote into the working copy this
# run is a guess, however it is worded. A client's LVI-033: an unattended
# tester rewrote two eyes:cosmetic rows a human had FAILed to PASS ("all
# verified") and the gate subtracted them. A human's PASS was committed by the
# session that recorded it, so it survives the filter.
wf_test_progress_passes() {
  local file="$1" sha="${2:-}" committed
  [ -f "$file" ] || return 0
  if [ "${LV_UNATTENDED:-0}" = "1" ] \
     && git -C "$(dirname "$file")" rev-parse --git-dir >/dev/null 2>&1; then
    committed=$(git -C "$(dirname "$file")" show "HEAD:./$(basename "$file")" 2>/dev/null || true)
    [ -n "$committed" ] || return 0
    grep -xF -f <(printf '%s\n' "$committed" | wf_test_progress_passes_of "$sha") \
      <(wf_test_progress_passes_of "$sha" < "$file") || true
    return 0
  fi
  wf_test_progress_passes_of "$sha" < "$file"
}

# wf_test_progress_passes_of [sha] — the parser behind the above, on stdin.
wf_test_progress_passes_of() {
  local sha="${1:-}"
  awk -F'|' -v sha="$sha" '
    function trim(x) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", x); return x }
    NF < 6 { next }
    {
      criterion = trim($3); build = trim($4); result = toupper(trim($5))
      if (result != "PASS") next
      if (criterion == "" || tolower(criterion) == "criterion") next
      if (sha == "") { print criterion; next }
      # Any hex run of 7+ characters in the Build cell is a candidate sha. It
      # matches when it is a prefix of the tree in hand — the file abbreviates,
      # and by how much is the writing sessions business.
      n = split(build, parts, /[^0-9a-fA-F]+/)
      for (i = 1; i <= n; i++) {
        if (length(parts[i]) >= 7 && index(sha, tolower(parts[i])) == 1) {
          print criterion
          next
        }
      }
    }
  '
}

# wf_live_criteria <plan.md>
#
# Prints plan.md as the criteria parsers should read it: the Human Test
# Criteria that are live NOW, once every amendment is applied. Same line count
# as the file, so a line number reported against the view is a line number in
# plan.md.
#
#   - An amendment's own `##### Chrome-Assisted` / `##### Manual` lists are
#     live criteria. They come out as `#### …` headings, which is what every
#     parser keys on.
#   - Criteria an amendment replaces drop out. A line that names them — a
#     `Human Test Criteria` heading, or a `**Supersedes:**` line — saying e.g.
#     "replace Chrome-Assisted 1–2 and Manual 8" retires those criteria. The
#     numbers are positions in the one flat list /lv-test works from and
#     test-progress.md's `#` column shows (Chrome-Assisted first, then Manual),
#     so with 7 Chrome-Assisted criteria "Manual 8" is the first Manual one. A
#     Manual number no larger than the Chrome-Assisted count cannot be flat,
#     and is read as a position in the Manual list instead. The retired line
#     becomes an HTML comment: neither criterion nor heading.
#   - Amendments apply IN ORDER. A retirement counts positions in the live
#     list as it stood before the amendment naming it — the original criteria
#     and every earlier amendment's, less what earlier amendments retired —
#     and never the amendment's own criteria. An amendment starts at a `###`
#     heading or a `Human Test Criteria` heading; a `**Supersedes:**` line
#     belongs to the amendment it sits in.
#
# The parsers used to read only the original `####` lists. A client's PLN-038
# A-2 replaced two Chrome-Assisted criteria and one Manual criterion with seven
# and one of its own: the gate named all seven superseded originals as
# unrecorded, never saw the A-2 criteria, and once the originals were SKIPped
# it reported CHROME_UNTESTED=2 on a plan whose every live criterion had
# passed (LVI-027). Retirement then reached only the ORIGINAL lists, so a later
# amendment's "replace Manual 2" could not retire an earlier amendment's
# criterion: PLN-026's A-4 left A-1's Manual 2 live beside its own replacement,
# and MANUAL_TOTAL went 3 -> 4 (a client's LVI-010).
wf_live_criteria() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Two passes over one file: the first records every criterion and every
  # retirement against the amendment block it sits in and resolves them in
  # order; the second prints.
  # The dashes go in as variables: a range is written `1–2` as often as `1-2`,
  # and BSD awk has no portable way to spell a multibyte character in a regex.
  awk -v en='–' -v em='—' '
    function mark(sec, list,   n, parts, i, ab, k) {
      n = split(list, parts, ",")
      for (i = 1; i <= n; i++) {
        if (parts[i] ~ /^[0-9]+-[0-9]+$/) {
          split(parts[i], ab, "-")
          for (k = ab[1] + 0; k <= ab[2] + 0; k++) SUP[blk, ++NS[blk]] = sec "\t" k
        } else if (parts[i] ~ /^[0-9]+$/) SUP[blk, ++NS[blk]] = sec "\t" (parts[i] + 0)
      }
    }
    function scan(line,   l, sec, rest, m) {
      l = tolower(line)
      if (l !~ /replac|supersed/) return
      gsub(en, "-", l); gsub(em, "-", l)
      while (match(l, /(chrome-assisted|manual)( criteri(on|a))?[[:space:]]+[0-9]/)) {
        sec = (substr(l, RSTART, 6) == "manual") ? "manual" : "chrome"
        rest = substr(l, RSTART + RLENGTH - 1)
        match(rest, /^[0-9]+([[:space:]]*(-|,|and)[[:space:]]*[0-9]+)*/)
        m = substr(rest, 1, RLENGTH)
        gsub(/[[:space:]]*-[[:space:]]*/, "-", m)
        gsub(/[[:space:]]*(,|and)[[:space:]]*/, ",", m)
        mark(sec, m)
        l = substr(rest, RLENGTH + 1)
      }
    }
    FNR == NR {
      if ($0 ~ /^###+[[:space:]]*Human Test Criteria/) { blk++; cs = ""; scan($0); next }
      if ($0 ~ /^###[[:space:]]/) { blk++; cs = ""; next }
      if ($0 ~ /^[[:space:]]*\*\*Supersedes:?\*\*/) { scan($0); next }
      if ($0 ~ /^#####?[[:space:]]*Chrome-Assisted/) { cs = "chrome"; next }
      if ($0 ~ /^#####?[[:space:]]*Manual/) { cs = "manual"; next }
      if ($0 ~ /^#+[[:space:]]/) { cs = ""; next }
      if (cs != "" && $0 ~ /^[[:space:]]*-[[:space:]]*\[[ xX]\]/) { N++; LN[N] = FNR; S[N] = cs; B[N] = blk }
      next
    }
    FNR == 1 {
      # Resolve each block against the list as it stood before it.
      for (b = 0; b <= blk; b++) {
        if (!NS[b]) continue
        nc = 0; nm = 0
        for (i = 1; i <= N; i++) {
          if (B[i] >= b || (LN[i] in GONE)) continue
          if (S[i] == "chrome") C[++nc] = LN[i]; else M[++nm] = LN[i]
        }
        for (j = 1; j <= NS[b]; j++) {
          split(SUP[b, j], sk, "\t"); k = sk[2] + 0
          if (sk[1] == "chrome") { if (k >= 1 && k <= nc) KILL[C[k]] = 1 }
          else if (k > nc) { if (k - nc <= nm) KILL[M[k - nc]] = 1 }
          else if (k >= 1 && k <= nm) KILL[M[k]] = 1
        }
        for (l in KILL) { GONE[l] = 1; delete KILL[l] }
      }
    }
    /^#####[[:space:]]*(Chrome-Assisted|Manual)/ { sub(/^#####/, "####"); print; next }
    (FNR in GONE) { print "<!-- superseded by an amendment -->"; next }
    { print }
  ' "$file" "$file"
}

# ── Claims ────────────────────────────────────────────────────────────────
#
# A claim says "a live session is working this artifact". It is only worth
# anything if the PID it records outlives the shell that wrote it.
#
# wf_session_pid walks up from the calling shell to the first ancestor that is
# not a shell — the agent session, the daemon, the terminal. The walk used to
# compare `ps -o comm=` against `bash|sh|zsh|dash`, which is exactly right on
# Linux and never matches on macOS, where comm is the full path (`/bin/zsh`).
# So the walk stopped on its first step and recorded the transient shell that
# ran the script — dead by the next tool call, which made EVERY attended claim
# read as stale to the liveness check below. client-a's WFI-062: an attended
# /lv-test session claimed a plan, the daemon dispatched an unattended tester
# onto the same worktree 36 seconds later, and only luck kept it from removing
# the worktree out from under a human mid-test.
#
# THE WALK IS A GUESS; ASK THE SESSION INSTEAD
#
# Fixing the comm match was not enough, because the walk only reaches a
# session-stable process when every process between here and the session is a
# SHELL. It is not: a sandboxed tool call inserts a wrapper (sandbox-exec,
# bwrap) that is not a shell, so the walk stops on it and records a PID that
# dies with the call. client-a's WFI-102 caught the consequence in full — an
# attended /lv-test held a claim, `lv-claim.sh --if-free` from the daemon read
# it as stale seconds later and returned 0, and the unattended tester it
# dispatched destroyed the container the human was testing in and overwrote
# test-progress.md.
#
# No PID-liveness test can be satisfied by walking, so we do not walk when we
# can be told. $CLAUDE_PID is the agent session's own process — it lives
# exactly as long as the session that took the claim, which is precisely the
# lifetime a claim is meant to describe. $LV_SESSION_PID overrides it for
# callers that know better (a daemon claiming on its own behalf).
wf_session_pid() {
  local pid name parent
  if [ -n "${LV_SESSION_PID:-}" ]; then printf '%s' "$LV_SESSION_PID"; return 0; fi
  if [ -n "${CLAUDE_PID:-}" ] && kill -0 "$CLAUDE_PID" 2>/dev/null; then
    printf '%s' "$CLAUDE_PID"; return 0
  fi
  pid=${1:-$PPID}
  for _ in 1 2 3 4 5; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    [ -n "$name" ] || break
    name=${name##*/}      # /bin/zsh → zsh
    name=${name#-}        # -zsh (login shell) → zsh
    case "$name" in
      bash|sh|zsh|dash|ksh|fish)
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$parent" ] && [ "$parent" -gt 1 ] 2>/dev/null || break
        pid="$parent"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$pid"
}

# wf_claim_dir <artifact> → the directory holding that artifact's claim.
#
# WHY NOT THE PLAN FOLDER
#
# Claims used to live at plans/<PLN-NNN-slug>/.wf-claim, which makes the claim
# depend on a folder the work does not have yet. A spec worker dispatched onto
# BRF-002 has no plan folder — the folder is one of the things it creates — so
# lv-spawn.sh's claim was skipped entirely and `lv-claim.sh BRF-002 --if-free`
# exited 1 with "plan directory not found". Every brief- and bug-sourced spec
# run was therefore unclaimed from spawn until it happened to mkdir the plan
# folder, and two workers in that window both pass --if-free: the exact WFI-067
# race the claim exists to stop (client-c WFI-004).
#
# The claim now hangs off the artifact NUMBER, which is the identity that work
# actually has: the counter is global and one piece of work carries two names
# through spec (BUG-022 → PLN-022, BRF-002 → PLN-002). This is the same key
# lv-spawn.sh's already-running pidfile guard uses, and for the same reason — a
# name-keyed claim cannot see its own other name.
#
# Accepts any of PLN-NNN, PLN-NNN-slug, BUG-NNN, BRF-NNN, or the two fixed
# pipeline-stage literals RELEASE / DEPLOY (release and deploy are batches
# across plans, not one artifact, so they claim under a fixed name rather than
# a counter-allocated number). Prints nothing and returns 1 for a string
# carrying none of these.
wf_claim_dir() {
  local artifact="$1" num d
  case "$artifact" in
    RELEASE|DEPLOY)
      d="$(wf_orch_dir)/claims/$artifact"
      mkdir -p "$d"
      printf '%s' "$d"
      return 0
      ;;
  esac
  num=$(printf '%s' "$artifact" | grep -oE "($LV_WORK_RE)-[0-9]+" | head -1 | sed 's/.*-//')
  [ -n "$num" ] || return 1
  # 10# strips the padding, so PLN-002 and PLN-2 name one claim rather than two.
  num=$((10#$num))
  d="$(wf_orch_dir)/claims/$num"
  mkdir -p "$d"
  printf '%s' "$d"
}

# wf_claim_held <artifact> — 0 when a live session holds this artifact's claim.
#
# Checks the canonical number-keyed claim, then any pre-v5.6 claim still sitting
# in the plan folder, so an upgrade mid-flight does not read a live worker's
# claim as absent and double-book it. Sets LV_CLAIM_AGE and LV_CLAIM_HELD_DIR
# (the directory the live claim was found in) for callers that report on it.
wf_claim_held() {
  local artifact="$1" dir legacy
  LV_CLAIM_HELD_DIR=""
  dir=$(wf_claim_dir "$artifact") || return 1
  if wf_claim_live "$dir"; then LV_CLAIM_HELD_DIR="$dir"; return 0; fi
  legacy="$(wf_develop_root)/plans/${artifact}"
  if [ -d "$legacy" ] && wf_claim_live "$legacy"; then
    LV_CLAIM_HELD_DIR="$legacy"; return 0
  fi
  return 1
}

# wf_promote_sibling_held <artifact> — 0 when <artifact> is one promotion slot
# (RELEASE or DEPLOY) and the OTHER one is held by a live session that is not
# the caller's own. Sets LV_PROMOTE_SIBLING to the slot it found held, and the
# LV_CLAIM_* reporting variables from reading it. 1 otherwise, for every other
# artifact.
#
# ONE PROMOTION LOCK, TWO NAMES (a client's LVI-063)
#
# /lv-release moves `release`; /lv-deploy checks `release` against its remote
# with lv-release-sync.sh, then merges it into `main` and pushes. Each claimed
# only its own slot, so a release could move the ref between the deploy's
# check and its merge: one deploy was told "release is in sync with
# origin/release (1adfbb4f) — safe to promote" while git showed the local ref
# already at e44a164d, a commit no E2E run had pushed; the next run said
# "AHEAD". So the two claims are now exclusive of each other. A deploy that
# finds a release in flight is refused exactly as if its own slot were taken,
# and the other way round, for the whole run, because each skill holds its
# claim from its first step to its last. It never promotes on a stale check.
wf_promote_sibling_held() {
  local sib d
  LV_PROMOTE_SIBLING=""
  case "$1" in
    RELEASE) sib=DEPLOY ;;
    DEPLOY)  sib=RELEASE ;;
    *) return 1 ;;
  esac
  d=$(wf_claim_dir "$sib") || return 1
  wf_claim_live "$d" || return 1
  wf_claim_mine "$d" && return 1
  LV_PROMOTE_SIBLING="$sib"
  LV_CLAIM_HELD_DIR="$d"
  return 0
}

# wf_artifacts_with_number <num> — every artifact in this project carrying that
# number, one "<PREFIX> <where>" line each. Empty when the number is unused.
#
# ONE definition of "is this number in use", because there were two and they
# disagreed. lv-counter-next.sh derives its high-water mark from the registry
# plus `plans/*/`, `bugs/*/*/` and `plans/briefs/*`; lv-plan-id.sh's collision
# check asked about PLN rows and PLN folders only. So a BRF or BUG holding a
# number was invisible to the inherit, and client-a ended up with BRF-210
# and PLN-210 as unrelated artifacts sharing one — which claims, keying on the
# number, then locked together (WFI-215).
#
# Numbers are compared NUMERICALLY, not by glob. `BRF-0*215-*` is a regex habit
# that means something else entirely as a pathname pattern: `0*` there is a
# literal zero followed by anything, so it matches nothing a client actually
# has on disk. Padding is normalised with 10# so 215, 0215 and 00215 are one
# number.
wf_artifacts_with_number() {
  local num="$1" root reg want f b n
  [ -n "$num" ] || return 0
  want=$((10#$num))
  root="$(wf_develop_root)"
  reg="$root/plans/REGISTRY.md"

  if [ -f "$reg" ]; then
    awk -F'|' -v want="$want" -v work_re="^($LV_WORK_RE)-[0-9]+$" '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      {
        id = trim($2)
        if (id !~ work_re) next
        split(id, p, "-")
        if (p[2] + 0 == want) printf "%s REGISTRY row %s\n", p[1], id
      }
    ' "$reg"
  fi

  local p cands=()
  for p in $LV_PLN_ALL; do cands+=("$root"/plans/"$p"-*/); done
  for p in $LV_BUG_ALL; do cands+=("$root"/bugs/*/"$p"-*/); done
  for p in $LV_BRF_ALL; do cands+=("$root"/plans/briefs/"$p"-*.md); done
  for f in "${cands[@]}"; do
    [ -e "${f%/}" ] || continue
    b=$(basename "${f%/}")
    n=${b#*-}; n=${n%%-*}
    case "$n" in ''|*[!0-9]*) continue ;; esac
    [ "$((10#$n))" -eq "$want" ] || continue
    printf '%s %s\n' "${b%%-*}" "${f%/}"
  done
}

# wf_claim_write <plan-dir> [pid] [artifact] — timestamp on line 1, owning PID
# on line 2, and the artifact AS THE CALLER NAMED IT on line 3.
#
# The third line is new and every reader treats it as optional, because a claim
# written by an older client has two lines. It exists because the claim keys on
# the NUMBER, so the file itself has never said which artifact it is for — the
# registry did, and a `grep | head -1` resolving the number picks whichever row
# it reaches first. client-a claimed BRF-210 and the listing reported it as
# "PLN-210-publish-path-reports-elision (complete)", a different artifact that
# happened to share the number (WFI-215). Recording what was asked for costs
# one line and removes the guess.
# wf_proc_start <pid> — that process's start time, empty when it is not running.
#
# IDENTITY, NOT LIVENESS. A PID is reusable, so `kill -0` answering yes does
# not prove the answerer is the process that took the claim — after a reboot or
# a busy fortnight it is routinely somebody else. The start time pins it.
# Nothing parses the value; it is only ever compared against another reading
# from the same `ps`, so the format being unspecified costs nothing. Whitespace
# is squeezed because `ps -o lstart=` pads its column.
wf_proc_start() {
  [ -n "${1:-}" ] || return 0
  ps -o lstart= -p "$1" 2>/dev/null | tr -s '[:space:]' ' ' | sed 's/^ *//; s/ *$//'
}

wf_claim_write() {
  local dir="$1" pid="${2:-}" artifact="${3:-}"
  [ -d "$dir" ] || return 1
  [ -n "$pid" ] || pid=$(wf_session_pid)
  # Line 4 is the owner's start time, and like line 3 every reader treats it as
  # optional — a claim written by an older client has three lines, and is aged
  # out on the TTL alone exactly as it was before. See wf_claim_live.
  printf '%s\n%s\n%s\n%s\n' "$(date +%s)" "$pid" "$artifact" "$(wf_proc_start "$pid")" > "$dir/.wf-claim"
}

# wf_claim_mine <plan-dir> — 0 when the live claim on <plan-dir> belongs to the
# caller's own dispatch rather than to somebody else's session.
#
# lv-spawn.sh claims on the worker's behalf BEFORE launching it (WFI-067: the
# claim belongs to whoever hands out the work, or two workers start inside the
# window between "the dispatcher decided this was free" and "the worker said
# so"). But the worker then opens by asking whether the plan is free, sees the
# claim the dispatcher just wrote naming the worker's own PID, and stands down
# against itself. client-a watched that happen three ways: lv-test exiting
# in 15s reporting "a human is testing" against its own spawn PID (WFI-073,
# WFI-075) and lv-list-implementable.sh reporting an explicitly dispatched plan
# as "processing" (WFI-076). Every plan reaching testing under the daemon
# parked after three no-op dispatches.
#
# Ownership is established two ways, either sufficient:
#   - LV_CLAIM_PID — lv-spawn.sh exports the PID it recorded into the worker's
#     environment, so the worker can name its own claim directly.
#   - ancestry — the claim's PID is a parent, grandparent, … of this process.
#     Covers callers that lost the environment (a nested shell that scrubbed
#     it) and the foreground spawn path, where the claim names lv-spawn.sh
#     itself. A human's attended claim names their own session, which is never
#     an ancestor of a different session, so this cannot swallow a real one.
#   - identity — the claim names the PID wf_session_pid would record for THIS
#     caller. Same session, therefore same owner. Ancestry usually covers this,
#     but a sandbox wrapper between the tool call and the session breaks the
#     walk (WFI-102), and a session must always recognise its own claim.
wf_claim_mine() {
  local dir="$1" claim_pid pid parent
  claim_pid=$(sed -n '2p' "$dir/.wf-claim" 2>/dev/null | tr -cd '0-9')
  [ -n "$claim_pid" ] || return 1
  [ -n "${LV_CLAIM_PID:-}" ] && [ "$claim_pid" = "$LV_CLAIM_PID" ] && return 0
  [ "$claim_pid" = "$(wf_session_pid)" ] && return 0
  pid=$$
  for _ in $(seq 1 20); do
    [ "$pid" = "$claim_pid" ] && return 0
    parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$parent" ] && [ "$parent" -gt 1 ] 2>/dev/null || break
    pid="$parent"
  done
  return 1
}

# wf_claim_live <plan-dir> — 0 when a live session holds the claim.
#
# Sets LV_CLAIM_AGE (seconds) for callers that report "claimed Nm ago", and
# LV_CLAIM_OVERDUE=1 when the claim is past the TTL but its owner is provably
# still running. A claim whose owner is gone is reaped here: a worker killed
# mid-run must not park an artifact forever (WFI-067).
#
# THE TTL DOES NOT OUTRANK A LIVE OWNER
#
# This used to check the PID only INSIDE the `age < TTL` branch, so at 7200s it
# fell straight through to `rm -f` without asking whether the owner was alive —
# and reaped the claim of a session sitting right there doing the work. That
# inverts what the two signals are worth: a running owner is direct evidence
# the work is still held, and the TTL is a guess standing in for evidence when
# the owner cannot be found.
#
# The cost was not theoretical. client-b parked PLN-011 — a draft plan blocked
# on another repo — behind a claim, because a lease is the only park the
# harness offers (WFI-015). Two hours later the claim would have evaporated
# under a live session and a spec worker would have replanned the plan against
# tokens that did not exist yet. The only defence available was stopping the
# daemon, which is a poor thing for a correct park to require.
#
# Reuse is what the TTL was really guarding against, and the start time on line
# 4 addresses that directly: the owner counts as alive only when the PID is up
# AND started when the claim says it did. A recycled PID fails that and is
# reaped on schedule, as is a three-line claim from an older client, which
# carries no start time and so cannot be verified either way.
#
# An overdue claim is kept, NOT refreshed. The age keeps climbing and
# LV_CLAIM_OVERDUE keeps saying so, because a claim held for six hours is worth
# a human's attention even when it is legitimate — hiding it by resetting the
# clock would trade one silent failure for another.
LV_CLAIM_TTL=${LV_CLAIM_TTL:-7200}
LV_CLAIM_OVERDUE=0
wf_claim_live() {
  local dir="$1" f="$1/.wf-claim" ts pid started now_started
  LV_CLAIM_AGE=0
  LV_CLAIM_OVERDUE=0
  # Set so a caller can SAY WHO. A worklist that silently drops a claimed
  # artifact is indistinguishable from one that has no work: client-d's
  # BRF-020 vanished from lv-list-specable.sh with nothing on stdout or stderr
  # because the daemon had spawned a spec worker on it 90 seconds earlier, and
  # the attended operator — seeing an empty menu and no explanation —
  # investigated by running lv-unclaim.sh on it, deleting the live worker's
  # claim (WFI-019). Blocked briefs explain themselves; claimed ones must too.
  #
  # HOLDER, not LV_CLAIM_PID. That name is taken, by an INPUT: lv-spawn.sh
  # exports the PID it recorded into the worker it launches, and wf_claim_mine
  # compares a claim against it to answer "is this mine". Writing the claim's
  # own PID there makes that comparison compare the claim to itself, so every
  # claim reads as ours — the write guard stops refusing, --if-free stops
  # standing down, and a second claimant is admitted onto a live worker's plan.
  # The orchestrator and client-reports suites caught it; nothing else would
  # have until two workers were on one artifact.
  LV_CLAIM_HOLDER_PID=""
  [ -f "$f" ] || return 1
  ts=$(sed -n '1p' "$f" 2>/dev/null | tr -cd '0-9')
  pid=$(sed -n '2p' "$f" 2>/dev/null | tr -cd '0-9')
  started=$(sed -n '4p' "$f" 2>/dev/null | tr -d '\r' || true)
  [ -n "$ts" ] || ts=0
  LV_CLAIM_HOLDER_PID="$pid"
  LV_CLAIM_AGE=$(( $(date +%s) - ts ))
  if [ "$LV_CLAIM_AGE" -lt "$LV_CLAIM_TTL" ]; then
    # No PID is the pre-v5.1 format: the TTL alone decides.
    [ -z "$pid" ] && return 0
    kill -0 "$pid" 2>/dev/null && return 0
  elif [ -n "$pid" ] && [ -n "$started" ]; then
    now_started=$(wf_proc_start "$pid")
    if [ -n "$now_started" ] && [ "$now_started" = "$started" ]; then
      LV_CLAIM_OVERDUE=1
      return 0
    fi
  fi
  rm -f "$f"
  return 1
}

# ── Gates ─────────────────────────────────────────────────────────────────

# wf_gate_field <gate-file> <KEY> [--unescape]
# One field from a gate file written by wf_emit — `KEY='value'`, with any
# embedded quote already shell-escaped as `'\''`. Plain form returns exactly
# that escaped text, which is what most callers want: it is re-emitted into
# another gate file, or compared against another still-escaped GATE_* value.
# `--unescape` undoes the `'\''` → `'` shell-quoting, for a value going out to
# a human reader instead — a findings.md entry, a printed report. Printing the
# escaped form there renders the four characters `'\''` literally where an
# apostrophe belongs (WFI-214). Empty, not a failure, when the key or the file
# is missing — every call site here used to hand-roll this same grep|sed pair.
wf_gate_field() {
  local file="$1" key="$2" mode="${3:-}" val
  val=$(grep -m1 "^${key}=" "$file" 2>/dev/null | sed "s/^${key}='//; s/'\$//" || true)
  if [ "$mode" = "--unescape" ]; then
    val=$(printf '%s' "$val" | sed "s/'\\\\''/'/g")
  fi
  printf '%s' "$val"
}

# wf_gate_file <artifact> — path of the gate file for that artifact, open or
# not. Prints the path and returns 0 when one EXISTS; prints the path it would
# be written to and returns 1 when none does.
#
# THE GATE BELONGS TO THE NUMBER, NOT TO THE NAME
#
# Claims settled this question already: "the claim now hangs off the artifact
# NUMBER, which is the identity that work actually has — one piece of work
# carries two names through spec (BUG-022 → PLN-022, BRF-002 → PLN-002)"
# (wf_claim_dir). Gates were keyed on the full prefixed ID, so the two lookups
# disagreed about what one artifact is.
#
# client-a's BRF-161 (WFI-187): lv-spec opened `spec-approval` on the plan it
# had just written, producing `gates/PLN-161.gate`. The dispatcher's skip check
# asked `lv-list-gates.sh BRF-161` — the name it had dispatched under — found no
# `BRF-161.gate`, and concluded nothing was parked. It re-dispatched a spec
# worker onto a brief whose plan was sitting behind an unanswered gate, and
# would have gone on doing it every sweep until a human answered.
#
# Resolution order: the exact name first, so nothing about today's files
# changes; then any other prefix carrying the same number. `10#` normalises the
# padding, so BRF-002 and PLN-2 are one artifact here as they are everywhere
# else.
wf_gate_file() {
  local artifact="$1" id num dir exact f fid
  case "$artifact" in
    RELEASE|DEPLOY) id="$artifact" ;;
    *) id=$(printf '%s' "$artifact" | grep -oE "($LV_WORK_RE)-[0-9]+" | head -1) ;;
  esac
  [ -n "$id" ] || return 1
  dir="$(wf_orch_dir)/gates"
  exact="$dir/${id}.gate"
  if [ -f "$exact" ]; then printf '%s' "$exact"; return 0; fi
  # No fuzzy number-match for these two — they were never counter-allocated,
  # so there is no numeric suffix to compare. The exact name is where a new
  # one belongs, same as the "none open" fallback below (WFI: caught in
  # verification — omitting this printf left callers writing to `> ""`).
  case "$id" in RELEASE|DEPLOY) printf '%s' "$exact"; return 1 ;; esac

  num=$((10#${id##*-}))
  for f in "$dir"/*.gate; do
    [ -f "$f" ] || continue
    fid=$(basename "$f" .gate)
    [[ "$fid" =~ ^($LV_WORK_RE)- ]] || continue
    [ "$((10#${fid##*-}))" = "$num" ] || continue
    printf '%s' "$f"
    return 0
  done

  # None open. The exact name is where a new one belongs.
  printf '%s' "$exact"
  return 1
}

# wf_gate_resolved_file <artifact> <gate-name> — same resolution for the
# answered-gate slot, which is keyed the same way and drifts the same way: a
# `spec-approval` answered under PLN-161 is an answer for BRF-161 too.
#
# THE SLOT, NEVER THE LEDGER. `resolved/<id>.<gate>` is a record of KEY='value'
# lines that callers eval; `resolved/<id>.<gate>.log` is the append-only history
# beside it, one tab-separated line per close. Evaluating a line of that as
# shell is arbitrary execution of a human's resolution text. The `.log` suffix
# puts it outside the `*.<gate>` glob already; it is excluded by name as well,
# because that is an invariant worth stating rather than inferring.
wf_gate_resolved_file() {
  local artifact="$1" gate="$2" id num dir exact f base
  case "$artifact" in
    RELEASE|DEPLOY) id="$artifact" ;;
    *) id=$(printf '%s' "$artifact" | grep -oE "($LV_WORK_RE)-[0-9]+" | head -1) ;;
  esac
  [ -n "$id" ] || return 1
  dir="$(wf_orch_dir)/gates/resolved"
  exact="$dir/${id}.${gate}"
  if [ -f "$exact" ]; then printf '%s' "$exact"; return 0; fi
  case "$id" in RELEASE|DEPLOY) printf '%s' "$exact"; return 1 ;; esac

  num=$((10#${id##*-}))
  for f in "$dir"/*."$gate"; do
    [ -f "$f" ] || continue
    case "$f" in *.log) continue ;; esac
    base=$(basename "$f")
    base="${base%".$gate"}"
    [[ "$base" =~ ^($LV_WORK_RE)- ]] || continue
    [ "$((10#${base##*-}))" = "$num" ] || continue
    printf '%s' "$f"
    return 0
  done

  printf '%s' "$exact"
  return 1
}

# wf_gate_revision_scoped <gate-name> — 0 when one answer covers this gate for
# as long as the plan's specification stands.
#
# Two kinds of gate share one mechanism, and telling them apart is the whole
# question of whether a closed gate may be opened again.
#
#   REVISION-SCOPED. "Approve this plan." "Someone already built this — accept
#   it or revert it." The question is about the document, the answer is about
#   the document, and it stays answered until the document changes. Asking it
#   twice is asking a human the same question twice.
#
#   CYCLE-SCOPED. "Do these criteria pass?" "The PR would not merge." "The
#   attempt budget is spent." Each occurrence is its own question about its own
#   run. A manual-test gate is opened and answered once per test cycle by
#   design (WFI-100), and blocking the second one would stop the pipeline.
#
# Only the first kind is listed. The default is cycle-scoped, so a gate name
# nobody has classified keeps today's behaviour rather than silently jamming.
#
# client-a's PLN-135 is why this exists: a `prior-work` gate answered and
# closed at 11:43, re-opened at 12:01 with identical wording while
# lv-gate-status.sh still reported GATE_ANSWERED=true, GATE_STALE=false
# (WFI-180). Transcribing the resolution into findings.md did not stop it
# (WFI-181), and it re-opened a fourth time thirty minutes after the decision
# was committed (WFI-182) — by then having RE-DERIVED the question, offering an
# option the human never authorized and describing a data structure that had
# changed two merges earlier. A re-asked question does not come back the same,
# which is what makes the loop worse than merely wasteful.
LV_GATE_REVISION_SCOPED="${LV_GATE_REVISION_SCOPED:-spec-approval prior-work scope-reduction goal-missing migration consistency-migration branch-exists spec-stuck}"
wf_gate_revision_scoped() {
  local name="${1:-}" g
  [ -n "$name" ] || return 1
  for g in $LV_GATE_REVISION_SCOPED; do
    [ "$g" = "$name" ] && return 0
  done
  return 1
}

# ── Promotion gates are scoped to a commit set, not to a plan revision ─────
#
# `release-approval` and `deploy-approval` ask about a batch of commits, and
# their answer has to be scoped to that batch the way a spec approval is scoped
# to a plan revision. The source branch's tip IS that scope: same tip, same
# promotion; moved tip, a different question.
#
# wf_promote_tip_ref names the ref whose tip the gate is about, and is empty for
# every other gate name — callers use that emptiness as "this is not a promotion
# gate". wf_promote_tip resolves it, preferring the remote ref where one exists,
# because `release` and `main` live in pinned worktrees this checkout never
# moves and their local refs are routinely behind (WFI-024, WFI-027).
#
# `deploy-deferred-criteria` is on this list for the same reason: it asks "ship
# these plans with these criteria still open?", and which plans those are comes
# straight out of `release --not main`. client-a WFI-260 — the gate opened at
# 15:15 quoting 91 commits, /lv-release merged PR #214 into origin/release two
# minutes later, and the batch the human would be answering about was 118
# commits carrying two plans (PLN-279, PLN-280) whose deferred criteria that
# question never showed. Scoping it to the release tip lapses the answer the
# moment the batch changes, exactly as it does for deploy-approval.
#
# `production-push` asks the last question — "push local `main` to origin?" —
# and is scoped to LOCAL `main`, because that is the thing the push sends and
# nothing has pushed it yet. /lv-deploy step 14 opens it when an unattended run
# finished the promotion but holds no `production-push` grant. Without it the
# push had no way to be asked for: the worker stopped with main unpushed, which
# lv-list-deploy.sh reads as unfinished work, so the daemon re-dispatched it
# until the attempt budget parked a `stuck` gate on a deploy that had worked
# (coordinator WFI-008, client-b 2026-09-23).
wf_promote_tip_ref() {
  case "${1:-}" in
    release-approval) printf 'develop' ;;
    deploy-approval)  printf 'release' ;;
    deploy-deferred-criteria) printf 'release' ;;
    production-push)  printf 'main' ;;
    *) printf '' ;;
  esac
}

wf_promote_tip() {
  local ref sha root
  ref=$(wf_promote_tip_ref "${1:-}")
  [ -n "$ref" ] || return 1
  root="$(wf_develop_root)"
  # develop is the branch every skill commits to locally, and /lv-release
  # pushes it as part of the promotion — so the LOCAL tip is what the commit
  # list was taken from. release is only ever advanced by a push, so its remote
  # ref is the authoritative one. `main` is read locally for the same reason
  # `develop` is: production-push asks about the tip that has NOT been pushed.
  case "$ref" in
    develop|main)
      sha=$(git -C "$root" rev-parse --verify -q "refs/heads/$ref" 2>/dev/null || true) ;;
    *)
      sha=$(git -C "$root" rev-parse --verify -q "refs/remotes/origin/$ref" 2>/dev/null || true)
      [ -n "$sha" ] || sha=$(git -C "$root" rev-parse --verify -q "refs/heads/$ref" 2>/dev/null || true) ;;
  esac
  [ -n "$sha" ] || return 1
  printf '%s' "$sha"
}

# wf_promote_fetch <gate-name>
#
# Refresh the remote-tracking ref a promotion gate is scoped to, so the tip
# stamped on the gate is the tip that EXISTS rather than the one this checkout
# last happened to hear about.
#
# WHY: wf_promote_tip reads refs/remotes/origin/<ref>, which only moves on a
# fetch, and nothing on the gate-open path fetches. client-a WFI-264: a
# `deploy-deferred-criteria` gate opened at 17:46 carrying d762af79 — already 69
# commits stale, because /lv-test had merged PR #220 into origin/release through
# GitHub and no local ref had heard of it. A human approved that gate four hours
# later; /lv-deploy's step 2a then fetched as a side effect of lv-release-sync.sh,
# lv-promote-approval.sh compared the fresh tip against the stale recorded one,
# and discarded an answer the human had no way to give correctly. The gate
# re-opened 41 seconds later with the same headline. A gate opened against a tip
# that was never current cannot be answered in a way that sticks.
#
# Best effort by design: offline, the cached ref is still the best answer
# available and a gate that cannot be opened is worse than one scoped to the
# last tip this checkout saw. `develop` is local — /lv-release pushes it as part
# of the promotion, so its local ref IS the batch (see wf_promote_tip).
wf_promote_fetch() {
  local ref root
  ref=$(wf_promote_tip_ref "${1:-}")
  [ -n "$ref" ] || return 0
  case "$ref" in develop|main) return 0 ;; esac
  root="$(wf_develop_root)"
  git -C "$root" fetch --quiet origin \
    "+refs/heads/$ref:refs/remotes/origin/$ref" 2>/dev/null || true
  return 0
}

# ── Events ────────────────────────────────────────────────────────────────

# wf_event <type> <artifact> <message>
# One tab-separated line per event. Appended with a single write so concurrent
# workers interleave cleanly (well under PIPE_BUF).
wf_event() {
  local type="$1" artifact="$2" msg="${3:-}"
  local log="$(wf_orch_dir)/events.log"
  printf '%s\t%s\t%s\t%s\n' "$(wf_now)" "$type" "$artifact" "$msg" >> "$log"
}

# ── plans/briefs/INDEX.md ─────────────────────────────────────────────────
#
# The briefs backlog is a markdown file with one `## <Status>` section per
# state and one `- [name](file.md) — description` row per brief. Two scripts
# rewrite it — lv-brief-park.sh moves a row between sections, and
# lv-brainstorm-reindex.sh adds a missing one — and both want the same two
# careful behaviours, so they live here rather than as two awk programs that
# will drift apart:
#
#   · a row is carried VERBATIM. It is a human's own words about their own
#     idea; a script that re-derives it from the brief header replaces a
#     description with a title and quietly loses the difference.
#   · insertion goes after the section's last non-blank line, so a row lands
#     under the existing entries and the `>` blurb keeps its blank line
#     instead of collecting one row of stray whitespace per edit.

# wf_brief_title <brief.md> — the brief's heading, for a row or a list line.
#
# The first line is not it: some briefs open with a `---` frontmatter block
# (client-e's BRF-011 and BRF-067 among them), and reading line 1 turned those
# into rows titled "---". The first `# ` heading is the title in both shapes.
wf_brief_title() {
  local t
  t=$(grep -m1 -E '^#[ \t]' "$1" 2>/dev/null | sed 's/^#[[:space:]]*//; s/[[:space:]]*$//' || true)
  # Then a frontmatter `title:`, then the filename. "(untitled)" tells a reader
  # nothing and makes the row harder to act on than the path would have been.
  [ -n "$t" ] || t=$(grep -m1 -E '^(title|name):' "$1" 2>/dev/null \
                     | sed -E 's/^(title|name):[[:space:]]*//; s/^"//; s/"$//; s/[[:space:]]*$//' || true)
  [ -n "$t" ] || t=$(basename "$1" .md | sed -E "s/^($LV_BRF_RE)-[0-9]+-//; s/-/ /g")
  printf '%s' "$t"
}

# wf_brief_status <brief.md> — the brief's status, whichever way it is written.
#
# TEMPLATE.md's header blockquote (`> **Status:** Exploring`) is the current
# shape, but a run of briefs in the field carry YAML frontmatter instead
# (`status: Decided` — client-e's BRF-066, 067, 068). Reading only the
# blockquote called those "unknown" and filed them under Idea, which is how a
# Decided brief ends up looking like an idea nobody has touched.
#
# Prints the empty string when neither is present, or when the template's
# unedited vocabulary line ("Idea | Exploring | Decided | Planned") is all
# there is — that says nothing about THIS brief.
wf_brief_status() {
  local s
  s=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Status:\*\*' "$1" 2>/dev/null \
      | sed -E 's/^.*\*\*Status:\*\*[[:space:]]*//; s/[[:space:]]*$//' || true)
  [ -n "$s" ] || s=$(grep -m1 -E '^status:' "$1" 2>/dev/null \
                     | sed -E 's/^status:[[:space:]]*//; s/^"//; s/"$//; s/[[:space:]]*$//' || true)
  case "$s" in *"|"*) s="" ;; esac
  printf '%s' "$s"
}

# wf_brief_has_plan <brief.md> — true when a plan was written from this brief.
#
# Two ways to know, because the Plan: field has been written four different
# ways in the field (a markdown link, a backticked legacy path, a bare slug,
# and in plenty of briefs not at all):
#
#   1. any PLN-NNN named in the brief's Plan: field, matched to a real
#      plans/PLN-NNN-* directory;
#   2. failing that, the brief's own number — a plan inherits the number of
#      the brief it came from (BRF-041 → PLN-041, see CLAUDE.md), and the
#      counter is global, so plans/PLN-041-* can only have come from BRF-041.
#
# Used to tell a brief that is unlisted BECAUSE IT SHIPPED (/lv-brainstorm
# prunes those rows — client-c WFI-028) from one that fell out of the
# index by accident.
wf_brief_has_plan() {
  local brief_md="$1" num pln p
  [ -f "$brief_md" ] || return 1

  pln=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*Plan:\*\*' "$brief_md" 2>/dev/null \
        | grep -oE "($LV_PLN_RE)-[0-9]+" | head -1 || true)
  if [ -n "$pln" ]; then
    for d in plans/"$pln"-*/; do [ -d "$d" ] && return 0; done
  fi

  num=$(basename "$brief_md" | grep -oE "^($LV_BRF_RE)-[0-9]+" | head -1 | grep -oE '[0-9]+' || true)
  if [ -n "$num" ]; then
    for p in $LV_PLN_ALL; do
      for d in plans/"$p"-"$num"-*/; do [ -d "$d" ] && return 0; done
    done
  fi
  return 1
}

# wf_index_take_row <index> <needle> — remove the first row mentioning
# <needle> and print it. Rewrites the index in place. Prints nothing and
# leaves the file untouched when there is no such row.
wf_index_take_row() {
  local index="$1" needle="$2" tmp="$1.tmp.$$"
  [ -f "$index" ] || return 1
  local row
  row=$(grep -m1 -F -- "$needle" "$index" | grep '^- \[' || true)
  [ -n "$row" ] || return 1
  # Pulling a row out can leave the blank line above it stacked on the blank
  # line below it; a run of blanks is collapsed so a section that has been
  # edited a few times still looks hand-written.
  LV_ROW="$row" awk '
    BEGIN { dropped = 0; blanks = 0 }
    !dropped && $0 == ENVIRON["LV_ROW"] { dropped = 1; next }
    {
      if ($0 ~ /^[ \t]*$/) { blanks++; if (blanks > 1) next } else blanks = 0
      print
    }
  ' "$index" > "$tmp" && mv "$tmp" "$index"
  printf '%s\n' "$row"
}

# wf_index_put_row <index> <section> <row> — insert <row> at the end of
# `## <section>`, creating the section at the end of the file if it is absent.
wf_index_put_row() {
  local index="$1" section="$2" row="$3" tmp="$1.tmp.$$" blurb=""
  [ -f "$index" ] || return 1
  case "$section" in
    Parked)    blurb="Set aside on purpose — not being explored, kept for the record with a dated reason." ;;
    Idea)      blurb="Captured but not yet explored." ;;
    Exploring) blurb="Actively being discussed or researched. Open questions remain." ;;
    Decided)   blurb="Approach chosen, ready for a planner session to convert into an implementation plan." ;;
    Planned)   blurb="Ideas that have graduated to implementation plans." ;;
    Reference) blurb="Long-lived context documents, not actionable ideas." ;;
  esac
  LV_SECTION="$section" LV_ROW="$row" LV_BLURB="$blurb" awk '
    { lines[++n] = $0 }
    END {
      target = "^## " ENVIRON["LV_SECTION"] "[ \t]*$"
      start = 0
      for (i = 1; i <= n; i++) if (lines[i] ~ target) { start = i; break }

      if (start == 0) {
        # Creating the section: it gets the same one-line `>` blurb every
        # hand-written section has, or it reads as something a script dropped
        # in. `## Parked` is the case that actually happens — it is newer than
        # every index in the field.
        for (i = 1; i <= n; i++) print lines[i]
        if (n > 0 && lines[n] != "") print ""
        print "## " ENVIRON["LV_SECTION"]
        if (ENVIRON["LV_BLURB"] != "") print "> " ENVIRON["LV_BLURB"]
        print ""
        print ENVIRON["LV_ROW"]
        exit 0
      }

      end = n
      for (i = start + 1; i <= n; i++) if (lines[i] ~ /^## /) { end = i - 1; break }
      at = start
      for (i = start; i <= end; i++) if (lines[i] != "") at = i

      for (i = 1; i <= n; i++) {
        print lines[i]
        if (i == at) {
          # Inserting into an empty section lands right after its `>` blurb;
          # the template puts a blank line between the two, so keep it rather
          # than producing a shape no hand-written section has.
          if (lines[i] ~ /^>/ || lines[i] ~ /^## /) print ""
          print ENVIRON["LV_ROW"]
        }
      }
    }
  ' "$index" > "$tmp" && mv "$tmp" "$index"
}

# ── Self-documentation ────────────────────────────────────────────────────
#
# Every script in this folder opens with a comment block that IS its manual:
# the usage lines, the options, and the incident that shaped each one. Nothing
# routed a caller to it. `lv-commit.sh --help` consumed `--help` as the
# positional <message> and printed "nothing to commit for the given paths —
# skipped"; `lv-claim.sh --status` and `lv-bug-close.sh --help` answered
# "Unknown option" and exited 1 over usage text they define a few lines later.
# So the only discoverable way to read an interface was to open the file
# (client-b WFI-006, and the same point again in WFI-008).
#
# lv-exec.sh now intercepts -h/--help for every script that does not handle it
# itself. These two are for the other half: an option the script does not know.

# wf_usage [file] — print the leading comment block of a script, unprefixed.
wf_usage() {
  local f="${1:-$0}"
  awk 'NR == 1 && /^#!/ { next }
       /^#/ { sub(/^#[ ]?/, ""); print; next }
       { exit }' "$f"
}

# wf_bad_option <option> [file] — say which option, then show the manual.
# Exits 1; a caller that wants to continue should not use it.
wf_bad_option() {
  local opt="$1" f="${2:-$0}"
  echo "$(basename "$f"): unknown option '$opt'" >&2
  echo >&2
  wf_usage "$f" >&2
  exit 1
}

# ── Directives and the context a plan was decided in (LVI-033) ─────────────
#
# A plan is specified, reviewed and approved as a document — but it is written
# against OTHER documents: the plans in its Deps, the answers a human gave on
# them, and any direction the overseer has given. Every staleness test the
# harness had looked only at the plan's own text. So when one of those other
# documents moved, the plan's approval stood.
#
# A client, 2026-09-30. PLN-026 bounced implement→spec, ran three review
# rounds and parked `spec-stuck`; the operator resolved it by removing the
# Folder allow-list. PLN-028 (Deps PLN-025, PLN-026) had been specced against
# PLN-026's draft text and sat at spec-approval built on that allow-list — the
# only guard on serving a child's photo. Nothing marked PLN-028's approval
# stale, lv-consistency ran only at `ready`, and the overseer had no channel a
# /lv-spec worker would read as binding. The operator's only path was to
# remember to reject PLN-028's gate by hand.
#
# Two things live here. DIRECTIVES are that channel: binding direction written
# by lv-direct.sh into plans/<plan>/directives.md, which every worker reading
# the plan loads first. CONTEXT is the fingerprint of everything a plan was
# decided against — each plan in its closure (body, directives, answered
# revision-scoped gates) and its own directives. lv-gate-open.sh records it
# when a question is asked, lv-gate-close.sh when it is answered, and
# lv-gate-status.sh compares: a moved context makes an answer stale and an
# open question moot, the same as a moved plan body does.

# wf_plan_dir <id> → plans/<id>-<slug> in the develop root; 1 when none.
wf_plan_dir() {
  local id="$1" root slug d
  root="$(wf_develop_root)"
  slug=$(wf_registry_field "$id" slug "$root/plans/REGISTRY.md")
  if [ -n "$slug" ] && [ -d "$root/plans/${id}-${slug}" ]; then
    printf '%s' "$root/plans/${id}-${slug}"; return 0
  fi
  for d in "$root/plans/${id}"-*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; printf '%s' "$d"; return 0
  done
  return 1
}

# wf_directives_rows <plan-id> → one row per directive, \037-separated:
#   D-n  kind  status  author  date  supersedes  text
# The text is the body on one line, its line breaks shown as " / ". Nothing,
# and 0, when the plan has no directives.md.
wf_directives_rows() {
  local dir file
  dir=$(wf_plan_dir "$1") || return 0
  file="$dir/directives.md"
  [ -f "$file" ] || return 0
  awk '
    function flush() {
      if (did == "") return
      gsub(/^( \/ )+|( \/ )+$/, "", text)
      printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", did, kind, status, author, date, sup, text
    }
    function field(line,   v) { v = line; sub(/^>[ \t]*\*\*[A-Za-z]+:\*\*[ \t]*/, "", v); sub(/[ \t]+$/, "", v); return v }
    /^## D-[0-9]+/ {
      flush()
      did = $2; kind = $0; sub(/^## D-[0-9]+[ \t]*—[ \t]*/, "", kind); sub(/[ \t]+$/, "", kind)
      status = "open"; author = ""; date = ""; sup = "—"; text = ""
      next
    }
    did == "" { next }
    /^>[ \t]*\*\*Status:\*\*/     { status = field($0); next }
    /^>[ \t]*\*\*Author:\*\*/     { author = field($0); next }
    /^>[ \t]*\*\*Date:\*\*/       { date = field($0); next }
    /^>[ \t]*\*\*Supersedes:\*\*/ { sup = field($0); next }
    {
      line = $0; sub(/[ \t]+$/, "", line)
      if (line == "" && text == "") next
      text = (text == "") ? line : text " / " line
    }
    END { flush() }
  ' "$file"
}

# wf_directives_live <plan-id> → the rows above that still bind: everything
# not superseded. Applied directives still bind — `applied` says the plan text
# now carries them, not that they lapsed.
wf_directives_live() {
  wf_directives_rows "$1" | awk -F'\037' '$3 !~ /^superseded/'
}

# wf_plan_held <plan-id> → the D-n of a live `hold`, exit 0; exit 1 when the
# plan is not held. `release-hold` supersedes the hold it releases, so a live
# hold row is the whole answer.
wf_plan_held() {
  local d
  d=$(wf_directives_live "$1" | awk -F'\037' '$2 == "hold" { h = $1 } END { print h }')
  [ -n "$d" ] || return 1
  printf '%s' "$d"
}

# wf_directives_hash <plan-id> → a hash of the live directives that say
# something about the SPECIFICATION — constraint and replan — or empty. Status
# is left out, so marking a directive applied stales nothing; holds are left
# out, because pausing dispatch changes no design.
wf_directives_hash() {
  local rows
  rows=$(wf_directives_live "$1" | awk -F'\037' '$2 == "constraint" || $2 == "replan" { print $1 "\037" $2 "\037" $6 "\037" $7 }')
  [ -n "$rows" ] || return 0
  printf '%s\n' "$rows" | shasum | awk '{print substr($1, 1, 12)}'
}

# wf_gate_answers_stamp <id> → when each revision-scoped gate on that artifact
# (any prefix carrying its number) was last answered, as `gate@time` words.
# A withdrawn question was not answered, so it does not count.
wf_gate_answers_stamp() {
  local id="$1" dir num f base gate out=""
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
    [ "$(wf_gate_field "$f" GATE_WITHDRAWN)" = "true" ] && continue
    out="$out${out:+ }$gate@$(wf_gate_field "$f" GATE_RESOLVED)"
  done
  printf '%s' "$out"
}

# wf_plan_context <plan-id> → the context fingerprint, as sorted words:
#   PLN-025=<hash> PLN-026=<hash> directives=<hash>
# One word per plan in the transitive closure (its body, its directives, the
# answers given on it), plus this plan's own directives when it has any.
# `none` for a plan with no Deps and no directives: a context that was TAKEN and
# is empty, which is different from one never taken (an empty field in an older
# record) — a directive added later must still read as a change.
# Words rather than one hash so a change can be NAMED: wf_context_changed.
wf_plan_context() {
  local id="$1" words="" cid _slug _state h d
  while IFS=$'\t' read -r cid _slug _state; do
    [ -n "$cid" ] || continue
    h=$(printf '%s|%s|%s' "$(wf_plan_body_fingerprint "$cid")" "$(wf_directives_hash "$cid")" \
          "$(wf_gate_answers_stamp "$cid")" | shasum | awk '{print substr($1, 1, 12)}')
    words="$words $cid=$h"
  done < <("$(dirname "${BASH_SOURCE[0]}")/lv-list-closure.sh" "$id" 2>/dev/null || true)
  d=$(wf_directives_hash "$id")
  [ -n "$d" ] && words="$words directives=$d"
  [ -n "$words" ] || { printf 'none'; return 0; }
  printf '%s\n' $words | sort | tr '\n' ' ' | sed 's/^ *//; s/ *$//'
}

# wf_context_changed <old-context> <new-context> → the names whose words differ
# (a plan id, or `directives`), space-separated; empty when they agree. An old
# context that is empty is a record written before contexts existed, and is
# never reported as changed — a fingerprint that was never taken cannot have
# moved, and treating it as moved would stale every answer on upgrade.
wf_context_changed() {
  local old="$1" new="$2"
  [ -n "$old" ] || return 0
  [ "$old" = "$new" ] && return 0
  [ "$old" = "none" ] && old=""
  [ "$new" = "none" ] && new=""
  {
    printf '%s\n' $old | sed 's/^/o /'
    printf '%s\n' $new | sed 's/^/n /'
  } | awk '
    { split($2, kv, "="); k = kv[1]; v = kv[2]
      if ($1 == "o") o[k] = v; else n[k] = v; seen[k] = 1 }
    END { for (k in seen) if (o[k] != n[k]) print k }
  ' | sort | tr '\n' ' ' | sed 's/ *$//'
}

# wf_plan_dependents <plan-id> → the plans whose Deps name this one directly
# and that are not built yet (draft or ready), as `PLN-028 (draft)` words,
# comma-separated. An open gate on one is named too: `PLN-028 (draft,
# spec-approval open)`.
wf_plan_dependents() {
  local want="$1" out="" did _s state _p _b _u _w _t deps d g gf
  while IFS=$'\037' read -r did _s state _p _b _u _w _t deps; do
    case "$state" in draft|ready) ;; *) continue ;; esac
    case ",${deps// /}," in *",$want,"*) ;; *) continue ;; esac
    d="$did ($state"
    gf=$(wf_gate_file "$did" || true)
    if [ -f "$gf" ]; then g=$(wf_gate_field "$gf" GATE_NAME); d="$d, $g open"; fi
    out="$out${out:+, }$d)"
  done < <(wf_registry_rows)
  printf '%s' "$out"
}

# wf_plan_flux_note <plan-id> → a bracketed note naming the plans upstream of
# this one that are still being decided (draft), and the unbuilt plans that
# depend on it — or nothing. Appended to spec-approval and spec-stuck
# questions, so the human answering one sees which other decisions it moves
# with (LVI-033).
wf_plan_flux_note() {
  local id="$1" up="" cid _slug state deps
  while IFS=$'\t' read -r cid _slug state; do
    [ -n "$cid" ] || continue
    [ "$state" = "draft" ] && up="$up${up:+, }$cid (draft)"
  done < <("$(dirname "${BASH_SOURCE[0]}")/lv-list-closure.sh" "$id" 2>/dev/null || true)
  deps=$(wf_plan_dependents "$id")
  [ -n "$up" ] && printf ' [upstream still in flux: %s]' "$up"
  [ -n "$deps" ] && printf ' [unbuilt dependents that move with this answer: %s]' "$deps"
  return 0
}

# ── Native app runs (lv-docker-up.sh with no compose file) ─────────────────
#
# wf_app_run_dir — where a native run's pidfile and port live. Not $TMPDIR:
# it differs between Claude sessions (/private/tmp/claude-501/… against
# /var/folders/…), so the session that tore a plan down never found the
# pidfile the starting session wrote, and nothing else looked. 19 static
# servers were found alive 11-35 days later (the coordinator's LVI-039).
wf_app_run_dir() {
  local d="/tmp/lv-apps-$(id -u)"
  mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
  printf '%s' "$d"
}

# wf_app_descendants <pid> — every process under pid, deepest last.
wf_app_descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do
    printf '%s\n' "$c"
    wf_app_descendants "$c"
  done
}

# wf_stop_native <compose-name> — stop the native app started under that name:
# its process group, every descendant (a child that left the group survived a
# group kill and kept serving the port, a client's LVI-027), then anything
# still listening on its recorded port. Prints what it did; returns 1 when the
# port is still held afterwards, 0 otherwise (including nothing to stop).
wf_stop_native() {
  local name="$1" dir pidf portf pid port pids p held f
  dir=$(wf_app_run_dir)
  pidf="$dir/lv-app-$name.pid"; portf="$dir/lv-app-$name.port"
  # A pidfile from before 15.18 sits in the starting session's $TMPDIR.
  [ -f "$pidf" ] || { f="${TMPDIR:-/tmp}/lv-app-$name.pid"; [ -f "$f" ] && pidf="$f"; }
  [ -f "$pidf" ] || return 0
  pid=$(tr -d '[:space:]' < "$pidf")
  port=$(tr -d '[:space:]' < "$portf" 2>/dev/null || true)
  [ -n "$port" ] || port="${FEATURE_PORT:-}"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    pids="$pid $(wf_app_descendants "$pid" | tr '\n' ' ')"
    kill -TERM -- "-$pid" 2>/dev/null || true
    for p in $pids; do kill -TERM "$p" 2>/dev/null || true; done
    for _ in 1 2 3 4 5; do
      held=""
      for p in $pids; do kill -0 "$p" 2>/dev/null && held=1; done
      [ -z "$held" ] && break
      sleep 1
    done
    kill -KILL -- "-$pid" 2>/dev/null || true
    for p in $pids; do kill -KILL "$p" 2>/dev/null || true; done
  fi
  if [ -n "$port" ] && command -v lsof >/dev/null 2>&1; then
    # Only a process started from this run's tree is ours to kill: its pid was
    # recorded, or it descends from one. Anything else on the port is reported.
    for p in $(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null); do
      case " ${pids:-} " in *" $p "*) kill -KILL "$p" 2>/dev/null || true ;; esac
    done
    sleep 0.2
    if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
      echo "App $name: port $port is STILL held after stopping its run:" >&2
      lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /' >&2
      rm -f "$pidf" "$portf"
      return 1
    fi
  fi
  rm -f "$pidf" "$portf"
  echo "App $name stopped${port:+ (port $port free)}"
  return 0
}
