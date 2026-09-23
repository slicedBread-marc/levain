#!/usr/bin/env bash
# wf-retry.sh [--attempts N] [--label TEXT] -- <command> [args...]
#
# Runs a command that talks to the network, and retries it ONLY when it failed
# for a reason that retrying can fix.
#
# WHY THIS EXISTS
#
# client-a's PLN-157 (WFI-186) reached the end of a clean test run — 1734 of
# 1734 passing — and then lost the exit path to GitHub: `git push` timed out
# after 2m, the `gh` API answered HTTP 503, and wf-merge-release.sh timed out
# fetching. Every one of those is a weather report about github.com. None of
# them is a fact about the plan, the code or the merge.
#
# What the pipeline did with them is the problem: a failed push opens a
# `merge-failed` gate, which parks the plan until a human reads the error and
# says "try again". That is a person doing a computer's retry, and the answer
# is known before they are asked.
#
# WHAT IS NOT RETRIED, AND WHY THAT IS THE IMPORTANT HALF
#
# A retry loop that cannot tell "the network wobbled" from "you may not push to
# this branch" is worse than none: it turns an instant, accurate refusal into
# the same refusal three minutes later, and it does that in front of a human
# waiting on a gate whose question is now stale. So the default is NOT to
# retry. A failure is retried only when its output carries a transient
# signature — a timeout, a 5xx, a reset connection, a DNS failure, a rate limit
# — and anything else fails immediately with its own exit status, which is what
# the caller's gate question wants to quote.
#
# The command's stdout and stderr are passed through as they happen, so a
# caller reading output still sees it. On the final failure the exit status is
# the command's own, never this script's.
#
# --attempts N   total tries, including the first (default 3)
# --label TEXT   what to call this in the retry notice (default: the command)
# --tempfail     when every attempt failed transiently, exit 75 (EX_TEMPFAIL)
#                instead of the command's status. Lets a caller tell "GitHub is
#                still down" from "GitHub said no": the first is left for the
#                next sweep to retry, the second is a gate (coordinator WFI-006).
#
# Exit: the command's status; 75 with --tempfail when it never stopped being
# transient. 64 for bad usage here.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

attempts=3
label=""
tempfail=false

while [ $# -gt 0 ]; do
  case "$1" in
    --attempts) attempts="${2:?--attempts requires a number}"; shift 2 ;;
    --label)    label="${2:?--label requires text}"; shift 2 ;;
    --tempfail) tempfail=true; shift ;;
    --)         shift; break ;;
    -*)         echo "wf-retry: unknown option '$1'" >&2; exit 64 ;;
    *)          break ;;
  esac
done

[ $# -gt 0 ] || { echo "Usage: $0 [--attempts N] [--label TEXT] [--tempfail] -- <command> [args...]" >&2; exit 64; }
case "$attempts" in
  ''|*[!0-9]*) echo "wf-retry: --attempts must be a number, got '$attempts'" >&2; exit 64 ;;
esac
[ "$attempts" -ge 1 ] || attempts=1
[ -n "$label" ] || label="$1"

# The transient set. Deliberately explicit rather than "anything that is not a
# known-permanent error": an unrecognised failure is treated as permanent, so a
# new kind of refusal surfaces at once instead of being retried into a gate
# three minutes late.
is_transient() {
  printf '%s' "$1" | grep -qiE \
    'timed out|timeout|operation too slow|could not resolve host|couldn'\''t resolve|temporary failure in name resolution|connection (reset|refused|timed out)|connection was reset|unexpected EOF|early EOF|TLS handshake|SSL_ERROR|HTTP 5[0-9][0-9]|502 Bad Gateway|503 Service|504 Gateway|Internal Server Error|server error|rate limit|secondary rate|try again later|temporarily unavailable|remote end hung up|RPC failed|network is unreachable|no route to host'
}

# Backoff, in seconds, indexed by the attempt that just failed. GitHub's
# secondary rate limiter and a 503 both want tens of seconds, not one.
backoff_for() {
  case "$1" in
    1) echo 5 ;;
    2) echo 15 ;;
    3) echo 45 ;;
    *) echo 60 ;;
  esac
}

attempt=1
while : ; do
  # tee to stderr as it runs, and keep a copy to classify afterwards. The
  # caller sees the output live either way; without the copy there is nothing
  # to match a signature against.
  out=$( { "$@" 2>&1 1>&3 3>&- | tee /dev/stderr; } 3>&1 )
  rc=${PIPESTATUS[0]}
  # `out` holds stderr; a command that reports its failure on stdout (gh does,
  # for some subcommands) needs that too, so capture both when it failed.
  if [ "$rc" -eq 0 ]; then
    [ "$attempt" -gt 1 ] && echo "wf-retry: $label succeeded on attempt $attempt" >&2
    exit 0
  fi

  if [ "$attempt" -ge "$attempts" ]; then
    if [ "$attempt" -gt 1 ]; then
      echo "wf-retry: $label failed $attempt times — giving up (rc=$rc)" >&2
      wf_event retry-exhausted "—" "$label failed $attempt times, rc=$rc"
    fi
    if $tempfail && is_transient "$out"; then
      echo "wf-retry: $label is still failing transiently — exit 75 (try again later)" >&2
      exit 75
    fi
    exit "$rc"
  fi

  if ! is_transient "$out"; then
    # Not the network. Hand the caller its answer now, while its gate question
    # would still be describing what actually happened.
    exit "$rc"
  fi

  wait_for=$(backoff_for "$attempt")
  echo "wf-retry: $label failed with a transient error (rc=$rc) — retrying in ${wait_for}s (attempt $((attempt + 1))/$attempts)" >&2
  sleep "$wait_for"
  attempt=$((attempt + 1))
done
