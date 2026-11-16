#!/usr/bin/env bash
# lv-list-intake.sh [--count] [--fields]
#
# Lists FILED INTAKE — every bug in bugs/open/, the work waiting to be specced
# into a plan, in the order /lv-spec will reach it (the coordinator's LVI-050).
#
# WHY THIS EXISTS
#
# Every pipeline row on the board is a plan state, and a bug has no registry
# row until it is specced. A coordinator filed eight bugs into a client as one
# sealed intake group; the operator could not find any of them on the rack or
# the tray while the client's daemon was working through them, and the tray's
# RUNNING line named the spec in progress only as a bare number.
#
# THE ORDER
#
# bugs/open/ in folder order, which is the order lv-list-specable.sh offers
# them. A live intake group (Open or Sealed, bugs/groups/<slug>.md) is listed
# where its first open member falls, lead first, then the rest of its open
# members. Dissolved and consumed groups no longer bind their members, so those
# bugs list on their own.
#
# Output, one tab-separated line per open bug:
#
#   <id>\t<slug>\t<group>\t<role>\t<held>\t<blocked>
#
# An empty field is `-`, never blank: a tab is IFS whitespace, and `read`
# collapses a run of them, shifting every field after the blank one.
#
#   group    the live group's slug, or -
#   role     lead          the lead of a sealed group; it carries the rest
#            carried       carried with the lead (open, or held by a spec run)
#            amends:<PLN>  an amendment to the group's lead plan, still in spec
#            waiting       the group is still Open: nobody is offered yet
#            -             offered on its own
#   held     worker        a daemon worker's pidfile is live on its number
#            claim         a session's live claim holds it (lv-claim.sh)
#            -             nobody holds it
#   blocked  `blocked` when its Blocked: field holds it, else -
#
#   --count    print just the number of open bugs (still exit 1 when zero)
#   --fields   one line, `intake=<n>\tintake_group=<slug>\tintake_groups=<n>`:
#              the live group with the most open members (ties: the first
#              listed) and how many live groups have any — what lv-tray.sh
#              --fields passes to the rack
#
# Read-only. Exit 0 if any bug is open, 1 if none.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

mode="list"
case "${1:-}" in
  "")        ;;
  --count)   mode="count" ;;
  --fields)  mode="fields" ;;
  -h|--help) wf_usage "$0"; exit 0 ;;
  *)         wf_bad_option "$1" ;;
esac

ROOT="$(wf_develop_root)"
ORCH="$(wf_orch_dir)"

# Live worker numbers, by VALUE: a pidfile carries whatever digits the
# spawning id had, so `127` and `0127` are the same work.
workers=" "
for pf in "$ORCH/logs"/*.pid; do
  [ -f "$pf" ] || continue
  pid=$(cat "$pf" 2>/dev/null || echo "")
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || continue
  n=$(basename "$pf" .pid); n="${n%-*}"
  case "$n" in ''|*[!0-9]*) continue ;; esac
  workers="$workers$((10#$n)) "
done

# One pass over bugs/open: id, slug, live group.
ids=(); slugs=(); groups=(); mds=()
for bug_md in "$ROOT"/bugs/open/*/bug.md; do
  [ -f "$bug_md" ] || continue
  id=$(wf_bug_id "$bug_md" 2>/dev/null); [ -n "$id" ] || continue
  dir=$(basename "$(dirname "$bug_md")")
  slug="${dir#"$id"}"; slug="${slug#-}"
  g=$(wf_bug_field "$bug_md" Group)
  if [ -n "$g" ]; then
    case "$(wf_group_field "$g" Status)" in Open|Sealed) ;; *) g="" ;; esac
  fi
  ids+=("$id"); slugs+=("${slug:--}"); groups+=("$g"); mds+=("$bug_md")
done

n_open=${#ids[@]}

if [ "$mode" = "count" ]; then
  echo "$n_open"
  [ "$n_open" -gt 0 ]; exit $?
fi
# Nothing open: stop before any "${ids[@]}" — bash 3.2 calls an empty array
# under `set -u` unbound.
if [ "$n_open" -eq 0 ]; then
  [ "$mode" = "fields" ] && printf 'intake=0\tintake_group=\tintake_groups=0\n'
  exit 1
fi

# held <id> → worker | claim | empty
held() {
  local num; num=$(printf '%s' "$1" | grep -oE '[0-9]+$')
  if [ -n "$num" ] && [[ "$workers" == *" $((10#$num)) "* ]]; then printf 'worker'; return; fi
  wf_claim_held "$1" 2>/dev/null && printf 'claim'
  return 0
}

# role <index> → the bug's place in its group, by the rule lv-list-specable.sh
# offers it (wf_group_withholds), so the list says what dispatch will do.
role() {
  local i="$1" g="${groups[$1]}" why lead lplan
  [ -n "$g" ] || return 0
  case "$(wf_group_field "$g" Status)" in
    Open) printf 'waiting'; return ;;
  esac
  lead=$(wf_group_field "$g" Lead)
  if [ "$lead" = "${ids[$i]}" ]; then printf 'lead'; return; fi
  why=$(wf_group_withholds "${ids[$i]}" 2>/dev/null) || return 0
  case "$why" in
    "an amendment to "*)
      lplan=$(printf '%s' "$why" | grep -oE "($LV_PLN_RE)-[0-9]+" | head -1)
      printf 'amends:%s' "$lplan" ;;
    "carried with "*) printf 'carried' ;;
  esac
}

# Rank within a group: the lead first, then by position.
emit_bug() {
  local i="$1" b="-" r h
  wf_brief_blocked "${mds[$i]}" >/dev/null 2>&1 && b="blocked"
  r=$(role "$i"); h=$(held "${ids[$i]}")
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${ids[$i]}" "${slugs[$i]}" "${groups[$i]:--}" \
    "${r:--}" "${h:--}" "$b"
}

# Each live group's open members, in order, lead first; a group is emitted
# once, where its first open member falls.
done_groups=" "
out_lines=""
for i in "${!ids[@]}"; do
  g="${groups[$i]}"
  if [ -z "$g" ]; then
    out_lines+="$(emit_bug "$i")"$'\n'; continue
  fi
  [[ "$done_groups" == *" $g "* ]] && continue
  done_groups+="$g "
  lead=$(wf_group_field "$g" Lead)
  for j in "${!ids[@]}"; do
    [ "${groups[$j]}" = "$g" ] && [ "${ids[$j]}" = "$lead" ] && out_lines+="$(emit_bug "$j")"$'\n'
  done
  for j in "${!ids[@]}"; do
    [ "${groups[$j]}" = "$g" ] && [ "${ids[$j]}" != "$lead" ] && out_lines+="$(emit_bug "$j")"$'\n'
  done
done

if [ "$mode" = "fields" ]; then
  # The group with the most open members names the cell; the first listed wins
  # a tie, which is the one dispatch reaches first.
  top="" top_n=0 n_groups=0
  for g in $(printf '%s' "$out_lines" | awk -F'\t' '$3 != "-" && !seen[$3]++ { print $3 }'); do
    n_groups=$((n_groups + 1))
    c=$(printf '%s' "$out_lines" | awk -F'\t' -v g="$g" '$3 == g' | grep -c .)
    [ "$c" -gt "$top_n" ] && { top="$g"; top_n="$c"; }
  done
  printf 'intake=%s\tintake_group=%s\tintake_groups=%s\n' "$n_open" "$top" "$n_groups"
  [ "$n_open" -gt 0 ]; exit $?
fi

printf '%s' "$out_lines"
[ "$n_open" -gt 0 ]
