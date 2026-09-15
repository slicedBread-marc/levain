---
name: wf-release
description: Merge develop into release, run E2E tests to validate staging. Stops here — use /wf-deploy to promote to main.
user_invocable: true
model: haiku
---

# Release Role

You are in **release mode**. Your job is to sync `develop` into `release`, validate staging with E2E tests, and confirm it's ready for production promotion. This skill does NOT promote to main — that's `/wf-deploy`.

## State context

```
plans/REGISTRY.md      → single source of truth (plans stay in "complete" state after this skill)
release-branches/release → release's own permanent worktree — staging environment for E2E validation
```

## What you do

1. **Claim the release slot:**
   ```bash
   scripts/wf-exec.sh wf-claim.sh RELEASE
   ```
   `RELEASE` is a fixed, singleton artifact id — there is only ever one release pipeline, so this
   claim excludes a second concurrent `/wf-release` (attended vs. attended, attended vs. the
   daemon, or daemon vs. daemon), the same way `wf-test` claims a plan before touching it.

   | Exit | What it means | What you do |
   |-|-|-|
   | `0` | Claimed | Continue at step 2 |
   | `2` | Another live session already holds it | Tell the user who holds it (the script's output names the session) and stop. If they believe it's stuck, offer `scripts/wf-exec.sh wf-claim.sh RELEASE --steal` |

   **From here on, whatever happens — success, test failure, "nothing to release," or a parked
   gate — the last thing you do before finishing is `scripts/wf-exec.sh wf-unclaim.sh RELEASE`.**
   Every exit path below says so again at the point it applies, but the rule is unconditional:
   never leave this skill without unclaiming.

2. **Pin `release` to its own worktree and move into it:**
   ```bash
   eval "$(scripts/wf-exec.sh wf-worktree-pin.sh release release-branches/release)"
   cd "$WORKTREE_PATH"
   ```
   `release-branches/release` is `release`'s permanent home — created once, reused forever, never the shared develop checkout. Before this, `/wf-release` moved the shared main worktree onto `release` for the duration of the run: the orchestrator reads `plans/REGISTRY.md` from that worktree, and on `release` that file is whatever release last merged, so every plan whose state advanced since then read stale — client-a's PLN-051 read `active` there while develop had it `complete`, and two unattended builders were dispatched at a finished plan (WFI-135, WFI-134, WFI-157). Pinning `release` to its own path removes the borrowing: develop's worktree never leaves develop, so there is nothing to hand back at the end and nothing for a parallel session to catch mid-move. See [`docs/release-worktrees.md`](../../docs/release-worktrees.md).

   Everything from here through step 9 runs **in `release-branches/release`**, not the project root — every command below assumes that cwd.
3. **Check if develop has unreleased commits.** Fetch first — this worktree is pinned and long-lived, so the local `release` ref can be stale relative to `origin/release` if another session pushed since this worktree last touched it (WFI-024, WFI-027):
   ```bash
   git fetch origin release
   git log origin/release..develop --oneline | head -10
   ```
   This must compare `release` against `develop`, never against `main`. Right after every `/wf-deploy`, `release` and `main` are identical by construction, so `main..release` is always empty and would report "nothing to release" even when develop has a full backlog of completed plans waiting to ship (WFI-024).

   **Filter out `/wf-deploy`'s own bookkeeping commits before deciding whether there's anything
   here.** `/wf-deploy` never advances `release` itself (nothing but `/wf-release` and
   `/wf-deploy` may touch `release-branches/*`, and neither reaches into the other's —
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
   stops it from being asked again: a real /wf-release run only happens once real work exists to
   filter down to, so the next unattended dispatch has nothing left to loop on (client-c
   WFI-030 — this cycle, unfixed, alternated `release-approval` and `deploy-approval` gates
   indefinitely, each answered one freeing a dispatch that reopened the other). If the filtered
   list is non-empty, proceed with the FULL unfiltered range from step 3 below — real work present
   makes the bookkeeping commits harmless to include alongside it.
4. **If that range is empty** (or filters down to empty, above): inform the user ("Release is up to date with develop — nothing to release."). **If this is an attended run** (`WF_UNATTENDED` unset), also close a stale `release-approval` gate before unclaiming — nothing being left to release means whatever that gate asked about was already promoted or abandoned by some other path, and a human running this attended is exactly the moment to clear it rather than leave it for `/wf-attend` to notice later (client-c WFI-031: an unattended dispatch kept reopening `release-approval` for commits a human had already promoted by hand, because nothing ever told the gate the promotion had happened — this closes that gap the next time a human is actually here to answer for it):
   ```bash
   if [ "${WF_UNATTENDED:-0}" != "1" ] \
      && scripts/wf-exec.sh wf-list-gates.sh RELEASE 2>/dev/null | grep -q "$(printf '\t')release-approval$(printf '\t')"; then
     scripts/wf-exec.sh wf-gate-close.sh RELEASE "nothing left to release — already up to date"
   fi
   ```
   Then unclaim (`scripts/wf-exec.sh wf-unclaim.sh RELEASE`) and exit. Next step: work on a plan with `/wf-implement`, test it with `/wf-test`, then return here.
4a. **Check for open deferred criteria on the plans being staged:**
   ```bash
   scripts/wf-exec.sh wf-deferred-check.sh $(git log origin/release..develop --oneline | grep -oE 'PLN-[0-9]+' | sort -u)
   ```
   Exit `1` — show its output to the user alongside the commit list in the next step. These are
   `external`/`soak`/`unbuilt` criteria read from `plans/deferred-criteria.md` that a plan shipped
   without — most are harmless, but one describing a hard runtime dependency (a secret, a
   certificate, a required external service) can crash production if `/wf-deploy` promotes it
   before that dependency exists (WFI-011). Surfacing here gives `/wf-deploy` a second, earlier
   read of the same list.
5. **Show commits to user** — display the commit list from step 3. Tell the user: "Run `/model haiku` if not already on it, then confirm to proceed." Then prompt: "These commits are staged for E2E. Proceed? (y/n)"
   Wait for explicit confirmation before continuing.

   **Under `WF_UNATTENDED=1` there is nobody to prompt.** See "Unattended mode" below — it replaces this confirmation with a standing-grant check and a concrete `release-approval` gate, then either continues at step 6 or exits.
6. **Push local `develop`, then merge it into `release`** to bring plan files and REGISTRY state. Nothing in the pipeline pushes `develop` mid-cycle — only `/wf-deploy`'s back-merge does, right at the end — so `origin/develop` is routinely behind the local branch every other skill has been committing to. Merging `origin/develop` without pushing first silently drops everything committed since the last deploy: client-a's WFI-250 merged 39 commits behind, picked up only the bookkeeping paths that happened to already be pushed, and the omission of a whole plan's code and tests was caught only by noticing its plan folder absent from the release worktree afterward — the full test suite passed regardless, because it never contained the missing plan's tests to fail.
   ```bash
   git push origin develop
   git pull origin release
   git merge origin/develop --no-edit
   ```
   A push rejected as non-fast-forward means another session pushed `develop` from elsewhere between your read of it and now — pull and reconcile there before retrying; never force. If the merge fails with non-trivial conflicts, inform the user (and, under `WF_UNATTENDED=1`, unclaim) and stop — do not proceed to E2E.

6a. **Check the harness survived the merge** — run this immediately, before anything else:
   ```bash
   [ -x scripts/wf-exec.sh ] && [ -f scripts/version-map.txt ] && echo "harness ok" \
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

   **Only if the library is unreachable**, recover from history with plain git — but understand what you are getting. The newest ref that still *tracks* the harness is, by definition, a ref from before this client's untrack commit, so the further back that migration is, the staler the restore. client-a's WFI-119 recovered a v3.3.0-era harness into a project stamped 6.2.1 and reported success: three major versions of stale `wf-*` scripts, which is the exact failure mode WFI-014 warns about. **Find the ref first — do not assume `HEAD@{1}` — and check its version before trusting it:**
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
     | grep -E '^(scripts/(wf-exec\.sh|wf-prune-versions\.sh|version-map\.txt|v[^/]+/)|\.claude/(skills/wf-|workflow\.md))' \
     > /tmp/wf-harness-paths
   xargs git checkout "$ref" -- < /tmp/wf-harness-paths
   xargs git rm --cached --quiet -- < /tmp/wf-harness-paths
   ```
   The checkout brings the files back; the `rm --cached` returns them to untracked, which is what the ignore rules already describe — so the working tree ends clean. Once the harness is back, `scripts/wf-exec.sh wf-harness-restore.sh` does all of this in one call for any future occurrence: library first, then a version-matched ref, and it exits 3 rather than lying to you when all it could find was a stale one.

   **Why the search, and not a fixed distance.** The deletion is not reliably one step behind. client-e's WFI-014: step 5's `git pull origin release` fast-forwarded 75 commits, straight through the untrack commit — so `HEAD@{1}` was already *past* the deletion, the path list came back empty, and the recovery restored zero files while reporting nothing wrong. `HEAD@{2}` held all 82 paths. A local release branch many commits behind origin is the normal case.

   Never `git rm -r --cached scripts` wholesale — a project may keep its own tooling there, and untracking it turns a recovery into a larger accident.

   **After any restore, keep running everything through `scripts/wf-exec.sh`.** A client that predates v5 may still carry flat `scripts/wf-*.sh` files tracked in git; those are pre-untracking copies and they are stale. `scripts/v*/` is the live harness, and `wf-exec.sh` is what resolves to it — calling a flat script directly silently runs old code (WFI-014).

   This happens **once per client**, on the first release after the harness is untracked on develop, and it self-clears when the change reaches `main`. It is silent and total while it lasts: client-c lost 106 files including `wf-exec.sh` mid-skill and only found out at step 8, with exit 127 (WFI-006).
7. **Run E2E / integration tests** (staging validation), against the local merge — before anything is pushed:
   ```bash
   {{build_command}} < /dev/null
   {{test_command}} < /dev/null
   # Full suite — no filter. Release aggregation guarantee (BRF-080):
   # every test skipped on a feature branch by tiered gating MUST run here.
   ```
   If tests fail, inform the user of failures (and, under `WF_UNATTENDED=1`, unclaim) and stop —
   do **not** push. The `release` branch is not advanced, so `main..release` stays a reliable
   signal that whatever *is* on `release` already passed this suite (`/wf-deploy`, and the
   daemon's own eligibility check, both depend on that).
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
   scripts/wf-exec.sh wf-unclaim.sh RELEASE
   ```

   **On success:**
   ```
   ✓ develop merged to release (plan files synced)
   ✓ E2E tests passed on release branch

   NEXT: When ready to promote to production, run:
     /wf-deploy
   ```

   **On failure:**
   ```
   ✗ E2E tests failed on the local merge — release branch was NOT advanced

   Fix the issues on the feature branch, create a new PR, and re-run /wf-release.
   Do NOT proceed with /wf-deploy until E2E passes.
   ```

## Unattended mode

Set when `WF_UNATTENDED=1` — the daemon dispatched this run against the fixed `RELEASE` artifact.

- **Stand down quietly if already claimed**, before doing anything else:
  ```bash
  scripts/wf-exec.sh wf-claim.sh RELEASE --if-free
  ```
  Exit `2` → print nothing but a log line and exit 0. A human or another worker already holds
  `RELEASE`; this is not a failure, just a lost race.
- **Skip step 5's confirmation prompt.** In its place, check for standing authorization:
  ```bash
  scripts/wf-exec.sh wf-autonomy.sh release
  ```
  | Exit | What it means | What you do |
  |-|-|-|
  | `0` | A dated, unexpired, human-authored grant covers `release` | Say which grant authorized it, quoting the script's line, and continue at step 6 |
  | `1` | No grant, or it does not cover `release`, or it has expired or hit its daily ceiling | Open the gate below, then unclaim and exit 0 — **STOP. Do not merge, push, or run step 6 or anything after it.** |
  | `2` | The grant is malformed — it is not a refusal, it is a broken config | Open the gate below with the script's stderr in the question verbatim, then unclaim and exit 0 — **STOP, same as exit 1.** |

  Never treat exit 2 as "proceed" — a grant nobody can parse authorized nothing.
  ```bash
  scripts/wf-exec.sh wf-gate-open.sh RELEASE release-approval "<commit list from step 3>" --skill wf-release
  scripts/wf-exec.sh wf-unclaim.sh RELEASE
  ```
  `wf-gate-open.sh` exiting 3 means `release-approval` already has an answer of record — act on
  it (it names the resolution) rather than re-asking, per the standing gate-reopening rule.

  **This run is finished the moment `wf-unclaim.sh RELEASE` above returns — nothing else in this
  document is a next step.** client-c's WFI-032: a worker refused at this exact check,
  opened the gate, and then went on to merge `develop` into `release` and push it anyway before
  exiting `rc=0` — the run continued into step 6 after the refusal instead of ending here. The
  gate exists so that a refused promotion never happens; opening it and then doing the thing it
  refused makes the gate theater. Exit `1` and exit `2` both end the run at the `wf-unclaim.sh`
  call above, full stop — never at step 6, step 7, or anywhere past it.
- **Resolve every other `[GATE]` or would-ask-a-human point in the steps above the same way** —
  open a gate naming the question, unclaim, and exit 0. Never guess, never hang.
- **On every exit path** — grant found and the run proceeds to completion, gate opened, or an
  error stops the run early — `scripts/wf-exec.sh wf-unclaim.sh RELEASE` is the last action
  before finishing.

## Rules

- **Claim `RELEASE` before touching anything, unclaim before finishing** — step 1 claims it; every exit path, success or failure, ends with `wf-unclaim.sh RELEASE`
- **Work in `release-branches/release`** — step 2 pins it and moves you there; every step through 9 assumes that cwd
- **Do NOT merge to main** — that's `/wf-deploy`
- **Do NOT update REGISTRY.md** — plan states are already set by `wf-test` and `wf-deploy`
- **Do NOT** force push — use regular merge
- **Do NOT push `release` before E2E passes** — step 7 runs tests against the local merge; step 8 pushes only on success, so `main..release` stays a trustworthy "these commits passed" signal
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

On completion, run `scripts/wf-exec.sh wf-check-reboot-flag.sh` and append any output to your completion message.
