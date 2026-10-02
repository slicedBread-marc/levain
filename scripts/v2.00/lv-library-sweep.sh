#!/usr/bin/env bash
# lv-library-sweep.sh — a blind library sweep: the library's top open client
# issues, fixed by a headless session nobody watches, started from the rack (LVI-031).
#
#   lv-library-sweep.sh count  <library>            open client issues, summed
#   lv-library-sweep.sh start  <library> <state>    preflight, then detach a run
#   lv-library-sweep.sh run    <library> <state>    the detached body (start calls it)
#   lv-library-sweep.sh resolve-pending <library> <state>
#                                                   resolve what a held sweep fixed,
#                                                   once a deploy has shipped it
#
# <state> is the coordinator's gitignored .claude/orchestrator/library-sweep/:
#   pid        the run's PID while one is going; the board says "sweeping…"
#   result     one line once it is done: fixed N · left M · deployed vX | held for review
#   latest     the path of the last run's log, under logs/
#   pending    LVI<TAB>client<TAB>sha for fixes committed but held from deploy
#   settings.json  the permission baseline the session runs under
#
# WHO DECIDES WHAT
#
# The session diagnoses, fixes and commits. Everything with a consequence past
# the library's own history is decided here, in bash, after it exits: whether
# its commits deploy, and which issues are resolved. A prompt that says "don't
# deploy a fix to the permission baseline" is a request; a `git diff --name-only`
# against a list is a rule. So the session is told it never runs deploy-all.sh
# or --resolve, and the guard-file check below does not depend on it listening.
#
# THE LOCK
#
# This process takes LIBRARY-LOCK.md as holder `blind-sweep`, before the session
# starts, and releases it on every exit. LV_SESSION_PID names this process, and
# the session inherits it, so lock.sh reports the lock as the session's own and
# a stale lock is exactly "this process is gone". A held or stale lock refuses
# the run. Stealing is the operator's call (the work it names may be
# half-applied), never a board key's.
#
# THE BASELINE
#
# The session runs with --dangerously-skip-permissions, like a pipeline worker,
# and under the same fail-closed guard: lv-guard-baseline.sh from THIS
# directory — the coordinator's deployed copy, not the library tree the session
# is editing, so a sweep that touches the guard is not guarded by its own edit.
# No guard on disk, no sweep.
#
# NEVER --upstream. Public issues and pull requests are applied only after the
# operator has read every line (docs/upstream-intake.md). The prompt says so,
# and nothing here offers the session that list.
#
# Test seams: LV_SWEEP_CLAUDE replaces `claude`; LV_RACK_SUITE replaces the
# suite (the same seam the rack's `U` reads); LV_SWEEP_MODEL picks a model.
#
# Exit: 0 started / done · 3 refused (the reason on stdout) · 1 usage or error.

set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
HERE="$(dirname "$SELF")"

# A fix touching any of these is committed and never deployed by a sweep: the
# baseline the workers run under, the denylist that keeps private names out of
# the public copy, the deploy itself, and this script. "held for review" on the
# board; the operator reads it and presses U.
GUARD_PATHS_RE='^(scripts/v[0-9.]+/lv-guard-baseline\.sh|scripts/v[0-9.]+/lv-library-sweep\.sh|scripts/v[0-9.]+/hooks\.default/(secrets-deny-patterns|provider-deny|publish-denylist)|templates/hooks/settings-merge\.py|check-denylist\.sh|githooks/.*|deploy-all\.sh|install\.sh)$'

# Top N faults per sweep; duplicates of one fault across clients are one slot.
SLOTS=3

usage() { sed -n '2,12p' "$SELF" | sed 's/^# \{0,1\}//' >&2; exit 1; }

cmd="${1:-}"; LIB="${2:-}"; STATE="${3:-}"
[ -n "$cmd" ] && [ -n "$LIB" ] || usage

# count — the sum of sweep-issues.sh --count. Nothing printed when the library
# has no sweep-issues.sh or it fails outright, so the board draws no number
# rather than a wrong zero.
count() {
  [ -x "$LIB/sweep-issues.sh" ] || return 1
  local out
  out=$(cd "$LIB" && ./sweep-issues.sh --count 2>/dev/null)
  # Exit 1 means "every client is clean", which is an answer; no output is not.
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | awk -F': *' 'NF >= 2 && $2 ~ /^[0-9]+$/ { s += $2 } END { print s + 0 }'
}

refuse() { printf 'refused — %s\n' "$1"; exit 3; }

lock() { (cd "$LIB" && LV_SESSION_PID="$LOCK_PID" ./lock.sh "$@"); }

running() {
  local pid=""
  [ -f "$STATE/pid" ] && IFS= read -r pid < "$STATE/pid"
  [ -n "$pid" ] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null
}

# The checks `start` refuses on, again in `run` — between the key and the
# detached process the world can move.
preflight() {
  [ -d "$LIB" ] || refuse "no library at $LIB"
  [ -x "$LIB/lock.sh" ] || refuse "the library has no lock.sh"
  running && refuse "a sweep is already running (PID $(cat "$STATE/pid"))"
  [ -x "$HERE/lv-guard-baseline.sh" ] || refuse "lv-guard-baseline.sh is not beside this script; a sweep never runs without the permission baseline"
  command -v python3 >/dev/null 2>&1 || refuse "python3 is missing, and the baseline needs it"
  command -v "${LV_SWEEP_CLAUDE:-claude}" >/dev/null 2>&1 || refuse "${LV_SWEEP_CLAUDE:-claude} is not on PATH"
  local n; n=$(count) || refuse "sweep-issues.sh --count gave no answer"
  [ "$n" -gt 0 ] || refuse "no open client issues"
  if [ -n "$(git -C "$LIB" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    refuse "the library has uncommitted changes — somebody's work in progress"
  fi
  (cd "$LIB" && ./lock.sh status >/dev/null 2>&1) || refuse "LIBRARY-LOCK.md is held or stale"
}

settings_file() {
  # Fail closed: any non-zero from the guard is a refusal, exit 2 being how
  # PreToolUse blocks. The deny rules are the secret reads settings-merge.py
  # installs for every session; the guard adds the pack's own.
  python3 - "$HERE/lv-guard-baseline.sh" > "$STATE/settings.json" <<'PY'
import json, shlex, sys
guard = shlex.quote(sys.argv[1])
cmd = f"[ -x {guard} ] || {{ echo 'permission baseline: guard not on disk; refusing' >&2; exit 2; }}; {guard}; rc=$?; [ $rc -eq 0 ] && exit 0; exit 2"
print(json.dumps({
    "permissions": {"deny": ["Read(~/.ssh/**)", "Read(~/.aws/credentials)",
                             "Read(~/.config/gh/hosts.yml)", "Read(~/.netrc)"]},
    "hooks": {"PreToolUse": [{"matcher": "*", "hooks": [{"type": "command", "command": cmd}]}]},
}, indent=2))
PY
}

prompt() {
  cat <<EOF
You are running a BLIND library sweep: unattended, headless, started from the
coordinator's board. Nobody is watching and nobody will answer a question.
Your working directory is the harness library. Read its CLAUDE.md first.

LIBRARY-LOCK.md is already held for you (holder: blind-sweep); \`./lock.sh status\`
reports it as yours. Do not take, steal or release it.

1. Run \`./sweep-issues.sh\`. NEVER pass --upstream: public issues and pull
   requests are never applied unread.
2. Choose at most ${SLOTS} faults, OLDEST FIRST by the timestamp in each issue's
   heading. The same fault reported by several clients is one slot.
3. For each, in that order: diagnose it and fix the cause in this library,
   following CLAUDE.md and, for any SKILL.md, docs/prompt-contract.md. Add or
   extend a test that fails without the fix. Run the tests that cover it.
   Commit the moment they pass: one commit per fault, the issue IDs in the
   subject, LV_BUMP stated, only that fix's files. Do everything else
   CLAUDE.md says to do after a commit.
4. A fault you cannot fix with confidence, or that needs the operator to
   decide something, you leave open: revert your edits for it and say why.
   Do not take another fault in its place.
5. NEVER run ./deploy-all.sh, ./sweep-issues.sh --resolve, or git push. The
   process that started you deploys and resolves after you exit, and only
   when every check it runs holds.
6. Leave no uncommitted change to a tracked file.

End your final message with one line per fix you committed, and one per
client when a fault was reported by several:
SWEEP_FIXED <issue-id> <client> <commit-sha>
and one line per fault you looked at and left:
SWEEP_LEFT <issue-id> <client> <one-line reason>
EOF
}

finish() { printf '%s\n' "$1" > "$STATE/result"; printf '\n== result: %s\n' "$1"; }

# hold <reason> — the fixes stay committed and pending; the deploy is the operator's.
hold() {
  printf '%s\n' "$fixed" | grep . >> "$STATE/pending"
  finish "fixed $n_fixed · left $(count) · held for review — $1"
}

run() {
  LOCK_PID=$$
  local why
  if ! why=$(preflight); then
    finish "$why"; exit 3
  fi
  printf '%s\n' "$$" > "$STATE/pid"
  if ! lock take blind-sweep "blind sweep from the board — top ${SLOTS} client issues" >/dev/null 2>&1; then
    rm -f "$STATE/pid"
    finish "refused — LIBRARY-LOCK.md is held or stale"; exit 3
  fi
  trap 'lock release >/dev/null 2>&1; rm -f "$STATE/pid"' EXIT
  printf '== blind sweep %s in %s\n' "$(date -u +%FT%TZ)" "$LIB"
  local start_sha out rc
  start_sha=$(git -C "$LIB" rev-parse HEAD)
  settings_file || { finish "failed — could not write the baseline settings"; exit 1; }

  printf '== session (baseline: %s)\n' "$HERE/lv-guard-baseline.sh"
  out=$(cd "$LIB" && LV_UNATTENDED=1 LV_SESSION_PID="$LOCK_PID" \
        "${LV_SWEEP_CLAUDE:-claude}" -p ${LV_SWEEP_MODEL:+--model "$LV_SWEEP_MODEL"} \
        --dangerously-skip-permissions --settings "$STATE/settings.json" "$(prompt)" < /dev/null 2>&1)
  rc=$?
  printf '%s\n' "$out"
  printf '== session exited %s\n' "$rc"

  # A fix is only resolved against a commit this sweep made.
  fixed=$(printf '%s\n' "$out" | grep -E '^SWEEP_FIXED [^ ]+ [^ ]+ [0-9a-f]{7,}' | awk '{ print $2 "\t" $3 "\t" $4 }' | sort -u \
    | while IFS=$'\t' read -r id client sha; do
        full=$(git -C "$LIB" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) || continue
        [ "$full" != "$start_sha" ] && git -C "$LIB" merge-base --is-ancestor "$start_sha" "$full" \
          && git -C "$LIB" merge-base --is-ancestor "$full" HEAD \
          && printf '%s\t%s\t%s\n' "$id" "$client" "$full"
      done)
  n_fixed=$(printf '%s' "$fixed" | grep -c .)

  if [ -n "$(git -C "$LIB" status --porcelain --untracked-files=no)" ]; then
    git -C "$LIB" status --short --untracked-files=no
    hold "the session left uncommitted changes"; exit 0
  fi
  if [ "$(git -C "$LIB" rev-list --count "$start_sha..HEAD")" -eq 0 ]; then
    finish "fixed 0 · left $(count)$([ "$rc" -ne 0 ] && printf ' · session exited %s' "$rc")"; exit 0
  fi

  local guarded
  guarded=$(git -C "$LIB" diff --name-only "$start_sha" HEAD | grep -E "$GUARD_PATHS_RE")
  if [ -n "$guarded" ]; then
    printf '== guard files changed, not deploying:\n%s\n' "$guarded"
    hold "guard files changed: $(printf '%s' "$guarded" | tr '\n' ' ' | sed 's/ $//')"; exit 0
  fi

  printf '== suite\n'
  suite || { hold "the suite is red"; exit 0; }
  printf '== deploy\n'
  (cd "$LIB" && ./deploy-all.sh) < /dev/null || { hold "deploy-all.sh failed"; exit 0; }
  printf '%s\n' "$fixed" | grep . >> "$STATE/pending"
  resolve_pending
  finish "fixed $n_fixed · left $(count) · deployed v$(head -1 "$LIB/VERSION")"
}

# suite — every tests/*.sh, naming each failure; LV_RACK_SUITE instead when set.
suite() {
  if [ -n "${LV_RACK_SUITE:-}" ]; then (cd "$LIB" && bash -c "$LV_RACK_SUITE"); return; fi
  local t red=0
  for t in "$LIB"/tests/*.sh; do
    [ -f "$t" ] || continue
    (cd "$LIB" && bash "$t") >/dev/null 2>&1 || { printf '  FAILED %s\n' "${t#$LIB/}"; red=1; }
  done
  return "$red"
}

# resolve_pending — every pending fix whose commit the library carries,
# resolved and dropped from the file; anything else stays for next time.
resolve_pending() {
  [ -s "$STATE/pending" ] || return 0
  local v keep id client sha
  v=$(head -1 "$LIB/VERSION")
  keep=$(mktemp "$STATE/pending.XXXXXX")
  while IFS=$'\t' read -r id client sha; do
    [ -n "$id" ] || continue
    if git -C "$LIB" merge-base --is-ancestor "$sha" HEAD 2>/dev/null \
       && (cd "$LIB" && ./sweep-issues.sh --resolve "$id" --client "$client" "fixed in v$v (${sha:0:7}) — blind sweep") >/dev/null 2>&1; then
      printf 'resolved %s (%s)\n' "$id" "$client"
    else
      printf '%s\t%s\t%s\n' "$id" "$client" "$sha" >> "$keep"
    fi
  done < "$STATE/pending"
  mv -f "$keep" "$STATE/pending"
  [ -s "$STATE/pending" ] || rm -f "$STATE/pending"
}

case "$cmd" in
  count) count ;;
  start)
    [ -n "$STATE" ] || usage
    mkdir -p "$STATE/logs" || exit 1
    preflight
    log="$STATE/logs/$(date -u +%Y%m%dT%H%M%SZ).log"
    printf '%s\n' "$log" > "$STATE/latest"
    rm -f "$STATE/result"
    # Detached the way deploy-all.sh restarts a daemon: a new session where one
    # can be had, every descriptor pointed away, and `exec` so no shell
    # lingers holding the board's terminal.
    if command -v setsid >/dev/null 2>&1; then
      ( exec setsid nohup "$SELF" run "$LIB" "$STATE" ) >> "$log" 2>&1 < /dev/null &
    else
      ( exec nohup "$SELF" run "$LIB" "$STATE" ) >> "$log" 2>&1 < /dev/null &
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      { running || [ -f "$STATE/result" ]; } && break
      sleep 0.2
    done
    if [ -f "$STATE/result" ]; then cat "$STATE/result"; exit 3; fi
    printf 'sweeping — log: %s\n' "$log"
    ;;
  run)
    [ -n "$STATE" ] || usage
    mkdir -p "$STATE" || exit 1
    run
    ;;
  resolve-pending)
    [ -n "$STATE" ] || usage
    resolve_pending
    ;;
  *) usage ;;
esac
