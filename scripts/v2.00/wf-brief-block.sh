#!/usr/bin/env bash
# wf-brief-block.sh <BRF-NNN> "<why>" [--on <artifact>] [--repo <name>] [--no-commit]
# wf-brief-block.sh <BRF-NNN> --clear [--no-commit]
#
# Records that a Decided brief cannot be converted to a plan yet, by writing a
# `> **Blocked:**` field into its header — and clears it again when the blocker
# lifts. wf-list-specable.sh reads that field and stops offering the brief, so
# the dispatcher stops sending a spec worker at work that cannot be done.
#
# WHY THIS EXISTS
#
# A bug leaves the specable list by MOVING (open/ → triaged/). A brief has no
# such move: the documented exit is a plan folder existing (WFI-188/189/190).
# Two kinds of brief can never satisfy that and so were offered on every sweep
# forever:
#
#   · one blocked on something outside this repo — client-b BRF-010's only
#     specable move waits on client-d BUG-002, still open, and the answered
#     gate of record says in as many words "no PLN-010 yet; BRF-010 stays
#     Decided";
#   · one that sequences SEVERAL future plans rather than becoming one, whose
#     Plan: field is a deliberate "(none — …)".
#
# A spec worker was dispatched onto BRF-010 anyway, read the brief, the gate
# resolution and the blocking bug in the other repo, and exited having created
# nothing. Every future sweep repeats that run identically. Re-opening the
# answered gate is not the escape either — that is the re-derived-question
# anti-pattern (WFI-180/181/182). There was simply no verb for "decided, and
# not yet convertible" (client-b WFI-009).
#
# This is that verb. It is a statement of fact with a reason attached, not a
# state: the brief stays `Decided`, its INDEX.md row does not move, and nothing
# else in the pipeline changes. Clearing it puts the brief straight back on the
# list.
#
#   --on <artifact>   the blocking artifact, e.g. BUG-002, PLN-014
#   --repo <name>     the project that artifact belongs to, when it is not
#                     this one — a cross-repo blocker is the common case
#   --clear           the blocker lifted; remove the field
#
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=wf-orch-lib.sh
source "$SELF_DIR/wf-orch-lib.sh"

brief_id=""
why=""
on_artifact=""
on_repo=""
clear=false
do_commit=true

while [ $# -gt 0 ]; do
  case "$1" in
    --clear)     clear=true; shift ;;
    --on)        on_artifact="${2:?--on requires an artifact ID}"; shift 2 ;;
    --repo)      on_repo="${2:?--repo requires a project name}"; shift 2 ;;
    --no-commit) do_commit=false; shift ;;
    -h|--help)   wf_usage; exit 0 ;;
    -*)          wf_bad_option "$1" ;;
    *)  if [ -z "$brief_id" ]; then brief_id="$1"
        elif [ -z "$why" ]; then why="$1"
        else echo "Error: unexpected argument '$1' — the reason is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$brief_id" ] || { ! $clear && [ -z "$why" ]; }; then
  echo "Usage: $0 <BRF-NNN> \"<why>\" [--on <artifact>] [--repo <name>] [--no-commit]" >&2
  echo "       $0 <BRF-NNN> --clear [--no-commit]" >&2
  echo >&2
  echo "A blocker with no reason is a brief nobody can unblock. The reason is required." >&2
  exit 1
fi

cd "$(wf_develop_root)"

brief_md=""
for f in plans/briefs/${brief_id}*.md; do
  [ -f "$f" ] && brief_md="$f" && break
done
if [ -z "$brief_md" ]; then
  echo "Error: no brief matching $brief_id in plans/briefs/" >&2
  exit 1
fi

if $clear; then
  if ! grep -qE '^[ \t]*>?[ \t]*\*\*Blocked:\*\*' "$brief_md"; then
    echo "$brief_id is not blocked — nothing to clear"
    exit 0
  fi
  awk '!/^[ \t]*>?[ \t]*\*\*Blocked:\*\*/' "$brief_md" > "$brief_md.tmp" && mv "$brief_md.tmp" "$brief_md"
  msg="brief($brief_id): unblocked"
  result="$brief_id unblocked — back on the specable list"
else
  # One line, assembled so a reader of the brief alone can act on it: what is
  # blocking, where it lives, and why it matters here.
  blocked="$why"
  [ -n "$on_artifact" ] && blocked="$on_artifact${on_repo:+ (in $on_repo)} — $why"
  [ -z "$on_artifact" ] && [ -n "$on_repo" ] && blocked="$on_repo — $why"

  # Rewrite an existing field rather than stacking a second one; insert after
  # Plan: (or at the end of the header blockquote) when there is none.
  WF_BLOCKED="$blocked" awk '
    BEGIN { note = "> **Blocked:** " ENVIRON["WF_BLOCKED"]; replaced = 0; last_quote = 0; body = 0 }
    {
      if (!replaced && $0 ~ /^[ \t]*>?[ \t]*\*\*Blocked:\*\*/) { lines[NR] = note; replaced = 1; next_ok = 1 }
      else lines[NR] = $0
      if ($0 ~ /^[ \t]*##[ \t]/) body = 1
      if (!body && $0 ~ /^[ \t]*>/) last_quote = NR
    }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (!replaced && i == last_quote) print note
      }
    }
  ' "$brief_md" > "$brief_md.tmp" && mv "$brief_md.tmp" "$brief_md"

  if ! grep -qE '^[ \t]*>?[ \t]*\*\*Blocked:\*\*' "$brief_md"; then
    echo "Error: could not write the Blocked field into $brief_md — nothing changed" >&2
    exit 1
  fi
  msg="brief($brief_id): blocked — $blocked"
  result="$brief_id blocked — $blocked"
fi

if $do_commit; then
  if ! "$SELF_DIR/wf-commit.sh" "$msg" --add "$brief_md"; then
    echo "Error: $brief_md is written but could not be committed — commit it before another worker does" >&2
    exit 1
  fi
fi

echo "$result"
