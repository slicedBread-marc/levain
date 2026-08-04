# Untracked harness — the client copy is build output, not source

> **Status: proposed, not implemented.** Targets **v5.0.0** (breaking: changes what a
> client repo tracks). Origin: no client issue — this came from the observation that
> every client carries a permanent pile of uncommitted deploy churn, and from noticing
> that `app` has quietly been running half of it for months.

## The gap

`deploy-all.sh` writes generated files into five client repos. Those files are tracked,
so every deploy leaves every client dirty. Nobody commits them, because committing
generated output feels wrong — correctly, because it is.

```
app 68    client-i 79    client-a 39    client-f 41    client-c 26
```

**253 permanently-dirty files across five repos**, none of which a human wrote.

The costs are not hypothetical. Every one of these exists to manage the churn:

| Symptom | What it costs |
|-|-|
| `wf-infra-sync.sh` | An entire script whose only job is committing develop's own bytes onto a feature branch so the tree stops being dirty |
| `chore: sync workflow infra from develop` | 7 such commits in client-a alone, carrying no authored change |
| `wf-merge-develop.sh:52`, `wf-merge-release.sh:30` | `git checkout develop -- .claude/skills/` — more reconciliation, in two more scripts |
| `git merge develop` aborting | "your local changes would be overwritten", mid-plan, on a tree the session never touched |
| WFI-036 | The stale stash that nearly reverted a day's skills was **18 files of superseded workflow deploy** |
| WFI-032 | `feature-branches/` untracked on develop |
| WFI-048 / WFI-049 | A permanent 39-file pile of staged-adjacent churn, in exactly the directory where index-sweeping bites |

## The library already found the rule, and took the other branch

`wf-worktree-sparse.sh`'s header states it exactly:

> A sparse-checkout exclusion holds ONLY while the file is absent from the working tree,
> or byte-identical to the branch's committed blob. The moment anything writes DIFFERENT
> content to that path, git drops the skip-worktree bit … `git merge develop` does not
> merely conflict — it ABORTS.
>
> **Excluding a file you also write is not a stricter policy than tracking it; it is a
> broken one.**

That is the correct diagnosis of a real dilemma: **a path cannot be both git-managed and
deploy-managed.** The resolution taken was *"then track it, and reconcile."* This proposes
the other resolution: *don't track it, and there is nothing to reconcile.* Sparse-checkout
stops being relevant to those paths at all, because sparse-checkout only governs tracked
files — the entire hazard class the header describes evaporates rather than being managed.

## The constraint that is real

Three paths must **physically exist** inside a feature worktree or a session there cannot
function:

- `.claude/skills/**` — Claude Code reads skills from the tree it is running in
- `scripts/wf-exec.sh` — skills invoke it by relative path
- `.claude/workflow.md`

Everything else workflow-owned already resolves from the MAIN worktree and is
sparse-excluded — including all of `scripts/v*/`, because `wf-exec.sh` resolves the main
worktree first.

**"Must exist" does not imply "must be tracked."** Tracking is one way to get files into a
new worktree; git materialises them on `git worktree add`. Deploy is the other — and
`install.sh` **already does it**, walking every worktree and copying skills + `wf-exec.sh`
into each. The harness arrives twice, by two independent mechanisms, and every cost above
is the collision between them.

## The natural experiment already running

`app` — the largest and most active client — has gitignored its generated skills for
months:

```gitignore
.claude/skills/*
!.claude/skills/ref-*      # hand-authored reference skills stay tracked
```

26 skills on disk, 1 tracked. It works. Its remaining churn is entirely `scripts/` and
`WORKFLOW.md` — precisely the paths not yet ignored. This is not a speculative design;
it is finishing something one client already proved.

`app`'s pattern is also the better shape, and generalises: ignore the **generated** skills
by name (`wf-*`), never all skills, so a project's own hand-written skills stay tracked.

## Proposed

**Untracked (generated — the library is the source of truth):**

| Path | Why |
|-|-|
| `.claude/skills/wf-*/` | Generated per deploy. Note the `wf-` prefix: a project's own skills are its source and stay tracked |
| `.claude/workflow.md` | Generated from `claude-md/workflow-snippet.md` |
| `.claude/on-implement-commit.sh`, `.claude/on-verify-trigger.sh` | Generated, templated with project config |
| `scripts/v*/` | Generated snapshots — the bulk of the churn |
| `scripts/wf-exec.sh`, `scripts/version-map.txt`, `scripts/wf-prune-versions.sh` | Generated |

**Still tracked (repo state, not build output):**

| Path | Why |
|-|-|
| `claude-workflow.yml` | The client's own config. Hand-edited, never generated |
| `.claude/workflow-version` | One line. The stamp that says which harness a commit was made under — the one audit property tracking actually buys |
| `WORKFLOW.md` | The entry contract an agent landing cold reads. Also the natural place to say "run the installer" |
| `plans/**`, `bugs/**` | Pipeline data. Unchanged, including tracked `plans/REGISTRY.md` |
| `plans/TEMPLATE.md` | Seeded once, then the project's own |

## Change surface

- **`install.sh`** — seed the new ignore lines; keep writing the harness into the main
  worktree and every existing worktree; drop the `wf-infra-sync.sh` call.
- **`wf-worktree-sparse.sh`** (or a new `wf-worktree-harness.sh`) — copy the three
  must-exist paths from the main worktree into a newly created one. Self-contained: the
  main worktree has them on disk, so no library checkout is needed at worktree-creation
  time. Its exclusion list also shrinks, since untracked paths need no sparse rule.
- **`wf-infra-sync.sh`** — **deleted.** Its entire reason for existing is gone.
- **`wf-merge-develop.sh` / `wf-merge-release.sh`** — drop the
  `git checkout develop -- .claude/skills/` reconciliation and the infra staging in their
  `git add` lines. Call the harness copy after merging instead, which is what makes the
  migration self-healing (see below).
- **`docs/worktrees.md`** — rewrite. The "both excluded and written by deploy breaks git"
  contract becomes "generated paths are untracked; here are the three that must exist."
- **`tests/`** — the acceptance criterion below, plus: ignores are seeded; a fresh
  worktree gets all three paths; `wf-*` skills are ignored while other skills are not.

## Migration, and the one dangerous step

Per client, in this order:

1. `git rm -r --cached <paths>` — removes from the index, leaves them on disk.
2. Add the ignores; commit as `chore: stop tracking generated workflow harness`.
3. Redeploy.

**The hazard is step 2 meeting a live feature worktree.** That commit *deletes* those
paths on develop. A feature branch cut earlier still tracks them, so the next
`git merge develop` in that worktree applies the deletion and the worktree loses its
skills mid-plan — the session running there breaks.

Two mitigations, and the second is the one to build:

- Migrate when no plan is mid-flight (fine for a one-person portfolio, not a policy).
- **Have `wf-merge-develop.sh` re-copy the harness after every merge.** Then a worktree
  that takes the deletion immediately gets the files back as ignored files, and the tree
  is clean rather than dirty. This is worth doing on its own merits and makes the
  migration self-healing rather than sequenced.

Do `app` first: it is already half-migrated, so it exercises the `scripts/` half against
the biggest history with the least novelty.

## What this breaks

- **A fresh `git clone` has no harness until the installer runs.** This is the real
  trade. It is also how every generated-artifact toolchain behaves, and `WORKFLOW.md` —
  which stays tracked — is exactly the right place to say so in one line.
- **`git checkout <old commit>` no longer yields that commit's skills.** Acceptable:
  version pinning is already explicit and elsewhere — the registry's `WF` column plus
  `scripts/version-map.txt` — and never relied on git history.
- **CI would need the installer** if it ran `wf-*` scripts. **Checked: none does.** Zero
  references to `wf-exec`, `scripts/v2.00` or `.claude/skills` across all seven workflow
  files in all five clients.
- Local edits to a deployed skill stop being visible to git. Already true in effect —
  deploy overwrites them, and `CLAUDE.md` forbids fixing anything in a client.

## Acceptance criterion

One line, and it is currently false:

```bash
./deploy-all.sh && for c in $(cat deployments.txt); do git -C "$c" status --porcelain; done
# → no output
```

Today that prints 253 files.
