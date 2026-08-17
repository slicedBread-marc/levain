#!/usr/bin/env bash
# wf-orch-lib.sh — shared helpers for the orchestrator. Source it; don't run it.
#
#   source "$(dirname "$0")/wf-orch-lib.sh"
#
# Everything orchestrator-related is anchored to the DEVELOP ROOT, never to the
# current worktree. A worker running in feature/PLN-097-foo must open a gate
# that /wf-attend on develop can see, so gates, events and pidfiles all live
# under <develop-root>/.claude/orchestrator/.
#
# Provides:
#   wf_develop_root                  → absolute path of the first worktree
#   wf_orch_dir                      → <develop-root>/.claude/orchestrator (created)
#   wf_registry_rows [path]          → one trimmed plan row per line (0x1f-separated)
#   wf_bug_id <bug.md>               → the bug that file declares itself to be
#   wf_goal_text <plan.md>           → that plan's one-line goal
#   wf_cfg <dotted.path> [default]   → value from claude-workflow.yml
#   wf_emit <KEY> <value>            → eval-safe KEY='value' line
#   wf_plan_fingerprint <PLN-NNN>    → hash of that plan's plan.md (may be empty)
#   wf_session_pid                   → PID of the long-lived session, not the shell
#   wf_claim_dir <artifact>          → the directory that holds this artifact's claim
#   wf_claim_write <dir> [pid]       → write <dir>/.wf-claim
#   wf_claim_live <dir>              → 0 if a live claim holds it; sets WF_CLAIM_AGE
#   wf_claim_mine <dir>              → 0 if that claim is this caller's own
#   wf_claim_held <artifact>         → wf_claim_live against wf_claim_dir + legacy
#   wf_event <type> <artifact> <msg> → append to events.log
#   wf_now                           → ISO-8601 UTC timestamp

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
  root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  # Not a worktree setup — fall back to the repo toplevel, then CWD.
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || true
  [ -n "$root" ] || root="$PWD"
  _WF_DEVELOP_ROOT="$root"
  printf '%s' "$root"
}

_WF_ORCH_DIR_MADE=""
wf_orch_dir() {
  local d="$(wf_develop_root)/.claude/orchestrator"
  # pending/: spawns deferred behind the requester's own claim, served by
  # wf-unclaim.sh when it comes down (WFI-086, WFI-091).
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
# rejects it. On a 70-row registry that is ~0.9s per script, and /wf-status
# runs eight of them. One awk pass is 0.006s.
#
# It also fixes the fragility that came with positional reads: `IFS='|' read -r
# _ id slug state priority branch _rest` names its columns by position in
# twelve places, so a new registry column silently shifts all twelve. Here it
# shifts one function.
wf_registry_rows() {
  local reg="${1:-$(wf_develop_root)/plans/REGISTRY.md}"
  [ -f "$reg" ] || return 0
  awk -F'|' '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    BEGIN { US = sprintf("%c", 31) }
    {
      id = trim($2)
      if (id !~ /^PLN-[0-9]+$/) next          # header, separator, counter comment
      printf "%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n",
        id, US, trim($3), US, trim($4), US, trim($5), US, trim($6), US,
        trim($7), US, trim($8), US, trim($9), US, trim($10)
    }
  ' "$reg"
}

# ── Artifacts ─────────────────────────────────────────────────────────────

# wf_bug_id <path/to/bug.md> — which bug that file IS. Empty when undecidable.
#
# A bug declares its identity in one place: the `> **ID:** BUG-NNN` header field
# wf-bug-new.sh writes. Every other BUG-NNN token in the file is a bug it TALKS
# ABOUT — a title, a Links line, a Description citing the report it follows on
# from.
#
# wf-list-specable.sh and wf-list-bugs.sh both used to take the first BUG-NNN
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
# wf-bug-new.sh creates `bugs/<stage>/BUG-NNN-<slug>/` and nothing else does.
#
# A disagreement between the two is reported and the declared field wins: the
# field is what wf-bug-consume.sh and wf-bug-close.sh rewrite, so a folder that
# has drifted from it is a rename nobody finished.
wf_bug_id() {
  local bug_md="$1" declared folder
  [ -f "$bug_md" ] || return 0
  declared=$(grep -m1 -E '^[ \t]*>?[ \t]*\*\*ID:\*\*' "$bug_md" 2>/dev/null \
             | grep -oE 'BUG-[0-9]+' | head -1 || true)
  folder=$(basename "$(dirname "$bug_md")" | grep -oE '^BUG-[0-9]+' || true)
  if [ -n "$declared" ] && [ -n "$folder" ] && [ "$declared" != "$folder" ]; then
    echo "wf_bug_id: $bug_md declares $declared but sits in $folder/ — using $declared" >&2
  fi
  printf '%s' "${declared:-$folder}"
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
# they disagreed. wf-progress-count.sh counts only inside `## Steps`; the board
# (wf-list-active.sh) and wf-rehydrate.sh each open-coded a whole-file
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

wf_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Config ────────────────────────────────────────────────────────────────

# wf_cfg <dotted.path> [default]
# Reads a scalar from claude-workflow.yml. Deliberately does NOT require yq —
# the orchestrator must run on a bare client checkout. Handles the nested
# 2-space-indented scalar shape this config uses; not a general YAML parser.
wf_cfg() {
  local path="$1" default="${2:-}" cfg val
  cfg="$(wf_develop_root)/claude-workflow.yml"
  if [ ! -f "$cfg" ]; then printf '%s' "$default"; return 0; fi

  val=$(awk -v path="$path" '
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
        sub(/[ \t]+#.*$/, "", rest)                 # trailing comment
        gsub(/^[ \t]+|[ \t]+$/, "", rest)
        gsub(/^"|"$/, "", rest); gsub(/^'"'"'|'"'"'$/, "", rest)
        print rest; exit
      }
      level++
    }
  ' "$cfg")

  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
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
  cfg="$(wf_develop_root)/claude-workflow.yml"
  [ -f "$cfg" ] || return 0

  awk -v path="$path" '
    BEGIN { n = split(path, want, "."); level = 0; collecting = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2

      if (collecting) {
        if (probe ~ /^- /) {
          item = probe; sub(/^-[ \t]*/, "", item)
          sub(/[ \t]+#.*$/, "", item)
          gsub(/^[ \t]+|[ \t]+$/, "", item)
          gsub(/^"|"$/, "", item); gsub(/^'"'"'|'"'"'$/, "", item)
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

# ── Output ────────────────────────────────────────────────────────────────

# Single-quoted so `eval` survives spaces, semicolons, backticks — the same
# contract wf-plan-info.sh uses (and the reason BUG-094 existed).
wf_emit() {
  printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}

# ── Plan identity ─────────────────────────────────────────────────────────

# wf_plan_fingerprint <PLN-NNN> → hash of that plan's plan.md, or empty.
#
# Used to scope a gate answer to the plan REVISION it was given for: an
# approval is given to a document, not to an ID forever. Lives here because the
# writer (wf-gate-close.sh) and the reader (wf-gate-status.sh) must agree
# exactly — two copies of this would mean a gate that either re-opens forever
# or never re-opens, with nothing to indicate which.
#
# Empty for a BUG/BRF id, or a plan with no folder yet. Callers treat an empty
# fingerprint as "cannot tell", not as "changed".
wf_plan_fingerprint() {
  local id="$1" root slug plan_md
  root="$(wf_develop_root)"
  slug=$(grep "^| $id |" "$root/plans/REGISTRY.md" 2>/dev/null \
         | head -1 | awk -F'|' '{print $3}' | xargs || true)
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
# wf-review-status.sh unable to order the two, and it says so with
# REVIEW_STALE=unknown. wf-spec's replanning gate then reads "REVIEW_STALE must
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
#   - Checkbox state. wf-implement and wf-verify tick `## Verification
#     Checklist` boxes on every cycle, so REVIEW_STALE flipped to true after
#     each one — and wf-spec's replan gate ("REVIEW_STALE must be false") then
#     charged a full architectural review round to re-approve text that was
#     byte-identical to what was reviewed (client-a WFI-095). Marks are
#     normalised, so ticking a criterion is invisible and ADDING one is not.
#   - `### Goal History`. Owned end-to-end by wf-goal-push.sh / wf-goal-pop.sh
#     and explicitly not hand-editable; a pop resolving a row is bookkeeping,
#     not a design change (WFI-092, WFI-093).
#   - `## Consistency`. The cross-plan pass's own done-marker, written by
#     wf-consistency and by nothing else — the template says in so many words
#     not to write it by hand. It lands on every `ready` plan that declares
#     Deps, and it landed AFTER the review stamp, so the consistency pass
#     invalidated the verdict of every plan it touched without one word of the
#     specification changing (client-a WFI-151). When that pass does change
#     a specification it amends the plan body and `## Amendments`, both still
#     hashed — so a real consistency amendment still reads as stale, and only
#     the bookkeeping line stops doing so.
#   - Trailing whitespace, which no reviewer read.
#
# The `## Goal` one-liner stays IN. It is the plan's promise, a scope reduction
# is exactly the kind of change a stale verdict must catch, and the pop that
# rewrites it mechanically is ordered before the stamp for that reason.
wf_plan_body_fingerprint() {
  local id="$1" root slug plan_md
  root="$(wf_develop_root)"
  slug=$(grep "^| $id |" "$root/plans/REGISTRY.md" 2>/dev/null \
         | head -1 | awk -F'|' '{print $3}' | xargs || true)
  [ -n "$slug" ] || return 0
  plan_md="$root/plans/${id}-${slug}/plan.md"
  [ -f "$plan_md" ] || return 0
  awk '
    /^## /  { inside = ($0 ~ /^## (Review|Consistency)([ \t]|$)/) ? 1 : 0 }
    /^### / { hist   = ($0 ~ /^### Goal History([ \t]|$)/) ? 1 : 0 }
    /^## /  { hist = 0 }
    inside || hist { next }
    {
      line = $0
      gsub(/\[[xX]\]/, "[ ]", line)     # a ticked box is not a spec change
      sub(/[ \t]+$/, "", line)
      print line
    }
  ' "$plan_md" | shasum 2>/dev/null | awk '{print $1}' || true
}

# ── The goal stack ────────────────────────────────────────────────────────
#
# Three scripts read and write `### Goal History` — push, pop, amend — and the
# section is a four-column markdown table inside a file full of other
# four-column markdown tables. Locating it by shape rather than by section is
# how a goal push once prepended its row to `## Tests` (fixed in
# wf-goal-push.sh), and how a pop later wrote `~~E2E~~` into `## Goal` and
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
# wf-goal-pop.sh replaces it when it is plain text and refuses when it is not,
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
# /wf-test session claimed a plan, the daemon dispatched an unattended tester
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
# attended /wf-test held a claim, `wf-claim.sh --if-free` from the daemon read
# it as stale seconds later and returned 0, and the unattended tester it
# dispatched destroyed the container the human was testing in and overwrote
# test-progress.md.
#
# No PID-liveness test can be satisfied by walking, so we do not walk when we
# can be told. $CLAUDE_PID is the agent session's own process — it lives
# exactly as long as the session that took the claim, which is precisely the
# lifetime a claim is meant to describe. $WF_SESSION_PID overrides it for
# callers that know better (a daemon claiming on its own behalf).
wf_session_pid() {
  local pid name parent
  if [ -n "${WF_SESSION_PID:-}" ]; then printf '%s' "$WF_SESSION_PID"; return 0; fi
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
# wf-spawn.sh's claim was skipped entirely and `wf-claim.sh BRF-002 --if-free`
# exited 1 with "plan directory not found". Every brief- and bug-sourced spec
# run was therefore unclaimed from spawn until it happened to mkdir the plan
# folder, and two workers in that window both pass --if-free: the exact WFI-067
# race the claim exists to stop (client-c WFI-004).
#
# The claim now hangs off the artifact NUMBER, which is the identity that work
# actually has: the counter is global and one piece of work carries two names
# through spec (BUG-022 → PLN-022, BRF-002 → PLN-002). This is the same key
# wf-spawn.sh's already-running pidfile guard uses, and for the same reason — a
# name-keyed claim cannot see its own other name.
#
# Accepts any of PLN-NNN, PLN-NNN-slug, BUG-NNN, BRF-NNN. Prints nothing and
# returns 1 for a string carrying no artifact id.
wf_claim_dir() {
  local artifact="$1" num d
  num=$(printf '%s' "$artifact" | grep -oE '(PLN|BUG|BRF)-[0-9]+' | head -1 | sed 's/.*-//')
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
# claim as absent and double-book it. Sets WF_CLAIM_AGE and WF_CLAIM_HELD_DIR
# (the directory the live claim was found in) for callers that report on it.
wf_claim_held() {
  local artifact="$1" dir legacy
  WF_CLAIM_HELD_DIR=""
  dir=$(wf_claim_dir "$artifact") || return 1
  if wf_claim_live "$dir"; then WF_CLAIM_HELD_DIR="$dir"; return 0; fi
  legacy="$(wf_develop_root)/plans/${artifact}"
  if [ -d "$legacy" ] && wf_claim_live "$legacy"; then
    WF_CLAIM_HELD_DIR="$legacy"; return 0
  fi
  return 1
}

# wf_claim_write <plan-dir> [pid] — timestamp on line 1, owning PID on line 2.
wf_claim_write() {
  local dir="$1" pid="${2:-}"
  [ -d "$dir" ] || return 1
  [ -n "$pid" ] || pid=$(wf_session_pid)
  printf '%s\n%s\n' "$(date +%s)" "$pid" > "$dir/.wf-claim"
}

# wf_claim_mine <plan-dir> — 0 when the live claim on <plan-dir> belongs to the
# caller's own dispatch rather than to somebody else's session.
#
# wf-spawn.sh claims on the worker's behalf BEFORE launching it (WFI-067: the
# claim belongs to whoever hands out the work, or two workers start inside the
# window between "the dispatcher decided this was free" and "the worker said
# so"). But the worker then opens by asking whether the plan is free, sees the
# claim the dispatcher just wrote naming the worker's own PID, and stands down
# against itself. client-a watched that happen three ways: wf-test exiting
# in 15s reporting "a human is testing" against its own spawn PID (WFI-073,
# WFI-075) and wf-list-implementable.sh reporting an explicitly dispatched plan
# as "processing" (WFI-076). Every plan reaching testing under the daemon
# parked after three no-op dispatches.
#
# Ownership is established two ways, either sufficient:
#   - WF_CLAIM_PID — wf-spawn.sh exports the PID it recorded into the worker's
#     environment, so the worker can name its own claim directly.
#   - ancestry — the claim's PID is a parent, grandparent, … of this process.
#     Covers callers that lost the environment (a nested shell that scrubbed
#     it) and the foreground spawn path, where the claim names wf-spawn.sh
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
  [ -n "${WF_CLAIM_PID:-}" ] && [ "$claim_pid" = "$WF_CLAIM_PID" ] && return 0
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
# Sets WF_CLAIM_AGE (seconds) for callers that report "claimed Nm ago". A claim
# whose PID is gone, or one older than the TTL, is reaped here: a worker killed
# mid-run must not park an artifact forever (WFI-067).
WF_CLAIM_TTL=${WF_CLAIM_TTL:-7200}
wf_claim_live() {
  local dir="$1" f="$1/.wf-claim" ts pid
  WF_CLAIM_AGE=0
  [ -f "$f" ] || return 1
  ts=$(sed -n '1p' "$f" 2>/dev/null | tr -cd '0-9')
  pid=$(sed -n '2p' "$f" 2>/dev/null | tr -cd '0-9')
  [ -n "$ts" ] || ts=0
  WF_CLAIM_AGE=$(( $(date +%s) - ts ))
  if [ "$WF_CLAIM_AGE" -lt "$WF_CLAIM_TTL" ]; then
    # No PID is the pre-v5.1 format: the TTL alone decides.
    [ -z "$pid" ] && return 0
    kill -0 "$pid" 2>/dev/null && return 0
  fi
  rm -f "$f"
  return 1
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
