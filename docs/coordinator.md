# Coordinators: a harness install for a project that runs no pipeline

`~/dev/coordinator` oversees every project in the portfolio and owns none of their code.
When an initiative there needs something built, the work belongs in the target
project's own pipeline. Until now there was no way to put it there: coordinator is not a
client, has no `scripts/wf-exec.sh`, and its own instructions told it to write
`plans/briefs/` plus a REGISTRY row by hand — which means deriving an artifact
number by hand, from a counter it is not allowed to touch.

That is the WFI-025 shape, and `docs/cross-project-reports.md` already says why
it is wrong. A coordinator install is the way to do it right.

Read this before setting `role: coordinator` on a project.

## What a coordinator is

A project with `role: coordinator` in its `claude-workflow.yml`. It gets the
harness on disk and **one capability**: filing work into the pipelines of the
projects it coordinates, through each of those projects' own scripts.

It does not get a pipeline. No `plans/`, no `plans/REGISTRY.md`, no `bugs/`, no
plan templates, no feature or release worktrees, no orchestrator, no git
post-commit hook, no session hooks, and none of the `/wf-*` pipeline skills.

## What it gets, exactly

```
scripts/wf-exec.sh              the dispatcher
scripts/version-map.txt         version → script-folder map
scripts/wf-prune-versions.sh
scripts/v*/wf-orch-lib.sh       config + repo-root helpers
scripts/v*/wf-lock.sh
scripts/v*/wf-dep-notify.sh     file into the projects it coordinates
scripts/v*/wf-dep-bug.sh        file into a declared dependency
scripts/v*/wf-issue.sh          report a harness fault
.claude/skills/wf-dep-notify/   the entry point a human or agent invokes
.claude/workflow-version        the stamp
.claude/workflow-source         where the library lives on this machine
WORKFLOW.md                     from templates/WORKFLOW-coordinator.md
WORKFLOW-ISSUES.md              seeded, so the reporting channel is discoverable
```

Only a script generation that actually ships `wf-dep-notify.sh` is installed;
an older generation would otherwise land as an empty directory that
`wf-exec.sh` can still resolve to and then fail in.

The install is also **subtractive**. A coordinator that was previously a full
client has its pipeline skills removed and its `scripts/v*/` pruned to the slice
above, on every deploy. A pipeline script left behind on a coordinator's disk
looks current and is one `wf-exec.sh` call away from running — the same argument
install.sh already makes for pruning scripts the library stopped shipping.

## Why it gets the harness at all

Two reasons that pull the same way.

**Filing has to run the target's own scripts.** The whole guarantee of
`docs/cross-project-reports.md` is that a report is allocated by the target's
own counter and lands in the target's own `bugs/open/`, where its own `/wf-spec`
already looks — no second inbox, nothing to remember to check. Reaching that
requires `wf-dep-notify.sh` on the coordinator's side. A hand-rolled wrapper in
the coordinator's own `bin/` would duplicate the resolution, the branch guard
and the `--source` stamping, and would drift from the library the first time
either side changed.

**A coordinator has to understand pipelines it does not run.** It reasons about
work in several projects at once, so it needs an accurate description of how
they behave — the states, who acts on each, the shared counter, and above all
where its own authority stops. The only description that cannot go stale is one
the library regenerates on every deploy. That is `WORKFLOW.md`, rendered from
`templates/WORKFLOW-coordinator.md`.

## Where its authority stops

Filing is the **terminal action**. Everything downstream of a filed report —
triage, spec, claiming, registry rows, implementation, verification, testing,
release — belongs to a session rooted in the target project.

Nothing at the tool level enforces this. A coordinator session has a shell and
can write anywhere; client-e's WFI-025 did exactly that into client-c and
had to be reverted wholesale. The convention is the only guard, which is why
`WORKFLOW-coordinator.md` states it in its first section rather than burying it.

## Setup

1. Write the project's `claude-workflow.yml` by hand:

   ```yaml
   role: "coordinator"
   project_slug: "coordinator"

   coordinates:
     - "client-e:/Users/you/dev/client-e"
     - "client-f:/Users/you/dev/client-f"
   ```

   The build, test and deploy keys a client needs are irrelevant here and can be
   omitted; `project_slug` is still required, since it is what stamps
   `--source cross-project:<slug>` on everything the coordinator files.

2. Add its path to `deployments.txt` like any other client. `deploy-all.sh`
   keeps it current from then on.

3. Point the project's own `CLAUDE.md` at `WORKFLOW.md`. Without that, a session
   there never learns what it may and may not do to a coordinated project.
   install.sh warns when the mention is missing but will not edit that file — a
   coordinator's `CLAUDE.md` is its own, not generated harness.

## `coordinates:` vs `dependents:`

`wf-dep-notify.sh` reads both and concatenates them, so a project that is both
depended upon and a coordinator keeps all of its targets.

They are two names for the same list shape because the relationship runs in
opposite directions and only one word is ever true of a given project. Calling
the projects coordinator directs its "dependents" would be false in the one file a human
maintains by hand, and a wrong word there is a cost paid on every read.

## Filing

```bash
scripts/wf-exec.sh wf-dep-notify.sh "<title>" \
  --to client-e \
  --kind request \
  --description "..." --expected "..." --actual "..."
```

`--kind` defaults to `notice` (the dependent-notification case). A coordinator
passes `request` — it is asking for work, not announcing a change it made.
Nothing enforces that: a coordinator reporting a defect it actually observed
files a `bug`, and one relaying an upstream change files a `notice`.

Everything else is unchanged from `docs/cross-project-reports.md` §
*Notifying dependents of a change*: the target's branch is read and never
written, a target not on `develop` is skipped rather than displaced, the filing
commits in the target but does **not** push, and the run exits 0 once every
target has been attempted. Read the `SKIPPED` lines and tell the user which
targets did not land — nothing retries them.

## Tooling that walks `deployments.txt`

- `sweep-issues.sh` works unchanged: a coordinator gets a `WORKFLOW-ISSUES.md`
  and reports harness faults like any client.
- `check-profiles.sh` skips coordinators. A governance tier describes
  `specApproval`, `manualTestGate` and autonomy scope — none of which exist
  without a pipeline — and there is no `wf-profile.sh` installed to ask.
