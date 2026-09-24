#!/usr/bin/env bash
# lv-test-scope.sh <plan-name> [--args|--split]
#
# Emits a test-filter expression for the given plan's test scope.
#
# stdout: filter expression (e.g. "FullyQualifiedName~Core.Tests|FullyQualifiedName~E2E.HomePageTests")
#         Empty string means "run full suite" (no filter flag needed).
# stderr: human-readable category list ("scope: unit, e2e-smoke") for logging in the verify agent.
#
# --args: emit the COMPLETE argument string instead of a bare filter value —
#         flag names included. This exists because not every runner expresses a
#         filter as one flag plus one value. Microsoft.Testing.Platform needs a
#         repeated `--filter-class` and a mandatory `--ignore-exit-code 8`,
#         which `<flag> "<value>"` cannot express at all. Callers should prefer
#         --args; the bare form is kept for existing callers.
#
#         The output carries its own quoting, so run it through eval:
#             ARGS=$(lv-test-scope.sh PLN-NNN-slug --args)
#             eval "<test command> $ARGS"
#         Unquoted expansion instead of eval would leave the quote characters
#         in the argument AND let the shell glob `*Core.Tests*` against the
#         working directory. The values are project-authored config, the same
#         trust level as the test command itself.
#
# --split: the same arguments, but one COMPLETE argument string per line — one
#          line per filter value instead of all of them ORed into a single run.
#
#          A SCOPE IS NOT A TIME BUDGET
#
#          `--args` answers "which tests are in scope?", and a caller that has
#          to run them inside one tool call needs a second answer: "will that
#          fit?". client-a's WFI-228 — one testScopes value naming a whole
#          1,972-test assembly, so the *scoped* command was as unrunnable as
#          the unscoped one had been (WFI-222). The agent hit the 600s ceiling
#          mid-run, moved the process to the background, and reported counts
#          read off a live progress line as though they were a result.
#
#          There is no filter this script can compute that makes a large
#          assembly small; the scope is what the project declared and it is
#          correct. What it can do is hand the caller the pieces, so a run that
#          does not fit in one call is several calls that do — which is exactly
#          the recovery the reporter performed by hand, and it worked.
#
#              lv-test-scope.sh PLN-NNN-slug --split | while read -r a; do
#                eval "<test command> $a"
#              done
#
#          Each line is independently runnable and carries its own quoting, so
#          each still needs eval. Every line of an `mtp` split carries
#          `--ignore-exit-code 8` for the reason given below — it applies per
#          run, and a split makes MORE projects match zero tests, not fewer.
#          A --split of one value is one line, identical to --args.
#
# Why stdout/stderr split (diverges from lv-plan-info.sh env-var pattern):
#   lv-plan-info.sh outputs eval-friendly key=value pairs for multiple values.
#   This script outputs a single filter string that callers capture via $(...).
#   Mixing the category log line into stdout would corrupt the captured filter.
#   stderr is the correct channel for informational output that must not be captured.
#
# Exit codes:
#   0 — success (filter on stdout, possibly empty for full-suite fallback)
#   2 — bad input (plan name fails validation)
#   3 — yq missing and LV_TEST_SCOPE_FALLBACK is not set to "full"
#
# LV_TEST_SCOPE_FALLBACK=full: bypass yq requirement, emit empty stdout (full-suite fallback).

set -euo pipefail

# shellcheck source=lv-ids.sh
source "$(dirname "$0")/lv-ids.sh"   # the ID prefix map: LV_PLN_RE and kin

PLAN_NAME="${1:-}"
EMIT_ARGS=false
SPLIT=false
case "${2:-}" in
  --args)  EMIT_ARGS=true ;;
  --split) EMIT_ARGS=true; SPLIT=true ;;
  "")      ;;
  *) echo "lv-test-scope.sh: unknown option '${2}' — expected --args or --split" >&2; exit 2 ;;
esac

# Input validation — close command-injection vector before plan name reaches eval.
if ! echo "$PLAN_NAME" | grep -qE "^($LV_PLN_RE)-[0-9]+-[a-z0-9-]+$"; then
  echo "lv-test-scope.sh: invalid plan name '$PLAN_NAME' — must match $LV_PLN-NNN-slug (e.g. $LV_PLN-080-tiered-test-gating)" >&2
  exit 2
fi

# Locate the script's own directory and walk up until we find claude-workflow.yml.
# Works for both flat (scripts/) and versioned (scripts/vN.NN/) layouts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVELOP_ROOT=""
search="$SCRIPT_DIR"
while [ "$search" != "/" ]; do
  if [ -f "$search/claude-workflow.yml" ]; then DEVELOP_ROOT="$search"; break; fi
  search="$(dirname "$search")"
done
if [ -z "$DEVELOP_ROOT" ]; then
  echo "lv-test-scope.sh: cannot locate claude-workflow.yml by walking up from $SCRIPT_DIR" >&2
  exit 2
fi
# ── Which tree answers "what is the config?" ──────────────────────────────
#
# DEVELOP_ROOT is found by walking up from SCRIPT_DIR, and lv-exec.sh's
# find_project_root always resolves the MAIN worktree — so on a feature branch
# the walk above lands on develop no matter where the caller is standing.
#
# That is right for plans/ (it exists only on develop) and wrong for everything
# else here. A plan whose Step 1 adds a new test project to testScopes commits
# that edit on its own branch; verify then runs from the feature worktree, reads
# develop's config, does not see the new scope, and files a finding saying the
# scope was "never added" — citing the exact lines where the branch's own commit
# added it. client-a's PLN-004 (WFI-052). The branch's config is not visible
# to the branch's own verification until the plan merges, which is after verify.
#
# So: plans come from develop, config comes from the tree the caller is in.
WORKTREE_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
CONFIG_ROOT="$DEVELOP_ROOT"
if [ -n "$WORKTREE_ROOT" ] && [ -f "$WORKTREE_ROOT/claude-workflow.yml" ]; then
  CONFIG_ROOT="$WORKTREE_ROOT"
fi
CONFIG="$CONFIG_ROOT/claude-workflow.yml"

# Check yq dependency before doing anything else.
if ! command -v yq >/dev/null 2>&1; then
  if [ "${LV_TEST_SCOPE_FALLBACK:-}" = "full" ]; then
    echo "lv-test-scope.sh: yq not found — LV_TEST_SCOPE_FALLBACK=full, returning empty filter (full suite)" >&2
    printf ""
    exit 0
  fi
  echo "lv-test-scope.sh: yq required but not found on PATH — install yq or set LV_TEST_SCOPE_FALLBACK=full to bypass" >&2
  exit 3
fi

# Resolve PLAN_DIR via sibling lv-plan-info.sh (quoted $PLAN_NAME — already validated above).
eval "$("$SCRIPT_DIR/lv-plan-info.sh" "$PLAN_NAME")"
PLAN_FILE="$DEVELOP_ROOT/$PLAN_DIR/plan.md"

if [ ! -f "$PLAN_FILE" ]; then
  echo "lv-test-scope.sh: plan file not found: $PLAN_FILE" >&2
  exit 2
fi

# Parse declared categories from "## Test Scope" section in plan.md.
declared=()
in_scope=0
while IFS= read -r line; do
  if echo "$line" | grep -qE '^## Test Scope'; then
    in_scope=1
    continue
  fi
  if [ "$in_scope" -eq 1 ] && echo "$line" | grep -qE '^## '; then
    break
  fi
  if [ "$in_scope" -eq 1 ] && echo "$line" | grep -qE '^- '; then
    # A bullet is a bare category name. Anything after it is annotation, not
    # part of the key: plans routinely justify a scope inline —
    #   - vectors <!-- A3: Step 1a edits src/Tracker.Cli/**, mapped to vectors -->
    # — and reading the comment as part of the name made `vectors` an "unknown
    # category" that was silently skipped. client-a only kept the scope
    # because testMappings happened to auto-detect it from the same diff; a
    # plan whose changed files did not also map to it would have lost the
    # category with nothing but a warning (WFI-116).
    cat_name=$(echo "$line" \
      | sed -e 's/^-[[:space:]]*//' -e 's/<!--.*$//' -e 's/[[:space:]]*$//')
    [ -n "$cat_name" ] && declared+=("$cat_name")
  fi
done < "$PLAN_FILE"

# No scope section or empty → exit 0 with empty stdout (full-suite fallback).
if [ ${#declared[@]} -eq 0 ]; then
  exit 0
fi

# Length of a yq collection, as a number that is safe to loop over.
#
# yq prints the string "null" for an absent key and exits 0, so a `|| echo 0`
# fallback never fires, and `$(( null - 1 ))` is -1. That met BSD seq, which
# REVERSES a range whenever first > last: `seq 0 -1` emits 0 and -1, so the
# loop ran twice, yq died on index [-1], and `set -e` killed the script. Any
# project whose config omits testScopeMandatory or testMappings hit it.
#
# The loops below are C-style for exactly this reason — `seq` cannot express
# an empty range on macOS, in either direction.
yq_count() {
  local n
  n=$(yq e "$1" "$CONFIG" 2>/dev/null || echo 0)
  case "$n" in ''|null|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# Auto-detect categories from git diff --name-only develop..HEAD.
auto=()
# Also CONFIG_ROOT, and for a second reason: on DEVELOP_ROOT, HEAD *is* develop,
# so `develop..HEAD` is empty by definition and the whole testMappings
# auto-detection below could never fire. It only means anything from the
# worktree of the branch under test.
if git -C "$CONFIG_ROOT" rev-parse --verify develop >/dev/null 2>&1; then
  changed_files=$(git -C "$CONFIG_ROOT" diff --name-only develop..HEAD 2>/dev/null || true)
  if [ -n "$changed_files" ]; then
    mapping_count=$(yq_count '.testMappings | length')
    for (( i = 0; i < mapping_count; i++ )); do
      glob=$(yq e ".testMappings[$i].glob" "$CONFIG")
      scopes_count=$(yq_count ".testMappings[$i].scopes | length")
      matched=0
      while IFS= read -r f; do
        pattern="${glob#./}"
        case "$f" in
          $pattern) matched=1; break ;;
        esac
      done <<< "$changed_files"
      if [ "$matched" -eq 1 ]; then
        for (( j = 0; j < scopes_count; j++ )); do
          scope=$(yq e ".testMappings[$i].scopes[$j]" "$CONFIG")
          auto+=("$scope")
        done
      fi
    done
  fi
else
  echo "lv-test-scope.sh: auto-detect skipped: develop ref unavailable" >&2
fi

# ── Changes that no filter can be trusted around ──────────────────────────
#
# A filtered run answers "do the selected tests pass?", and for most changes
# that is the same question as "did this break anything?". It is not the same
# question when the change is to something the OTHER tests share: a collection
# fixture, a test base class, a seeded database helper, a DI container built
# once per assembly. Those failures depend on what else ran, and in what order,
# so a subset run can pass while the assembly fails.
#
# client-a's WFI-123: PLN-038 touched a shared test helper, verify and the
# test gate both passed, and AdminCapsuleListTests failed on develop the moment
# the merge landed — the failure needed a test-class ordering the filtered run
# never produced. Nothing was wrong with the gating; it was answering a
# narrower question than the one being asked of it.
#
# So: name those files in config, and a diff that touches one drops the filter.
# There is no way to infer the list — "shared" is a fact about the project's
# test architecture, not about a path — but stating it is cheap and the failure
# mode of leaving it empty is exactly today's behaviour.
full_suite_count=$(yq_count '.testScopeFullSuiteGlobs | length')
if [ -n "${changed_files:-}" ] && [ "$full_suite_count" -gt 0 ]; then
  for (( i = 0; i < full_suite_count; i++ )); do
    glob=$(yq e ".testScopeFullSuiteGlobs[$i]" "$CONFIG")
    pattern="${glob#./}"
    while IFS= read -r f; do
      case "$f" in
        $pattern)
          echo "lv-test-scope.sh: '$f' matches testScopeFullSuiteGlobs ('$glob') — running the FULL suite." >&2
          echo "lv-test-scope.sh: a filtered run cannot see an ordering-dependent failure in shared test state (WFI-123)." >&2
          exit 0 ;;
      esac
    done <<< "$changed_files"
  done
fi

# Mandatory categories.
mandatory=()
mandatory_count=$(yq_count '.testScopeMandatory | length')
for (( i = 0; i < mandatory_count; i++ )); do
  cat_name=$(yq e ".testScopeMandatory[$i]" "$CONFIG")
  mandatory+=("$cat_name")
done

# Union: declared ∪ auto-detected ∪ mandatory (deduplicate).
all_cats=()
seen=()
for cat in \
  "${declared[@]+"${declared[@]}"}" \
  "${auto[@]+"${auto[@]}"}" \
  "${mandatory[@]+"${mandatory[@]}"}"; do
  skip=0
  for s in "${seen[@]+"${seen[@]}"}"; do
    [ "$s" = "$cat" ] && skip=1 && break
  done
  if [ "$skip" -eq 0 ]; then
    all_cats+=("$cat")
    seen+=("$cat")
  fi
done

# Resolve each category to FQN substrings from testScopes.
fqn_parts=()
used_cats=()
for cat in "${all_cats[@]}"; do
  count=$(yq_count ".testScopes.\"$cat\" | length")
  if [ "$count" = "0" ]; then
    echo "lv-test-scope.sh: warning: unknown category '$cat' — skipped" >&2
    continue
  fi
  used_cats+=("$cat")
  for (( i = 0; i < count; i++ )); do
    fqn=$(yq e ".testScopes.\"$cat\"[$i]" "$CONFIG")
    fqn_parts+=("FullyQualifiedName~$fqn")
  done
done

if [ ${#fqn_parts[@]} -eq 0 ]; then
  exit 0
fi

cat_list=$(IFS=", "; echo "${used_cats[*]}")

# ── Runner check ──────────────────────────────────────────────────────────
# `FullyQualifiedName~X` is VSTest syntax. A project on Microsoft.Testing
# Platform does not recognise `--filter` in native mode: it prints MTP's help,
# reports "Zero tests ran", and exits 1. That is the worst possible failure
# here — a verify agent reading only the exit code sees a fully passing plan
# fail, and routes it back to active or draft for nothing.
#
# `mtp` renders the same scope in MTP's own syntax instead. `none` remains as
# the deliberate opt-out: run everything, always. Running everything is never
# wrong, only slower.
#
#   auto   — detect the runner (default)
#   vstest — FullyQualifiedName~ expressions behind test_filter_flag
#   mtp    — repeated --filter-class, plus --ignore-exit-code 8
#   none   — never filter; always the full suite
filter_style=$(yq e '.testFilterStyle // ""' "$CONFIG" 2>/dev/null || echo "")
if [ -z "$filter_style" ] || [ "$filter_style" = "null" ]; then
  filter_style="auto"
fi

if [ "$filter_style" = "auto" ]; then
  mtp=""
  # CONFIG_ROOT for the same reason as the config: a plan that ADDS the first
  # MTP test project changes the answer on its own branch first.
  if [ -f "$CONFIG_ROOT/global.json" ] &&
     grep -q '"runner"[[:space:]]*:[[:space:]]*"Microsoft.Testing.Platform"' "$CONFIG_ROOT/global.json" 2>/dev/null; then
    mtp="global.json pins runner: Microsoft.Testing.Platform"
  elif grep -rlq '<TestingPlatformDotnetTestSupport>[[:space:]]*true' \
         "$CONFIG_ROOT" --include='*.csproj' 2>/dev/null; then
    mtp="a test project sets TestingPlatformDotnetTestSupport"
  fi
  [ -n "$mtp" ] && filter_style="mtp"
fi

if [ "$filter_style" = "none" ]; then
  echo "lv-test-scope.sh: testFilterStyle: none — filtering disabled." >&2
  echo "lv-test-scope.sh: falling back to the FULL suite (scope would have been: $cat_list)." >&2
  exit 0
fi

echo "scope: $cat_list" >&2

if [ "$filter_style" = "mtp" ]; then
  # Confirmed against real `dotnet test --solution` runs on .NET 10 / xUnit v3
  # (client-a, WFI-045). `--filter-class` matches the fully-qualified class
  # name, so wrapping each testScopes value in `*` reproduces the substring
  # semantics of VSTest's `FullyQualifiedName~`. Repeating the flag ORs the
  # values together.
  #
  # `--ignore-exit-code 8` is not optional and not cosmetic. Filtering across a
  # solution makes every project with zero matching tests exit 8, so a run in
  # which every selected test passed still reports failure — and a verify agent
  # reading the exit code routes a good plan back to active. It is applied ONLY
  # on filtered runs: on an unfiltered one, exit 8 means the suite genuinely
  # found no tests, which is a real failure and must stay one. That asymmetry
  # is why this cannot simply be baked into test_command.
  if [ "$EMIT_ARGS" != "true" ]; then
    echo "lv-test-scope.sh: testFilterStyle: mtp needs --args — its filter is several flags," >&2
    echo "lv-test-scope.sh: not one value. Falling back to the FULL suite." >&2
    exit 0
  fi
  if [ "$SPLIT" = "true" ]; then
    for part in "${fqn_parts[@]}"; do
      fqn="${part#FullyQualifiedName~}"
      printf -- "--filter-class '*%s*' --ignore-exit-code 8\n" "$fqn"
    done
    exit 0
  fi
  args=""
  for part in "${fqn_parts[@]}"; do
    fqn="${part#FullyQualifiedName~}"   # the raw testScopes value
    args="$args --filter-class '*${fqn}*'"
  done
  printf '%s --ignore-exit-code 8' "${args# }"
  exit 0
fi

flag=$(yq e '.test_filter_flag // ""' "$CONFIG" 2>/dev/null || echo "")
case "$flag" in ''|null) flag="--filter" ;; esac

if [ "$SPLIT" = "true" ]; then
  for part in "${fqn_parts[@]}"; do
    printf "%s '%s'\n" "$flag" "$part"
  done
  exit 0
fi

filter=$(IFS="|"; echo "${fqn_parts[*]}")

if [ "$EMIT_ARGS" = "true" ]; then
  printf "%s '%s'" "$flag" "$filter"
  exit 0
fi

printf "%s" "$filter"
