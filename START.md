# Setting up Levain

> **For Claude.** Someone opened Claude Code and said *"read START.md and set me up"*, or pointed
> you at this file some other way. You run the setup. They answer questions and approve the steps
> that matter. This file and the prompts under `install/` are your instructions. `install.sh` is
> what you use underneath.

## Words used here

- **The library** is the directory that holds this file. Call its absolute path `$LIB`, and use it
  in every command. It is not the user's project and nothing is built in it.
- **The project** is the repository the user wants Levain in. It is usually your working
  directory. If your working directory is the library, ask the user which project they mean.
- **A rung** is one level of the ladder below. Each rung is one prompt file in `install/`.

## The ladder

Levain can be used at three levels: manual → attended → overseer. Most people should start at the bottom, and each rung works
without the ones above it.

| Rung | What they get | For whom | Prompt |
|-|-|-|-|
| 1. Manual | The pipeline on one project: ideas become specs, specs become code, then verify and test. Every step is a skill they run themselves | Anyone new to it, and anyone not yet sure the model is right for their work | `install/project.md`, then `install/first-brainstorm.md` |
| 2. Attended | A daemon moves the work between the user's decisions. The user attends to what needs a human, with `/lv-attend` | Someone who has taken a few items through by hand and trusts the shape | `install/attended.md` |
| 3. Overseer | Several projects on one board, work filed between them, and a vision that says what they are for together | Someone running more than one project | `install/overseer.md`, then `install/vision.md` |

These three can be done at any time, on any rung:

| Step | When | Prompt |
|-|-|-|
| Pack | The user has their own tools (a secrets manager, a hosting provider, an activity log) that the harness should call | `install/pack.md` |
| Upgrade | Levain is already installed and the library has a newer version | `install/upgrade.md` |
| Issues | The harness has recorded faults in `WORKFLOW-ISSUES.md`, and the user wants them fixed, resolved and sent upstream | `install/issues.md` |

## What to do

1. **Run `install/preflight.md`.** Always run it, even on a re-run, because it is quick and it
   catches a machine that has changed.
2. **Find out where they already are.** Look before you ask:
   - no `levain.yml` in the project: nothing is installed yet
   - `levain.yml` with `role: "coordinator"`: this is an overseer's seat, not a project
   - `plans/REGISTRY.md` with rows past `draft`: they have used rung 1
   - `orchestrator.enabled: true` in `levain.yml`: rung 2 is set up
   - `.claude/workflow-version` older than `$LIB/VERSION`: offer the upgrade first

   Then tell them in two or three lines what you found, show the ladder table, and ask which
   rung they want to reach. Recommend the next rung up from where they are. **Re-running this
   file climbs one rung.** It never starts from scratch on something that is already installed.
3. **Run only the prompts for the rungs they still need, in order.** Read each prompt file in
   full before you start it. Finish one before starting the next, and end each with its short
   report.
4. **Close.** Tell them in no more than 8 lines what now exists, the one command to type next,
   and what the next rung would give them when they want it.

## Rules for every step

- **Ask before anything outward-facing or hard to undo:** turning the daemon on, creating a
  repository, pushing, changing another project, or installing software on their machine.
  Everything else in these prompts you may do without asking, and you say what you did.
- **Never turn on the daemon for them** without a clear yes to that specific question. Its workers
  run with `--dangerously-skip-permissions`, and that grant is theirs to give.
- **Never read, print or move a secret.** If a step needs a credential, the user sets it
  themselves, or their pack's hook does.
- **`install.sh` commits what it installs** on `main`, `master`, `develop` or `release`. Say so before
  the first run. If they would rather commit it themselves, pass `--no-commit`.
- **If something in these prompts is wrong** (a command that does not exist, or a step that does not
  match what you see), say so plainly, work around it if that is safe, and tell them it is worth
  reporting upstream.
