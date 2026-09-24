---
name: lv-release
description: Merge develop into release, run E2E tests to validate staging. Stops here — use /lv-deploy to promote to main.
user_invocable: true
model: haiku
---

# Release Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are in **release mode**. Your job is to sync `develop` into `release`, validate staging with E2E tests, and confirm it's ready for production promotion. This skill does NOT promote to main — that's `/lv-deploy`.

## State context

```
plans/REGISTRY.md      → single source of truth (plans stay in "complete" state after this skill)
release-branches/release → release's own permanent worktree — staging environment for E2E validation
```

## What you do

1. **Claim the release slot:**
   ```bash
   scripts/lv-exec.sh lv-claim.sh RELEASE
   ```
   `RELEASE` is a fixed, singleton artifact id — there is only ever one release pipeline, so this
   claim excludes a second concurrent `/lv-release` (attended vs. attended, attended vs. the
   daemon, or daemon vs. daemon), the same way `lv-test` claims a plan before touching it.

   | Exit | What it means | What you do |
   |-|-|-|
   | `0` | Claimed | Continue at step 2 |
   | `2` | Another live session already holds it | Tell the user who holds it (the script's output names the session) and stop. If they believe it's stuck, offer `scripts/lv-exec.sh lv-claim.sh RELEASE --steal` |

   **From here on, whatever happens — success, test failure, "nothing to release," or a parked
   gate — the last thing you do before finishing is `scripts/lv-exec.sh lv-unclaim.sh RELEASE`.**
   Every exit path below says so again at the point it applies, but the rule is unconditional:
   never leave this skill without unclaiming.

2. **Pin `release` to its own worktree and move into it:**
   ```bash
   eval "$(scripts/lv-exec.sh lv-worktree-pin.sh release release-branches/release)"
   cd "$WORKTREE_PATH"
   ```
   `release-branches/release` is `release`'s permanent home — created once, reused forever, never the shared develop checkout. Before this, `/lv-release` moved the shared main worktree onto `release` for the duration of the run: the orchestrator reads `plans/REGISTRY.md` from that worktree, and on `release` that file is whatever release last merged, so every plan whose state advanced since then read stale — client-a's PLN-051 read `active` there while develop had it `complete`, and two unattended builders were dispatched at a finished plan (WFI-135, WFI-134, WFI-157). Pinning `release` to its own path removes the borrowing: develop's worktree never leaves develop, so there is nothing to hand back at the end and nothing for a parallel session to catch mid-move. See [`docs/release-worktrees.md`](../../docs/release-worktrees.md).

   Everything from here through step 9 runs **in `release-branches/release`**, not the project root — every command below assumes that cwd.
3. **Check if develop has unreleased commits.** Fetch first — this worktree is pinned and long-lived, so the local `release` ref can be stale relative to `origin/release` if another session pushed since this worktree last touched it (WFI-024, WFI-027):
   ```bash
   git fetch origin release
   TOTAL=$(git rev-list --count origin/release..develop)
   git log origin/release..develop --oneline | head -10
   if [ "$TOTAL" -gt 10 ]; then echo "…and $((TOTAL - 10)) more ($TOTAL commits total)"; fi
   ```
   **Always carry the total with the list.** `head -10` is a display convenience, not the
   promotion — everything in the range ships whether or not it was printed. A bare truncated
   list reads as the whole batch, both to the user at step 5 and to whoever later answers the
   `release-approval` gate that quotes it (client-b WFI-003/WFI-004), so the count and the
   `…and N more` line are part of the list from here on: wherever a step below says "the commit
   list from step 3", it means the list *plus* that marker.

   This must compare `release` against `develop`, never against `main`. Right after every `/lv-deploy`, `release` and `main` are identical by construction, so `main..release` is always empty and would report "nothing to release" even when develop has a full backlog of completed plans waiting to ship (WFI-024).

   **Filter out `/lv-deploy`'s own bookkeeping commits before deciding whether there's anything
   here.** `/lv-deploy` never advances `release` itself (nothing but `/lv-release` and
   `/lv-deploy` may touch `release-branches/*`, and neither reaches into the other's —
   `docs/release-worktrees.md`); instead it commits registry transitions, plan-completion state
   and bug closes directly to `main` (steps 9–11) and back-merges `main` into `develop` (step
   12). All of that lands on `develop` as commits `release` has never seen, so it shows up here
   as "unreleased" every time — even though none of it is new work, just the record of a deploy
   that already shipped:
   ```bash
   git log origin/release..develop --format=%s \
     | grep -vE '^(release: promote to main$|release: complete |sync: bring completed plans back to develop$|registry\(|bug\()'
   ```
   If this filtered list is EMPTY (every commit in range matches one of those patterns),
   treat it exactly like step 4's "nothing to release" — the next real batch of work will carry
   this bookkeeping into `release` as a side effect of merging in step 6, so there's no reason to
   run E2E or ask for approval over content with no user-facing change. Skipping here is what
   stops it from being asked again: a real /lv-release run only happens once real work exists to
   filter down to, so the next unattended dispatch has nothing left to loop on (client-c
   WFI-030 — this cycle, unfixed, alternated `release-approval` and `deploy-approval` gates
   indefinitely, each answered one freeing a dispatch that reopened the other). If the filtered
   list is non-empty, proceed with the FULL unfiltered range from step 3 below — real work present
   makes the bookkeeping commits harmless to include alongside it.
4. **If that range is empty** (or filters down to empty, above): inform the user ("Release is up to date with develop — nothing to release."). **If this is an attended run** (`LV_UNATTENDED` unset), also close a stale `release-approval` gate before unclaiming — nothing being left to release means whatever that gate asked about was already promoted or abandoned by some other path, and a human running this attended is exactly the moment to clear it rather than leave it for `/lv-attend` to notice later (client-c WFI-031: an unattended dispatch kept reopening `release-approval` for commits a human had already promoted by hand, because nothing ever told the gate the promotion had happened — this closes that gap the next time a human is actually here to answer for it):
   ```bash
   if [ "${LV_UNATTENDED:-0}" != "1" ] \
      && scripts/lv-exec.sh lv-list-gates.sh RELEASE 2>/dev/null | grep -q "$(printf '\t')release-approval$(printf '\t')"; then
     scripts/lv-exec.sh lv-gate-close.sh RELEASE "nothing left to release — already up to date"
   fi
   ```
   Then unclaim (`scripts/lv-exec.sh lv-unclaim.sh RELEASE`) and exit. Next step: work on a plan with `/lv-implement`, test it with `/lv-test`, then return here.
4a. **Check for open deferred criteria on the plans being staged:**
   ```bash
   scripts/lv-exec.sh lv-deferred-check.sh $(git log origin/release..develop --oneline | grep -oE 'PLN-[0-9]+' | sort -u)
   ```
   Exit `1` — show its output to the user alongside the commit list in the next step. These are
   `external`/`soak`/`unbuilt` criteria read from `plans/deferred-criteria.md` that a plan shipped
   without — most are harmless, but one describing a hard runtime dependency (a secret, a
   certificate, a required external service) can crash production if `/lv-deploy` promotes it
   before that dependency exists (WFI-011). Surfacing here gives `/lv-deploy` a second, earlier
   read of the same list.
5. **Ask whether this promotion needs a person at all** (coordinator WFI-006):
   ```bash
   scripts/lv-exec.sh lv-autonomy.sh release
   ```
   `release` runs unattended by default: it does not leave this machine, and the permission
   baseline, not a pause, is what keeps it safe. **Exit `0`:** show the commit list from step 3,
   say "release runs unattended by default — proceeding", and do not prompt. If a stale
   `release-approval` gate is open, close it with the setting as its basis, then continue at step 6:
   ```bash
   if scripts/lv-exec.sh lv-list-gates.sh RELEASE 2>/dev/null | grep -q "$(printf '\t')release-approval$(printf '\t')"; then
     scripts/lv-exec.sh lv-gate-close.sh RELEASE "orchestrator.autonomy: release unattended by default (WFI-006)" --decision approve --basis config
   fi
   ```
   **Exit `1` or `2`:** the project has put `release` back under `attended_for`, or its daily
   ceiling is spent. Prompt as below.

   **Show commits to user** — display the commit list from step 3. Tell the user: "Run `/model haiku` if not already on it, then confirm to proceed." Then prompt: "These commits are staged for E2E. Proceed? (y/n)"
   Wait for explicit confirmation before continuing. If they decline, stop here — do not proceed to step 6.

   On "yes", **close a stale `release-approval` gate before continuing**, if one is open — an
   earlier unattended run may have been refused and parked one:
   ```bash
   if scripts/lv-exec.sh lv-list-gates.sh RELEASE 2>/dev/null | grep -q "$(printf '\t')release-approval$(printf '\t')"; then
     scripts/lv-exec.sh lv-gate-close.sh RELEASE "approved attended by the human running this /lv-release" --decision approve
   fi
   ```
   **This is not optional.** `lv-guard-promote.sh` (a PreToolUse hook) refuses `git push origin
   release` while `RELEASE.gate` exists — step 6's push would otherwise be blocked by the same
   mechanism that stops an unattended run from pushing past a refusal (WFI-004, WFI-005). Closing
   it here, on a real "yes" from a human, is what tells that hook this promotion is authorized.

   **Under `LV_UNATTENDED=1` there is nobody to prompt.** See "Unattended mode" below — it replaces this confirmation with a standing-grant check and a concrete `release-approval` gate, then either continues at step 6 or exits.
6. **Push local `develop`, then merge it into `release`** to bring plan files and REGISTRY state. Nothing in the pipeline pushes `develop` mid-cycle — only `/lv-deploy`'s back-merge does, right at the end — so `origin/develop` is routinely behind the local branch every other skill has been committing to. Merging `origin/develop` without pushing first silently drops everything committed since the last deploy: client-a's WFI-250 merged 39 commits behind, picked up only the bookkeeping paths that happened to already be pushed, and the omission of a whole plan's code and tests was caught only by noticing its plan folder absent from the release worktree afterward — the full test suite passed regardless, because it never contained the missing plan's tests to fail.
   ```bash
   git push origin develop
   git pull origin release
   git merge origin/develop --no-edit
   ```
   A push rejected as non-fast-forward means another session pushed `develop` from elsewhere between your read of it and now — pull and reconcile there before retrying; never force. If the merge fails with non-trivial conflicts, `git merge --abort` first — a worktree left mid-merge is neither the old state nor the new one, and the next run inherits it — then inform the user (and, under `LV_UNATTENDED=1`, unclaim) and stop; do not proceed to E2E.

6a. **Check the harness survived the merge** — run this immediately, before anything else:
   ```bash
   [ -x scripts/lv-exec.sh ] && [ -f scripts/version-map.txt ] && echo "harness ok" \
     || echo "HARNESS MISSING"
   ```
   `harness ok` → continue at step 7.

   `HARNESS MISSING` means the untrack commit reached a branch that still tracked the generated harness, so git deleted the files — and they are gitignored now, so nothing puts them back.

   **Reinstall from the library first.** `install.sh` recorded its own path when this project was set up, and it survives any checkout because it is untracked. That last word is also why the snippet below looks in two places: untracked files are **not** materialised in a git worktree, and you are always releasing from `release-branches/release` — a dedicated worktree — so `.claude/workflow-source` exists only in the main (develop) checkout (client-a's WFI-191 — the old one-liner was guarded with `[ -n "$lib" ] &&`, so an empty `$lib` made it a silent no-op that exited 0).
   ```bash
   lib=$(cat .claude/workflow-source 2>/dev/null | tr -d '[:space:]')
   if [ -z "$lib" ]; then
     main_root=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
     lib=$(cat "$main_root/.claude/workflow-source" 2>/dev/null | tr -d '[:space:]')
   fi
   if [ -n "$lib" ] && [ -f "$lib/install.sh" ]; then
     bash "$lib/install.sh" "$PWD"
   else
     echo "NO LIBRARY — .claude/workflow-source is empty in this checkout and in the main worktree"
   fi
   ```
   That regenerates the harness this project's `.claude/workflow-version` actually names, and leaves the tree clean because the files are gitignored. **Re-run the step 6a check** — do not take the installer's exit code as the answer. On `harness ok`, continue at step 7; on `NO LIBRARY` or a still-missing harness, use the history recovery below.

   **Only if the library is unreachable**, recover from history with plain git — but understand what you are getting. The newest ref that still *tracks* the harness is, by definition, a ref from before this client's untrack commit, so the further back that migration is, the staler the restore. client-a's WFI-119 recovered a v3.3.0-era harness into a project stamped 6.2.1 and reported success: three major versions of stale `lv-*` scripts, which is the exact failure mode WFI-014 warns about. **Find the ref first — do not assume `HEAD@{1}` — and check its version before trusting it:**
   ```bash
   want=$(cat .claude/workflow-version 2>/dev/null | tr -d '[:space:]')
   for n in $(seq 1 40); do
     ref="HEAD@{$n}"
     git rev-parse --verify --quiet "$ref" >/dev/null || continue
     git ls-tree -r --name-only "$ref" -- scripts/version-map.txt | grep -q . || continue
     got=$(git show "$ref:.claude/workflow-version" 2>/dev/null | tr -d '[:space:]')
     echo "$ref carries workflow ${got:-unknown} (this project declares $want)"
     break
   done
   ```
   If `got` does not equal `want`, this ref is **not** a recovery — restoring it silently downgrades the harness. Stop, and get the library reachable instead. If they match, with that ref in `$ref`:
   ```bash
   git ls-tree -r --name-only "$ref" -- scripts .claude \
     | grep -E '^(scripts/((lv|wf)-exec\.sh|(lv|wf)-prune-versions\.sh|version-map\.txt|v[^/]+/)|\.claude/(skills/(lv|wf)-|workflow\.md))' \
     > /tmp/wf-harness-paths
   xargs git checkout "$ref" -- < /tmp/wf-harness-paths
   xargs git rm --cached --quiet -- < /tmp/wf-harness-paths
   ```
   The checkout brings the files back; the `rm --cached` returns them to untracked, which is what the ignore rules already describe — so the working tree ends clean. Once the harness is back, `scripts/lv-exec.sh lv-harness-restore.sh` does all of this in one call for any future occurrence: library first, then a version-matched ref, and it exits 3 rather than lying to you when all it could find was a stale one.

   **Why the search, and not a fixed distance.** The deletion is not reliably one step behind. client-e's WFI-014: step 5's `git pull origin release` fast-forwarded 75 commits, straight through the untrack commit — so `HEAD@{1}` was already *past* the deletion, the path list came back empty, and the recovery restored zero files while reporting nothing wrong. `HEAD@{2}` held all 82 paths. A local release branch many commits behind origin is the normal case.

   Never `git rm -r --cached scripts` wholesale — a project may keep its own tooling there, and untracking it turns a recovery into a larger accident.

   **After any restore, keep running everything through `scripts/lv-exec.sh`.** A client that predates v5 may still carry flat `scripts/lv-*.sh` files tracked in git; those are pre-untracking copies and they are stale. `scripts/v*/` is the live harness, and `lv-exec.sh` is what resolves to it — calling a flat script directly silently runs old code (WFI-014).

   This happens **once per client**, on the first release after the harness is untracked on develop, and it self-clears when the change reaches `main`. It is silent and total while it lasts: client-c lost 106 files including `lv-exec.sh` mid-skill and only found out at step 8, with exit 127 (WFI-006).
6b. **Check the suite's external prerequisites before running it:**
   ```bash
   scripts/lv-exec.sh lv-preflight.sh
   ```
   Exit `0` → continue at step 7 (this includes "none declared", which is the normal case for a
   self-contained suite). Exit `1` → **do not run the suite.** It names which prerequisite is
   unreachable; roll the merge back (step 7's `lv-release-rollback.sh`), report *that* as the
   reason, and stop — attended, tell the user what to start; under `LV_UNATTENDED=1`, open a
   `needs-input` gate quoting the DOWN line, then unclaim and exit 0.

   A red suite is only evidence against the commits if the suite is self-contained. client-e
   WFI-028: 9 of 70 E2E tests failed with 30s response timeouts on a merge carrying no `src/`
   changes at all — the login tests drive an OIDC challenge at `Oidc:Authority`
   (`http://localhost:8084`), and client-c's local dev issuer was not running. Starting it
   and re-running, with no code change, turned the same filter from 2 failed / 5 passed in 1m6s
   into 7 passed / 0 failed in 8s. The rollback did its job, so nothing unsafe followed — but the
   report accused a clean batch, and an operator acting on it goes hunting a regression that does
   not exist. Prerequisites are declared per project in its own `claude-workflow.yml` under
   `e2ePrereqs:`; a project with none declared is unaffected by this step.

7. **Run E2E / integration tests** (staging validation), against the local merge — before anything is pushed. **Do not type a test command here; run the script:**
   ```bash
   scripts/lv-exec.sh lv-suite-run.sh --label release --build
   ```
   It runs `build_command` and then `test_command` from `claude-workflow.yml`, verbatim and unfiltered, in the worktree you are standing in, and ends with three lines: `SUITE_CMD=`, `SUITE_LOG=`, `SUITE_RESULT=`. **Exit 0 pass, 1 fail, 2 no suite is configured** — 2 is a gap to report and never a pass.

   **`SUITE_RESULT=` is the only thing that may be reported as the verdict, and `SUITE_CMD=` must be quoted beside it.** A count you read out of the output is not evidence of what ran. client-a's WFI-252: a run reported "✓ E2E tests passed: **474 passed, 0 failed**" and pushed `release`. 474 was one assembly; the configured suite on that content was 3100 tests with 121 failures, every one of them in the E2E assembly the run had named as passing. So the run labelled a non-E2E assembly as the E2E suite, never ran the suite it claimed had passed, and pushed on that basis. `/lv-deploy`'s own full run caught it and reset `main` — nothing else would have.

   This is the **release aggregation guarantee** (BRF-080) and it is now enforced rather than requested: every test a feature branch skipped under tiered gating runs here, whole. Narrowing the suite — an assembly, a filter, a category — is not a judgment call available at this step.

   **The suite may outlast a foreground Bash call** (the cap is 10 minutes). Do not background it — detach it and wait in slices:
   ```bash
   scripts/lv-exec.sh lv-suite-run.sh --label release --build --detach   # prints SUITE_HANDLE=
   scripts/lv-exec.sh lv-suite-wait.sh <SUITE_HANDLE>                    # blocks up to 9 minutes
   ```
   `lv-suite-wait.sh` exits **0 pass, 1 fail, 3 still running** — on `3`, call it again with the same handle, as many times as it takes. Each call is its own foreground command under the cap, and each one keeps the session alive. **`3` is neither a pass nor a failure**, and under `LV_UNATTENDED=1` a headless run ends the moment it stops producing output and takes every background job with it — which is how a DEPLOY worker came to announce it was awaiting results and exit sixty seconds later on a red suite (WFI-255). Never report a verdict `lv-suite-wait.sh` did not return.

   **You may not end this turn while the suite you started is unfinished. There is no scheduled wake-up, no "I'll check back", no notification coming.** The loop above is the entire mechanism. client-a WFI-266: two RELEASE workers in one morning reached this step and each wrote a single line — "Waiting for completion with scheduled wakeup at 08:36:00", then "Scheduled to check back on test progress in 5 minutes" — and exited. The second one's suite finished 13 minutes later, 3341 of 3342 passed, 0 failed: a fully green full-suite run nobody acted on. Nothing was pushed. A run 90 minutes earlier did it correctly end to end, same role, same client, same version.

   The cost is not the wasted 22 minutes. Local `release` was left 4 commits ahead of `origin/release`, and that is read downstream as "commits /lv-release did not push, therefore commits that did not pass" — which was exactly wrong, and which no script could tell apart. Until this session's fix the pipeline then had no candidate at all: DEPLOY refuses an unpushed release, and RELEASE needed develop to be ahead.

   **Before spending the suite, ask whether its answer already exists:**
   ```bash
   scripts/lv-exec.sh lv-suite-receipts.sh --for release
   ```
   Exit **0** a run already passed on this exact tip, **1** one failed on it, **2** no receipt — run the suite. A receipt is admissible only because `SUITE_TIP` is stamped into it: a pass measures one tree and says nothing about any other, so a receipt whose tip is not the tip you are standing on is not yours to use. `SUITE_COLLECTED=never` means the worker that started it walked away — that is the WFI-266 shape, and finding your own predecessor's green run there is the normal way this step ends now. Quote the receipt's `SUITE_RESULT=` and `SUITE_CMD=` lines as the verdict, exactly as if you had waited for them, and say which run they came from.

   If tests fail, **first ask whether the suite was even in a position to judge**: re-run
   `scripts/lv-exec.sh lv-preflight.sh`. A prerequisite that went down mid-run implicates the
   environment, not the commits (WFI-028) — report it that way. Either way, do **not** push, and
   **roll the local merge back before you report anything**:
   ```bash
   scripts/lv-exec.sh lv-release-rollback.sh
   ```
   Then inform the user of the failures, quoting that script's line verbatim, and (under
   `LV_UNATTENDED=1`) unclaim and stop.

   **The rollback is not optional and not cosmetic.** Step 6 already fast-forwarded the *local*
   `release` ref onto develop; stopping at "do not push" leaves it there. `main..release` is read
   as "these commits passed E2E" by `lv-list-deploy.sh`, by the daemon, and by `/lv-deploy` —
   and every one of them reads the LOCAL ref. client-b WFI-007: E2E failed 1/117, this step
   exited without resetting, and 71 seconds later the daemon counted 30 commits on
   `release..main` and dispatched a deploy worker, which opened a `deploy-approval` gate quoting
   the whole red batch as ready to promote to production. coordinator WFI-002 is the same finding read
   across every client: unfixed, it blocks enabling the daemon on every client that holds a
   release/deploy grant.

   `lv-release-rollback.sh` resets `release` to `origin/release` — which *is* the pre-merge tip,
   because step 6 pulls it immediately before merging and step 8 pushes only on success. It
   refuses, loudly and without touching anything, if the refs have diverged or the worktree has
   modified tracked files. **Exit 1 means the local ref is still ahead**: say so in the failure
   report and tell the user the deploy signal is untrustworthy until it is reconciled — never
   report "release was not advanced" over a refusal.
8. **Push release branch** — only reached once tests pass:
   ```bash
   git push origin release
   ```
9. **Return to the develop worktree** — you never left it checked out, but this session's own cwd did:
   ```bash
   cd "$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
   ```
   There is nothing to hand back — `release-branches/release` stays on `release`, always, so the orchestrator's own read of `plans/REGISTRY.md` off the develop worktree was never affected by any of this. (Don't cache the path from step 2 in a shell variable — each step here may run as a separate shell, and only the working directory itself is guaranteed to carry over.)
10. **Unclaim, then display result:**
   ```bash
   scripts/lv-exec.sh lv-unclaim.sh RELEASE
   ```

   **On success** — the suite line is step 7's receipt, copied, not composed:
   ```
   ✓ develop merged to release (plan files synced)
   ✓ <the SUITE_RESULT= line, verbatim>
     ran: <the SUITE_CMD= line, verbatim>
     log: <the SUITE_LOG= path>

   NEXT: When ready to promote to production, run:
     /lv-deploy
   ```

   **On failure** — state what the local ref actually did, quoting step 7's rollback line. Never
   assert "not advanced" from the fact that nothing was pushed; that claim is about the local ref
   and only the rollback's own output can support it (WFI-007).

   Rollback succeeded:
   ```
   ✗ E2E tests failed on the local merge — nothing pushed
   ✓ <the lv-release-rollback.sh line, verbatim>

   Fix the issues on the feature branch, create a new PR, and re-run /lv-release.
   Do NOT proceed with /lv-deploy until E2E passes.
   ```

   Rollback refused (exit 1):
   ```
   ✗ E2E tests failed on the local merge — nothing pushed
   ✗ local `release` is STILL ahead of origin/release — the rollback refused:
     <the script's stderr, verbatim>

   Until that is reconciled, `main..release` overstates what passed E2E: /lv-deploy and the
   orchestrator both read that local ref. Do NOT deploy.
   ```

## Unattended mode

Set when `LV_UNATTENDED=1` — the daemon dispatched this run against the fixed `RELEASE` artifact.

- **Stand down quietly if already claimed**, before doing anything else:
  ```bash
  scripts/lv-exec.sh lv-claim.sh RELEASE --if-free
  ```
  Exit `2` → print nothing but a log line and exit 0. A human or another worker already holds
  `RELEASE`; this is not a failure, just a lost race.
- **Skip step 5's confirmation prompt.** In its place, check the two things that can authorize
  this promotion without a human present. **Ask for the one-off approval first** — it is an
  answer a human actually gave about *these* commits, where a standing grant is a policy written
  in advance:
  ```bash
  scripts/lv-exec.sh lv-promote-approval.sh release
  ```
  | Exit | What it means | What you do |
  |-|-|-|
  | `0` | A human approved this exact batch at the `release-approval` gate, and `develop` has not moved since | Quote the script's line and continue at step 6 — **do not** ask `lv-autonomy.sh`, and do not open a gate |
  | `1` | No answer of record, or it was a rejection, or it was closed without a recorded decision | Fall through to the autonomy check below |
  | `2` | An approval exists, but `develop` has moved on — it covered a different batch | Fall through to the autonomy check below, and if that also refuses, say so in the gate question: the human should know they are being asked again because new commits landed, not because their answer was lost |

  A gate approval reaching the merge is what closes client-b WFI-005: `/lv-attend` closed the
  `release-approval` gate with an approval at 19:25:49Z, the daemon dispatched this skill a
  minute later, the run asked `lv-autonomy.sh`, was told no — and re-opened the gate it had just
  been let through. Twice. `lv-autonomy.sh` knows only about standing grants; it has never known
  anything about the answer a human just gave, so asking it alone can only ever produce that
  loop.

  Then, only if the above did not authorize it, check for standing authorization:
  ```bash
  scripts/lv-exec.sh lv-autonomy.sh release
  ```
  | Exit | What it means | What you do |
  |-|-|-|
  | `0` | `release` runs unattended by default (WFI-006), or a dated, unexpired, human-authored grant covers it | Quote the script's line and continue at step 6 |
  | `1` | No grant, or it does not cover `release`, or it has expired or hit its daily ceiling | Open the gate below, then unclaim and exit 0 — **STOP. Do not merge, push, or run step 6 or anything after it.** |
  | `2` | The grant is malformed — it is not a refusal, it is a broken config | Open the gate below with the script's stderr in the question verbatim, then unclaim and exit 0 — **STOP, same as exit 1.** |

  Never treat exit 2 as "proceed" — a grant nobody can parse authorized nothing.
  ```bash
  scripts/lv-exec.sh lv-gate-open.sh RELEASE release-approval "<commit list from step 3>" --skill lv-release
  scripts/lv-exec.sh lv-unclaim.sh RELEASE
  ```
  `lv-gate-open.sh` exiting 3 means `release-approval` already has an answer of record — act on
  it (it names the resolution) rather than re-asking, per the standing gate-reopening rule.

  **This run is finished the moment `lv-unclaim.sh RELEASE` above returns — nothing else in this
  document is a next step.** client-c's WFI-032: a worker refused at this exact check,
  opened the gate, and then went on to merge `develop` into `release` and push it anyway before
  exiting `rc=0` — the run continued into step 6 after the refusal instead of ending here. The
  gate exists so that a refused promotion never happens; opening it and then doing the thing it
  refused makes the gate theater. Exit `1` and exit `2` both end the run at the `lv-unclaim.sh`
  call above, full stop — never at step 6, step 7, or anywhere past it.
- **Resolve every other `[GATE]` or would-ask-a-human point in the steps above the same way** —
  open a gate naming the question, unclaim, and exit 0. Never guess, never hang.
- **On every exit path** — grant found and the run proceeds to completion, gate opened, or an
  error stops the run early — `scripts/lv-exec.sh lv-unclaim.sh RELEASE` is the last action
  before finishing.

## Rules

- **Claim `RELEASE` before touching anything, unclaim before finishing** — step 1 claims it; every exit path, success or failure, ends with `lv-unclaim.sh RELEASE`
- **Work in `release-branches/release`** — step 2 pins it and moves you there; every step through 9 assumes that cwd
- **Do NOT merge to main** — that's `/lv-deploy`
- **Do NOT update REGISTRY.md** — plan states are already set by `lv-test` and `lv-deploy`
- **Do NOT** force push — use regular merge
- **Run the configured suite through `lv-suite-run.sh`, whole** — never a hand-typed or narrowed test command. Report its `SUITE_RESULT=` line verbatim with `SUITE_CMD=` beside it; a pass asserted from a count you read is how one assembly's 474 tests were pushed to `release` as the whole E2E suite (WFI-252)
- **A run that refuses to push has accomplished nothing, and must read that way** — say so plainly, unclaim, and stop. The orchestrator's forward-progress signal for `RELEASE` is `origin/release`, not the local ref, precisely so a failed run whose rollback refused (local `release` left ahead) no longer resets the attempt budget and spawns the next release worker: client-a's WFI-254 burned 3 of a 4/day standing grant that way, three runs in a row, each one reporting "Do NOT deploy"
- **Do NOT push `release` before E2E passes, and roll the local merge back when it doesn't** — step 7 runs tests against the local merge, step 8 pushes only on success, and step 7's `lv-release-rollback.sh` returns the local ref on failure. All three are needed for `main..release` to stay a trustworthy "these commits passed" signal: `/lv-deploy` and the daemon read the LOCAL ref, so a failed run that only skips the push still hands them a batch that never passed (WFI-007, coordinator WFI-002)
- **Complete all steps** — if the user interrupts mid-run, tell them which step to resume at; there is no shared checkout to leave parked, so an interruption costs nothing beyond finishing later
- **Return your own cwd to the develop worktree at step 9** — not because anything needs it back (nothing else ever touches `release-branches/release`), but so the session you're running in ends up back where the human expects it

## On startup

1. Claim `RELEASE` (step 1)
2. Pin `release` to `release-branches/release` and move into it (step 2)
3. Check for commits on `release` that aren't on `main`
4. If new commits exist: show them and prompt user to confirm proceeding
5. If no new commits: inform user there is nothing to release, unclaim

## Committing work

This skill creates one merge commit (`develop → release`) and one push. No other commits are created.

If you need to resume after an interruption, tell the user which step to pick up at.

On completion, run `scripts/lv-exec.sh lv-check-reboot-flag.sh` and append any output to your completion message.

## Usage

```text
/lv-release             merge develop into release and run E2E against it.
                        Stops there — /lv-deploy promotes to main
```
