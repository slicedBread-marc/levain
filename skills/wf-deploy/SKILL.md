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
release-branches/main → main's own permanent worktree, pinned by step 6
```

## Pre-flight check

Before starting, confirm E2E passed on release:

1. **Claim the deploy slot:**
   ```bash
   scripts/wf-exec.sh wf-claim.sh DEPLOY
   ```
   `DEPLOY` is a fixed, singleton artifact id — there is only ever one deploy pipeline, so this
   claim excludes a second concurrent `/wf-deploy` (attended vs. attended, attended vs. the
   daemon, or daemon vs. daemon).

   | Exit | What it means | What you do |
   |-|-|-|
   | `0` | Claimed | Continue at step 2 |
   | `2` | Another live session already holds it | Tell the user who holds it (the script's output names the session) and stop. If they believe it's stuck, offer `scripts/wf-exec.sh wf-claim.sh DEPLOY --steal` |

   **From here on, whatever happens — success, test failure, "nothing to deploy," or a parked
   gate — the last thing you do before finishing is `scripts/wf-exec.sh wf-unclaim.sh DEPLOY`.**
   Every exit path below says so again at the point it applies, but the rule is unconditional:
   never leave this skill without unclaiming.

2. **`release` must exist as a ref** — it doesn't need to be checked out anywhere for this check:
   ```bash
   git rev-parse --verify release
   ```
   Steps 3 and 4 read `release` and `main` as refs too, which resolve from any worktree in the repository.
3. **Show recent release commits** so the user can confirm what's being promoted:
   ```bash
   git log --oneline release --not main -n 20
   ```
4. **If no new commits on release vs main**: inform the user there is nothing to deploy. **If this is an attended run** (`WF_UNATTENDED` unset), also close a stale `deploy-approval` gate before unclaiming — nothing being left to deploy means whatever that gate asked about was already promoted or abandoned by some other path, and a human running this attended is exactly the moment to clear it rather than leave it for `/wf-attend` to notice later (client-c WFI-031: an unattended dispatch kept reopening `deploy-approval` for a commit already the tip of `main`, because nothing ever told the gate the promotion had happened — this closes that gap the next time a human is actually here to answer for it):
   ```bash
   if [ "${WF_UNATTENDED:-0}" != "1" ] \
      && scripts/wf-exec.sh wf-list-gates.sh DEPLOY 2>/dev/null | grep -q "$(printf '\t')deploy-approval$(printf '\t')"; then
     scripts/wf-exec.sh wf-gate-close.sh DEPLOY "nothing left to deploy — already up to date"
   fi
   ```
   Then unclaim (`scripts/wf-exec.sh wf-unclaim.sh DEPLOY`) and exit.
4a. **Check for open deferred criteria on the plans being promoted:**
   ```bash
   scripts/wf-exec.sh wf-deferred-check.sh $(git log --oneline release --not main | grep -oE 'PLN-[0-9]+' | sort -u)
   ```
   Exit `0` — nothing open, continue. Exit `1` — print its output to the user before the confirmation
   prompt below: these are `external`/`soak`/`unbuilt` criteria that plan shipped without,
   read from `plans/deferred-criteria.md`. Most are harmless (a soak period, a future
   integration test) — but some describe a hard runtime dependency (a secret, a certificate, a
   required external service) that will crash the app in production if it's still missing. This
   check cannot tell the two apart; a human or grant has to. client-c's DC-014 was exactly
   the dangerous kind and went unread straight into a production crash-loop (WFI-011) — don't
   let this step become the same silent skip.
5. **Prompt user**: "These commits will be promoted to main. Proceed? (y/n)"
   Wait for explicit confirmation before continuing.

   **Under `WF_UNATTENDED=1`**, see "Unattended mode" below — it replaces this confirmation with
   a standing-grant check and a concrete `deploy-approval` gate, then either continues at step 6
   or exits.

## What you do

6. **Pin `main` to its own worktree and move into it:**
   ```bash
   eval "$(scripts/wf-exec.sh wf-worktree-pin.sh main release-branches/main)"
   cd "$WORKTREE_PATH"
   git pull origin main
   ```
   `release-branches/main` is `main`'s permanent home — created once, reused forever. Before this, `/wf-deploy` moved the *shared* develop worktree onto `main` for the duration of the run, which put `plans/REGISTRY.md` — the file the orchestrator and every other session reads — behind `main`'s older copy for as long as the deploy took, and any concurrent session standing in that same directory found itself on `main` too (client-a's WFI-135, WFI-157, WFI-213 — the last of those had a client already work around exactly this by hand, keeping `release` in its own worktree; this generalizes that shape and applies it to `main` as well). Pinning `main` here means the develop worktree — project root, wherever this session started — never moves at all. **Steps 6–11 run in `release-branches/main`**, not the project root; every command below assumes that cwd. See [`docs/release-worktrees.md`](../../docs/release-worktrees.md).
7. **Merge `release` into `main`** (auto-resolve in favor of release):
   ```bash
   git merge -X theirs --no-ff release -m "release: promote to main"
   ```
   The `-X theirs` option automatically accepts release's version of any conflicting files in `plans/`.

7a. **Check the harness survived the merge:**
   ```bash
   [ -x scripts/wf-exec.sh ] && [ -f scripts/version-map.txt ] && echo "harness ok" \
     || echo "HARNESS MISSING"
   ```
   `HARNESS MISSING` means this merge carried the commit that stops tracking the generated harness onto a branch that still tracked it, so git deleted the files — and they are gitignored, so nothing puts them back. Restore with `scripts/wf-exec.sh wf-harness-restore.sh` if the dispatcher survived — it reinstalls from the library recorded in `.claude/workflow-source` and only falls back to history, with a version check, if the library is gone. **Exit 3 means it could only find a stale harness**: treat that as unrecovered and reinstall from the library before doing anything else (WFI-119). If the dispatcher itself did not survive, use the recovery in `/wf-release` step 6a, which needs no harness. Run the same check again after step 12 returns to the develop worktree (WFI-006) — the back-merge there is a separate merge and can go stale independently.

8. **Run full test suite** (final integration check):
   ```bash
   {{build_command}} < /dev/null
   {{test_command}} < /dev/null
   ```
   If tests fail, abort the deploy — do NOT proceed to registry updates. Inform user of failures (and, under `WF_UNATTENDED=1`, unclaim) and suggest fixing on the release branch, then re-running `/wf-release`.

   **This step reads as inline and on a large project it cannot be.** A foreground Bash call is capped at 10 minutes; client-a's full suite takes about 13, so it used to be killed mid-run every time, and back when this ran in the shared develop worktree that stalled the deploy at its most dangerous point — the registry every other session read was `main`'s stale copy (WFI-213). That specific danger is gone now that `main` lives in its own worktree: a long suite here no longer touches `plans/REGISTRY.md` on develop, and the orchestrator keeps dispatching normally throughout. The 10-minute cap itself is unchanged, though — if the suite is known to exceed it, run it with `run_in_background` and **wait for it to finish before doing anything else**. That is safe here and nowhere else in the harness: `/wf-deploy` runs in a session that persists across turns, unlike the verify agent, which is killed the moment it stops producing output and must never background anything.

8a. **Sanity-check the branch before anything else commits:**
    ```bash
    git branch --show-current    # must print: main
    ```
    `release-branches/main` is pinned — nothing else in this pipeline ever checks it out to anything else, so this should always pass. If it doesn't, a human touched this worktree by hand; stop and sort that out before continuing rather than guess.
9. **Update REGISTRY.md** — for each plan that was on the release branch, verify state is `complete`. If not:
   ```bash
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN testing complete -
   ```
10. **Close linked bugs** — for each completed plan, check `plan.md` Goal for `**Bug:**` line:
   ```bash
   scripts/wf-exec.sh wf-bug-close.sh BUG-NNN PLN-NNN-<slug>
   ```
   Each call commits its own rename, both sides — leave the bug folders out of step 11's pathspec (WFI-136).

   **Run it for every completed plan that names a bug, without checking first.** `/wf-test` closes some bugs at plan completion and some it does not, with nothing in the plan telling them apart (WFI-143), so this step meets a mix. A bug that is already closed is the outcome this step wants: the script says `already closed — nothing to do` and exits 0. Do not skip the call to avoid an error, and do not treat one as a deploy failure.

   **The general sweep for cross-run orphans runs later, in step 12a — not here.** `wf-bug-close-sweep.sh` always operates on the develop worktree (`wf_develop_root()`), regardless of cwd. Calling it here, while still in `release-branches/main` and before step 12's back-merge, means develop still shows the bugs this step just closed in main as untouched — the sweep would "find" them, genuinely re-close them a second time, and commit that redundant close directly onto develop instead of letting it arrive via the back-merge (WFI-025). Wait for develop to actually be in sync with main before sweeping it.
11. **Commit plan updates** — name the plans this deploy actually carried, not
    `plans/PLN-*/`. That wildcard spans every concurrent worker's tree;
    `wf-commit.sh` commits the pathspec and nothing else staged (WFI-109,
    WFI-110):
    ```bash
    scripts/wf-exec.sh wf-commit.sh "release: complete <plan-names>" \
      --branch main --add plans/PLN-NNN-<slug>/plan.md
    ```
12. **Return to the develop worktree and back-merge `main` → `develop`** (auto-resolve in favor of main). Unlike steps 6–11, this one runs in the develop worktree itself — the commits `main` just received in `release-branches/main` are already visible there as local refs, no push needed:
    ```bash
    cd "$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
    git pull origin develop
    git merge -X ours main -m "sync: bring completed plans back to develop"
    ```
    The `-X ours` option automatically accepts main's version of any conflicting files in `plans/` (main has complete state).
12a. **Now run the general bug-close sweep** — develop is caught up with main as of step 12, so this correctly sees only genuine cross-run orphans (a bug whose link was never acted on before its own close step existed, or an earlier deploy that skipped it on error — client-c's WFI-017 found two, each a full deploy cycle stale) and not the bugs step 10 just closed:
    ```bash
    scripts/wf-exec.sh wf-bug-close-sweep.sh --apply
    ```
    Still in the develop worktree from step 12 — do not run this in `release-branches/main`. Read-only without `--apply`, for a standalone check outside a deploy (`/wf-status` can point to it the same way this repo's own `check-profiles.sh` and `sweep-issues.sh` are pointed to). Any bug it closes here needs its own commit pushed with develop in step 13, so run it before that push, not after.
13. **Push develop branch**:
    ```bash
    git push origin develop
    ```
    (This syncs the completed plans back to develop)

14. **Do NOT push main** — that's a separate, deliberate step:
    ```
    To deploy to production, run:
    git push origin main
    (This triggers the production deploy in GitHub Actions)
    ```

    This holds **even when `deploy` was authorized in step 5**. The local promotion and the
    production push are two grants because they are two different bets: a wrong `main` that
    never left this machine is fixed with `git reset`, and a pushed one is already running for
    users. A project that genuinely wants the push unattended says so, separately:
    ```bash
    scripts/wf-exec.sh wf-autonomy.sh production-push
    ```
    Exit `0` — run `git push origin main` and say, in the completion message, that a standing
    grant did it and which one. Anything else — print the manual instruction above and stop.
    Attended runs never call this: a human who is present is asked, not looked up.

15. **Unclaim, then display success:**
    ```bash
    scripts/wf-exec.sh wf-unclaim.sh DEPLOY
    ```
    ```
    ✓ Release promoted to main
    ✓ Plans marked complete
    ✓ Bugs closed
    ✓ Back-merged to develop and pushed

    NEXT: When ready to go live, manually push main:
      git push origin main
    ```
    Add a line saying what that push will actually do — see [Production deploy](#production-deploy-separate-step). Name the workflow if one deploys on `main`; say "runs CI only, nothing is deployed" if none does. Do not assert a production deploy without checking.

## Unattended mode

Set when `WF_UNATTENDED=1` — the daemon dispatched this run against the fixed `DEPLOY` artifact.

- **Stand down quietly if already claimed**, before doing anything else:
  ```bash
  scripts/wf-exec.sh wf-claim.sh DEPLOY --if-free
  ```
  Exit `2` → print nothing but a log line and exit 0. A human or another worker already holds
  `DEPLOY`; this is not a failure, just a lost race.
- **Skip step 5's confirmation prompt.** In its place, check for standing authorization:
  ```bash
  scripts/wf-exec.sh wf-autonomy.sh deploy
  ```
  | Exit | What it means | What you do |
  |-|-|-|
  | `0` | A dated, unexpired grant covers `deploy` | Name the grant, continue at step 6 |
  | `1` or `2` | No grant, or malformed | Open the gate below (exit 2: include the script's stderr verbatim — a malformed grant is a broken file, not a refusal), then unclaim and exit 0 — **STOP. Do not merge, push, or run step 6 or anything after it.** |

  ```bash
  scripts/wf-exec.sh wf-gate-open.sh DEPLOY deploy-approval "<commit list from step 3>" --skill wf-deploy
  scripts/wf-exec.sh wf-unclaim.sh DEPLOY
  ```
  `wf-gate-open.sh` exiting 3 means `deploy-approval` already has an answer of record — act on it
  rather than re-asking, per the standing gate-reopening rule.

  **This run is finished the moment `wf-unclaim.sh DEPLOY` above returns — nothing else in this
  document is a next step for exit `1` or `2`.** client-c's WFI-032 saw a RELEASE worker do
  exactly this wrong at the matching check in `/wf-release`: refuse, open the gate, then continue
  on to merge and push anyway before exiting `rc=0`. Refusing here and then promoting `release` to
  `main` regardless makes the gate theater — a refusal ends the run at the `wf-unclaim.sh` call
  above, full stop, never at step 6 or anywhere past it.

  This authorizes promoting `release` to `main` **locally only**. It never authorizes step 14's
  push to the production remote — that step still looks up `production-push` separately, and an
  unattended run that gets `0` there pushes and says so; anything else, it leaves `main` unpushed
  and reports that in the completion message, same as an attended run.

  **Step 14 never opens a gate, in either outcome.** A deploy that reaches step 14 has already
  succeeded — `deploy-approval` (or a standing `deploy` grant) already covers everything this run
  did. The production push is deliberately a *second*, separate grant (`production-push`), not a
  second approval of the same work, and "no grant for it" is not a blocked or parked state — it's
  the designed default: finish normally, report the deploy as complete, and say the push is still
  manual. Re-opening `deploy-approval` here — reusing its name, or replaying its original
  step-3 commit list as the question — parks a *finished* deploy behind a gate that describes
  work already done, and the next `deploy-approval` answer frees a dispatch that finds nothing
  left to do but hit this same non-gate again (client-c WFI-029). Nothing in the "resolve
  every other gate" bullet below applies to step 14; it is not a would-ask-a-human point, it is a
  documented no-op.
- **Resolve every other `[GATE]` or would-ask-a-human point in the steps above the same way** —
  open a gate naming the question, unclaim, and exit 0. Never guess, never hang.
- **On every exit path** — grant found and the run proceeds to completion, gate opened, or an
  error stops the run early — `scripts/wf-exec.sh wf-unclaim.sh DEPLOY` is the last action before
  finishing.

## Conflict resolution

Merge strategy `-X theirs` (step 7) and `-X ours` (step 12) automatically resolve conflicts:

- **release → main:** Accept release's version
- **main → develop:** Accept main's version (has REGISTRY.md updates)

Plans never move folders, so the only potential conflict is REGISTRY.md — which is tracked as of v3.2.0, and row-based precisely so that transitions to different plans auto-merge. Feature branches carry no copy (`plans/**` is excluded from every feature worktree), so conflicts can only arise between the long-lived branches this skill promotes. If a merge fails, abort and notify the user.

## Rules

- **Claim `DEPLOY` before touching anything, unclaim before finishing** — step 1 claims it; every exit path, success or failure, ends with `wf-unclaim.sh DEPLOY`
- **Require confirmation** — always show what's being promoted and wait for user approval
- **E2E must have passed** — this skill assumes `/wf-release` already validated the release branch
- **Do NOT** force push — this is a main branch, use regular merge
- **Do NOT** skip back-merge — develop needs to stay in sync with main
- **Steps 6–11 run in `release-branches/main`, step 12 onward runs in the develop worktree** — step 6 pins and moves you into the former; step 12 moves you back
- **Complete all steps** — if the user interrupts, tell them which step to resume at; there is no shared checkout to leave parked, so an interruption costs nothing beyond finishing later

## On startup

1. Claim `DEPLOY` (step 1)
2. Confirm `release` exists as a ref (`git rev-parse --verify release`) — it need not be checked out anywhere
3. Show commits on release that aren't on main
4. If new commits exist: prompt user to confirm promotion
5. If no new commits: inform user there is nothing to deploy, unclaim

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
