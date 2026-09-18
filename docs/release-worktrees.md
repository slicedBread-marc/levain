# Release worktrees — `release` and `main` get their own

`/wf-release` and `/wf-deploy` each pin their branch to a persistent linked
worktree — `release-branches/release` and `release-branches/main` — created
once via `wf-worktree-pin.sh` and reused on every subsequent run. Neither
skill checks out its branch in the shared develop worktree anymore.

## What this replaces

Before this, both skills borrowed the *shared* main worktree — the single
project-root checkout that every terminal, every skill, and the orchestrator
treat as canonical (`wf_develop_root()` in `wf-orch-lib.sh` resolves to it:
the first entry `git worktree list --porcelain` reports, which is always the
original clone, never a `git worktree add` result). `/wf-release` ran `git
checkout release` there; `/wf-deploy` ran `git checkout main`; each handed
the checkout back to `develop` when it finished.

For as long as either checkout lasted:

- `plans/REGISTRY.md` at that path was `release`'s or `main`'s older copy,
  not develop's — every plan whose state had advanced since the last sync
  read stale. The orchestrator's `checkout_available()` (`wf-orchestrate.sh`)
  refuses to dispatch anything while the shared worktree is off `develop`
  specifically because of this — a documented, sound guard, but its cost was
  a paused pipeline for the whole release or deploy.
- Any other session — human or unattended — standing in that same directory
  found itself on `release` or `main` without having done anything to cause
  it. client-a's WFI-135 (two `wf-implement` workers dispatched at a
  finished plan because the registry they read was release's stale copy) and
  WFI-157 (a spec worker's own branch-check flipped the shared checkout from
  `main` to `develop` three and a half minutes into `/wf-deploy`'s test
  suite, silently redirecting that deploy's remaining commits to the wrong
  branch) are both this same borrowing, from two different sides of it.
  WFI-213 is a client that had already worked around the problem by hand,
  keeping `release` permanently checked out in its own worktree — which is
  exactly the shape this generalizes into the default, rather than a special
  case `/wf-deploy` had to detect.

## The shape now

```
<project root>/              → develop's worktree. Never leaves develop. Ever.
release-branches/release/    → release's worktree. Pinned by /wf-release step 1.
release-branches/main/       → main's worktree. Pinned by /wf-deploy step 5.
```

`wf-worktree-pin.sh <branch> <path>` (in `scripts/v*/`) creates the worktree
on first use — tracking a local branch if one exists, tracking
`origin/<branch>` if only a remote copy does, or branching fresh off
`develop` for a greenfield project with neither — and refuses to touch a
worktree that already exists but is on the wrong branch, on the theory that
a pinned worktree found off its pin is a human's deliberate action, not
something to silently correct. Every subsequent run just moves in
(`cd "$WORKTREE_PATH"`) and reuses it.

Both are gitignored the same way `feature-branches/PLN-NNN/` is
(`install.sh` adds the pattern) — they are workflow-generated state, not
project content.

### Why these two are NOT sparse, unlike feature worktrees

`docs/worktrees.md` documents why a *feature* worktree excludes
`plans/**`, `templates/**` and the versioned `scripts/v*/` — develop owns
those, and nothing should ever write a divergent copy into a branch that
will merge back. `release-branches/release` and `release-branches/main` are
the opposite case: carrying `plans/**` (REGISTRY.md above all) forward
through the merge chain *is* the reason they exist. They get a full
checkout, same as any ordinary `git worktree add` without sparse-checkout
configured, and only the gitignored harness paths (`scripts/wf-exec.sh`,
`.claude/skills/wf-*/`, `.claude/workflow.md`, `.claude/settings.local.json`)
are copied in by `wf-worktree-harness.sh` — the same mechanism, and the same
reason, as for a feature worktree.

## What this removes, not just relocates

- The orchestrator's `checkout_available()` skip rule — dispatch pausing
  because the shared worktree is on `release`/`main`/`main worktree is not
  develop` — is now unreachable through the documented release/deploy flow.
  It still exists as a guard against a human parking the shared checkout
  somewhere else by hand (a real, if rare, case); it simply never fires for
  a release or a deploy anymore.
- `wf-branch-check.sh`'s `release|main|master` special-casing (the refusal
  built for WFI-157/WFI-156) is dead code for the same reason: nothing but
  `/wf-release` and `/wf-deploy` ever touches `release-branches/*`, and
  neither of them calls `wf-branch-check.sh` against it. It is left in place
  as defense-in-depth for any client session still running a pre-migration
  copy of these skills.
- `/wf-deploy`'s old step 7a — holding `WF_REQUIRE_BRANCH=main` across steps
  8–10 so a commit made mid-suite couldn't land on the wrong branch — is
  gone. That guard existed because the shared worktree could be moved out
  from under a running deploy by something else entirely (WFI-157); nothing
  else ever reaches `release-branches/main`, so there is nothing left to
  guard against beyond a quick sanity check. Step 10's own
  `wf-commit.sh ... --branch main` is that sanity check, and it stays: it
  costs one `git branch --show-current`, and it is the one thing standing
  between a stray commit and the wrong branch if a human ever `cd`s into
  `release-branches/main` by hand and checks something else out mid-deploy —
  a narrower threat than WFI-157's shared-checkout race, but not a
  nonexistent one.

## What the pinning costs: a local `release` ref nobody in this session moves

Pinning has a consequence worth stating outright, because it cost a production deploy.
`release` now lives in a worktree a given session never enters, so the *local* `release` ref
holds whatever the last run **in this checkout** left there — not what the last `/wf-release`
anywhere pushed. Every downstream reader is local: `git rev-list --count release --not main`
is the eligibility signal, and `git merge release` is the promotion.

client-a WFI-258: an unattended `/wf-deploy` merged a local `release` that was 34 commits
behind `origin/release`, ran the full suite green on that stale tree, pushed `main`, and
reported *"15 commits promoted (PLN-273 work)"*. PLN-273 was registry-complete, on
`origin/release`, and not in production. Nothing detected it — a stale tree builds, the suite
passes, and the completion message names plans the merge never carried. Only the *ahead*
direction had a guard (client-b WFI-007, unpushed commits); behind had none.

`wf-release-sync.sh` is that guard, run by `/wf-deploy` step 2a before anything reads the ref:
in sync or fast-forwarded → 0, ahead → 2, diverged → 3, unanswerable → 1. Behind-only is the
one case it repairs rather than refuses, because a behind-only ref has nothing local to lose —
the repair is a fast-forward and never a reset. **Any new reader of `release --not main` has the
same exposure**; put the sync in front of it.

## Migration note for an existing client

The first `/wf-release` or `/wf-deploy` run after this lands creates the
pinned worktree the first time it's needed. The one failure mode worth
knowing: if the shared worktree happens to be parked on `release` or `main`
from a run of the *old* skill that never handed the checkout back, `git
worktree add release-branches/release release` fails outright — git refuses
to check out a branch in two places at once. `wf-worktree-pin.sh` reports
this rather than guessing; resolve it by returning the shared worktree to
`develop` (`git checkout develop` there) and re-running.
