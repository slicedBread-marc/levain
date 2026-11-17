#!/usr/bin/env bash
# lv-list-blocked.sh [--count]
#
# Lists the bugs and briefs held off /lv-spec by a `> **Blocked:**` header
# field (lv-brief-block.sh), with the recorded reason and how the block lifts.
#
# WHY THIS EXISTS
#
# A Blocked: field is not a gate. lv-list-specable.sh withholds the artifact
# and says so only on its own stderr, which no human reads — the daemon reads
# it. /lv-attend showed plan gates and nothing else, so on a client with
# BUG-096, BUG-127 and BUG-132 all withheld as Blocked it said nothing was
# waiting, and the operator could not see why the daemon was not picking them
# up (a client's LVI-054). One of the three had been clearable for 33 days
# (LVI-055).
#
# Output, one tab-separated line per blocked artifact:
#
#   <id>\t<where>\t<reason>\t<clears>
#
#   where    bugs/open | bugs/triaged | briefs
#   reason   the field as recorded, as wf_brief_blocked reads it — including
#            its `[not re-checked: …]` note when a cross-repo blocker cannot
#            be read from here
#   clears   auto:<ARTIFACT> in <project>   lifts by itself once it closes there
#            auto:<PLN-ID>                  lifts by itself once it is complete here
#            hand                           only `lv-brief-block.sh <id> --clear`
#                                           lifts it
#
# A field that has already lifted by itself (its blocker landed) is not
# listed: lv-list-specable.sh offers that artifact again, so it is not held.
#
#   --count   print just the number (still exit 1 when zero)
#
# Read-only. Exit 0 if anything is blocked, 1 if nothing is.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

mode="list"
case "${1:-}" in
  "")        ;;
  --count)   mode="count" ;;
  -h|--help) wf_usage "$0"; exit 0 ;;
  *)         wf_bad_option "$1" ;;
esac

cd "$(wf_develop_root)" || exit 1

# clears <reason> → how the block lifts, by the same rules wf_brief_blocked
# applies when it decides whether the field still holds.
clears() {
  local field="$1" art proj
  if [[ "$field" =~ ^([A-Z]+-[0-9]+)\ \(in\ ([A-Za-z0-9._/-]+)\) ]]; then
    art="${BASH_REMATCH[1]}"; proj="${BASH_REMATCH[2]}"
    case "$field" in
      *"[not re-checked: "*) printf 'hand' ;;
      *) printf 'auto:%s in %s' "$art" "$proj" ;;
    esac
    return
  fi
  if [[ "$field" =~ ^(($LV_PLN_RE)-[0-9]+)([[:space:]]|$) ]]; then
    printf 'auto:%s' "${BASH_REMATCH[1]}"; return
  fi
  printf 'hand'
}

lines=""
emit() {
  local id="$1" where="$2" md="$3" why
  why=$(wf_brief_blocked "$md" 2>/dev/null) || return 0
  # A tab inside the reason would shift every field after it.
  why="${why//$'\t'/ }"
  lines+="$id"$'\t'"$where"$'\t'"$why"$'\t'"$(clears "$why")"$'\n'
}

for where in open triaged; do
  for md in bugs/"$where"/*/bug.md bugs/"$where"/*.md; do
    [ -f "$md" ] || continue
    id=$(wf_bug_id "$md" 2>/dev/null); [ -n "$id" ] || continue
    emit "$id" "bugs/$where" "$md"
  done
done

for md in plans/briefs/*.md; do
  [ -f "$md" ] || continue
  id=$(basename "$md" | grep -oE "^($LV_BRF_RE)-[0-9]+" || true)
  [ -n "$id" ] || continue
  emit "$id" "briefs" "$md"
done

n=$(printf '%s' "$lines" | grep -c . || true)
if [ "$mode" = "count" ]; then
  echo "$n"
  [ "$n" -gt 0 ]; exit $?
fi
[ "$n" -gt 0 ] || exit 1
printf '%s' "$lines"
