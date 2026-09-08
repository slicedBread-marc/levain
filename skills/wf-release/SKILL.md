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

1. **Pin `release` to its own worktree and move into it:**
   ```bash
   eval "$(scripts/wf-exec.sh wf-worktree-pin.sh release release-branches/release)"
   cd "$WORKTREE_PATH"
   ```
   `release-branches/release` is `release`'s permanent home — created once, reused forever, never the shared develop checkout. Before this, `/wf-release` moved the shared main worktree onto `release` for the duration of the run: the orchestrator reads `plans/REGISTRY.md` from that worktree, and on `release` that file is whatever release last merged, so every plan whose state advanced since then read stale — client-a's PLN-051 read `active` there while develop had it `complete`, and two unattended builders were dispatched at a finished plan (WFI-135, WFI-134, WFI-157). Pinning `release` to its own path removes the borrowing: develop's worktree never leaves develop, so there is nothing to hand back at the end and nothing for a parallel session to catch mid-move. See [`docs/release-worktrees.md`](../../docs/release-worktrees.md).

   Everything from here through step 8 runs **in `release-branches/release`**, not the project root — every command below assumes that cwd.
2. **Check if release has unreleased commits:**
   ```bash
   git log main..release --oneline | head -10
   ```
3. **If no new commits on release vs main**: inform the user ("Release is up to date with main — nothing to release.") and exit. Next step: work on a plan with `/wf-implement`, test it with `/wf-test`, then return here.
3a. **Check for open deferred criteria on the plans being staged:**
   ```bash
   scripts/wf-exec.sh wf-deferred-check.sh $(git log main..release --oneline | grep -oE 'PLN-[0-9]+' | sort -u)
   ```
   Exit `1` — show its output to the user alongside the commit list in the next step. These are
   `external`/`soak`/`unbuilt` criteria read from `plans/deferred-criteria.md` that a plan shipped
   without — most are harmless, but one describing a hard runtime dependency (a secret, a
   certificate, a required external service) can crash production if `/wf-deploy` promotes it
   before that dependency exists (WFI-011). Surfacing here gives `/wf-deploy` a second, earlier
   read of the same list.
4. **Show commits to user** — display the commit list from step 2. Tell the user: "Run `/model haiku` if not already on it, then confirm to proceed." Then prompt: "These commits are staged for E2E. Proceed? (y/n)"
   Wait for explicit confirmation before continuing.

   **Under `WF_UNATTENDED=1` there is nobody to prompt.** Ask whether the project has recorded standing authorization instead:
   ```bash
   scripts/wf-exec.sh wf-autonomy.sh release
   ```
   | Exit | What it means | What you do |
   |-|-|-|
   | `0` | A dated, unexpired, human-authored grant covers `release` | Say which grant authorized it, quoting the script's line, and continue at step 5 |
   | `1` | No grant, or it does not cover `release`, or it has expired or hit its daily ceiling | **[GATE]** `release-approval` with the commit list as the question, then exit 0 |
   | `2` | The grant is malformed — it is not a refusal, it is a broken config | **[GATE]** `release-approval`, and put the script's stderr in the question verbatim so the next human fixes the file |

   Never treat exit 2 as "proceed". A grant nobody can parse authorized nothing.
5. **Merge `develop` into `release`** to bring plan files and REGISTRY state:
   ```bash
   git pull origin release
   git merge origin/develop --no-edit
   ```
   If this fails with non-trivial conflicts, inform the user and stop — do not proceed to E2E.

5a. **Check the harness survived the merge** — run this immediately, before anything else:
   ```bash
   [ -x scripts/wf-exec.sh ] && [ -f scripts/version-map.txt ] && echo "harness ok" \
     || echo "HARNESS MISSING"
   ```
   `harness ok` → continue at step 6.

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
   That regenerates the harness this project's `.claude/workflow-version` actually names, and leaves the tree clean because the files are gitignored. **Re-run the step 5a check** — do not take the installer's exit code as the answer. On `harness ok`, continue at step 6; on `NO LIBRARY` or a still-missing harness, use the history recovery below.

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
6. **Push release branch:**
   ```bash
   git push origin release
   ```
7. **Run E2E / integration tests** (staging validation):
   ```bash
   {{build_command}} < /dev/null
   {{test_command}} < /dev/null
   # Full suite — no filter. Release aggregation guarantee (BRF-080):
   # every test skipped on a feature branch by tiered gating MUST run here.
   ```
   If tests fail, inform the user of failures. The release branch stays as-is for fixes.
8. **Return to the develop worktree** — you never left it checked out, but this session's own cwd did:
   ```bash
   cd "$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"
   ```
   There is nothing to hand back — `release-branches/release` stays on `release`, always, so the orchestrator's own read of `plans/REGISTRY.md` off the develop worktree was never affected by any of this. (Don't cache the path from step 1 in a shell variable — each step here may run as a separate shell, and only the working directory itself is guaranteed to carry over.)
9. **Display result**:

   **On success:**
   ```
   ✓ develop merged to release (plan files synced)
   ✓ E2E tests passed on release branch

   NEXT: When ready to promote to production, run:
     /wf-deploy
   ```

   **On failure:**
   ```
   ✗ E2E tests failed on release branch

   Fix the issues on the feature branch, create a new PR, and re-run /wf-release.
   Do NOT proceed with /wf-deploy until E2E passes.
   ```

## Rules

- **Work in `release-branches/release`** — step 1 pins it and moves you there; every step through 7 assumes that cwd
- **Do NOT merge to main** — that's `/wf-deploy`
- **Do NOT update REGISTRY.md** — plan states are already set by `wf-test` and `wf-deploy`
- **Do NOT** force push — use regular merge
- **Complete all steps** — if the user interrupts mid-run, tell them which step to resume at; there is no shared checkout to leave parked, so an interruption costs nothing beyond finishing later
- **Return your own cwd to the develop worktree at step 8** — not because anything needs it back (nothing else ever touches `release-branches/release`), but so the session you're running in ends up back where the human expects it

## On startup

1. Pin `release` to `release-branches/release` and move into it (step 1)
2. Check for commits on `release` that aren't on `main`
3. If new commits exist: show them and prompt user to confirm proceeding
4. If no new commits: inform user there is nothing to release

## Committing work

This skill creates one merge commit (`develop → release`) and one push. No other commits are created.

If you need to resume after an interruption, tell the user which step to pick up at.

On completion, run `scripts/wf-exec.sh wf-check-reboot-flag.sh` and append any output to your completion message.
