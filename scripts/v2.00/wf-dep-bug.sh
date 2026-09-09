#!/usr/bin/env bash
# wf-dep-bug.sh --host <name> "<title>" [options]
#
# Files a bug or request against a DEPENDENCY project — for when THIS project
# hits a defect or wants a capability change in a project it depends on (e.g.
# client-e integrating client-c's OIDC), not a bug in this project
# itself. For that, use /wf-bug (wf-bug-new.sh) as normal.
#
# The dependency must be a local checkout of a project running this same
# harness, declared in THIS project's claude-workflow.yml:
#
#   dependencies:
#     - "client-c:/Users/you/dev/client-c"
#
# One name, one absolute path, joined by the first ':'. See
# docs/cross-project-reports.md for the full convention.
#
# HOW IT WORKS
#
# This does not write into the dependency's files directly. It cd's into the
# dependency's own worktree and runs ITS OWN scripts/wf-exec.sh wf-bug-new.sh,
# so the bug is allocated through THAT project's own counter and registry —
# not this one's — landing exactly where a human on that project would have
# filed it by hand. Their own /wf-spec picks it up like any other bug; there
# is no second triage path for the host to learn.
#
# It goes through the host's own wf-branch-check.sh first, so it inherits the
# same protection wf-bug gets locally: a shared checkout a human parked on
# some other branch is left alone (exit 2), and nothing is written. Try again
# once the host is idle or on develop.
#
# It commits in the host but does NOT push — same as wf-bug-new.sh does
# locally. Pushing another project's branch is that project's call, made by a
# human or its own orchestrator there, not by a script running on its behalf
# from somewhere else.
#
#   --host <name>          required — must match an entry in dependencies:
#   --kind bug|request      default: bug
#   --severity Critical|High|Medium|Low   default: Medium
#   --description / --steps / --expected / --actual / --notes  <text>
#
# The reporting project is recorded automatically: --source is stamped
# "cross-project:<this project's slug>" on the host's side. Write the title
# and description for the HOST's reader — say what they need to know, not
# just how it looks from here.
#
# Output is an eval contract:
#   DEP_BUG_ID='BUG-041'
#   DEP_BUG_HOST='client-c'
#   DEP_BUG_PATH='/Users/you/dev/client-c'
#   DEP_BUG_DIR='bugs/open/BUG-041-login-crash'      (relative to DEP_BUG_PATH)
# Everything else goes to stderr.
#
# Exit 0 on success. Exit 1 on bad usage, missing config, or a host that
# isn't a harness-enabled local checkout. Exit 2 when the host refused
# because a human has its checkout parked elsewhere — nothing was written.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

host_name=""
title=""
kind="bug"
severity="Medium"
description=""
steps=""
expected=""
actual=""
notes=""

while [ $# -gt 0 ]; do
  case "$1" in
    --host)        host_name="${2:?--host requires a value}"; shift 2 ;;
    --kind)        kind="${2:?--kind requires a value}"; shift 2 ;;
    --severity)    severity="${2:?--severity requires a value}"; shift 2 ;;
    --description) description="${2:?--description requires a value}"; shift 2 ;;
    --steps)       steps="${2:?--steps requires a value}"; shift 2 ;;
    --expected)    expected="${2:?--expected requires a value}"; shift 2 ;;
    --actual)      actual="${2:?--actual requires a value}"; shift 2 ;;
    --notes)       notes="${2:?--notes requires a value}"; shift 2 ;;
    -h|--help)     sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "wf-dep-bug.sh: unknown option '$1'" >&2; exit 1 ;;
    *)  if [ -z "$title" ]; then title="$1"; else
          echo "Error: unexpected argument '$1' — the title is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$host_name" ] || [ -z "$title" ]; then
  echo "Usage: $0 --host <name> \"<title>\" [--kind bug|request] [--severity ...] ... — see --help" >&2
  exit 1
fi

case "$kind" in
  bug|request) ;;
  *) echo "Error: --kind must be 'bug' or 'request' (got '$kind')" >&2; exit 1 ;;
esac

# ── Resolve the host from THIS project's own config ────────────────────────
caller_root="$(wf_develop_root)"
caller_slug=$(wf_cfg project_slug "$(basename "$caller_root")")

host_path=""
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  name="${entry%%:*}"
  path="${entry#*:}"
  if [ "$name" = "$host_name" ]; then host_path="$path"; break; fi
done < <(wf_cfg_list dependencies)

if [ -z "$host_path" ]; then
  echo "Error: no dependency named '$host_name' in $caller_root/claude-workflow.yml" >&2
  configured=$(wf_cfg_list dependencies | sed 's/:.*//' | paste -sd, - 2>/dev/null || true)
  if [ -n "$configured" ]; then
    echo "Configured dependencies: $configured" >&2
  else
    echo "No 'dependencies:' key found — add one, e.g.:" >&2
    echo "  dependencies:" >&2
    echo "    - \"$host_name:/absolute/path/to/$host_name\"" >&2
  fi
  exit 1
fi

# ── Validate the host is a real, harness-enabled local checkout ────────────
if [ ! -d "$host_path" ]; then
  echo "Error: dependency '$host_name' path does not exist: $host_path" >&2
  exit 1
fi
if [ ! -x "$host_path/scripts/wf-exec.sh" ]; then
  echo "Error: $host_path has no scripts/wf-exec.sh — it is not running this harness (or deploy-all.sh has not reached it yet)" >&2
  exit 1
fi

# ── File it in the host, exactly as the host would file it itself ──────────
source_tag="cross-project:$caller_slug"
kind_note=""
[ "$kind" = "request" ] && kind_note="This is a capability request from $caller_slug, not a defect found locally in $host_name."

branch_out=""
# WF_UNATTENDED=1: this call is not a human sitting at the host's own
# terminal — it is another project reaching in uninvited. wf-branch-check.sh
# only REFUSES a checkout parked on a foreign branch under this flag; without
# it, the attended path merely warns and switches anyway (right for a human
# who owns the mistake, wrong for a script that does not).
if branch_out=$(cd "$host_path" && WF_UNATTENDED=1 scripts/wf-exec.sh wf-branch-check.sh develop true); then
  eval "$branch_out"
else
  # `!` before a command substitution clobbers $? with the negation's own
  # status, not the command's — read it here, in the branch where it is
  # still the real one.
  status=$?
  echo "Error: $host_name's checkout could not be switched to develop (exit $status) — a human likely has it parked elsewhere. Nothing was written." >&2
  exit 2
fi

bug_out=""
if ! bug_out=$(cd "$host_path" && scripts/wf-exec.sh wf-bug-new.sh "$title" \
    --kind "$kind" \
    --severity "$severity" \
    --source "$source_tag" \
    --description "${description:-TBD}" \
    --steps "${steps:-TBD}" \
    --expected "${expected:-TBD}" \
    --actual "${actual:-TBD}" \
    --notes "${kind_note}${kind_note:+$'\n\n'}${notes:-—}"); then
  echo "Error: filing in $host_name failed — see output above" >&2
  [ -n "${SWITCHED_FROM:-}" ] && (cd "$host_path" && git checkout "$SWITCHED_FROM") >/dev/null 2>&1
  exit 1
fi
eval "$bug_out"

if [ -n "${SWITCHED_FROM:-}" ]; then
  (cd "$host_path" && git checkout "$SWITCHED_FROM") >&2
fi

echo "$BUG_ID filed in $host_name → $host_path/$BUG_DIR" >&2
echo "Not pushed — push $host_name's develop from that project (or let its own orchestrator do it) before anyone there can act on it." >&2

printf "DEP_BUG_ID='%s'\n" "$BUG_ID"
printf "DEP_BUG_HOST='%s'\n" "$host_name"
printf "DEP_BUG_PATH='%s'\n" "$host_path"
printf "DEP_BUG_DIR='%s'\n" "$BUG_DIR"
