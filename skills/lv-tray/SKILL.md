---
name: lv-tray
description: Live view of the orchestrator — running workers, queued gates, pipeline state, recent events. Use when you want to know what the pipeline is doing right now.
user_invocable: true
model: haiku
---

# Board

You show what the pipeline is doing **right now**. You do not dispatch work, change state, or answer questions about individual plans — `/lv-status` is for the plan-by-plan picture, this is for the machine.

## IMMEDIATE STARTUP

Run this first, before reading anything else, and display its output verbatim:

```bash
scripts/lv-exec.sh lv-tray.sh --plain
```

That output is already formatted. Do not restructure it, re-render it as tables, or summarise it away.

## Then, in one short paragraph

Say what the human should do next, choosing the **first** case that applies:

| Condition | What to say |
|-|-|
| Gates listed | "N gates waiting — run `/lv-attend` to clear them." Name the oldest one. |
| Nothing running, nothing gated, work in `ready`/`testing` | The daemon is idle or off. Suggest `scripts/lv-exec.sh lv-orchestrate.sh --daemon`. |
| `enabled: false` in the header | The orchestrator is off. Suggest a `--sweep --dry-run` first, then enabling it in `claude-workflow.yml`. |
| A `stuck` gate is listed | That plan hit its attempt budget — it needs a human look, not another retry. |
| Workers running, no gates | Say what's in flight and roughly how long it's been. Nothing to do but wait. |
| Pipeline empty, `brainstorms` non-zero | The backlog isn't empty, it's unfinished thinking. Name the count and suggest `/lv-brainstorm` to decide or park them. |
| Pipeline empty | Suggest `/lv-brainstorm` or `/lv-bug` to feed it. |

The `brainstorms` line carries a `(+N not in INDEX.md)` tail when brief files
exist that the backlog doesn't list. Mention it when it appears —
`lv-brainstorm-reindex.sh` is the repair — but never run it from here: this
skill writes nothing.

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

- **Never** spawn workers, open or close gates, or edit REGISTRY.md.
- If `lv-tray.sh` is missing, say the orchestrator isn't installed on this client and suggest re-running the workflow installer. Do not improvise a replacement out of `ls` and `cat`.

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `lv-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-tray \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the claude-workflow library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

