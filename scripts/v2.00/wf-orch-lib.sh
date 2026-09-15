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
#   wf_registry_field <id> <col>     → one trimmed field of one plan's row
#   wf_state_of <id>                 → one plan's REGISTRY state, PLN-alias aware
#   wf_bug_id <bug.md>               → the bug that file declares itself to be
#   wf_goal_text <plan.md>           → that plan's one-line goal
#   wf_cfg <dotted.path> [default]   → value from claude-workflow.yml
#   wf_emit <KEY> <value>            → eval-safe KEY='value' line
#   wf_gate_field <file> <KEY> [--unescape] → one field of a gate file
#   wf_restore_harness               → re-copy the gitignored runtime files after a merge
#   wf_plan_fingerprint <PLN-NNN>    → hash of that plan's plan.md (may be empty)
#   wf_session_pid                   → PID of the long-lived session, not the shell
#   wf_artifacts_with_number <num>   → "<PREFIX> <where>" per artifact using it
#   wf_claim_dir <artifact>          → the directory that holds this artifact's claim
#   wf_claim_write <dir> [pid] [artifact] → write <dir>/.wf-claim
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
  local id="$1" reg="${2:-$(wf_develop_root)/plans/REGISTRY.md}" s alt
  if [ "$_WF_STATE_MAP_REG" != "$reg" ]; then
    _WF_STATE_MAP=""
    if [ -f "$reg" ]; then
      _WF_STATE_MAP=" $(awk -F'|' '
        function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
        { i = trim($2); if (i ~ /^(PLN|BUG|BRF)-[0-9]+$/) printf "%s=%s ", i, trim($4) }
      ' "$reg")"
    fi
    _WF_STATE_MAP_REG="$reg"
  fi
  [ -n "$_WF_STATE_MAP" ] || { printf '—'; return 0; }
  s="${_WF_STATE_MAP##* $id=}"
  [ "$s" != "$_WF_STATE_MAP" ] || s=""
  s="${s%% *}"
  if [ -z "$s" ]; then
    alt="${_WF_STATE_MAP##* PLN-${id#*-}=}"
    [ "$alt" = "$_WF_STATE_MAP" ] || s="${alt%% *}"
  fi
  printf '%s' "${s:-—}"
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
          print "wf_cfg: " path " uses YAML block-scalar syntax which claude-workflow.yml cannot express (scalars only, one line per key) -- flatten it to a single line using a semicolon as the statement separator. Treating it as unset." > "/dev/stderr"
          exit
        }
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

# ── Harness ───────────────────────────────────────────────────────────────

# wf_restore_harness — put the gitignored runtime files back after a merge.
#
# A branch cut before the v5.0.0 untrack commit still TRACKS
# .claude/skills/wf-*, .claude/workflow.md and scripts/wf-exec.sh; merging one
# that has already taken the migration DELETES them from this worktree, and
# they are gitignored afterwards, so nothing puts them back on its own
# (client-c WFI-006). In a feature worktree the main worktree still has
# the files, so copying is enough — and copying is all that is wanted: a
# worktree needs only the three paths wf-worktree-harness.sh delivers,
# because wf-exec.sh resolves scripts/v*/ from the main worktree. Reaching
# into git history there would put a stale TRACKED copy back on a branch that
# no longer wants one.
#
# The main worktree is the case with nowhere to copy from — client-c lost
# the harness outright on the release side (WFI-006) — so only there does the
# wf-harness-restore.sh fallback apply.
#
# Was two byte-identical copies (wf-merge-develop.sh, wf-merge-release.sh);
# a fix to one silently didn't reach the other. Resolved via BASH_SOURCE, not
# the caller's $0: both call sites already used $0 to reach these same
# scripts, which happened to work because both live next to this library, but
# a shared function looking up ITS OWN directory doesn't depend on that
# coincidence holding at every future call site.
wf_restore_harness() {
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  "$dir/wf-worktree-harness.sh" . >/dev/null 2>&1 || true
  local main_wt
  main_wt=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  [ -n "$main_wt" ] && [ "$main_wt" = "$(git rev-parse --show-toplevel 2>/dev/null)" ] || return 0
  [ -x scripts/wf-exec.sh ] && [ -f scripts/version-map.txt ] && return 0
  "$dir/wf-harness-restore.sh" >/dev/null 2>&1 || true
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
  slug=$(wf_registry_field "$id" slug "$root/plans/REGISTRY.md")
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

# ── Reading a review verdict ──────────────────────────────────────────────
#
# ONE PARSER, BECAUSE FOUR SCRIPTS TOUCH THIS SECTION
#
# `## Review` is written by hand, by whatever session ran the review, and read
# back by wf-review-status.sh, wf-review-stamp.sh and wf-manual-lint.sh. When
# each carried its own idea of what a verdict looks like, a plan could pass
# every writer and fail the one reader that mattered.
#
# client-a's PLN-209: a prose review section (`### Round 1 — 2026-08-20 —
# **Approved with notes**`, no blockquote, no `Result:` line) was linted clean
# twice, stamped with a Plan-Hash, and then reported by wf-review-status.sh as
# REVIEW_LOCATION='none', REVIEW_STAMPED='false' — the row /wf-attend renders
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
# the wf-review-stamp comment are scaffolding, not content.
# Is there a REVIEW here, or only the template's placeholder?
#
# The menu line and the stamp hint were filtered; the rest of TEMPLATE.md's
# `## Review` block was not, so a plan.md written verbatim from the template
# the wf-spec skill tells planners to follow counted as "a review is written
# here" and failed wf-manual-lint.sh with `unreadable-review` — every brand-new
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
    | grep -v 'wf-review-stamp' \
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

# wf_artifacts_with_number <num> — every artifact in this project carrying that
# number, one "<PREFIX> <where>" line each. Empty when the number is unused.
#
# ONE definition of "is this number in use", because there were two and they
# disagreed. wf-counter-next.sh derives its high-water mark from the registry
# plus `plans/*/`, `bugs/*/*/` and `plans/briefs/*`; wf-plan-id.sh's collision
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
    awk -F'|' -v want="$want" '
      function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
      {
        id = trim($2)
        if (id !~ /^(PLN|BUG|BRF)-[0-9]+$/) next
        split(id, p, "-")
        if (p[2] + 0 == want) printf "%s REGISTRY row %s\n", p[1], id
      }
    ' "$reg"
  fi

  for f in "$root"/plans/PLN-*/ "$root"/bugs/*/BUG-*/ "$root"/plans/briefs/BRF-*.md; do
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
wf_claim_write() {
  local dir="$1" pid="${2:-}" artifact="${3:-}"
  [ -d "$dir" ] || return 1
  [ -n "$pid" ] || pid=$(wf_session_pid)
  printf '%s\n%s\n%s\n' "$(date +%s)" "$pid" "$artifact" > "$dir/.wf-claim"
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
# client-a's BRF-161 (WFI-187): wf-spec opened `spec-approval` on the plan it
# had just written, producing `gates/PLN-161.gate`. The dispatcher's skip check
# asked `wf-list-gates.sh BRF-161` — the name it had dispatched under — found no
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
    *) id=$(printf '%s' "$artifact" | grep -oE '(PLN|BUG|BRF)-[0-9]+' | head -1) ;;
  esac
  [ -n "$id" ] || return 1
  dir="$(wf_orch_dir)/gates"
  exact="$dir/${id}.gate"
  if [ -f "$exact" ]; then printf '%s' "$exact"; return 0; fi
  case "$id" in RELEASE|DEPLOY) return 1 ;; esac

  num=$((10#${id##*-}))
  for f in "$dir"/*.gate; do
    [ -f "$f" ] || continue
    fid=$(basename "$f" .gate)
    case "$fid" in PLN-*|BUG-*|BRF-*) ;; *) continue ;; esac
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
  id=$(printf '%s' "$artifact" | grep -oE '(PLN|BUG|BRF)-[0-9]+' | head -1)
  [ -n "$id" ] || return 1
  dir="$(wf_orch_dir)/gates/resolved"
  exact="$dir/${id}.${gate}"
  if [ -f "$exact" ]; then printf '%s' "$exact"; return 0; fi

  num=$((10#${id##*-}))
  for f in "$dir"/*."$gate"; do
    [ -f "$f" ] || continue
    case "$f" in *.log) continue ;; esac
    base=$(basename "$f")
    base="${base%".$gate"}"
    case "$base" in PLN-*|BUG-*|BRF-*) ;; *) continue ;; esac
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
# wf-gate-status.sh still reported GATE_ANSWERED=true, GATE_STALE=false
# (WFI-180). Transcribing the resolution into findings.md did not stop it
# (WFI-181), and it re-opened a fourth time thirty minutes after the decision
# was committed (WFI-182) — by then having RE-DERIVED the question, offering an
# option the human never authorized and describing a data structure that had
# changed two merges earlier. A re-asked question does not come back the same,
# which is what makes the loop worse than merely wasteful.
WF_GATE_REVISION_SCOPED="${WF_GATE_REVISION_SCOPED:-spec-approval prior-work scope-reduction goal-missing migration consistency-migration branch-exists spec-stuck}"
wf_gate_revision_scoped() {
  local name="${1:-}" g
  [ -n "$name" ] || return 1
  for g in $WF_GATE_REVISION_SCOPED; do
    [ "$g" = "$name" ] && return 0
  done
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
