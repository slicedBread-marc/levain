#!/usr/bin/env bash
# wf-guard-promote.sh — PreToolUse guard: refuse the git actions that promote
# `release` or `main` while that branch's own promotion gate is still open.
#
# Wired to PreToolUse on Bash by templates/hooks/settings-merge.py. Reads the
# hook payload on stdin and exits 2 (block, message to the model) for four
# specific commands, each identified with the exact branch/ref it names:
#
#   git push origin release                    while RELEASE.gate exists
#   git push origin main                        while DEPLOY.gate exists
#   git merge ... release ...   (wf-deploy §7)   while DEPLOY.gate exists
#   git merge ... main ...      (wf-deploy §12)  while DEPLOY.gate exists
#
# Exits 0 in every other case.
#
# WHY A HOOK, AND NOT A LOUDER "STOP" IN THE SKILL
#
# /wf-release and /wf-deploy already say, in so many words, that a refused
# autonomy check ends the run at the gate-open call — "STOP. Do not merge,
# push, or run step 6 or anything after it." That sentence has now been
# ignored four times across three different runs, each of which opened the
# gate it was refused at and then acted anyway (client-c WFI-032,
# client-d WFI-004, WFI-005, WFI-034). A model under a refusal is,
# structurally, the model least likely to also honour the paragraph telling it
# to stop — same shape of gap wf-guard-write.sh was built to close for claims,
# and the same fix applies: the thing about to run the command is the only
# thing positioned to check it.
#
# WHY BOTH THE PUSH *AND* THE MERGE
#
# The first cut of this guard only blocked the push. WFI-034 (client-c)
# showed why that was not enough: a deploy worker refused `deploy`, opened
# `deploy-approval`, then ran step 7's LOCAL merge of `release` into `main`
# (never pushed — `main` isn't pushed automatically by design) and step 12's
# back-merge of that now-corrupted `main` into `develop` — which IS pushed,
# routinely, by design. The bad promotion never touched `origin/main`, but it
# reached `origin/develop` anyway, through the one branch this guard
# deliberately never gates. Blocking the two merges themselves closes that
# path at its source instead of trying to catch it downstream on a branch
# this guard cannot afford to gate broadly.
#
# WHY NOT `develop` ITSELF
#
# `origin develop` is pushed constantly, by design, by work with nothing to do
# with a release or deploy in flight — /wf-verify, /wf-test and step 6 of
# /wf-release itself all push it as a routine, load-bearing step. Gating it on
# RELEASE.gate/DEPLOY.gate being open would stall every unrelated plan moving
# through the pipeline for as long as a human takes to answer one gate. The
# four commands above are the actual leak points; `develop` itself is not one
# of them once those four are closed.
#
# THE INVARIANT THIS RELIES ON
#
# No LEGITIMATE path pushes `release`/`main` or runs either merge while its
# own approval gate is open: unattended-and-authorized never opens the gate at
# all, and attended closes any stale gate of its own name before proceeding
# past its y/n prompt (see wf-release/SKILL.md and wf-deploy/SKILL.md, step 5,
# "close a stale gate before continuing"). Only a refused run — which is
# supposed to stop — leaves the gate open and reaches one of these four. If
# that invariant is ever broken by a future skill change, this guard starts
# blocking a real release; read both skills' gate-close ordering before
# touching either one.
#
# FAIL OPEN, ALWAYS
#
# Same posture as wf-guard-write.sh: the only path to exit 2 is a positively
# identified instance of one of the four commands above while that exact
# gate's file is on disk. No payload, unparseable JSON, no matching command,
# no orch dir, not a repo, missing wf-orch-lib.sh — every one of those exits 0
# and says nothing. A missed block costs a repeat of a known WFI; a wrong
# block costs every legitimate release.
#
# WFI-006: THREE MORE LEAK POINTS, ONE OF THEM WITH NO GUARD AT ALL
#
# client-d probed the first cut of this guard with variants of its own
# blocked commands and found three gaps:
#
#   1. `git -C <dir> push origin release` was allowed, because the parser
#      only ever looked at the token right after `git` for "push"/"merge" —
#      `-C` sits there instead. Fixed by walking past git's own global
#      options (tracking any `-C` override) to find the real subcommand,
#      wherever it lands.
#   2. Bare `git push` (current branch to its configured upstream) and
#      `git push origin HEAD` (current branch, by name, to a same-named ref)
#      were both allowed, because neither literally spells "release" or
#      "main" in the command line. Fixed by asking git itself — at the
#      resolved cwd, honouring any `-C`/`cd` in the same command — what the
#      upstream or current branch actually is, and matching on that.
#   3. RELEASE.gate had no merge protection at all. /wf-deploy's two merges
#      are always named `git merge ... release ...` / `git merge ... main
#      ...`, so matching the literal ref text happened to work for DEPLOY.
#      But /wf-release's own promoting step is `git merge origin/develop
#      --no-edit` run *while checked out on release* — the ref being merged
#      IN is `origin/develop`, never "release", so the old text match could
#      never have caught it. A refused release worker that ran this step
#      anyway advanced local `release` without ever touching a push, which
#      wf-guard-promote had no way to see (client-d WFI-005) — and a
#      dispatcher that reads the pinned release worktree's own branch state
#      then finds a deploy newly eligible, despite the refusal.
#
#      The fix is the general form of the invariant this guard already
#      relies on: a merge advances whatever branch is CURRENTLY CHECKED OUT,
#      never the ref named on the command line — that ref is only ever the
#      thing being merged in. So merge detection asks git which branch is
#      checked out at the resolved cwd and gates on THAT: `release` maps to
#      RELEASE.gate, `main` to DEPLOY.gate, anything else is untouched. This
#      also covers /wf-deploy's two merges without needing their literal ref
#      text, and does not touch `git pull`, which never appears in either
#      skill's promotion path and cannot advance a branch past what a gate
#      already approved on origin.
#
# THE FALLBACK ARM AND THE ONE FALSE POSITIVE IT CAUSED
#
# The ref-text fallback below stayed, for the merges the checkout probe cannot
# see, and its mapping was wrong: it read `git merge ... release ...` as a
# RELEASE action. That command is /wf-deploy STEP 7 — release promoted into
# main — which is a DEPLOY action, and the probe misses it whenever the hook
# payload's cwd is still the project root rather than `release-branches/main`
# (the skill `cd`s there in step 6, a separate tool call). So an approved
# deploy's merge into `main` was refused by whatever release-approval gate
# happened to be parked — and one is parked most of the time, because a
# refused release worker leaves one behind. Both fallback arms are DEPLOY now;
# see the mapping note further down for why nothing is lost.
#
# The git lookups this adds (current branch, upstream ref) fail closed to
# "cannot tell" the same way everything else here does — an error or timeout
# returns None, which matches nothing, which allows. They run at most once
# per push/merge already found in a command already past the push|merge
# grep prefilter, not on every Bash call.

set -uo pipefail   # deliberately NOT -e: a failing probe must allow, not block

payload=$(</dev/stdin)
[ -n "$payload" ] || exit 0

# Cheap pre-filter before python3 forks: the overwhelming majority of Bash
# calls are neither `git push` nor `git merge` — this is a hot path, running
# before every Bash tool call in the repo.
#
# Both the read and the filter are bash builtins on purpose. `$(cat)` piped
# into `grep -qE` is three forks, paid by every Bash call in the project to
# answer a question a glob settles for free, and the overwhelming majority of
# those calls bail on the very next line.
[[ "$payload" == *push* || "$payload" == *merge* ]] || exit 0

# Classify the command as one of the four protected actions, if it is one.
# Splits on shell separators and tokenizes each piece with shlex rather than a
# hand-rolled regex — good enough for the fixed handful of push/merge
# invocations these two skills ever write, not a general shell parser. Tracks
# `cd` across pieces and `-C` within a git invocation to know where each git
# call actually runs, and asks git itself for current-branch/upstream facts
# it cannot get from the command line alone (WFI-006). Prints "<action>:<ref>"
# (e.g. "push:release", "merge:main") or nothing.
action=$(printf '%s' "$payload" | python3 -c '
import json, os, re, shlex, subprocess, sys
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
base_cwd = d.get("cwd")
if not isinstance(base_cwd, str) or not base_cwd:
    base_cwd = "."

# Flags that consume the following token as their own value, so it is never
# mistaken for a positional arg — `-X theirs`, `-m "message"`.
VALUE_FLAGS = {"-X", "-s", "-m", "-F", "--strategy", "--strategy-option"}
# Global git options (before the subcommand) that also take a value.
GLOBAL_VALUE_FLAGS = {"-c", "--git-dir", "--work-tree", "--namespace", "--exec-path"}

def first_positional(toks):
    i = 0
    while i < len(toks):
        t = toks[i]
        if t in VALUE_FLAGS:
            i += 2
            continue
        if t.startswith("-"):
            i += 1
            continue
        return t
    return None

def branch_at(path):
    # Current branch checked out at `path`, or None on any failure — every
    # caller treats None as "cannot tell", which allows rather than blocks.
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD"],
                            capture_output=True, text=True, timeout=2)
        return r.stdout.strip() or None if r.returncode == 0 else None
    except Exception:
        return None

def upstream_at(path):
    # "origin/release" etc for the branch checked out at `path`, or None.
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--abbrev-ref",
                             "--symbolic-full-name", "@{u}"],
                            capture_output=True, text=True, timeout=2)
        return r.stdout.strip() or None if r.returncode == 0 else None
    except Exception:
        return None

cur_dir = base_cwd
for piece in re.split(r"&&|\|\||;|\n", cmd):
    try:
        toks = shlex.split(piece)
    except ValueError:
        continue
    if not toks:
        continue

    if toks[0] == "cd":
        target = next((t for t in toks[1:] if not t.startswith("-")), None)
        if target and target != "-":
            cur_dir = target if os.path.isabs(target) else os.path.join(cur_dir, target)
        continue

    if toks[0] != "git":
        continue

    # Walk past git'"'"'s own global options to find the real subcommand —
    # `git -C foo push ...` has it at index 2, not 1 — tracking any `-C`
    # override the same way git itself would apply it.
    i, dir_override = 1, None
    while i < len(toks):
        t = toks[i]
        if t == "-C":
            if i + 1 < len(toks):
                base = dir_override if dir_override is not None else cur_dir
                nxt = toks[i + 1]
                dir_override = nxt if os.path.isabs(nxt) else os.path.join(base, nxt)
            i += 2
            continue
        if t in GLOBAL_VALUE_FLAGS:
            i += 2
            continue
        if t.startswith("--") and "=" in t:
            i += 1
            continue
        if t.startswith("-"):
            i += 1
            continue
        break
    if i >= len(toks):
        continue
    subcmd, rest = toks[i], toks[i + 1:]
    effective_dir = dir_override if dir_override is not None else cur_dir

    if subcmd == "push":
        args = [t for t in rest if not t.startswith("-")]
        ref = None
        if "origin" in args:
            j = args.index("origin")
            if j + 1 < len(args):
                ref = args[j + 1].split(":")[-1]
        elif not args:
            # Bare `git push` — goes to the current branch'"'"'s upstream.
            u = upstream_at(effective_dir)
            if u and "/" in u:
                remote, _, branch = u.partition("/")
                if remote == "origin":
                    ref = branch
        if ref == "HEAD":
            ref = branch_at(effective_dir)
        if ref in ("release", "main"):
            print(f"push:{ref}")
            break

    elif subcmd == "merge":
        # A merge advances the CURRENT branch — catches /wf-release'"'"'s own
        # promoting step (checked out on release, merging in origin/develop,
        # which never names "release" on the command line at all) and
        # /wf-deploy'"'"'s release-into-main step the same way.
        b = branch_at(effective_dir)
        if b in ("release", "main"):
            print(f"merge-into:{b}")
            break
        # Fallback: the ref text itself names a protected branch, for the two
        # /wf-deploy merges whose advanced branch this cannot see — step 7 when
        # the cwd probe misses, and step 12'"'"'s back-merge, which lands on
        # develop. Both are DEPLOY actions; see the mapping note below.
        ref = first_positional(rest)
        if ref in ("release", "main"):
            print(f"merge-ref:{ref}")
            break
' 2>/dev/null) || exit 0
[ -n "$action" ] || exit 0

kind="${action%%:*}"
ref="${action#*:}"

lib="$(dirname "$0")/wf-orch-lib.sh"
[ -f "$lib" ] || exit 0
# shellcheck source=wf-orch-lib.sh
source "$lib" 2>/dev/null || exit 0

git rev-parse --git-dir >/dev/null 2>&1 || exit 0

# WHICH GATE OWNS WHICH COMMAND
#
# `push:<ref>` is the pushed ref, named on the command line: `release` is
# /wf-release's promotion, `main` is /wf-deploy's production push.
#
# `merge-into:<branch>` is the branch a merge ACTUALLY advances, read from the
# checkout. Advancing `release` is /wf-release step 6; advancing `main` is
# /wf-deploy step 7. Those are the two skills' own promotions, so each maps to
# its own gate.
#
# `merge-ref:<ref>` is the fallback — the ref text, used only when the
# current-branch probe could not name a protected branch. BOTH arms are DEPLOY
# actions, and getting that wrong is what this mapping was fixed for:
#
#   · `git merge -X theirs --no-ff release` is /wf-deploy STEP 7, promoting
#     release into main. Nothing in the harness ever merges `release` into
#     anything else. The old table read that as a RELEASE action and gated it
#     on RELEASE.gate — so with a release-approval gate parked (the normal
#     resting state whenever a release worker is refused), an already-approved
#     deploy's merge into `main` was refused by an unrelated gate. There is no
#     true positive on that arm to lose: a merge that advances `release`
#     itself is /wf-release step 6, which `merge-into:release` above already
#     catches by the checkout, never by this ref text.
#   · `git merge -X ours main` is /wf-deploy STEP 12's back-merge. It lands on
#     develop, so no `merge-into` arm can see it; the danger is pulling an
#     unapproved `main` INTO develop, which the literal ref name does catch.
case "$kind:$ref" in
  push:release)       gate_id="RELEASE"; gate_name="release-approval" ;;
  # Either DEPLOY gate forbids the push: `deploy-approval` because the batch
  # was never cleared, `production-push` because the push itself was asked
  # about and is not yet answered (coordinator WFI-008).
  push:main)          gate_id="DEPLOY";  gate_name="deploy-approval production-push" ;;
  merge-into:release) gate_id="RELEASE"; gate_name="release-approval" ;;
  merge-into:main)    gate_id="DEPLOY";  gate_name="deploy-approval" ;;
  merge-ref:release)  gate_id="DEPLOY";  gate_name="deploy-approval" ;;
  merge-ref:main)     gate_id="DEPLOY";  gate_name="deploy-approval" ;;
esac

gate_file=$(wf_gate_file "$gate_id" 2>/dev/null); rc=$?
[ "$rc" -eq 0 ] && [ -f "$gate_file" ] || exit 0

# Confirm it's actually the promotion gate and not some future, unrelated
# gate type opened on the same fixed artifact — belt and suspenders, since
# today nothing else ever gates RELEASE or DEPLOY.
existing_name=$(wf_gate_field "$gate_file" GATE_NAME 2>/dev/null || true)
case " $gate_name " in *" $existing_name "*) gate_name="$existing_name" ;; *) exit 0 ;; esac

question=$(wf_gate_field "$gate_file" GATE_QUESTION --unescape 2>/dev/null || true)

case "$kind" in
  push)       what="Pushing '$ref' now" ;;
  merge-into) what="Merging into '$ref' now" ;;
  merge-ref)  what="Merging '$ref' now" ;;
esac

cat >&2 <<EOF
Refusing: this run's own '$gate_name' gate on $gate_id is still open — it was
refused (or not yet answered) and asked:

  $question

$what is the exact failure this gate exists to prevent (WFI-004, WFI-005,
WFI-034): a refusal that gets ignored. The run ends at wf-gate-open.sh /
wf-unclaim.sh, not here. If this gate DID get a real "yes" from a human in
this session, close it first:

  scripts/wf-exec.sh wf-gate-close.sh $gate_id "<their answer>"

then retry.
EOF
exit 2
