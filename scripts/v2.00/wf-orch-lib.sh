#!/usr/bin/env bash
# wf-orch-lib.sh — shared helpers for the orchestrator. Source it; don't run it.
#
#   source "$(dirname "$0")/wf-orch-lib.sh"
#
# Everything orchestrator-related is anchored to the DEVELOP ROOT, never to the
# current worktree. A worker running in feature/PLN-097-foo must open a gate
# that /wf-attend on develop can see, so gates, events and pidfiles all live
# under <develop-root>/.claude/orchestrator/.
#
# Provides:
#   wf_develop_root                  → absolute path of the first worktree
#   wf_orch_dir                      → <develop-root>/.claude/orchestrator (created)
#   wf_cfg <dotted.path> [default]   → value from claude-workflow.yml
#   wf_emit <KEY> <value>            → eval-safe KEY='value' line
#   wf_plan_fingerprint <PLN-NNN>    → hash of that plan's plan.md (may be empty)
#   wf_session_pid                   → PID of the long-lived session, not the shell
#   wf_claim_write <dir> [pid]       → write <dir>/.wf-claim
#   wf_claim_live <dir>              → 0 if a live claim holds it; sets WF_CLAIM_AGE
#   wf_event <type> <artifact> <msg> → append to events.log
#   wf_now                           → ISO-8601 UTC timestamp

# ── Paths ─────────────────────────────────────────────────────────────────

wf_develop_root() {
  # The first worktree git reports is always the main one (where develop lives).
  local root
  root=$(git worktree list --porcelain 2>/dev/null | head -1 | sed 's/^worktree //')
  if [ -n "$root" ]; then printf '%s' "$root"; return 0; fi
  # Not a worktree setup — fall back to the repo toplevel, then CWD.
  root=$(git rev-parse --show-toplevel 2>/dev/null) && [ -n "$root" ] && { printf '%s' "$root"; return 0; }
  printf '%s' "$PWD"
}

wf_orch_dir() {
  local d="$(wf_develop_root)/.claude/orchestrator"
  mkdir -p "$d/gates" "$d/logs"
  printf '%s' "$d"
}

wf_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ── Config ────────────────────────────────────────────────────────────────

# wf_cfg <dotted.path> [default]
# Reads a scalar from claude-workflow.yml. Deliberately does NOT require yq —
# the orchestrator must run on a bare client checkout. Handles the nested
# 2-space-indented scalar shape this config uses; not a general YAML parser.
wf_cfg() {
  local path="$1" default="${2:-}" cfg val
  cfg="$(wf_develop_root)/claude-workflow.yml"
  if [ ! -f "$cfg" ]; then printf '%s' "$default"; return 0; fi

  val=$(awk -v path="$path" '
    BEGIN { n = split(path, want, "."); level = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2
      if (indent > level) next          # inside a subtree we did not match
      if (indent < level) level = indent # popped back out
      key = probe; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)
      if (key != want[level + 1]) next
      if (level == n - 1) {
        rest = probe; sub(/^[^:]*:[ \t]*/, "", rest)
        sub(/[ \t]+#.*$/, "", rest)                 # trailing comment
        gsub(/^[ \t]+|[ \t]+$/, "", rest)
        gsub(/^"|"$/, "", rest); gsub(/^'"'"'|'"'"'$/, "", rest)
        print rest; exit
      }
      level++
    }
  ' "$cfg")

  if [ -z "$val" ]; then printf '%s' "$default"; else printf '%s' "$val"; fi
}

# wf_cfg_list <dotted.path>
# Reads a YAML sequence of scalars, one item per output line:
#
#   manualTestGate:
#     renderingSurfaces:
#       - "src/**/wwwroot/**"      →  src/**/wwwroot/**
#
# Same deliberate limits as wf_cfg: no yq, 2-space indentation, scalars only.
# Prints nothing when the key is absent or the list is empty — callers decide
# what an empty list means.
wf_cfg_list() {
  local path="$1" cfg
  cfg="$(wf_develop_root)/claude-workflow.yml"
  [ -f "$cfg" ] || return 0

  awk -v path="$path" '
    BEGIN { n = split(path, want, "."); level = 0; collecting = 0 }
    {
      line = $0; sub(/\r$/, "", line)
      probe = line; sub(/^[ ]*/, "", probe)
      if (probe ~ /^#/ || probe == "") next
      match(line, /^[ ]*/); indent = RLENGTH / 2

      if (collecting) {
        if (probe ~ /^- /) {
          item = probe; sub(/^-[ \t]*/, "", item)
          sub(/[ \t]+#.*$/, "", item)
          gsub(/^[ \t]+|[ \t]+$/, "", item)
          gsub(/^"|"$/, "", item); gsub(/^'"'"'|'"'"'$/, "", item)
          if (item != "") print item
          next
        }
        exit                      # first non-item line ends the sequence
      }

      if (indent > level) next
      if (indent < level) level = indent
      key = probe; sub(/:.*/, "", key); gsub(/[ \t]/, "", key)
      if (key != want[level + 1]) next
      if (level == n - 1) { collecting = 1; next }
      level++
    }
  ' "$cfg"
}

# ── Output ────────────────────────────────────────────────────────────────

# Single-quoted so `eval` survives spaces, semicolons, backticks — the same
# contract wf-plan-info.sh uses (and the reason BUG-094 existed).
wf_emit() {
  printf "%s='%s'\n" "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g")"
}

# ── Plan identity ─────────────────────────────────────────────────────────

# wf_plan_fingerprint <PLN-NNN> → hash of that plan's plan.md, or empty.
#
# Used to scope a gate answer to the plan REVISION it was given for: an
# approval is given to a document, not to an ID forever. Lives here because the
# writer (wf-gate-close.sh) and the reader (wf-gate-status.sh) must agree
# exactly — two copies of this would mean a gate that either re-opens forever
# or never re-opens, with nothing to indicate which.
#
# Empty for a BUG/BRF id, or a plan with no folder yet. Callers treat an empty
# fingerprint as "cannot tell", not as "changed".
wf_plan_fingerprint() {
  local id="$1" root slug plan_md
  root="$(wf_develop_root)"
  slug=$(grep "^| $id |" "$root/plans/REGISTRY.md" 2>/dev/null \
         | head -1 | awk -F'|' '{print $3}' | xargs || true)
  [ -n "$slug" ] || return 0
  plan_md="$root/plans/${id}-${slug}/plan.md"
  [ -f "$plan_md" ] || return 0
  shasum "$plan_md" 2>/dev/null | awk '{print $1}' || true
}

# wf_plan_body_fingerprint <PLN-NNN> → hash of that plan MINUS its ## Review
# section, or empty.
#
# What a review is a verdict ON. Dates cannot answer that: a plan reviewed and
# amended on the same day — the ordinary case, since a review, its findings and
# the amendment that answers them all happen in one session — leaves
# wf-review-status.sh unable to order the two, and it says so with
# REVIEW_STALE=unknown. wf-spec's replanning gate then reads "REVIEW_STALE must
# be false", which that plan can never satisfy (client-a WFI-069).
#
# A hash can answer it. The Review section is excluded because recording the
# stamp inside it would change the very thing being hashed.
wf_plan_body_fingerprint() {
  local id="$1" root slug plan_md
  root="$(wf_develop_root)"
  slug=$(grep "^| $id |" "$root/plans/REGISTRY.md" 2>/dev/null \
         | head -1 | awk -F'|' '{print $3}' | xargs || true)
  [ -n "$slug" ] || return 0
  plan_md="$root/plans/${id}-${slug}/plan.md"
  [ -f "$plan_md" ] || return 0
  awk '
    /^## / { inside = ($0 ~ /^## Review([ \t]|$)/) ? 1 : 0 }
    !inside { print }
  ' "$plan_md" | shasum 2>/dev/null | awk '{print $1}' || true
}

# ── Claims ────────────────────────────────────────────────────────────────
#
# A claim says "a live session is working this artifact". It is only worth
# anything if the PID it records outlives the shell that wrote it.
#
# wf_session_pid walks up from the calling shell to the first ancestor that is
# not a shell — the agent session, the daemon, the terminal. The walk used to
# compare `ps -o comm=` against `bash|sh|zsh|dash`, which is exactly right on
# Linux and never matches on macOS, where comm is the full path (`/bin/zsh`).
# So the walk stopped on its first step and recorded the transient shell that
# ran the script — dead by the next tool call, which made EVERY attended claim
# read as stale to the liveness check below. client-a's WFI-062: an attended
# /wf-test session claimed a plan, the daemon dispatched an unattended tester
# onto the same worktree 36 seconds later, and only luck kept it from removing
# the worktree out from under a human mid-test.
wf_session_pid() {
  local pid name parent
  pid=${1:-$PPID}
  for _ in 1 2 3 4 5; do
    name=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    [ -n "$name" ] || break
    name=${name##*/}      # /bin/zsh → zsh
    name=${name#-}        # -zsh (login shell) → zsh
    case "$name" in
      bash|sh|zsh|dash|ksh|fish)
        parent=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -n "$parent" ] && [ "$parent" -gt 1 ] 2>/dev/null || break
        pid="$parent"
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$pid"
}

# wf_claim_write <plan-dir> [pid] — timestamp on line 1, owning PID on line 2.
wf_claim_write() {
  local dir="$1" pid="${2:-}"
  [ -d "$dir" ] || return 1
  [ -n "$pid" ] || pid=$(wf_session_pid)
  printf '%s\n%s\n' "$(date +%s)" "$pid" > "$dir/.wf-claim"
}

# wf_claim_live <plan-dir> — 0 when a live session holds the claim.
#
# Sets WF_CLAIM_AGE (seconds) for callers that report "claimed Nm ago". A claim
# whose PID is gone, or one older than the TTL, is reaped here: a worker killed
# mid-run must not park an artifact forever (WFI-067).
WF_CLAIM_TTL=${WF_CLAIM_TTL:-7200}
wf_claim_live() {
  local dir="$1" f="$1/.wf-claim" ts pid
  WF_CLAIM_AGE=0
  [ -f "$f" ] || return 1
  ts=$(sed -n '1p' "$f" 2>/dev/null | tr -cd '0-9')
  pid=$(sed -n '2p' "$f" 2>/dev/null | tr -cd '0-9')
  [ -n "$ts" ] || ts=0
  WF_CLAIM_AGE=$(( $(date +%s) - ts ))
  if [ "$WF_CLAIM_AGE" -lt "$WF_CLAIM_TTL" ]; then
    # No PID is the pre-v5.1 format: the TTL alone decides.
    [ -z "$pid" ] && return 0
    kill -0 "$pid" 2>/dev/null && return 0
  fi
  rm -f "$f"
  return 1
}

# ── Events ────────────────────────────────────────────────────────────────

# wf_event <type> <artifact> <message>
# One tab-separated line per event. Appended with a single write so concurrent
# workers interleave cleanly (well under PIPE_BUF).
wf_event() {
  local type="$1" artifact="$2" msg="${3:-}"
  local log="$(wf_orch_dir)/events.log"
  printf '%s\t%s\t%s\t%s\n' "$(wf_now)" "$type" "$artifact" "$msg" >> "$log"
}
