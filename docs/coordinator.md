# Coordinators: a harness install for a project that runs no pipeline

A coordinator oversees every project in a portfolio and owns none of their code.
When work planned there needs something built, the work belongs in the target
project's own pipeline. Before coordinator installs there was no way to put it there: the
coordinator was not a client, had no `scripts/lv-exec.sh`, and its own instructions told it to write
`plans/briefs/` plus a REGISTRY row by hand — which means deriving an artifact
number by hand, from a counter it is not allowed to touch.

That is the WFI-025 shape, and `docs/cross-project-reports.md` already says why
it is wrong. A coordinator install is the way to do it right.

Read this before setting `role: coordinator` on a project.

## What a coordinator is

A project with `role: coordinator` in its `levain.yml`. It gets the
harness on disk and **one capability**: filing work into the pipelines of the
projects it coordinates, through each of those projects' own scripts.

It does not get a pipeline. No `plans/`, no `plans/REGISTRY.md`, no `bugs/`, no
plan templates, no feature or release worktrees, no orchestrator, no git
post-commit hook, no session hooks, and none of the `/lv-*` pipeline skills.

## What it gets, exactly

```
scripts/lv-exec.sh              the dispatcher
scripts/version-map.txt         version → script-folder map
scripts/lv-prune-versions.sh
scripts/v*/lv-orch-lib.sh       config + repo-root helpers
scripts/v*/lv-lock.sh
scripts/v*/lv-dep-notify.sh     file into the projects it coordinates
scripts/v*/lv-dep-bug.sh        file into a declared dependency
scripts/v*/lv-issue.sh          report a harness fault
scripts/v*/lv-hook.sh           the extension-hook dispatcher, + hooks.default/
scripts/v*/lv-rack.sh           the cross-project board
scripts/v*/lv-direct.sh         steer a coordinated plan (--project), via the target's own harness
scripts/v*/lv-bug-group.sh      hold a batch of filings off /lv-spec until sealed (--project)
.claude/skills/lv-dep-notify/   filing: the entry point a human or agent invokes
.claude/skills/lv-rack/         the board, summarised
.claude/skills/lv-vision/       the owner's vision skill, or the interview that writes one
.claude/docs/                   the docs those skills cite (vision-spec.md, extension-hooks.md)
.claude/workflow-version        the stamp
.claude/workflow-source         where the library lives on this machine
WORKFLOW.md                     from templates/WORKFLOW-coordinator.md
WORKFLOW-ISSUES.md              seeded, so the reporting channel is discoverable
```

Only a script generation that actually ships `lv-dep-notify.sh` is installed;
an older generation would otherwise land as an empty directory that
`lv-exec.sh` can still resolve to and then fail in.

The install is also **subtractive**. A coordinator that was previously a full
client has its pipeline skills removed and its `scripts/v*/` pruned to the slice
above, on every deploy. A pipeline script left behind on a coordinator's disk
looks current and is one `lv-exec.sh` call away from running — the same argument
install.sh already makes for pruning scripts the library stopped shipping.

## Why it gets the harness at all

Two reasons that pull the same way.

**Filing has to run the target's own scripts.** The whole guarantee of
`docs/cross-project-reports.md` is that a report is allocated by the target's
own counter and lands in the target's own `bugs/open/`, where its own `/lv-spec`
already looks — no second inbox, nothing to remember to check. Reaching that
requires `lv-dep-notify.sh` on the coordinator's side. A hand-rolled wrapper in
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

There is one other thing it may write into a target, and it does not write it
itself. `lv-direct.sh … --project <name>` runs the target's own `lv-direct.sh`
through the target's `lv-exec.sh`. The directive is recorded as
`coordinator:<slug>` and committed by the target's harness. The target's own
workers then apply it ([directives.md](directives.md)).
`lv-bug-group.sh … --project <name>` is routed the same way: it holds a batch of
reports this coordinator is still filing off the target's `/lv-spec` until it
seals them ([intake-groups.md](intake-groups.md)).

Filing is the **terminal action**. Everything downstream of a filed report —
triage, spec, claiming, registry rows, implementation, verification, testing,
release — belongs to a session rooted in the target project.

Nothing at the tool level enforces this. A coordinator session has a shell and
can write anywhere; client-e's WFI-025 did exactly that into client-c and
had to be reverted wholesale. The convention is the only guard, which is why
`WORKFLOW-coordinator.md` states it in its first section rather than burying it.

## Setup

1. Write the project's `levain.yml` by hand:

   ```yaml
   role: "coordinator"
   project_slug: "coordinator"

   coordinates:
     - "client-e:/path/to/client-e"
     - "client-f:/path/to/client-f"
   ```

   The build, test and deploy keys a client needs are irrelevant here and can be
   omitted; `project_slug` is still required, since it is what stamps
   `--source cross-project:<slug>` on everything the coordinator files.

2. Add its path to the project registry like any other client (`deployments.txt`
   in the library, or your pack's `project-registry` hook). `deploy-all.sh`
   keeps it current from then on. `START.md`'s `install/overseer.md` walks
   through all of this.

3. Point the project's own `CLAUDE.md` at `WORKFLOW.md`. Without that, a session
   there never learns what it may and may not do to a coordinated project.
   install.sh warns when the mention is missing but will not edit that file — a
   coordinator's `CLAUDE.md` is its own, not generated harness.

## `coordinates:` vs `dependents:`

`lv-dep-notify.sh` reads both and concatenates them, so a project that is both
depended upon and a coordinator keeps all of its targets.

They are two names for the same list shape because the relationship runs in
opposite directions and only one word is ever true of a given project. Calling
the projects coordinator directs its "dependents" would be false in the one file a human
maintains by hand, and a wrong word there is a cost paid on every read.

## Filing

```bash
scripts/lv-exec.sh lv-dep-notify.sh "<title>" \
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

## The overseer rung: board and vision

A coordinator is where one person oversees several pipelines (LVI-014). Beyond filing, it gets:

- **The board**, `scripts/lv-exec.sh lv-rack.sh` (`/lv-rack` for a summary): every project's
  `lv-tray.sh --fields` as one grid. `--watch` is a live terminal board with a drill-down into
  workers, plans and logs, daemon toggles, stop/resume of every daemon (`--stop-all`/`--resume`,
  which `deploy-all.sh --stop-daemons` also uses), and `t` to start `/lv-attend` in the
  highlighted project. On the release or deploy row, `t`
  starts `/lv-release`/`/lv-deploy` there instead. `z` (or `--sleep`/`--wake`/`--dormant`) marks
  a project dormant: no column and no scan, unless its daemon is live, and `--include-dormant`
  still shows it. The `harness` row compares each client's installed version with the library's, and `U`
  runs the library's `deploy-all.sh`, refusing on a held `LIBRARY-LOCK.md`, a dirty library or
  a red suite. The library line under it counts open client issues, and `W` starts a **blind
  sweep** (`lv-library-sweep.sh`): a detached, headless session in the library that fixes the
  top three, oldest first with duplicates as one, while the board keeps running. The script, not
  the session, holds the lock, runs it under the permission baseline, and decides the deploy:
  a green suite deploys and resolves; a red one, or a fix touching the baseline, the denylist or
  the deploy itself, is committed and held for review until `U`. It never reads `--upstream`.
  The line shows `sweeping…`, then one result; the log is under
  `.claude/orchestrator/library-sweep/logs/`. Its projects come from the `project-registry` hook: the owner's pack, else
  the library's `deployments.txt` (found through `.claude/workflow-source`), else this
  coordinator's `coordinates:` list. Its own state, the suspend record, the dormant set and the snapshot cache,
  lives in the coordinator's gitignored `.claude/orchestrator/`.
- **A vision**, through `/lv-vision`. The library ships a contract, not a vision:
  [vision-spec.md](vision-spec.md) defines the modes, the file tree, the rules and the output
  formats. The `overseer-vision` hook names the owner's skill: a pack's, or
  `.claude/skills/vision/SKILL.md` here. With none, `/lv-vision setup` interviews the owner and
  writes one from the spec's template, together with a first `VISION.md`. That skill sits outside
  the `lv-` names, so a deploy never touches it.

## Tooling that walks the project registry

- `sweep-issues.sh` works unchanged: a coordinator gets a `WORKFLOW-ISSUES.md`
  and reports harness faults like any client.
- `check-profiles.sh` skips coordinators. A governance tier describes
  `specApproval`, `manualTestGate` and autonomy scope — none of which exist
  without a pipeline — and there is no `lv-profile.sh` installed to ask.
