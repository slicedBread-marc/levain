# Levain

**From developer to CEO.**

An open-source harness for Claude Code, for developers already running a session per task. It
turns your windows into one pipeline per project, and your projects into one board. You still
decide what gets built; it keeps the work moving between your decisions.

Start with one project. Climb when you're ready: **manual → attended → overseer**.

Ideas become briefs, briefs become reviewed plans, and plans become code that is verified and
then acceptance-tested. State lives in a registry in the repository, not in your head or in a
chat.

Home page: [slicedbread.ca/levain](https://slicedbread.ca/levain)

## Quick start

```bash
git clone <this repository> ~/levain
cd ~/your-project
claude
```

Then say:

> read ~/levain/START.md and set me up

Claude checks your machine, asks where you want to start on the ladder below, installs only
those rungs, and ends by starting a brainstorm on your first idea. Run it again later and it
offers the next rung. The prompts it follows are in [`START.md`](START.md) and
[`install/`](install/), and you can read them first.

**Platform.** Levain is built and tested on macOS, with its own bash 3.2, git, python3 and Claude
Code (yq is recommended). On another platform, your Claude session can adapt the scripts in place
during setup. There is no further promise than that.

## The ladder

| Rung | You get | Start here if |
|-|-|-|
| **1. Manual** | The pipeline on one project. You run each skill yourself and see every step | You're new to it, or not yet sure the model suits your work |
| **2. Attended** | A daemon moves the work between your decisions. You attend to the gates, with `/lv-attend` | You've taken a few items through by hand and trust the shape |
| **3. Overseer** | One board for several projects, work filed between them, and a vision of what they are for | You run more than one project |

Each rung works on its own, and nothing above it is needed.

## Rung 1: the pipeline

```
draft → ready → active → verify ──[agent]──→ testing → complete
                  ↑          |
                  |          ├→ active  (fix cycle)
                  |          └→ draft   (escalation)
                  └→ draft  (implementer escalation)
```

**`plans/REGISTRY.md` is the status.** Plans never move. Only their state column changes.

| Command | Purpose |
|-|-|
| `/lv-brainstorm` | Capture and explore ideas as briefs |
| `/lv-bug` | File a bug into the same pipeline |
| `/lv-spec` | Turn a decided brief or a bug into a reviewed implementation plan |
| `/lv-implement` | Build from the plan in its own worktree, and fix what verify finds |
| `lv-verify` | Autonomous check of the build against the plan (runs on its own) |
| `/lv-consistency` | Check a plan against the plans it depends on |
| `/lv-test` | Human acceptance testing. `browser` mode drives Chrome |
| `/lv-stage`, `/lv-release`, `/lv-deploy`, `/lv-rollback` | Stage a release, ship it, and take it back |
| `/lv-tray` | The pipeline, workers, gates and the one next action. `/lv-tray <ID>` shows one item's history |
| `/lv-help` | Every skill in one line. `/<skill> help` shows one skill's usage |

Installed into a project, it adds `.claude/skills/lv-*`, `scripts/` (versioned, swapped
atomically on upgrade), `plans/` with the registry and templates, a permission guard in
`.claude/settings.json`, a workflow section in `CLAUDE.md`, and `WORKFLOW.md`, the entry point
for an agent arriving cold.

By hand, the skills split naturally across terminals, one model each:

```
T1 intake (sonnet)   /lv-tray, /lv-brainstorm, /lv-bug
T2 planner (opus)    /lv-spec
T3 builder (sonnet)  /lv-implement      (verify runs by itself)
T4 tester (haiku)    /lv-test
```

## Rung 2: attended

```bash
scripts/lv-exec.sh lv-orchestrate.sh --sweep --dry-run   # preview first, always
scripts/lv-exec.sh lv-orchestrate.sh --daemon            # continuous dispatch
scripts/lv-exec.sh lv-orchestrate.sh BUG-094             # drive one item end to end
scripts/lv-exec.sh lv-tray.sh --watch                    # live view
```

The daemon reads the registry and starts a headless worker for each plan that can move: spec on
opus, implement and verify on sonnet, test on haiku. **Routing is plain bash, and the
orchestrator never calls a model.** Only the workers cost tokens.

When a worker reaches something a machine shouldn't decide (approving a spec, a criterion that
needs human eyes, a release), it opens a **gate** and stops cleanly instead of guessing.
`/lv-attend` walks that queue. Which stops are worth a human is measured, not assumed. See
[`docs/orchestrator.md`](docs/orchestrator.md).

It ships **disabled** (`orchestrator.enabled: false`). Workers run with
`--dangerously-skip-permissions`, fenced by the permission guard
([`docs/autonomy.md`](docs/autonomy.md)), so turning it on is your decision. Caps on concurrency,
attempts per plan and spawns per hour are the guardrails.

**Driving it from another project or agent.** The contract is the exit code:

| Code | Meaning |
|-|-|
| 0 | Reached the target state |
| 20 | Blocked on a human. The gate's details are in `--json`. **Never auto-retry** |
| 30 | A worker ran, and the state did not change |
| 1 | Error |

## Rung 3: the overseer

A **coordinator** is a project with `role: coordinator` in its `levain.yml`. It runs no
pipeline of its own, so it has no plans, registry or worktrees. It oversees the projects listed
under `coordinates:`:

- **`/lv-rack`, the board.** Every project's pipeline in one grid, and what waits on you.
  `scripts/lv-exec.sh lv-rack.sh --watch` gives a live terminal board. You can drill into a cell,
  start `/lv-attend` in a project from it, and stop or resume every daemon at once.
- **`/lv-dep-notify`, filing.** A request lands in the target project's own pipeline, numbered
  by its own counter. Filing is where the coordinator's authority stops.
- **`/lv-vision`, the vision.** It records what the projects are for together, and answers
  "what should I work on next?" Levain ships the contract ([`docs/vision-spec.md`](docs/vision-spec.md))
  and an interview that writes your own vision skill from it, never a vision of its own.

See [`docs/coordinator.md`](docs/coordinator.md).

## Your own tools: extension hooks

The library never names your secrets tool, your hosting provider, your activity log or your
list of projects. It calls a hook named for the job (`secrets-deny-patterns`, `provider-deny`,
`secrets-deploy`, `activity-log`, `project-registry`, `overseer-vision`, `publish-denylist`), and `lv-hook.sh`
finds who answers it. It looks first in the project's `.lv-local/hooks/`, then in your
**packs** (private directories listed in `~/.config/levain/packs`), and finally in the library's
neutral default. A pack can tighten the permission guard but never loosen it.
[`install/pack.md`](install/pack.md) sets one up. [`docs/extension-hooks.md`](docs/extension-hooks.md)
is the reference.

## When the harness is wrong

When a skill or script does something its own documentation doesn't describe, whoever hits it
records it rather than working around it silently:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-implement \
  --expected "active→verify to succeed" --actual "Error: PLN-097 not found in state 'active'"
```

That appends to the project's `WORKFLOW-ISSUES.md`. From the library, `./sweep-issues.sh`
collects the open ones across every installed project. The fix goes into the library, and
reaches every project on the next upgrade. Unattended workers file these too.

## Configuration

`levain.yml` at the project root. [`config.example.yml`](config.example.yml) is the
schema. Each key says what it is for and where to find its value, and it is written for Claude to
fill in during setup rather than for you to edit. Most projects need only the build and test
commands and the source directories.

Without the prompt, the same install is two runs of `install.sh`. The first creates the config,
and the second installs once the config is filled in:

```bash
~/levain/install.sh .     # creates levain.yml; fill it in
~/levain/install.sh .     # installs (commits on main/develop; --no-commit to leave that to you)
```

## Updating

Say *"read ~/levain/START.md and upgrade me"*, or do it by hand: pull the library and re-run
`install.sh` in the project. For several projects, list their paths in `deployments.txt` in the
library (gitignored), or have a pack answer `project-registry`, then run
`./deploy-all.sh --stop-daemons`. Upgrades overwrite skills and scripts, never your config or
templates, and a running daemon never sees a half-written harness
([`docs/atomic-deploy.md`](docs/atomic-deploy.md)).

## Token strategy

- **Opus** only where quality matters most: writing plans.
- **Sonnet** for structured work: implementation, review and verification.
- **Haiku** for light work: status, testing and agent subtasks. Skills spawn haiku agents to
  gather data in parallel, which keeps the main context lean.

## Working on Levain itself

[`CLAUDE.md`](CLAUDE.md) covers the library's own conventions: the lock two sessions take before
editing, tests (`tests/*.sh`), and version bumps.

## License

MIT
