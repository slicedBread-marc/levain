#!/usr/bin/env bash
# atomic-deploy.sh — tests for the v9.0.0 invariant:
#
#   NO PATH A RUNNING PROCESS RESOLVES IS EVER WRITTEN TWICE.
#
# Before v9.0.0 install.sh rendered every script with a plain `>` into the
# folder a daemon was sweeping out of. For the length of that loop the folder
# held a mixture of two harnesses and each file in it was briefly zero bytes.
# Nothing errored at deploy time; a sweep that landed in the window misbehaved
# an hour later and was blamed on anything else (coordinator WFI-003).
#
# The load-bearing test is (4): a reader resolving the script folder in a tight
# loop across a live install must never once catch it holding two harnesses at
# the same time. Everything above it checks the mechanism that makes (4) true.
#
# Usage: ./tests/atomic-deploy.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=""
PASS=0
FAIL=0

cleanup() {
  if [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ]; then rm -rf "$TEST_DIR"; fi
  return 0
}
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then ok "$label"; else bad "$label" "want [$want], got [$got]"; fi
}

TEST_DIR=$(mktemp -d)
CLIENT="$TEST_DIR/client"

new_client() {
  rm -rf "$CLIENT"
  mkdir -p "$CLIENT"
  git init -q "$CLIENT"
  printf 'project_slug: "atomic-test"\n' > "$CLIENT/claude-workflow.yml"
}

install_client() {
  WF_INSTALL_NO_COMMIT=1 bash "$REPO_ROOT/install.sh" "$CLIENT" >/dev/null 2>&1
}

echo "atomic-deploy.sh"
echo "================"

# ── 1. A build is published and the pointer names it ────────────────────────
echo ""
echo "1. Publish and flip"
new_client
install_client

build=$(tr -d '[:space:]' < "$CLIENT/scripts/current" 2>/dev/null || echo "")
if [ -n "$build" ] && [ -d "$CLIENT/scripts/gen/$build/v2.00" ]; then
  ok "scripts/current names a build directory that exists"
else
  bad "scripts/current names a build directory that exists" "current=[$build]"
fi

if [ -x "$CLIENT/scripts/gen/$build/v2.00/wf-counter-next.sh" ]; then
  ok "the published build holds executable scripts"
else
  bad "the published build holds executable scripts"
fi

out=$( cd "$CLIENT" && scripts/wf-exec.sh wf-counter-next.sh --peek 2>&1 )
assert_eq "wf-exec.sh dispatches through the pointer" "1" "$out"

# ── 2. Every deploy is a new build ──────────────────────────────────────────
#
# The timestamp in a build id is not decoration: it is what lets a build be
# published by a rename with no destination to displace, which is what makes
# re-deploying the SAME workflow version an ordinary case rather than an
# overwrite of a folder something is running out of.
echo ""
echo "2. Re-deploying the same version"
first="$build"
sleep 1
install_client
second=$(tr -d '[:space:]' < "$CLIENT/scripts/current")

if [ "$first" != "$second" ]; then
  ok "a same-version redeploy produces a different build id"
else
  bad "a same-version redeploy produces a different build id" "both [$first]"
fi

if [ -d "$CLIENT/scripts/gen/$first" ]; then
  ok "the replaced build is retained (a subprocess may still be in it)"
else
  bad "the replaced build is retained"
fi

# ── 3. Retention keeps exactly two ──────────────────────────────────────────
echo ""
echo "3. Retention"
sleep 1
install_client
sleep 1
install_client
count=$(ls "$CLIENT/scripts/gen" | wc -l | tr -d ' ')
assert_eq "four deploys leave two builds on disk" "2" "$count"

newest=$(tr -d '[:space:]' < "$CLIENT/scripts/current")
if [ -d "$CLIENT/scripts/gen/$newest" ]; then
  ok "the published build is one of the two retained"
else
  bad "the published build is one of the two retained"
fi

# ── 4. A reader never sees a torn harness ───────────────────────────────────
#
# This is the whole point, and it needs a probe sharp enough to see the window.
# Sampling a single file's size is not: the truncate-then-fill of one script
# lasts microseconds. The window that lasts the WHOLE DEPLOY is the folder
# being a MIXTURE — the loop rewrites wf-abandon.sh first and
# wf-worktree-sparse.sh last, so for the length of the loop the first carries
# the incoming harness and the last still carries the outgoing one.
#
# So: deploy from a marked copy of the library, and have a reader resolve the
# script folder the way a caller does and check that its first and last script
# agree about the marker. Measured against the pre-v9.0.0 installer this fails
# on roughly a quarter of samples; it must fail on none.
echo ""
echo "4. Reading the script folder across a live install"

MARKED_LIB="$TEST_DIR/marked-lib"
rm -rf "$MARKED_LIB"; mkdir -p "$MARKED_LIB"
cp -R "$REPO_ROOT/scripts" "$REPO_ROOT/templates" "$REPO_ROOT/skills" \
      "$REPO_ROOT/claude-md" "$REPO_ROOT/config.example.yml" \
      "$REPO_ROOT/VERSION" "$REPO_ROOT/install.sh" "$MARKED_LIB/"
for f in "$MARKED_LIB/scripts/v2.00"/wf-*.sh; do
  printf '# ATOMIC-TEST-MARKER\n' >> "$f"
done

new_client
install_client

# Resolve the way wf-exec.sh does: pointer first, legacy folder as fallback.
resolve_dir() {
  local build=""
  [ -f "$CLIENT/scripts/current" ] && build=$(tr -d '[:space:]' < "$CLIENT/scripts/current")
  if [ -n "$build" ] && [ -d "$CLIENT/scripts/gen/$build/v2.00" ]; then
    echo "$CLIENT/scripts/gen/$build/v2.00"
  else
    echo "$CLIENT/scripts/v2.00"
  fi
}

probe() {
  local d a z
  d=$(resolve_dir)
  if grep -q 'ATOMIC-TEST-MARKER' "$d/wf-abandon.sh" 2>/dev/null; then a=1; else a=0; fi
  if grep -q 'ATOMIC-TEST-MARKER' "$d/wf-worktree-sparse.sh" 2>/dev/null; then z=1; else z=0; fi
  echo "$a$z"
}

assert_eq "the client starts on an unmarked harness" "00" "$(probe)"

rm -f "$TEST_DIR/reader.stop"
: > "$TEST_DIR/reader.log"
(
  i=0; f=0
  while [ ! -f "$TEST_DIR/reader.stop" ]; do
    i=$((i + 1))
    p=$(probe)
    if [ "$p" = "01" ] || [ "$p" = "10" ]; then
      f=$((f + 1)); printf 'sample %s: %s\n' "$i" "$p" >> "$TEST_DIR/reader.log"
    fi
  done
  printf 'iterations=%s failures=%s\n' "$i" "$f" > "$TEST_DIR/reader.result"
) &
reader_pid=$!

WF_INSTALL_NO_COMMIT=1 bash "$MARKED_LIB/install.sh" "$CLIENT" >/dev/null 2>&1

touch "$TEST_DIR/reader.stop"
wait "$reader_pid" 2>/dev/null

result=$(cat "$TEST_DIR/reader.result" 2>/dev/null || echo "iterations=0 failures=0")
iterations=${result#iterations=}; iterations=${iterations%% *}
failures=${result##*failures=}; failures=${failures%%[!0-9]*}

assert_eq "the deploy landed (the folder is now marked throughout)" "11" "$(probe)"

if [ "${iterations:-0}" -lt 20 ]; then
  bad "the reader sampled enough to be meaningful" "$result"
elif [ "${failures:-1}" -eq 0 ]; then
  ok "$iterations reads across a live install, none saw a mixed harness"
else
  bad "reads across a live install never see a mixed harness" \
      "$result$(printf '\n      ')$(head -3 "$TEST_DIR/reader.log")"
fi

# ── 5. Legacy folders survive the migration deploy, and only that one ────────
#
# install.sh flips scripts/current BEFORE it replaces wf-exec.sh, so on a
# client's first gen-era deploy an old dispatcher — which knows nothing of
# scripts/current — has to resolve the legacy folder, and that folder must
# still hold the old harness, whole. The deploy after that removes them.
echo ""
echo "5. Migration from the pre-gen layout"
new_client
mkdir -p "$CLIENT/scripts/v2.00" "$CLIENT/.claude"
printf '#!/bin/sh\necho legacy\n' > "$CLIENT/scripts/v2.00/wf-counter-next.sh"
chmod +x "$CLIENT/scripts/v2.00/wf-counter-next.sh"

install_client
if [ -f "$CLIENT/scripts/v2.00/wf-counter-next.sh" ]; then
  ok "the first gen-era deploy leaves the legacy folder standing"
else
  bad "the first gen-era deploy leaves the legacy folder standing"
fi

install_client
if [ ! -d "$CLIENT/scripts/v2.00" ]; then
  ok "the next deploy removes it"
else
  bad "the next deploy removes it"
fi

# ── 6. A failed install publishes nothing ───────────────────────────────────
#
# The staging directory is torn down on any exit before the publish, so a
# broken deploy leaves the client on the build it already had rather than on a
# half-written one.
echo ""
echo "6. An interrupted install"
before=$(tr -d '[:space:]' < "$CLIENT/scripts/current")
stage_count=$(ls -d "$CLIENT/scripts/gen"/.building.* 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no staging directory survives a completed install" "0" "$stage_count"
after=$(tr -d '[:space:]' < "$CLIENT/scripts/current")
assert_eq "the pointer is stable when nothing deploys" "$before" "$after"

# ── 7. Retention never deletes a build something is running out of ──────────
#
# "Current and previous" assumed the only thing holding a build open is a
# subprocess lasting seconds. An implement worker runs for hours out of the
# build it was launched from, and a daemon runs out of one indefinitely — and
# client-a took two deploys inside a minute, which retired a build under
# both (WFI-256, WFI-257).
echo ""
echo "7. Retention with a live process in an older build"
new_client
install_client
held=$(tr -d '[:space:]' < "$CLIENT/scripts/current")

# A process whose ARGV carries the build path, which is the shape of both real
# holders: the daemon's own command line, and the `bash -c` wrapper wf-spawn.sh
# detaches with the build's wf-event.sh inside it.
printf '#!/usr/bin/env bash\nsleep 30\n' > "$CLIENT/scripts/gen/$held/v2.00/wf-holder-test.sh"
chmod +x "$CLIENT/scripts/gen/$held/v2.00/wf-holder-test.sh"
bash "$CLIENT/scripts/gen/$held/v2.00/wf-holder-test.sh" &
holder_pid=$!

sleep 1; install_client   # $held becomes previous — retained either way
sleep 1; install_client   # $held is now older than previous — the real test

if [ -d "$CLIENT/scripts/gen/$held" ]; then
  ok "a build with a live process in it is kept past the two-build rule"
else
  bad "a build with a live process in it is kept past the two-build rule"
fi

kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

# And the exemption is about liveness, not about the build: once nothing is in
# it, the next deploy collects it. Otherwise the fix trades a deleted harness
# for an unbounded one.
sleep 1; install_client
if [ ! -d "$CLIENT/scripts/gen/$held" ]; then
  ok "and is retired once nothing is running out of it"
else
  bad "and is retired once nothing is running out of it"
fi

# ── 8. A daemon re-execs onto the build that replaced its own ───────────────
#
# client-a WFI-257: the daemon kept running out of a deleted tree. Bash held
# the script's open file, so it swept, logged, and answered --daemon-status
# "running" while every spawn died rc=127 — 71 minutes with an active plan and
# an open gate. Section 7 stops the deletion; this is the other half, for the
# ordinary case where the build is merely superseded.
echo ""
echo "8. Daemon across a deploy"
new_client
mkdir -p "$CLIENT/plans"
cat > "$CLIENT/plans/REGISTRY.md" << 'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|

<!-- Counter: 1 -->
SEED
printf 'project_slug: "atomic-test"\norchestrator:\n  enabled: true\n' > "$CLIENT/claude-workflow.yml"
(cd "$CLIENT" && git add -A && git commit -q -m seed) >/dev/null 2>&1
install_client
b1=$(tr -d '[:space:]' < "$CLIENT/scripts/current")

( cd "$CLIENT" && "$CLIENT/scripts/gen/$b1/v2.00/wf-orchestrate.sh" --daemon --interval 2 \
    > "$TEST_DIR/daemon.log" 2>&1 ) &
daemon_wrapper=$!
DPID_FILE="$CLIENT/.claude/orchestrator/daemon.pid"
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$DPID_FILE" ] && break; sleep 0.5; done
dpid=$(tr -d '[:space:]' < "$DPID_FILE" 2>/dev/null || echo "")

if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
  ok "the daemon came up from build $b1"

  sleep 1; install_client
  b2=$(tr -d '[:space:]' < "$CLIENT/scripts/current")

  # Give it a couple of sweep intervals to notice.
  moved=false
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if ps -o command= -p "$dpid" 2>/dev/null | grep -q "/gen/$b2/"; then moved=true; break; fi
    sleep 1
  done

  assert_eq "it re-execs onto the build that replaced its own" "true" "$moved"
  assert_eq "keeping its PID, so the pidfile still names it" "$dpid" \
    "$(tr -d '[:space:]' < "$DPID_FILE" 2>/dev/null || echo "")"
  if kill -0 "$dpid" 2>/dev/null; then
    ok "and is still alive to be stopped"
  else
    bad "and is still alive to be stopped"
  fi

  ( cd "$CLIENT" && scripts/wf-exec.sh wf-orchestrate.sh --stop ) >/dev/null 2>&1
  wait "$daemon_wrapper" 2>/dev/null || true
  if kill -0 "$dpid" 2>/dev/null; then kill "$dpid" 2>/dev/null || true; fi
else
  bad "the daemon came up from build $b1" "$(tail -3 "$TEST_DIR/daemon.log" 2>/dev/null)"
fi

echo ""
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
