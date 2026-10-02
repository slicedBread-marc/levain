#!/usr/bin/env bash
# lv-direct.sh — binding direction from the overseer onto one plan (LVI-033)
#
#   lv-direct.sh add <PLN-ID> --kind <kind> --text "<direction>"
#                [--supersedes D-n] [--from operator|coordinator:<name>]
#                [--project <name>]
#   lv-direct.sh list   <PLN-ID> [--all]
#   lv-direct.sh status <PLN-ID>
#   lv-direct.sh apply  <PLN-ID> <D-n> --sha <commit>
#
# WHY THIS EXISTS
#
# An overseer (the operator, or a coordinator session) had two channels into a
# project's pipeline: lv-dep-notify, which files a NEW bug, and a bug addendum.
# A /lv-spec worker on an existing plan reads neither as binding. So when plans
# collided, the only way to steer one was to remember to reject its gate by
# hand, with a note, and hope the next worker read the note.
#
# A client, 2026-09-30: PLN-026 bounced implement→spec, ran three review rounds
# of one amendment and parked spec-stuck. The operator resolved it by removing
# the Folder allow-list. PLN-028, which depends on PLN-026, sat at
# spec-approval built on that allow-list — the only guard on serving a child's
# photo — and nothing could tell its worker so. "We get into these stuck loops
# frequently, where we are defining requirements and plans begin to collide."
#
# A directive is that channel. It is written into
# plans/<plan>/directives.md, committed on develop, and every worker that
# reads the plan (lv-spec, its reviewer, lv-implement, lv-consistency,
# lv-verify, lv-test) loads the live ones FIRST. A directive outranks the
# worker's own reading of the plan — the standing a human's gate answer
# already has — and the worker quotes it in Design Decisions and marks it
# applied with the commit that carries it.
#
# A directive never APPROVES anything. A plan that needs spec-approval still
# needs it; a directive can only add a constraint, send a plan back, or stop
# dispatch.
#
# KINDS
#
#   constraint    A requirement the plan must meet. Any state. On a plan with
#                 an open spec-approval gate the question is withdrawn — it
#                 asks about a document that no longer covers the direction —
#                 and /lv-spec re-specs against the directive.
#   replan        Send the plan back to spec, with this text as the brief.
#                 Only on `draft` or `ready`: an open spec-approval gate is
#                 withdrawn, a `ready` plan returns to `draft`. On `active` or
#                 later it is REFUSED (exit 4) — code exists, and the rule is a
#                 new plan with Deps on this one, never a rewrite underneath a
#                 build.
#   hold          The dispatcher spawns nothing on the plan until released.
#   release-hold  Releases the live hold (supersedes it).
#
# WHO MAY WRITE ONE
#
# The operator, at a terminal in the project, or a coordinator through
# `--project`. Never a pipeline worker: a worker that could direct its own
# pipeline could launder its own reading into "binding input" for the next
# one. So under LV_UNATTENDED=1 this refuses (exit 6), and `--project` is
# refused unless the calling project declares `role: coordinator`.
#
# `--project <name>` resolves <name> from the coordinator's `coordinates:` and
# runs the TARGET's own lv-direct.sh through the target's own lv-exec.sh — the
# same routing lv-dep-notify uses — so the directive is written and committed
# by the project that owns the plan, recorded as `coordinator:<slug>`.
#
# COMMANDS
#
#   add     Write a directive, commit it (pathspec-scoped), then apply its
#           effect: the registry transition commits next, the gate withdraws
#           last (docs/guard-ordering.md). Prints DIRECTIVE_ID=D-n.
#   list    The live directives (not superseded), in a form to read. --all
#           includes superseded ones.
#   status  eval-friendly: DIRECTIVES_LIVE, DIRECTIVES_UNAPPLIED (live
#           constraint/replan without an applied SHA), DIRECTIVE_IDS,
#           DIRECTIVE_HOLD (the D-n of a live hold, or empty).
#   apply   Mark a directive applied, naming the commit that carries it into
#           the plan. Workers run this after their own commit. Commits itself.
#
# Exit codes:
#   0  done
#   1  usage, unknown plan, unknown directive
#   4  replan refused — the plan is built (active or later)
#   5  the target's develop checkout is not on develop — nothing written
#   6  refused — not an overseer (a pipeline worker, or --project from a
#      project that is not a coordinator, or an unrecognized --from)

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

cmd="${1:-}"
case "$cmd" in
  add|list|status|apply) shift ;;
  -h|--help|"") wf_usage "$0"; [ -n "$cmd" ]; exit $? ;;
  *) wf_bad_option "$cmd" ;;
esac

kind="" text="" supersedes="" from="" project="" all=false sha="" plan="" did=""
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)       kind="${2:?--kind requires a kind}"; shift 2 ;;
    --text)       text="${2?--text requires the direction}"; shift 2 ;;
    --supersedes) supersedes="${2:?--supersedes requires D-n}"; shift 2 ;;
    --from)       from="${2:?--from requires operator or coordinator:<name>}"; shift 2 ;;
    --project)    project="${2:?--project requires a name from coordinates:}"; shift 2 ;;
    --all)        all=true; shift ;;
    --sha)        sha="${2:?--sha requires a commit}"; shift 2 ;;
    -h|--help)    wf_usage "$0"; exit 0 ;;
    -*)           wf_bad_option "$1" ;;
    *)
      if [ -z "$plan" ]; then plan="$1"; elif [ -z "$did" ]; then did="$1"; else wf_bad_option "$1"; fi
      shift ;;
  esac
done

refuse() { echo "lv-direct: refused — $1" >&2; exit 6; }

# ── Routed from a coordinator ──────────────────────────────────────────────
if [ -n "$project" ]; then
  [ "$cmd" = "add" ] || [ "$cmd" = "list" ] || [ "$cmd" = "status" ] \
    || { echo "lv-direct: --project routes add, list and status only" >&2; exit 1; }
  [ "${LV_UNATTENDED:-0}" = "1" ] && refuse "a pipeline worker does not direct a pipeline (LV_UNATTENDED=1)"
  [ "$(wf_cfg role client)" = "coordinator" ] \
    || refuse "--project directs ANOTHER project's plan, which only a coordinator (role: coordinator) does. In this project, drop --project."
  slug=$(wf_cfg project_slug "$(basename "$(wf_develop_root)")")
  path=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    [ "${entry%%:*}" = "$project" ] && { path="${entry#*:}"; break; }
  done < <(wf_cfg_list coordinates)
  [ -n "$path" ] || { echo "lv-direct: no '$project' in this coordinator's coordinates:" >&2; exit 1; }
  [ -x "$path/scripts/lv-exec.sh" ] || { echo "lv-direct: $path has no scripts/lv-exec.sh — not running this harness" >&2; exit 1; }
  args=("$cmd" "$plan")
  [ -n "$kind" ] && args+=(--kind "$kind")
  [ "$cmd" = "add" ] && args+=(--text "$text")
  [ -n "$supersedes" ] && args+=(--supersedes "$supersedes")
  $all && args+=(--all)
  cd "$path" && LV_DIRECT_FROM="coordinator:$slug" exec scripts/lv-exec.sh lv-direct.sh "${args[@]}"
fi

[ "$(wf_cfg role client)" = "coordinator" ] && {
  echo "lv-direct: this is a coordinator — it has no plans. Name the project: --project <name>" >&2; exit 1; }

# ── The plan ───────────────────────────────────────────────────────────────
[ -n "$plan" ] || { wf_usage "$0" >&2; exit 1; }
id=$(printf '%s' "$plan" | grep -oE "^($LV_PLN_RE)-[0-9]+" || true)
[ -n "$id" ] || { echo "lv-direct: '$plan' is not a plan id — directives bind plans" >&2; exit 1; }
plan_dir=$(wf_plan_dir "$id") || { echo "lv-direct: no plan folder for $id" >&2; exit 1; }
root="$(wf_develop_root)"
rel_dir="${plan_dir#"$root"/}"
file="$plan_dir/directives.md"
state=$(wf_state_of "$id")

show_rows() {
  local rows="$1" d k st au dt sp tx
  [ -n "$rows" ] || { echo "$id: no directives"; return 0; }
  while IFS=$'\037' read -r d k st au dt sp tx; do
    printf '%s  %-12s %s — %s, %s%s\n' "$d" "$k" "$st" "$au" "${dt%%T*}" \
      "$([ "$sp" != "—" ] && [ -n "$sp" ] && printf ' (supersedes %s)' "$sp")"
    printf '    %s\n' "$tx"
  done <<< "$rows"
}

case "$cmd" in
  list)
    if $all; then show_rows "$(wf_directives_rows "$id")"; else show_rows "$(wf_directives_live "$id")"; fi
    exit 0 ;;
  status)
    live=$(wf_directives_live "$id")
    wf_emit DIRECTIVES_LIVE "$(printf '%s' "$live" | grep -c . || true)"
    wf_emit DIRECTIVES_UNAPPLIED "$(printf '%s\n' "$live" | awk -F'\037' '($2 == "constraint" || $2 == "replan") && $3 == "open"' | grep -c . || true)"
    wf_emit DIRECTIVE_IDS "$(printf '%s\n' "$live" | awk -F'\037' 'NF { printf "%s%s", sep, $1; sep = " " }')"
    wf_emit DIRECTIVE_HOLD "$(wf_plan_held "$id" || true)"
    exit 0 ;;
esac

# Both writers commit on develop's shared checkout, like every develop-side
# worker. A checkout on another branch is somebody else's, and the registry
# there is that branch's older copy.
branch=$(git -C "$root" branch --show-current 2>/dev/null || true)
if [ "$branch" != "develop" ]; then
  echo "lv-direct: $root is on '${branch:-detached HEAD}', not develop — nothing written. Try again once it is back on develop." >&2
  exit 5
fi

# set_status <D-n> <status> — rewrite one directive's Status line in place.
set_status() {
  local want="$1" st="$2" tmp
  tmp=$(mktemp)
  awk -v want="$want" -v st="$st" '
    /^## D-[0-9]+/ { cur = $2 }
    cur == want && /^>[ \t]*\*\*Status:\*\*/ { print "> **Status:** " st; next }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

if [ "$cmd" = "apply" ]; then
  [ -n "$did" ] && [ -n "$sha" ] || { echo "Usage: lv-direct.sh apply <PLN-ID> <D-n> --sha <commit>" >&2; exit 1; }
  row=$(wf_directives_rows "$id" | awk -F'\037' -v d="$did" '$1 == d')
  [ -n "$row" ] || { echo "lv-direct: $id has no directive $did" >&2; exit 1; }
  case "$(printf '%s' "$row" | cut -d$'\037' -f3)" in
    superseded*) echo "lv-direct: $did is superseded — apply the directive that replaced it" >&2; exit 1 ;;
  esac
  full=$(git -C "$root" rev-parse --verify --quiet "$sha^{commit}" 2>/dev/null) \
    || { echo "lv-direct: '$sha' is not a commit here" >&2; exit 1; }
  set_status "$did" "applied ${full:0:10} $(wf_now)"
  "$SELF_DIR/lv-commit.sh" "direct($id): $did applied in ${full:0:10}" --add "$rel_dir/directives.md" >/dev/null \
    || { echo "lv-direct: could not commit $rel_dir/directives.md" >&2; exit 1; }
  wf_event directive-applied "$id" "$did in ${full:0:10}"
  echo "$id: $did applied (${full:0:10})"
  exit 0
fi

# ── add ────────────────────────────────────────────────────────────────────
[ "${LV_UNATTENDED:-0}" = "1" ] && refuse "a pipeline worker does not direct its own pipeline (LV_UNATTENDED=1). Raise it with the operator, or open a needs-input gate."

author="${LV_DIRECT_FROM:-${from:-operator}}"
case "$author" in
  operator) ;;
  coordinator:?*) ;;
  *) refuse "'$author' is not an overseer — operator, or coordinator:<name> via --project" ;;
esac

case "$kind" in
  constraint|replan|hold|release-hold) ;;
  "") echo "lv-direct: --kind is required (constraint | replan | hold | release-hold)" >&2; exit 1 ;;
  *)  echo "lv-direct: unknown kind '$kind' (constraint | replan | hold | release-hold)" >&2; exit 1 ;;
esac
case "$kind" in
  constraint|replan) [ -n "${text// /}" ] || { echo "lv-direct: a $kind needs --text — the direction itself" >&2; exit 1; } ;;
esac

case "$state" in
  complete|abandoned)
    echo "lv-direct: $id is $state — nothing will read a directive. File a new plan with Deps $id." >&2
    exit 4 ;;
esac
if [ "$kind" = "replan" ]; then
  case "$state" in
    draft|ready) ;;
    *)
      echo "lv-direct: replan refused — $id is '$state', so code for it exists." >&2
      echo "  A built plan is not rewritten underneath its build. File a new plan with Deps $id" >&2
      echo "  (lv-dep-notify.sh --kind request from a coordinator, or /lv-bug here), or add a" >&2
      echo "  constraint directive if the current build must honour something." >&2
      exit 4 ;;
  esac
fi

live=$(wf_directives_live "$id")
if [ "$kind" = "release-hold" ]; then
  hold=$(wf_plan_held "$id" || true)
  [ -n "$hold" ] || { echo "lv-direct: $id is not held — nothing to release" >&2; exit 1; }
  supersedes="$hold"
  [ -n "${text// /}" ] || text="Released $hold."
fi
if [ "$kind" = "hold" ] && wf_plan_held "$id" >/dev/null; then
  echo "lv-direct: $id is already held ($(wf_plan_held "$id"))" >&2; exit 1
fi
if [ -n "$supersedes" ]; then
  printf '%s\n' "$live" | awk -F'\037' -v d="$supersedes" '$1 == d { f = 1 } END { exit !f }' \
    || { echo "lv-direct: $id has no live directive $supersedes to supersede" >&2; exit 1; }
fi

lockdir="$(wf_orch_dir)/directives.$id.lock"
for _ in 1 2 3 4 5 6 7 8 9 10; do mkdir "$lockdir" 2>/dev/null && break; sleep 1; done
[ -d "$lockdir" ] || { echo "lv-direct: $id's directives are locked by another writer — try again" >&2; exit 1; }
trap 'rmdir "$lockdir" 2>/dev/null' EXIT

n=$(wf_directives_rows "$id" | awk -F'\037' '{ sub(/^D-/, "", $1); if ($1 + 0 > m) m = $1 + 0 } END { print m + 0 }')
new="D-$((n + 1))"
now=$(wf_now)

if [ ! -f "$file" ]; then
  cat > "$file" <<EOF2
# Directives — $id

Binding direction from the overseer — the operator, or a coordinator. Written
by \`lv-direct.sh\` only; never edit by hand. Every worker that reads this plan
reads the live directives first: they outrank the worker's own reading of the
plan, and are quoted in Design Decisions and marked applied with the commit
that carries them. A directive never approves anything.
EOF2
fi
{
  printf '\n## %s — %s\n' "$new" "$kind"
  printf '> **Author:** %s\n' "$author"
  printf '> **Date:** %s\n' "$now"
  printf '> **Status:** open\n'
  printf '> **Supersedes:** %s\n\n' "${supersedes:-—}"
  printf '%s\n' "$text"
} >> "$file"
[ -n "$supersedes" ] && set_status "$supersedes" "superseded by $new"

short=$(printf '%s' "$text" | tr '\n' ' ' | cut -c1-60)
"$SELF_DIR/lv-commit.sh" "direct($id): $new $kind — $short" --add "$rel_dir/directives.md" >/dev/null \
  || { echo "lv-direct: could not commit $rel_dir/directives.md — the directive is written but not committed" >&2; exit 1; }
wf_event directive "$id" "$new $kind ($author): $short"
wf_emit DIRECTIVE_ID "$new"

# ── Effects: transition first, gate last ──────────────────────────────────
if [ "$kind" = "replan" ] && [ "$state" = "ready" ]; then
  if "$SELF_DIR/lv-registry-update.sh" "$id" ready draft --note "replan directive $new: $short" \
       --commit "direct($id): $new replan — ready → draft" >/dev/null; then
    echo "$id: ready → draft (replan directive $new)"
  else
    echo "lv-direct: $id could not be moved ready → draft — the directive stands; move it by hand" >&2
  fi
fi

case "$kind" in
  constraint|replan)
    gate_file=$(wf_gate_file "$id" || true)
    if [ -f "$gate_file" ]; then
      open_gate=$(wf_gate_field "$gate_file" GATE_NAME)
      if [ "$open_gate" = "spec-approval" ]; then
        "$SELF_DIR/lv-gate-close.sh" "$id" "withdrawn — $kind directive $new changes what is being approved: $short" \
          --only spec-approval --withdraw >/dev/null 2>&1 \
          && echo "$id: open spec-approval withdrawn — /lv-spec re-specs against $new"
      else
        echo "$id: '$open_gate' is open and left as is — it asks a different question. The next worker reads $new." >&2
      fi
    fi
    ;;
  hold)         echo "$id: held — the dispatcher spawns nothing on it until release-hold" ;;
  release-hold) echo "$id: released ($supersedes)" ;;
esac
exit 0
