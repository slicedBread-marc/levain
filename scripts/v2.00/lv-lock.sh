#!/usr/bin/env bash
# lv-lock.sh — named advisory locks, repo-scoped.
#
# Two ways to use it:
#
#   1. Sourced (preferred inside other lv-* scripts):
#        source "$(dirname "$0")/lv-lock.sh"
#        wf_lock_acquire registry
#        ...mutate...
#        # released automatically on exit
#
#   2. Executed, wrapping a command:
#        lv-lock.sh run registry -- ./some-script.sh args
#
# Why mkdir: it is the only atomic create-or-fail primitive available on both
# macOS and Linux without flock(1) (macOS ships no flock).
#
# Lock location: <git-common-dir>/wf-locks/<name>/ — shared across every
# worktree of the repo, isolated from other repos on the machine.
#
# Re-entrancy: acquiring a lock exports LV_LOCK_HELD_<NAME>=1, so a child
# process that acquires the same lock is a no-op instead of a deadlock. This
# is what lets the orchestrator hold `registry` while invoking scripts that
# also lock `registry`.
#
# Stale locks are reclaimed when the owning PID is dead, or after
# LV_LOCK_TTL seconds (default 300) regardless — a worker killed with -9
# in another process tree must not wedge the pipeline forever.
#
# Tunables (env): LV_LOCK_TIMEOUT (default 30s), LV_LOCK_TTL (default 300s).

# ── Internals ─────────────────────────────────────────────────────────────

_wf_lock_root() {
  local common
  if common=$(git rev-parse --git-common-dir 2>/dev/null) && [ -n "$common" ]; then
    # --git-common-dir may be relative to CWD
    case "$common" in
      /*) printf '%s/wf-locks' "$common" ;;
      *)  printf '%s/%s/wf-locks' "$PWD" "$common" ;;
    esac
    return 0
  fi
  # Not a git repo — fall back to a CWD-derived temp path
  printf '%s/wf-locks-%s' "${TMPDIR:-/tmp}" "$(printf '%s' "$PWD" | tr -c 'A-Za-z0-9' '_')"
}

# Env-var-safe form of a lock name: registry → REGISTRY, develop-merge → DEVELOP_MERGE
_wf_lock_var() {
  printf 'LV_LOCK_HELD_%s' "$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
}

# Locks this process actually owns (space-separated), so release only removes ours.
LV_LOCK_OWNED="${LV_LOCK_OWNED:-}"

wf_lock_release_all() {
  local status=$?
  local root name
  root=$(_wf_lock_root)
  for name in $LV_LOCK_OWNED; do
    rm -rf "$root/$name"
  done
  LV_LOCK_OWNED=""
  return $status
}

# ── Public API ────────────────────────────────────────────────────────────

# wf_lock_acquire <name>
# Blocks until the lock is held (or LV_LOCK_TIMEOUT elapses, then exits 1).
# Installs an EXIT trap that releases every lock this process owns.
wf_lock_acquire() {
  local name="${1:?wf_lock_acquire: lock name required}"
  local timeout="${LV_LOCK_TIMEOUT:-30}"
  local ttl="${LV_LOCK_TTL:-300}"
  local var lockdir elapsed=0 lock_pid lock_ts age now

  var=$(_wf_lock_var "$name")
  # Already held by us or an ancestor — nothing to do.
  if [ -n "${!var:-}" ]; then
    return 0
  fi

  lockdir="$(_wf_lock_root)/$name"
  mkdir -p "$(dirname "$lockdir")"

  while ! mkdir "$lockdir" 2>/dev/null; do
    lock_pid=$(cat "$lockdir/pid" 2>/dev/null || echo "")
    lock_ts=$(cat "$lockdir/ts" 2>/dev/null || echo "")
    now=$(date +%s)
    age=$(( now - ${lock_ts:-$now} ))

    if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
      echo "lv-lock($name): reclaiming — owner PID $lock_pid is dead" >&2
      rm -rf "$lockdir"
      continue
    fi
    if [ -n "$lock_ts" ] && [ "$age" -ge "$ttl" ]; then
      echo "lv-lock($name): reclaiming — held ${age}s (TTL ${ttl}s)" >&2
      rm -rf "$lockdir"
      continue
    fi
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "lv-lock($name): timed out after ${timeout}s (held by PID ${lock_pid:-unknown})" >&2
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  echo $$ > "$lockdir/pid"
  date +%s > "$lockdir/ts"

  LV_LOCK_OWNED="$LV_LOCK_OWNED $name"
  export "$var=1"
  trap wf_lock_release_all EXIT
  return 0
}

# wf_lock_release <name> — explicit early release. Optional; EXIT handles it.
wf_lock_release() {
  local name="${1:?wf_lock_release: lock name required}"
  local var
  var=$(_wf_lock_var "$name")
  case " $LV_LOCK_OWNED " in
    *" $name "*)
      rm -rf "$(_wf_lock_root)/$name"
      LV_LOCK_OWNED=$(printf '%s' "$LV_LOCK_OWNED" | tr ' ' '\n' | grep -vx "$name" | tr '\n' ' ')
      unset "$var"
      ;;
  esac
}

# ── Durable registry writes ───────────────────────────────────────────────
#
# wf_registry_commit <message>
#
# Every script that rewrites a row in plans/REGISTRY.md calls this immediately
# after the write, while it still holds the `registry` lock. A row left dirty
# on the develop root does not stay yours: another worker's
# `git stash push --include-untracked` takes it (WFI-064/065, ticks and a whole
# ready→active transition vanished mid-run), and another worker's pathspec
# commit carries it under a message about something else (WFI-061, one
# session's Tags edit shipped inside another's spec commit). Pathspec scoping
# cannot separate two edits to ONE file; only committing promptly can.
#
# Never fatal: the write the caller asked for has already landed.
wf_registry_commit() {
  local msg="$1" dir root
  # Nothing to make durable outside a repository — and a caller under
  # `set -euo pipefail` must not die because git had no opinion.
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //') || root=""
  [ -n "$root" ] || root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  [ -n "$root" ] || root="$PWD"
  if ! ( cd "$root" && "$dir/lv-commit.sh" "$msg" --add plans/REGISTRY.md >/dev/null ); then
    echo "lv-lock: registry write is staged but could not be committed — commit plans/REGISTRY.md before another worker does" >&2
  fi
}

# ── Executed directly ─────────────────────────────────────────────────────

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail

  case "${1:-}" in
    run)
      shift
      lock_name="${1:?Usage: lv-lock.sh run <name> -- <command> [args...]}"
      shift
      [ "${1:-}" = "--" ] && shift
      [ $# -gt 0 ] || { echo "Usage: lv-lock.sh run <name> -- <command> [args...]" >&2; exit 1; }
      wf_lock_acquire "$lock_name"
      "$@"
      ;;
    status)
      root=$(_wf_lock_root)
      if [ -d "$root" ]; then
        for d in "$root"/*/; do
          [ -d "$d" ] || continue
          printf '%s\tpid=%s\theld=%ss\n' \
            "$(basename "$d")" \
            "$(cat "$d/pid" 2>/dev/null || echo '?')" \
            "$(( $(date +%s) - $(cat "$d/ts" 2>/dev/null || date +%s) ))"
        done
      fi
      ;;
    clear)
      # Escape hatch: drop every lock. Only safe when nothing is running.
      rm -rf "$(_wf_lock_root)"
      echo "lv-lock: all locks cleared"
      ;;
    *)
      cat >&2 <<'USAGE'
Usage:
  lv-lock.sh run <name> -- <command> [args...]   run a command under a lock
  lv-lock.sh status                              list currently held locks
  lv-lock.sh clear                               drop all locks (nothing running!)

Or source it and call wf_lock_acquire <name> / wf_lock_release <name>.
USAGE
      exit 1
      ;;
  esac
fi
