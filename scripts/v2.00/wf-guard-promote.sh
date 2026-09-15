#!/usr/bin/env bash
# wf-guard-promote.sh — PreToolUse guard: refuse a `git push` of `release` or
# `main` while that branch's own promotion gate is still open.
#
# Wired to PreToolUse on Bash by templates/hooks/settings-merge.py. Reads the
# hook payload on stdin, and exits 2 (block, message to the model) when the
# command pushes to `origin release` while `RELEASE.gate` exists, or to
# `origin main` while `DEPLOY.gate` exists. Exits 0 in every other case.
#
# WHY A HOOK, AND NOT A LOUDER "STOP" IN THE SKILL
#
# /wf-release and /wf-deploy already say, in so many words, that a refused
# autonomy check ends the run at the gate-open call — "STOP. Do not merge,
# push, or run step 6 or anything after it." That sentence has now been
# ignored three times by three different unattended (and once attended) runs,
# each of which opened the gate it was refused at and then pushed anyway
# (client-c WFI-032, client-d WFI-004, WFI-005). A model under a refusal
# is, structurally, the model least likely to also honour the paragraph
# telling it to stop — same shape of gap wf-guard-write.sh was built to close
# for claims, and the same fix applies: the thing about to run the command is
# the only thing positioned to check it.
#
# WHY THIS AND NOT `develop`
#
# `origin develop` is pushed constantly, by design, by work with nothing to do
# with a release or deploy in flight — /wf-verify, /wf-test and step 6 of
# /wf-release itself all push it as a routine, load-bearing step. Gating it on
# RELEASE.gate/DEPLOY.gate being open would stall every unrelated plan moving
# through the pipeline for as long as a human takes to answer one gate. Only
# `release` and `main` are pushed by anything this guard needs to stop, and
# only by /wf-release and /wf-deploy.
#
# THE INVARIANT THIS RELIES ON
#
# No LEGITIMATE path pushes `release` or `main` while its own approval gate is
# open: unattended-and-authorized never opens the gate at all, and attended
# closes any stale gate of its own name before proceeding past its y/n prompt
# (see wf-release/SKILL.md and wf-deploy/SKILL.md, "the attended path closes
# a stale gate before continuing"). Only a refused run — which is supposed to
# stop — leaves the gate open and reaches a push. If that invariant is ever
# broken by a future skill change, this guard starts blocking a real release;
# read both skills' gate-close ordering before touching either one.
#
# FAIL OPEN, ALWAYS
#
# Same posture as wf-guard-write.sh: the only path to exit 2 is a positively
# identified push of `release` or `main` while that exact branch's gate file
# is on disk. No payload, unparseable JSON, no `git push`, a push of anything
# else, no orch dir, not a repo, missing wf-orch-lib.sh — every one of those
# exits 0 and says nothing. A missed block costs a repeat of WFI-004/WFI-005,
# recoverable by hand; a wrong block costs every legitimate release.

set -uo pipefail   # deliberately NOT -e: a failing probe must allow, not block

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

# Cheap pre-filter before python3 forks: the overwhelming majority of Bash
# calls are not `git push` at all, and this is a hot path — it runs before
# every Bash tool call in the repo.
printf '%s' "$payload" | grep -q 'push' || exit 0

# Which protected branch (if any) this command pushes to `origin`. Splits the
# command on shell separators and tokenizes each piece with shlex rather than
# a hand-rolled regex — good enough for the fixed handful of push invocations
# these two skills ever write (`git push origin release`, `git push origin
# main`, each with an optional `-u`/leading flag), not a general shell parser.
# Any command this cannot confidently classify as one of those two pushes
# prints nothing, which is the same as not matching.
branch=$(printf '%s' "$payload" | python3 -c '
import json, re, shlex, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
if not isinstance(ti, dict):
    sys.exit(0)
cmd = ti.get("command") or ""
if not isinstance(cmd, str) or not cmd:
    sys.exit(0)

for piece in re.split(r"&&|\|\||;|\n", cmd):
    try:
        toks = shlex.split(piece)
    except ValueError:
        continue
    if len(toks) < 2 or toks[0] != "git" or toks[1] != "push":
        continue
    args = [t for t in toks[2:] if not t.startswith("-")]
    if "origin" not in args:
        continue
    i = args.index("origin")
    if i + 1 >= len(args):
        continue
    ref = args[i + 1].split(":")[-1]
    if ref in ("release", "main"):
        print(ref)
        break
' 2>/dev/null) || exit 0
[ -n "$branch" ] || exit 0

lib="$(dirname "$0")/wf-orch-lib.sh"
[ -f "$lib" ] || exit 0
# shellcheck source=wf-orch-lib.sh
source "$lib" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

case "$branch" in
  release) gate_id="RELEASE"; gate_name="release-approval" ;;
  main)    gate_id="DEPLOY";  gate_name="deploy-approval" ;;
esac

gate_file=$(wf_gate_file "$gate_id" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -f "$gate_file" ] || exit 0

# Confirm it's actually the promotion gate and not some future, unrelated
# gate type opened on the same fixed artifact — belt and suspenders, since
# today nothing else ever gates RELEASE or DEPLOY.
existing_name=$(wf_gate_field "$gate_file" GATE_NAME 2>/dev/null || true)
[ "$existing_name" = "$gate_name" ] || exit 0

question=$(wf_gate_field "$gate_file" GATE_QUESTION --unescape 2>/dev/null || true)

cat >&2 <<EOF
Refusing: this run's own '$gate_name' gate on $gate_id is still open — it was
refused (or not yet answered) and asked:

  $question

Pushing '$branch' now is the exact failure this gate exists to prevent
(WFI-004, WFI-005): a refusal that gets ignored. The run ends at
wf-gate-open.sh / wf-unclaim.sh, not here. If this gate DID get a real "yes"
from a human in this session, close it first:

  scripts/wf-exec.sh wf-gate-close.sh $gate_id "<their answer>"

then retry the push.
EOF
exit 2
