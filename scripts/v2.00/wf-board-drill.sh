#!/usr/bin/env bash
# wf-board-drill.sh <node> [args...]
#
# What is BEHIND a number on the board. `wf-board.sh --fields` says a project
# has 3 running workers and 2 gates; this says which three and which two, and
# then what each one of those is — down to the log a live worker is writing
# right now.
#
# Read-only. Changes nothing, starts nothing, costs no tokens.
#
# THE CONTRACT
#
# Every invocation prints either a LIST or a BODY, and a list line says how to
# go one level deeper. A list line is tab-separated:
#
#   <display>\t<kind>\t<target>
#
#   kind=list  target is the argv of the next wf-board-drill.sh call
#   kind=text  target is the argv of a call whose stdout is a body to show
#   kind=log   target is a path to a log file (view, and follow while live)
#   kind=file  target is a path to a file (view)
#   kind=none  nothing deeper — the line is the whole answer
#
# The target of `list`/`text` is an ARGV, not a key the caller has to assemble
# — so the caller keeps a plain stack of argv strings and never has to know
# how this script routes. Adding a node type here needs no change there.
#
# NODES
#
#   row <metric>     the items behind one grid row: daemon, running, gates,
#                    attn, ideas, draft, ready, active, verify, testing,
#                    complete, rolled-back, abandoned, release, deploy,
#                    registry
#   artifact <ID>    one plan/bug/brief: its files, its logs, its gate
#   logs <ID>        every worker log for that artifact, newest first
#   worker <pidbase> <ID>   one live worker: its log, its artifact
#   gate <ID>        an open gate: the gate file, the artifact it sits on
#   summary <ID>     BODY — state, priority, goal, steps, claim, attempts
#   events <ID>      BODY — that artifact's lines from events.log
#   audit            BODY — wf-registry-audit.sh
#
# Exit 0 when there is something to print, 1 when the node is empty (no
# running workers, no open gates) so a caller can say so rather than showing
# a blank pane. Exit 2 for an unknown node.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

ROOT="$(wf_develop_root)"
ORCH="$(wf_orch_dir)"
REGISTRY="$ROOT/plans/REGISTRY.md"
US=$'\x1f'

node="${1:-}"
[ -n "$node" ] || { echo "Usage: $0 <node> [args...]" >&2; exit 2; }
shift

emitted=0
# emit <display> <kind> <target>
#
# One line per item is the whole contract, so a display that carries a tab or
# a newline would hand the caller a field boundary that isn't one — and the
# display text is free prose written by a human (a brief's INDEX.md blurb runs
# to paragraphs). Flattened and capped here, once, rather than at each of the
# dozen call sites: a caller that wants the full text opens the file the line
# points at.
emit() {
  local disp
  # Tabs and newlines only — a run of spaces is column padding this script
  # put there on purpose, and collapsing it would unalign every list.
  disp=$(printf '%s' "$1" | tr '\n\t' '  ')
  [ "${#disp}" -gt 220 ] && disp="${disp:0:219}…"
  printf '%s\t%s\t%s\n' "$disp" "$2" "$3"
  emitted=$((emitted + 1))
}

# plan_dir <ID> — plans/PLN-NNN-<slug>/, found by number so a caller holding
# the bug's name (BUG-043) still reaches the plan it became (PLN-043). Empty
# when there is no plan folder yet, which is the normal state of a brief.
plan_dir() {
  local id="$1" num d
  num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
  [ -n "$num" ] || return 0
  for d in "$ROOT/plans/PLN-$num"-*; do
    [ -d "$d" ] || continue
    printf '%s' "$d"; return 0
  done
  return 0
}

brief_file() {
  local id="$1" num f
  num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
  [ -n "$num" ] || return 0
  for f in "$ROOT/plans/briefs/BRF-$num"-*.md; do
    [ -f "$f" ] || continue
    printf '%s' "$f"; return 0
  done
  return 0
}

# artifact_logs <ID> — worker logs for that artifact, newest first. Two
# shapes, both written by wf-spawn.sh: <ID>-<role>-<ts>.log for a normal
# worker, <ID>-<ts>.log for the release/deploy stage roles.
artifact_logs() {
  local id="$1"
  ls -t "$ORCH/logs/${id}-"*.log 2>/dev/null || true
}

# id_of_number <num> — the registry's own name for an artifact number, since
# a pidfile is keyed on the number alone (wf-spawn.sh) and that number is the
# one identity a bug keeps when it becomes a plan.
# Matched on the NUMBER's value, not its text: a pidfile carries whatever
# digits the spawning id had (`001` from PLN-001, `73` from BUG-73), and a
# string compare against the registry misses across that padding and hands
# back a plan id that exists nowhere.
id_of_number() {
  local num="$1" id
  id=$(awk -F'|' -v n="$num" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { id = trim($2) }
    id ~ /^(PLN|BUG|BRF)-[0-9]+$/ {
      split(id, a, "-")
      if (a[2] + 0 == n + 0) { print id; exit }
    }' "$REGISTRY" 2>/dev/null || true)
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  printf 'PLN-%s' "$num"
}

# ── row <metric> ────────────────────────────────────────────────────────
row_daemon() {
  local dpid state="off"
  if [ -f "$ORCH/daemon.pid" ]; then
    dpid=$(cat "$ORCH/daemon.pid" 2>/dev/null || echo "")
    if [ -n "$dpid" ] && kill -0 "$dpid" 2>/dev/null; then
      state="running (pid $dpid)"
    else
      state="stale pidfile (pid ${dpid:-?} is gone)"
    fi
  fi
  emit "daemon: $state" none ""
  emit "enabled: $(wf_cfg orchestrator.enabled false)   spawns this hour: $(cat "$ORCH/spawns-$(date +%Y%m%d%H)" 2>/dev/null || echo 0)/$(wf_cfg orchestrator.max_spawns_per_hour 20)" none ""
  [ -f "$ORCH/daemon.log" ] && emit "daemon.log — what the sweep decided" log "$ORCH/daemon.log"
  [ -f "$ORCH/daemon.out" ] && emit "daemon.out — the daemon's own stdout" log "$ORCH/daemon.out"
  [ -f "$ORCH/events.log" ] && emit "events.log — every spawn, gate and transition" log "$ORCH/events.log"
}

row_running() {
  local pf pid base role num artifact age
  for pf in "$ORCH/logs"/*.pid; do
    [ -f "$pf" ] || continue
    pid=$(cat "$pf" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    base=$(basename "$pf" .pid)
    role="${base##*-}"
    num="${base%-*}"
    if printf '%s' "$num" | grep -qE '^[0-9]+$'; then
      artifact=$(id_of_number "$num")
    else
      artifact="$num"
    fi
    age=$(( $(date +%s) - $(wf_file_mtime "$pf") ))
    emit "$(printf '%-11s %-22s %6s  pid %s' "$role" "$artifact" "$(wf_human_age "$age")" "$pid")" \
      list "worker $base $artifact"
  done
}

row_gates() {
  local gid gname gage gq gctx gblk gstate gfit line
  while IFS=$'\t' read -r gid gname gage gq gctx gblk gstate gfit; do
    [ -n "$gid" ] || continue
    line=$(printf '%-14s %-11s %s' "$gname" "$gid" "$gq")
    [ "${gblk:-0}" -gt 0 ] 2>/dev/null && line="$line  (blocking $gblk)"
    [ "${gfit:-}" = "mismatch" ] && line="$line  (state is now $gstate — gate no longer fits)"
    emit "$line" list "gate $gid"
  done < <("$SELF_DIR/wf-list-gates.sh" 2>/dev/null || true)
}

row_ideas() {
  local id detail name desc f
  while IFS=$'\t' read -r id detail name desc; do
    [ -n "$id" ] || continue
    f=$(brief_file "$id")
    if [ -n "$f" ]; then
      emit "$(printf '%-11s %-11s %s' "$id" "$detail" "${desc:-$name}")" file "$f"
    else
      emit "$(printf '%-11s %-11s %s' "$id" "$detail" "${desc:-$name}")" none ""
    fi
  done < <("$SELF_DIR/wf-list-brainstorms.sh" 2>/dev/null || true)
}

row_state() {
  local want="$1" id slug state prio branch updated wf tags deps
  while IFS="$US" read -r id slug state prio branch updated wf tags deps; do
    [ "$state" = "$want" ] || continue
    emit "$(printf '%-11s %-34s %-8s %s' "$id" "$slug" "${prio:--}" "${tags:-}")" list "artifact $id"
  done < <(wf_registry_rows "$REGISTRY")
}

# row_promotable <from-ref> <to-ref> — plans whose commits reached <from> but
# not <to>: `release` for work merged to develop and never carried through
# /wf-release, `deploy` for work sitting on release awaiting /wf-deploy. The
# registry cannot answer this — a plan reads `complete` the day before the
# release and the day after.
row_promotable() {
  local from="$1" to="$2" id
  git -C "$ROOT" rev-parse --verify "$from" >/dev/null 2>&1 || return 0
  git -C "$ROOT" rev-parse --verify "$to"   >/dev/null 2>&1 || return 0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    emit "$(printf '%-11s %s' "$id" "$(wf_registry_field "$id" slug "$REGISTRY")")" list "artifact $id"
  done < <(git -C "$ROOT" log --oneline "$from" --not "$to" 2>/dev/null \
            | grep -oE 'PLN-[0-9]+' | sort -u)
}

case "$node" in
  row)
    metric="${1:-}"
    case "$metric" in
      daemon)   row_daemon ;;
      running)  row_running ;;
      gates|attn) row_gates ;;
      ideas)    row_ideas ;;
      draft|ready|active|verify|testing|complete|rolled-back|abandoned)
                row_state "$metric" ;;
      release)  row_promotable develop release ;;
      deploy)   row_promotable release main ;;
      registry) emit "registry audit — the registry against plans/" text "audit" ;;
      *) echo "wf-board-drill: no such row '$metric'" >&2; exit 2 ;;
    esac
    ;;

  worker)
    base="${1:-}" id="${2:-}"
    role="${base##*-}"
    # The log a live worker is writing is the newest one matching its
    # artifact and role — a worker that has been retried has several.
    newest=$(ls -t "$ORCH/logs/${id}-${role}-"*.log 2>/dev/null | head -1 || true)
    [ -n "$newest" ] || newest=$(artifact_logs "$id" | head -1 || true)
    [ -n "$newest" ] && emit "live log — $(basename "$newest")" log "$newest"
    emit "$id — plan, progress, findings, every log" list "artifact $id"
    emit "$id — recent events" text "events $id"
    ;;

  gate)
    id="${1:-}"
    gf=$(wf_gate_file "$id" 2>/dev/null || true)
    [ -n "$gf" ] && [ -f "$gf" ] && emit "gate file — the question, in full" file "$gf"
    emit "$id — plan, progress, findings, every log" list "artifact $id"
    emit "$id — recent events" text "events $id"
    ;;

  artifact)
    id="${1:-}"
    emit "summary — state, goal, steps, claim, attempts" text "summary $id"
    d=$(plan_dir "$id")
    if [ -n "$d" ]; then
      [ -f "$d/plan.md" ]     && emit "plan.md — the spec" file "$d/plan.md"
      [ -f "$d/progress.md" ] && emit "progress.md — the live Steps checklist" file "$d/progress.md"
      [ -f "$d/findings.md" ] && emit "findings.md — what verify and test found" file "$d/findings.md"
    fi
    bf=$(brief_file "$id")
    [ -n "$bf" ] && emit "brief — the thinking this came from" file "$bf"
    gf=$(wf_gate_file "$id" 2>/dev/null || true)
    [ -n "$gf" ] && [ -f "$gf" ] && emit "gate — open, waiting on a human" file "$gf"
    if [ -n "$(artifact_logs "$id" | head -1)" ]; then
      emit "logs — every worker run for $id" list "logs $id"
    fi
    emit "events — $id's line in events.log" text "events $id"
    ;;

  logs)
    id="${1:-}"
    now=$(date +%s)
    while IFS= read -r f; do
      [ -f "$f" ] || continue
      emit "$(printf '%-44s %7sB  %s ago' "$(basename "$f")" "$(wf_file_size "$f")" \
        "$(wf_human_age $(( now - $(wf_file_mtime "$f") )))")" log "$f"
    done < <(artifact_logs "$id")
    ;;

  summary)
    id="${1:-}"
    d=$(plan_dir "$id")
    printf '%s\n' "$id"
    printf '  state      %s\n' "$(wf_state_of "$id" "$REGISTRY")"
    printf '  slug       %s\n' "$(wf_registry_field "$id" slug "$REGISTRY")"
    printf '  priority   %s\n' "$(wf_registry_field "$id" priority "$REGISTRY")"
    printf '  branch     %s\n' "$(wf_registry_field "$id" branch "$REGISTRY")"
    printf '  updated    %s\n' "$(wf_registry_field "$id" updated "$REGISTRY")"
    printf '  wf         %s\n' "$(wf_registry_field "$id" wf "$REGISTRY")"
    printf '  tags       %s\n' "$(wf_registry_field "$id" tags "$REGISTRY")"
    printf '  deps       %s\n' "$(wf_registry_field "$id" deps "$REGISTRY")"
    if [ -n "$d" ]; then
      printf '  folder     %s\n' "${d#$ROOT/}"
      printf '  steps      %s\n' "$(wf_step_counts "$d/progress.md")"
      printf '  escalated  %s finding(s)\n' "$(wf_escalated_count "$d/findings.md")"
      printf '\n'
      # The Steps checklist is the forward-progress signal (schema v6) — the
      # one thing in a plan folder that says how far a run actually got, so
      # it is worth having here rather than one file-open away.
      awk '/^## Steps/ { s = 1; print; next } /^## / { s = 0 } s' "$d/progress.md" 2>/dev/null \
        | head -40 | sed 's/^/  /'
    else
      printf '  folder     (no plan folder — still a bug or brief)\n'
    fi
    num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
    if [ -n "$num" ]; then
      printf '\n'
      for c in "$ORCH/claims/$num"*; do
        [ -e "$c" ] || continue
        printf '  claim      %s\n' "$(basename "$c")"
      done
      for a in "$ORCH/attempts/$num"*; do
        [ -f "$a" ] || continue
        printf '  attempts   %s: %s\n' "$(basename "$a")" "$(cat "$a" 2>/dev/null | tr '\n' ' ')"
      done
    fi
    ;;

  events)
    id="${1:-}"
    num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
    # Matched on the NUMBER, not the name: an artifact's events are written
    # under whichever name it had at the time (BUG-043 then PLN-043), and the
    # number is the identity that survives the rename. RELEASE and DEPLOY
    # were never counter-allocated, so for those the name IS the identity.
    pattern="(PLN|BUG|BRF)-0*$num([^0-9]|$)"
    [ -n "$num" ] || pattern="$id"
    if [ -s "$ORCH/events.log" ]; then
      grep -E "$pattern" "$ORCH/events.log" \
        | tail -40 \
        | while IFS=$'\t' read -r ets etype eart emsg; do
            printf '  %s  %-11s %-11s %s\n' "${ets#*T}" "$etype" "$eart" "$emsg"
          done
    else
      printf '  no events for %s\n' "$id"
    fi
    ;;

  audit)
    "$SELF_DIR/wf-registry-audit.sh" 2>&1 | sed 's/^/  /'
    ;;

  *)
    echo "wf-board-drill: no such node '$node'" >&2
    exit 2
    ;;
esac

# A body node has already said everything it has to say; only a list node can
# be empty in the way a caller needs to hear about.
case "$node" in
  row|worker|gate|artifact|logs) [ "$emitted" -gt 0 ] || exit 1 ;;
esac
exit 0
