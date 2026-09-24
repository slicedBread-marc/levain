# Rung 1: the first brainstorm

> Part of [START.md](../START.md). Rung 1 ends with the user's first real idea in the
> pipeline, not with an empty install.

## 1. The pipeline, briefly

Say this in your own words, in no more than 8 lines:

- An idea starts as a **brief** (`/lv-brainstorm`), explored until it is decided.
- `/lv-spec` turns a decided brief, or a bug, into a **plan** with steps, tests and design
  decisions. The plan is reviewed before anything is built.
- `/lv-implement` builds it in its own worktree. A verify agent then checks the result against
  the plan without being asked.
- `/lv-test` is the human's acceptance test. After it, `/lv-release` and `/lv-deploy` ship.
- `plans/REGISTRY.md` is the only record of state. `/lv-tray` shows it, and says what to do next.
- `/lv-help` lists every skill, and `/<skill> help` explains one.

## 2. Start it

Ask what they want to build or fix first. If they have no idea ready, ask what annoys them
most about the project today.

Then run `/lv-brainstorm` with their answer. The skills were installed during this session, so
if `/lv-brainstorm` is not available to you yet, ask them to restart Claude Code in the project
and type `/lv-brainstorm <their idea>` themselves.

## Report

Once the brief exists, tell them what comes next, in 3 lines: `/lv-spec` when the brief says
*Decided*, then `/lv-implement`, then `/lv-test`. Mention that re-running START.md later offers
rung 2, the daemon, and that it is worth taking one or two items through by hand first.
