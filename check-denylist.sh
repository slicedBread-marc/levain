#!/usr/bin/env bash
# check-denylist.sh [--require-list] [--pre-push]
#
# Keeps names that must never be published out of this repo: the tracked tree,
# and — as a pre-push hook — the commit messages and added lines being pushed.
#
# The patterns are NOT in this repo, because a list of names to keep out would
# itself publish them. They live in a local, gitignored file: $WF_DENYLIST, else
# .denylist at the repo root. One Perl regex per line, matched case-insensitively;
# blank lines and lines starting with # are ignored.
#
#   (default)       scan every tracked file at the working tree
#   --pre-push      also read git's pre-push stdin and scan each pushed range's
#                   commit messages and added lines (install: see below)
#   --require-list  fail when no pattern file exists, instead of passing. The
#                   maintainer's hook uses this, so a missing list fails closed.
#
# Install as the maintainer's pre-push hook:
#   printf '#!/bin/sh\nexec ./check-denylist.sh --require-list --pre-push\n' > .git/hooks/pre-push
#   chmod +x .git/hooks/pre-push
#
# Exit 0 clean, 1 a match (file:line printed; the matching text is not), 2 usage
# or a missing list under --require-list.

set -uo pipefail

require=0 prepush=0
for a in "$@"; do
  case "$a" in
    --require-list) require=1 ;;
    --pre-push)     prepush=1 ;;
    -h|--help)      sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "check-denylist.sh: unknown option '$a'" >&2; exit 2 ;;
  esac
done

root=$(git rev-parse --show-toplevel) || exit 2
list="${WF_DENYLIST:-$root/.denylist}"

if [ ! -s "$list" ]; then
  if [ "$require" = 1 ]; then
    echo "check-denylist: no pattern list at $list — refusing (--require-list)" >&2
    exit 2
  fi
  echo "check-denylist: no pattern list at $list — nothing to check" >&2
  exit 0
fi

patterns=$(grep -vE '^\s*(#|$)' "$list")
[ -n "$patterns" ] || { echo "check-denylist: $list has no patterns" >&2; [ "$require" = 1 ] && exit 2; exit 0; }
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
    bad=$(git log --format='%H' "$range" | while read -r c; do
      if git log -1 -p --format='%B' "$c" | grep -vE '^(-|diff |index |--- )' \
         | perl -ne 'BEGIN{$r=shift} if(/$r/i){print "x"; exit}' "$combined" | grep -q x; then
        echo "${c:0:12}"
      fi
    done)
    if [ -n "$bad" ]; then
      echo "check-denylist: denylisted text in commits being pushed (message or added lines):" >&2
      printf '  %s\n' $bad >&2
      hits=1
    fi
  done
fi

[ "$hits" = 0 ] && echo "check-denylist: clean" >&2
exit "$hits"
