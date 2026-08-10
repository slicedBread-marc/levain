# Guard ordering on exit

Every skill that finishes with a plan has to hand it back. Three things happen in that
handback, and **the order is a contract, not a style preference**:

```
1. commit the state transition      wf-registry-update.sh … --commit …
2. close the gate                   wf-gate-close.sh …
3. release the claim                wf-unclaim.sh …
```

Transition first. Guards down last, gate before claim.

## Why

The dispatcher decides what to run from three facts: the plan's registry state, whether a
gate is open on it, and whether a live session holds its claim. Those are read at slightly
different moments, and everything below follows from that.

**An uncommitted transition does not exist.** `wf-registry-update.sh` writes and commits
under a lock precisely because a dirty `REGISTRY.md` on the shared develop working tree is
not durable — another worker's `git stash push --include-untracked` takes it, another's
pathspec commit carries it under the wrong message. client-a lost a whole `ready→active`
transition that way (WFI-065). Until the commit lands, every other session still reads the
old state.

**A gate or a claim is absolute.** While either is up, no worker is dispatched at the plan
regardless of what the registry says.

Put those together and there is exactly one safe order. Drop a guard before the transition
has landed and you create a window — up to a full sweep interval wide — in which the plan
is unguarded *and* stale. Everything the dispatcher checks says go, and what it is going on
is a state that has already been superseded.

## The failure this came from

client-a, 2026-08-05 (WFI-079). An attended `/wf-test` on PLN-006 found five issues and
routed the plan back to the planner:

```
15:32:33Z  gate-close  PLN-006 manual-test "manual test found 5 issue(s)"
15:32:35Z  spawn       PLN-006 test (haiku) pid 58919      ← the window
15:32:38Z  commit      990dbac "registry(PLN-006): testing → draft"
```

Two seconds. The daemon's sweep landed inside it, read `testing` — still true — found no
gate and no claim, and launched an unattended tester at a plan that was on its way to
`draft`. That worker ran the whole e2e scope and, at 15:37:10Z, opened a *fresh*
`manual-test` gate asking a human to eyeball acceptance criteria on a plan that had been in
`draft` with five unaddressed findings for four and a half minutes.

The false gate was worse than the wasted run: subsequent sweeps logged
`skip PLN-006 test: gate open`, so the plan could not be dispatched to `wf-spec` either. One
mis-ordered exit blocked the plan outright.

## The two halves of the fix

**Skills order their exit correctly.** Every exit path in `wf-test`, `wf-chrome-test`,
`wf-verify`, `wf-implement`, `wf-spec` and `wf-consistency` commits before releasing
anything. Where a skill previously did a bare transition followed by a separate
`wf-commit.sh`, the two are fused into one `wf-registry-update.sh … --commit … --add …` call
so the row and the files it describes land together.

**`wf-spawn.sh` re-reads the state at the last moment.** Immediately before `exec`, with the
launch decision already made, it greps the plan's row and refuses a role the state no longer
supports (exit 2 — "not mine to do", which both the dispatcher and drive-one already handle).

| Role | States it will launch into |
|-|-|
| `spec` | `draft`, or no row at all (a bug/brief awaiting its first spec) |
| `implement` | `ready`, `active` |
| `verify` | `verify` |
| `test` | `testing` |
| `consistency` | `ready` |

This is a backstop, not the fix. It narrows the window from one sweep interval to the
microseconds between the grep and the `exec` — as close to closed as a check-then-act ever
gets — but a check-then-act it remains. The ordering in the skills is what actually removes
the race.

## The successor a correct exit cannot start

The same ordering has a second consequence, and it is not a race — it is arithmetic. The
post-commit hook that starts `verify` fires from *inside* `wf-commit.sh`, at step 1. The claim
does not come down until step 3. So the hook always meets a claim, always held by the worker
that triggered it, and `wf-spawn.sh`'s claim guard declined every time: the hook's inline spawn
was structurally dead for the exact sequence this document mandates (client-a WFI-086,
WFI-091, two plans, same message).

Spawning anyway is worse than declining — the successor's claim would be written at step 1 and
deleted by the outgoing worker's own `wf-unclaim.sh` at step 3, leaving a live worker on a plan
that reads as free. So the trigger moved to the release:

```
wf-spawn.sh   claim is ours     → write .claude/orchestrator/pending/<num>-<role>.spawn, exit 2
wf-unclaim.sh claim is released → serve the marker, spawn for real
```

`wf_claim_mine` distinguishes our claim from a stranger's (by `WF_CLAIM_PID`, by ancestry, or by
the claim naming this session's own PID — see "Which PID a claim records" in `docs/orchestrator.md`).
A stranger's claim is still a hard stop. The daemon's sweep remains the safety net behind
both — the marker is a low-latency nudge, never the only path.

## Reviewing a change

When a skill's exit path is edited, check that the last three commands are still in this
order. A quick sweep for the shape:

```bash
grep -n 'wf-gate-close\.sh\|wf-unclaim\.sh\|wf-registry-update\.sh' skills/*/SKILL.md
```

An `wf-unclaim.sh` or `wf-gate-close.sh` line appearing *above* the transition that it
belongs with is the bug.

## Related

- [`eligibility.md`](eligibility.md) — what the dispatcher checks and where each rule lives
- [`orchestrator.md`](orchestrator.md) — sweep loop, gates, claims, attempt budgets
