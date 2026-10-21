---
name: lv-deploy
description: Promote release branch to main. Mark plans complete, close bugs, back-merge to develop. Final step before production push.
user_invocable: true
model: haiku
---

# Deploy Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are in **deploy mode**. Your job is to promote the validated release branch to main, mark plans complete, close bugs, and back-merge to develop. This is the final pipeline step — run only after `/lv-release` has merged PRs and E2E tests have passed on the release branch.

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
   scripts/lv-exec.sh lv-claim.sh DEPLOY
   ```
   `DEPLOY` is a fixed, singleton artifact id — there is only ever one deploy pipeline, so this
   claim excludes a second concurrent `/lv-deploy` (attended vs. attended, attended vs. the
   daemon, or daemon vs. daemon).

   | Exit | What it means | What you do |
   |-|-|-|
   | `0` | Claimed | Continue at step 2 |
   | `2` | Another live session already holds it | Tell the user who holds it (the script's output names the session) and stop. If they believe it's stuck, offer `scripts/lv-exec.sh lv-claim.sh DEPLOY --steal` |

   **From here on, whatever happens — success, test failure, "nothing to deploy," or a parked
   gate — the last thing you do before finishing is `scripts/lv-exec.sh lv-unclaim.sh DEPLOY`.**
   Every exit path below says so again at the point it applies, but the rule is unconditional:
   never leave this skill without unclaiming.

2. **`release` must exist as a ref** — it doesn't need to be checked out anywhere for this check:
   ```bash
   git rev-parse --verify release
   ```
   Steps 3 and 4 read `release` and `main` as refs too, which resolve from any worktree in the repository.

2a. **Make the local `release` ref agree with `origin/release` before reading it.** Everything
   below treats `release --not main` as "commits that passed E2E", and that is only true of
   commits `/lv-release` actually pushed — it pushes *after* its suite passes, and never before.
   The local ref is not automatically those commits: `release` lives in its own long-lived
   worktree this session never enters, so it holds whatever the last run *in this checkout* left
   there. Ask the script, do not hand-roll the comparison:
   ```bash
   scripts/lv-exec.sh lv-release-sync.sh; echo "sync exit=$?"
   ```

   | Exit | What it means | What you do |
   |-|-|-|
   | `0` | Local `release` equals `origin/release` — already, or it was just fast-forwarded (the script says which). | Continue at step 3 |
   | `2` | Local is **ahead** — unpushed commits no E2E run validated | **Stop.** Name what is unpushed, point the user at `scripts/lv-exec.sh lv-release-rollback.sh` or at re-running `/lv-release`, then unclaim and exit |
   | `3` | Local and `origin/release` have **diverged** | **Stop.** Report both tips; this needs a human. Unclaim and exit |
   | `1` | The answer could not be established (no `origin/release`, dirty release worktree, fast-forward refused) | **Stop.** Quote its stderr, unclaim and exit |

   **Every non-zero exit is a hard stop** — do not prompt, do not open a gate, and under
   `LV_UNATTENDED=1` do not proceed on any grant. A standing grant authorizes promoting a
   validated batch; it does not make this one validated.

   Both directions of that disagreement have shipped a wrong deploy. Ahead: client-b WFI-007 —
   30 commits reached a `deploy-approval` gate quoted as ready for production, over a suite that
   was red 1/117. Behind: client-a WFI-258 — an unattended run merged a local `release` that
   was **34 commits behind** `origin/release`, ran the full suite green on that stale tree, pushed
   `main`, and reported "15 commits promoted (PLN-273 work)" while PLN-273 stayed out of
   production. Nothing else catches the behind case: the stale tree builds, the suite passes, and
   the completion message names plans the merge never carried.

   It also fetches `origin/main` and prints `DEPLOY_BASE=origin/main (<sha>)` before every exit.
   **That is the ref every count and every plan list below is taken against — not local `main`.**
   Local `main` is what the promotion merges *into*, and between step 7 and step 14 it legitimately
   holds commits production does not; a previous run that stopped in that window leaves them there
   until step 6a recovers, which happens *after* the gate. client-a WFI-264: the deferred-criteria
   question put to a human quoted "205 commits" off a local `main` carrying an unrecovered promote
   merge. The real batch was 353 commits and 15 plans. Set it once and use it:
   ```bash
   BASE=origin/main; git rev-parse --verify -q "$BASE" >/dev/null || BASE=main
   ```

2b. **Has this exact batch already failed the deploy suite?**
   ```bash
   scripts/lv-exec.sh lv-deploy-suite-memo.sh --check; echo "memo exit=$?"
   ```
   Exit `0` — no record for this release tip; continue at step 3. Exit `1` — a previous deploy
   already merged these same commits and ran the whole suite red. **Do not run it again.** The
   tip cannot pass until something lands on `release`, and landing on `release` moves the tip,
   which clears this by construction. Report the recorded `MEMO_SUMMARY=` and `MEMO_LOG=` lines
   verbatim, then:
   - **Attended**: tell the user which test failed and that the fix belongs on a feature branch
     (`/lv-bug` it if there is no plan for it yet). Unclaim and exit.
   - **Unattended** (`LV_UNATTENDED=1`): open gate `deploy-suite-red` with the summary as the
     question, then unclaim and exit 0.

   client-a, 2026-09-18: three deploys at 18:36, 19:03 and 19:25, each merging the identical
   commits, each running a ~20-minute suite, each failing the same single test of 3,339, each
   recovering `main`. An hour of compute to learn one fact three times, and DEPLOY then parked
   `stuck` knowing no more than the first run had. Nothing was wrong with any of those runs; what
   was missing was a memory between them.
3. **Show recent release commits** so the user can confirm what's being promoted:
   ```bash
   TOTAL=$(git rev-list --count release --not $BASE)
   git log --oneline release --not $BASE -n 20
   if [ "$TOTAL" -gt 20 ]; then echo "…and $((TOTAL - 20)) more ($TOTAL commits total)"; fi
   ```
   **Always carry the total with the list.** `-n 20` is a display convenience, not the
   promotion — everything in the range ships whether or not it was printed. A bare truncated
   list reads as the whole batch, both to the user here and to whoever later answers the
   `deploy-approval` gate that quotes it (client-b WFI-003/WFI-004), so the count and the
   `…and N more` line are part of the list from here on: wherever a step below says "the commit
   list from step 3", it means the list *plus* that marker.

   `$BASE` is step 2a's, and it is `origin/main` on any project that has ever deployed. Counting
   against local `main` is how a human came to be asked about "205 commits" when 353 were about
   to ship (WFI-264).
4. **If no new commits on release vs `$BASE`**: inform the user there is nothing to deploy. **If this is an attended run** (`LV_UNATTENDED` unset), also close a stale `deploy-approval` gate before unclaiming — nothing being left to deploy means whatever that gate asked about was already promoted or abandoned by some other path, and a human running this attended is exactly the moment to clear it rather than leave it for `/lv-attend` to notice later (client-c WFI-031: an unattended dispatch kept reopening `deploy-approval` for a commit already the tip of `main`, because nothing ever told the gate the promotion had happened — this closes that gap the next time a human is actually here to answer for it):
   ```bash
   if [ "${LV_UNATTENDED:-0}" != "1" ] \
      && scripts/lv-exec.sh lv-list-gates.sh DEPLOY 2>/dev/null | grep -q "$(printf '\t')deploy-approval$(printf '\t')"; then
     scripts/lv-exec.sh lv-gate-close.sh DEPLOY "nothing left to deploy — already up to date"
   fi
   ```
   **Then, attended or not, clear an armed deploy guard before you unclaim:**
   ```bash
   scripts/lv-exec.sh lv-deploy-guard.sh --recover; echo "recover exit=$?"
   ```
   It finds `main`'s worktree from the marker itself, so it runs from here. Exit `1` — nothing
   was armed, the normal case. Exit `0` — say what it printed (usually "nothing to undo" or
   "origin/main already carries this commit"). Exit `2` — `main` needs a human: open a `stuck`
   gate on `DEPLOY` quoting its output, then unclaim.

   **This is not optional, and step 6a does not cover it** — this exit returns before step 6a
   is reached. `lv-list-deploy.sh` offers DEPLOY for as long as the guard is armed, precisely so
   that a worker comes and recovers it; a worker that says "nothing to deploy" and leaves the
   marker behind is re-dispatched to say it again. A client's WFI-039: three workers in a row
   exited here with the guard armed on a `main` that already equalled `origin/main`, attempts
   reached 3, and a stuck gate asked a human about a deploy that had nothing wrong with it.

   Then unclaim (`scripts/lv-exec.sh lv-unclaim.sh DEPLOY`) and exit.
4a. **Check for open deferred criteria on the plans being promoted:**
   ```bash
   scripts/lv-exec.sh lv-deferred-check.sh --range release --not $BASE
   ```
   The batch is the plan each commit is *about* — the first plan ID in its subject; a plan a
   subject only mentions is not in it (LVI-037). Exit `2` means the range could not be read: that
   is a check that did not run, not a clean result — attended, tell the user and ask; under
   `LV_UNATTENDED=1`, open a `needs-input` gate quoting the error, then unclaim and exit 0.
   Exit `0` — nothing open, continue. Exit `1` — print its output to the user before the confirmation
   prompt below: these are `external`/`soak`/`unbuilt` criteria that plan shipped without,
   read from `plans/deferred-criteria.md`. Most are harmless (a soak period, a future
   integration test) — but some describe a hard runtime dependency (a secret, a certificate, a
   required external service) that will crash the app in production if it's still missing. This
   check cannot tell the two apart; a human or grant has to. client-c's DC-014 was exactly
   the dangerous kind and went unread straight into a production crash-loop (WFI-011) — don't
   let this step become the same silent skip.

   **On exit `1`, ask the express lane first:**
   ```bash
   scripts/lv-exec.sh lv-lane.sh deferred-covered -- release --not $BASE; echo "lane exit=$?"
   ```
   Exit `0` — every open row is an `(external)` or `(soak)` criterion of a plan whose express
   lane still holds. A plan only holds the lane with such criteria when a human accepted the
   `criteria:` warning, so a human has already said these ship and get checked afterwards.
   Print its output (the criteria stay open in `plans/deferred-criteria.md` for after the
   deploy), and continue at step 5, attended or not; no gate. Exit `1` (a row the lane does
   not cover, named on stderr) or `2` — go on below. A client answered this gate twice in one
   day with "post-deploy iPad walks, accepted unrun" for plans whose lane had already
   accepted exactly those criteria.

   **Under `LV_UNATTENDED=1`, exit `1` is a gate — but read the answer of record first:**
   ```bash
   scripts/lv-exec.sh lv-promote-approval.sh deferred; echo "deferred approval exit=$?"
   ```
   Exit `0` — a human already answered this question *for this batch*; quote its line and
   continue at step 5. Exit `1` or `2` — open the gate **under exactly this name**, then unclaim
   and exit 0.

   **A standing `deploy` grant does not answer this one, and `lv-autonomy.sh` is not consulted
   here.** A grant is policy written in advance; these criteria did not exist when it was written,
   and one of them can be the hard runtime dependency that crash-loops production (WFI-011).
   `lv-gate-close.sh` enforces the same thing from the other side — `--basis autonomy` is refused
   on this gate name, because no autonomy action stands behind it.
   ```bash
   COVERS=; scripts/lv-exec.sh lv-autonomy.sh production-push --check --quiet || COVERS=--covers-push
   scripts/lv-exec.sh lv-gate-open.sh DEPLOY deploy-deferred-criteria \
     "<the check's output> — <commit list from step 3>" --skill lv-deploy $COVERS
   scripts/lv-exec.sh lv-unclaim.sh DEPLOY
   ```
   **Paste the check's output and step 3's list into the question as literal text.** A
   `$VARIABLE` set in an earlier Bash call is unset in this one, and inside single quotes it never
   expands; either way the human is asked to approve a name, so `lv-gate-open.sh` refuses it
   (LVI-023: "Commits: $COMMIT_LIST").
   `--check` because this is a probe, not the push: the recording form counts against the
   daily `production-push` ceiling and would spend an express-lane plan's one push on a question
   (LVI-025).

   **`--covers-push` makes this the deploy's only question** when the push has no standing
   grant: the script appends to the question that approving also pushes, and step 14's
   `lv-promote-approval.sh push` accepts the answer while `main`'s code is exactly this release
   tip. Without it every deploy asked twice — promote, then push — and a client's operator
   answered 8 gates for 3 batches (LVI-041). Always pass it on those terms; never widen it by hand.
   **Do not invent a gate name here, and do not fold this into `deploy-approval`.** The name is
   what gives the answer its scoping: `wf_promote_tip_ref` maps `deploy-deferred-criteria` to the
   `release` tip, so a gate opened for one batch stops authorizing a different one. A worker that
   names its own gate gets neither — its answer is never recorded against a commit set, and
   `lv-promote-approval.sh` has nothing to read, so the next dispatch re-runs this check, gets the
   same exit 1, and re-asks a question that was already answered (client-b WFI-005's loop).

   **And the batch this question describes goes stale.** client-a WFI-260: this gate opened at
   15:15 quoting 91 commits; `/lv-release` merged PR #214 into `origin/release` at 15:17, and by
   the time a human read the question the promotion was 118 commits carrying PLN-279 and PLN-280
   — two plans whose deferred criteria the question never showed. Step 2a's fast-forward means the
   *merge* is never stale; the **question** is what ages, and only the tip scoping catches it. On
   exit `2`, say in the gate question that new commits landed on `release` after the earlier answer.
5. **Ask whether this promotion needs a person at all** (coordinator WFI-006):
   ```bash
   scripts/lv-exec.sh lv-autonomy.sh deploy
   ```
   `deploy` runs unattended by default: it does not leave this machine, and the permission
   baseline, not a pause, is what keeps it safe. **Exit `0`:** show the commit list from step 3,
   say "deploy runs unattended by default — proceeding", and do not prompt. If a stale
   `deploy-approval` gate is open, close it with the setting as its basis, then continue at step 6:
   ```bash
   if scripts/lv-exec.sh lv-list-gates.sh DEPLOY 2>/dev/null | grep -q "$(printf '\t')deploy-approval$(printf '\t')"; then
     scripts/lv-exec.sh lv-gate-close.sh DEPLOY "orchestrator.autonomy: deploy unattended by default (WFI-006)" --decision approve --basis config
   fi
   ```
   **Exit `1` or `2`:** the project has put `deploy` back under `attended_for`, or its daily
   ceiling is spent. Prompt as below.

   **Prompt user**: "These commits will be promoted to main. Proceed? (y/n)"
   Wait for explicit confirmation before continuing. If they decline, stop here — do not proceed
   to step 6.

   On "yes", **close a stale `deploy-approval` gate before continuing**, if one is open — an
   earlier unattended run may have been refused and parked one:
   ```bash
   if scripts/lv-exec.sh lv-list-gates.sh DEPLOY 2>/dev/null | grep -q "$(printf '\t')deploy-approval$(printf '\t')"; then
     scripts/lv-exec.sh lv-gate-close.sh DEPLOY "approved attended by the human running this /lv-deploy" --decision approve
   fi
   ```
   **This is not optional.** `lv-guard-promote.sh` (a PreToolUse hook) refuses `git push origin
   main` while `DEPLOY.gate` exists — step 14's push would otherwise be blocked by the same
   mechanism that stops an unattended run from pushing past a refusal (WFI-004, WFI-005). Closing
   it here, on a real "yes" from a human, is what tells that hook this promotion is authorized.

   **Under `LV_UNATTENDED=1`**, see "Unattended mode" below — it replaces this confirmation with
   a standing-grant check and a concrete `deploy-approval` gate, then either continues at step 6
   or exits.

## What you do

6. **Pin `main` to its own worktree and move into it:**
   ```bash
   eval "$(scripts/lv-exec.sh lv-worktree-pin.sh main release-branches/main)"
   cd "$WORKTREE_PATH"
   git pull origin main
   ```
   `release-branches/main` is `main`'s permanent home — created once, reused forever. Before this, `/lv-deploy` moved the *shared* develop worktree onto `main` for the duration of the run, which put `plans/REGISTRY.md` — the file the orchestrator and every other session reads — behind `main`'s older copy for as long as the deploy took, and any concurrent session standing in that same directory found itself on `main` too (client-a's WFI-135, WFI-157, WFI-213 — the last of those had a client already work around exactly this by hand, keeping `release` in its own worktree; this generalizes that shape and applies it to `main` as well). Pinning `main` here means the develop worktree — project root, wherever this session started — never moves at all. **Steps 6–11 run in `release-branches/main`**, not the project root; every command below assumes that cwd. See [`docs/release-worktrees.md`](../../docs/release-worktrees.md).
6a. **Recover any merge a previous run left unverified, before adding another:**
   ```bash
   scripts/lv-exec.sh lv-deploy-guard.sh --recover
   ```
   Exit 1 means there was nothing to recover — the normal case. Exit 0 means a previous `/lv-deploy` merged into `main` and stopped before its suite returned a verdict, and `main` has just been put back to where it was; say so, and carry on with this run from a clean base. Exit 2 means it refused and `main` needs a human — stop there.

6b. **Confirm the tree is clean before you arm anything:**
   ```bash
   git status --porcelain
   ```
   Empty is the expected result — go to step 7. Anything printed means the merge in step 7 will
   abort, and arming first turns a merge that could not run into a `main` left **armed but
   unmerged**, which is the state step 6a of the *next* run has to undo.

   client-b WFI-029 hit this: the harness refresh in step 6 rewrote the tracked
   `.claude/settings.json`, and `git merge` refused with *"Your local changes to the following
   files would be overwritten by merge"* — after `--arm` had already succeeded. The installer no
   longer writes tracked files in a linked worktree, so this should not recur; the check stays
   because it costs one command and the failure it catches costs a recovery.

   If something *is* dirty: for each path, compare it against the incoming branch —
   ```bash
   git diff release -- <path>
   ```
   Empty means the working copy already matches what the merge would bring, and
   `git checkout -- <path>` discards nothing; take that and carry on. Anything else is a real
   local change nobody in this pipeline made — **stop and tell the user**, naming the paths. Do
   not stash it, do not commit it onto `main`, and do not arm.
7. **Arm the guard, then merge `release` into `main`** (auto-resolve in favor of release) — **in one call, in this order:**
   ```bash
   scripts/lv-exec.sh lv-deploy-guard.sh --arm
   git merge -X theirs --no-ff release -m "release: promote to main"
   ```
   The `-X theirs` option automatically accepts release's version of any conflicting files in `plans/`.

   `release` here is the *local* ref, which is only the validated batch because step 2a made it
   equal `origin/release` — the merge does not re-check that (client-a WFI-258). If you reached
   this step without a clean `lv-release-sync.sh`, go back; a stale tree merges and tests green.

   **The arm is what makes this merge provisional.** From here until step 8's suite passes, local `main` claims a promotion nothing has verified, and a run that stops in that window leaves the claim standing. client-a's WFI-255: an unattended worker merged 164 commits here, wrote *"Full test suite running (expected ~13 min)"* and *"Awaiting test results"*, then exited rc=0 sixty seconds later. It never awaited them and the suite was red. Nothing reached production — `origin/main` never moved — but the repository read as deployed until a human noticed and reset it by hand. The marker is what step 6a of the *next* run reads, so an abandoned deploy undoes itself instead of waiting to be spotted.

7a. **Check the harness survived the merge** — ask the script, do not hand-roll the test:
   ```bash
   scripts/lv-exec.sh lv-harness-restore.sh --check && echo "harness ok" || echo "HARNESS MISSING"
   ```
   **You are standing in `release-branches/main`, a LINKED worktree, and the harness there is only `scripts/lv-exec.sh` plus the `lv-*` skills.** `version-map.txt`, `scripts/current` and the versioned script folders resolve from the *main* worktree — `lv-exec.sh`'s `find_project_root` answers with it — so they are not supposed to be here and testing for them condemns a dispatcher that works. This step used to do exactly that (`[ -f scripts/version-map.txt ]`), and client-a's WFI-253 spent a recovery on a harness that was never missing.

   `HARNESS MISSING` means this merge carried the commit that stops tracking the generated harness onto a branch that still tracked it, so git deleted the files — and they are gitignored, so nothing puts them back. Restore with:
   ```bash
   scripts/lv-exec.sh lv-harness-restore.sh; echo "restore exit=$?"
   ```
   In this worktree its first recovery is the main worktree sitting next to you, which needs no library and no network; the library and then history are the fallbacks. **Read the exit code, and report it** — `0` restored, `2` a total failure to restore (every reason is on stderr; never read one of those as recovered), `3` it could only find a **stale** harness, which is unrecovered too: reinstall from the library before doing anything else (WFI-119). If the dispatcher itself did not survive, use the recovery in `/lv-release` step 6a, which needs no harness. Run the same check again after step 12 returns to the develop worktree (WFI-006) — the back-merge there is a separate merge and can go stale independently.

8. **Run full test suite** (final integration check) — **run the script, do not type a test command:**
   ```bash
   scripts/lv-exec.sh lv-suite-run.sh --label deploy --build --reuse-stage deploy
   ```
   It runs `build_command` then `test_command` from `levain.yml`, verbatim and unfiltered, against merged `main` in the worktree you are standing in, and ends with `SUITE_CMD=` / `SUITE_LOG=` / `SUITE_RESULT=`. **Exit 0 pass, 1 fail, 2 no suite configured** — 2 is a gap to report, never a pass. Report the `SUITE_RESULT=` line verbatim with `SUITE_CMD=` beside it; a count read out of the output is not evidence of what ran (WFI-252, where a release was pushed on one assembly's 474 tests reported as the whole E2E suite — **this step is what caught it**, and it only caught it because it ran the configured command).

   **`--reuse-stage deploy` reuses a receipt only when `levain.yml` says `suiteReuse: deploy`** — the default (`release`) and `none` always run the suite here (LVI-035). When it does reuse, the receipt is for this exact tree, command, toolchain and Levain version on a clean tree, and `SUITE_RESULT=pass (reused …)` says so: report it as reused, naming the run.

   **On a pass, and only then, disarm the guard and clear any recorded failure:**
   ```bash
   scripts/lv-exec.sh lv-deploy-guard.sh --disarm
   scripts/lv-exec.sh lv-deploy-suite-memo.sh --clear
   ```

   If tests fail, abort the deploy — do NOT proceed to registry updates, and **leave the guard armed**; recover the merge and **record the verdict against this batch** before you stop:
   ```bash
   scripts/lv-exec.sh lv-deploy-guard.sh --recover
   scripts/lv-exec.sh lv-deploy-suite-memo.sh --fail "<the failing test, N of M>" --log "<SUITE_LOG path>"
   ```
   Then inform the user of the failures (and, under `LV_UNATTENDED=1`, unclaim) and say where the fix belongs: on a feature branch through the pipeline, not on `release` by hand. Re-running `/lv-deploy` on these same commits will do nothing but spend the suite again — step 2b now refuses it, which is the point of the memo. **The summary you pass is what the next run and the gate quote**, so name the failing test; "tests failed" tells the next reader nothing the memo did not already cost them.

   **This step reads as inline and on a large project it cannot be.** A foreground Bash call is capped at 10 minutes; client-a's full suite takes about 13. Back when this ran in the shared develop worktree that stalled the deploy at its most dangerous point — the registry every other session read was `main`'s stale copy (WFI-213). That danger is gone now that `main` lives in its own worktree. The cap is not.

   **When the suite will not fit in one call, detach it and wait in slices — never background it and move on:**
   ```bash
   scripts/lv-exec.sh lv-suite-run.sh --label deploy --build --reuse-stage deploy --detach   # prints SUITE_HANDLE=
   scripts/lv-exec.sh lv-suite-wait.sh <SUITE_HANDLE>                   # blocks up to 9 minutes
   ```
   `lv-suite-wait.sh` exits **0 pass, 1 fail, 3 still running**. On `3`, call it again with the same handle, as many times as it takes. Each call is its own foreground command, safely under the cap, and every one of them is a tool call that keeps the session alive.

   **`3` is not a pass and not a failure, and this is the step where that has actually gone wrong.** WFI-255 is a worker that backgrounded the suite, announced it was awaiting results, and exited rc=0 sixty seconds later with `main` merged and the suite red. Under `LV_UNATTENDED=1` there is no session to come back to: a headless run ends the moment it stops producing output and takes every background job with it. So no `run_in_background`, no "I'll check the log later", and no verdict reported that `lv-suite-wait.sh` did not return.

   **And no scheduled wake-up.** It has now happened three times in five days across two roles — WFI-255 here, WFI-265 here again ("Test suite is progressing. System will check again in 90 seconds", then 22 hours of nothing with `main` merged locally and the guard armed), and WFI-266 twice in one morning in /lv-release. Every one of them announced a wait that no mechanism was going to honour. **The `lv-suite-wait.sh` loop is the only wait that exists. Ending the turn is abandoning the run.**

   **Before spending the suite, ask whether its answer already exists:**
   ```bash
   scripts/lv-exec.sh lv-suite-receipts.sh --for main
   ```
   Exit **0** a run already passed on this exact tip, **1** one failed on it, **2** no receipt — run the suite. The tip is what makes a receipt admissible: a pass measures one tree and says nothing about any other. `SUITE_COLLECTED=never` means the worker that started it walked away, which is the shape above. Quote its `SUITE_RESULT=` and `SUITE_CMD=` lines as the verdict and say which run they came from.

8a. **Sanity-check the branch before anything else commits:**
    ```bash
    git branch --show-current    # must print: main
    ```
    `release-branches/main` is pinned — nothing else in this pipeline ever checks it out to anything else, so this should always pass. If it doesn't, a human touched this worktree by hand; stop and sort that out before continuing rather than guess.
9. **Update REGISTRY.md** — ask which plans this deploy actually shipped, then transition those:
   ```bash
   scripts/lv-exec.sh lv-list-completable.sh --ref release
   ```
   Each line is `<plan-name>\t<merged|unmerged|no-branch>\t<branch>\t<detail>`. Run the transition
   for the `merged` rows **and only those**:
   ```bash
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN testing complete -
   ```
   Exit 1 means no plan is completable. That is the **normal** outcome and not a failure — say so
   and go to step 10. Report any `unmerged` or `no-branch` row in your summary, with its detail
   text; do not transition it and do not try to merge it here.

   **Do not select this set yourself.** The rule has been written in prose twice and been wrong
   both times, in the same direction, on the same plan:

   - "every plan folder on release" — a `plan.md` reaches release on its own through a
     planning-only commit on develop, while the plan is still `draft` or `ready` (WFI-001).
   - "every plan in state `testing` whose folder is on release" — client-b' PLN-012 satisfied
     that exactly while `feature/PLN-012-prototypes` carried 10 commits that were not an ancestor
     of release and had shipped nothing. The 33 PLN-012 commits inside `release --not origin/main`
     were all spec, registry, progress and gate bookkeeping (WFI-030, WFI-035).

   The direction of the error is why it matters. `testing` means *passed verify, needs a human* —
   precisely the state whose code is normally **not** yet on release, because `/lv-test` is what
   merges the PR and sets `complete`. Every plan whose code did ship is already `complete` before
   you get here. So this step fires rarely, and left to a prose rule it fires on exactly the plan
   whose human acceptance test has not happened yet — marking it `complete` removes it from
   `/lv-test`'s queue and records production content that does not exist.
10. **Close linked bugs** — for each completed plan, check `plan.md` Goal for `**Bug:**` line:
   ```bash
   scripts/lv-exec.sh lv-bug-close.sh BUG-NNN PLN-NNN-<slug>
   ```
   Each call commits its own rename, both sides — leave the bug folders out of step 11's pathspec (WFI-136).

   **Run it for every completed plan that names a bug, without checking first.** `/lv-test` closes some bugs at plan completion and some it does not, with nothing in the plan telling them apart (WFI-143), so this step meets a mix. A bug that is already closed is the outcome this step wants: the script says `already closed — nothing to do` and exits 0. Do not skip the call to avoid an error, and do not treat one as a deploy failure.

   **The general sweep for cross-run orphans runs later, in step 12a — not here.** `lv-bug-close-sweep.sh` always operates on the develop worktree (`wf_develop_root()`), regardless of cwd. Calling it here, while still in `release-branches/main` and before step 12's back-merge, means develop still shows the bugs this step just closed in main as untouched — the sweep would "find" them, genuinely re-close them a second time, and commit that redundant close directly onto develop instead of letting it arrive via the back-merge (WFI-025). Wait for develop to actually be in sync with main before sweeping it.
11. **Commit plan updates** — name the plans this deploy actually carried, not
    `plans/PLN-*/`. That wildcard spans every concurrent worker's tree;
    `lv-commit.sh` commits the pathspec and nothing else staged (WFI-109,
    WFI-110):
    ```bash
    scripts/lv-exec.sh lv-commit.sh "release: complete <plan-names>" \
      --branch main --add plans/PLN-NNN-<slug>/plan.md
    ```
12. **Return to the develop worktree and back-merge `main` → `develop`** (auto-resolve in favor of develop). Unlike steps 6–11, this one runs in the develop worktree itself — the commits `main` just received in `release-branches/main` are already visible there as local refs, no push needed:
    ```bash
    cd "$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
    git pull origin develop
    git merge -X ours main -m "sync: bring completed plans back to develop"
    ```
    The merge runs *on develop*, so `-X ours` keeps **develop's** side of any conflicting hunk in `plans/`. That is the side to keep: every registry transition, `complete` included, is written on develop, so develop's `REGISTRY.md` is the live one and main's is the snapshot release carried. Taking main's side would roll back rows that moved since release was cut (a client's LVI-042 found this sentence had it backwards).
12a. **Now run the general bug-close sweep** — develop is caught up with main as of step 12, so this correctly sees only genuine cross-run orphans (a bug whose link was never acted on before its own close step existed, or an earlier deploy that skipped it on error — client-c's WFI-017 found two, each a full deploy cycle stale) and not the bugs step 10 just closed:
    ```bash
    scripts/lv-exec.sh lv-bug-close-sweep.sh --apply
    ```
    Still in the develop worktree from step 12 — do not run this in `release-branches/main`. Read-only without `--apply`, for a standalone check outside a deploy (`/lv-tray` can point to it the same way this repo's own `check-profiles.sh` and `sweep-issues.sh` are pointed to). Any bug it closes here needs its own commit pushed with develop in step 13, so run it before that push, not after.
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
    scripts/lv-exec.sh lv-autonomy.sh production-push
    ```
    Exit `0` — run `git push origin main` and say, in the completion message, what authorized it
    — quote the script's line: a standing grant; **the pre-launch default**, which answers `0`
    while `projectProfile.tier` is `pre-launch` and `projectProfile.live_from` is unset or still
    ahead (LVI-036); or **the express lane**, which answers `0` when
    every code commit in `origin/main..main` belongs to a `complete` plan whose lane still holds,
    once per plan (`lv-lane.sh push-covered`, LVI-025). Anything else — print the manual
    instruction above and stop.
    Attended runs never call this: a human who is present is asked, not looked up.

    **Unattended, with no grant, the push is asked for at a gate** — see
    [Unattended mode](#unattended-mode). The human accepts it at `/lv-attend`, and the next
    dispatch pushes.

15. **Unclaim, then display success:**
    ```bash
    scripts/lv-exec.sh lv-unclaim.sh DEPLOY
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

Set when `LV_UNATTENDED=1` — the daemon dispatched this run against the fixed `DEPLOY` artifact.

- **Stand down quietly if already claimed**, before doing anything else:
  ```bash
  scripts/lv-exec.sh lv-claim.sh DEPLOY --if-free
  ```
  Exit `2` → print nothing but a log line and exit 0. A human or another worker already holds
  `DEPLOY`; this is not a failure, just a lost race.
- **Skip step 5's confirmation prompt.** In its place, check the two things that can authorize
  this promotion with nobody present. **The one-off approval first** — it is an answer a human
  gave about *these* commits, where a grant is policy written in advance:
  ```bash
  scripts/lv-exec.sh lv-promote-approval.sh deploy
  ```
  | Exit | What it means | What you do |
  |-|-|-|
  | `0` | A human approved this exact batch at the `deploy-approval` gate, and `release` has not moved since | Quote the script's line and continue at step 6 — do not ask `lv-autonomy.sh`, do not open a gate |
  | `1` | No answer of record, a rejection, or a close with no recorded decision | Fall through to the autonomy check below |
  | `2` | An approval exists but `release` has moved on — it covered a different batch | Fall through, and if the autonomy check also refuses, say in the gate question that new commits landed after the answer |

  Without this, an approval given at `/lv-attend` cannot reach the merge: `lv-autonomy.sh` only
  ever knew about standing grants, so every dispatch after an approval re-opened the gate it had
  just been let through (client-b WFI-005, filed against `/lv-release` — the same shape here).

  Then, only if that did not authorize it, check for standing authorization:
  ```bash
  scripts/lv-exec.sh lv-autonomy.sh deploy
  ```
  | Exit | What it means | What you do |
  |-|-|-|
  | `0` | `deploy` runs unattended by default (WFI-006), or a dated, unexpired grant covers it | Quote the script's line and continue at step 6 |
  | `1` or `2` | No grant, or malformed | Open the gate below (exit 2: include the script's stderr verbatim — a malformed grant is a broken file, not a refusal), then unclaim and exit 0 — **STOP. Do not merge, push, or run step 6 or anything after it.** |

  ```bash
  COVERS=; scripts/lv-exec.sh lv-autonomy.sh production-push --check --quiet || COVERS=--covers-push
  scripts/lv-exec.sh lv-gate-open.sh DEPLOY deploy-approval "<commit list from step 3>" --skill lv-deploy $COVERS
  scripts/lv-exec.sh lv-unclaim.sh DEPLOY
  ```
  The commit list goes into the question as literal text, never as a `$VARIABLE` from an earlier
  call — `lv-gate-open.sh` refuses an unexpanded one (LVI-023).
  `lv-gate-open.sh` exiting 3 means `deploy-approval` already has an answer of record — act on it
  rather than re-asking, per the standing gate-reopening rule.

  **This run is finished the moment `lv-unclaim.sh DEPLOY` above returns — nothing else in this
  document is a next step for exit `1` or `2`.** client-c's WFI-032 saw a RELEASE worker do
  exactly this wrong at the matching check in `/lv-release`: refuse, open the gate, then continue
  on to merge and push anyway before exiting `rc=0`. Refusing here and then promoting `release` to
  `main` regardless makes the gate theater — a refusal ends the run at the `lv-unclaim.sh` call
  above, full stop, never at step 6 or anywhere past it.

  This authorizes promoting `release` to `main` **locally only**. It never authorizes step 14's
  push to the production remote — that is a second, separate question.

- **A push waiting on `main` goes first — check right after claiming, before step 2.** If
  `main` is ahead of `origin/main` and the guard is not armed, an earlier run finished steps 6–13
  and stopped at step 14. Ask step 14's two questions (below) **before looking at `release`**:
  - Either answers `0` → push `main` now, as step 14 says. Then, if `git rev-list main..release`
    is empty, finish; otherwise continue at step 2 with the next batch.
  - Neither answers `0`, and `release` has nothing `main` lacks → open the `production-push` gate
    as step 14 says, and finish.
  - Neither answers `0`, and `release` has moved on → **promote nothing.** Open (or leave open)
    the `production-push` gate for the `main` that exists, unclaim, and exit 0. A promotion on
    top of it moves `main`, which voids the question in front of the human.

  Do not re-run the promotion, the suite, or the bookkeeping for a batch already merged. A client's
  LVI-042: a human approved pushing `main` ec0b40b at 14:10:07Z; the next dispatch saw a new plan
  on `release`, went to step 4a instead, promoted it, and ec0b40b was never pushed — the approval
  was discarded and a new `production-push` gate opened for the combined tip five minutes later.
  An approved push drains before anything new is promoted.

- **Step 14, unattended — the push.** Ask, in this order, and stop at the first `0`:
  ```bash
  scripts/lv-exec.sh lv-promote-approval.sh push      # a human approved THIS main tip at the gate
  scripts/lv-exec.sh lv-autonomy.sh production-push   # a standing grant, pre-launch (LVI-036), or the express lane
  ```
  Either `0` → `git push origin main` from `release-branches/main`, and say in the completion
  message which one authorized it (quote the script's line). `lv-promote-approval.sh push` also
  answers `0` for a step-4a/step-5 approval opened with `--covers-push` whose release tip is
  exactly `main`'s code — that is the one-question deploy, and its line says so. Exit `2` means
  `main` moved since the answer — treat it as no answer.

  Neither → **open the push gate**, then unclaim and finish normally. The count goes in by
  command, after a fetch — never typed. A client's LVI-039 asked "0 commits not on origin/main
  (15 commits promoted in this batch)" about a `main` that was 16 ahead, and the human approved
  a push the question said was empty:
  ```bash
  git fetch -q origin main
  AHEAD=$(git rev-list --count origin/main..main)
  scripts/lv-exec.sh lv-gate-open.sh DEPLOY production-push \
    "Push main $(git rev-parse --short main) to origin? $AHEAD commits not on origin/main; <what the push triggers — name the workflow, or 'CI only, nothing is deployed'>" \
    --skill lv-deploy
  scripts/lv-exec.sh lv-unclaim.sh DEPLOY
  ```
  `AHEAD` of `0` means there is nothing to push: do not open the gate, and say so.
  Report the deploy as **complete, push awaiting approval at `/lv-attend`** — not as blocked.
  The promotion succeeded; the gate asks only about the push. That is why it has its own name:
  re-opening `deploy-approval` here, or replaying step 3's commit list as the question, parks a
  finished deploy behind a question about work already done (client-c WFI-029). And it must
  be a gate, not just a line in the completion message: `main` ahead of `origin/main` keeps
  `DEPLOY` a candidate, so a run that only *says* "push manually" is re-dispatched until the
  attempt budget parks it as `stuck` (coordinator WFI-008, client-b 2026-09-23 — three identical runs,
  then a stuck gate on a deploy that had worked).

  `lv-gate-open.sh` exiting 3 means `production-push` already has an answer of record: an
  `approve` for this tip was caught above, so it is a `reject` — leave `main` unpushed, say so,
  and finish. `lv-list-deploy.sh` stops offering `DEPLOY` while that rejection covers the tip.
- **Step 4a has its own named gate and its own answer-of-record check** — `deploy-deferred-criteria`,
  read back with `lv-promote-approval.sh deferred`. It is written out at step 4a; do not re-derive
  it here and do not give it another name.
- **Resolve every other `[GATE]` or would-ask-a-human point in the steps above the same way** —
  open a gate naming the question, unclaim, and exit 0. Never guess, never hang. A question that
  is about *the batch* rather than about one plan needs a gate name this harness knows
  (`wf_promote_tip_ref` in `lv-orch-lib.sh`), or its answer is recorded against no commit set and
  cannot lapse when the batch moves — that is client-a WFI-260 (`production-push` is one such
  name, for step 14). If you find yourself needing a
  new one, file it with `lv-issue.sh` rather than inventing it.
- **On every exit path** — grant found and the run proceeds to completion, gate opened, or an
  error stops the run early — `scripts/lv-exec.sh lv-unclaim.sh DEPLOY` is the last action before
  finishing.

## Conflict resolution

Merge strategy `-X theirs` (step 7) and `-X ours` (step 12) automatically resolve conflicts:

- **release → main:** Accept release's version
- **main → develop:** Keep develop's version (`-X ours`, run on develop): develop's REGISTRY.md is live, main's is release's snapshot

Plans never move folders, so the only potential conflict is REGISTRY.md — which is tracked as of v3.2.0, and row-based precisely so that transitions to different plans auto-merge. Feature branches carry no copy (`plans/**` is excluded from every feature worktree), so conflicts can only arise between the long-lived branches this skill promotes. If a merge fails, abort and notify the user.

## Rules

- **Claim `DEPLOY` before touching anything, unclaim before finishing** — step 1 claims it; every exit path, success or failure, ends with `lv-unclaim.sh DEPLOY`
- **Require confirmation** — always show what's being promoted and wait for user approval
- **E2E must have passed** — this skill assumes `/lv-release` already validated the release branch
- **Do NOT** force push — this is a main branch, use regular merge
- **Do NOT** skip back-merge — develop needs to stay in sync with main
- **Steps 6–11 run in `release-branches/main`, step 12 onward runs in the develop worktree** — step 6 pins and moves you into the former; step 12 moves you back
- **The merge into `main` is provisional until its suite passes** — step 7 arms `lv-deploy-guard.sh`, step 8 disarms it on a pass and recovers on a failure, and step 6a recovers whatever a previous run abandoned. Never merge without arming first: a run that stops in that window leaves `main` claiming a promotion nothing verified (WFI-255)
- **Never report a suite verdict you did not wait for** — `lv-suite-wait.sh` exit `3` means *still running*, and the only correct response is to call it again. Under `LV_UNATTENDED=1` nothing you background survives your own exit
- **Complete all steps** — if the user interrupts, tell them which step to resume at; there is no shared checkout to leave parked, so an interruption costs nothing beyond finishing later

## On startup

1. Claim `DEPLOY` (step 1)
2. Confirm `release` exists as a ref (`git rev-parse --verify release`) — it need not be checked out anywhere
3. Show commits on release that aren't on main
4. If new commits exist: prompt user to confirm promotion
5. If no new commits: inform user there is nothing to deploy, run `lv-deploy-guard.sh --recover`, unclaim

## Committing work

Three commits are normal:
1. Merge commit (release → main): `"release: promote to main"`
2. Plans + bugs: `"release: complete [plan-names], close bugs"`
3. Back-merge: `"sync: bring completed plans back to develop"`

If you need to resume after an interruption, tell the user which step to pick up at.

On completion, run `scripts/lv-exec.sh lv-check-reboot-flag.sh` and append any output to your completion message.

## Production deploy (separate step)

This skill does NOT push to main. After `/lv-deploy` completes:

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

## Usage

```text
/lv-deploy              promote release to main: mark plans complete, close bugs,
                        back-merge to develop. The step before a production push
```
