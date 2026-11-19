#!/usr/bin/env bash
# lv-issue.sh — record a problem with the WORKFLOW HARNESS ITSELF.
#
# This is not for application bugs (that's /lv-bug) and not for plan findings
# (that's findings.md). It is for the pipeline misbehaving: a lv-* script that
# errored unexpectedly, a skill instruction that referenced something that
# doesn't exist, a registry state that contradicts reality, a plan that looped.
#
# Entries land in WORKFLOW-ISSUES.md at the DEVELOP ROOT of this client, so a
# worker inside a feature worktree still files to the one place per project.
# The Levain library sweeps every client periodically (sweep-issues.sh)
# and fixes the underlying process bugs upstream.
#
# FILE AN ISSUE
#   lv-issue.sh --source lv-implement \
#               --expected "lv-registry-update.sh active→verify to succeed" \
#               --actual   "Error: PLN-097 not found in state 'active'" \
#               [--context "PLN-097, worktree feature/PLN-097-foo"] \
#               [--notes   "registry already showed verify"]
#
# READ THEM BACK
#   lv-issue.sh --list            open issues, newest first
#   lv-issue.sh --list --all      including resolved
#   lv-issue.sh --count           number of open issues (stdout, for scripts)
#   lv-issue.sh --resolve LVI-003 "fixed in workflow v2.6.0"
#
# The prefix comes from the ID map (lv-ids.sh, kind `issue`): LVI by default,
# WFI before 14.0.0. Every accepted prefix shares one sequence, and --resolve
# takes any of them for any entry.
#
# Deliberately non-interactive: an unattended worker must be able to file one
# and carry on. Never prompts, never blocks, never fails the caller — filing a
# report must not be able to break the run that hit the problem.
#
# A filing or a --resolve is committed (WORKFLOW-ISSUES.md only) where it is
# written; one that cannot be committed is kept, with a warning (LVI-060).
#
# Exit 0 on success. Exit 1 only on genuinely bad usage.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"
# shellcheck source=lv-lock.sh
source "$SELF_DIR/lv-lock.sh"
# shellcheck source=lv-ids.sh
source "$SELF_DIR/lv-ids.sh"

ISSUE_PREFIX=$(lv_id_prefix issue)
ISSUE_MATCH=$(lv_id_match issue)

ROOT="$(wf_develop_root)"
ISSUES="$ROOT/WORKFLOW-ISSUES.md"

# commit_issues <subject> — commit WORKFLOW-ISSUES.md where it was written.
#
# A filing used to stay uncommitted until /lv-deploy step 12 swept it up, so the
# file collected entries between deploys, a coordinator (which never deploys)
# never committed its own at all, and every session found it already dirty and
# left it for someone else (the coordinator's LVI-060). The file is append-only
# reports, so committing whatever else is pending in it is correct. Pathspec
# only (lv-commit.sh), on whatever branch the root is on, never moving it.
# Anything that refuses (no repo, file ignored, a lock, a hook) keeps the entry
# and warns: a filing must never be lost or fail its caller. LV_ISSUE_NO_COMMIT=1
# skips it. /lv-deploy step 12 stays as the backstop.
commit_issues() {
  [ "${LV_ISSUE_NO_COMMIT:-}" = 1 ] && return 0
  ( cd "$ROOT" 2>/dev/null || exit 0
    git rev-parse --git-dir >/dev/null 2>&1 || exit 0
    git check-ignore -q WORKFLOW-ISSUES.md 2>/dev/null && exit 0
    out=$("$SELF_DIR/lv-commit.sh" "$1" --add WORKFLOW-ISSUES.md 2>&1) || {
      echo "lv-issue.sh: written, but not committed — commit WORKFLOW-ISSUES.md by hand:" >&2
      printf '%s\n' "$out" | sed 's/^/  /' >&2
    }
  ) || true
  return 0
}

HEADER='# Workflow Issues

Problems with the **workflow harness itself** — a `lv-*` script, a skill
instruction, or the pipeline behaving in a way its own documentation does not
describe.

**This is not for application bugs** (use `/lv-bug`) and not for plan findings
(those go in the plan'"'"'s `findings.md`). It is for the tooling being wrong.

File one with:

```bash
scripts/lv-exec.sh lv-issue.sh --source <skill-or-script> \
  --expected "<what the docs say should happen>" \
  --actual   "<what happened, verbatim>"
```

These are swept into the Levain library periodically and fixed
upstream, so an entry here becomes a fix for every project using the workflow.
Leave resolved entries in place — they are the record of what was already
reported.

<!-- New entries are inserted directly below this line, newest first. -->
'

ensure_file() {
  [ -f "$ISSUES" ] || printf '%s\n' "$HEADER" > "$ISSUES"
}

# ── Read modes ────────────────────────────────────────────────────────────

case "${1:-}" in
  --list)
    ensure_file
    # Split on the issue heading so each record is one whole block, then filter
    # by its own Status line. RS='\n## ' means record 1 is the file header.
    if [ "${2:-}" = "--all" ]; then
      awk -v RS='\n## ' 'NR > 1 { print "## " $0 }' "$ISSUES"
    else
      awk -v RS='\n## ' 'NR > 1 && /\*\*Status:\*\* *open/ { print "## " $0 }' "$ISSUES"
    fi
    exit 0
    ;;
  --count)
    ensure_file
    # grep -c prints 0 AND exits 1 when there are no matches, so a `|| echo 0`
    # fallback would emit two lines. Capture, then print exactly once.
    n=$(grep -c '^\*\*Status:\*\* *open' "$ISSUES" 2>/dev/null)
    printf '%s\n' "${n:-0}"
    exit 0
    ;;
  --resolve)
    id="${2:?Usage: $0 --resolve <LVI-NNN> [note]}"
    # Any accepted prefix names the entry: LVI-012 finds a WFI-012 and back.
    if ! grep -q "^## $id " "$ISSUES" 2>/dev/null; then
      for alt in $(lv_id_prefixes issue); do
        grep -q "^## $alt-${id#*-} " "$ISSUES" 2>/dev/null && { id="$alt-${id#*-}"; break; }
      done
    fi
    # Flattened: this goes through awk -v, which cannot carry newlines.
    note=$(printf '%s' "${3:-resolved}" | tr '\n' ' ')
    ensure_file
    wf_lock_acquire "workflow-issues" || exit 0

    # An entry is resolved once. Re-resolving overwrote the original date and
    # the version that actually carried the fix with whatever the second caller
    # believed — a silent rewrite of the record this file exists to be. Refuse,
    # and say what is already there. (Exit 0: nothing is wrong, there is just
    # nothing to do.)
    existing=$(awk -v id="$id" '
      $0 ~ "^## " id " " { inblock = 1; next }
      inblock && /^\*\*Status:\*\*/ { sub(/^\*\*Status:\*\* */, ""); print; exit }
    ' "$ISSUES")
    case "$existing" in
      resolved*)
        echo "$id: already $existing — not overwriting" >&2
        exit 0
        ;;
    esac

    awk -v id="$id" -v note="$note" -v today="$(wf_today)" '
      $0 ~ "^## " id " " { inblock = 1 }
      inblock && /^\*\*Status:\*\*/ {
        print "**Status:** resolved " today " — " note
        inblock = 0; next
      }
      { print }
    ' "$ISSUES" > "$ISSUES.tmp" && mv "$ISSUES.tmp" "$ISSUES"
    wf_lock_release "workflow-issues" 2>/dev/null || true
    commit_issues "issue(WORKFLOW-ISSUES): $id resolved"
    echo "$id: resolved — $note"
    exit 0
    ;;
esac

# ── File mode ─────────────────────────────────────────────────────────────

source_name=""
expected=""
actual=""
context=""
notes=""

while [ $# -gt 0 ]; do
  case "$1" in
    --source)   source_name="${2:-}"; shift 2 ;;
    --expected) expected="${2:-}"; shift 2 ;;
    --actual)   actual="${2:-}"; shift 2 ;;
    --context)  context="${2:-}"; shift 2 ;;
    --notes)    notes="${2:-}"; shift 2 ;;
    -h|--help)  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "lv-issue.sh: unknown option '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$source_name" ] || [ -z "$actual" ]; then
  echo "Usage: $0 --source <skill-or-script> --expected <text> --actual <text> [--context <text>] [--notes <text>]" >&2
  echo "       $0 --list [--all] | --count | --resolve <LVI-NNN> [note]" >&2
  exit 1
fi
[ -n "$expected" ] || expected="(not stated)"

ensure_file

# ── Body text may not impersonate entry structure ──────────────────────────
#
# The most natural evidence to paste into a report about the workflow is the
# workflow's own files — and for an issue about issue-filing, that is this
# file. client-a's WFI-065 carries a diff of WORKFLOW-ISSUES.md in its
# Actual block, so its body holds three `+**Status:** open` lines; the sweep
# read the entry as open and printed a RESOLVED issue under a client that had
# none. A diff pasted without its `+` prefixes is worse: `## WFI-064` at column
# one splits the record and steals the next-ID lookup.
#
# One leading space is enough to settle it — every marker this file's readers
# key on is line-anchored, and inside a fenced block the indent is invisible to
# anyone reading the entry.
neutralise() {
  printf '%s' "$1" | sed -E -e "s/^(## ($ISSUE_MATCH)-)/ \\1/" \
                            -e 's/^(\*\*Status:\*\*)/ \1/' \
                            -e 's/^(<!-- New entries)/ \1/'
}
expected=$(neutralise "$expected")
actual=$(neutralise "$actual")
notes=$(neutralise "$notes")
context=$(neutralise "$context")

# Serialize appends — several workers can hit the same harness bug at once.
wf_lock_acquire "workflow-issues" || exit 0

# Next ID: one more than the highest already present.
# 10# forces base 10 — the IDs are zero-padded, so bash reads 008 and 009 as
# octal and errors out, leaving $next empty and the heading without an ID.
# Every accepted prefix counts, so a renamed prefix carries the numbering on.
last=$(grep -oE "^## ($ISSUE_MATCH)-[0-9]+" "$ISSUES" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1)
next=$(printf '%s-%03d' "$ISSUE_PREFIX" "$(( 10#${last:-0} + 1 ))")

wf_version=$(tr -d '[:space:]' < "$ROOT/.claude/workflow-version" 2>/dev/null || echo "unknown")

entry=$(cat <<ENTRY

## $next — $source_name — $(wf_now)

**Status:** open
**Workflow version:** $wf_version
**Context:** ${context:-—}

**Expected:**
$expected

**Actual:**
\`\`\`
$actual
\`\`\`
ENTRY
)
[ -n "$notes" ] && entry="$entry

**Notes:**
$notes"

# Insert directly after the marker so newest is first and the header survives.
# Done with head/tail rather than awk -v: awk cannot carry a multi-line value
# through -v (it dies with "newline in string"), and a captured error message
# is very often multi-line — which is exactly the case worth recording.
marker='<!-- New entries are inserted directly below this line, newest first. -->'
marker_line=$(grep -nF "$marker" "$ISSUES" 2>/dev/null | head -1 | cut -d: -f1)
if [ -n "$marker_line" ]; then
  {
    head -n "$marker_line" "$ISSUES"
    printf '%s\n' "$entry"
    tail -n +"$((marker_line + 1))" "$ISSUES"
  } > "$ISSUES.tmp" && mv "$ISSUES.tmp" "$ISSUES"
else
  printf '%s\n' "$entry" >> "$ISSUES"
fi

# The lock is released first: lv-commit.sh takes the commit lock, and a caller
# already holding that one may be filing too.
wf_lock_release "workflow-issues" 2>/dev/null || true
commit_issues "issue(WORKFLOW-ISSUES): $next $source_name"

wf_event issue "${context:-—}" "$next: $source_name — $expected"
echo "$next filed in WORKFLOW-ISSUES.md ($source_name)"
exit 0
