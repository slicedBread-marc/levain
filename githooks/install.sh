#!/usr/bin/env bash
# githooks/install.sh — link this repo's tracked hooks into .git/hooks.
#
# git never clones hooks, so a fresh checkout has no VERSION bump until this
# runs once. It links rather than copies, so an edit to githooks/ is live at
# once. A hook already in .git/hooks that is not one of these links is left
# alone and reported: it may be a local one on purpose (the operator's
# denylist pre-push is), and overwriting it would drop a guard silently.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
hooks=$(git rev-parse --git-path hooks)
for src in "$root"/githooks/*; do
  name=$(basename "$src")
  [ "$name" = install.sh ] && continue
  dest="$hooks/$name"
  if [ -e "$dest" ] && [ ! -L "$dest" ]; then
    if cmp -s "$src" "$dest"; then rm "$dest"
    else echo "githooks: $dest is a local hook, left alone" >&2; continue; fi
  fi
  ln -sfn "$src" "$dest"
  echo "githooks: $name linked"
done
