#!/usr/bin/env bash
# wf-guard-write.sh — PreToolUse guard: refuse a write into an artifact another
# live session has claimed.
#
# Wired to PreToolUse on Edit|Write|NotebookEdit by templates/hooks/settings-merge.py.
# Reads the hook payload on stdin, resolves the target path to an artifact, and
# exits 2 (block, message to the model) when a DIFFERENT live session holds that
# artifact's claim. Exits 0 in every other case.
#
# WHY A HOOK, AND NOT MORE INSTRUCTIONS IN THE SKILLS
#
# Two primitives already existed and neither one covers a session driving a file:
#
#   - wf-lock.sh is a real mutex, but its lifetime is ONE PROCESS. It ends with
#     `trap wf_lock_release_all EXIT` and its re-entrancy rides on an exported
#     WF_LOCK_HELD_<NAME>. Every agent Bash call is a fresh shell, so a session
#     cannot hold one across two tool calls — it is released the instant the
#     call returns. It protects a script's critical section (a REGISTRY row
#     rewrite), which is what it was built for, and nothing longer.
#
#   - wf-claim.sh IS session-scoped — a PID file with liveness and a TTL, the
#     right shape and the right lifetime. But it was only ever read at DISPATCH
#     (wf-spawn.sh, three list scripts). It answers "should I launch a worker
#     onto this?" and never "may I write this file?". So it stopped a second
#     worker being started and guarded nothing already running.
#
# The gap between them is a session that writes a claimed plan without ever
# asking — which is not a discipline problem to be solved with a louder skill
# instruction, because the session that most needs the answer is the one that
# never read the instruction. A machine that is about to write the file is the
# only thing positioned to check, so the check goes there.
#
# FAIL OPEN, ALWAYS
#
# This runs before EVERY Edit and Write in the repo. A guard that fails closed
# on its own bugs bricks the editor for the whole project, which is far worse
# than the collision it prevents. So the only path to exit 2 is a positively
# identified foreign live claim: no artifact in the path, no claim, an expired
# claim, an unreadable payload, a missing python3, not a repo — every one of
# those exits 0 and says nothing.
#
# Exit 0 allow (and on any uncertainty), 2 block.

set -uo pipefail   # deliberately NOT -e: a failing probe must allow, not block

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

# Cheap pre-filter, on the whole payload, before anything forks. A payload with
# no artifact ID anywhere in it cannot have one in its path, and the overwhelming
# majority of edits in a working repo are source files under no artifact at all.
# This is a hot path — the hook runs before EVERY Edit and Write — and skipping
# the python3 start-up on that case is most of the cost.
#
# A false positive here (an ID inside the file CONTENT of an Edit) costs one
# parse and then exits on the real path. It cannot cause a wrong block.
printf '%s' "$payload" | grep -qE '(PLN|BUG|BRF)-[0-9]+' || exit 0

# The path the tool is about to write. python3 rather than a regex over JSON:
# it is already a deploy dependency (templates/hooks/settings-merge.py), and a
# hand-rolled extractor that mis-parses an escaped path fails in the one
# direction this script must never fail — blocking a write it cannot explain.
target=$(printf '%s' "$payload" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    sys.exit(0)
p = ti.get("file_path") or ti.get("notebook_path") or ""
print(p if isinstance(p, str) else "")
' 2>/dev/null) || exit 0
[ -n "$target" ] || exit 0

# The artifact whose territory this path is in.
#
# "Territory" is a LOCATION, not a spelling. This used to be a bare
# `grep -oE '(PLN|BUG|BRF)-[0-9]+'` over the whole path string, so any path
# whose name mentioned an artifact was treated as that artifact's file —
# wherever it pointed. client-a's WFI-163: a planner recording a spec
# correction for later was blocked from writing
# `/private/tmp/…/scratchpad/PLN-101-spec-correction.md`, a note in the
# session's own temp directory, outside the repository, that no other session
# can see (the guard's refusal on that plan's `findings.md`, moments earlier,
# was correct and is untouched).
#
# The cost of that is not one annoyed session: the workaround is to rename the
# file, so the guard teaches people to route around it rather than respect it.
#
# So the ID must both START a path segment and sit under a directory the
# pipeline owns, which is what every real layout looks like:
#   plans/PLN-042-slug/plan.md          feature-branches/PLN-042-slug/src/…
#   bugs/open/BUG-013-slug.md           briefs/BRF-007-slug.md
#
# A path with no artifact ID in an owned location belongs to no artifact —
# plans/REGISTRY.md among them, which is shared by design and has wf-lock.sh's
# `registry` lock instead. Failing open here is the whole posture of this
# script: a missed block costs a collision the other guards still catch, a
# wrong block costs the editor.
# The owning artifact is the one named in the segment DIRECTLY under the owned
# directory — so a source file inside a plan's worktree belongs to that plan,
# whatever the file is called. `feature-branches/PLN-042-slug/src/BUG-013-fix.cs`
# is PLN-042's, not BUG-013's; a greedy match over intervening segments gets
# that backwards and would hand the file to the wrong claim.
#
# `bugs/` is the one layout with a segment in between — `bugs/open/BUG-013…`,
# `bugs/triaged/…`, `bugs/closed/…` — so it is asked second and only for itself.
artifact=$(printf '%s' "$target" \
  | grep -oE '(^|/)(plans|briefs|feature-branches)/(PLN|BUG|BRF)-[0-9]+' \
  | head -1 | grep -oE '(PLN|BUG|BRF)-[0-9]+$')
if [ -z "$artifact" ]; then
  artifact=$(printf '%s' "$target" \
    | grep -oE '(^|/)bugs/([^/]+/)?(PLN|BUG|BRF)-[0-9]+' \
    | head -1 | grep -oE '(PLN|BUG|BRF)-[0-9]+$')
fi
[ -n "$artifact" ] || exit 0

lib="$(dirname "$0")/wf-orch-lib.sh"
[ -f "$lib" ] || exit 0
# shellcheck source=wf-orch-lib.sh
source "$lib" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

wf_claim_held "$artifact" 2>/dev/null || exit 0

# Our own claim, or one our dispatcher took out for us. wf_claim_mine is the
# same test wf-claim.sh and wf-spawn.sh use, and getting this wrong is not
# hypothetical: reading a claim written on the worker's own behalf as somebody
# else's is what made every dispatched tester stand down against itself and
# parked every plan that reached testing (WFI-073, WFI-075).
wf_claim_mine "$WF_CLAIM_HELD_DIR" 2>/dev/null && exit 0

holder=$(sed -n '2p' "$WF_CLAIM_HELD_DIR/.wf-claim" 2>/dev/null | tr -cd '0-9')
age_min=$(( ${WF_CLAIM_AGE:-0} / 60 ))

# stderr, exit 2: the PreToolUse contract for "block and tell the model why".
# It names the one command that resolves it, because a block whose only advice
# is "stop" gets worked around by deleting the claim file, which the skills
# already forbid and which loses the trigger wf-unclaim.sh flushes.
cat >&2 <<EOF
$artifact is claimed by another live session (PID ${holder:-unknown}, held ${age_min}m).

  $target

Do not edit it: that session is driving this artifact, and two writers on one
plan is what the claim exists to prevent. Work something else, or — only if you
know the holder is finished or wedged — take it deliberately:

  scripts/wf-exec.sh wf-claim.sh $artifact --steal

Never by deleting the claim file by hand.
EOF
exit 2
