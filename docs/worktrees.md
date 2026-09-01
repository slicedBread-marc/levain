# Feature worktrees — what is in one, and why

A plan is built in a linked git worktree at `feature-branches/PLN-NNN-<slug>/`
on branch `feature/PLN-NNN-<slug>`. Everything the workflow owns lives on
`develop`; the worktree carries the plan's code changes and nothing else.

Two mechanisms keep it that way, and they are **mutually exclusive per path**.
Getting that wrong is what produced client-a WFI-021: 33 files an implementer
never touched showing as modified, and a `git merge develop` that aborted.

## The rule

> A sparse-checkout exclusion holds only while the path is **absent** from the
> working tree, or **byte-identical** to the branch's committed blob.

Write different content to an excluded path and git drops its `skip-worktree`
bit on the next index refresh. The file shows as modified,
`git sparse-checkout reapply` refuses to re-exclude it ("not up to date and were
left despite sparse patterns"), and `git merge develop` fails with *your local
changes would be overwritten* before it reaches a real conflict.

So a path may be excluded **only if nothing materialises it**.

## Excluded — develop-owned, never written into a worktree

Configured by `wf-worktree-sparse.sh`:

| Path | Resolved instead from |
|-|-|
| `plans/**` | the develop worktree (the registry has one writer) |
| `templates/**` | develop |
| `.claude/workflow-version` | the plan's `WF` column, then develop's stamp |
| `scripts/version-map.txt` | the main worktree |
| `scripts/v*/wf-*.sh` | the main worktree |
| `scripts/wf-prune-versions.sh` | the main worktree |

`wf-exec.sh`'s `find_project_root` answers with the **main** worktree, so a
worktree copy of a versioned script is never the one that runs. Copying them in
bought nothing and cost the exclusion.

## Gitignored — a session reads these off its own disk

`.claude/workflow.md`, `.claude/skills/wf-*/`, `scripts/wf-exec.sh`, `.plan-ref`.

Claude Code loads skills from the tree it is running in, and skills invoke
`scripts/wf-exec.sh` by relative path, so these three must **physically exist**
in every feature worktree.

They used to be tracked, which is one way to get a file into a new worktree —
git materialises tracked files on `git worktree add`. `install.sh` also wrote
them. **Two delivery mechanisms for one requirement**, and their collision was
the entire problem: deploy rewrote a tracked path, the worktree went dirty
against its own branch, `git merge develop` aborted before it could conflict on
anything real, and a script existed solely to commit develop's own bytes onto
the feature branch to make it stop.

As of **v5.0.0** they are gitignored and arrive one way: `wf-worktree-harness.sh`
copies them from the main worktree. An ignored file cannot go dirty, cannot
conflict, and cannot abort a merge, so there is nothing left to reconcile —
`wf-infra-sync.sh` was deleted rather than fixed. See
[`untracked-harness.md`](untracked-harness.md).

The `wf-` prefix on the skills glob is load-bearing: a project's own skills sit
in the same directory, are its source rather than ours, and stay tracked.

### `.plan-ref` — the same lesson, arrived at twice

`.plan-ref` names the plan **this worktree** is building. `wf-implement` writes
it at worktree creation; `wf-plan-ref.sh`, `wf-rehydrate.sh` and the
`on-implement-commit` hook read it off disk. Nothing reads it out of git.

It was nonetheless *committed* until **v6.0.0** — and a committed pointer does
not stay in the worktree it points at. It travels with the branch: feature →
release on the PR merge, release → main on deploy, main → develop on the
back-merge. client-a's WFI-103 found develop tracking a `.plan-ref` reading
`PLN-015`, carried in by that plan's own merge commit.

That is worse than litter, because the loop closes on itself:

1. `git worktree add` materialises tracked files, so the next worktree is born
   pointing at a plan that finished weeks ago.
2. `wf-implement` overwrites it with the right ID — which now registers as a
   modification to a **tracked** file rather than a new ignored one.
3. The next `git add -A` in the implement loop stages that modification, and the
   next merge carries the new value onward. Go to 1.

Untracking breaks the loop at step 2: an ignored file has no committed blob to
differ from. Note that `.gitignore` does not untrack anything already in the
index — `install.sh` prints the one-time `git rm --cached .plan-ref` a
pre-v6.0.0 client still owes.

## The three states a path can be in

Decide which one applies *before* adding a path, and put it in exactly one:

| State | When | Where it goes |
|-|-|-|
| **Gitignored** | The library generates it, and a session needs it on the worktree's disk | the ignore list in `install.sh`, and the copy list in `wf-worktree-harness.sh` |
| **Sparse-excluded** | Develop owns it and nothing materialises it in a worktree | the pattern list in `wf-worktree-sparse.sh` |
| **Tracked normally** | The project authors it | neither list |

The rule that makes this a contract rather than a preference, from
`wf-worktree-sparse.sh`'s own header:

> Excluding a file you also write is not a stricter policy than tracking it; it
> is a broken one.

A path that is both sparse-excluded and written by deploy breaks git outright —
that is WFI-021. A path that is both **tracked** and written by deploy is the
milder version of the same mistake: it does not break, it just leaves every
client permanently dirty and needs a reconciliation script to hide it. Generated
content belongs in neither state; it belongs in the first row.
