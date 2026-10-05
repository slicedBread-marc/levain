#!/usr/bin/env bash
# lv-dep-notify.sh "<title>" [options]
#
# Announces a change in THIS project to the projects that depend on it — the
# mirror image of lv-dep-bug.sh. Use this when a change here (a contract
# change, a breaking API shift, a migration a dependent needs to run) affects
# code this project does not own. For a defect or capability ask against a
# DEPENDENCY, use lv-dep-bug.sh instead — this script only ever writes
# outward, never asks for anything back.
#
# Dependents are local checkouts of this same harness, declared in THIS
# project's levain.yml:
#
#   dependents:
#     - "client-e:/path/to/client-e"
#     - "client-f:/path/to/client-f"
#
# One name, one absolute path, joined by the first ':' — same shape as
# `dependencies:`, just declared on the other side of the relationship. A
# project only appears here if a human put it here: there is no reverse scan
# of who declared this project as a dependency, so `dependents:` can drift
# from what other projects actually declare. That drift is cheap and visible
# (a stale path here just fails loudly) versus the alternative of a changelog
# nobody is on the hook to read. See docs/cross-project-reports.md.
#
# HOW IT WORKS
#
# For each target dependent, this runs THAT project's own scripts/lv-exec.sh
# lv-bug-new.sh in THAT project's own checkout — same mechanism lv-dep-bug.sh
# uses, just reversed. The notice is allocated through the dependent's own
# counter and lands in the dependent's own bugs/open/, exactly where its own
# /lv-spec already looks. There is no second inbox, no changelog to poll, no
# new triage path for either side to learn.
#
# It NEVER switches a dependent's branch. A dependent whose shared checkout
# is already on `develop` — its permanent home, docs/release-worktrees.md —
# gets the notice filed normally. Any other branch (a human's feature/* work
# included) is skipped, not displaced: see lv-dep-bug.sh's header for the
# full reasoning, which applies here unchanged.
#
# This is a BROADCAST by default — every declared dependent gets the same
# notice, because the whole point is keeping every consumer in sync, not
# picking one. One dependent parked off develop does not block the others:
# each is attempted independently and the per-dependent result is reported.
# Restrict to a single dependent with --to when a change only affects one.
#
# It commits in each dependent but does NOT push — same as lv-dep-bug.sh.
# Pushing another project's branch is that project's call.
#
#   --to <name>             optional — restrict to one entry in dependents:
#                            (default: every declared dependent)
#   --kind notice|request|bug   default: notice. A COORDINATOR (see below)
#                            files `request` — it is asking for work, not
#                            announcing a change it already made.
#   --severity Critical|High|Medium|Low   default: Medium — how urgently a
#                            dependent should act; Critical/High for a
#                            breaking change, Low for a heads-up with no
#                            required action yet
#   --description  <text>   what changed, for the DEPENDENT's reader
#   --expected     <text>   what the dependent's integration should do now —
#                            the new contract, the action needed
#   --actual       <text>   what breaks, or changes, if the dependent does
#                            not update
#   --steps        <text>   optional — a reproduction or verification
#                            procedure, if there is one (default: N/A, this
#                            is a notice, not a reproducible defect)
#   --notes        <text>   deploy reference, migration guide, timeline
#   --links        <text>   free text for the new report's Links: field —
#                            a ticket, a decision record, a related artifact
#                            in the target project
#   --lane express          declare the express lane on each filed report
#                            (lv-lane.sh): no human gate in the target, if its
#                            written plan passes the eligibility check there.
#                            Refused under LV_UNATTENDED=1. Recorded as declared
#                            by this operator "via <this project's slug>".
#   --lane trusted          the same, and the target waives the check's
#                            warnings while IT is pre-launch (lv-lane.sh,
#                            TRUSTED); plain express in a target that is live.
#   --amends <BUG-id>       this report CORRECTS one already filed in the
#                            target. Sets Links on both sides in the target's
#                            own repo: the new one says "Amends <ID>", the
#                            named one gains "Amended by <new ID>". Requires
#                            --to unless exactly one target is configured —
#                            the ID belongs to one project's counter, and
#                            broadcasting it would name a different artifact
#                            in each.
#   --group <slug>          file into an intake group in each target, opening it
#                            if absent (lv-bug-group.sh, LVI-024). Its members
#                            are not offered to /lv-spec until the group is
#                            sealed, so a conversation still filing — and
#                            correcting what it already filed — is not specced
#                            one report at a time. Each filing ends with the
#                            group's state and the command that seals it.
#                            An --amends report joins its target's open group
#                            without being told.
#
# AMENDING, AND WHY IT IS A FLAG RATHER THAN AN EDIT
#
# A correction to an already-filed request arrives before triage more often
# than not, and the two reports are only useful together. Nothing could link
# them: `--links` did not exist here, and no script could touch a filed bug's
# Links field, so the only route was hand-editing bugs/open/ inside another
# project — which is precisely what a coordinator is told never to do. coordinator hit
# it filing client-b BUG-008 against BUG-007, and again with client-e
# BUG-125 against BUG-123/124, still unlinked (coordinator WFI-001).
#
# The back-link is written by the TARGET's own lv-bug-link.sh, through the
# target's own lv-exec.sh — the same rule the filing itself follows: this
# script never writes into another project's tree directly.
#
# This project's identity is recorded automatically: --source is stamped
# "cross-project:<this project's slug>" on each dependent's side.
#
# COORDINATORS
#
# A coordinator (role: coordinator, docs/coordinator.md) oversees
# projects rather than depending on them, and uses this same script to file
# work down into them. The mechanism is identical; only the config key and the
# default kind differ. A coordinator declares its targets under `coordinates:`,
# because calling the projects it directs its "dependents" would be false in
# the one file a human maintains by hand — the arrow points the other way.
# A coordinator passes --kind request; nothing enforces that,
# because a coordinator reporting a defect it actually observed is a `bug`,
# and one relaying an upstream change is a `notice`.
#
# Both keys are read the same way and both may be present; entries are
# concatenated, so a project that both coordinates others and is depended upon
# does not have to choose.
#
# Output (one summary line per dependent, to stdout):
#   NOTIFIED <name> <bug-id> <path> <dir>
#   SKIPPED  <name> <reason>
# Everything else goes to stderr. This is a report, not an eval contract —
# do not eval it; a broadcast has no single artifact to capture into
# variables. Exit 0 once every declared dependent has been attempted, even
# if some were skipped — a partial broadcast is the normal, expected
# outcome, not a script failure. Exit 1 on bad usage, no dependents:
# configured, or an unknown --to name.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

to_name=""
title=""
kind="notice"
severity="Medium"
description=""
steps=""
expected=""
actual=""
notes=""
links=""
amends=""
lane="normal"
group=""

while [ $# -gt 0 ]; do
  case "$1" in
    --to)          to_name="${2:?--to requires a value}"; shift 2 ;;
    --links)       links="${2:?--links requires a value}"; shift 2 ;;
    --amends)      amends="${2:?--amends requires a bug ID}"; shift 2 ;;
    --lane)        lane="${2:?--lane requires a value}"; shift 2 ;;
    --group)       group="${2:?--group requires a slug}"; shift 2 ;;
    --kind)        kind="${2:?--kind requires a value}"; shift 2 ;;
    --severity)    severity="${2:?--severity requires a value}"; shift 2 ;;
    --description) description="${2:?--description requires a value}"; shift 2 ;;
    --steps)       steps="${2:?--steps requires a value}"; shift 2 ;;
    --expected)    expected="${2:?--expected requires a value}"; shift 2 ;;
    --actual)      actual="${2:?--actual requires a value}"; shift 2 ;;
    --notes)       notes="${2:?--notes requires a value}"; shift 2 ;;
    -h|--help)     wf_usage; exit 0 ;;
    -*) wf_bad_option "$1" ;;
    *)  if [ -z "$title" ]; then title="$1"; else
          echo "Error: unexpected argument '$1' — the title is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$title" ]; then
  echo "Usage: $0 \"<title>\" [--to <name>] [--severity ...] ... — see --help" >&2
  exit 1
fi

case "$severity" in
  Critical|High|Medium|Low) ;;
  *) echo "Error: --severity must be Critical, High, Medium or Low (got '$severity')" >&2; exit 1 ;;
esac

case "$kind" in
  notice|request|bug) ;;
  *) echo "Error: --kind must be 'notice', 'request' or 'bug' (got '$kind')" >&2; exit 1 ;;
esac

case "$lane" in
  normal|express|trusted) ;;
  *) echo "Error: --lane must be 'express', 'trusted' or 'normal' (got '$lane')" >&2; exit 1 ;;
esac
if [ "$lane" != normal ] && [ "${LV_UNATTENDED:-}" = "1" ]; then
  echo "Error: --lane $lane is a human's statement, and this is an unattended worker (LV_UNATTENDED=1). Nothing was filed." >&2
  exit 1
fi

# ── Resolve targets from THIS project's own config ─────────────────────────
caller_root="$(wf_develop_root)"
caller_slug=$(wf_cfg project_slug "$(basename "$caller_root")")

declare -a target_names=()
declare -a target_paths=()

# `dependents:` and `coordinates:` are the same list under two names, because
# the relationship they describe runs in opposite directions and only one of
# the two words is ever true of a given project. Both are read: a project can
# be depended upon AND coordinate others, and making it pick one word would
# cost it half its targets silently.
for cfg_key in dependents coordinates; do
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name="${entry%%:*}"
    path="${entry#*:}"
    target_names+=("$name")
    target_paths+=("$path")
  done < <(wf_cfg_list "$cfg_key")
done

target_key="dependents"
[ "$(wf_cfg role client)" = "coordinator" ] && target_key="coordinates"

if [ "${#target_names[@]}" -eq 0 ]; then
  echo "Error: no '$target_key:' key in $caller_root/levain.yml — nothing to notify. Add one, e.g.:" >&2
  echo "  $target_key:" >&2
  echo "    - \"<name>:/absolute/path/to/<name>\"" >&2
  exit 1
fi

# An --amends ID is allocated by ONE project's counter. Broadcasting it would
# name a different artifact in each target, or none.
if [ -n "$amends" ]; then
  if [ -z "$to_name" ] && [ "${#target_names[@]}" -gt 1 ]; then
    echo "Error: --amends names an artifact in one project's counter — say which with --to." >&2
    printf 'Configured targets: %s\n' "$(IFS=,; echo "${target_names[*]}")" >&2
    exit 1
  fi
  links="${links:+$links; }Amends $amends"
fi

if [ -n "$to_name" ]; then
  found=false
  for n in "${target_names[@]}"; do [ "$n" = "$to_name" ] && found=true && break; done
  if ! $found; then
    echo "Error: no target named '$to_name' in $caller_root/levain.yml" >&2
    printf 'Configured targets: %s\n' "$(IFS=,; echo "${target_names[*]}")" >&2
    exit 1
  fi
fi

source_tag="cross-project:$caller_slug"
case "$kind" in
  notice)  kind_note="This is a change notice from $caller_slug — an upstream dependency change this project's integration may need to account for." ;;
  request) kind_note="This is a work request from $caller_slug, which coordinates this project. It is a capability ask, not a defect found here — triage it through this project's own /lv-spec like any other request. $caller_slug does not plan, claim or implement it." ;;
  bug)     kind_note="This is a defect reported by $caller_slug, observed from outside this project. $caller_slug does not plan, claim or implement it — it goes through this project's own /lv-spec like any other bug." ;;
esac

# An array, not `${links:+--links "$links"}`: an unquoted conditional expansion
# word-splits, which turns a multi-word link into several arguments.
link_args=()
[ -n "$links" ] && link_args=(--links "$links")
lane_args=()
[ "$lane" != normal ] && lane_args=(--lane "$lane" --lane-by "$(git config user.name 2>/dev/null || whoami) via $caller_slug")
group_args=()
[ -n "$group" ] && group_args=(--group "$group")
# Who opened or joined the group, as the target's lv-bug-group.sh records it.
group_from="operator"
[ "$(wf_cfg role client)" = "coordinator" ] && group_from="coordinator:$caller_slug"

notified=0
skipped=0

for i in "${!target_names[@]}"; do
  name="${target_names[$i]}"
  path="${target_paths[$i]}"

  [ -n "$to_name" ] && [ "$name" != "$to_name" ] && continue

  if [ ! -d "$path" ]; then
    echo "SKIPPED $name path-not-found:$path"
    echo "lv-dep-notify: $name's path does not exist: $path" >&2
    skipped=$((skipped + 1)); continue
  fi
  if [ ! -x "$path/scripts/lv-exec.sh" ]; then
    echo "SKIPPED $name not-a-harness-checkout"
    echo "lv-dep-notify: $path has no scripts/lv-exec.sh — not running this harness (or deploy-all.sh hasn't reached it yet)" >&2
    skipped=$((skipped + 1)); continue
  fi

  # Same reasoning as lv-dep-bug.sh: proceed only when the dependent's shared
  # checkout is already on develop, its permanent home. Anything else is
  # skipped rather than displaced — a human's feature/* work included.
  dep_branch=$(cd "$path" && git branch --show-current)
  if [ "$dep_branch" != "develop" ]; then
    echo "SKIPPED $name not-on-develop:$dep_branch"
    echo "lv-dep-notify: $name's checkout is on '$dep_branch', not 'develop' — skipped, nothing written. Try again once it's back on develop." >&2
    skipped=$((skipped + 1)); continue
  fi

  bug_out=""
  if ! bug_out=$(cd "$path" && LV_GROUP_FROM="$group_from" scripts/lv-exec.sh lv-bug-new.sh "$title" \
      --kind "$kind" \
      --severity "$severity" \
      --source "$source_tag" \
      --description "${description:-TBD}" \
      --steps "${steps:-N/A — this is a $kind, not a reproducible defect.}" \
      --expected "${expected:-TBD}" \
      --actual "${actual:-TBD}" \
      "${link_args[@]+"${link_args[@]}"}" \
      "${lane_args[@]+"${lane_args[@]}"}" \
      "${group_args[@]+"${group_args[@]}"}" \
      --notes "${kind_note}${notes:+$'\n\n'}${notes}"); then
    echo "SKIPPED $name filing-failed"
    echo "lv-dep-notify: filing in $name failed — see output above" >&2
    skipped=$((skipped + 1)); continue
  fi
  eval "$bug_out"

  # The other half of --amends: the report being corrected has to say so too,
  # or a reader who opens it first never learns a correction exists. Written by
  # the TARGET's own lv-bug-link.sh, through the target's own lv-exec.sh — this
  # script never edits another project's files directly (coordinator WFI-001).
  if [ -n "$amends" ]; then
    if (cd "$path" && scripts/lv-exec.sh lv-bug-link.sh "$amends" "Amended by $BUG_ID" >&2); then
      echo "$amends in $name now links $BUG_ID" >&2
    else
      echo "lv-dep-notify: $BUG_ID was filed in $name, but back-linking $amends FAILED — $BUG_ID says it amends $amends and $amends does not mention it. Link it in $name before its triage reads only one side." >&2
    fi
  fi

  # Where the batch stands, every filing: the overseer is the one who seals it,
  # and a group nobody remembers to seal holds its members forever.
  group_out=$(cd "$path" && scripts/lv-exec.sh lv-bug-group.sh of "$BUG_ID" 2>/dev/null || true)
  GROUP_SLUG="" GROUP_STATUS="" GROUP_MEMBERS=""
  [ -n "$group_out" ] && eval "$group_out"
  if [ -n "$GROUP_SLUG" ]; then
    seal_cmd="lv-bug-group.sh seal $GROUP_SLUG"
    [ "$group_from" != "operator" ] && seal_cmd="lv-bug-group.sh --project $name seal $GROUP_SLUG"
    echo "$BUG_ID is in $name's intake group $GROUP_SLUG ($GROUP_STATUS: $GROUP_MEMBERS) — held from /lv-spec until: $seal_cmd" >&2
  fi

  echo "NOTIFIED $name $BUG_ID $path $BUG_DIR"
  echo "$BUG_ID filed in $name → $path/$BUG_DIR (not pushed — that project's own push)" >&2
  notified=$((notified + 1))
done

echo "lv-dep-notify: $notified notified, $skipped skipped" >&2
exit 0
