#!/usr/bin/env bash
# lv-bug-group.sh — hold a batch of related bugs off the spec list until the
# overseer says the batch is ready, then send it to /lv-spec together (LVI-024)
#
#   lv-bug-group.sh open     <slug> "<why>"
#   lv-bug-group.sh add      <slug> <BUG-ID>... [--create "<why>"]
#   lv-bug-group.sh remove   <slug> <BUG-ID>...
#   lv-bug-group.sh seal     <slug> [--lead <BUG-ID>]
#   lv-bug-group.sh dissolve <slug> ["<why>"]
#   lv-bug-group.sh consume  <slug> <PLN-ID>
#   lv-bug-group.sh leave    <slug> <BUG-ID> --after <PLN-ID> "<why>"
#   lv-bug-group.sh list     [--all] [--stale]
#   lv-bug-group.sh show     <slug>
#   lv-bug-group.sh of       <BUG-ID>
#   … and --project <name> on any of them, from a coordinator.
#
# WHY THIS EXISTS
#
# One overseer conversation filed BUG-041..049 into a client inside a few
# hours, and later reports corrected earlier ones: BUG-046 reversed the premise
# of BUG-041 and BUG-043, and 047/048/049 amended 041/043/046. By the time the
# corrections landed, BUG-041 was already PLN-041, `active` on a feature
# branch, built against the superseded model. The operator stopped the whole
# daemon by hand to keep the rest from being specced one at a time, and the
# handoff — "run /lv-spec BUG-046, taking BUG-047 and BUG-048 with it" — was a
# human sequencing a group the harness could not represent.
#
# Nothing else covered it. `Blocked:` is per bug, has no release-all, and says
# "external blocker", not "still being written". A `hold` directive binds plans
# only. `--amends` links two bugs and nothing read the link.
#
# THE RECORD
#
# bugs/groups/<slug>.md on develop, tracked: Status (Open | Sealed | Dissolved
# | Consumed), Opened, Why, Lead, Sealed, Holds, and a `## Members` list. Each
# member carries `> **Group:** <slug>` in its own header, which is what
# lv-list-specable.sh reads:
#
#   Open      no member is offered; each says why on stderr.
#   Sealed    the lead is offered, carrying the members still open; the others
#             are not offered on their own while the lead is open or claimed.
#   Dissolved / Consumed   members are independent again.
#
# COMMANDS
#
#   open      Create the group, Status Open.
#   add       Put bugs in it (one commit). --create opens the group first if it
#             does not exist. A member already consumed into a plan in `draft`
#             or `ready` gets a `hold` directive on that plan (lv-direct.sh),
#             released at seal — this is what PLN-041 needed. A plan `active`
#             or later is REFUSED (exit 4): a built plan changes by a new plan
#             with Deps on it, never underneath its build.
#   remove    Take bugs out; a hold placed for them is released.
#   seal      Status Sealed, lead fixed, holds released. The default lead is
#             the lowest-numbered open member that amends no other member;
#             --lead overrides, and may name a member already in a plan still
#             in draft/ready (a spec run that beat the add, LVI-026): that
#             plan keeps a hold, `Lead plan` names it, and the open members
#             are offered together as amendments to it.
#   dissolve  Members fall back to independent; holds released; their Group
#             field is cleared.
#   consume   /lv-spec's exit: Status Consumed, naming the lead's plan, any
#             hold still placed released. Refused
#             (exit 2) while any member is still in bugs/open — the group's
#             done-condition is that every member has left it, or was left
#             for its own plan.
#   leave     /lv-spec's, for the lead's run: record that a member is
#             separate work for its own later plan with Deps on the lead's
#             (--after). It stays in bugs/open, it no longer holds `consume`
#             back, lv-bug-consume.sh refuses to fold or amend it into the
#             plan it was left after, and once the group is Consumed it is
#             offered on its own. Written as `- BUG-a after PLN-L — why`
#             under `## Left for their own plans`, the marker every reader
#             checks — never the prose in Design Decisions (a client's
#             LVI-005: the decision was prose, consume refused, the group
#             stayed Sealed, and the member was withheld as carried).
#   list      Groups not yet finished (--all: every group). --stale: only Open
#             groups older than bugs.groupStaleAfter hours (default 24).
#   show      One group, readable.
#   of        eval-friendly: GROUP_SLUG, GROUP_STATUS, GROUP_LEAD,
#             GROUP_MEMBERS, GROUP_OPEN_MEMBERS for the group a bug is in.
#
# WHO MAY WRITE ONE
#
# open, add, remove, seal and dissolve are the overseer's: the operator at a
# terminal here, or a coordinator through --project. Under LV_UNATTENDED=1 they
# refuse (exit 6) — a worker that could seal its own group could release its
# own hold. consume is a worker's, because /lv-spec is what finishes a group.
# leave is a worker's too, for the same reason. list, show and of read only.
#
# Exit codes:
#   0  done
#   1  usage, unknown group or bug
#   2  consume refused — members still open; leave refused — not an open,
#      non-lead member of a Sealed group, or --after names no plan
#   4  add refused — the member's plan is built (active or later)
#   5  the develop checkout is not on develop — nothing written
#   6  refused — not an overseer

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

# Options may sit on either side of the command — `--project proj seal x`
# reads as naturally as `seal x --project proj`.
[ $# -gt 0 ] || { wf_usage "$0"; exit 1; }
project="" lead="" create_why="" after="" all=false stale=false
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --project) project="${2:?--project requires a name from coordinates:}"; shift 2 ;;
    --lead)    lead="${2:?--lead requires a bug ID}"; shift 2 ;;
    --create)  create_why="${2?--create requires the why}"; shift 2 ;;
    --after)   after="${2:?--after requires the lead plan ID}"; shift 2 ;;
    --all)     all=true; shift ;;
    --stale)   stale=true; shift ;;
    -h|--help) wf_usage "$0"; exit 0 ;;
    -*)        wf_bad_option "$1" ;;
    *)         pos+=("$1"); shift ;;
  esac
done

cmd="${pos[0]:-}"
case "$cmd" in
  open|add|remove|seal|dissolve|consume|leave|list|show|of) pos=("${pos[@]:1}") ;;
  "") wf_usage "$0" >&2; exit 1 ;;
  *) wf_bad_option "$cmd" ;;
esac

refuse() { echo "lv-bug-group: refused — $1" >&2; exit 6; }
is_write() { case "$cmd" in open|add|remove|seal|dissolve) return 0 ;; esac; return 1; }

# ── Routed from a coordinator ──────────────────────────────────────────────
# Same routing as lv-direct.sh: the TARGET's own script, through the target's
# own lv-exec.sh, so the group is written and committed by the project that
# owns the bugs, recorded as coordinator:<slug>.
if [ -n "$project" ]; then
  is_write && [ "${LV_UNATTENDED:-0}" = "1" ] && refuse "a pipeline worker does not group its own intake (LV_UNATTENDED=1)"
  [ "$(wf_cfg role client)" = "coordinator" ] \
    || refuse "--project groups ANOTHER project's bugs, which only a coordinator (role: coordinator) does. In this project, drop --project."
  me=$(wf_cfg project_slug "$(basename "$(wf_develop_root)")")
  path=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "${entry%%:*}" = "$project" ] && { path="${entry#*:}"; break; }
  done < <(wf_cfg_list coordinates)
  [ -n "$path" ] || { echo "lv-bug-group: no '$project' in this coordinator's coordinates:" >&2; exit 1; }
  [ -x "$path/scripts/lv-exec.sh" ] || { echo "lv-bug-group: $path has no scripts/lv-exec.sh — not running this harness" >&2; exit 1; }
  args=("$cmd" "${pos[@]+"${pos[@]}"}")
  [ -n "$lead" ] && args+=(--lead "$lead")
  [ -n "$create_why" ] && args+=(--create "$create_why")
  [ -n "$after" ] && args+=(--after "$after")
  $all && args+=(--all)
  $stale && args+=(--stale)
  cd "$path" && LV_GROUP_FROM="coordinator:$me" exec scripts/lv-exec.sh lv-bug-group.sh "${args[@]}"
fi

[ "$(wf_cfg role client)" = "coordinator" ] && {
  echo "lv-bug-group: this is a coordinator — it has no bugs. Name the project: --project <name>" >&2; exit 1; }

root="$(wf_develop_root)"
cd "$root" || exit 1
mkdir_groups() { mkdir -p "$root/bugs/groups"; }

# ── Readers ────────────────────────────────────────────────────────────────

# open_members <slug> → members still in bugs/open, one per line.
open_members() {
  local m loc
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    loc=$(wf_bug_md "$m")
    [ "${loc%%$'\t'*}" = "open" ] && printf '%s\n' "$m"
  done < <(wf_group_members "$1")
}

join_csv() { paste -sd, - | sed 's/,/, /g'; }

epoch_of() {   # ISO-8601 Z → epoch seconds (BSD date, then GNU date)
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || echo 0
}

show_group() {
  local slug="$1" f m loc st
  f="$(wf_group_file "$slug")"
  printf '%s — %s\n' "$slug" "$(wf_group_field "$slug" Status)"
  printf '  why:     %s\n' "$(wf_group_field "$slug" Why)"
  printf '  opened:  %s\n' "$(wf_group_field "$slug" Opened)"
  [ -n "$(wf_group_field "$slug" Sealed)" ] && printf '  sealed:  %s\n' "$(wf_group_field "$slug" Sealed)"
  [ -n "$(wf_group_field "$slug" Lead)" ] && printf '  lead:    %s\n' "$(wf_group_field "$slug" Lead)"
  [ -n "$(wf_group_field "$slug" Holds)" ] && printf '  holds:   %s\n' "$(wf_group_field "$slug" Holds)"
  [ -n "$(wf_group_field "$slug" Consumed)" ] && printf '  consumed: %s\n' "$(wf_group_field "$slug" Consumed)"
  while IFS= read -r m; do
    [ -n "$m" ] || continue
    loc=$(wf_bug_md "$m"); st="${loc%%$'\t'*}"
    printf '  - %s  %s  %s\n' "$m" "${st:-missing}" "$(head -1 "${loc#*$'\t'}" 2>/dev/null | sed 's/^# //')"
  done < <(wf_group_members "$slug")
  [ -f "$f" ] || true
}

case "$cmd" in
  list)
    threshold=$(wf_cfg bugs.groupStaleAfter 24)
    now=$(date -u +%s)
    n=0
    for f in "$root"/bugs/groups/*.md; do
      [ -f "$f" ] || continue
      slug=$(basename "$f" .md)
      st=$(wf_group_field "$slug" Status)
      case "$st" in Open|Sealed) ;; *) $all || continue ;; esac
      opened=$(wf_group_field "$slug" Opened); opened_at="${opened%% *}"
      age=$(( now - $(epoch_of "$opened_at") ))
      if $stale; then
        [ "$st" = "Open" ] || continue
        [ "$age" -ge $(( threshold * 3600 )) ] || continue
      fi
      members=$(wf_group_members "$slug" | grep -c . || true)
      open_n=$(open_members "$slug" | grep -c . || true)
      printf '%s\t%s\t%s member(s), %s open\t%s\t%s\n' "$slug" "$st" "$members" "$open_n" "$(wf_human_age "$age") old" \
        "$( [ "$st" = "Open" ] && printf 'seal: lv-bug-group.sh seal %s' "$slug" || printf 'lead %s' "$(wf_group_field "$slug" Lead)")"
      n=$((n + 1))
    done
    [ "$n" -gt 0 ]; exit $? ;;
  show)
    slug="${pos[0]:-}"; [ -n "$slug" ] || { wf_usage "$0" >&2; exit 1; }
    [ -f "$(wf_group_file "$slug")" ] || { echo "lv-bug-group: no group '$slug'" >&2; exit 1; }
    show_group "$slug"; exit 0 ;;
  of)
    bug="${pos[0]:-}"; [ -n "$bug" ] || { wf_usage "$0" >&2; exit 1; }
    loc=$(wf_bug_md "$bug"); [ -n "$loc" ] || { echo "lv-bug-group: no bug $bug" >&2; exit 1; }
    slug=$(wf_bug_field "${loc#*$'\t'}" Group)
    wf_emit GROUP_SLUG "$slug"
    if [ -n "$slug" ]; then
      wf_emit GROUP_STATUS "$(wf_group_field "$slug" Status)"
      wf_emit GROUP_LEAD "$(wf_group_field "$slug" Lead)"
      wf_emit GROUP_MEMBERS "$(wf_group_members "$slug" | paste -sd' ' -)"
      wf_emit GROUP_OPEN_MEMBERS "$(open_members "$slug" | paste -sd' ' -)"
    else
      wf_emit GROUP_STATUS ""; wf_emit GROUP_LEAD ""; wf_emit GROUP_MEMBERS ""; wf_emit GROUP_OPEN_MEMBERS ""
    fi
    exit 0 ;;
esac

# ── Writers ────────────────────────────────────────────────────────────────
slug="${pos[0]:-}"
[ -n "$slug" ] || { wf_usage "$0" >&2; exit 1; }
[[ "$slug" =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "lv-bug-group: '$slug' is not a kebab-case slug" >&2; exit 1; }
file="$(wf_group_file "$slug")"
rel="bugs/groups/$slug.md"

if is_write; then
  [ "${LV_UNATTENDED:-0}" = "1" ] && refuse "a pipeline worker does not group its own intake (LV_UNATTENDED=1). Raise it with the operator, or open a needs-input gate."
fi
author="${LV_GROUP_FROM:-operator}"
case "$author" in operator|coordinator:?*) ;; *) refuse "'$author' is not an overseer" ;; esac

branch=$(git branch --show-current 2>/dev/null || true)
if [ "$branch" != "develop" ]; then
  echo "lv-bug-group: $root is on '${branch:-detached HEAD}', not develop — nothing written." >&2
  exit 5
fi

lockdir="$(wf_orch_dir)/bug-group.$slug.lock"
mkdir -p "$(dirname "$lockdir")" 2>/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do mkdir "$lockdir" 2>/dev/null && break; sleep 1; done
[ -d "$lockdir" ] || { echo "lv-bug-group: group '$slug' is locked by another writer — try again" >&2; exit 1; }
trap 'rmdir "$lockdir" 2>/dev/null' EXIT

# set_field <file> <Field> <value> — rewrite a header field, inserting it at
# the end of the header blockquote when absent. ENVIRON, not -v: the value is
# human-written and -v expands escapes.
set_field() {
  local f="$1" tmp
  tmp=$(mktemp)
  LV_F="$2" LV_V="$3" awk '
    BEGIN { k = ENVIRON["LV_F"]; v = ENVIRON["LV_V"]; pat = "\\*\\*" k ":\\*\\*" }
    {
      lines[NR] = $0
      if ($0 ~ /^[ \t]*##[ \t]/) body = 1
      if (!body && $0 ~ /^[ \t]*>/) last = NR
      if (!done && !body && $0 ~ pat) { lines[NR] = "> **" k ":** " v; done = 1 }
    }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (!done && i == last) print "> **" k ":** " v
      }
    }' "$f" > "$tmp" && mv "$tmp" "$f"
}

# clear_field <file> <Field> — drop a header field.
clear_field() {
  local tmp; tmp=$(mktemp)
  LV_F="$2" awk 'BEGIN { pat = "^[ \t]*>?[ \t]*\\*\\*" ENVIRON["LV_F"] ":\\*\\*" } $0 !~ pat' "$1" > "$tmp" && mv "$tmp" "$1"
}

commit() {   # commit <message> <path>...
  local msg="$1"; shift
  "$SELF_DIR/lv-commit.sh" "$msg" --add "$@" >/dev/null \
    || { echo "lv-bug-group: written but could not be committed — commit $* before another worker does" >&2; exit 1; }
}

require_group() {
  [ -f "$file" ] || { echo "lv-bug-group: no group '$slug' — lv-bug-group.sh open $slug \"<why>\"" >&2; exit 1; }
}

write_new_group() {   # write_new_group <why>
  mkdir_groups
  {
    printf '# Intake group — %s\n\n' "$slug"
    printf '> **Status:** Open\n'
    printf '> **Opened:** %s by %s\n' "$(wf_now)" "$author"
    printf '> **Why:** %s\n' "$1"
    printf '> **Lead:** —\n'
    printf '> **Sealed:** —\n'
    printf '> **Holds:** —\n\n'
    printf 'Written by `lv-bug-group.sh` only. While Open, no member is offered to\n'
    printf '/lv-spec; once Sealed, the lead is offered with the rest carried.\n\n'
    printf '## Members\n'
  } > "$file"
}

# release_holds <PLN-ID>... — release the hold this group placed on each plan.
# An empty list releases them all.
release_holds() {
  local holds want entry pid kept="" out="" why_released
  case "$cmd" in
    seal)     why_released="sealed, its members go to /lv-spec together" ;;
    dissolve) why_released="dissolved, its members are independent again" ;;
    consume)  why_released="consumed, every member is decided" ;;
    *)        why_released="the member was removed from it" ;;
  esac
  # consume is a worker's, and a worker may not release a hold. This one it
  # may: the overseer who sealed the group placed it "until the group is
  # consumed", and consume has just proved that condition — no member is left
  # in bugs/open. So it is released in the sealer's name, not the worker's.
  local rel_author="$author" rel_unattended="${LV_UNATTENDED:-0}"
  if [ "$cmd" = consume ]; then
    rel_author=$(wf_group_field "$slug" Sealed | sed -nE 's/.* by ([^ ]+).*/\1/p')
    rel_unattended=0
  fi
  holds=$(wf_group_field "$slug" Holds)
  [ -n "$holds" ] || return 0
  want=" $* "
  for entry in ${holds//,/ }; do
    pid="${entry%%:*}"
    if [ $# -eq 0 ] || [[ "$want" == *" $pid "* ]]; then
      if wf_plan_held "$pid" >/dev/null 2>&1; then
        LV_UNATTENDED="$rel_unattended" LV_DIRECT_FROM="$rel_author" "$SELF_DIR/lv-direct.sh" add "$pid" --kind release-hold \
          --text "Released — intake group $slug: $why_released." >/dev/null 2>&1 \
          && out+="$pid released; " \
          || echo "lv-bug-group: could not release the hold on $pid — lv-direct.sh add $pid --kind release-hold" >&2
      fi
    else
      kept="${kept:+$kept, }$entry"
    fi
  done
  set_field "$file" Holds "${kept:-—}"
  [ -n "$out" ] && echo "$out" >&2
  return 0
}

case "$cmd" in
  open)
    why="${pos[1]:-}"
    [ -n "${why// /}" ] || { echo "lv-bug-group: open needs the why — what the batch is and why it waits" >&2; exit 1; }
    [ -f "$file" ] && { echo "lv-bug-group: group '$slug' already exists ($(wf_group_field "$slug" Status))" >&2; exit 1; }
    write_new_group "$why"
    commit "bug-group($slug): opened — $why" "$rel"
    wf_event bug-group "$slug" "opened by $author: $why"
    echo "group $slug opened — add members with: lv-bug-group.sh add $slug BUG-NNN..."
    exit 0 ;;

  add)
    [ "${#pos[@]}" -ge 2 ] || { echo "Usage: lv-bug-group.sh add <slug> <BUG-ID>... [--create \"<why>\"]" >&2; exit 1; }
    created=false
    if [ ! -f "$file" ]; then
      [ -n "$create_why" ] || { echo "lv-bug-group: no group '$slug' — open it first, or pass --create \"<why>\"" >&2; exit 1; }
      write_new_group "$create_why"; created=true
    fi
    st=$(wf_group_field "$slug" Status)
    [ "$st" = "Open" ] || { echo "lv-bug-group: group '$slug' is $st — only an Open group takes members" >&2; exit 1; }

    # Validate every bug before writing anything: one bad ID must not leave
    # half a batch grouped.
    paths=("$rel") added=() plans=()
    for bug in "${pos[@]:1}"; do
      loc=$(wf_bug_md "$bug")
      [ -n "$loc" ] || { echo "lv-bug-group: no bug $bug in bugs/open or bugs/triaged" >&2; exit 1; }
      stage="${loc%%$'\t'*}"; md="${loc#*$'\t'}"
      [ "$stage" = "closed" ] && { echo "lv-bug-group: $bug is closed — nothing to hold" >&2; exit 1; }
      other=$(wf_bug_field "$md" Group)
      if [ -n "$other" ] && [ "$other" != "$slug" ]; then
        case "$(wf_group_field "$other" Status)" in
          Open|Sealed) echo "lv-bug-group: $bug is already in group '$other' — remove it there first" >&2; exit 1 ;;
        esac
      fi
      pid=""
      if [ "$stage" = "open" ]; then
        # A spec run dispatched before this add can be mid-draft (LVI-026). It
        # stands down at lv-plan-id.sh's re-check before writing, or at
        # lv-bug-consume.sh if it drafted first — and a plan it already
        # registered is held below, so the daemon does not respec it alone.
        if wf_claim_held "$bug"; then
          echo "$bug: a spec run holds its claim (PID ${LV_CLAIM_HOLDER_PID:-?}, $((LV_CLAIM_AGE / 60))m) — it stands down before drafting (lv-plan-id.sh exit 4) or at triage (lv-bug-consume.sh exit 3)" >&2
        fi
        pid=$(eval "$("$SELF_DIR/lv-plan-id.sh" "$bug" --peek 2>/dev/null)" 2>/dev/null
              [ "${PLAN_ID_RESUME:-}" = true ] && printf '%s' "${PLAN_ID:-}") || true
        case "$(wf_state_of "${pid:-x}" 2>/dev/null)" in draft|ready) ;; *) pid="" ;; esac
      elif [ "$stage" = "triaged" ]; then
        pf=$(wf_bug_field "$md" Plan); pid=$(printf '%s' "$pf" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
        if [ -n "$pid" ]; then
          pst=$(wf_state_of "$pid")
          case "$pst" in
            draft|ready) ;;
            —|"") pid="" ;;
            *)
              echo "lv-bug-group: refused — $bug is already $pid, which is '$pst', so code for it exists." >&2
              echo "  A built plan is not rewritten underneath its build. Leave $bug out of the group; the" >&2
              echo "  member that changes its premise becomes a new plan with Deps $pid (or abandon $pid)." >&2
              exit 4 ;;
          esac
        fi
      fi
      added+=("$bug"); plans+=("${pid:--}")
    done

    holds=$(wf_group_field "$slug" Holds)
    for i in "${!added[@]}"; do
      bug="${added[$i]}"; pid="${plans[$i]}"
      loc=$(wf_bug_md "$bug"); md="${loc#*$'\t'}"
      set_field "$md" Group "$slug"
      paths+=("${md#"$root"/}")
      wf_group_members "$slug" | grep -qx "$bug" || printf -- '- %s\n' "$bug" >> "$file"
      if [ "$pid" != "-" ]; then
        if wf_plan_held "$pid" >/dev/null 2>&1; then
          echo "$bug: $pid ($(wf_state_of "$pid")) is already held — left as is" >&2
        elif LV_DIRECT_FROM="$author" "$SELF_DIR/lv-direct.sh" add "$pid" --kind hold \
               --text "Held — $bug is in intake group $slug, still being written. Released when the group is sealed." >/dev/null 2>&1; then
          d=$(wf_plan_held "$pid" || true)
          holds="$( [ -n "$holds" ] && printf '%s, ' "$holds")$pid:$d"
          echo "$bug: $pid ($(wf_state_of "$pid")) held until the group is sealed" >&2
        else
          echo "lv-bug-group: could not hold $pid — hold it by hand: lv-direct.sh add $pid --kind hold" >&2
        fi
      fi
    done
    [ -n "$holds" ] && set_field "$file" Holds "$holds"
    commit "bug-group($slug): $($created && printf 'opened; ')added ${added[*]}" "${paths[@]}"
    wf_event bug-group "$slug" "added ${added[*]} ($author)"
    echo "group $slug: $(wf_group_members "$slug" | grep -c .) member(s), Open — seal with: lv-bug-group.sh seal $slug"
    exit 0 ;;

  remove)
    require_group
    [ "${#pos[@]}" -ge 2 ] || { echo "Usage: lv-bug-group.sh remove <slug> <BUG-ID>..." >&2; exit 1; }
    paths=("$rel") rel_plans=()
    for bug in "${pos[@]:1}"; do
      wf_group_members "$slug" | grep -qx "$bug" || { echo "lv-bug-group: $bug is not in group '$slug'" >&2; exit 1; }
      tmp=$(mktemp); awk -v b="- $bug" '$0 != b' "$file" > "$tmp" && mv "$tmp" "$file"
      loc=$(wf_bug_md "$bug")
      if [ -n "$loc" ]; then
        md="${loc#*$'\t'}"; clear_field "$md" Group; paths+=("${md#"$root"/}")
        pid=$(wf_bug_field "$md" Plan | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
        [ -n "$pid" ] && rel_plans+=("$pid")
      fi
    done
    [ "${#rel_plans[@]}" -gt 0 ] && release_holds "${rel_plans[@]}"
    commit "bug-group($slug): removed ${pos[*]:1}" "${paths[@]}"
    echo "group $slug: removed ${pos[*]:1}"
    exit 0 ;;

  seal)
    require_group
    st=$(wf_group_field "$slug" Status)
    [ "$st" = "Open" ] || { echo "lv-bug-group: group '$slug' is $st, not Open — nothing to seal" >&2; exit 1; }
    opens=$(open_members "$slug")
    lead_plan=""
    if [ -n "$lead" ] && ! printf '%s\n' "$opens" | grep -qx "$lead"; then
      # A member the operator means as the lead may already be a plan: specced
      # by a run dispatched before it was grouped (LVI-026). While that plan is
      # still in spec (draft or ready) it can lead — the rest are carried to it
      # as amendments, and its hold stays until the group is consumed. Built
      # (active or later), it cannot: a built plan changes by a new plan.
      wf_group_members "$slug" | grep -qx "$lead" \
        || { echo "lv-bug-group: --lead $lead is not a member of '$slug'" >&2; exit 1; }
      loc=$(wf_bug_md "$lead")
      [ "${loc%%$'\t'*}" = "triaged" ] \
        && lead_plan=$(wf_bug_field "${loc#*$'\t'}" Plan | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
      lp_state=$( [ -n "$lead_plan" ] && wf_state_of "$lead_plan" )
      case "$lp_state" in
        draft|ready) ;;
        *) echo "lv-bug-group: --lead $lead is not a member still in bugs/open, nor in a plan still in spec${lead_plan:+ ($lead_plan is '$lp_state')} (open: $(printf '%s\n' "$opens" | join_csv))" >&2
           exit 1 ;;
      esac
    elif [ -z "$lead" ] && [ -n "$opens" ]; then
      # The lowest-numbered open member that amends no other member: the
      # premise the rest are written against. A ring of amendments falls back
      # to the lowest number.
      members=" $(wf_group_members "$slug" | paste -sd' ' -) "
      while IFS= read -r m; do
        loc=$(wf_bug_md "$m"); amends_member=false
        while IFS= read -r t; do
          [ -n "$t" ] && [[ "$members" == *" $t "* ]] && amends_member=true
        done < <(wf_bug_amends "${loc#*$'\t'}")
        $amends_member || { lead="$m"; break; }
      done < <(printf '%s\n' "$opens" | sort -t- -k2,2n)
      [ -n "$lead" ] || lead=$(printf '%s\n' "$opens" | sort -t- -k2,2n | head -1)
    fi
    set_field "$file" Status Sealed
    set_field "$file" Lead "${lead:-—}"
    set_field "$file" Sealed "$(wf_now) by $author"
    if [ -n "$lead_plan" ]; then
      set_field "$file" "Lead plan" "$lead_plan — the members still open amend it"
      others=()
      for entry in $(wf_group_field "$slug" Holds | tr ',' ' '); do
        [ "${entry%%:*}" = "$lead_plan" ] || others+=("${entry%%:*}")
      done
      [ "${#others[@]}" -gt 0 ] && release_holds "${others[@]}"
      # The lead's plan must not reach a builder before the amendments do.
      if ! wf_plan_held "$lead_plan" >/dev/null 2>&1; then
        if LV_DIRECT_FROM="$author" "$SELF_DIR/lv-direct.sh" add "$lead_plan" --kind hold \
             --text "Held — it leads intake group $slug, whose open members amend it. Released when the group is consumed." >/dev/null 2>&1; then
          d=$(wf_plan_held "$lead_plan" || true)
          h=$(wf_group_field "$slug" Holds)
          set_field "$file" Holds "${h:+$h, }$lead_plan:$d"
        else
          echo "lv-bug-group: could not hold $lead_plan — hold it by hand: lv-direct.sh add $lead_plan --kind hold" >&2
        fi
      fi
    else
      release_holds
    fi
    commit "bug-group($slug): sealed${lead:+, lead $lead}" "$rel"
    wf_event bug-group "$slug" "sealed by $author${lead:+, lead $lead}"
    if [ -n "$lead_plan" ]; then
      echo "group $slug sealed — lead $lead is $lead_plan ($lp_state, held); /lv-spec amends it with $(printf '%s\n' "$opens" | join_csv)"
    elif [ -n "$lead" ]; then
      carried=$(printf '%s\n' "$opens" | grep -vx "$lead" | join_csv)
      echo "group $slug sealed — /lv-spec takes $lead${carried:+, carrying $carried}"
    else
      echo "group $slug sealed — no member is still open; nothing for /lv-spec"
    fi
    exit 0 ;;

  dissolve)
    require_group
    st=$(wf_group_field "$slug" Status)
    case "$st" in Open|Sealed) ;; *) echo "lv-bug-group: group '$slug' is already $st" >&2; exit 1 ;; esac
    paths=("$rel")
    while IFS= read -r m; do
      loc=$(wf_bug_md "$m"); [ -n "$loc" ] || continue
      md="${loc#*$'\t'}"; clear_field "$md" Group; paths+=("${md#"$root"/}")
    done < <(wf_group_members "$slug")
    set_field "$file" Status Dissolved
    set_field "$file" Dissolved "$(wf_now) by $author${pos[1]:+ — ${pos[1]}}"
    release_holds
    commit "bug-group($slug): dissolved${pos[1]:+ — ${pos[1]}}" "${paths[@]}"
    wf_event bug-group "$slug" "dissolved by $author"
    echo "group $slug dissolved — its members are independent again"
    exit 0 ;;

  consume)
    require_group
    plan="${pos[1]:-}"
    [ -n "$plan" ] || { echo "Usage: lv-bug-group.sh consume <slug> <PLN-ID>" >&2; exit 1; }
    st=$(wf_group_field "$slug" Status)
    [ "$st" = "Sealed" ] || { echo "lv-bug-group: group '$slug' is $st — only a Sealed group is consumed" >&2; exit 1; }
    left=$(wf_group_left "$slug" | cut -f1)
    still=$(open_members "$slug" | while IFS= read -r m; do
              printf '%s\n' "$left" | grep -qxF "$m" || printf '%s\n' "$m"; done)
    if [ -n "$still" ]; then
      echo "lv-bug-group: refused — still in bugs/open: $(printf '%s\n' "$still" | join_csv)." >&2
      echo "  Every member leaves bugs/open in the pass that consumes the group: folded into the lead's" >&2
      echo "  plan (lv-bug-consume.sh --folded), its own plan with Deps, an amendment (--amends), or" >&2
      echo "  closed as superseded (lv-bug-close.sh) — each with its reason in Design Decisions." >&2
      echo "  A member left for its own plan is recorded first: lv-bug-group.sh leave $slug <BUG-ID> --after $plan \"<why>\"." >&2
      exit 2
    fi
    set_field "$file" Status Consumed
    set_field "$file" Consumed "$(wf_now) by $plan"
    release_holds
    commit "bug-group($slug): consumed by $plan" "$rel"
    wf_event bug-group "$slug" "consumed by $plan"
    echo "group $slug consumed by $plan"
    [ -n "$left" ] && echo "  left for their own plans, offered on their own now: $(printf '%s\n' "$left" | join_csv)"
    exit 0 ;;

  leave)
    require_group
    bug="${pos[1]:-}"; why="${pos[2]:-}"
    if [ -z "$bug" ] || [ -z "$after" ] || [ -z "$why" ]; then
      echo "Usage: lv-bug-group.sh leave <slug> <BUG-ID> --after <PLN-ID> \"<why>\"" >&2; exit 1
    fi
    st=$(wf_group_field "$slug" Status)
    [ "$st" = "Sealed" ] || { echo "lv-bug-group: refused — group '$slug' is $st; only a Sealed group's member is left for its own plan" >&2; exit 2; }
    wf_group_members "$slug" | grep -qxF "$bug" || { echo "lv-bug-group: refused — $bug is not a member of '$slug'" >&2; exit 2; }
    [ "$bug" != "$(wf_group_field "$slug" Lead)" ] || { echo "lv-bug-group: refused — $bug is the lead; the lead becomes the plan, it is not left" >&2; exit 2; }
    loc=$(wf_bug_md "$bug")
    [ "${loc%%$'\t'*}" = "open" ] || { echo "lv-bug-group: refused — $bug is not in bugs/open (${loc%%$'\t'*}); it has already left" >&2; exit 2; }
    after_id=$(printf '%s' "$after" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
    if [ -z "$after_id" ] || { [ -z "$(wf_registry_field "$after_id" state)" ] && ! compgen -G "$root/plans/$after_id-*/plan.md" >/dev/null; }; then
      echo "lv-bug-group: refused — --after $after names no plan here (no REGISTRY row, no plans/$after_id-*/plan.md)" >&2; exit 2
    fi
    if wf_group_left "$slug" | cut -f1 | grep -qxF "$bug"; then
      echo "$bug already left for its own plan in $slug — nothing to do"; exit 0
    fi
    grep -q '^## Left for their own plans' "$file" || printf '\n## Left for their own plans\n' >> "$file"
    tmp=$(mktemp)
    # The line goes at the end of the Left section (ENVIRON, not -v: the why
    # is human-written and -v expands escapes).
    LV_L="- $bug after $after_id — $why" awk '
      BEGIN { line = ENVIRON["LV_L"] }
      /^## Left for their own plans/ { inl = 1; print; next }
      inl && /^## / { print line; inl = 0; done = 1 }
      { print }
      END { if (inl && !done) print line }' "$file" > "$tmp" && mv "$tmp" "$file"
    commit "bug-group($slug): $bug left for its own plan after $after_id" "$rel"
    wf_event bug-group "$slug" "$bug left for its own plan after $after_id"
    echo "$bug left for its own plan after $after_id — it stays in bugs/open and no longer holds '$slug' open"
    exit 0 ;;
esac
