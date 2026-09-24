---
name: lv-tray
description: What the pipeline is doing and what to do next — running workers, open gates, every plan by what it is waiting for, bugs, ideas, and one ranked next action. `/lv-tray <ID>` shows one plan, bug or brief's full history. Works with or without the orchestrator daemon.
user_invocable: true
model: haiku
---

# Tray

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You show where the pipeline stands and the **one** thing the human should do next — or, given an ID, everything that has happened to that artifact. You do not dispatch work, change state, or start anything.

Nothing here needs the orchestrator daemon. A project worked entirely by hand (`enabled: false`, no daemon ever started) gets the same view: the plan lists, bugs, gates and next action are all read from `plans/`, `bugs/` and the gate files. RUNNING and RECENT simply say "nothing" there — that is normal, not a fault.

## Which view

| Invoked as | Show |
|-|-|
| `/lv-tray` | **The tray** — below |
| `/lv-tray <ID>` — a plan, bug or brief ID, or just its number | **One artifact's history** — further below |
| "just tell me what to do next" | Only the `NEXT` block of the tray, nothing else |

## The tray

Run this first, before reading anything else, and display its output verbatim:

```bash
scripts/lv-exec.sh lv-tray.sh --plain --plans; scripts/lv-prune-versions.sh --list 2>/dev/null || true; scripts/lv-exec.sh lv-check-reboot-flag.sh 2>/dev/null || true
```

That output is already formatted. Do not restructure it, re-render it as tables, or summarise it away. The `NEXT` block at its end is the recommendation: the script ranks it (open gates first, then fixing built work, replanning, acceptance testing, building, drafts, planning briefs and serious bugs, verifying, then ideas) and names the plan to start with, `[URGENT]` included. Do not re-rank it or pick something else.

### Then, in one short paragraph

Restate the `NEXT` action in plain words, and add only what applies:

- **A `REGISTRY` section is printed** — say so first: the registry and `plans/` disagree, and every list below it can only show plans the registry knows about.
- **A gate line reads `stuck`** — that plan hit its attempt budget. It needs a human look, not another retry.
- **`pending migration actions`** in the banner — point at `plans/MIGRATION-NOTES.md`.
- **The `brainstorms` line carries `(+N not in INDEX.md)`** — brief files the backlog doesn't list. `lv-brainstorm-reindex.sh` is the repair; never run it from here.
- **`enabled: false`** — the project runs by hand, and `NEXT` is a skill to run, not a daemon to start. Mention `scripts/lv-exec.sh lv-orchestrate.sh --sweep --dry-run` (then enabling it in `levain.yml`) only if the user asks about automating.
- **A plan is `in progress — claimed by a session`** — another session is working it; say so, so nobody picks it up twice.

## One artifact's history — `/lv-tray <ID>`

```bash
scripts/lv-exec.sh lv-tray-drill.sh history <ID>
```

Display its output verbatim. It gathers everything carrying the ID's **number** — an artifact keeps its number when a bug or brief becomes a plan — so it shows, where they exist: the registry row (state, priority, branch, tags, deps and what blocks it), the goal, what the plan came from, the Steps checklist, the progress log, every finding marked `[open]`/`[closed]`, the bug and brief records, plans that name this bug or brief, the open gate and every answered one, claim and attempts, the ten newest commits on any branch, events and worker logs.

If it prints `not found`, say so and stop. After the output, add one line only if it helps: the state and what moves it next (e.g. "draft — `/lv-spec` moves it to ready").

To go deeper — plan.md, a findings file, a worker's live log — list what is behind the artifact and open the file a line points at:

```bash
scripts/lv-exec.sh lv-tray-drill.sh artifact <ID>
```

## Watch mode

If the user asks to watch it live, tell them to run this themselves rather than running it yourself — it never returns:

```bash
scripts/lv-exec.sh lv-tray.sh --watch 10
```

If they want a version that never scrolls — e.g. running it in a small pane
alongside other work — point them at `--stats`: header + pipeline counts
only, a fixed line count regardless of how much is running or gated, so a
`--watch` loop never grows past one screen:

```bash
scripts/lv-exec.sh lv-tray.sh --watch 10 --stats
```

## Rules

- **Read-only.** Never spawn workers, open or close gates, claim anything, or edit REGISTRY.md or any other file.
- **Recommend, don't act.** Name the skill to run; do not start implementing, planning or testing.
- If `lv-tray.sh` is missing, say the harness isn't installed on this client and suggest re-running the workflow installer. Do not improvise a replacement out of `ls`, `grep` and `cat`.
- **Final response under 2000 characters**, not counting the script output you display.

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `lv-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-tray \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the Levain library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

## Usage

```text
/lv-tray                every plan by what it waits on, workers, gates, and one next action
/lv-tray <ID>           one plan, bug or brief's full history (a bare number works)
                        replaces /lv-status and /lv-info <ID>
```
