#!/usr/bin/env bash
# wf-dep-notify.sh "<title>" [options]
#
# Announces a change in THIS project to the projects that depend on it — the
# mirror image of wf-dep-bug.sh. Use this when a change here (a contract
# change, a breaking API shift, a migration a dependent needs to run) affects
# code this project does not own. For a defect or capability ask against a
# DEPENDENCY, use wf-dep-bug.sh instead — this script only ever writes
# outward, never asks for anything back.
#
# Dependents are local checkouts of this same harness, declared in THIS
# project's claude-workflow.yml:
#
#   dependents:
#     - "client-e:/Users/you/dev/client-e"
#     - "client-f:/Users/you/dev/client-f"
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
# For each target dependent, this runs THAT project's own scripts/wf-exec.sh
# wf-bug-new.sh in THAT project's own checkout — same mechanism wf-dep-bug.sh
# uses, just reversed. The notice is allocated through the dependent's own
# counter and lands in the dependent's own bugs/open/, exactly where its own
# /wf-spec already looks. There is no second inbox, no changelog to poll, no
# new triage path for either side to learn.
#
# It NEVER switches a dependent's branch. A dependent whose shared checkout
# is already on `develop` — its permanent home, docs/release-worktrees.md —
# gets the notice filed normally. Any other branch (a human's feature/* work
# included) is skipped, not displaced: see wf-dep-bug.sh's header for the
# full reasoning, which applies here unchanged.
#
# This is a BROADCAST by default — every declared dependent gets the same
# notice, because the whole point is keeping every consumer in sync, not
# picking one. One dependent parked off develop does not block the others:
# each is attempted independently and the per-dependent result is reported.
# Restrict to a single dependent with --to when a change only affects one.
#
# It commits in each dependent but does NOT push — same as wf-dep-bug.sh.
# Pushing another project's branch is that project's call.
#
#   --to <name>             optional — restrict to one entry in dependents:
#                            (default: every declared dependent)
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
#
# This project's identity is recorded automatically: --source is stamped
# "cross-project:<this project's slug>" on each dependent's side, and the
# notice is filed with --kind notice.
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
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

to_name=""
title=""
severity="Medium"
description=""
steps=""
expected=""
actual=""
notes=""

while [ $# -gt 0 ]; do
  case "$1" in
    --to)          to_name="${2:?--to requires a value}"; shift 2 ;;
    --severity)    severity="${2:?--severity requires a value}"; shift 2 ;;
    --description) description="${2:?--description requires a value}"; shift 2 ;;
    --steps)       steps="${2:?--steps requires a value}"; shift 2 ;;
    --expected)    expected="${2:?--expected requires a value}"; shift 2 ;;
    --actual)      actual="${2:?--actual requires a value}"; shift 2 ;;
    --notes)       notes="${2:?--notes requires a value}"; shift 2 ;;
    -h|--help)     sed -n '2,75p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "wf-dep-notify.sh: unknown option '$1'" >&2; exit 1 ;;
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

# ── Resolve targets from THIS project's own config ─────────────────────────
caller_root="$(wf_develop_root)"
caller_slug=$(wf_cfg project_slug "$(basename "$caller_root")")

declare -a target_names=()
declare -a target_paths=()
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  name="${entry%%:*}"
  path="${entry#*:}"
  target_names+=("$name")
  target_paths+=("$path")
done < <(wf_cfg_list dependents)

if [ "${#target_names[@]}" -eq 0 ]; then
  echo "Error: no 'dependents:' key in $caller_root/claude-workflow.yml — nothing to notify. Add one, e.g.:" >&2
  echo "  dependents:" >&2
  echo "    - \"<name>:/absolute/path/to/<name>\"" >&2
  exit 1
fi

if [ -n "$to_name" ]; then
  found=false
  for n in "${target_names[@]}"; do [ "$n" = "$to_name" ] && found=true && break; done
  if ! $found; then
    echo "Error: no dependent named '$to_name' in $caller_root/claude-workflow.yml" >&2
    printf 'Configured dependents: %s\n' "$(IFS=,; echo "${target_names[*]}")" >&2
    exit 1
  fi
fi

source_tag="cross-project:$caller_slug"
kind_note="This is a change notice from $caller_slug — an upstream dependency change this project's integration may need to account for."

notified=0
skipped=0

for i in "${!target_names[@]}"; do
  name="${target_names[$i]}"
  path="${target_paths[$i]}"

  [ -n "$to_name" ] && [ "$name" != "$to_name" ] && continue

  if [ ! -d "$path" ]; then
    echo "SKIPPED $name path-not-found:$path"
    echo "wf-dep-notify: $name's path does not exist: $path" >&2
    skipped=$((skipped + 1)); continue
  fi
  if [ ! -x "$path/scripts/wf-exec.sh" ]; then
    echo "SKIPPED $name not-a-harness-checkout"
    echo "wf-dep-notify: $path has no scripts/wf-exec.sh — not running this harness (or deploy-all.sh hasn't reached it yet)" >&2
    skipped=$((skipped + 1)); continue
  fi

  # Same reasoning as wf-dep-bug.sh: proceed only when the dependent's shared
  # checkout is already on develop, its permanent home. Anything else is
  # skipped rather than displaced — a human's feature/* work included.
  dep_branch=$(cd "$path" && git branch --show-current)
  if [ "$dep_branch" != "develop" ]; then
    echo "SKIPPED $name not-on-develop:$dep_branch"
    echo "wf-dep-notify: $name's checkout is on '$dep_branch', not 'develop' — skipped, nothing written. Try again once it's back on develop." >&2
    skipped=$((skipped + 1)); continue
  fi

  bug_out=""
  if ! bug_out=$(cd "$path" && scripts/wf-exec.sh wf-bug-new.sh "$title" \
      --kind notice \
      --severity "$severity" \
      --source "$source_tag" \
      --description "${description:-TBD}" \
      --steps "${steps:-N/A — this is a change notice, not a reproducible defect.}" \
      --expected "${expected:-TBD}" \
      --actual "${actual:-TBD}" \
      --notes "${kind_note}${notes:+$'\n\n'}${notes}"); then
    echo "SKIPPED $name filing-failed"
    echo "wf-dep-notify: filing in $name failed — see output above" >&2
    skipped=$((skipped + 1)); continue
  fi
  eval "$bug_out"

  echo "NOTIFIED $name $BUG_ID $path $BUG_DIR"
  echo "$BUG_ID filed in $name → $path/$BUG_DIR (not pushed — that project's own push)" >&2
  notified=$((notified + 1))
done

echo "wf-dep-notify: $notified notified, $skipped skipped" >&2
exit 0
