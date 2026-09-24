#!/usr/bin/env bash
# check-denylist.sh [--require-list] [--pre-push] [--all-objects]
#
# Keeps names that must never be published out of this repo: the tracked tree,
# and — as a pre-push hook — the commit messages and added lines being pushed.
#
# The patterns are NOT in this repo, because a list of names to keep out would
# itself publish them. They come from the publish-denylist hook
# (scripts/v2.00/lv-hook.sh), which a private pack answers; $LV_DENYLIST names a
# file to use instead. One Perl regex per line, matched case-insensitively;
# blank lines and lines starting with # are ignored. A listed pack that is
# missing refuses everything (exit 2), so a moved pack cannot pass as clean.
#
#   (default)       scan every tracked file at the working tree
#   --pre-push      also read git's pre-push stdin and scan each pushed range's
#                   commit messages and added lines (install: see below)
#   --all-objects   also scan every object in the object store — reachable or
#                   not, every blob, tree, commit and tag. Run it on a fresh
#                   clone before a first public push: that is what can travel.
#   --require-list  fail when no pattern comes back, instead of passing. The
#                   maintainer's hook uses this, so a missing list fails closed.
#
# Install as the maintainer's pre-push hook:
#   printf '#!/bin/sh\nexec ./check-denylist.sh --require-list --pre-push\n' > .git/hooks/pre-push
#   chmod +x .git/hooks/pre-push
#
# Exit 0 clean, 1 a match (file:line or object id printed; the matching text is
# not), 2 usage, a failed hook, or no patterns under --require-list.

set -uo pipefail

require=0 prepush=0 allobj=0
for a in "$@"; do
  case "$a" in
    --require-list) require=1 ;;
    --pre-push)     prepush=1 ;;
    --all-objects)  allobj=1 ;;
    -h|--help)      sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-denylist.sh: unknown option '$a'" >&2; exit 2 ;;
  esac
done

root=$(git rev-parse --show-toplevel) || exit 2
list="${LV_DENYLIST:-${WF_DENYLIST:-}}"
if [ -n "$list" ]; then
  [ -f "$list" ] || { echo "check-denylist: \$LV_DENYLIST names $list, which does not exist" >&2; exit 2; }
  raw=$(cat "$list"); from="$list"
else
  hook="$root/scripts/v2.00/lv-hook.sh"
  [ -x "$hook" ] || { echo "check-denylist: no $hook to ask for the list" >&2; exit 2; }
  raw=$(CLAUDE_PROJECT_DIR="$root" "$hook" publish-denylist) \
    || { echo "check-denylist: the publish-denylist hook failed — refusing" >&2; exit 2; }
  from="the publish-denylist hook"
  [ -f "$root/.denylist" ] && echo "check-denylist: $root/.denylist is ignored — the list comes from the publish-denylist hook now" >&2
fi

patterns=$(printf '%s\n' "$raw" | grep -vE '^[[:space:]]*(#|$)')
if [ -z "$patterns" ]; then
  if [ "$require" = 1 ]; then
    echo "check-denylist: no patterns from $from — refusing (--require-list)" >&2
    exit 2
  fi
  echo "check-denylist: no patterns from $from — nothing to check" >&2
  exit 0
fi
combined=$(printf '%s\n' "$patterns" | paste -sd'|' -)

hits=0

# 1. The tracked tree. Print location only, never the matched text.
tree=$(cd "$root" && git grep -nIiP -- "$combined" 2>/dev/null | cut -d: -f1,2)
if [ -n "$tree" ]; then
  echo "check-denylist: denylisted text in tracked files:" >&2
  printf '  %s\n' $tree >&2
  hits=1
fi

# 2. What a push would publish: messages and added lines of each new range.
if [ "$prepush" = 1 ]; then
  zero=0000000000000000000000000000000000000000
  while read -r _lref lsha _rref rsha; do
    [ "$lsha" = "$zero" ] && continue                 # a delete publishes nothing
    if [ "$rsha" = "$zero" ]; then range="$lsha"; else range="$rsha..$lsha"; fi
    # perl reads to the end and answers once. It used to `exit` on the first
    # match, which closed the pipe under git and grep; with pipefail their
    # SIGPIPE failed the whole pipeline, so the `if` saw a failure and a match
    # in any commit bigger than a pipe buffer passed as clean.
    bad=$(git log --format='%H' "$range" | while read -r c; do
      hit=$(git log -1 -p --format='%B' "$c" | grep -vE '^(-|diff |index |--- )' \
         | perl -ne 'BEGIN{$r=shift} $f=1 if /$r/i; END{print $f ? "x" : ""}' "$combined")
      [ "$hit" = x ] && echo "${c:0:12}"
    done)
    if [ -n "$bad" ]; then
      echo "check-denylist: denylisted text in commits being pushed (message or added lines):" >&2
      printf '  %s\n' $bad >&2
      hits=1
    fi
  done
fi

# 3. Everything the object store holds, reachable or not.
if [ "$allobj" = 1 ]; then
  bad=$(git cat-file --batch-all-objects --batch | perl -e '
    my $r = shift; $r = qr/$r/i;
    while (my $h = <STDIN>) {
      my ($sha, $type, $size) = split " ", $h;
      read(STDIN, my $body, $size); my $nl = <STDIN>;
      print substr($sha, 0, 12), " $type\n" if $body =~ $r;
    }' "$combined")
  if [ -n "$bad" ]; then
    echo "check-denylist: denylisted text in the object store:" >&2
    printf '%s\n' "$bad" | sed 's/^/  /' >&2
    hits=1
  fi
fi

[ "$hits" = 0 ] && echo "check-denylist: clean" >&2
exit "$hits"
