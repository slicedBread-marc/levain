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
plans/REGISTRY.md → single source of truth (plans move testing → complete)
bugs/triaged/     → bugs linked to plans (move to closed/ when plan completes)
bugs/closed/      → closed bugs
```

## Pre-flight check

Before starting, confirm E2E passed on release:

1. **Confirm you are on the `release` branch:**
   ```bash
   scripts/wf-exec.sh wf-branch-check.sh release
   ```
2. **Show recent release commits** so the user can confirm what's being promoted:
   ```bash
   git log --oneline release --not main -n 20
   ```
3. **If no new commits on release vs main**: inform the user there is nothing to deploy and exit.
4. **Prompt user**: "These commits will be promoted to main. Proceed? (y/n)"
   Wait for explicit confirmation before continuing.

## What you do

5. **Switch to `main` branch**:
   ```bash
   git checkout main
   git pull origin main
   ```
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
   `HARNESS MISSING` means this merge carried the commit that stops tracking the generated harness onto a branch that still tracked it, so git deleted the files — and they are gitignored, so nothing puts them back. Restore with `scripts/wf-exec.sh wf-harness-restore.sh` if the dispatcher survived — it reinstalls from the library recorded in `.claude/workflow-source` and only falls back to history, with a version check, if the library is gone. **Exit 3 means it could only find a stale harness**: treat that as unrecovered and reinstall from the library before doing anything else (WFI-119). If the dispatcher itself did not survive, use the recovery in `/wf-release` step 5a, which needs no harness. Run the same check again after step 11's `git checkout develop` (WFI-006).

7. **Run full test suite** (final integration check):
   ```bash
   {{build_command}}
   {{test_command}}
   ```
   If tests fail, abort the deploy — do NOT proceed to registry updates. Inform user of failures and suggest fixing on the release branch, then re-running `/wf-release`.
8. **Update REGISTRY.md** — for each plan that was on the release branch, verify state is `complete`. If not:
   ```bash
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN testing complete -
   ```
9. **Close linked bugs** — for each completed plan, check `plan.md` Goal for `**Bug:**` line:
   ```bash
   scripts/wf-exec.sh wf-bug-close.sh BUG-NNN PLN-NNN-<slug>
   ```
10. **Commit plan and bug updates** — name the plans and bugs this deploy actually
    carried, not `plans/PLN-*/` and `bugs/closed/`. Those wildcards span every
    concurrent worker's tree; `wf-commit.sh` commits the pathspec and nothing
    else staged (WFI-109, WFI-110):
    ```bash
    scripts/wf-exec.sh wf-commit.sh "release: complete <plan-names>, close bugs" \
      --add plans/PLN-NNN-<slug>/plan.md bugs/closed/BUG-NNN-<slug>/
    ```
11. **Back-merge `main` → `develop`** (auto-resolve in favor of main):
    ```bash
    git checkout develop
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
- **Complete all steps** — if the user interrupts, provide a clear resumption point

## On startup

1. Confirm on `release` branch
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
