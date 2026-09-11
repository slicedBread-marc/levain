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
# This does not write into the dependency's files directly. It runs the
# host's own scripts/wf-exec.sh wf-bug-new.sh in the host's own checkout, so
# the bug is allocated through THAT project's own counter and registry — not
# this one's — landing exactly where a human on that project would have
# filed it by hand. Their own /wf-spec picks it up like any other bug; there
# is no second triage path for the host to learn.
#
# It NEVER switches the host's branch. A host whose shared checkout is
# already on `develop` — its permanent home, docs/release-worktrees.md:
# "Never leaves develop. Ever." — files normally. Anything else (a human's
# feature/* work included) is refused outright (exit 2, nothing written)
# rather than displaced.
#
# This used to force the host onto `develop` first (wf-branch-check.sh),
# file, then switch back — and it silently did so even when the host was on
# a feature/* branch, moving a human's or the host's own orchestrator's work
# out from under them for the duration. Giving the filer its own worktree
# (the release-branches/{release,main} fix for the analogous shared-checkout
# problem, docs/release-worktrees.md) does NOT generalize here: `develop` is
# the shared checkout's own home branch, so a second worktree pinned to it
# fails outright whenever the host is in its normal state ("already checked
# out" — git refuses the same branch in two worktrees at once). Worse,
# wf-counter-next.sh — what actually allocates the bug ID — resolves
# plans/REGISTRY.md via wf_develop_root(), always the host's MAIN worktree,
# never wherever wf-bug-new.sh itself runs from; a second worktree would not
# even decouple the write. Refusing cleanly, rather than moving the host's
# branch, is the fix that's actually available without changing what
# wf_develop_root() means project-wide.
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
# isn't a harness-enabled local checkout. Exit 2 when the host's checkout
# isn't on develop right now — nothing was written; try again once it is.

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

# The host's shared checkout is the ONLY place this can write: wf-bug-new.sh
# allocates through wf-counter-next.sh, which resolves plans/REGISTRY.md via
# wf_develop_root() — always the host's main worktree, never wherever this
# script itself is invoked from. Pointing wf-bug-new.sh at a different
# worktree would still update the counter back at the shared checkout, so a
# separate worktree does not actually decouple filing from the host's branch
# — it would just add a second place to go wrong.
#
# So: proceed only when the shared checkout is ALREADY on develop — its
# stated permanent home (docs/release-worktrees.md: "Never leaves develop.
# Ever."). That is the normal state and nothing needs to move. When it's
# anything else — a human's feature/* work included — refuse (exit 2)
# instead of the silent switch-file-switch-back this used to do. That old
# behavior moved a stranger's checkout out from under them whenever it
# happened to be parked on a feature/* branch (the `develop|feature/*)` ;;
# no-op case below wf-branch-check.sh's foreign-branch guard, which only
# ever covered non-pipeline branches, release and main — never feature/*).
# A report that can't land right now is a no-op; one that silently moved
# someone else's branch is not.
host_branch=$(cd "$host_path" && git branch --show-current)
if [ "$host_branch" != "develop" ]; then
  echo "Error: $host_name's checkout is on '$host_branch', not 'develop'. Nothing was written." >&2
  echo "       Filing a cross-project report never switches the host's branch — that already" >&2
  echo "       belongs to whoever has it parked there. Try again once $host_name is back on develop." >&2
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
  exit 1
fi
eval "$bug_out"

echo "$BUG_ID filed in $host_name → $host_path/$BUG_DIR" >&2
echo "Not pushed — push $host_name's develop from that project (or let its own orchestrator do it) before anyone there can act on it." >&2

printf "DEP_BUG_ID='%s'\n" "$BUG_ID"
printf "DEP_BUG_HOST='%s'\n" "$host_name"
printf "DEP_BUG_PATH='%s'\n" "$host_path"
printf "DEP_BUG_DIR='%s'\n" "$BUG_DIR"
