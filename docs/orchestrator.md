# Orchestrator

The pipeline had a complete state machine and no dispatcher. Every transition
needed a human to notice it and trigger the next skill — four terminals, constant
attention, and the whole board held in your head.

The orchestrator is the dispatcher. It watches `plans/REGISTRY.md` and launches
unattended workers by state, so the only thing left for a human is the set of
decisions a machine shouldn't make.

## Design

```
                    ┌─ wf-orchestrate.sh ─┐
   post-commit ────▶│  --sweep  (one pass)│──▶ wf-spawn.sh <role> <artifact>
   (low-latency     │  --daemon (loop)    │      └─ claude -p --model <tier>
    nudge)          │  <ID>     (drive-1) │         WF_UNATTENDED=1
                    └──────────┬──────────┘
                               │ reads                 writes
              wf-list-*.sh ────┘                 .claude/orchestrator/
              gates, claims, deps                  gates/  logs/  events.log
```

Three properties worth stating, because they're the reason it's cheap and safe:

1. **Routing is pure bash.** State → role is a table lookup. The orchestrator
   never calls a model; only workers cost tokens, each on its cheapest
   sufficient tier.
2. **Eligibility is not reimplemented.** The existing `wf-list-*.sh` scripts
   (spec'd in [eligibility.md](eligibility.md)) remain the single source of truth
   for what's actionable. The dispatcher parses them and adds skip rules.
3. **One spawn path.** The post-commit hook and the daemon both call
   `wf-spawn.sh`, so the pidfile guard lives in one place and they cannot
   double-launch a plan.

## Roles and tiers

| State | Role | Default model | Why |
|-|-|-|-|
| `draft`, open bugs, decided briefs | spec | opus | Planning is where judgment lives |
| `ready` with unchecked `Deps` | consistency | sonnet | Nothing else reads across plans |
| `ready`, `active` | implement | sonnet | Bulk of the work |
| `verify` | verify | sonnet | Already autonomous before this existed |
| `testing` | test | haiku | Guided by the plan's criteria |

Sweep order is **verify → test → consistency → implement → spec**: drain the
furthest-along work first so WIP doesn't pile up behind freshly specced plans.
`consistency` sits immediately ahead of `implement`, and a plan still owing a
pass is filtered out of the implement candidates — a cross-plan contradiction
caught while both plans are still documents is an amendment; caught after one is
built, it is a migration.

### The consistency pass

Every review in the pipeline is scoped to one plan, so two plans can each be
correct alone and contradict each other. One program specified a forward-paging
list API in PLN-003 while PLN-007 needed to page backward; both reviews passed on
the point, and it surfaced only because an attending human happened to hold both
plans at once. The same missing-provisioning-path defect appeared independently
in 7 of 16 plans — a pattern no per-plan reviewer is scoped to see.

`wf-consistency` reads a plan plus its full dependency closure and checks only
inter-plan claims: consumed APIs exist with the assumed shape, required entities
have a provisioning path somewhere, no two plans define the same artifact
incompatibly, and no dependency's prohibition has outlived its purpose to the
point of making a downstream plan unbuildable. Findings against an **unbuilt** dependency become amendments to it;
findings against a **built** one open a `consistency-migration` gate.

It writes `## Consistency` into the plan, which is the done-marker
`wf-list-consistency.sh` reads — so it runs once per plan, not once per sweep.
Turn it off with `orchestrator.consistency_pass: false`, but read the note under
`specApproval` first: it is the compensating control for verdict-mode spec
approval.

## Skip rules

An artifact is not dispatched when any of these hold:

| Condition | Detected by |
|-|-|
| A gate is open on it | `wf-list-gates.sh <ID>` |
| Another session holds its claim | `claims/<NNN>/.wf-claim` (via the list scripts) |
| Its deps are not `complete` | `PLAN_BLOCKED` / list-script `blocked` rows |
| Its role is at `max_concurrent` | live pidfiles under `.claude/orchestrator/logs/` |
| It's over `max_attempts_per_plan` | `.claude/orchestrator/attempts/<ID>.<role>` |
| The hourly spawn budget is spent | `.claude/orchestrator/spawns-<YYYYMMDDHH>` |
| It still owes a consistency pass (implement only) | `wf-list-consistency.sh` |

And nothing at all is dispatched when the whole sweep is disqualified:

| Condition | Detected by |
|-|-|
| The main worktree is not on `develop` | `checkout_available()` in `wf-orchestrate.sh` |

### The registry is a file, and only develop's copy is the state machine

`plans/REGISTRY.md` is tracked on `develop`. Every other branch carries its own
older copy — whatever it last merged. So when the shared main worktree is
checked out anywhere else, the dispatcher is not reading the state machine; it
is reading a snapshot of it.

client-a's WFI-135 is what that costs. An interactive `/wf-release` checked
out `release`, where PLN-051 still read `active` while develop had it
`complete`. Within three minutes the daemon dispatched two unattended
`wf-implement` workers at a finished plan. Nothing raced — the registry was
moved out from under the dispatcher by a documented step of another skill, and
every plan whose state had advanced since the last release sync was exposed the
same way, for as long as the checkout stayed off develop.

`release` and `main` used to be on the allow-list, on the reasoning that a
release or a deploy legitimately parks the root there. It does — and that is
precisely when the registry is wrong. So the rule is now "is this develop?",
with one exception: before `develop` exists there is no other copy to be stale
against, so a greenfield client dispatches from whatever branch it has.

The pause is latched, self-clearing and loud: the sweep prints which branch it
is standing on and why, and the next sweep after the checkout returns to
develop dispatches normally. `/wf-release` and `/wf-deploy` are each responsible
for handing the checkout back when they finish — a release left parked stops the
pipeline, silently, until someone notices.

### Claims name the worker, and the worker knows it

The dispatcher claims an artifact *before* launching the worker, stamping the
worker's PID on `.wf-claim` — the claim belongs to whoever hands out the work,
or two workers start inside the window between "the dispatcher decided this was
free" and "the worker said so" (WFI-067).

That makes "another session holds the claim" ambiguous from inside the worker,
and the ambiguity was expensive: a dispatched `wf-test` read the claim taken out
*for it*, reported a human who did not exist, and exited in 15 seconds. Every
plan reaching `testing` under the daemon parked as `stuck` after three such
no-op dispatches (WFI-073, WFI-075), and the same confusion told an explicitly
dispatched implementer its own plan was `processing` (WFI-076).

So ownership is now answerable. `wf-spawn.sh` exports `WF_CLAIM_PID` into the
worker's environment, and `wf_claim_mine` also accepts a claim whose PID is an
ancestor of the asking process, or one naming the asking session directly —
which covers the foreground spawn path, a caller that lost the environment, and
a caller whose ancestry chain is broken by a sandbox wrapper. `wf-claim.sh
--if-free` refreshes a claim it recognises as its own and exits 0; exit 2 now
means, and only means, somebody else. An attended session's claim names that
session, which is never an ancestor of a different one, so a human mid-test is
still protected.

**Both forms respect a live claim, as of v6.6.** `--if-free` used to be the flag
that stood down and the bare form the one that ignored a claim — and the skills
present the bare form as the *attended* default, which is backwards: the
attended caller is the one whose sessions the unattended workers are meant to
stay out of. An attended `/wf-spec` overwrote the dispatcher's claim for a live
`wf-test` worker mid-run and printed "Claimed PLN-059" (WFI-146). Now both forms
exit 2 against another live session, and taking a claim on purpose is
`--steal` — which says whose it was and writes a `claim-steal` event. Prefer it
over `wf-unclaim.sh` + `wf-claim.sh`: unclaiming is also a *trigger*, and flushes
any spawn the daemon deferred behind that claim.

**The claim also carries the state precondition, as of v6.15.** A dispatch is a
statement about the registry at the moment it was read, and the worker acts on
it some time later; nothing re-checked in between. A `wf-verify` worker was
handed PLN-078 whose verify, human test, PR merge and bug close were all already
committed — it stood down by judgement, but a verify that runs to completion
routes on its findings, and routing a `complete` plan sends it back to `testing`
(WFI-153). So every dispatched role now claims with the states it can actually
work — `--state verify`, `--state testing`, `--state ready,active`, `--state
ready` — and `wf-claim.sh` exits **3**, claiming nothing, when the plan has moved
on. The check is skipped when no `PLN` row exists for that number, so a spec
worker claiming `BUG-096` before the plan exists is unaffected.

### Which PID a claim records

A claim is only worth what its PID outlives. `wf_session_pid` records, in order:
`$WF_SESSION_PID` if a caller set it, then `$CLAUDE_PID` — the agent session's
own process — and only then falls back to walking up the process tree to the
first non-shell ancestor.

The walk is last because it is a guess, and it guesses wrong wherever something
that is not a shell sits between the script and the session. A sandboxed tool
call inserts exactly that, so the walk stopped on a wrapper that died with the
call and **every attended claim read as stale**. client-a's WFI-102: the
daemon dispatched an unattended `wf-test` onto a plan a human was mid-test on,
and that worker's container cleanup destroyed the container the attended session
was testing in and blanked `test-progress.md`. `$CLAUDE_PID` lives exactly as
long as the session that took the claim, which is the lifetime a claim means.

### A claim keys on the number, not on the folder

Claims live at `.claude/orchestrator/claims/<NNN>/.wf-claim`, keyed on the
artifact **number** — the same identity `wf-spawn.sh`'s already-running pidfile
guard uses, and the only one the work actually keeps: the counter is global and
one piece of work carries two names through spec (`BUG-022 → PLN-022`,
`BRF-002 → PLN-002`).

They used to live at `plans/<PLN-NNN-slug>/.wf-claim`, which ties the claim to a
folder the work does not have yet. A spec worker dispatched onto a brief creates
that folder — so `wf-spawn.sh` skipped the claim entirely and `wf-claim.sh
BRF-002 --if-free` exited 1 with "plan directory not found". Every brief- and
bug-sourced spec run was unclaimed from spawn until it happened to `mkdir`, and
two workers inside that window both pass `--if-free` (client-c WFI-004).
`wf-list-specable.sh` now filters bugs and briefs on the claim too; before, it
offered them unconditionally because there was no folder to check.

A pre-v5.6 claim left in a plan folder is still honoured (`wf_claim_held`) and
adopted into the new location on the next `wf-claim.sh`, so an upgrade mid-flight
does not read a live worker's claim as absent.

### A claim is enforced at the write, not only at the dispatch

`wf-guard-write.sh` runs as a `PreToolUse` hook on `Edit|Write|NotebookEdit`. It
maps the target path to an artifact — any `PLN-NNN` / `BUG-NNN` / `BRF-NNN` in
the path, which covers `plans/`, `bugs/`, `briefs/` and `feature-branches/`
alike — and exits **2** when a *different* live session holds that artifact's
claim, naming `wf-claim.sh <id> --steal` as the one way through.

Until v6.9 the claim was read only at dispatch, by `wf-spawn.sh` and three list
scripts. That answers "should I launch a worker onto this?" and never "may I
write this file?", so it stopped a second worker being *started* and guarded
nothing already *running*. The two sessions that collide most are the daemon's
worker and an attended session that never claimed at all — and no amount of
skill instruction reaches the second one, because the session that most needs
the rule is the one that did not read it. The machine about to write the file is
the only thing positioned to check.

**It is not a lock, and `wf-lock.sh` cannot be one here.** That library is a real
mutex, but its lifetime is one process: it ends with `trap wf_lock_release_all
EXIT`, and its re-entrancy rides on an exported `WF_LOCK_HELD_<NAME>`. Every
agent Bash call is a fresh shell, so a session cannot hold one across two tool
calls. It protects a script's critical section — a REGISTRY row rewrite — and
nothing longer. The claim is the only primitive with a session's lifetime, which
is why enforcement was built on it rather than beside it.

**The guard fails open, deliberately.** It runs before every `Edit` and `Write`
in the repo, and one that failed closed on its own bugs would brick the editor
for the whole project — a far worse outcome than the collision it prevents. Only
a positively identified foreign live claim exits 2. No artifact in the path
(`plans/REGISTRY.md` among them, which is shared by design and has the
`registry` lock instead), no claim, an expired or dead-owner claim, an
unreadable payload, no `python3`, not a repo: every one of those allows the
write silently. Ownership uses `wf_claim_mine`, the same test `wf-claim.sh` and
`wf-spawn.sh` use — reading a claim taken out on the worker's own behalf as
somebody else's is what parked every plan that reached testing (WFI-073/075),
and in the guard it would block a session's own edits.

The installed hook deliberately does **not** carry the `2>/dev/null || true`
suffix the rehydration hooks wear. `|| true` rewrites every exit to 0, and exit
2 is the entire mechanism; a guard wearing it would report the collision and
permit the write anyway, which is worse than no guard because it reads as
protection. A missing harness is tolerated by testing for `wf-exec.sh` up front
instead, which leaves the exit status alone.

The attempt budget is the loop breaker. A plan bouncing `active ⇄ verify`
forever burns tokens silently; after N implement spawns it parks as a `stuck`
gate instead of retrying.

### Resume is not retry

The budget counts worker **launches**, which for a while made it useless: a clean
resume of an 11-step plan spent the same budget as a genuine `active ⇄ verify`
thrash, so long plans parked as `stuck` with nothing wrong and the only
workaround was raising the cap until the loop breaker no longer broke loops.
Nothing recorded forward progress — `wf-implement` kept `progress.md`'s Log
current but never ticked its Steps checklist, which read *1 of 11* while the
branch sat at step 9.

Both halves are fixed together:

- `wf-progress-tick.sh` ticks the checklist and writes the Log line in one call,
  and `wf-implement` calls it on every step commit.
- The dispatcher records a progress signature per plan —
  `<state>:<ticked>/<total>:<consistency-pending>` — and **resets the attempt
  budget whenever it changes.**

So `max_attempts_per_plan: 3` now means what it claims: three launches with *no
forward progress*. If a plan still parks mid-build, the implementer is not
calling `wf-progress-tick.sh`; raising the cap hides that rather than fixing it.

## Gates

A gate is how an unattended worker says *"a human has to decide this"* without
hanging. Instead of asking a question it writes
`.claude/orchestrator/gates/<ID>.gate` and exits 0. The dispatcher skips gated
artifacts; `/wf-attend` drains the queue.

| Gate | Opened when |
|-|-|
| `spec-approval` | A spec is drafted **and reviewed**, under `specApproval.mode: gate` (the default) — writing and reviewing a spec unattended is fine, approving one is not. Also opened in `verdict` mode for plans tagged in `specApproval.gateTags`. The review always runs before the gate opens, in every mode: gating first meant a tagged plan got *less* automated scrutiny than an untagged one, and a human was spent obtaining a review a machine could have run immediately |
| `spec-stuck` | The review blocked the plan for `maxReviewRounds` rounds running. Any mode — the fix loop is the same everywhere |
| `scope-reduction` | A replan's amendment drops or qualifies a capability the plan's `## Goal` promises. Fires whatever the review verdict says: a reviewer judges whether a plan is sound, and a narrowing is very often sound engineering, but whether a capability the user asked for may be dropped is a product decision no verdict answers |
| `consistency-migration` | A plan contradicts an **already-built** dependency — an amendment can't fix it |
| `manual-test` | `wf-manual-gate.sh` says a human is needed: the diff touches a rendering surface **and** unresolved `(eyes:*)` criteria remain |
| `goal-missing` | No concrete goal line; it's quoted in PRs and by the tester, so it isn't invented |
| `migration` | Pending `MIGRATION-NOTES.md` actions for the plan |
| `merge-failed` | `git push` was rejected |
| `stuck` | Attempt budget exhausted |
| `needs-input` | Catch-all — anything a skill would otherwise have asked |

One file per artifact rather than a shared `GATES.md`: concurrent workers would
race on appends, and "is this parked?" becomes a single `test -f`. Values are
single-quoted (`wf_emit`) so a question containing an apostrophe survives `eval`
— the lesson from BUG-094. The queue is ordered by **blocked-closure size**,
costliest first: a gate at the root of a dependency chain holds everything
behind it, and that cost is invisible from the gate itself. Ties break
oldest-first, and re-opening an existing gate keeps its original timestamp, so
nothing starves.

Gates live under the **develop root**, not the current worktree — a worker inside
`feature/PLN-097-foo` must open a gate that `/wf-attend` on develop can see.

### Closing one: a slot readers look up, a ledger that remembers

`wf-gate-close.sh` writes two things:

| Path | Shape | Read by |
|-|-|-|
| `gates/resolved/<id>.<gate>` | latest resolution, `wf_emit` key/values | `wf-gate-status.sh`, by exact path |
| `gates/resolved/<id>.<gate>.log` | append-only, one tab-separated line per close | humans, after the fact |

The slot is a *single* file per plan per gate name, and some gates are opened and
answered once per cycle — `manual-test` once per test run. Each cycle therefore
overwrote the record of the one before it, and a resolution carrying an earlier
cycle's outcome verbatim was indistinguishable from a real one. client-a's
WFI-100: a `manual-test` gate resolved with "criterion 8 FAIL ← ESCALATED to
spec" for a run that never happened, against a row still reading `testing`. The
ledger is what makes "who approved what, when, and from which state" answerable
later; `GATE_RESOLVED_STATE` in the slot is what makes a resolution that
contradicts its own registry row visible at all.

The resolution text is the record of the decision **just made**. Restating an
earlier outcome fabricates a run.

## Unattended mode

Skills are written for a human. Under `claude -p` every prompt is either a hang
or an improvisation. Each of `wf-spec`, `wf-implement` and `wf-test` carries an
`## Unattended mode` section: a table tagging every existing prompt `[AUTO]`
(resolve to a documented default) or `[GATE]` (park, never guess), plus inline
markers at the gates themselves.

Judgment calls encoded there worth knowing:

- **wf-spec** flips auto-test promotion to `[AUTO] yes`, overriding step 7c's
  "never auto-promote". Maximizing automation is the standing direction.
- **wf-spec**'s review gate is `[GATE]` or `[AUTO]` depending on
  `specApproval.mode` — see below.
- **wf-test** does *not* gate on the first Manual criterion, and does not decide
  the question at all: `wf-manual-gate.sh` does, and its answer is final in both
  directions.
- **wf-test** treats an unverified criterion as *not* a PASS. A false PASS ships.
- **wf-consistency** may amend an unbuilt dependency unattended; against a built
  one it must gate, because that is a migration.

### Which gates are actually worth a human

Two of them were measured and found empty, and both were removed on evidence
rather than taste.

**Spec approval** (`specApproval.mode`). In a 16-plan program, 15 plans parked as
`spec-approval`. The architecture review found Critical findings in 8 of 8 gates
drained with a human present — not one plan was approvable as drafted — so the
human's decision was never *"is this good?"* but *"proceed with the fix loop the
reviewer just specified."* Total human input across those 8: the word "approve",
then the word "all". Under `mode: verdict` the review runs unattended and its
verdict is the gate; every plan in that run converged in 2 rounds, and a plan
still Blocked after `maxReviewRounds` parks as `spec-stuck`. Ships as `gate` —
switching is a deliberate grant, and it should not be switched without the
consistency pass running.

The **review runs before the gate opens in every mode**, which is a separate
decision from what the verdict may do. It used to run after: a tag-gated plan
parked untouched and waited for a human to commission the review, so carrying a
`gateTags` tag bought a plan *less* automated scrutiny than not carrying one.
One plan sat gated 3h20m unreviewed, and in the same drain two of four gates
were consumed only to end at `draft` with findings — where an unattended
Blocked verdict routes them anyway. Only an Approved verdict is worth
interrupting a human for; a Blocked one is work, and the fix loop is identical
in both modes.

`gateTags` is the escape hatch and remains non-overridable, but choose the tag
by what a wrong approval costs, not by what the plan is about. A tag carried by
7 of 16 plans describes the project rather than its risky subset, and a gate
list that admits everything gates nothing. The sharper discriminator is
`scope-reduction`, which fires on the decision itself and catches plans no tag
list would have.

**Manual test** (`manualTestGate`). The old rule stopped on any `#### Manual`
criterion, and every plan has some. Sorted by surface, CLI-only plans had 14 of
15 "manual" criteria that were plain shell assertions; browser-UI plans had 12 of
14 that genuinely needed eyes. The gate now keys on whether the diff touches a
configured rendering surface — something the planner does not control when
classifying criteria — so a plan that renders nothing to a human never stops for
one. `(external)` and `(soak)` criteria never gate under any condition: they
cannot be satisfied at gate time either, so gating on them buys a stop and
nothing else.

### Standing authorization for the promotions after `complete` (v6.18)

The pipeline ends at `complete`. `/wf-release`, `/wf-deploy` and the production
push sit outside it — the orchestrator never dispatches them, and until v6.18
there was nowhere to record that a person had authorized them anyway. A user who
said "go ahead and release overnight" was heard by one agent and forgotten at the
next session boundary (client-a WFI-159).

`wf-autonomy.sh` is that home. It reads `orchestrator.autonomy` from
`claude-workflow.yml` and answers one question — *is this action authorized right
now?* — for exactly three actions: `release`, `deploy`, `production-push`. It
performs none of them; `/wf-release` and `/wf-deploy` call it at the point where
they would otherwise prompt, and park a `release-approval` / `deploy-approval`
gate on a no.

Ships **off**: absent config is `mode: attended`, which is the pre-v6.18
behaviour exactly. The vocabulary is closed, `--show` names any `standing_for`
entry that nothing reads, and every grant must carry an author, a date and an
expiry. Judgment gates are untouched — `spec-approval` has `specApproval.mode`
and `manual-test` has `manualTestGate`, and neither is reachable from here.

Read [`autonomy.md`](autonomy.md) before writing a grant.

## Concurrency

Running workers in parallel makes every read-modify-write of `REGISTRY.md` a
race — previously avoided only because humans are slow. `wf-lock.sh` provides
named, repo-scoped advisory locks (`mkdir` as the atomic primitive; macOS ships
no `flock`). The mutators are **self-locking**, so no SKILL.md call site changed:

| Lock | Held by |
|-|-|
| `registry` | `wf-registry-update.sh`, `wf-set-tags.sh`, `wf-set-deps.sh`, `wf-set-priority.sh`, `wf-counter-next.sh` |
| `plan-<ID>` | `wf-goal-push.sh`, `wf-goal-pop.sh` |

`wf-counter-next.sh` was the sharpest edge: two concurrent specs were handed the
same artifact ID.

Acquiring exports `WF_LOCK_HELD_<NAME>`, so a child process taking the same lock
is a no-op rather than a deadlock. Stale locks are reclaimed when the owning PID
is dead or after `WF_LOCK_TTL` seconds.

## Driving one item

The hook for an agent in another repo. Accepts a bug, brief, or plan — the shared
counter makes `BUG-094 → PLN-094` predictable.

```bash
scripts/wf-exec.sh wf-orchestrate.sh BUG-094 --json
```

| Exit | Meaning |
|-|-|
| 0 | Reached the target state |
| 20 | Blocked on a human. **Normal outcome — never auto-retry** |
| 30 | Worker ran, state unchanged |
| 40 | Plan is abandoned — terminal, not successful |
| 41 | A worker for that role is already running; not a fault |
| 1 | Error (bad ID, or orchestrator disabled) |

40 and 41 both exist to keep 30 meaningful. 30 says *something is wrong with the plan or
the skill*, and both of these used to land on it: a dropped plan was an unknown state that
hard-failed, and a plan whose implementer had just spawned its own verify agent looked
identical to a stalled one — the orchestrator was turned away by the already-running guard,
saw no state change, and reported a stall while the real worker ran healthily beside it
(client-c WFI-002). A caller obeying the contract would have retried, burning one of
`max_attempts_per_plan` for a non-fault.

## Safety

Everything below is configurable in `claude-workflow.yml → orchestrator`:

- `enabled: false` by default. Workers run with
  `--dangerously-skip-permissions`; turning this on is a deliberate human grant,
  and `/wf-orchestrate` is explicitly forbidden from flipping it for you.
- `--dry-run` on `--sweep` reports what would be spawned and spawns nothing. It
  is a pure read: no workers, no gates opened, and nothing written to
  `events.log` — a preview that left entries behind would be indistinguishable
  from a real dispatch when the log is read back later.
- The daemon logs a sweep only when it dispatched something. A sweep that
  spawns nothing while no worker is live is a **stall**: it emits one `stalled`
  event naming the gates responsible and their blocked-closure sizes, then
  stays quiet until that situation changes. Total stall is the one condition
  worth notifying on — unambiguous, never self-correcting, and every minute in
  it is wasted wall-clock.
- Skip lines are **latched, not logged**. Every skip reason is a standing
  condition — a gate stays open, a role stays at cap, a spent budget stays
  spent — so one line per candidate per sweep records the same fact forever:
  1,583 identical `skip PLN-002 spec: gate open` lines in 26 hours in one
  measured run. A skip is written when the reason for a (role, artifact) pair
  first appears or changes, and the latch clears the moment that pair
  dispatches, so a plan gated → freed → gated again is reported both times.
- `wf-list-gates.sh` ranks the queue by **blocked-closure size**, not by age.
  A gate's cost is the time until someone looks times the number of plans
  behind it, and the second term is invisible from the gate itself. Column 6 is
  that count; ties break oldest-first so nothing starves.
- Config is read **once, at startup**. Changing `sweep_interval`,
  `max_attempts_per_plan` or any other `orchestrator.*` key needs a daemon
  restart to take effect.
- Per-role `max_concurrent` caps.
- `max_attempts_per_plan` parks thrashing plans.
- `max_spawns_per_hour` is the hard ceiling on a runaway pipeline.
- `max_launch_failures` stands the daemon down (exit 4) when launches keep
  dying before their worker starts. That failure is a property of the daemon
  process, not of any artifact — it fails every dispatch identically until the
  daemon is replaced — so it costs no attempt and parks no plan.
- `--stop` ends the daemon; `--kill-all` also terminates live workers.
- `events.log` is the audit trail: every spawn, exit, gate, skip and sweep.

## Testing

`tests/orchestrator.sh` puts a **stub `claude` first on `PATH`** that records its
argv and simulates the state transition a real worker would make. The entire
dispatch path — selection, caps, gates, attempt budgets, exit codes — is covered
for zero tokens.

Run it with `WF_TEST_SCRIPT_DIR=<path>` to point the suite at an alternate copy
of the scripts; that's how the locking and prefix-collision assertions were
proven to fail against pre-fix code.
