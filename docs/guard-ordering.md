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

## The one exception: a gate that GATES the transition itself

The rule above assumes closing the gate is a downstream *record* of a decision the transition
already carried out. **`spec-approval` is not that shape, on any plan.** Closing it is not a
record of the transition, it is a *precondition* that both scripts able to perform the
transition check first:

| Transition | Script | Refuses until the gate reads answered |
|-|-|-|
| `draft → ready`, any plan | `wf-registry-update.sh` | exit 1 (client-b WFI-012) |
| a gating-tagged **replan**, to `ready`/`active`/`testing` | `wf-replan-target.sh --apply` | exit 2 (WFI-178, WFI-021) |

Transition-then-close is impossible on either — the ordinary way to make a gate read
`GATE_ANSWERED=true` is to close it, which the rule above says to do only *after* a transition
that cannot happen yet. client-c hit the deadlock first on the replan half (WFI-021),
worked around by chaining `wf-gate-close.sh && wf-replan-target.sh --apply` in one shell call
to shrink the unguarded window as far as a shell invocation allows — which is not the same as
closing it.

**The second row is the one this document got wrong.** When the WFI-012 guard was added to
`wf-registry-update.sh` it made the exception universal for `spec-approval`, and nothing said
so here: this section still read "the replan path, and nothing else", and `/wf-attend` still
documented a brand-new plan's approve as transition-then-close with the close deferred to a
later step. That instruction cannot be followed by any plan sitting at the gate, because the
guard reads neither tags nor worktrees — only whether the gate is open and unanswered, which
is what "sitting at the gate" means. client-d's PLN-016 (WFI-015) and client-b' PLN-015
(WFI-023) hit the refusal six hours apart and each reinvented the same workaround by hand.

**The actual fix is not a different order, it's the guard the order exists to approximate.**
Nothing above requires the transition-first order for its own sake; it requires that no
window exist in which the plan is both unguarded (no open gate, no claim) and stale. A claim
guards that window exactly as well as an open gate does — "a gate **or a claim** is absolute"
above — so for this one case, hold the claim across both calls instead of ordering around them:

```
1. wf-claim.sh <plan-name>                       ← guard up before anything moves
2. wf-gate-close.sh <PLN-ID> "approved" …          ← now safe: the claim, not the gate, covers the gap
3. wf-replan-target.sh <PLN-ID> --apply            ← the transition the close unblocked, committed
4. wf-unclaim.sh <plan-name>                       ← guard down last, as always
```

This is not a license to reorder anything else. It applies only where a script's own
precondition makes transition-then-close impossible to satisfy — today that is `spec-approval`,
in both rows of the table above, and nothing else. Everywhere the general rule *can* be
followed, follow it.

## One artifact, one question

A related constraint, and the reason a second exception exists: gates are stored **one file per
artifact**, not one per gate name. `gate_open <id>` is a boolean the dispatcher reads about an
artifact, and an artifact parks on one question at a time.

So a flow that would leave two gates open on one plan cannot. `wf-gate-open.sh` refuses a
different gate while one is open (exit 5), and `wf-gate-close.sh --gate X` refuses when the open
gate is not X (exit 5). Before those refusals existed the second open overwrote the first and the
close filed its resolution against the surviving question: client-b WFI-025 ended with a
`needs-input` resolution recorded against a `spec-approval` question, published in findings.md as
the decision of record, and `wf-list-gates.sh` reporting `GATES: 0` over a plan owing two answers.

The practical consequence is one more close-first case, for the same reason as the section above:
when answering a `needs-input` gate means sending the plan back to `/wf-spec`, the replan opens
its own `spec-approval` gate, so `needs-input` has to close before the handoff rather than after
it. The answer is what *authorizes* the replan; it is not waiting on its outcome.

**Adding a guard of this shape is what makes the exception grow, so say so here when you add
one.** A precondition that refuses a transition until a gate is answered is not a local change
to one script: it silently inverts the exit ordering of every skill that performs that
transition, and those skills are written in prose that no test reads. The check when adding
one is the sweep below, plus this section.

## Reviewing a change

When a skill's exit path is edited, check that the last three commands are still in this
order. A quick sweep for the shape:

```bash
grep -n 'wf-gate-close\.sh\|wf-unclaim\.sh\|wf-registry-update\.sh' skills/*/SKILL.md
```

An `wf-unclaim.sh` or `wf-gate-close.sh` line appearing *above* the transition that it
belongs with is the bug — **unless** the gate being closed is `spec-approval`, where it is
the fix, and the line that should appear above *both* is `wf-claim.sh`. A `spec-approval`
close with no claim taken before it is the other bug.

## Related

- [`eligibility.md`](eligibility.md) — what the dispatcher checks and where each rule lives
- [`orchestrator.md`](orchestrator.md) — sweep loop, gates, claims, attempt budgets

---

## The same contract at park time

Everything above is about an exit that *advances* a plan. A plan parked on a gate exits too,
and it has the same two guards in the same relationship — just reached from the other side:

```
1. open the gate        wf-gate-open.sh …      ← guard UP
2. release the claim    (wf-gate-open.sh does it)  ← guard DOWN
```

**Gate up before claim down.** At no instant is the artifact both unguarded and parked. Reverse
it and there is a window in which the plan has no gate and no claim while its worker walks away
— which is the two seconds WFI-079 dispatched a tester into, entered from a different door.

### Why the script does it and the skill does not

A review of all 25 skills against [`docs/prompt-contract.md`](prompt-contract.md) found the
claim disposition missing from every `[GATE]` exit in `wf-spec`, seven stop/gate exits in
`wf-test`, four in `wf-deploy`, and the approve path in `wf-attend`. `wf-consistency` repeated
it on its escalated exit. That is roughly twenty exit paths across six skills, each of which
had to remember the second half of a two-part action.

`wf-spec:913` is the tell. The library hit this exact failure, wrote it down as WFI-012, fixed
the one path it bit on — the Replanning exit, which had left a worker holding a claim on a plan
it had just moved to `active` — and never propagated the fix to the five gate exits in the same
file. Prose guarantees erode toward the shape of whichever path someone last debugged.

So `wf-gate-open.sh` releases the claim itself. A caller that has opened a gate has parked the
work by definition, and the claim it still holds is redundant from that moment: the gate is
already a standing skip reason for the dispatcher **and**, since v12.0.0, for `wf-spawn.sh`.
The twenty decisions collapse into one script behaviour that cannot be got wrong, which is the
contract's own principle — determinism belongs in bash, and judgment is spent only where
nothing cheaper will do.

### The two exceptions

**`--hold-claim`** is for a caller that keeps working the artifact after the gate is up — an
attended skill mid-procedure, `/wf-attend` answering in place.

**`RELEASE` and `DEPLOY` hold by default.** Their skills resume in place after an answer, and
the claim is what keeps a second promotion out while a human is deciding on the first.

### The other door

`wf-spawn.sh` never checked gates. The dispatcher did — a gate is one of its standing skip
reasons — but the dispatcher is not the only way a worker is launched. `wf-unclaim.sh` serves
deferred spawn markers the moment a claim drops, and that path consulted nothing.

Which made the sequence: something tries to spawn while the plan is claimed and is deferred to
`pending/`; the holder parks the plan on a gate and releases its claim; the release serves the
marker and launches a worker at a plan sitting on an unanswered human decision. Making
`wf-gate-open.sh` release the claim would have widened that hole rather than closing it, so the
guard went into `wf-spawn.sh` first — where every launch path converges, and where the same
read also answers redundantly for the dispatcher's own calls. A guard only one caller performs
is a guard the next caller forgets.
