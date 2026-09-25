---
name: lv-rack
description: The cross-project board — every coordinated project's pipeline in one grid, and what waits on a human. Coordinators only.
---

# /lv-rack

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

The overseer's board (LVI-014): `/lv-tray` for every project at once. Projects come from the
`project-registry` hook ([`docs/extension-hooks.md`](../../docs/extension-hooks.md)) — the owner's
pack, else the library's `deployments.txt`, else this coordinator's `coordinates:` list.

1. Run:

   ```bash
   scripts/lv-exec.sh lv-rack.sh --plain --all
   ```

2. Report, in this order and briefly:
   - **Waiting on a human:** each project's gates, naming the plans the ATTN row lists. A
     `stuck` gate first — it does not resolve by waiting.
   - **Ready to ship:** non-zero RELEASE and DEPLOY rows.
   - **Idle:** daemons off in projects with queued work.
   - A dashed column means that project's harness is missing or too old; say which.
3. Offer the next step for the most urgent item: `/lv-attend <ID>` in that project, or the
   board itself.

**`daemons`:** run `scripts/lv-exec.sh lv-rack.sh --list-daemons` and list them.

**The live board is a terminal program.** Its drill-down, daemon toggles (`d`), stop/resume of
every daemon (`s`/`R`) and attend (`t` — on the release or deploy row it starts `/lv-release` or
`/lv-deploy` instead) need a real terminal, so point the owner at
`! scripts/lv-exec.sh lv-rack.sh --watch` rather than running it here. `--stop-all` and
`--resume` change what every project is doing unattended: run them only when asked.

## Usage

```text
/lv-rack             the board, summarised: what waits on you, what can ship
/lv-rack daemons     which orchestrator daemons are live
/lv-rack help        this block
In a terminal:  scripts/lv-exec.sh lv-rack.sh --watch      the live board
```
