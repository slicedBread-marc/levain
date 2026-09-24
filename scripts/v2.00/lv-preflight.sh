#!/usr/bin/env bash
# lv-preflight.sh [--quiet]
#
# Checks the external services this project's E2E suite needs before the suite
# runs, so a missing dependency is reported as a missing dependency rather than
# as a failing batch of commits.
#
# WHY THIS EXISTS
#
# /lv-release step 7 runs the full suite against the local merge and treats a
# red result as "E2E tests failed on the local merge" — the commits are what
# stands accused. That is only sound if the suite is self-contained. client-e
# WFI-028: 9 of 70 E2E tests failed with 30s response timeouts on a merge
# containing no src/ changes at all. The tests that exercise /account/login
# drive an OIDC challenge against `Oidc:Authority` (http://localhost:8084),
# client-c's local dev issuer, which was not running. Starting it and
# re-running, with no code change, turned 2 failed / 5 passed in 1m6s into
# 7 passed / 0 failed in 8s. The rollback did its job and nothing unsafe
# followed, but the report sent an operator hunting a regression that did not
# exist.
#
# DECLARING PREREQUISITES
#
# In this project's own claude-workflow.yml — the harness cannot guess them:
#
#   e2ePrereqs:
#     - "dev issuer:http://localhost:8084/.well-known/openid-configuration"
#     - "database:pg_isready -q -h localhost"
#
# One name, one check, joined by the FIRST ':' — same shape as `dependents:`.
# A check starting http:// or https:// is fetched (2s connect, 5s total);
# anything else is run as a shell command and passes on exit 0. Keep each one
# cheap: this runs before every release.
#
# Prefer a probe that is specific. `curl localhost:8084` proves a socket is
# open; the discovery endpoint proves the issuer is actually serving.
#
# Output is one line per prerequisite — `ok <name>` or `DOWN <name> — <check>`
# — and a summary to stderr. Exit 0 when every prerequisite is up OR none are
# declared (a project with a self-contained suite is not in trouble, it is
# just quiet), 1 when any is down.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

quiet=false
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet)   quiet=true; shift ;;
    -h|--help) wf_usage; exit 0 ;;
    -*)        wf_bad_option "$1" ;;
    *)         echo "Error: unexpected argument '$1'" >&2; exit 1 ;;
  esac
done

names=()
checks=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  names+=("${entry%%:*}")
  checks+=("${entry#*:}")
done < <(wf_cfg_list e2ePrereqs)

if [ "${#names[@]}" -eq 0 ]; then
  $quiet || echo "lv-preflight: no e2ePrereqs declared — nothing to check" >&2
  exit 0
fi

down=0
for i in "${!names[@]}"; do
  name="${names[$i]}"
  check="${checks[$i]}"
  ok=false
  case "$check" in
    http://*|https://*)
      # --fail so a 4xx/5xx is a failure, not "the socket answered". A
      # redirect is fine — many discovery endpoints issue one.
      if curl -fsSL --connect-timeout 2 --max-time 5 -o /dev/null "$check" 2>/dev/null; then ok=true; fi
      ;;
    *)
      if ( eval "$check" ) >/dev/null 2>&1; then ok=true; fi
      ;;
  esac
  if $ok; then
    $quiet || echo "ok $name"
  else
    echo "DOWN $name — $check"
    down=$((down + 1))
  fi
done

if [ "$down" -gt 0 ]; then
  echo "lv-preflight: $down of ${#names[@]} prerequisite(s) not reachable — a suite run now would fail for reasons that have nothing to do with the code." >&2
  exit 1
fi

$quiet || echo "lv-preflight: ${#names[@]} prerequisite(s) up" >&2
exit 0
