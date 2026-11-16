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
   - **In progress:** a RUNNING cell with a `+ID` tail is work an attended session holds a claim
     on right now (`0 +RELEASE`: someone is mid-`/lv-release`). An ATTN id marked `*` is a gate
     that work is answering — RELEASE and DEPLOY count as one promotion — so report it here,
     not as waiting, and do not offer to start that skill in a second session.
   - **Waiting on a human:** each project's gates, naming the plans the ATTN row lists. A
     `stuck` gate first — it does not resolve by waiting.
   - **Ready to ship:** non-zero RELEASE and DEPLOY rows.
   - **Idle:** daemons off in projects with queued work.
   - A dashed column means that project's harness is missing or too old; say which.
   - A yellow HARNESS cell means that client runs a different version from the library; say
     which, and that `U` on the live board deploys.
   - The library line under it counts open client issues; when it is non-zero, say so, and that
     `W` on the live board starts a blind sweep of the top three. The line reads `heal (N)`, three
     hearts filling while a sweep runs, and `restart required` once a deploy has landed under a
     running board (`X` restarts it). `/lv-sweep` runs the same sweep from a session.
3. Offer the next step for the most urgent item: `/lv-attend <ID>` in that project, or the
   board itself.

**`daemons`:** run `scripts/lv-exec.sh lv-rack.sh --list-daemons` and list them.

**`services`:** run `scripts/lv-exec.sh lv-rack.sh --services --plain` and show the table: every
project's declared `services:`, up or down, and the checkout each runs from. A row flagged `⚠` runs
from a branch other than main. Starting and stopping a service is the owner's, from `v` on the live
board: the launchers read keys in the owner's own terminal, and `lv-services.sh` refuses under an agent.
The PROGRESS column is the service's own one-line summary (`progress:`), with `⏸ paused` or
`⏹ stopped for the day` before it when its `throttle:` control file says so; report it as written,
and note when it reads stale. A runaway throttled run may be slowed from here with
`lv-services.sh throttle <id> pause` (or `stop-for-day`) in that project; resuming or raising a
limit is the owner's and refuses under an agent (`docs/services.md`).
The grid's `services` row reads running/available per project: `-` for none declared, otherwise
`N/M` (`0/5` when none run), in green once any has a live beacon.

**The live board is a terminal program.** Its drill-down (Enter on a `daemon` cell opens that
daemon's menu — start/stop, sweep, kill, its logs — and on a `services` cell the services screen
for that project alone), daemon toggles (`d`), stop/resume of
every daemon (`s`/`R`), attend (`t` — on the release or deploy row it starts `/lv-release` or
`/lv-deploy` instead), the dormant-project toggle (`z`, which offers to stop a running daemon first), the services view (`v`), the library deploy (`U`),
the blind library sweep (`W`, or Enter on `heal (N)`), the restart (`X`) and the settings screen (`,`, where
auto-heal is turned on) need a real terminal, so point the owner at
`! scripts/lv-exec.sh lv-rack.sh --watch` rather than running it here. `--stop-all` and
`--resume` change what every project is doing unattended: run them only when asked.

## Usage

```text
/lv-rack             the board, summarised: what waits on you, what can ship
/lv-rack daemons     which orchestrator daemons are live
/lv-rack help        this block
In a terminal:  scripts/lv-exec.sh lv-rack.sh --watch      the live board
```
