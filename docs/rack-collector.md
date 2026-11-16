# The rack's collector: one process collects, every board reads

**Since:** the coordinator's LVI-048. **Script:** `scripts/v2.00/lv-rack.sh`.

The rack (`lv-rack.sh`, `/lv-rack`) runs as two processes joined by one JSON snapshot:

- **The collector**, `lv-rack.sh --collect`. It is the only thing that runs each client's
  `lv-tray.sh --fields` for the grid. It checks the projects in parallel subshells, saves
  `grid.json`, rewrites a heartbeat every tick, and takes requests as files.
- **The boards**: `--watch`, `--plain`, the picker, and a piped run. They read `grid.json` and
  paint it. However many are open, they share one collector.

Before this, every open board polled the whole portfolio itself, the collector was a child of
the board and stopped when it closed, and `--plain` collected from scratch each time.

## The files

All of them live in the coordinator's `.claude/orchestrator/board-cache/` (`LV_BOARD_CACHE`):

| File | Written by | What it is |
|-|-|-|
| `grid.json` | collector | The snapshot, written atomically (temp file and rename) |
| `collector.hb` | collector | `<pid> <started> <beat> <idle\|collecting> <seq>`, rewritten every tick. `seq` counts the snapshots this collector has saved, so a board repaints exactly when there is a new one |
| `collector.lock/` | collector | Created with `mkdir`, so the first claim is atomic. `pid` inside names the collector |
| `collector.log` | collector | One line per start, stand-down, replacement and exit, with the reason |
| `readers/<pid>` | board | One per open board, `interval=<s> dormant=<0\|1>`. A `--plain` writes `readers/plain-<pid>` |
| `requests/refresh-<project>[@<token>]` | board | Refresh that project now. `refresh-all` refreshes everything |
| `served/<token>` | collector | Written once the snapshot that answers that token's request is saved |
| `node-*.json` | board | Drill levels. A board still fetches these itself, on demand |

## Lifecycle

- **Start.** A board that finds no fresh heartbeat starts a collector, detached (`nohup`, stdin
  from `/dev/null`, output to `collector.log`), from the same copy of the script, against the
  same coordinator and cache. The board does not collect anything itself.
- **Fresh** means the heartbeat's pid is alive and its beat is at most `LV_RACK_STALE_SECS`
  old (default 15). A heartbeat whose pid is gone is dead at once.
- **One collector.** A second `--collect` finds the lock held by a live, beating collector and
  exits 0. Two boards started together can each spawn one. Whichever claims the lock last owns
  it, and the other sees on its next tick that the lock names someone else and exits.
- **Stale is replaced.** A lock whose holder is dead is taken over. So is one whose holder is
  alive but has stopped beating. If that process is a collector (a hung one), it is sent TERM.
  If the pid now belongs to some other process, it is left alone.
- **Collect.** A full collect starts at once, then every `LV_RACK_COLLECT_SECS` (default 60), or
  sooner when a reader asked for a faster `--watch N`. It runs in the background, so the loop
  keeps beating and taking requests while clients answer. Each project is its own subshell, at
  most `LV_RACK_JOBS` (default 8) at once, so a collect takes as long as its slowest client
  rather than the sum of them all. The registry hook is re-read before each full collect, and the
  library line's counts are refreshed with it.
- **Requests.** Between jobs the collector takes everything in `requests/`. `refresh-all` runs
  a full collect. Otherwise only the named projects are fetched and merged into the snapshot by
  path, and every other project keeps its numbers and its time. Each token is answered in
  `served/`, including a token for a name the registry does not know, so nobody waits on it
  until a timeout.
- **Idle exit.** A reader whose pid is alive keeps the collector running. A `plain-` reader, or
  one left by a board that crashed, counts from its file's mtime. After `LV_RACK_IDLE_SECS`
  (default 300) with no reader, the collector exits and removes its heartbeat and lock. It also
  exits when its cache directory is gone.

There is no launchd service and no per-project collector. If the rack ever has to run with no
board open, for example to raise alerts, that is the point to revisit (LVI-048's notes).

## What each board does

- **`--watch`** registers as a reader and makes sure a collector is running. It paints the
  snapshot already on disk at once, with its age tint, and repaints whenever the heartbeat's
  `seq` moves. On a cold start (no `grid.json` yet) it says it is collecting and waits for the
  first snapshot. The spinner follows the collector's `collecting` state. If the collector dies,
  the next tick starts another.
- **`--plain`** is instant when a live collector has already saved a snapshot: it reads the
  file and prints it, and runs no client's `lv-tray.sh`. With no collector, it starts one and
  waits for its first snapshot (`LV_RACK_WAIT_SECS`, default 90). The `plain-` reader file it
  leaves keeps that collector warm, so the next `/lv-rack` is instant too.
- **Actions** (`d`, the project menu, `s`/`R`) used to re-fetch the project they changed. Now
  `refresh_one` writes `refresh-<project>@<token>`, waits for `served/<token>`
  (`LV_RACK_REQ_WAIT`, default 30), and takes the new record in place, so the menu's indexes
  hold. Every other open board picks up the same snapshot. Back from a Claude session, or after
  `z`, the board queues `refresh-all`.
- **`X`** restarts the board on the newest deployed version and stops the collector, so the
  restarted board starts a collector from the new code.
- **Without jq** there is no snapshot, so there is no collector. The board collects in-process
  as it did before, with the same background refresh. `LV_RACK_COLLECTOR=off` forces that
  mode.

`--services`, `--decide`, `--list-daemons`, `--stop-all`/`--resume` and `--sleep`/`--wake` read
their own sources directly, as before.

## The snapshot

`grid.json` keeps `schema: 1`, and every change to it adds fields:

```json
{ "schema": 1, "saved_at": 1794869377, "include_dormant": false,
  "collector": { "pid": 90002, "started": 1794869300 },
  "projects": [ { "name": "alpha", "path": "/…/alpha", "status": "ok",
                  "daemon": "off", "running": "1", "…": "…", "fetched_at": 1794869376,
                  "services": "2\talpha\t app",
                  "tray": { "daemon": "off", "running": "1", "queued": "7" },
                  "dormant": false } ] }
```

- **`tray`** holds every key of the project's `lv-tray.sh --fields` line, including keys the grid
  does not draw yet. The 9-row grid in [`proposals/rack-rows.md`](proposals/rack-rows.md) adds
  tray keys (`queued`, `queued_group`, …). Those reach the snapshot with no change to the
  collector, so that proposal's phase 2 is a change to the board's painting alone.
- **`services`** is the manifest count and the health probe (`<declared>\t<slug>\t<ids up by
  health>`). It is taken by the collector, so a board never runs curl. The board still checks
  beacons (`kill -0`) every frame.
- **`dormant`** is true for a project scanned only because some reader asked for
  `--include-dormant`. Every other board drops it. `include_dormant` says whether this snapshot
  scanned dormant projects at all. A `--plain --include-dormant` that finds it false asks for one
  `refresh-all`, and its reader file makes that refresh include them.

Because the board only reads this file, it could be rewritten later (TS, C#) without touching the
collector.

## Tests

`tests/rack/collector.test.sh` runs real collectors against stub clients. It covers: the start
when none is running; reuse when one is fresh, with `--plain` reading rather than collecting; a
request file honoured for one project only; `refresh_one` going through the collector; a board
tick painting each new snapshot once; replacement of a dead collector and of a silent heartbeat
under a reused pid; two boards sharing one collector; and idle exit, with and without a live
reader. It uses short `LV_RACK_*` timeouts and does not need Docker.
