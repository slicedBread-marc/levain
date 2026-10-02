#!/usr/bin/env bash
# lv-tray.sh [--watch [seconds]] [--plain] [--stats] [--fields] [--plans]
#
# One pane showing everything in flight: running workers, queued gates, the
# pipeline by state, and recent events. This is the replacement for holding
# four terminals' worth of state in your head.
#
# None of it needs the daemon. Every number here is read from REGISTRY.md,
# plans/, bugs/ and the gate files, which a project run entirely by hand
# (orchestrator.enabled: false, no daemon ever started) has just the same —
# the orchestrator's own files only add the RUNNING and RECENT sections, and
# each of those says "nothing" rather than failing when they are absent.
#
# Read-only — reads REGISTRY.md, pidfiles, gate files and events.log, and runs
# lv-registry-audit.sh. Changes nothing, costs no tokens.
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
#                 script to parse (see coordinator' lv-rack, which builds a
#                 cross-project grid from this). Not for humans. Includes
#                 attn=<comma-separated gated plan IDs, most-important
#                 first, `!` suffix on a stuck one, `~` on a collision:
#                 a question whose plan's upstream or directives moved
#                 after it was asked (LVI-033)>,
#                 brainstorms=<briefs listed under ## Idea / ## Exploring in
#                 plans/briefs/INDEX.md — thinking never carried to a
#                 decision> with brainstorms_drift=<brief files that have no
#                 row in that index at all>,
#                 release_pending=<plans complete on develop but not yet
#                 carried through /lv-release, or `-` with no release
#                 branch>, and deploy_pending=<plans on release but not
#                 main, or `-` if this project has no release/main split>.
#   --plans       the full view plus the plan-by-plan picture (PLANS: each
#                 plan by what it is waiting for, bugs, done-by-tag) and one
#                 ranked NEXT action — what /lv-tray shows. Ignored by
#                 --stats and --fields, whose shapes are fixed.
#
# Exit 0 always.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"
# shellcheck source=lv-states.sh
source "$SELF_DIR/lv-states.sh"

watch_mode=false
watch_secs=10
plain=false
stats_only=false
fields_mode=false
plans_mode=false

while [ $# -gt 0 ]; do
  case "$1" in
    --watch) watch_mode=true
             if [ "${2:-}" ] && [ "${2#-}" = "${2}" ]; then watch_secs="$2"; shift; fi
             shift ;;
    --plain)  plain=true; shift ;;
    --stats)  stats_only=true; shift ;;
    --fields) fields_mode=true; shift ;;
    --plans)  plans_mode=true; shift ;;
    *) echo "Usage: $0 [--watch [seconds]] [--plain] [--stats] [--fields] [--plans]" >&2; exit 1 ;;
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

has_ref() { git -C "$ROOT" rev-parse --verify "$1" >/dev/null 2>&1; }

# plans_ahead <a> <b> — how many DISTINCT plan IDs appear in commits on <a>
# that are not on <b>.
#
# One `git log` into one awk. The `--oneline | grep -oE | sort -u | wc -l |
# tr -d ' '` form this replaces was five processes per counter, twice per
# render, and coordinator' lv-rack renders this board for nine projects at once.
# `--format=%s` rather than `--oneline` because the abbreviated SHA an
# --oneline line carries is hex and can never hold a PLN id anyway.
# The seen-count is kept in a variable, not `length(array)`, which is a gawk
# extension and not available in the awk that ships on macOS.
plans_ahead() {
  git -C "$ROOT" log --format=%s "$1" --not "$2" 2>/dev/null | awk -v plan_id_re="($LV_PLN_RE)-[0-9]+" '
    {
      while (match($0, plan_id_re)) {
        k = substr($0, RSTART, RLENGTH)
        if (!(k in seen)) { seen[k] = 1; n++ }
        $0 = substr($0, RSTART + RLENGTH)
      }
    }
    END { print n + 0 }'
}

# ── --plans: the plan-by-plan picture and one ranked next action ─────────
#
# What /lv-status used to assemble in a model from a dozen lv-list-* calls and
# a priority table, done once here instead: the lists are the same scripts,
# and the ranking is code, so every reader gets the same answer to "what do I
# do now" — and gates rank in it, which the table never had. A gate is the one
# thing that no amount of waiting, and no other skill, moves.
#
# Nothing here reads the orchestrator's files except to know whether a worker
# already holds a plan. A project run by hand gets the whole view.

# plans_context — the banner lines /lv-status carried: branch, harness
# version, and the two plan files that change what a reader should do next.
plans_context() {
  local branch ver
  branch=$(git -C "$ROOT" branch --show-current 2>/dev/null || true)
  ver=$(cat "$ROOT/.claude/workflow-version" 2>/dev/null || true)
  printf '  branch: %s   workflow: %s\n' "${branch:-?}" "${ver:-?}"
  [ -f "$ROOT/plans/MIGRATION-NOTES.md" ] && \
    printf '  %spending migration actions — see plans/MIGRATION-NOTES.md%s\n' "$YEL" "$R"
  [ -f "$ROOT/plans/auto-test-log.md" ] && \
    printf '  auto-test log active — see plans/auto-test-log.md (feedback for spec classification)\n'
  printf '\n'
}

# run_list <script> — one lv-list-* script's stdout, from the develop root,
# tabs turned into 0x1f. They exit 1 when empty, which is not an error here.
# 0x1f because tab is IFS whitespace: a run of them collapses, so an empty
# goal column would shift every field after it.
run_list() {
  (cd "$ROOT" && "$SELF_DIR/$1" 2>/dev/null) | tr '\t' '\037' || true
}

# split_plan_name <ID-slug> — sets p_id and p_slug. The lists key on the
# folder name; a reader wants the ID and the slug as two columns.
split_plan_name() {
  local re="^(($LV_PLN_RE)-[0-9]+)-?(.*)$"
  if [[ $1 =~ $re ]]; then
    p_id="${BASH_REMATCH[1]}"; p_slug="${BASH_REMATCH[3]}"
  else
    p_id="$1"; p_slug=""
  fi
}

# section <title> <lines> — a sub-heading and its items, or nothing at all
# when it has none: an empty section is noise in a view meant to be scanned.
section() {
  [ -n "$2" ] || return 0
  printf '  %s%s%s\n' "$B" "$1" "$R"
  printf '%s\n' "$2"
  plans_shown=$((plans_shown + 1))
}

# item <urgent?> <id> <slug> <detail>
item() {
  local tag=""
  local detail="${4# }"
  [ "$1" = "urgent" ] && tag="${RED}[urgent]${R} "
  if [ -n "$detail" ]; then
    printf '    %s%-11s %-30s %s\n' "$tag" "$2" "$3" "$detail"
  else
    printf '    %s%-11s %s\n' "$tag" "$2" "$3"
  fi
}

# gated_note <id> — " [gated: <name>]" when a gate is open on it. The draft,
# verify and test lists do not look at gates; lv-list-implementable.sh does,
# which is why build and fix rows never need this.
gated_note() {
  local g
  g=$(printf '%s\n' "$gates" | awk -F'\t' -v id="$1" '$1 == id { print $2; exit }')
  [ -n "$g" ] && printf ' [gated: %s]' "$g"
  return 0
}

render_plans() {
  local impl replan drafts verify testable briefs bugs ideas
  impl=$(run_list lv-list-implementable.sh)
  replan=$(run_list lv-list-replanning.sh)
  drafts=$(run_list lv-list-drafts.sh)
  verify=$(run_list lv-list-verify.sh)
  testable=$(run_list lv-list-testable.sh)
  briefs=$(run_list lv-list-briefs.sh)
  bugs=$(run_list lv-list-bugs.sh)
  ideas=$(run_list lv-list-brainstorms.sh)

  local s_replan="" s_fix="" s_build="" s_blocked="" s_progress=""
  local s_verify="" s_test="" s_draft="" s_plan="" s_ideas="" s_bugs=""
  # The first of each kind, for NEXT. `*_u` is the first URGENT one: urgency
  # decides who is named first within a level, never which level applies.
  local n_fix="" n_fix_u="" n_fix_n=0 n_replan="" n_test="" n_test_u=""
  local n_build="" n_build_u="" n_draft="" n_plan="" n_verify=""
  local n_progress="" n_blocked=""
  local type name goal prio extra f5 f6 unchecked esc detail
  local p_id p_slug plans_shown=0

  # lv-list-implementable.sh is the one list that already knows every reason
  # a plan cannot be picked up — gate, deps, a claim — so it sorts the active
  # and ready plans. Its `new` rows ARE "ready to build": a ready plan that is
  # blocked or gated shows under those instead, not twice. `gated` rows are
  # left to the GATES section above, which already names every one of them.
  while IFS=$'\037' read -r type name goal prio extra; do
    [ -n "$type" ] || continue
    split_plan_name "$name"
    case "$type" in
      fix)
        unchecked=$(wf_unchecked_count "$ROOT/plans/$name/findings.md")
        s_fix="$s_fix$(item "$prio" "$p_id" "$p_slug" "$unchecked open finding(s)")"$'\n'
        n_fix_n=$((n_fix_n + 1))
        [ -n "$n_fix" ] || n_fix="$p_id"
        [ "$prio" = "urgent" ] && [ -z "$n_fix_u" ] && n_fix_u="$p_id" ;;
      resume)
        s_fix="$s_fix$(item "$prio" "$p_id" "$p_slug" "stalled — no open findings, resume it")"$'\n'
        n_fix_n=$((n_fix_n + 1))
        [ -n "$n_fix" ] || n_fix="$p_id"
        [ "$prio" = "urgent" ] && [ -z "$n_fix_u" ] && n_fix_u="$p_id" ;;
      new)
        s_build="$s_build$(item "$prio" "$p_id" "$p_slug" "")"$'\n'
        [ -n "$n_build" ] || n_build="$p_id"
        [ "$prio" = "urgent" ] && [ -z "$n_build_u" ] && n_build_u="$p_id" ;;
      processing)
        s_progress="$s_progress$(item "$prio" "$p_id" "$p_slug" "claimed $extra")"$'\n'
        [ -n "$n_progress" ] || n_progress="$p_id" ;;
      blocked)
        s_blocked="$s_blocked$(item "$prio" "$p_id" "$p_slug" "[blocked by $extra]")"$'\n'
        [ -n "$n_blocked" ] || n_blocked="$p_id (blocked by $extra)" ;;
    esac
  done <<< "$impl"

  while IFS=$'\037' read -r name esc goal; do
    [ -n "$name" ] || continue
    split_plan_name "$name"
    s_replan="$s_replan$(item - "$p_id" "$p_slug" "$esc escalated finding(s)$(gated_note "$p_id")")"$'\n'
    [ -n "$n_replan" ] || n_replan="$p_id"
  done <<< "$replan"

  # A draft carrying ESCALATED findings is already listed above as replanning.
  while IFS=$'\037' read -r name goal; do
    [ -n "$name" ] || continue
    split_plan_name "$name"
    case $'\n'"$s_replan" in *$'\n'"    $p_id "*) continue ;; esac
    s_draft="$s_draft$(item - "$p_id" "$p_slug" "$(gated_note "$p_id")")"$'\n'
    [ -n "$n_draft" ] || n_draft="$p_id"
  done <<< "$drafts"

  while IFS=$'\037' read -r name unchecked esc goal; do
    [ -n "$name" ] || continue
    split_plan_name "$name"
    detail="automated checks"
    [ "${unchecked:-0}" -gt 0 ] 2>/dev/null && detail="$detail, $unchecked unchecked"
    [ "${esc:-0}" -gt 0 ] 2>/dev/null && detail="$detail, $esc escalated"
    s_verify="$s_verify$(item - "$p_id" "$p_slug" "$detail$(gated_note "$p_id")")"$'\n'
    [ -n "$n_verify" ] || n_verify="$p_id"
  done <<< "$verify"

  # Urgent first, as the build and fix lists already are — lv-list-testable.sh
  # keeps registry order.
  local t_urgent="" t_normal=""
  while IFS=$'\037' read -r name _wt _br goal prio f6; do
    [ -n "$name" ] || continue
    split_plan_name "$name"
    detail="awaiting human acceptance test"
    case "$f6" in blocked:*) detail="[blocked by ${f6#blocked:}]" ;; esac
    detail="$detail$(gated_note "$p_id")"
    if [ "$prio" = "urgent" ]; then
      t_urgent="$t_urgent$(item urgent "$p_id" "$p_slug" "$detail")"$'\n'
    else
      t_normal="$t_normal$(item - "$p_id" "$p_slug" "$detail")"$'\n'
    fi
    # A blocked plan cannot be accepted yet, so it is never the next action.
    case "$f6" in blocked:*) continue ;; esac
    [ -n "$n_test" ] || n_test="$p_id"
    [ "$prio" = "urgent" ] && [ -z "$n_test_u" ] && n_test_u="$p_id"
  done <<< "$testable"
  s_test="$t_urgent$t_normal"

  # Ready to plan: briefs whose thinking concluded, and open bugs serious
  # enough to plan now. The rest of the bugs are listed under their own head.
  local section_name="" bname bdesc bid bslug
  while IFS=$'\037' read -r bname bdesc; do
    case "$bname" in '# '*) section_name="${bname#\# }"; continue ;; esac
    [ -n "$bname" ] && [ "$section_name" = "Decided" ] || continue
    bid="${bname%%-[!0-9]*}"; bslug="${bname#"$bid"}"
    s_plan="$s_plan$(item - "$bid" "${bslug#-}" "Decided — ${bdesc:0:90}")"$'\n'
    [ -n "$n_plan" ] || n_plan="$bid"
  done <<< "$briefs"
  local sev btitle bplan stage=""
  while IFS=$'\037' read -r bid sev btitle bplan; do
    case "$bid" in '# '*) stage="${bid#\# }"; continue ;; esac
    [ -n "$bid" ] || continue
    detail="[$stage]"
    case "$bplan" in *[0-9]*) detail="→ $(printf '%s' "$bplan" | grep -oE "($LV_PLN_RE)-[0-9]+" | head -1) $detail" ;; esac
    s_bugs="$s_bugs$(item - "$bid" "(${sev:-?})" "${btitle:0:90} $detail")"$'\n'
    if [ "$stage" = "open" ]; then
      case "$sev" in Critical*|High*)
        s_plan="$s_plan$(item - "$bid" "" "$sev bug — ${btitle:0:90}")"$'\n'
        [ -n "$n_plan" ] || n_plan="$bid" ;;
      esac
    fi
  done <<< "$bugs"

  local iid istatus iname idesc
  while IFS=$'\037' read -r iid istatus iname idesc; do
    [ -n "$iid" ] || continue
    idesc="${idesc:-$iname}"
    s_ideas="$s_ideas$(item - "$iid" "$istatus" "${idesc:0:90}")"$'\n'
  done <<< "$ideas"

  # Done, counted per tag. A plan carrying two tags counts under both — the
  # question this answers is "how much of each kind of work has shipped".
  local s_done=""
  if [ -f "$REGISTRY" ]; then
    s_done=$(wf_registry_rows "$REGISTRY" | awk -F'\037' '
      $3 == "complete" {
        n = split($8, t, ",")
        k = 0
        for (i = 1; i <= n; i++) {
          gsub(/^[ \t]+|[ \t]+$/, "", t[i])
          if (t[i] != "" && t[i] != "—" && t[i] != "-") { c[t[i]]++; k++ }
        }
        if (k == 0) c["uncategorized"]++
      }
      END { for (x in c) printf "%d\t%s\n", c[x], x }' \
      | sort -t"$(printf '\t')" -k1,1nr -k2,2 \
      | awk -F'\t' '{ printf "    %-24s %d plan(s)\n", $2, $1 }')
  fi

  # The express lane (LVI-025): every live plan whose `## Lane` section says
  # what lv-lane.sh last decided, so a downgrade is on the board with its
  # reason instead of only inside plan.md.
  local s_lane="" l_row l_id l_slug l_md l_verdict l_first l_n
  if [ -f "$REGISTRY" ]; then
    while IFS=$'\037' read -r l_id l_slug l_state _; do
      case "$l_state" in complete|abandoned) continue ;; esac
      l_md="$ROOT/plans/${l_id}-${l_slug}/plan.md"
      [ -f "$l_md" ] && grep -q '^## Lane' "$l_md" 2>/dev/null || continue
      l_verdict=$(awk '/^## Lane/{i=1;next} /^## /{i=0} i && /\*\*Checked:\*\*/{print; exit}' "$l_md")
      if printf '%s' "$l_verdict" | grep -q 'downgraded'; then
        l_n=$(awk '/^## Lane/{i=1;next} /^## /{i=0} i && /^> - /{n++} END{print n+0}' "$l_md")
        l_first=$(awk '/^## Lane/{i=1;next} /^## /{i=0} i && /^> - /{sub(/^> - /,""); print; exit}' "$l_md" | cut -c1-70)
        l_row="downgraded — $l_n reason(s): $l_first"
      else
        l_row="express — no human gate"
      fi
      s_lane+="$(item normal "$l_id" "$l_slug" "$l_row")"$'\n'
    done < <(wf_registry_rows "$REGISTRY")
  fi

  printf '\n%s\n' "${B}PLANS${R}"
  section "express lane (lv-lane.sh check <ID>)" "${s_lane%$'\n'}"
  section "needs replanning (/lv-spec)" "${s_replan%$'\n'}"
  section "ready to fix (/lv-implement)" "${s_fix%$'\n'}"
  section "ready to build (/lv-implement)" "${s_build%$'\n'}"
  section "blocked" "${s_blocked%$'\n'}"
  section "in progress — claimed by a session" "${s_progress%$'\n'}"
  section "verifying" "${s_verify%$'\n'}"
  section "ready to test (/lv-test)" "${s_test%$'\n'}"
  section "drafts (/lv-spec)" "${s_draft%$'\n'}"
  section "ready to plan (/lv-spec)" "${s_plan%$'\n'}"
  section "ideas — $brainstorms incomplete brainstorm(s) (/lv-brainstorm)" "${s_ideas%$'\n'}"
  section "bugs" "${s_bugs%$'\n'}"
  section "done, by tag" "$s_done"
  [ "$plans_shown" -gt 0 ] || printf '  %snothing in the pipeline%s\n' "$DIM" "$R"
  printf '\n'

  # ── NEXT: one action, the first level that applies ─────────────────
  # The order is the point. A lower level is never chosen because a higher
  # one "seems minor": fixing a built plan is cheaper than building a new
  # one, and a plan a human could accept today outranks one nobody has built.
  local next="" why="" first=""
  if [ "$gates_n" -gt 0 ]; then
    first=$(printf '%s\n' "$gates" | head -1 | awk -F'\t' '{ print $1 " (" $2 ")" }')
    next="Run /lv-attend — $gates_n gate(s) waiting; start with $first."
    why="a gate only moves when a human answers it, and it holds up everything behind it"
    [ "$gates_stuck" -gt 0 ] && \
      why="$why. $gates_stuck stuck: those hit their attempt budget and need a human look, not another retry"
  elif [ "$daemon_raw" = "running" ] && \
       [ $((running_n + st_draft + st_ready + st_active + st_verify + st_testing)) -gt 0 ]; then
    next="Nothing needs you — the daemon is driving ($running_n worker(s) running). Check back."
    why="no gate is open, and every other state is the daemon's to move"
  elif [ -n "$n_fix" ]; then
    first="${n_fix_u:-$n_fix}"
    next="Run /lv-implement to fix $first ($n_fix_n plan(s) with open findings or stalled)."
    why="built work with findings is the cheapest to finish"
  elif [ -n "$n_replan" ]; then
    next="Run /lv-spec to address the escalated findings in $n_replan."
    why="escalated findings sent it back to draft; nothing else moves it"
  elif [ -n "$n_test" ]; then
    first="${n_test_u:-$n_test}"
    next="Run /lv-test for human acceptance testing of $first."
    why="it is built and verified, and only a human can accept it"
  elif [ -n "$n_build" ]; then
    first="${n_build_u:-$n_build}"
    next="Run /lv-implement to start $first."
    why="it is ready, unblocked and unclaimed"
  elif [ -n "$n_draft" ]; then
    next="Review $n_draft in /lv-spec to move it to ready."
    why="a plan only leaves draft through a spec run"
  elif [ -n "$n_plan" ]; then
    next="Run /lv-spec to plan $n_plan."
    why="a decided brief or a serious open bug is waiting for a plan"
  elif [ -n "$n_verify" ]; then
    case "$running_roles" in
      *" verify:$n_verify-"*|*" verify:$n_verify "*)
        next="Wait — a verify worker is running on $n_verify." ;;
      *) next="Run /lv-verify on $n_verify." ;;
    esac
    why="it is built, and verify is the only step between it and a human test"
  elif [ -n "$n_progress" ]; then
    next="Wait — $n_progress is claimed by another session."
    why="everything else is done or waiting on it"
  elif [ -n "$n_blocked" ]; then
    next="Unblock $n_blocked — every remaining plan waits on a dependency."
    why="nothing is buildable until its deps complete"
  elif [ "$brainstorms" -gt 0 ] 2>/dev/null; then
    next="Run /lv-brainstorm to decide or park $brainstorms unfinished idea(s)."
    why="the pipeline is empty, but the backlog is unfinished thinking, not nothing"
  else
    next="Run /lv-brainstorm or /lv-bug to feed the pipeline."
    why="nothing is pending"
  fi
  local urgent=""
  if { [ -n "$n_fix_u" ] && [ "$first" = "$n_fix_u" ]; } || \
     { [ -n "$n_test_u" ] && [ "$first" = "$n_test_u" ]; } || \
     { [ -n "$n_build_u" ] && [ "$first" = "$n_build_u" ]; }; then
    urgent="${RED}[URGENT]${R} "
  fi

  printf '%s\n' "${B}NEXT${R}"
  printf '  %s%s\n' "$urgent" "$next"
  printf '  %swhy: %s%s\n' "$DIM" "$why" "$R"
  # Starting the daemon is an alternative to working the list by hand, never
  # the recommendation: a project with the orchestrator off runs this way on
  # purpose. Said only where the daemon is switched on and not running.
  if [ "$daemon_raw" = "stale" ]; then
    printf '  %sthe daemon pidfile is stale — it died; restart it with lv-orchestrate.sh --daemon%s\n' "$YEL" "$R"
  elif [ "$daemon_raw" = "off" ] && [ "$enabled" = "true" ] && [ -n "$n_fix$n_build$n_draft$n_verify" ]; then
    printf '  %sor let the daemon do it: scripts/lv-exec.sh lv-orchestrate.sh --daemon%s\n' "$DIM" "$R"
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

  local running_n=0 pf pid base role artifact age running_roles=""
  local -a running_lines=()
  for pf in "$ORCH/logs"/*.pid; do
    [ -f "$pf" ] || continue
    pid=$(cat "$pf" 2>/dev/null || echo "")
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
    base=$(basename "$pf" .pid)
    role="${base##*-}"
    artifact="${base%-*}"
    # Pidfiles are keyed on the artifact number (lv-spawn.sh), which is the one
    # identity a bug keeps when it becomes a plan. Name it for the reader.
    if printf '%s' "$artifact" | grep -qE '^[0-9]+$'; then
      # Matched on the number's VALUE, not its text: a pidfile carries
      # whatever digits the spawning id had (`001` from PLN-001), and a
      # string compare misses across that padding — leaving the board naming
      # a live worker by a bare number it cannot look up.
      artifact=$(awk -F'|' -v n="$artifact" -v work_re="^($LV_WORK_RE)-[0-9]+$" '
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        { id = trim($2) }
        id ~ work_re {
          split(id, a, "-")
          if (a[2] + 0 == n + 0) { print id "-" trim($3); exit }
        }' "$ROOT/plans/REGISTRY.md" 2>/dev/null || true)
      [ -n "$artifact" ] || artifact="${base%-*}"
    fi
    age=$(( now - $(wf_file_mtime "$pf") ))
    running_lines+=("$(printf '  %s%-11s%s %-34s %s  %spid %s%s' \
      "$CYN" "$role" "$R" "$artifact" "$(wf_human_age "$age")" "$DIM" "$pid" "$R")")
    running_n=$((running_n + 1))
    running_roles="$running_roles $role:$artifact "
  done

  local gates; gates=$("$SELF_DIR/lv-list-gates.sh" 2>/dev/null || true)
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

  # Which plans are gated, in the same cost-then-age order lv-list-gates.sh
  # already sorted them in — a `!` suffix flags a stuck one so a consumer can
  # colour it without re-deriving gate names. --fields only; the full-mode
  # GATES list below already names each plan.
  local attn=""
  if [ -n "$gates" ]; then
    attn=$(printf '%s\n' "$gates" | awk -F'\t' '{
      id = $1; sub(/^[A-Z]+-/, "", id)
      tok = id
      if ($2 ~ /stuck/) tok = tok "!"
      if ($9 == "moved") tok = tok "~"
      printf "%s%s", (NR > 1 ? "," : ""), tok
    }')
  fi

  # ── Pipeline histogram ───────────────────────────────────────────────
  # One pass, not one pass per state (see counts= below). The terminal states
  # are tracked too — a plan appearing in no column at all is how a project
  # ends up with plan folders nobody can account for (WFI-009).
  #
  # The list comes from lv-states.sh rather than being written out again here,
  # because the copy that used to live here had already drifted: `rolled-back`
  # was added to the pipeline and never to the board, so a rolled-back plan was
  # in exactly the accounting hole WFI-009 describes.
  local st_draft=0 st_ready=0 st_active=0 st_verify=0 st_testing=0
  local st_complete=0 st_rolled_back=0 st_abandoned=0
  if [ -f "$REGISTRY" ]; then
    local st n counts var
    counts=" $(awk -F'|' -v plan_row_re="^[|] ($LV_PLN_RE)-" '
      function trim(x) { gsub(/^[ \t]+|[ \t]+$/, "", x); return x }
      $0 ~ plan_row_re { c[trim($4)]++ }
      END { for (s in c) printf "%s=%s ", s, c[s] }' "$REGISTRY")"
    for st in $LV_STATES; do
      n="${counts##* $st=}"
      if [ "$n" = "$counts" ]; then n=0; else n="${n%% *}"; fi
      # `rolled-back` is not a legal variable name; the rest map straight over.
      var="st_${st//-/_}"
      printf -v "$var" '%s' "$n"
    done
  fi

  # ── Incomplete brainstorms ───────────────────────────────────────────
  # Briefs listed under `## Idea` / `## Exploring` in plans/briefs/INDEX.md —
  # thinking that was started and never carried to a decision. The pipeline
  # histogram above cannot show them: it counts PLN- rows, and a brief has no
  # registry row until it becomes a plan. lv-list-specable.sh cannot either —
  # it offers only `Decided` briefs, by design. So an idea captured on a
  # Tuesday and forgotten is invisible on every existing surface, which is
  # exactly the class of thing this board exists to stop.
  #
  # `brainstorms_drift` is the second number because the index is maintained
  # by hand: a brief file with no row in it is not counted (the index is the
  # source of truth) but must not be silent either — client-e carried ten of
  # them. lv-brainstorm-reindex.sh is the repair.
  local brainstorms=0 brainstorms_drift=0
  if [ -f "$ROOT/plans/briefs/INDEX.md" ]; then
    # `|| true`, not `|| echo 0`: --count prints the number and STILL exits 1
    # when it is zero (the lv-list-* convention), so a fallback echo would
    # append a second line to a perfectly good "0".
    brainstorms=$("$SELF_DIR/lv-list-brainstorms.sh" --count 2>/dev/null || true)
    brainstorms_drift=$("$SELF_DIR/lv-list-brainstorms.sh" --drift --count 2>/dev/null || true)
    [ -n "$brainstorms" ] || brainstorms=0
    [ -n "$brainstorms_drift" ] || brainstorms_drift=0
  fi

  # ── Release pending ──────────────────────────────────────────────────
  # Plans complete on `develop` that have never been carried through
  # /lv-release — so the full, unfiltered suite has never run against them
  # and `release` has never validated them against staging. This is the gap
  # the REGISTRY state histogram above can't show: a plan reads `complete`
  # the moment its PR merges to develop, which is also true the day before
  # /lv-release runs and the day after — the registry has no state for
  # "done, but not yet promoted." Same distinct-plan-ID convention as
  # deploy_pending below; same `-1`/`-` meaning for a project with no
  # release branch at all.
  # `release` is asked about once and the answer reused by deploy_pending
  # below, which needed the same fact.
  local has_release=false
  if has_ref release; then has_release=true; fi

  local release_pending=-1
  if [ "$has_release" = true ] && has_ref develop; then
    release_pending=$(plans_ahead develop release)
  fi

  # ── Deploy pending ────────────────────────────────────────────────────
  # Plans whose commits reached `release` (passed /lv-release's E2E) but
  # haven't reached `main` yet — staged for /lv-deploy. Distinct plan IDs,
  # not commit count: one plan can land several commits on release. `-1`
  # (rendered `-`) means this project doesn't have both refs, not "zero
  # pending" — client-i and friends have no release/main split.
  local deploy_pending=-1
  if [ "$has_release" = true ] && has_ref main; then
    deploy_pending=$(plans_ahead release main)
  fi

  # ── Registry integrity ──────────────────────────────────────────────
  # The audit's own exit code is the dirty signal (0 = clean, 1 = problems),
  # not "did it print anything" — it also emits informational note() lines
  # (e.g. a COUNTER note) that don't count as problems and precede a trailing
  # "registry audit: clean". Matching on output text used to call that dirty
  # and print a REGISTRY section headed "the registry and plans/ disagree"
  # directly above a line saying the opposite.
  local audit registry_dirty=false registry_n=0
  if ! audit=$("$SELF_DIR/lv-registry-audit.sh" 2>/dev/null); then
    registry_dirty=true
    # The audit's own last line carries its authoritative count ("registry
    # audit: N problem(s)") — counting non-blank lines instead would count
    # description rows too, which over-reports.
    registry_n=$(printf '%s\n' "$audit" | grep -oE '[0-9]+ problem' | tail -1 | grep -oE '^[0-9]+')
    [ -n "$registry_n" ] || registry_n=-1
  fi

  if $fields_mode; then
    # One line, tab-separated key=value, no colour — for another script to
    # parse (coordinator' lv-rack builds a cross-project grid from this rather
    # than scraping the human-formatted output above).
    local registry_field="clean"
    $registry_dirty && registry_field="$registry_n"
    local release_field="$release_pending"
    [ "$release_field" -lt 0 ] 2>/dev/null && release_field="-"
    local deploy_field="$deploy_pending"
    [ "$deploy_field" -lt 0 ] 2>/dev/null && deploy_field="-"
    printf 'daemon=%s\tenabled=%s\tspawns=%s/%s\trunning=%s\tgates=%s\tgates_stuck=%s\tgates_blocked=%s\tdraft=%s\tready=%s\tactive=%s\tverify=%s\ttesting=%s\tcomplete=%s\trolled_back=%s\tabandoned=%s\tregistry=%s\tattn=%s\trelease_pending=%s\tdeploy_pending=%s\tbrainstorms=%s\tbrainstorms_drift=%s\n' \
      "$daemon_raw" "$enabled" "$budget_used" "$budget_max" \
      "$running_n" "$gates_n" "$gates_stuck" "$gates_blocked" \
      "$st_draft" "$st_ready" "$st_active" "$st_verify" "$st_testing" \
      "$st_complete" "$st_rolled_back" "$st_abandoned" \
      "$registry_field" "$attn" "$release_field" "$deploy_field" \
      "$brainstorms" "$brainstorms_drift"
    return
  fi

  # ── Header ──────────────────────────────────────────────────────────
  printf '%s\n' "${B}WORKFLOW BOARD${R}  ${DIM}$(date '+%Y-%m-%d %H:%M:%S')${R}"
  printf '  daemon: %s   enabled: %s   spawns this hour: %s/%s\n\n' \
    "$daemon_state" "$enabled" "$budget_used" "$budget_max"
  $plans_mode && ! $stats_only && plans_context

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
    printf '%s\n' "${B}GATES${R} ${DIM}— waiting on you (/lv-attend)${R}"
    if [ -n "$gates" ]; then
      printf '%s\n' "$gates" | while IFS=$'\t' read -r gid gname gopened gq _gctx gblk _gst _gfit gqfit; do
        [ -n "$gid" ] || continue
        # A collision: the plan's own text is unchanged, but what it was
        # specced against moved after the question was asked (LVI-033).
        [ "$gqfit" = "moved" ] && gq="${RED}COLLISION — upstream or directives moved since asked; do not approve (lv-plan-context.sh $gid)${R} $gq"
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

    # ── Directives ────────────────────────────────────────────────────
    # An overseer's standing instructions on plans in flight (lv-direct.sh,
    # LVI-033): holds, and constraints/replans not yet applied by /lv-spec.
    # Applied ones are binding too but need nothing from anyone, so they are
    # not listed. Printed only when there is something to show.
    local dlines="" dfile did drows
    for dfile in "$ROOT"/plans/*/directives.md; do
      [ -f "$dfile" ] || continue
      did=$(basename "$(dirname "$dfile")" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
      [ -n "$did" ] || continue
      drows=$(wf_directives_live "$did" 2>/dev/null | awk -F'\037' -v id="$did" '
        $2 == "hold" { printf "  HOLD    %-11s %s %s\n", id, $1, $7; next }
        $3 == "open" { printf "  %-7s %-11s %s %s\n", toupper($2), id, $1, $7 }')
      [ -n "$drows" ] && dlines="$dlines$drows"$'\n'
    done
    if [ -n "$dlines" ]; then
      printf '%s\n' "${B}DIRECTIVES${R} ${DIM}— held, or not yet applied (lv-direct.sh list <ID>)${R}"
      printf '%s' "$dlines"
      printf '\n'
    fi
  fi

  # ── Pipeline ────────────────────────────────────────────────────────
  printf '%s\n' "${B}PIPELINE${R}"
  if [ -f "$REGISTRY" ]; then
    # Before `draft`: thinking that hasn't produced a plan yet. Listed with the
    # states even though it isn't one, because that is where a reader looks for
    # "what is in this project" — and an idea nobody has looked at in a month
    # is the one thing here that never announces itself.
    if [ "$brainstorms" -gt 0 ] 2>/dev/null; then
      printf '  %-11s %s' "brainstorms" "$brainstorms"
    else
      printf '  %s%-11s %s%s' "$DIM" "brainstorms" "$brainstorms" "$R"
    fi
    if [ "$brainstorms_drift" -gt 0 ] 2>/dev/null; then
      printf ' %s(+%s not in INDEX.md — lv-brainstorm-reindex.sh)%s' "$YEL" "$brainstorms_drift" "$R"
    fi
    printf '\n'
    printf '  %-11s %s\n' "draft" "$st_draft"
    printf '  %-11s %s\n' "ready" "$st_ready"
    printf '  %-11s %s\n' "active" "$st_active"
    printf '  %-11s %s\n' "verify" "$st_verify"
    printf '  %-11s %s\n' "testing" "$st_testing"
    printf '  %s%-11s %s%s\n' "$DIM" "complete" "$st_complete" "$R"
    printf '  %s%-11s %s%s\n' "$DIM" "rolled-back" "$st_rolled_back" "$R"
    printf '  %s%-11s %s%s\n' "$DIM" "abandoned" "$st_abandoned" "$R"
    if [ "$release_pending" -ge 0 ] 2>/dev/null; then
      if [ "$release_pending" -gt 0 ]; then
        printf '  %s%-9s %s%s\n' "$YEL" "release" "$release_pending" "$R"
      else
        printf '  %s%-9s %s%s\n' "$DIM" "release" "$release_pending" "$R"
      fi
    fi
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

  $plans_mode && render_plans
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
