#!/usr/bin/env bash
# lv-brief-block.sh <BRF-NNN|BUG-NNN> "<why>" [--on <artifact>] [--repo <name>] [--no-commit]
# lv-brief-block.sh <BRF-NNN|BUG-NNN> --clear [--no-commit]
#
# Records that a specable artifact cannot be converted to a plan yet, by
# writing a `> **Blocked:**` field into its header — and clears it again when
# the blocker lifts. lv-list-specable.sh reads that field and stops offering
# the artifact, so the dispatcher stops sending a spec worker at work that
# cannot be done.
#
# A hand-written `> **Blocked by:**` is the same field (LVI-013): blocking
# rewrites it to `Blocked:`, and --clear removes it.
#
# The name says `brief` because briefs were the only case when it was written.
# Bugs turned out to need the identical verb for the identical reason (below),
# and the field, the reader and the semantics are the same — so it takes both
# rather than growing a near-duplicate script.
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
# A BUG CAN BE IN EXACTLY THE SAME POSITION, and the "bugs move" claim above is
# what hid it. client-d WFI-018: BUG-017's needs-input gate was answered "stays
# OPEN pending BRF-018, and is closed by whatever that brief decides". So no
# plan may be created, so lv-bug-consume.sh never runs, so the bug never leaves
# bugs/open/ — and lv-list-specable.sh offered it again the moment the worker
# unclaimed. The next spec worker repeats the run identically: read bug, read
# answered gate, create nothing, exit. bugs/triaged/ is no escape either, since
# a triaged bug with an empty Plan: field is re-offered by design (WFI-249).
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
#   --on <artifact>   the blocking artifact, e.g. BUG-002, PLN-014, BRF-018.
#                     A block on a plan — here, or with --repo there — lifts by
#                     itself once that plan is complete (LVI-036, LVI-058);
#                     any other blocker waits for --clear
#   --repo <name>     the project that artifact belongs to, when it is not
#                     this one — a cross-repo blocker is the common case
#   --clear           the blocker lifted; remove the field
#
# Exit 0 on success, 1 on error.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

artifact_id=""
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
    *)  if [ -z "$artifact_id" ]; then artifact_id="$1"
        elif [ -z "$why" ]; then why="$1"
        else echo "Error: unexpected argument '$1' — the reason is one argument, quote it" >&2; exit 1
        fi; shift ;;
  esac
done

if [ -z "$artifact_id" ] || { ! $clear && [ -z "$why" ]; }; then
  echo "Usage: $0 <$LV_BRF-NNN|$LV_BUG-NNN> \"<why>\" [--on <artifact>] [--repo <name>] [--no-commit]" >&2
  echo "       $0 <$LV_BRF-NNN|$LV_BUG-NNN> --clear [--no-commit]" >&2
  echo >&2
  echo "A blocker with no reason is an artifact nobody can unblock. The reason is required." >&2
  exit 1
fi

cd "$(wf_develop_root)"

# Where the header lives depends on the artifact. A bug's is bug.md, in
# whichever folder it currently sits — this verb is for the bug that CANNOT
# move, so both are in scope.
brief_md=""
kind=""
if [[ "$artifact_id" =~ ^($LV_BUG_RE)- ]]; then artifact_kind=bug
elif [[ "$artifact_id" =~ ^($LV_BRF_RE)- ]]; then artifact_kind=brief
else artifact_kind=""; fi
case "$artifact_kind" in
  bug)
    kind=bug
    for f in bugs/open/${artifact_id}*/bug.md bugs/triaged/${artifact_id}*/bug.md; do
      [ -f "$f" ] && brief_md="$f" && break
    done
    if [ -z "$brief_md" ]; then
      echo "Error: no bug matching $artifact_id in bugs/open/ or bugs/triaged/" >&2
      exit 1
    fi
    ;;
  brief)
    kind=brief
    for f in plans/briefs/${artifact_id}*.md; do
      [ -f "$f" ] && brief_md="$f" && break
    done
    if [ -z "$brief_md" ]; then
      echo "Error: no brief matching $artifact_id in plans/briefs/" >&2
      exit 1
    fi
    ;;
  *)
    echo "Error: '$artifact_id' is not a $LV_BRF-NNN or $LV_BUG-NNN id" >&2
    exit 1
    ;;
esac

if $clear; then
  if ! grep -qE '^[ \t]*>?[ \t]*\*\*Blocked( [Bb]y)?:\*\*' "$brief_md"; then
    echo "$artifact_id is not blocked — nothing to clear"
    exit 0
  fi
  awk '!/^[ \t]*>?[ \t]*\*\*Blocked( [Bb]y)?:\*\*/' "$brief_md" > "$brief_md.tmp" && mv "$brief_md.tmp" "$brief_md"
  msg="$kind($artifact_id): unblocked"
  result="$artifact_id unblocked — back on the specable list"
else
  # One line, assembled so a reader of the brief alone can act on it: what is
  # blocking, where it lives, and why it matters here.
  blocked="$why"
  [ -n "$on_artifact" ] && blocked="$on_artifact${on_repo:+ (in $on_repo)} — $why"
  [ -z "$on_artifact" ] && [ -n "$on_repo" ] && blocked="$on_repo — $why"

  # A cross-repo blocker lifts by itself only when this project can read the
  # other one, through its dependencies: entry. Without it the block holds
  # until someone remembers to --clear it (a client's LVI-055: 33 days). Say
  # so now, while the writer can still declare it.
  if [ -n "$on_artifact" ] && [ -n "$on_repo" ]; then
    wf_external_dep_state "$on_repo:$on_artifact"
    if [ "$LV_EXTERNAL_DEP_STATE" = "unknown" ]; then
      echo "Warning: $on_artifact (in $on_repo) cannot be re-checked ($LV_EXTERNAL_DEP_DETAIL), so this block will not lift by itself. Declare $on_repo under dependencies: in levain.yml, or run --clear when it lands." >&2
    fi
  fi

  # Rewrite an existing field rather than stacking a second one; insert after
  # Plan: (or at the end of the header blockquote) when there is none.
  LV_BLOCKED="$blocked" awk '
    BEGIN { note = "> **Blocked:** " ENVIRON["LV_BLOCKED"]; replaced = 0; last_quote = 0; body = 0 }
    {
      if (!replaced && $0 ~ /^[ \t]*>?[ \t]*\*\*Blocked( [Bb]y)?:\*\*/) { lines[NR] = note; replaced = 1; next_ok = 1 }
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

  if ! grep -qE '^[ \t]*>?[ \t]*\*\*Blocked( [Bb]y)?:\*\*' "$brief_md"; then
    echo "Error: could not write the Blocked field into $brief_md — nothing changed" >&2
    exit 1
  fi
  msg="$kind($artifact_id): blocked — $blocked"
  result="$artifact_id blocked — $blocked"
fi

if $do_commit; then
  if ! "$SELF_DIR/lv-commit.sh" "$msg" --add "$brief_md"; then
    echo "Error: $brief_md is written but could not be committed — commit it before another worker does" >&2
    exit 1
  fi
fi

echo "$result"
