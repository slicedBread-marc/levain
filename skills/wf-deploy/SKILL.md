---
name: wf-deploy
description: Promote release branch to main. Mark plans complete, close bugs, back-merge to develop. Final step before production push.
user_invocable: true
model: haiku
---

# Deploy Role

You are in **deploy mode**. Your job is to promote the validated release branch to main, mark plans complete, close bugs, and back-merge to develop. This is the final pipeline step — run only after `/wf-release` has merged PRs and E2E tests have passed on the release branch.

## State context

```
plans/REGISTRY.md    → single source of truth (plans move testing → complete)
bugs/triaged/        → bugs linked to plans (move to closed/ when plan completes)
bugs/closed/         → closed bugs
release-branches/main → main's own permanent worktree, pinned by step 5
```

## Pre-flight check

Before starting, confirm E2E passed on release:

1. **`release` must exist as a ref** — it doesn't need to be checked out anywhere for this check:
   ```bash
   git rev-parse --verify release
   ```
   Steps 2 and 3 read `release` and `main` as refs too, which resolve from any worktree in the repository.
2. **Show recent release commits** so the user can confirm what's being promoted:
   ```bash
   git log --oneline release --not main -n 20
   ```
3. **If no new commits on release vs main**: inform the user there is nothing to deploy and exit.
4. **Prompt user**: "These commits will be promoted to main. Proceed? (y/n)"
   Wait for explicit confirmation before continuing.

   **Under `WF_UNATTENDED=1`, ask the config instead of the human:**
   ```bash
   scripts/wf-exec.sh wf-autonomy.sh deploy
   ```
   Exit `0` — a dated, unexpired grant covers `deploy`; name the grant and continue at step 5.
   Exit `1` or `2` — **[GATE]** `deploy-approval`, question = the commit list (exit 2: plus the
   script's stderr verbatim, because a malformed grant is a broken file, not a refusal), then exit 0.

   This authorizes promoting `release` to `main` **locally**. It does not authorize step 13's push
   to the production remote — that is a separate action with a separate grant, deliberately, because
   an unpushed `main` is still recoverable and a pushed one is somebody else's deployment.

## What you do

5. **Pin `main` to its own worktree and move into it:**
   ```bash
   eval "$(scripts/wf-exec.sh wf-worktree-pin.sh main release-branches/main)"
   cd "$WORKTREE_PATH"
   git pull origin main
   ```
   `release-branches/main` is `main`'s permanent home — created once, reused forever. Before this, `/wf-deploy` moved the *shared* develop worktree onto `main` for the duration of the run, which put `plans/REGISTRY.md` — the file the orchestrator and every other session reads — behind `main`'s older copy for as long as the deploy took, and any concurrent session standing in that same directory found itself on `main` too (client-a's WFI-135, WFI-157, WFI-213 — the last of those had a client already work around exactly this by hand, keeping `release` in its own worktree; this generalizes that shape and applies it to `main` as well). Pinning `main` here means the develop worktree — project root, wherever this session started — never moves at all. **Steps 5–10 run in `release-branches/main`**, not the project root; every command below assumes that cwd. See [`docs/release-worktrees.md`](../../docs/release-worktrees.md).
6. **Merge `release` into `main`** (auto-resolve in favor of release):
   ```bash
   git merge -X theirs --no-ff release -m "release: promote to main"
   ```
   The `-X theirs` option automatically accepts release's version of any conflicting files in `plans/`.

6a. **Check the harness survived the merge:**
   ```bash
   [ -x scripts/wf-exec.sh ] && [ -f scripts/version-map.txt ] && echo "harness ok" \
     || echo "HARNESS MISSING"
   ```
   `HARNESS MISSING` means this merge carried the commit that stops tracking the generated harness onto a branch that still tracked it, so git deleted the files — and they are gitignored, so nothing puts them back. Restore with `scripts/wf-exec.sh wf-harness-restore.sh` if the dispatcher survived — it reinstalls from the library recorded in `.claude/workflow-source` and only falls back to history, with a version check, if the library is gone. **Exit 3 means it could only find a stale harness**: treat that as unrecovered and reinstall from the library before doing anything else (WFI-119). If the dispatcher itself did not survive, use the recovery in `/wf-release` step 5a, which needs no harness. Run the same check again after step 11 returns to the develop worktree (WFI-006) — the back-merge there is a separate merge and can go stale independently.

7. **Run full test suite** (final integration check):
   ```bash
   {{build_command}} < /dev/null
   {{test_command}} < /dev/null
   ```
   If tests fail, abort the deploy — do NOT proceed to registry updates. Inform user of failures and suggest fixing on the release branch, then re-running `/wf-release`.

   **This step reads as inline and on a large project it cannot be.** A foreground Bash call is capped at 10 minutes; client-a's full suite takes about 13, so it used to be killed mid-run every time, and back when this ran in the shared develop worktree that stalled the deploy at its most dangerous point — the registry every other session read was `main`'s stale copy (WFI-213). That specific danger is gone now that `main` lives in its own worktree: a long suite here no longer touches `plans/REGISTRY.md` on develop, and the orchestrator keeps dispatching normally throughout. The 10-minute cap itself is unchanged, though — if the suite is known to exceed it, run it with `run_in_background` and **wait for it to finish before doing anything else**. That is safe here and nowhere else in the harness: `/wf-deploy` runs in a session that persists across turns, unlike the verify agent, which is killed the moment it stops producing output and must never background anything.

7a. **Sanity-check the branch before anything else commits:**
    ```bash
    git branch --show-current    # must print: main
    ```
    `release-branches/main` is pinned — nothing else in this pipeline ever checks it out to anything else, so this should always pass. If it doesn't, a human touched this worktree by hand; stop and sort that out before continuing rather than guess.
8. **Update REGISTRY.md** — for each plan that was on the release branch, verify state is `complete`. If not:
   ```bash
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN testing complete -
   ```
9. **Close linked bugs** — for each completed plan, check `plan.md` Goal for `**Bug:**` line:
   ```bash
   scripts/wf-exec.sh wf-bug-close.sh BUG-NNN PLN-NNN-<slug>
   ```
   Each call commits its own rename, both sides — leave the bug folders out of step 10's pathspec (WFI-136).

   **Run it for every completed plan that names a bug, without checking first.** `/wf-test` closes some bugs at plan completion and some it does not, with nothing in the plan telling them apart (WFI-143), so this step meets a mix. A bug that is already closed is the outcome this step wants: the script says `already closed — nothing to do` and exits 0. Do not skip the call to avoid an error, and do not treat one as a deploy failure.
10. **Commit plan updates** — name the plans this deploy actually carried, not
    `plans/PLN-*/`. That wildcard spans every concurrent worker's tree;
    `wf-commit.sh` commits the pathspec and nothing else staged (WFI-109,
    WFI-110):
    ```bash
    scripts/wf-exec.sh wf-commit.sh "release: complete <plan-names>" \
      --branch main --add plans/PLN-NNN-<slug>/plan.md
    ```
11. **Return to the develop worktree and back-merge `main` → `develop`** (auto-resolve in favor of main). Unlike steps 5–10, this one runs in the develop worktree itself — the commits `main` just received in `release-branches/main` are already visible there as local refs, no push needed:
    ```bash
    cd "$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
    git pull origin develop
    git merge -X ours main -m "sync: bring completed plans back to develop"
    ```
    The `-X ours` option automatically accepts main's version of any conflicting files in `plans/` (main has complete state).
12. **Push develop branch**:
    ```bash
    git push origin develop
    ```
    (This syncs the completed plans back to develop)

13. **Do NOT push main** — that's a separate, deliberate step:
    ```
    To deploy to production, run:
    git push origin main
    (This triggers the production deploy in GitHub Actions)
    ```

    This holds **even when `deploy` was authorized in step 4**. The local promotion and the
    production push are two grants because they are two different bets: a wrong `main` that
    never left this machine is fixed with `git reset`, and a pushed one is already running for
    users. A project that genuinely wants the push unattended says so, separately:
    ```bash
    scripts/wf-exec.sh wf-autonomy.sh production-push
    ```
    Exit `0` — run `git push origin main` and say, in the completion message, that a standing
    grant did it and which one. Anything else — print the manual instruction above and stop.
    Attended runs never call this: a human who is present is asked, not looked up.

14. **Display success**:
    ```
    ✓ Release promoted to main
    ✓ Plans marked complete
    ✓ Bugs closed
    ✓ Back-merged to develop and pushed

    NEXT: When ready to go live, manually push main:
      git push origin main
    ```
    Add a line saying what that push will actually do — see [Production deploy](#production-deploy-separate-step). Name the workflow if one deploys on `main`; say "runs CI only, nothing is deployed" if none does. Do not assert a production deploy without checking.

## Conflict resolution

Merge strategy `-X theirs` (step 6) and `-X ours` (step 11) automatically resolve conflicts:

- **release → main:** Accept release's version
- **main → develop:** Accept main's version (has REGISTRY.md updates)

Plans never move folders, so the only potential conflict is REGISTRY.md — which is tracked as of v3.2.0, and row-based precisely so that transitions to different plans auto-merge. Feature branches carry no copy (`plans/**` is excluded from every feature worktree), so conflicts can only arise between the long-lived branches this skill promotes. If a merge fails, abort and notify the user.

## Rules

- **Require confirmation** — always show what's being promoted and wait for user approval
- **E2E must have passed** — this skill assumes `/wf-release` already validated the release branch
- **Do NOT** force push — this is a main branch, use regular merge
- **Do NOT** skip back-merge — develop needs to stay in sync with main
- **Steps 5–10 run in `release-branches/main`, step 11 onward runs in the develop worktree** — step 5 pins and moves you into the former; step 11 moves you back
- **Complete all steps** — if the user interrupts, tell them which step to resume at; there is no shared checkout to leave parked, so an interruption costs nothing beyond finishing later

## On startup

1. Confirm `release` exists as a ref (`git rev-parse --verify release`) — it need not be checked out anywhere
2. Show commits on release that aren't on main
3. If new commits exist: prompt user to confirm promotion
4. If no new commits: inform user there is nothing to deploy

## Committing work

Three commits are normal:
1. Merge commit (release → main): `"release: promote to main"`
2. Plans + bugs: `"release: complete [plan-names], close bugs"`
3. Back-merge: `"sync: bring completed plans back to develop"`

If you need to resume after an interruption, tell the user which step to pick up at.

On completion, run `scripts/wf-exec.sh wf-check-reboot-flag.sh` and append any output to your completion message.

## Production deploy (separate step)

This skill does NOT push to main. After `/wf-deploy` completes:

To deploy to production, manually push main:
```bash
git push origin main
```

**Check what pushing `main` actually does before telling the user it deployed.** Not every project has a deploy workflow, and saying so when it does not is the one failure here a user cannot detect for themselves — they read "deployed to production" and stop looking.

```bash
grep -ln 'branches:.*main\|branches:$' .github/workflows/*.yml 2>/dev/null | while read -r wf; do
  printf '%s: %s\n' "$(basename "$wf")" "$(grep -m1 '^name:' "$wf" | sed 's/^name:[ ]*//')"
done
```

Then report only what is true:

- **A workflow deploys on push to `main`** — name it, and give the Logs / Live site / Health lines below.
- **Only build/test CI runs on `main`** — say exactly that: the push runs CI, and nothing is deployed. client-c has only `build.yml`, and a user following the old wording would have believed a release was live when nothing had shipped (WFI-003).
- **`{{production_url}}` is blank** — omit the Live site line entirely rather than rendering it empty. A blank value is a deliberate "this project has no production URL", not a missing config.

When there is a real deploy:
- **Logs:** {{production_logs_url}}
- **Live site:** {{production_url}} (update should be live in 2–5 minutes)
- **Health:** Check `/health` endpoint for server status
