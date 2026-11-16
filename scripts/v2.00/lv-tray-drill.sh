#!/usr/bin/env bash
# lv-tray-drill.sh <node> [args...]
#
# What is BEHIND a number on the board. `lv-tray.sh --fields` says a project
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
#   kind=list  target is the argv of the next lv-tray-drill.sh call
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
#                    attn, intake, ideas, draft, ready, active, verify, testing,
#                    complete, rolled-back, abandoned, release, deploy,
#                    registry
#   artifact <ID>    one plan/bug/brief: its files, its logs, its gate
#   logs <ID>        every worker log for that artifact, newest first
#   worker <pidbase> <ID>   one live worker: its log, its artifact
#   gate <ID>        an open gate: the gate file, the artifact it sits on
#   summary <ID>     BODY — state, priority, goal, steps, claim, attempts
#   history <ID>     BODY — the whole record of one number: its plan, bug and
#                    brief, goal, steps, log, findings, gates open and
#                    answered, claim, git history, events. What
#                    `/lv-tray <ID>` shows. Exit 1 when nothing carries it.
#   events <ID>      BODY — that artifact's lines from events.log
#   audit            BODY — lv-registry-audit.sh
#
# Exit 0 when there is something to print, 1 when the node is empty (no
# running workers, no open gates) so a caller can say so rather than showing
# a blank pane. Exit 2 for an unknown node.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

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
  local id="$1" num d p
  num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
  [ -n "$num" ] || return 0
  for p in $LV_PLN_ALL; do
    for d in "$ROOT/plans/$p-$num"-*; do
      [ -d "$d" ] || continue
      printf '%s' "$d"; return 0
    done
  done
  return 0
}

brief_file() {
  local id="$1" num f p
  num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
  [ -n "$num" ] || return 0
  for p in $LV_BRF_ALL; do
    for f in "$ROOT/plans/briefs/$p-$num"-*.md; do
      [ -f "$f" ] || continue
      printf '%s' "$f"; return 0
    done
  done
  return 0
}

# artifact_logs <ID> — worker logs for that artifact, newest first. Two
# shapes, both written by lv-spawn.sh: <ID>-<role>-<ts>.log for a normal
# worker, <ID>-<ts>.log for the release/deploy stage roles.
artifact_logs() {
  local id="$1"
  ls -t "$ORCH/logs/${id}-"*.log 2>/dev/null || true
}

# id_of_number <num> — the registry's own name for an artifact number, since
# a pidfile is keyed on the number alone (lv-spawn.sh) and that number is the
# one identity a bug keeps when it becomes a plan.
# Matched on the NUMBER's value, not its text: a pidfile carries whatever
# digits the spawning id had (`001` from PLN-001, `73` from BUG-73), and a
# string compare against the registry misses across that padding and hands
# back a plan id that exists nowhere.
id_of_number() {
  local num="$1" id
  id=$(awk -F'|' -v n="$num" -v work_re="^($LV_WORK_RE)-[0-9]+$" '
    function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
    { id = trim($2) }
    id ~ work_re {
      split(id, a, "-")
      if (a[2] + 0 == n + 0) { print id; exit }
    }' "$REGISTRY" 2>/dev/null || true)
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  # No registry row: a spec worker on a bug not yet specced. Its bug, if one
  # is open or triaged, before a plan id that exists nowhere (LVI-050).
  local d bid
  for d in "$ROOT"/bugs/open/*/ "$ROOT"/bugs/triaged/*/; do
    [ -f "$d/bug.md" ] || continue
    bid=$(basename "$d" | grep -oE "^($LV_BUG_RE)-[0-9]+" || true)
    [ -n "$bid" ] && [ $((10#${bid##*-})) -eq $((10#$num)) ] && { printf '%s' "$bid"; return 0; }
  done
  printf '%s-%s' "$LV_PLN" "$num"
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
  done < <("$SELF_DIR/lv-list-gates.sh" 2>/dev/null || true)
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
  done < <("$SELF_DIR/lv-list-brainstorms.sh" 2>/dev/null || true)
}

# row_intake — filed bugs not yet specced, in dispatch order: a live intake
# group's heading, then its open members lead first, indented; `*` on the one
# a spec worker or a session holds now. The same list and the same marks as
# the tray's INTAKE section, both from lv-list-intake.sh (the coordinator's
# LVI-050).
row_intake() {
  local id slug grp role held blk last="" ind mark note st lead
  while IFS=$'\t' read -r id slug grp role held blk; do
    [ -n "$id" ] || continue
    [ "$grp" = "-" ] && grp=""
    if [ -n "$grp" ] && [ "$grp" != "$last" ]; then
      st=$(wf_group_field "$grp" Status); lead=$(wf_group_field "$grp" Lead)
      case "$st" in
        Open) emit "group $grp — open, nothing offered until: lv-bug-group.sh seal $grp" file "$(wf_group_file "$grp")" ;;
        *)    emit "group $grp — ${st:-?}${lead:+, lead $lead}" file "$(wf_group_file "$grp")" ;;
      esac
    fi
    last="$grp"
    ind=""; [ -n "$grp" ] && ind="  "
    mark=" "; [ "$held" != "-" ] && mark="*"
    note=""
    case "$role" in
      lead)     note="lead" ;;
      carried)  note="carried" ;;
      amends:*) note="amends ${role#amends:}" ;;
      waiting)  note="waiting for the seal" ;;
    esac
    case "$held" in
      worker) note="${note:+$note · }spec worker" ;;
      claim)  note="${note:+$note · }claimed" ;;
    esac
    [ "$blk" = "blocked" ] && note="${note:+$note · }blocked"
    emit "$(printf '%s%s %-11s %-40s %s' "$ind" "$mark" "$id" "$slug" "$note")" list "artifact $id"
  done < <("$SELF_DIR/lv-list-intake.sh" 2>/dev/null || true)
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
# /lv-release, `deploy` for work sitting on release awaiting /lv-deploy. The
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
            | grep -oE "($LV_PLN_RE)-[0-9]+" | sort -u)
}

# history_body — the sections of `history <ID>`, in reading order. Reads the
# globals that node sets: id, num, plan_id, d, bug_md, brief_md.
history_body() {
  # The plan, through lv-plan-info.sh — the registry row's one parser.
  if [ -n "$plan_id" ] && info=$("$SELF_DIR/lv-plan-info.sh" "$plan_id" 2>/dev/null); then
    eval "$info"
    printf '%s — %s\n' "$PLAN_ID" "$PLAN_SLUG"
    printf '  state      %s\n' "$PLAN_STATE"
    printf '  priority   %s\n' "$PLAN_PRIORITY"
    printf '  branch     %s\n' "${PLAN_BRANCH:-n/a}"
    printf '  updated    %s\n' "$PLAN_UPDATED"
    printf '  wf         %s\n' "${PLAN_WF:-—}"
    printf '  tags       %s\n' "$PLAN_TAGS"
    if [ "$PLAN_BLOCKED" = true ]; then
      printf '  deps       %s  [blocked by %s]\n' "$PLAN_DEPS" "$PLAN_BLOCKING"
      [ -n "$PLAN_DEPS_DEAD" ] && printf '             %s abandoned — never arriving\n' "$PLAN_DEPS_DEAD"
    else
      printf '  deps       %s\n' "$PLAN_DEPS"
    fi
    [ -n "$d" ] && printf '  folder     %s\n' "${d#$ROOT/}"
    printf '\nGoal\n  %s\n' "${PLAN_GOAL:-(none written)}"
  elif [ -n "$d" ]; then
    printf '%s — no REGISTRY row (lv-registry-audit.sh reports it)\n' "$(basename "$d")"
    printf '  folder     %s\n' "${d#$ROOT/}"
    printf '\nGoal\n  %s\n' "$(wf_goal_text "$d/plan.md")"
  fi

  if [ -n "$d" ]; then
    # The Plan header names the bug and brief it came from, which need not
    # share its number — a plan written for an older bug does not.
    xref=$(grep -E '^[ \t]*>?[ \t]*\*\*(Bug|Brief):\*\*' "$d/plan.md" 2>/dev/null \
           | sed -E 's/^[ \t]*>?[ \t]*\*\*(Bug|Brief):\*\*[ \t]*/\1: /' \
           | grep -v '_(optional' || true)
    [ -n "$xref" ] && { printf '\nCame from\n'; printf '%s\n' "$xref" | sed 's/^/  /'; }

    if [ -f "$d/progress.md" ]; then
      printf '\nProgress — %s steps\n' "$(wf_step_counts "$d/progress.md")"
      wf_section_body "$d/progress.md" "Steps" \
        | sed -nE 's/^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*/  [✓] /p; s/^[[:space:]]*-[[:space:]]*\[[[:space:]]*\][[:space:]]*/  [ ] /p'
      log=$(wf_section_body "$d/progress.md" "Log" | grep -vE '^[[:space:]]*(>|$)' || true)
      [ -n "$log" ] && { printf '\nActivity log\n'; printf '%s\n' "$log" | sed 's/^/  /'; }
    fi

    if [ -f "$d/findings.md" ]; then
      fl=$(wf_findings_flat "$d/findings.md" | sed -E \
             -e 's/\*\*//g' \
             -e 's/^- \[ \][[:space:]]*/[open]   /' \
             -e 's/^- \[[xX]\][[:space:]]*/[closed] /')
      if [ -n "$fl" ]; then
        printf '\nFindings — %s open, %s closed\n' \
          "$(printf '%s\n' "$fl" | grep -c '^\[open\]' || true)" \
          "$(printf '%s\n' "$fl" | grep -c '^\[closed\]' || true)"
        printf '%s\n' "$fl" | sed 's/^/  /'
      fi
    fi
  fi

  if [ -n "$bug_md" ] && [ -f "$bug_md" ]; then
    bstage=$(basename "$(dirname "$(dirname "$bug_md")")")
    printf '\nBug %s — %s  [%s]\n' "$(wf_bug_id "$bug_md" 2>/dev/null)" \
      "$(head -1 "$bug_md" | sed 's/^#[[:space:]]*//')" "$bstage"
    grep -E '^[ \t]*>?[ \t]*\*\*(Status|Severity|Kind|Source|Plan):\*\*' "$bug_md" 2>/dev/null \
      | sed -E 's/^[ \t]*>?[ \t]*\*\*([A-Za-z]+):\*\*[ \t]*/  \1: /'
    printf '  file: %s\n' "${bug_md#$ROOT/}"
    desc=$(wf_section_body "$bug_md" "Description" | grep -v '^[[:space:]]*$' | head -3)
    [ -n "$desc" ] && printf '%s\n' "$desc" | sed 's/^/  | /'
  fi

  if [ -n "$brief_md" ] && [ -f "$brief_md" ]; then
    printf '\nBrief %s — %s  [%s]\n' "$(basename "$brief_md" | grep -oE "^($LV_BRF_RE)-[0-9]+")" \
      "$(wf_brief_title "$brief_md")" "$(wf_brief_status "$brief_md")"
    grep -E '^[ \t]*>?[ \t]*\*\*(Plan|Blocked|Parked):\*\*' "$brief_md" 2>/dev/null \
      | sed -E 's/^[ \t]*>?[ \t]*\*\*([A-Za-z]+):\*\*[ \t]*/  \1: /'
    printf '  file: %s\n' "${brief_md#$ROOT/}"
    desc=$(wf_section_body "$brief_md" "Problem" | grep -v '^[[:space:]]*$' | head -3)
    [ -n "$desc" ] && printf '%s\n' "$desc" | sed 's/^/  | /'
  fi

  # Plans that name this bug or brief in their header without sharing its
  # number — the link /lv-spec writes when one plan absorbs an older item.
  if [ -z "$plan_id" ] || [ "$id" != "$plan_id" ]; then
    refs=$(grep -lE "^[ \t]*>?[ \t]*\*\*(Bug|Brief):\*\*.*${id}([^0-9]|\$)" "$ROOT"/plans/*/plan.md 2>/dev/null \
           | while IFS= read -r f; do basename "$(dirname "$f")"; done || true)
    [ -n "$refs" ] && { printf '\nPlans naming %s\n' "$id"; printf '%s\n' "$refs" | sed 's/^/  /'; }
  fi

  # Gates: the one open now, and every answer ever given — the ledger
  # lv-gate-close.sh appends, which outlives the slot it overwrites.
  grow=$("$SELF_DIR/lv-list-gates.sh" "${plan_id:-$id}" 2>/dev/null | head -1 || true)
  ledger=""
  for f in "$ORCH/gates/resolved/"*.log; do
    [ -f "$f" ] || continue
    fid=$(basename "$f" | grep -oE "^($LV_WORK_RE)-[0-9]+" || true)
    [ -n "$fid" ] && [ "$((10#${fid##*-}))" = "$((10#$num))" ] || continue
    ledger="$ledger$(sed 's/\t/  /g; s/^/  /' "$f")"$'\n'
  done
  if [ -n "$grow" ] || [ -n "$ledger" ]; then
    printf '\nGates\n'
    [ -n "$grow" ] && printf '%s\n' "$grow" | awk -F'\t' '{ printf "  OPEN  %s  opened %s — %s\n", $2, $3, $4 }'
    [ -n "$ledger" ] && printf '%s' "$ledger" | sort
  fi

  claims=""
  for c in "$ORCH/claims/$num"*; do
    [ -e "$c" ] && claims="$claims  claim      $(basename "$c")"$'\n'
  done
  for a in "$ORCH/attempts/$num"*; do
    [ -f "$a" ] && claims="$claims  attempts   $(basename "$a"): $(tr '\n' ' ' < "$a")"$'\n'
  done
  [ -n "$claims" ] && { printf '\nClaim\n'; printf '%s' "$claims"; }

  # Git history across every name the number has had, on every branch.
  hist=$(git -C "$ROOT" log --all -E --grep="($LV_WORK_RE)-0*${num}([^0-9]|\$)" \
           --format='%h — %s' -n 10 2>/dev/null || true)
  [ -n "$hist" ] && { printf '\nGit history — newest 10, all branches\n'; printf '%s\n' "$hist" | sed 's/^/  /'; }

  ev=$("$0" events "${plan_id:-$id}" 2>/dev/null | grep -v '^  no events' || true)
  [ -n "$ev" ] && { printf '\nEvents\n'; printf '%s\n' "$ev"; }

  logs=$(artifact_logs "${plan_id:-$id}" | head -5)
  [ -n "$logs" ] && { printf '\nWorker logs — newest 5\n'; printf '%s\n' "$logs" | sed "s|^$ORCH/|  |"; }
  
}

case "$node" in
  row)
    metric="${1:-}"
    case "$metric" in
      daemon)   row_daemon ;;
      running)  row_running ;;
      gates|attn) row_gates ;;
      ideas)    row_ideas ;;
      intake)   row_intake ;;
      draft|ready|active|verify|testing|accept|complete|rolled-back|abandoned)
                row_state "$metric" ;;
      release)  row_promotable develop release ;;
      deploy)   row_promotable release main ;;
      registry) emit "registry audit — the registry against plans/" text "audit" ;;
      *) echo "lv-tray-drill: no such row '$metric'" >&2; exit 2 ;;
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
    # A bug not yet specced has no plan folder; its bug.md is the whole record.
    bloc=$(wf_bug_md "$id" 2>/dev/null || true)
    [ -n "$bloc" ] && emit "bug.md — the report (${bloc%%$'\t'*})" file "${bloc#*$'\t'}"
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
    pattern="($LV_WORK_RE)-0*$num([^0-9]|$)"
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
    "$SELF_DIR/lv-registry-audit.sh" 2>&1 | sed 's/^/  /'
    ;;

  history)
    # One number's whole record, read top to bottom. An artifact keeps its
    # number when it changes kind — BUG-043 and BRF-041 become PLN-043 and
    # PLN-041 — so the number, not the name asked for, is what gathers it:
    # asking about the bug shows the plan it became, and the other way round.
    id="${1:-}"
    num=$(printf '%s' "$id" | grep -oE '[0-9]+' | head -1)
    [ -n "$num" ] || { echo "lv-tray-drill: history wants an ID, got '$id'" >&2; exit 2; }

    plan_id="" bug_md="" brief_md=""
    while IFS=' ' read -r _pfx what rest; do
      case "$what" in
        REGISTRY) plan_id="${rest#row }" ;;
        */bugs/*) [ -n "$bug_md" ] || bug_md="$what/bug.md" ;;
        */plans/briefs/*) [ -n "$brief_md" ] || brief_md="$what" ;;
      esac
    done < <(wf_artifacts_with_number "$num")
    d=$(plan_dir "$id")
    if [ -z "$plan_id" ] && [ -z "$d" ] && [ -z "$bug_md" ] && [ -z "$brief_md" ]; then
      printf '%s: not found — no REGISTRY row, plan folder, bug or brief carries that number\n' "$id"
      exit 1
    fi

    # Sections open with a blank line; a record that starts at the bug or the
    # brief (no plan yet) would lead with one, so leading blanks are dropped.
    history_body | sed '/./,$!d'
    ;;

  *)
    echo "lv-tray-drill: no such node '$node'" >&2
    exit 2
    ;;
esac

# A body node has already said everything it has to say; only a list node can
# be empty in the way a caller needs to hear about.
case "$node" in
  row|worker|gate|artifact|logs) [ "$emitted" -gt 0 ] || exit 1 ;;
esac
exit 0
