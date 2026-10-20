#!/usr/bin/env bash
# lv-worktree-preserve.sh <worktree-path>
#
# Copies the untracked and git-ignored files a plan produced under the
# project's `preserveIgnored:` paths out of its feature worktree and into the
# develop root, so removing the worktree does not delete them.
#
# WHY THIS EXISTS
#
# A merge carries tracked files and nothing else, and `git worktree remove
# --force` deletes untracked AND ignored files with the directory. That is
# right for build output and wrong for a project whose deliverable is
# deliberately kept out of git: a client parks generated renders under
# brainstorm/, ignored by a `brainstorm/*/*/*.png` rule because the folder runs
# to hundreds of megabytes. PLN-027's 24 renders — the whole content of the
# gallery the plan built — existed only in its worktree, and /lv-test step 6
# removed them at completion. develop got the gallery page and no images
# (WFI-023). Nothing warned; the operator found out by looking (WFI-024).
#
# The project names those paths once, in levain.yml:
#
#   preserveIgnored:
#     - brainstorm/
#
# and every exit that removes a feature worktree runs this first.
#
# What it does, per path:
#   - lists files git does not track under that path in the worktree
#     (ignored or merely untracked — both die with the directory)
#   - copies each one to the same relative path under the develop root
#   - skips one already there with identical content
#   - REFUSES one already there with different content: that is somebody
#     else's file, and choosing between the two is not a copy's job
#
# Exit 0 — preserved (or nothing configured, or nothing to preserve): the
#          worktree may be removed.
# Exit 1 — usage error.
# Exit 2 — a conflict or a failed copy. Do NOT remove the worktree; the files
#          named on stderr exist nowhere else. Also exit 2 when a service
#          (lv-services.sh) is running from the worktree: stop it first.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lv-orch-lib.sh
source "$SELF_DIR/lv-orch-lib.sh"

wt="${1:-}"
if [ -z "$wt" ] || [ "$wt" = "-h" ] || [ "$wt" = "--help" ]; then
  sed -n '2,40p' "$0" >&2
  [ -n "$wt" ] && exit 0 || exit 1
fi
if [ ! -d "$wt" ]; then
  # Already gone: nothing is left to lose, and a caller re-running its exit
  # path must not fail here.
  echo "lv-worktree-preserve: $wt does not exist — nothing to preserve" >&2
  exit 0
fi
wt="$(cd "$wt" && pwd -P)"
root="$(cd "$(wf_develop_root)" && pwd -P)"

# A service started from this worktree (lv-services.sh) keeps running after the removal, against
# a directory that is gone. pgrep on the path misses it: the launcher runs as `tools/x.sh`, by a
# relative path. Its beacon names the checkout, so ask that instead, before anything else.
if [ -x "$SELF_DIR/lv-services.sh" ] && ! "$SELF_DIR/lv-services.sh" guard "$wt"; then
  echo "  Do not remove $wt — stop the service above (lv-rack, v) first, then re-run." >&2
  exit 2
fi

paths=()
while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done < <(wf_cfg_list preserveIgnored)
[ ${#paths[@]} -gt 0 ] || exit 0

if [ "$wt" = "$root" ]; then
  echo "Error: $wt is the develop root, not a feature worktree" >&2
  exit 1
fi

copied=0 same=0 failed=0
for p in "${paths[@]}"; do
  p="${p#/}"
  # --others without --exclude-standard lists ignored files too — exactly the
  # set a forced removal destroys.
  while IFS= read -r -d '' f; do
    src="$wt/$f"; dst="$root/$f"
    [ -f "$src" ] || continue
    if [ -e "$dst" ]; then
      if cmp -s "$src" "$dst"; then same=$((same + 1)); continue; fi
      echo "  CONFLICT $f — develop already has a different file there" >&2
      failed=$((failed + 1)); continue
    fi
    if mkdir -p "$(dirname "$dst")" && cp -p "$src" "$dst"; then
      copied=$((copied + 1))
    else
      echo "  FAILED   $f — could not copy to $dst" >&2
      failed=$((failed + 1))
    fi
  done < <(git -C "$wt" ls-files --others -z -- "$p" 2>/dev/null)
done

echo "lv-worktree-preserve: $copied copied, $same already on develop, $failed not preserved (preserveIgnored: ${paths[*]})" >&2
if [ "$failed" -gt 0 ]; then
  echo "  Do not remove $wt — the files above exist only there. Resolve each by hand, then re-run." >&2
  exit 2
fi
exit 0
