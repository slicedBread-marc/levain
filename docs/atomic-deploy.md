# Atomic deploy — the client harness is never mutated in place

> **Status: implemented in v9.0.0.** Origin: coordinator WFI-003, and the review that followed it.
>
> Entry points: `install.sh` (`atomic_write` / `atomic_install`, the `scripts/gen/` build
> and the `scripts/current` flip), `scripts/lv-exec.sh` (resolves through `current`),
> `scripts/lv-prune-versions.sh` (retires old builds), `deploy-all.sh` (no longer refuses
> to run while a daemon is live).

## The gap

`install.sh` rewrote the running harness under whoever was running it:

```bash
sed -e "s|{{project_slug}}|$PROJECT_SLUG|g" "$script" > "$DEST"    # scripts/v2.00/lv-foo.sh
```

One `>` per file, ~102 files per generation, per client. For the duration of that loop
`scripts/v2.00/` is a mixture of two harnesses, and each individual file is briefly
truncated. An orchestrator daemon sweeps out of that same folder every 60s and re-reads
`lv-orchestrate.sh` and `lv-orch-lib.sh` as it goes. A sweep landing in the window reads a
half-replaced folder — or a zero-byte script.

Nothing errors at deploy time. What it produces is confusing dispatch behaviour an hour
later, attributed to anything but the deploy.

Everything `deploy-all.sh` grew is compensation for that one missing property:

| Mechanism | What it is compensating for |
|-|-|
| Refusing to deploy while a daemon is live | The write window |
| `--stop-daemons` | The same, with an escape hatch |
| `--force` | The same, with the escape hatch removed |
| `.deploy-suspended-daemons` | A retried `--stop-daemons` losing the record (coordinator WFI-003) |
| The `setsid`/`exec`/fd-detach comment block | Restarting what the guard stopped |

The 8.3.0 → 8.6.0 deploy ran with client-b' daemon live and survived. That is luck, not a
guarantee, and the header of `deploy-all.sh` said so.

## The property

**No path that a running process resolves is ever written twice.**

A deploy builds somewhere new and then moves one pointer. A process mid-run keeps a
complete, self-consistent harness; the next process to resolve the pointer gets the new one.
That is the whole idea, and it is worth stating as an invariant because every rule below
follows from it mechanically.

It also answers the question that prompted this — *can an update be staged so a busy agent
keeps its version and the next call picks up the new one?* Atomicity is the half of that
which costs almost nothing, and it is the half everything else depends on. Deferring the
flip to a quiescent boundary, and pinning a generation for a whole worker run, are separate
changes that build on this one; they are not implemented here.

## Layout

```
scripts/
  current                       one line: the build id the harness resolves to
  gen/
    9.0.0-20260916143012/       a build. Immutable from the moment it is named.
      v1.x/
      v2.00/
    8.10.1-20260915101500/      the previous build, retained
  lv-exec.sh                    unversioned dispatcher
  version-map.txt
  lv-prune-versions.sh
```

A **build id** is `<workflow version>-<UTC timestamp>`. The timestamp is not decoration: it
makes every deploy produce a directory name that has never existed, which is what lets the
build be created by a single `rename(2)` with no destination to displace. Re-deploying the
same workflow version — the common case while developing the library — is then a new build
like any other, rather than a special case that has to overwrite something.

Resolution is unchanged in its first half and new in its second:

1. effective workflow version → generation **label** (`v2.00`), via `version-map.txt`. This
   is the existing pinning contract and nothing here touches it.
2. label → **path**, via `scripts/gen/$(cat scripts/current)/<label>/`.

If `current` is missing, or names a build with no such label, `lv-exec.sh` falls back to the
legacy `scripts/<label>/` path. That fallback is what makes the first gen-era deploy safe on
a client still running the old dispatcher, and it is load-bearing during the migration
window described below — it is not dead code.

## Why a pointer file and not a symlink

The obvious shape is `scripts/v2.00 -> gen/<build>/v2.00`, flipped with `mv`. It does not
work, and it fails silently in the worst possible direction:

```console
$ ln -s a link; ln -s b tmplink; mv -f tmplink link; readlink link
a                      # unchanged
$ ls a
OLD  tmplink           # the new link was moved INSIDE the old target
```

BSD `mv` dereferences a destination that is a symlink to a directory. GNU `mv -T` suppresses
that; macOS `mv` has no `-T`, and every client here is macOS. `ln -sfh` avoids the
dereference but does unlink-then-symlink, which is the same non-atomic window in miniature.

A **regular file** has none of this. `mv tmp scripts/current` where `current` is a regular
file is a plain `rename(2)`: atomic, no dereference, portable. Readers do one `cat`. So the
pointer is a file, and the only thing that reads it is `lv-exec.sh`.

The same reasoning applies to every single generated file — `lv-exec.sh`, `version-map.txt`,
each `SKILL.md`, the hooks, `WORKFLOW.md`, `.claude/workflow.md`. They are written through
`atomic_write` (write `$dest.wftmp.$$`, rename over `$dest`) rather than `>`. A skill is read
by Claude Code at invocation; a truncated `SKILL.md` is the same class of fault as a
truncated script, and costs one helper function to remove.

## Flip order, and the one window that remains

Within a single install, in this order:

1. Build `scripts/gen/.building.$$/` complete — every label, every script.
2. `mv` it to `scripts/gen/<build id>`. The build now exists and is immutable.
3. Record the outgoing build id, then **flip** `scripts/current`. ← the deploy takes effect
4. Atomically replace `lv-exec.sh`, `version-map.txt`, `lv-prune-versions.sh`.
5. Retire old builds and legacy folders.

**The flip precedes the dispatcher replacement deliberately.** Between 3 and 4 a caller runs
the *old* `lv-exec.sh` against the *new* `current`:

- On the first gen-era deploy, the old dispatcher does not know `current` exists and resolves
  `scripts/<label>/` — still on disk, still the old harness, wholly consistent.
- On any later deploy, both dispatchers are gen-aware and agree.

Reversing the order would produce the one genuinely bad pairing: a new dispatcher reading a
`current` that still names the outgoing build while `version-map.txt` has already moved.

Between 3 and 4 the new build is also being resolved through the *old* `version-map.txt`.
Every label the old map names was built in step 1, so this resolves; a label the library has
since dropped falls back to its legacy folder. This is why step 1 builds a folder for every
label in the library source rather than only the current one.

## Retention

Step 5 keeps the new build, the one it replaced, and **any build a live process is running out
of**. Everything older goes.

The original rule was "current and previous", on the reasoning that the only thing holding a
build open is a script subprocess living seconds to minutes. That was wrong in both directions
that matter, and client-a paid for both inside one minute — two deploys, and the build under
them was 9.4.0:

- **A worker runs for hours out of the build it was launched from.** `lv-spawn.sh` detaches a
  `bash -c` whose last line logs the run's exit through that build's `lv-event.sh`. WFI-256: a
  completed implement run lost its exit event to `No such file or directory`.
- **A daemon runs out of one indefinitely.** It resolves `SELF_DIR` once at startup and calls
  every sibling from there. WFI-257: bash held the open file of `lv-orchestrate.sh` itself, so
  the loop kept sweeping, kept writing events, and kept answering `--daemon-status` *running*,
  while every spawn died `rc=127`. It then announced "the pipeline is empty or complete" — over
  an active plan and an open gate — because `lv-list-gates.sh` was in the same deleted tree and
  its failure was indistinguishable from an empty list. 71 minutes, silently.

So liveness is now part of the rule: `build_in_use` asks `pgrep -f "/gen/<build>/"`, which is
exactly the shape both holders have — the daemon's own command line, and the detached wrapper
carrying the build's `lv-event.sh`. The exemption is about liveness and not about the build, so
the next deploy after the process exits collects it; otherwise this trades a deleted harness for
an unbounded one.

Both holders also defend themselves now, because a retention rule is a policy and the callers
should not depend on it holding:

- `lv-spawn.sh` prefers the pinned `lv-event.sh` and falls back to `scripts/lv-exec.sh`.
- The daemon re-checks, once per sweep, where `scripts/current` says its own script lives, and
  `exec`s onto it when that is somewhere else. `exec` preserves the PID, so the pidfile, the
  claims stamped with it and `--stop` all stay valid — the daemon startup path allows a pidfile
  naming its own PID for precisely this case. With nothing to re-exec onto it stands down with
  exit 5 rather than sweep from a tree that no longer exists.

`lv-prune-versions.sh` retires builds on demand and reports them in `--list`. It keeps its
existing job too: a *label* is retained while any non-complete plan's WF stamp resolves to
it, which is the generation-pinning contract and is orthogonal to build retention.

**Legacy `scripts/v*/` folders are not removed by the deploy that introduces `gen/`.** They
are the fallback that keeps a mid-flight old dispatcher working, and a process that started
before the flip may still spawn siblings out of one. They are removed by the *next* deploy —
detectable because `scripts/current` already existed when the install began.

## What this changes in `deploy-all.sh`

The daemon guard is what the invariant was bought to retire. Its default inverts:

- **(default)** deploy, daemons and all. No refusal, no stop, no restart.
- `--stop-daemons` retained. Nothing needs it now, but a deploy that changes something a
  daemon caches beyond the script folder is still a reason a human might want it.
- `--force` accepted as a no-op with a deprecation line — it named the old default.

The suspend-state file and the detach machinery stay, because `--stop-daemons` still uses
them, and their comments still record why they are shaped the way they are.

## What this does *not* fix

- **A skill already loaded into a session's context.** Claude Code reads `SKILL.md` at
  invocation. Atomic writes guarantee it never reads a torn one; nothing can retroactively
  change text the model has already read. "Next invocation gets the new skill" is the
  strongest available semantics, and it is now the actual one.
- **A version switch mid-skill.** One skill invocation makes dozens of `lv-exec.sh` calls,
  and each resolves `current` independently, so a flip between two of them mixes builds.
  Every individual script is whole and every build is self-consistent, so this is far weaker
  than the fault being fixed — but it is real, and it is exactly what deferring the flip to a
  claim boundary would close. That is the next piece, not this one.
- **Generation pinning per run.** The WF column still pins a *label*, not a build, so an
  in-flight plan continues to pick up harness fixes as it always has — which
  `version-map.txt`'s header argues for at length, and which this change deliberately
  preserves.

## Acceptance criteria

```bash
# 1. A deploy never leaves a client's resolved script folder half-written.
#    (tests/atomic-deploy.sh runs a reader in a loop across a live install.)

# 2. The pointer survives a same-version redeploy.
./install.sh <client> && a=$(cat <client>/scripts/current)
./install.sh <client> && b=$(cat <client>/scripts/current)
[ "$a" != "$b" ]                       # a new build each time

# 3. Two builds retained, no more — plus any a live process is running out of.
ls <client>/scripts/gen | wc -l        # → 2 with nothing running

# 3a. A daemon survives the deploy that replaces its build, keeping its PID.
ps -o command= -p "$(cat <client>/.claude/orchestrator/daemon.pid)"   # names the NEW build

# 4. deploy-all.sh does not refuse a live daemon.
./deploy-all.sh                        # exit 0 with daemons running
```
