# Services: what a project runs on the operator's machine

A project declares its long-running processes under `services:` in its own `levain.yml`. These
are things like a web container and its tunnel, a worker that watches a folder, or a batch runner.
`lv-services.sh` lists them, starts them, stops them and reports on them, and the coordinator's
rack shows every project's services on one screen (`v`, or `lv-rack.sh --services`). The
reference for each key is the header of `scripts/v2.00/lv-services.sh`. This page covers the
three behaviours that need more than a line there: detached starts, progress and throttle.

## The manifest

```yaml
services:
  synth:
    label: "Synthetic learners"
    start: "tools/run-synth.sh runner"   # run from the chosen checkout
    stop: signal                         # TERM to each beacon's pid and the launch pid
    window: true                         # detached, with a window following its log
    heartbeat: 120                       # a beacon older than this is stale
    checkout: main                       # main (the default) | any
    needs: "synth-app bridge-synth"      # these must be up first
    progress: synth.status.json          # what it is doing (below)
    throttle:                            # how hard it may run (below)
      rate: 20/hour
      concurrency: 1
      budget: 400k tokens/5h
      hours: "23:00-07:00"
      ai_share: 10%
```

Every file named below lives in the project's services state directory,
`$LV_SERVICES_DIR/<project_slug>/`. The default is `~/.local/state/levain/services/<slug>/`, the
same place the beacon records go.

## Detached starts (the coordinator's LVI-049)

A service stopped by signal (`stop: signal`, or no `stop:`) is the long-running process itself.
Unless the manifest says `window: false`, `start` runs it like this:

- **in a session of its own**, using `setsid`, or perl's `POSIX::setsid` on macOS, which has no
  `setsid`, or `nohup` when neither is available;
- **with stdin closed**, and stdout and stderr going to `<id>.log`. The previous run's log is kept
  as `<id>.log.1`;
- **with its pid recorded** in `<id>.launch`.

The Terminal window that opens only runs `tail -F` on that log. Before this change the start:
command was typed into a fresh interactive shell, and a shell startup prompt (oh-my-zsh's update
question) took the typed line as its answer, so the service never started. Now a prompt like that
blocks the tail, never the service. Closing the window stops nothing, and `lv-services.sh log <id>`
(or `l` on the rack) opens a new one.

What this means for a launcher:

- **It cannot read the terminal.** A launcher that asks a question has to take the answer some
  other way. A secret store read that needs no TTY still works, so a launcher that reads keys is fine.
- **It is still refused under an agent.** `lv-services.sh start` refuses when `CLAUDECODE` is
  set, and the detached process inherits that environment from the operator's own terminal.
- **`stop: signal` sends TERM to every live beacon pid and to the launch pid**, and never to a
  window's shell. A launcher that leaves no beacon can therefore still be stopped, and while its
  launch pid lives a second start is refused (exit 6).
- **A start that dies within `LV_SERVICES_SETTLE_SECS` (0.5 s)** prints the end of its log and
  exits 8, and no window opens. A launcher that refuses because of a missing key, for example,
  shows its message on the rack.

`LV_SERVICES_OPENER` replaces Terminal in tests. It receives the window's command line.

## Redeploy (the coordinator's LVI-057)

A service that runs from main serves the build it was started from. A release that moves main
changes nothing it serves until someone restarts it, and before this nothing even showed that it
was stale: a beacon-less compose service had no commit on `status`.

```yaml
services:
  household:
    start: "tools/run-household.sh up"
    stop: "tools/run-household.sh down"
    compose: "myapp-household"
    redeploy: auto            # only with checkout: main (the default)
```

- **The deployed commit** is, in order: the `org.opencontainers.image.revision` label of a running
  container of the service's `compose:` project (what actually runs), else `<id>.deployed`, which
  every `start` writes (the checkout's full HEAD), else a beacon's commit. `status` fills a
  beacon-less up service's checkout, commit and `behind=N` from it.
- **`lv-services.sh redeploy [<id>...] [--auto] [--dry-run]`** stops and restarts each up,
  main-only service whose deployed commit is not at or past main: stop, wait until down
  (`LV_SERVICES_STOP_WAIT`, 60 s), start with no window (`LV_SERVICES_NO_WINDOW`). With no `<id>`
  it takes every service declaring `redeploy: auto`. It prints `REDEPLOYED`, `FAILED` or `WOULD
  <id> <deployed> -> <main>`, and exits 1 when a start failed.
- **A failed start is recorded** in `<id>.redeploy` with main's commit; `--auto` never retries that
  commit, an explicit `redeploy <id>` does. One redeploy runs per project at a time
  (`redeploy.lock/`, a dead holder's lock is taken over).
- **It runs in the operator's terminal.** Refused under an agent except `--dry-run`; `--auto` is
  silent instead, as it is when another redeploy holds the lock.
- **The rack's collector runs `redeploy --auto`** in the background after each full collect, for
  each project whose `levain.yml` declares `redeploy: auto`, and logs each line to
  `collector.log` as `redeploy <project>: …`. A collector started under an agent does nothing.
  `LV_RACK_REDEPLOY=off` turns it off.

## Progress (the coordinator's LVI-052)

`progress:` names a JSON file that the service writes. The path is either absolute or relative to
the state directory. The library reads three fields from it and nothing else:

```json
{"summary": "pass 3/8 struggler-en, $0.41 of $1.40 (29%), 12 sessions",
 "detail": ["pass 1/8 reader-en: $0.30", "budget: 110k of 400k tokens in 5h"],
 "updatedAt": "2026-11-15T02:23:43Z",
 "state": "running"}
```

- `summary`: one short line, shown in the rack's row.
- `detail`: optional, an array of short lines, shown in the drill.
- `updatedAt`: ISO 8601 with an offset or `Z`. Fractions of any length are accepted (.NET writes
  seven digits).
- `state`: optional, one word for what the service says it is doing. It is shown as "it reports:".

Write the file whole, through a rename, so that the rack never reads half of it. Any other fields
the file carries are ignored.

`lv-services.sh status` appends five fields after `url`. Fields are only ever appended, because
the rack reads them by position:

| # | Field | Values |
|-|-|-|
| 11 | progress | `ok`, `stale` (updatedAt older than `heartbeat:`), `undated`, `missing`, `unreadable`, `-` (none declared) |
| 12 | p.age | seconds since updatedAt, or `-` |
| 13 | summary | the summary, with tabs and newlines folded to spaces, or `-` |
| 14 | control | the throttle's state (below), or `-` when no `throttle:` is declared |
| 15 | reported | the progress file's `state`, or `-` |

If the file is missing or does not parse, the field says so. `status` never fails because of it.
`lv-services.sh progress <id>` prints a `file` line, then those five fields, then the detail lines.

On the rack, the PROGRESS column shows the summary. It is dim when stale, and it moves to a line
of its own on a narrow screen. Those cells are re-read every five seconds without probing health
again. `i` opens the drill, and so does Enter on a service that has no url. The drill re-reads the
file every two seconds.

## Throttle (the coordinator's LVI-041)

`throttle:` declares the service's defaults, and with them the keys that the rack may change. The
rack writes `<id>.control.json` beside the service's beacons. The service reads that file before
each unit of work and never rewrites it. The control file is a flat JSON object, and every field
in it is optional:

```json
{"state": "pause", "rate": "5/hour", "updatedAt": "2026-11-16T22:09:13Z"}
```

| Field | Shape | Meaning |
|-|-|-|
| `state` | `run` \| `pause` \| `stop-for-day` | `stop-for-day` lasts until the `hours` window next opens after `updatedAt` |
| `rate` | `N/hour` | units of work started in the last hour |
| `concurrency` | whole number | units at once |
| `budget` | `N tokens/Mh`, `N` may end in `k` or `m` | tokens per rolling window of M hours |
| `hours` | `HH:MM-HH:MM`, local time | when it may run; the range may wrap midnight, and equal ends mean always |
| `ai_share` | `N%` | the share of the budget one class of work may use |
| `updatedAt` | ISO 8601 UTC | stamped by every write |

A field that is absent falls back to the manifest's `throttle:` value. The library checks the
shape of the six fields above. Any other key a service declares is passed through as a string.
**Running out of budget means waiting for the next window, never failing.** Enforcing that
belongs to the service.

The library's side:

```bash
lv-services.sh throttle <id>                  # state and each key: value, and whether the control file or the manifest set it
lv-services.sh throttle <id> pause            # state: pause
lv-services.sh throttle <id> stop-for-day     # state: stop-for-day
lv-services.sh throttle <id> resume           # state: run
lv-services.sh throttle <id> set rate 5/hour  # one declared key
lv-services.sh throttle <id> unset rate       # back to the manifest's value
```

Each write merges into the file through a rename. Fields it does not name are kept, and
`updatedAt` is stamped. A control file that does not parse is refused (exit 9) rather than
overwritten, because someone may have written it by hand. `pause` and `stop-for-day` are allowed
under an agent, because either one only slows a run down. `resume`, `set` and `unset` can make a
run draw more, so they refuse under an agent, the same way `start` does.

On the rack, a paused service's row shows `⏸ paused`, and a stopped one shows
`⏹ stopped for the day`. `p` pauses or resumes. In the drill, `d` stops the service for the day
and `s` sets a declared key's value. The drill lists each key with its source, and the progress
file shows what the service reports: sessions run, tokens used against the budget, queue depth,
and its own state (running, paused, throttled, out of hours, over budget). Those belong in its
`summary`, `detail` and `state`.
