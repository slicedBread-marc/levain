#!/usr/bin/env bash
# board-drill.sh — the lv-tray-drill.sh output contract.
#
# The board says a project has 1 running worker and 3 plans in `active`;
# lv-tray-drill.sh says WHICH, and each of its lines carries the argv that
# opens the next level down. coordinator' lv-rack walks those lines blind — it
# holds no model of a plan, a gate or a log — so the contract is the whole
# integration:
#
#   <display>\tlist|log|file|text|none\t<argv-or-path>      exactly 3 fields
#   exit 1 for a list node with nothing in it, 2 for a node that doesn't exist
#
# A fourth field, or a display carrying a tab, silently shifts the target into
# the wrong variable on the other side and hands the reader a dead item — and
# display text is free prose (a brief's INDEX.md blurb runs to paragraphs), so
# that is a live risk, not a theoretical one.
#
# Usage: ./tests/tray-drill.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DRILL="$REPO_ROOT/scripts/v2.00/lv-tray-drill.sh"
TEST_DIR=""
SLEEPER=""
PASS=0
FAIL=0

cleanup() {
  [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
  return 0
}
trap cleanup EXIT

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }

assert_contains() { # <label> <haystack> <needle>
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "expected to contain: $3" ;; esac
}
assert_eq() { # <label> <expected> <actual>
  [ "$2" = "$3" ] && { pass "$1"; return; }
  fail "$1" "expected [$2], got [$3]"
}

# assert_shape <label> <output> — every line has exactly three tab-separated
# fields and a kind from the closed vocabulary.
assert_shape() {
  local label="$1" out="$2" bad=""
  local line n kind
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
    [ "$n" = "3" ] || { bad="field count $n: $line"; break; }
    kind=$(printf '%s' "$line" | cut -f2)
    case "$kind" in
      list|log|file|text|none) ;;
      *) bad="unknown kind '$kind': $line"; break ;;
    esac
  done <<< "$out"
  [ -z "$bad" ] && pass "$label" || fail "$label" "$bad"
}

# ── Fixture ─────────────────────────────────────────────────────────────
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lv-tray-drill.XXXXXX")
cd "$TEST_DIR" || exit 1
git init -q .
git config user.email t@t; git config user.name t

mkdir -p plans/PLN-001-alpha plans/briefs .claude/orchestrator/logs
cat > plans/REGISTRY.md <<'EOF'
# Plan Registry

<!-- Counter: 3 -->

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-001 | alpha | active | high | feature/PLN-001-alpha | 2026-09-17 | 9.4.0 | infra | — |
| PLN-002 | beta | complete | — | — | 2026-09-16 | 9.4.0 | — | PLN-001 |
EOF
printf '# PLN-001\n' > plans/PLN-001-alpha/plan.md
cat > plans/PLN-001-alpha/progress.md <<'EOF'
# Progress

## Steps
- [x] Step 1: the first thing
- [ ] Step 2: the second thing
EOF
printf 'a log line\nTHE-LAST-LINE\n' > .claude/orchestrator/logs/PLN-001-implement-20260917-120000.log
printf '2026-09-17T12:00:00Z\tspawn\tPLN-001\timplement (sonnet) pid 1\n' > .claude/orchestrator/events.log
git add -A >/dev/null 2>&1
git commit -qm init >/dev/null 2>&1

# A live worker: a real process whose pid sits in the usual pidfile, keyed on
# the artifact NUMBER the way lv-spawn.sh writes it.
sleep 120 & SLEEPER=$!
# Disowned so the shell doesn't print a "Terminated" job notice over the
# results when cleanup kills it.
disown "$SLEEPER" 2>/dev/null || true
echo "$SLEEPER" > .claude/orchestrator/logs/1-implement.pid

echo "lv-tray-drill.sh contract"

# ── running ─────────────────────────────────────────────────────────────
out=$("$DRILL" row running); rc=$?
assert_eq       "row running exits 0 with a live worker" 0 "$rc"
assert_shape    "row running lines are well shaped" "$out"
assert_contains "row running names the artifact" "$out" "PLN-001"
assert_contains "row running descends to the worker" "$out" "$(printf '\tlist\tworker 1-implement PLN-001')"

# A pidfile carries whatever digits the spawning id had — `001` from PLN-001
# — so the registry lookup has to match on the number's VALUE. A string
# compare finds nothing here and names the worker after a plan that doesn't
# exist.
mv .claude/orchestrator/logs/1-implement.pid .claude/orchestrator/logs/001-implement.pid
out=$("$DRILL" row running)
assert_contains "a zero-padded pidfile still resolves its plan" "$out" "PLN-001"
mv .claude/orchestrator/logs/001-implement.pid .claude/orchestrator/logs/1-implement.pid

# ── an empty row, and an unknown one ────────────────────────────────────
out=$("$DRILL" row draft); rc=$?
assert_eq "an empty row exits 1" 1 "$rc"
assert_eq "an empty row prints nothing" "" "$out"

"$DRILL" row nonsense >/dev/null 2>&1
assert_eq "an unknown row exits 2" 2 "$?"
"$DRILL" nonsense >/dev/null 2>&1
assert_eq "an unknown node exits 2" 2 "$?"

# ── state rows come from the registry ───────────────────────────────────
out=$("$DRILL" row active)
assert_shape    "row active lines are well shaped" "$out"
assert_contains "row active lists the active plan" "$out" "PLN-001"
assert_contains "row active descends to the artifact" "$out" "$(printf '\tlist\tartifact PLN-001')"
out=$("$DRILL" row complete)
assert_contains "row complete lists the complete plan" "$out" "PLN-002"

# ── one artifact: its files, its logs, its summary ──────────────────────
out=$("$DRILL" artifact PLN-001)
assert_shape    "artifact lines are well shaped" "$out"
assert_contains "artifact offers plan.md as a file" "$out" "$(printf '\tfile\t')"
assert_contains "artifact points at the real plan.md" "$out" "plans/PLN-001-alpha/plan.md"
assert_contains "artifact offers its logs"  "$out" "$(printf '\tlist\tlogs PLN-001')"
assert_contains "artifact offers a summary" "$out" "$(printf '\ttext\tsummary PLN-001')"

out=$("$DRILL" logs PLN-001)
assert_shape    "logs lines are well shaped" "$out"
assert_contains "logs offers the log file" "$out" "$(printf '\tlog\t')"
logpath=$(printf '%s' "$out" | head -1 | cut -f3)
[ -f "$logpath" ] && pass "the log target is a real file" \
                  || fail "the log target is a real file" "got [$logpath]"

# ── worker: the live log first, then everything else about the plan ─────
out=$("$DRILL" worker 1-implement PLN-001)
assert_shape    "worker lines are well shaped" "$out"
assert_contains "worker offers the live log" "$out" "$(printf '\tlog\t')"
assert_contains "worker descends to the artifact" "$out" "$(printf '\tlist\tartifact PLN-001')"

# ── bodies ──────────────────────────────────────────────────────────────
out=$("$DRILL" summary PLN-001)
assert_contains "summary reports the state"   "$out" "active"
assert_contains "summary reports the slug"    "$out" "alpha"
assert_contains "summary counts the steps"    "$out" "1/2"
assert_contains "summary shows the checklist" "$out" "Step 2: the second thing"

out=$("$DRILL" events PLN-001)
assert_contains "events finds the artifact's line" "$out" "implement (sonnet)"

# ── a display carrying prose never breaks the field shape ───────────────
# A brief's INDEX.md blurb is free text — tabs, newlines, paragraphs — and it
# is rendered as a display field. Flattening happens once, in emit().
cat > plans/briefs/INDEX.md <<'EOF'
# Briefs

## Idea

- [BRF-003](BRF-003-wide.md) — a blurb with	a tab in it
EOF
printf '# BRF-003\n\n**Status:** Idea\n' > plans/briefs/BRF-003-wide.md
out=$("$DRILL" row ideas)
assert_shape    "an idea's prose blurb keeps the 3-field shape" "$out"
assert_contains "an idea points at its brief file" "$out" "BRF-003-wide.md"

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
