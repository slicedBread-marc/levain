#!/usr/bin/env bash
# wf-board.sh [--watch [seconds]] [--plain] [--stats] [--fields]
#
# One pane showing everything in flight: running workers, queued gates, the
# pipeline by state, and recent events. This is the replacement for holding
# four terminals' worth of state in your head.
#
# Read-only — reads REGISTRY.md, pidfiles, gate files and events.log, and runs
# wf-registry-audit.sh. Changes nothing, costs no tokens.
#
#   --watch [n]   refresh every n seconds (default 10). Repaints only the
#                 lines that changed, not the whole screen — no flicker.
#   --plain       no colour (for piping or logging)
#   --stats       header + pipeline counts only — fixed line count, so
#                 --watch never grows past one screen and scrolls the
#                 summary out of view. No worker list, gate list, or
#                 events — those sections vary in length with how much is
#                 in flight, which is exactly what breaks a fixed-height
#                 refresh loop.
#   --fields      one tab-separated key=value line, no colour, for another
#                 script to parse (see coordinator' wf-board-all, which builds a
#                 cross-project grid from this). Not for humans. Includes
#                 attn=<comma-separated gated plan IDs, most-important
#                 first, `!` suffix on a stuck one> and
#                 deploy_pending=<plans on release but not main, or `-`
#                 if this project has no release/main split>.
#
# Exit 0 always.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

watch_mode=false
watch_secs=10
plain=false
stats_only=false
fields_mode=false

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) watch_mode=true
             if [ "${2:-}" ] && [ "${2#-}" = "${2}" ]; then watch_secs="$2"; shift; fi
             shift ;;
    --plain)  plain=true; shift ;;
    --stats)  stats_only=true; shift ;;
    --fields) fields_mode=true; shift ;;
    *) echo "Usage: $0 [--watch [seconds]] [--plain] [--stats] [--fields]" >&2; exit 1 ;;
  esac
done

$fields_mode && plain=true
if $plain || [ ! -t 1 ]; then
  B=""; DIM=""; R=""; GRN=""; YEL=""; CYN=""; RED=""
else
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RED=$'\033[31m'
fi

ROOT="$(wf_develop_root)"
ORCH="$(wf_orch_dir)"
REGISTRY="$ROOT/plans/REGISTRY.md"

# macOS and GNU stat disagree; try both.
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

human_age() {
  local secs="$1"
  if   [ "$secs" -lt 60 ]    ; then printf '%ds' "$secs"
  elif [ "$secs" -lt 3600 ]  ; then printf '%dm' "$((secs / 60))"
  elif [ "$secs" -lt 86400 ] ; then printf '%dh%dm' "$((secs / 3600))" "$(((secs % 3600) / 60))"
  else printf '%dd' "$((secs / 86400))"
  fi
}

render() {
  local now; now=$(date +%s)

  # ── Gather everything, unconditionally ─────────────────────────────
  # Every output mode (full / --stats / --fields) is a different rendering
  # of the same underlying numbers, so those numbers are computed once,
  # here, and the three branches below only format them.

  local daemon_raw="off" daemon_state="${DIM}off${R}"
  if [ -f "$ORCH/daemon.pid" ]; then
    local dpid; dpid=$(cat "$ORCH/daemon.pid" 2>/dev/null || echo "")
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
      daemon_raw="running"
      daemon_state="${GRN}running${R} ${DIM}(pid $dpid)${R}"
    else
      daemon_raw="stale"
      daemon_state="${YEL}stale pidfile${R}"
    fi
  fi
  local enabled; enabled=$(wf_cfg orchestrator.enabled false)
  local budget_used; budget_used=$(cat "$ORCH/spawns-$(date +%Y%m%d%H)" 2>/dev/null || echo 0)
  local budget_max;  budget_max=$(wf_cfg orchestrator.max_spawns_per_hour 20)

  local running_n=0 pf pid base role artifact age
  local -a running_lines=()
  for pf in "$ORCH/logs"/*.pid; do
    [ -f "$pf" ] || continue
    pid=$(cat "$pf" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    base=$(basename "$pf" .pid)
    role="${base##*-}"
    artifact="${base%-*}"
    # Pidfiles are keyed on the artifact number (wf-spawn.sh), which is the one
    # identity a bug keeps when it becomes a plan. Name it for the reader.
    if printf '%s' "$artifact" | grep -qE '^[0-9]+$'; then
      artifact=$(grep -E "^\| (PLN|BUG|BRF)-$artifact \|" "$ROOT/plans/REGISTRY.md" 2>/dev/null \
        | head -1 | awk -F'|' '{ gsub(/ /, "", $2); gsub(/^[ \t]+|[ \t]+$/, "", $3); print $2 "-" $3 }' \
        || true)
      [ -n "$artifact" ] || artifact="${base%-*}"
    fi
    age=$(( now - $(file_mtime "$pf") ))
    running_lines+=("$(printf '  %s%-11s%s %-34s %s  %spid %s%s' \
      "$CYN" "$role" "$R" "$artifact" "$(human_age "$age")" "$DIM" "$pid" "$R")")
    running_n=$((running_n + 1))
  done

  local gates; gates=$("$SELF_DIR/wf-list-gates.sh" 2>/dev/null || true)
  local gates_n=0 gates_blocked=0 gates_stuck=0
  if [ -n "$gates" ]; then
    gates_n=$(printf '%s\n' "$gates" | grep -c .)
    gates_blocked=$(printf '%s\n' "$gates" | awk -F'\t' '{n=$6+0; if (n>0) t+=n} END{print t+0}')
    # A `stuck`/`spec-stuck` gate means the plan hit its attempt budget with
    # no forward progress — a stall, not an ordinary decision waiting on a
    # human. Worth its own count: it is the one gate state that never
    # resolves by waiting.
    gates_stuck=$(printf '%s\n' "$gates" | awk -F'\t' '$2 ~ /stuck/ {n++} END{print n+0}')
  fi

  # Which plans are gated, in the same cost-then-age order wf-list-gates.sh
  # already sorted them in — a `!` suffix flags a stuck one so a consumer can
  # colour it without re-deriving gate names. --fields only; the full-mode
  # GATES list below already names each plan.
  local attn=""
  if [ -n "$gates" ]; then
    attn=$(printf '%s\n' "$gates" | awk -F'\t' '{
      id = $1; gsub(/^(PLN|BUG|BRF)-/, "", id)
      tok = id
      if ($2 ~ /stuck/) tok = tok "!"
      printf "%s%s", (NR > 1 ? "," : ""), tok
    }')
  fi

  # ── Pipeline histogram ───────────────────────────────────────────────
  # One pass, not one pass per state (see counts= below). The two terminal
  # states are tracked too — an abandoned plan appearing in no column at all
  # is how a project ends up with plan folders nobody can account for
  # (WFI-009).
  local st_draft=0 st_ready=0 st_active=0 st_verify=0 st_testing=0 st_complete=0 st_abandoned=0
  if [ -f "$REGISTRY" ]; then
    local st n counts
    counts=" $(awk -F'|' '
      function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
      /^\| PLN-/ { c[trim($4)]++ }
      END { for (s in c) printf "%s=%s ", s, c[s] }' "$REGISTRY")"
    for st in draft ready active verify testing complete abandoned; do
      n="${counts##* $st=}"
      if [ "$n" = "$counts" ]; then n=0; else n="${n%% *}"; fi
      case "$st" in
        draft)     st_draft="$n" ;;
        ready)     st_ready="$n" ;;
        active)    st_active="$n" ;;
        verify)    st_verify="$n" ;;
        testing)   st_testing="$n" ;;
        complete)  st_complete="$n" ;;
        abandoned) st_abandoned="$n" ;;
      esac
    done
  fi

  # ── Deploy pending ────────────────────────────────────────────────────
  # Plans whose commits reached `release` (passed /wf-release's E2E) but
  # haven't reached `main` yet — staged for /wf-deploy. Distinct plan IDs,
  # not commit count: one plan can land several commits on release. `-1`
  # (rendered `-`) means this project doesn't have both refs, not "zero
  # pending" — client-i and friends have no release/main split.
  local deploy_pending=-1
  if git -C "$ROOT" rev-parse --verify release >/dev/null 2>&1 \
     && git -C "$ROOT" rev-parse --verify main >/dev/null 2>&1; then
    deploy_pending=$(git -C "$ROOT" log --oneline release --not main 2>/dev/null \
      | grep -oE 'PLN-[0-9]+' | sort -u | wc -l | tr -d ' ')
  fi

  # ── Registry integrity ──────────────────────────────────────────────
  # The audit's own exit code is the dirty signal (0 = clean, 1 = problems),
  # not "did it print anything" — it also emits informational note() lines
  # (e.g. a COUNTER note) that don't count as problems and precede a trailing
  # "registry audit: clean". Matching on output text used to call that dirty
  # and print a REGISTRY section headed "the registry and plans/ disagree"
  # directly above a line saying the opposite.
  local audit registry_dirty=false registry_n=0
  if ! audit=$("$SELF_DIR/wf-registry-audit.sh" 2>/dev/null); then
    registry_dirty=true
    # The audit's own last line carries its authoritative count ("registry
    # audit: N problem(s)") — counting non-blank lines instead would count
    # description rows too, which over-reports.
    registry_n=$(printf '%s\n' "$audit" | grep -oE '[0-9]+ problem' | tail -1 | grep -oE '^[0-9]+')
    [ -n "$registry_n" ] || registry_n=-1
  fi

  if $fields_mode; then
    # One line, tab-separated key=value, no colour — for another script to
    # parse (coordinator' wf-board-all builds a cross-project grid from this rather
    # than scraping the human-formatted output above).
    local registry_field="clean"
    $registry_dirty && registry_field="$registry_n"
    local deploy_field="$deploy_pending"
    [ "$deploy_field" -lt 0 ] 2>/dev/null && deploy_field="-"
    printf 'daemon=%s\tenabled=%s\tspawns=%s/%s\trunning=%s\tgates=%s\tgates_stuck=%s\tgates_blocked=%s\tdraft=%s\tready=%s\tactive=%s\tverify=%s\ttesting=%s\tcomplete=%s\tabandoned=%s\tregistry=%s\tattn=%s\tdeploy_pending=%s\n' \
      "$daemon_raw" "$enabled" "$budget_used" "$budget_max" \
      "$running_n" "$gates_n" "$gates_stuck" "$gates_blocked" \
      "$st_draft" "$st_ready" "$st_active" "$st_verify" "$st_testing" "$st_complete" "$st_abandoned" \
      "$registry_field" "$attn" "$deploy_field"
    return
  fi

  # ── Header ──────────────────────────────────────────────────────────
  printf '%s\n' "${B}WORKFLOW BOARD${R}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${R}"
  printf '  daemon: %s   enabled: %s   spawns this hour: %s/%s\n\n' \
    "$daemon_state" "$enabled" "$budget_used" "$budget_max"

  if $stats_only; then
    # ── Rollup ────────────────────────────────────────────────────────
    # One fixed-width line in place of the RUNNING / GATES / RECENT
    # sections below — those grow with how much is in flight, which is
    # exactly what pushes this summary off-screen under --watch.
    local gate_word="gates"
    [ "$gates_n" -eq 1 ] && gate_word="gate"
    local stuck_note=""
    [ "$gates_stuck" -gt 0 ] && stuck_note=" ${RED}(${gates_stuck} stuck)${R}"
    if [ "$gates_blocked" -gt 0 ]; then
      printf '  running: %s   %s%s %s waiting (blocking %s)%s%s\n\n' \
        "$running_n" "$YEL" "$gates_n" "$gate_word" "$gates_blocked" "$R" "$stuck_note"
    else
      printf '  running: %s   %s waiting: %s%s\n\n' "$running_n" "$gate_word" "$gates_n" "$stuck_note"
    fi
  else
    # ── Running workers ───────────────────────────────────────────────
    printf '%s\n' "${B}RUNNING${R}"
    if [ "$running_n" -gt 0 ]; then
      printf '%s\n' "${running_lines[@]}"
    else
      printf '  %snothing running%s\n' "$DIM" "$R"
    fi
    printf '\n'

    # ── Gates ─────────────────────────────────────────────────────────
    printf '%s\n' "${B}GATES${R} ${DIM}— waiting on you (/wf-attend)${R}"
    if [ -n "$gates" ]; then
      printf '%s\n' "$gates" | while IFS=$'\t' read -r gid gname gopened gq _gctx gblk; do
        [ -n "$gid" ] || continue
        # Stuck outranks blocking: a stall needs a human look regardless of
        # whether anything downstream depends on it.
        local gcolor="$YEL"
        case "$gname" in *stuck*) gcolor="$RED" ;; esac
        # Costliest first — the count is what the gate is holding up, and it is
        # the only thing on this line that says whether answering it is urgent.
        if [ "${gblk:-0}" -gt 0 ] 2>/dev/null; then
          printf '  %s%-11s%s %-11s %s(blocking %s)%s %s\n' \
            "$gcolor" "$gname" "$R" "$gid" "$gcolor" "$gblk" "$R" "$gq"
        else
          printf '  %s%-11s%s %-11s %s\n' "$gcolor" "$gname" "$R" "$gid" "$gq"
        fi
      done
    else
      printf '  %snone — nothing is waiting on you%s\n' "$DIM" "$R"
    fi
    printf '\n'
  fi

  # ── Pipeline ────────────────────────────────────────────────────────
  printf '%s\n' "${B}PIPELINE${R}"
  if [ -f "$REGISTRY" ]; then
    printf '  %-9s %s\n' "draft" "$st_draft"
    printf '  %-9s %s\n' "ready" "$st_ready"
    printf '  %-9s %s\n' "active" "$st_active"
    printf '  %-9s %s\n' "verify" "$st_verify"
    printf '  %-9s %s\n' "testing" "$st_testing"
    printf '  %s%-9s %s%s\n' "$DIM" "complete" "$st_complete" "$R"
    printf '  %s%-9s %s%s\n' "$DIM" "abandoned" "$st_abandoned" "$R"
    if [ "$deploy_pending" -ge 0 ] 2>/dev/null; then
      if [ "$deploy_pending" -gt 0 ]; then
        printf '  %s%-9s %s%s\n' "$YEL" "deploy" "$deploy_pending" "$R"
      else
        printf '  %s%-9s %s%s\n' "$DIM" "deploy" "$deploy_pending" "$R"
      fi
    fi
  else
    printf '  %sno REGISTRY.md%s\n' "$DIM" "$R"
  fi
  printf '\n'

  if $stats_only; then
    if $registry_dirty; then
      local shown_n="$registry_n"
      [ "$shown_n" -ge 0 ] 2>/dev/null || shown_n="?"
      printf '  %sregistry: %s discrepancy(ies) — run without --stats%s\n' "$YEL" "$shown_n" "$R"
    else
      printf '  %sregistry: clean%s\n' "$DIM" "$R"
    fi
    return
  fi

  # ── Registry integrity ──────────────────────────────────────────────
  # Everything above reads the registry and therefore cannot show a plan the
  # registry has lost track of. Only when there is something to say — a
  # clean registry adds no line.
  if $registry_dirty; then
    printf '%s\n' "${B}REGISTRY${R} ${DIM}— the registry and plans/ disagree${R}"
    printf '%s\n' "$audit" | sed 's/^/  /'
    printf '\n'
  fi

  # ── Recent events ───────────────────────────────────────────────────
  printf '%s\n' "${B}RECENT${R}"
  if [ -s "$ORCH/events.log" ]; then
    tail -8 "$ORCH/events.log" | while IFS=$'\t' read -r ets etype eart emsg; do
      printf '  %s%s%s  %-11s %-11s %s\n' "$DIM" "${ets#*T}" "$R" "$etype" "$eart" "$emsg"
    done
  else
    printf '  %sno events yet%s\n' "$DIM" "$R"
  fi
}

# draw_frame — repaint only the lines that changed since the last frame.
#
# A full `\033[2J` clear-then-redraw blanks the whole terminal for one tick
# before the new content lands, which is what reads as flicker — worse the
# more of the screen is unchanged between refreshes (usually most of it).
# Instead: render into a string, diff it line-by-line against the previous
# frame, and only move the cursor and repaint rows whose text actually
# differs. A frame shorter than the last one still needs its leftover tail
# blanked, or the old bottom rows would linger under the new, shorter output.
prev_lines=()
draw_frame() {
  local content; content=$(render)
  local -a new_lines=()
  local line
  while IFS= read -r line; do new_lines+=("$line"); done <<< "$content"
  new_lines+=("")
  new_lines+=("$(printf '%srefreshing every %ss — Ctrl-C to stop%s' "$DIM" "$watch_secs" "$R")")

  local i row new_n="${#new_lines[@]}" prev_n="${#prev_lines[@]}"
  for ((i = 0; i < new_n; i++)); do
    row=$((i + 1))
    if [ "$i" -ge "$prev_n" ] || [ "${new_lines[$i]}" != "${prev_lines[$i]}" ]; then
      printf '\033[%d;1H\033[K%s' "$row" "${new_lines[$i]}"
    fi
  done
  if [ "$prev_n" -gt "$new_n" ]; then
    for ((i = new_n; i < prev_n; i++)); do
      printf '\033[%d;1H\033[K' "$((i + 1))"
    done
  fi
  prev_lines=("${new_lines[@]}")
}

if $watch_mode; then
  trap 'printf "\033[?25h\n"; exit 0' INT TERM
  printf '\033[2J\033[?25l'
  while true; do
    draw_frame
    sleep "$watch_secs"
  done
else
  render
fi
exit 0
