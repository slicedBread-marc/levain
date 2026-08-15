#!/usr/bin/env bash
# rehydrate.sh — tests for wf-rehydrate.sh, the post-compaction state producer.
#
# The two things that must hold:
#
#   1. `--hook session-start` emits ONE line of valid JSON carrying the state
#      block as additionalContext. That JSON is parsed by the harness; a stray
#      newline, an unescaped quote or a raw tab from a plan's Goal line makes it
#      unparseable, and the hook silently contributes nothing — the exact
#      failure this whole mechanism exists to prevent, arriving quietly.
#
#   2. Nothing in flight emits NOTHING. A repo between plans must not pay tokens
#      on every compaction to be told the pipeline is empty.
#
# Usage: ./tests/rehydrate.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS="$REPO_ROOT/scripts/v2.00"
TEST_DIR=""
PASS=0
FAIL=0

cleanup() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
  return 0
}
trap cleanup EXIT

ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }

assert_contains() {
  local label="$1" needle="$2" hay="$3"
  case "$hay" in *"$needle"*) ok "$label" ;; *) bad "$label" "missing: [$needle]" ;; esac
}

assert_empty() {
  local label="$1" actual="$2"
  if [ -z "$actual" ]; then ok "$label"; else bad "$label" "got: [$actual]"; fi
}

# Valid JSON, and additionalContext round-trips to the original text.
assert_json_roundtrip() {
  local label="$1" json="$2" needle="$3"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "  ~ $label (skipped: no python3)"; return 0
  fi
  local got
  got=$(printf '%s' "$json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
sys.stdout.write(d["hookSpecificOutput"]["additionalContext"])
' 2>&1)
  if [ $? -ne 0 ]; then bad "$label" "unparseable: $got"; return 0; fi
  case "$got" in *"$needle"*) ok "$label" ;; *) bad "$label" "decoded text missing: [$needle]" ;; esac
}

seed_repo() {
  TEST_DIR=$(mktemp -d)
  cd "$TEST_DIR" || exit 1
  git init -q . 2>/dev/null
  mkdir -p plans/PLN-041-relay-hardening .claude/orchestrator/gates .claude/orchestrator/claims

  cat > plans/REGISTRY.md << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-041 | relay-hardening | active | P1 | feature/PLN-041-relay-hardening | 2026-08-08 | 2.00 | security | — |
| PLN-030 | old-thing | complete | P3 | — | 2026-07-01 | 2.00 | — | — |

<!-- Counter: 41 -->
SEED

  # A Goal carrying every JSON hazard at once: a double quote, a backslash, an
  # apostrophe and a tab. If escaping is wrong, this is the line that breaks it.
  printf '# Relay\n\n## Goal\nHarden the "relay"\\path;\tdon'"'"'t widen scope\n\n## Amendments\n[2026-08-07] — narrowed to answer-only\n' \
    > plans/PLN-041-relay-hardening/plan.md

  cat > plans/PLN-041-relay-hardening/progress.md << 'SEED'
# Progress — Relay

## Steps
- [x] Step 1: schema
- [ ] Step 2: guard
- [ ] Step 3: tests

## Log
[2026-08-08] Step 1 — done
SEED
}

echo "── wf-rehydrate.sh ──"
seed_repo

# 1. Plain mode from the develop root: the pipeline, terminals excluded.
OUT=$("$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
assert_contains "pipeline lists the active plan"   "PLN-041"  "$OUT"
assert_contains "pipeline shows step progress"     "step 1/3" "$OUT"

# A plan with NO ticked steps — the common case, and the one that broke.
# `grep -c || echo 0` emits two lines on no match, rendering "step 0\n0/3".
sed -i.bak 's/^- \[x\] Step 1/- [ ] Step 1/' plans/PLN-041-relay-hardening/progress.md
OUT=$("$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
assert_contains "zero ticked steps render on one line" "step 0/3" "$OUT"
N=$(printf '%s' "$OUT" | grep -c "PLN-041")
[ "$N" = "1" ] && ok "pipeline row is a single line" || bad "pipeline row is a single line" "lines=$N"
mv plans/PLN-041-relay-hardening/progress.md.bak plans/PLN-041-relay-hardening/progress.md
if printf '%s' "$OUT" | grep -q "PLN-030"; then
  bad "terminal plans excluded" "PLN-030 (complete) appeared"
else
  ok "terminal plans excluded"
fi

# 2. SessionStart mode: one line, valid JSON, hazardous text survives escaping.
JSON=$(printf '{"hook_event_name":"SessionStart","source":"compact"}' \
  | "$SCRIPTS/wf-rehydrate.sh" --hook session-start 2>/dev/null)
LINES=$(printf '%s' "$JSON" | wc -l | tr -d ' ')
if [ "$LINES" = "0" ]; then ok "JSON is a single line"; else bad "JSON is a single line" "$LINES newlines"; fi
assert_contains "declares the hook event" '"hookEventName":"SessionStart"' "$JSON"
assert_json_roundtrip "JSON parses and carries the state" "$JSON" "PLN-041"
assert_json_roundtrip "compaction source named in the block" "$JSON" "after compact"

# 3. Inside a feature worktree, .plan-ref selects one plan and its steps.
mkdir -p wt && echo "PLN-041" > wt/.plan-ref
OUT=$(cd wt && "$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
assert_contains "plan detail resolved from .plan-ref" "PLAN:     PLN-041-relay-hardening" "$OUT"
assert_contains "live Steps checklist included"       "[ ] Step 2: guard"                 "$OUT"
assert_contains "amendment surfaced"                  "AMENDMENTS: 1 amendment(s)"        "$OUT"

# 3a. The block is a snapshot and has to say so (WFI-099). An old block survives
# into the next summary word for word; without a timestamp and a scoped
# precedence claim, an hour-old STATE line outranks a script run seconds ago.
OUT=$("$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
if printf '%s' "$OUT" | grep -qE 'read from disk at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z'; then
  ok "the block stamps when it was read"
else
  bad "the block stamps when it was read" "no ISO-8601 stamp in the header"
fi
assert_contains "precedence is over the summary, not over everything" \
  "Where the summary disagrees, these values win" "$OUT"
assert_contains "says it does not outrank a later script run" "SNAPSHOT, not a subscription" "$OUT"
assert_contains "an older block is explicitly superseded" "superseded" "$OUT"
if printf '%s' "$OUT" | grep -q "read from disk just now"; then
  bad "no unqualified freshness claim" "'just now' still present"
else
  ok "no unqualified freshness claim"
fi

# 3b. The feature worktree's absolute path, because cwd does not survive a
# compaction (WFI-098) — a relative read from the wrong root looks exactly like
# a broken feature.
git -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -c user.email=t@t -c user.name=t commit -qm seed >/dev/null 2>&1
git worktree add -q -b feature/PLN-041-relay-hardening "$TEST_DIR/feature-branches/PLN-041" >/dev/null 2>&1
echo "PLN-041" > "$TEST_DIR/feature-branches/PLN-041/.plan-ref"
OUT=$(cd wt && "$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
# git reports the resolved path; on macOS $TMPDIR is a symlink (/var → /private/var).
WT_REAL=$(cd "$TEST_DIR/feature-branches/PLN-041" && pwd -P)
assert_contains "the plan's worktree path is restated absolute" \
  "WORKTREE: $WT_REAL" "$OUT"
assert_contains "and says the working directory did not survive" \
  "did not survive the compaction" "$OUT"

# 4. An open gate is not something a rehydrated worker may walk past.
printf "GATE_NAME='contract'\n" > .claude/orchestrator/gates/PLN-041.gate
OUT=$(cd wt && "$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
assert_contains "open gate surfaced" "GATE OPEN: contract" "$OUT"
rm -f .claude/orchestrator/gates/PLN-041.gate

# 5. A stale .plan-ref must not be presented as the session's current work.
#
# .plan-ref is not cleaned up when a branch merges, so develop roots accumulate
# one naming the last plan built there — three of five clients had exactly this
# when the guard was written, all pointing at `complete` plans. Presenting one
# is worse than no rehydration: it hands the session a finished plan, complete
# with a step checklist, inside a block that says "these values win".
echo "PLN-030" > .plan-ref            # complete, per the seeded registry
OUT=$("$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
if printf '%s' "$OUT" | grep -q "^PLAN: *PLN-030"; then
  bad "terminal .plan-ref not presented as current work" "PLN-030 shown as the plan"
else
  ok "terminal .plan-ref not presented as current work"
fi
assert_contains "stale .plan-ref called out" "names PLN-030" "$OUT"
assert_contains "pipeline shown instead"     "PLN-041"       "$OUT"

# At the develop root, a .plan-ref is only this session's work if HEAD is the
# branch the registry names for it. PLN-041 is active but lives on a feature
# branch; a develop-root session holding that ref is holding litter.
echo "PLN-041" > .plan-ref
OUT=$("$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
assert_contains "root .plan-ref off-branch treated as stale" "names PLN-041" "$OUT"
rm -f .plan-ref

# 6. A .plan-ref naming a plan the registry does not have must not read as fine.
echo "PLN-999" > wt/.plan-ref
OUT=$(cd wt && "$SCRIPTS/wf-rehydrate.sh" 2>/dev/null)
assert_contains "unknown .plan-ref flagged" "ABSENT from REGISTRY.md" "$OUT"
echo "PLN-041" > wt/.plan-ref

# 7. Nothing in flight → no output at all, in either hook mode.
cat > plans/REGISTRY.md << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-030 | old-thing | complete | P3 | — | 2026-07-01 | 2.00 | — | — |

<!-- Counter: 30 -->
SEED
EMPTY=$(printf '{"source":"compact"}' | "$SCRIPTS/wf-rehydrate.sh" --hook session-start 2>/dev/null)
assert_empty "empty pipeline emits no JSON" "$EMPTY"

# 8. PostCompact mode is one plain line for the human — never JSON.
LINE=$(printf '{"trigger":"auto"}' | "$SCRIPTS/wf-rehydrate.sh" --hook post-compact 2>/dev/null)
assert_contains "post-compact says nothing is in flight" "nothing in flight" "$LINE"
case "$LINE" in *'hookSpecificOutput'*) bad "post-compact is not JSON" ;; *) ok "post-compact is not JSON" ;; esac

# 9. A repo with no registry at all must exit clean, not error.
rm -rf plans
OUT=$("$SCRIPTS/wf-rehydrate.sh" --hook session-start </dev/null 2>&1)
RC=$?
if [ "$RC" = "0" ] && [ -z "$OUT" ]; then ok "no registry → silent exit 0"; else bad "no registry → silent exit 0" "rc=$RC out=[$OUT]"; fi

cd "$REPO_ROOT"

# ── settings-merge.py ─────────────────────────────────────────────────────
#
# The merge writes into a file the PROJECT owns. Two ways it can go wrong are
# both silent: clobbering a project's own hooks, and stacking a second copy of
# ours every deploy so wf-rehydrate.sh runs twice per compaction.
echo ""
echo "── settings-merge.py ──"
MERGE="$REPO_ROOT/templates/hooks/settings-merge.py"
CMD='"$CLAUDE_PROJECT_DIR"/scripts/wf-exec.sh wf-rehydrate.sh --hook'

if ! command -v python3 >/dev/null 2>&1; then
  echo "  ~ skipped (no python3)"
else
  TEST_DIR=$(mktemp -d)
  S="$TEST_DIR/settings.json"
  GCMD='"$CLAUDE_PROJECT_DIR"/scripts/wf-exec.sh wf-guard-write.sh'
  merge() { SETTINGS_PATH="$S" REHYDRATE_CMD="$CMD" GUARD_CMD="$GCMD" python3 "$MERGE" 2>&1; }
  # An older install.sh passes no GUARD_CMD — it must not install a half-wired
  # blocking hook.
  merge_noguard() { SETTINGS_PATH="$S" REHYDRATE_CMD="$CMD" python3 "$MERGE" 2>&1; }
  field() { python3 -c "import json,sys;print($1)" < "$S"; }

  R=$(merge);  [ "$R" = "created" ]   && ok "absent file → created"   || bad "absent file → created" "got: $R"
  R=$(merge);  [ "$R" = "unchanged" ] && ok "re-run → unchanged"      || bad "re-run → unchanged" "got: $R"

  # settings.json is tracked in the client while scripts/ is gitignored build
  # output, so a fresh clone has the hook and not the script. Without the
  # suffix that is a dispatcher error on every session start until deploy runs.
  assert_contains "hook tolerates a missing harness" "|| true" \
    "$(field 'json.load(sys.stdin)["hooks"]["SessionStart"][0]["hooks"][0]["command"]')"

  # ── the write guard ────────────────────────────────────────────────────
  #
  # PreToolUse blocks by EXITING 2. The rehydration hooks' `|| true` tolerance
  # suffix rewrites every exit to 0, so wearing it here would install a guard
  # that reports the collision and permits the write anyway — worse than none,
  # because it reads as protection. Absence is tested up front instead.
  GUARD_ENTRY=$(field 'json.load(sys.stdin)["hooks"]["PreToolUse"][0]')
  assert_contains "the guard is wired to PreToolUse" "wf-guard-write.sh" "$GUARD_ENTRY"
  assert_contains "on the three in-place writers" "Edit|Write|NotebookEdit" "$GUARD_ENTRY"
  assert_contains "and still tolerates a missing harness" "|| exit 0;" "$GUARD_ENTRY"
  case "$GUARD_ENTRY" in
    *"|| true"*) bad "the guard does not swallow its own exit 2" "found '|| true' in: $GUARD_ENTRY" ;;
    *)           ok  "the guard does not swallow its own exit 2" ;;
  esac

  # A deploy from an install.sh that knows nothing of the guard must leave the
  # event alone rather than write a hook naming an empty command.
  rm -f "$S"; merge_noguard >/dev/null
  N=$(field 'len(json.load(sys.stdin)["hooks"].get("PreToolUse", []))')
  [ "$N" = "0" ] && ok "no GUARD_CMD installs no guard" || bad "no GUARD_CMD installs no guard" "entries=$N"
  rm -f "$S"; merge >/dev/null

  # A project's own settings must come through untouched.
  cat > "$S" << 'J'
{
  "permissions": { "allow": ["Bash(npm run *)"] },
  "hooks": {
    "SessionStart": [{ "matcher": "startup", "hooks": [{"type":"command","command":"echo mine"}] }],
    "PreToolUse":   [{ "matcher": "Bash",    "hooks": [{"type":"command","command":"./guard.sh"}] }]
  }
}
J
  merge >/dev/null
  assert_contains "project permissions preserved" "npm run" "$(field 'json.load(sys.stdin)["permissions"]["allow"]')"
  assert_contains "project PreToolUse preserved"  "guard.sh" "$(field 'json.load(sys.stdin)["hooks"]["PreToolUse"]')"
  assert_contains "project SessionStart preserved" "echo mine" "$(field 'json.load(sys.stdin)["hooks"]["SessionStart"]')"
  N=$(field 'len(json.load(sys.stdin)["hooks"]["SessionStart"])')
  [ "$N" = "2" ] && ok "ours appended, not substituted" || bad "ours appended, not substituted" "entries=$N"

  # An older deploy's matcher must be REPLACED. Identifying our entry by matcher
  # instead of by script name would leave both and fire the script twice.
  python3 -c '
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for e in d["hooks"]["SessionStart"]:
    if "wf-rehydrate" in e["hooks"][0]["command"]:
        e["matcher"] = "compact"
json.dump(d, open(p, "w"), indent=2)
' "$S"
  merge >/dev/null
  N=$(field 'len([e for e in json.load(sys.stdin)["hooks"]["SessionStart"] if "wf-rehydrate" in e["hooks"][0]["command"]])')
  [ "$N" = "1" ] && ok "matcher drift updates in place" || bad "matcher drift updates in place" "copies=$N"

  # Bad JSON must be reported and left alone, never half-written.
  echo '{ oops' > "$S"
  R=$(merge)
  case "$R" in unparseable:*) ok "invalid JSON reported" ;; *) bad "invalid JSON reported" "got: $R" ;; esac
  [ "$(cat "$S")" = "{ oops" ] && ok "invalid JSON left untouched" || bad "invalid JSON left untouched"

  rm -rf "$TEST_DIR"; TEST_DIR=""
fi

cd "$REPO_ROOT"
echo ""
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
