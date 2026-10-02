#!/usr/bin/env bash
# lv-suite-run.sh [--label <name>] [--build]
#
# Runs the project's CONFIGURED test command, verbatim, and issues a receipt
# that names what it ran.
#
# WHY THIS EXISTS
#
# /lv-release step 7 and /lv-deploy step 8 are the release aggregation
# guarantee: every test a feature branch skipped under tiered gating runs here,
# whole, before anything reaches production. Both skills stated that as a
# comment above a `{{test_command}}` placeholder and left the running of it to
# the model — so the guarantee was a request, and nothing downstream could tell
# a full run from a filtered one.
#
# client-a's WFI-252: a RELEASE worker reported exactly one line of
# evidence, "E2E tests passed: 474 passed, 0 failed", and pushed `release`.
# 474 is the size of one assembly (Tracker.Core.Tests). The configured suite on
# that same content measures 3100 total with 121 failures, all of them in the
# E2E assembly the run claimed had passed. /lv-deploy caught it at its own full
# run and reset `main`; nothing reached production, and nothing except that
# second full run would have.
#
# So the harness runs it. The command comes from levain.yml and is not
# the caller's to choose, narrow or re-type, and the receipt below is what the
# skill quotes — a caller cannot report a pass this script did not print.
#
#   --label <name>   tag for the log file name (default: suite)
#   --build          run build_command first; a failure there is exit 1 too
#   --detach         start the run in a process that outlives this call and
#                    return immediately; wait for it with lv-suite-wait.sh
#   --exclude-e2e    append test_exclude_e2e (lv-implement, lv-verify's
#                    unscoped fallback). Empty in levain.yml = the full suite
#   --only-e2e       append test_only_e2e (lv-test step 4)
#   --extra-args <s> append <s> — a plan's E2E scope. Anything appended makes
#                    the run a FILTERED one; /lv-release and /lv-deploy never
#                    pass any of these three, and must not (WFI-252)
#   --reuse          accept an earlier PASS receipt for this exact key instead
#                    of running (see REUSE below)
#   --reuse-stage release|deploy
#                    --reuse, but only if levain.yml `suiteReuse:` lets that
#                    promotion stage reuse: none | release (default) | deploy
#                    (deploy implies release)
#   --no-reuse       never reuse, whatever else was passed; so does
#                    LV_SUITE_REUSE=0 in the environment — for chasing a flake
#
# Output, on stdout, as the last lines:
#   SUITE_CMD=<the command that ran, verbatim>
#   SUITE_LOG=<absolute path to the full output>
#   SUITE_RESULT=pass|fail (exit <code of the command>)
#   SUITE_RESULT=pass (reused <log>, <tip>, <ended>)   — on a reuse hit, with
#   SUITE_REUSED_FROM=<the original log>, which holds the real output
#
# RECEIPTS AND REUSE (LVI-035)
#
# Every run, inline or detached, leaves <log>.meta and <log>.status in the
# develop root's .claude/orchestrator/logs. Before this, only a detached run
# did, and lv-implement, lv-verify and lv-test typed {{test_command}} into a
# haiku agent, so a client with no testScopes ran its whole suite about six
# times per plan — three of them on the same commit — at 65-110s each.
#
# A pass is reusable only for the exact thing it measured. SUITE_KEY is a
# sha256 over:
#   - HEAD^{tree} — the tree, not the commit, so a merge that changes nothing
#     measures the same code. The WHOLE tracked tree: an include-list of
#     "code" paths would turn every input left out (appsettings, fixtures,
#     lockfiles, compose files) into a way to reuse a stale pass
#   - the resolved test command as run (extras included) and build command
#   - the toolchain: `suiteToolchain:` commands from levain.yml, or by
#     default the version of each of dotnet/node/npm/python3/go/rustc/java
#     found on PATH, plus DOTNET_ROOT and JAVA_HOME — a SDK upgrade with no
#     code change must force a real run
#   - the Levain version (.claude/workflow-version)
#   - the VALUE of each env var named in levain.yml `suiteKeyEnv:` — hashed,
#     never written to .meta or the log
# and is written with its components (SUITE_TREE, SUITE_CMD_HASH,
# SUITE_TOOLCHAIN) to .meta. A receipt is reusable only when the tree was
# clean — `git status --porcelain` empty, untracked files included, because
# they are outside the tree hash — at both the start and the end of the run.
# Ignored build output is fine; build_command regenerates it.
#
# A run with --build satisfies a later request with or without --build (a
# build that passed followed by a suite that passed implies the suite passed);
# a run without it satisfies only requests without it. A fail, a dirty tree,
# a reused receipt and a different filter are never reused. The receipt is
# written by this script, not by the caller, so a reuse is never a claim a
# model made (WFI-252 stays closed).
#
# Exit 0 the suite passed, 1 it failed (or the build did), 2 no test_command is
# configured for this project — which is a fact to report, never a pass.
#
# THIS IS A LONG-RUNNING COMMAND, AND WAITING FOR IT IS THE HARD PART.
#
# A foreground call is capped at 10 minutes; client-a's suite takes about
# 13. An UNATTENDED worker cannot solve that by backgrounding, because a
# headless run ends the moment it stops producing output and takes every
# background job with it. client-a's WFI-255: a DEPLOY worker merged
# `release` into `main`, wrote "Full test suite running (expected ~13 min)"
# and "Awaiting test results", and exited rc=0 sixty seconds later. It never
# awaited them. The suite was red.
#
# `--detach` is the way to wait. The run is handed to a process that outlives
# this call and writes its verdict to <log>.status; lv-suite-wait.sh then
# blocks for a bounded slice and reports "still running" rather than lying.
# A worker loops on that, so every individual call stays under the cap while
# the session keeps producing output and therefore stays alive.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

label="suite"
do_build=false
detach=false
extras_cfg=""      # test_exclude_e2e / test_only_e2e key name
extra_args=""
reuse=false
reuse_stage=""
no_reuse=false
# Set by the re-exec below so the detached child runs the suite for real.
child="${LV_SUITE_CHILD_LOG:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --label) label="${2:-suite}"; shift 2 ;;
    --build) do_build=true; shift ;;
    --detach) detach=true; shift ;;
    --exclude-e2e) extras_cfg="test_exclude_e2e"; shift ;;
    --only-e2e) extras_cfg="test_only_e2e"; shift ;;
    --extra-args) extra_args="${2:-}"; shift 2 ;;
    --reuse) reuse=true; shift ;;
    --reuse-stage) reuse_stage="${2:?--reuse-stage requires release or deploy}"; shift 2 ;;
    --no-reuse) no_reuse=true; shift ;;
    -h|--help) sed -n '2,106p' "$0"; exit 0 ;;
    *) echo "lv-suite-run.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

TEST_CMD=$(wf_cfg test_command)
if [ -z "$TEST_CMD" ]; then
  echo "Error: no test_command in levain.yml — this project has no configured suite." >&2
  echo "       That is a gap to report, not a suite that passed." >&2
  echo "SUITE_RESULT=unconfigured"
  exit 2
fi

# What actually runs: the configured command plus whatever the caller's scope
# flag resolves to. An empty test_exclude_e2e leaves the full suite, and the
# receipt says so — the key below is over this string, so a filtered pass can
# never stand in for a full one.
EXTRAS=""
[ -n "$extras_cfg" ] && EXTRAS=$(wf_cfg "$extras_cfg")
[ -n "$extra_args" ] && EXTRAS="${EXTRAS:+$EXTRAS }$extra_args"
TEST_RUN="$TEST_CMD${EXTRAS:+ $EXTRAS}"
SCOPE="full"
[ -n "$EXTRAS" ] && SCOPE="filtered"

BUILD_CMD=""
$do_build && BUILD_CMD=$(wf_cfg build_command)

DEVELOP_ROOT="$(wf_develop_root)"
LOG_DIR="$DEVELOP_ROOT/.claude/orchestrator/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="${TMPDIR:-/tmp}"
# The pid as well as the second: two runs started in the same second would
# otherwise share one log, and one receipt would describe the other run.
LOG="${child:-$LOG_DIR/suite-$label-$(date +%Y%m%d-%H%M%S)-$$.log}"

# ── The key ───────────────────────────────────────────────────────────────

sha256() { { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}'; }

tree_now() { git rev-parse --verify --quiet 'HEAD^{tree}' 2>/dev/null || true; }

# Clean means nothing outside the tree hash could have reached the suite:
# no staged, unstaged or untracked change. Ignored output does not count.
clean_now() {
  local st
  st=$(git status --porcelain 2>/dev/null) || { echo 0; return; }
  [ -z "$st" ] && echo 1 || echo 0
}

# One line per tool: "<probe> => <first line it printed>". The probes run
# here, in the caller's tree and environment, because that is what the suite
# runs under — a global.json or .nvmrc in the tree picks the version.
toolchain_lines() {
  local probes=() p first
  while IFS= read -r p; do [ -n "$p" ] && probes+=("$p"); done < <(wf_cfg_list suiteToolchain)
  if [ ${#probes[@]} -eq 0 ]; then
    for p in "dotnet --version" "node --version" "npm --version" \
             "python3 --version" "go version" "rustc --version" "java -version"; do
      command -v "${p%% *}" >/dev/null 2>&1 && probes+=("$p")
    done
  fi
  for p in ${probes[@]+"${probes[@]}"}; do
    first=$(eval "$p" < /dev/null 2>&1 | head -1)
    printf '%s => %s\n' "$p" "$first"
  done
  printf 'DOTNET_ROOT=%s\nJAVA_HOME=%s\n' "${DOTNET_ROOT:-}" "${JAVA_HOME:-}"
}

# The values of suiteKeyEnv go into the hash and nowhere else. Their NAMES
# may be printed; a value is somebody's secret as often as not.
env_lines() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s=%s\n' "$n" "$(printenv "$n" 2>/dev/null || true)"
  done < <(wf_cfg_list suiteKeyEnv)
}

# key <build command, or empty> — over components computed once below.
key_for() {
  printf 'tree=%s\ntest=%s\nbuild=%s\nlevain=%s\n%s\n%s\n' \
    "$K_TREE" "$TEST_RUN" "${1:-}" "$K_LEVAIN" "$K_TOOLCHAIN" "$K_ENV" | sha256
}

K_TREE=""; K_CLEAN=0; K_LEVAIN=""; K_TOOLCHAIN=""; K_ENV=""
REQ_KEY=""; SATISFIES=""
compute_key() {
  K_TREE=$(tree_now)
  K_CLEAN=$(clean_now)
  K_LEVAIN=$(tr -d '[:space:]' < "$DEVELOP_ROOT/.claude/workflow-version" 2>/dev/null || true)
  K_LEVAIN="${K_LEVAIN:-unknown}"
  K_TOOLCHAIN=$(toolchain_lines)
  K_ENV=$(env_lines)
  [ -n "$K_TREE" ] || return 0
  REQ_KEY=$(key_for "$BUILD_CMD")
  # A build+suite pass also vouches for the suite alone.
  SATISFIES="$REQ_KEY"
  [ -n "$BUILD_CMD" ] && SATISFIES="$REQ_KEY $(key_for "")"
}

field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# Newest passing, clean, non-reused receipt whose SUITE_SATISFIES holds the key.
find_receipt() {
  local want="$1" st meta
  for st in $(ls -t "$LOG_DIR"/*.status 2>/dev/null); do
    meta="${st%.status}.meta"
    [ -f "$meta" ] || continue
    [ "$(field "$st" SUITE_RESULT)" = "pass (exit 0)" ] || continue
    [ "$(field "$st" SUITE_CLEAN_END)" = "1" ] || continue
    [ "$(field "$meta" SUITE_CLEAN)" = "1" ] || continue
    [ -z "$(field "$meta" SUITE_REUSED_FROM)" ] || continue
    case " $(field "$meta" SUITE_SATISFIES) " in
      *" $want "*) printf '%s' "${st%.status}"; return 0 ;;
    esac
  done
  return 1
}

write_meta() {
  {
    printf 'SUITE_LABEL=%s\nSUITE_DIR=%s\nSUITE_BRANCH=%s\nSUITE_TIP=%s\nSUITE_STARTED=%s\n' \
      "$label" "$(pwd -P)" \
      "$(git branch --show-current 2>/dev/null || echo '(detached)')" \
      "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'SUITE_SCOPE=%s\nSUITE_TREE=%s\nSUITE_CLEAN=%s\nSUITE_CMD_HASH=%s\nSUITE_LEVAIN=%s\n' \
      "$SCOPE" "${K_TREE:-unknown}" "$K_CLEAN" \
      "$(printf 'test=%s\nbuild=%s\n' "$TEST_RUN" "$BUILD_CMD" | sha256)" "$K_LEVAIN"
    printf 'SUITE_TOOLCHAIN=%s\n' "$(printf '%s' "$K_TOOLCHAIN" | tr '\n' ';')"
    printf 'SUITE_KEY=%s\n' "${REQ_KEY:-none}"
    # Only a clean tree's run can vouch for anything later.
    [ "$K_CLEAN" = "1" ] && [ -n "$SATISFIES" ] && printf 'SUITE_SATISFIES=%s\n' "$SATISFIES"
    [ -n "${1:-}" ] && printf 'SUITE_REUSED_FROM=%s\n' "$1"
  } > "$LOG.meta"
}

# ── Reuse ─────────────────────────────────────────────────────────────────

if [ -z "$child" ]; then
  compute_key

  if [ -n "$reuse_stage" ]; then
    policy=$(wf_cfg suiteReuse)
    policy="${policy:-release}"
    case "$policy:$reuse_stage" in
      release:release|deploy:release|deploy:deploy) reuse=true ;;
      none:*|release:deploy) ;;
      *) echo "lv-suite-run: suiteReuse: '$policy' / --reuse-stage '$reuse_stage' not understood — running the suite." >&2 ;;
    esac
  fi
  if $no_reuse || [ "${LV_SUITE_REUSE:-1}" = "0" ]; then reuse=false; fi

  if $reuse; then
    if [ -z "$REQ_KEY" ]; then
      echo "Reuse: not a git tree here — running the suite." >&2
    elif [ "$K_CLEAN" != "1" ]; then
      echo "Reuse: the tree has uncommitted or untracked changes — running the suite." >&2
    elif orig=$(find_receipt "$REQ_KEY"); then
      ost="$orig.status"
      ended=$(field "$ost" SUITE_ENDED)
      otip=$(field "$ost" SUITE_TIP); otip="${otip:0:9}"
      ocmd=$(field "$ost" SUITE_CMD)
      result="pass (reused $orig, ${otip:-?}, ${ended:-?})"
      write_meta "$orig"
      {
        echo "Reused a passing receipt — the suite was NOT run again."
        echo "  same tree ${K_TREE:0:12}, command, toolchain and Levain version as:"
        echo "  $orig"
        echo "  Its full output is in that log. Force a real run with --no-reuse."
      } | tee "$LOG"
      {
        printf 'SUITE_CMD=%s\nSUITE_LOG=%s\nSUITE_REUSED_FROM=%s\nSUITE_RESULT=%s\n' \
          "$ocmd" "$LOG" "$orig" "$result"
        printf 'SUITE_BRANCH=%s\nSUITE_TIP=%s\nSUITE_ENDED=%s\nSUITE_CLEAN_END=1\n' \
          "$(git branch --show-current 2>/dev/null || echo '(detached)')" \
          "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      } > "$LOG.status"
      if $detach; then
        # lv-suite-wait.sh collects it, as for any detached run.
        echo "SUITE_HANDLE=$LOG"
        echo "Wait for it: lv-suite-wait.sh $LOG"
      else
        printf 'READ_AT=%s\nREAD_BY_PID=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" > "$LOG.status.read" 2>/dev/null || true
      fi
      printf 'SUITE_CMD=%s\nSUITE_LOG=%s\nSUITE_REUSED_FROM=%s\nSUITE_RESULT=%s\n' \
        "$ocmd" "$LOG" "$orig" "$result"
      exit 0
    else
      echo "Reuse: no passing receipt for this tree, command and toolchain — running the suite." >&2
    fi
  fi
fi

# ── --detach: hand the run to a process that outlives this call ───────────
#
# `setsid` where it exists, `nohup` otherwise: the child must survive the
# session that started it, because the whole point is that the session cannot
# hold a 13-minute foreground call. The status file is written by the child
# when it finishes and is the only thing lv-suite-wait.sh trusts — a running
# child has none, which is exactly how "still running" is told apart from
# "finished and passed".
if $detach && [ -z "$child" ]; then
  rm -f "$LOG.status" "$LOG.status.read"
  # Create the handle here, not in the child: lv-suite-wait.sh tells "bad
  # handle" from "not finished yet" by whether the log exists, and a child that
  # has not been scheduled yet would otherwise look like a typo.
  : > "$LOG"
  # What was under test, recorded before the run rather than reconstructed
  # after it. A verdict nobody collected is only useful if the tree it measured
  # can still be named — see lv-suite-receipts.sh (client-a WFI-266).
  write_meta
  args=(--label "$label")
  $do_build && args+=(--build)
  [ "$extras_cfg" = "test_exclude_e2e" ] && args+=(--exclude-e2e)
  [ "$extras_cfg" = "test_only_e2e" ] && args+=(--only-e2e)
  [ -n "$extra_args" ] && args+=(--extra-args "$extra_args")
  launcher=(nohup)
  command -v setsid >/dev/null 2>&1 && launcher=(setsid nohup)
  LV_SUITE_CHILD_LOG="$LOG" "${launcher[@]}" "$0" "${args[@]}" >/dev/null 2>&1 &
  echo "SUITE_LOG=$LOG"
  echo "SUITE_HANDLE=$LOG"
  echo "SUITE_RESULT=running (detached pid $!)"
  echo "Wait for it: lv-suite-wait.sh $LOG"
  exit 0
fi

# An inline run records its receipt too: the next step may reuse it.
[ -z "$child" ] && write_meta

# The child records its verdict where lv-suite-wait.sh will look for it. A
# `trap` rather than a line at the bottom: a child killed mid-suite must leave
# a verdict that says so, not an absent file that reads as "still running"
# forever.
if [ -n "$child" ]; then
  trap 'printf "SUITE_LOG=%s\nSUITE_RESULT=fail (the suite process died before it finished — see the log)\n" "$LOG" > "$LOG.status"' EXIT INT TERM
fi

# Runs where the caller is standing, on purpose: /lv-release tests the local
# merge inside release-branches/release, /lv-deploy tests merged `main` inside
# release-branches/main. Running either from the develop root would test
# develop — the wrong-tree-reported-as-success class (WFI-105, WFI-225).
echo "Running the configured suite in $(pwd)" | tee "$LOG"
echo "  branch: $(git branch --show-current 2>/dev/null || echo '(detached)')" | tee -a "$LOG"
echo "  head:   $(git rev-parse --short HEAD 2>/dev/null || echo unknown)" | tee -a "$LOG"

rc=0

# The receipt, in one place. A detached child's stdout goes nowhere, so its
# copy has to land in the status file — same three lines, so a caller reads an
# identical receipt whether it ran the suite inline or waited for one.
finish() {
  local result="$1" cmd="$2" clean_end=0
  printf 'SUITE_CMD=%s\nSUITE_LOG=%s\nSUITE_RESULT=%s\n' "$cmd" "$LOG" "$result"
  # Still the tree it started on, still clean? A commit or an edit made
  # during the run means the pass measured something no longer standing here,
  # so it may be reported but never reused.
  if [ "$(field "$LOG.meta" SUITE_CLEAN)" = "1" ] \
     && [ "$(tree_now)" = "$(field "$LOG.meta" SUITE_TREE)" ] \
     && [ "$(clean_now)" = "1" ]; then
    clean_end=1
  elif [ "$(field "$LOG.meta" SUITE_CLEAN)" = "1" ]; then
    # Started clean, ended dirty: usually the suite itself writes output the
    # project does not ignore (TestResults/, coverage/). Say which, or every
    # receipt here is silently unusable.
    {
      echo "Receipt not reusable: the tree changed during the run. First changes:"
      git status --porcelain 2>/dev/null | head -3 | sed 's/^/  /'
      echo "  Ignore what the suite writes (.gitignore) to make its passes reusable."
    } | tee -a "$LOG" >&2
  fi
  [ -n "$child" ] && trap - EXIT
  # The tip is stamped into the verdict, not left to be inferred from the
  # log's first lines. A green run whose caller vanished is re-usable only by
  # someone who can prove it measured the tree in front of them (WFI-266).
  {
    printf 'SUITE_CMD=%s\nSUITE_LOG=%s\nSUITE_RESULT=%s\n' "$cmd" "$LOG" "$result"
    printf 'SUITE_BRANCH=%s\nSUITE_TIP=%s\nSUITE_ENDED=%s\nSUITE_CLEAN_END=%s\n' \
      "$(git branch --show-current 2>/dev/null || echo '(detached)')" \
      "$(git rev-parse HEAD 2>/dev/null || echo unknown)" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$clean_end"
  } > "$LOG.status"
  # Inline, the verdict reached its caller on stdout just now — so it is
  # collected, and lv-suite-receipts.sh --abandoned must not list it.
  if [ -z "$child" ]; then
    printf 'READ_AT=%s\nREAD_BY_PID=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$$" > "$LOG.status.read" 2>/dev/null || true
  fi
}

if [ -n "$BUILD_CMD" ]; then
  echo "  build:  $BUILD_CMD" | tee -a "$LOG"
  # `< /dev/null`: a build or test step that reads stdin blocks forever
  # otherwise, with no failure and no output to show for it (WFI-240).
  set -o pipefail
  eval "$BUILD_CMD" < /dev/null 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo ""
    finish "fail (build exit $rc — the suite never ran)" "$BUILD_CMD"
    exit 1
  fi
fi

echo "  suite:  $TEST_RUN" | tee -a "$LOG"
[ "$SCOPE" = "filtered" ] && echo "  scope:  FILTERED — not a full-suite run" | tee -a "$LOG"
echo "" | tee -a "$LOG"

set -o pipefail
eval "$TEST_RUN" < /dev/null 2>&1 | tee -a "$LOG"
rc=${PIPESTATUS[0]}

echo ""
if [ "$rc" -eq 0 ]; then
  finish "pass (exit 0)" "$TEST_RUN"
  exit 0
fi
finish "fail (exit $rc)" "$TEST_RUN"
exit 1
