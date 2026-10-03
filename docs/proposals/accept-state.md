# Proposal: an `accept` state for human acceptance

**Status:** built in workflow 15.0.0 (2026-10-03), phases 1 and 2 together. Where the build
differs from what follows, the build won, and the paragraph says so. Tests: `tests/accept-state.sh`,
plus the drive-one case in `tests/orchestrator.sh`.
**Decided so far:** acceptance is one pipeline stage with two flavours, `accept:auto` and
`accept:manual` (see [Naming](#naming-one-stage-two-flavours)). A new `/lv-accept` skill owns the
manual flavour, and the `manual-test` gate stays alongside it.
**Release level:** major. It adds a registry state (schema 6 → 7) and changes `/lv-test`'s
exit contract.

## Why

`testing` does two jobs today. The first is unattended: the suite, Playwright on every
criterion it can drive, deferrals, and the `lv-manual-gate.sh` verdict. The second is a human
walking whatever was left. They share one state, one claim and one skill. The split between
them is a gate file sitting on top of the state, and a gate was not built to carry that load:

| Incident | What the gate-on-a-state shape did |
|-|-|
| WFI-070 | The open gate is the only thing that keeps the daemon off a plan a human is testing. `/lv-attend` closed it on handoff, and 92 seconds later an unattended tester tore down the human's container |
| WFI-100 | `manual-test` is cycle-scoped, so each test run overwrites the last one's answer. A resolution repeated an earlier cycle's outcome for a run that never happened |
| WFI-082 | A stale `manual-test` gate sat on a plan that had already gone back to `draft`, and the attendant was sent to `/lv-test`, which cannot run in that state |
| LVI-009 | `testing → complete` had to learn to refuse while a `manual-test` gate is open, because the state alone could not say whether a human was still owed |

None of these is a reasoning error. Each one is the registry failing to say what is happening:
"waiting on a human" is a state, and today it is recorded as a file next to one.

## Shape

```
verify ──→ testing ──(no human needed)────────────────────────────→ complete
              │  ↑
              │  └──(human passed; hand back to ship)──┐
              │                                         │
              └──(human-only criteria remain)──→ accept ┤
                                                        └──(human failed)──→ active / draft
```

| Shown as | Stored as | Owner | Mode | Meaning |
|-|-|-|-|-|
| `accept:auto` | `testing` | `/lv-test` | attended or unattended; no human questions in either | The automated half: suite, headless runs, dispositions, the gate verdict, and the ship exit |
| `accept:manual` | `accept` | `/lv-accept` | **attended only** | Every criterion a machine can settle is settled on this build. What is left needs a person. Exists only when the gate verdict says so |

### Naming: one stage, two flavours

Acceptance is one stage of the pipeline, and every surface a person reads shows it that way:
`/lv-tray`, `lv-tray-drill.sh`, `lv-rack`, the coordinator's board, `WORKFLOW.md`, the docs. The
two flavours sit side by side in one column. `accept:manual` is the one that is waiting on you.

**The registry stores two separate state values, never `accept` plus a flavour.** If the flavour
lived in the Tags column, dispatch would have to read two fields. That brings back the
check-then-act race the state exists to remove. Each stored value names exactly one owner.

**The stored values are `testing` and `accept`, not the labels.** There are two reasons:

- `|` cannot appear in a stored value at all. REGISTRY.md is a markdown table, and a pipe in a
  cell splits the row.
- Storing `accept:auto` would rename `testing` in 54 library files and in every client's live
  registry rows and history. The label gives the same clarity without any of that.

The mapping lives in one place, `wf_state_label` in `lv-states.sh`, next to `LV_STATES`.
Display code calls it. **Scripts and skills match only stored values, and match them exactly.**
A grep for `accept` finds the manual flavour alone, while the label `accept` means both. That
asymmetry is the price of not renaming, and it is safe only if no script ever matches on a
label. `tests/` fails on a label string in `scripts/v2.00/`, the same way `tests/id-map.sh`
fails on a literal ID prefix.

The dispatcher never sends a worker to `accept`. `lv-orchestrate.sh`'s state → role `case` maps
it to `blocked-on-human`, the same result an open gate gives today. Here it comes from the
registry row, so closing a gate early can no longer put a worker in a human's container (WFI-070).

## Entering `accept`: only for work no machine can do

`/lv-test` step 6 changes in one place. Where `GATE='true'` opens a `manual-test` gate and exits
with the plan still in `testing`, it now:

1. commits `test-progress.md` (already required: LVI-033),
2. commits `testing → accept` through `lv-registry-update.sh`,
3. opens the `manual-test` gate with the same question as today, plus `BUILD=<sha>`,
4. unclaims.

That order (transition, then gate, then unclaim) is `docs/guard-ordering.md` applied
unchanged.

**`accept` must never absorb the tester's unfinished work.** The transition is allowed only when
`lv-manual-gate.sh` has nothing left that a machine could do:

- `PROGRESS_INCOMPLETE='false'`: every Chrome-Assisted criterion has a result or a recorded
  reason. LVI-040 is the case this blocks: a tester that ran nothing and asked a human
  about everything.
- every remaining reason is human-only: an open `eyes:*` criterion, a disagreement with a prior
  reading, or `needs: oauth|device|extension|profile`.

`lv-registry-update.sh` enforces this, not the prompt. It runs `lv-manual-gate.sh` itself on
`testing → accept` and refuses (exit 4, the same shape as the existing completion guard) when the
record is incomplete. A refused transition keeps the plan in `testing`, so the next sweep
re-dispatches the tester. That is the right outcome, because the missing work is the tester's.

`GATE='false'`, the express lane and every FAIL route exactly as they do now. `accept` is
reached only from `testing` and only on `GATE='true'`.

### The express lane never enters `accept:manual`

The express lane (`lv-lane.sh`, LVI-025; `docs/autonomy.md` → *The express lane*) is how a person
says, at filing, that one small change may run to production with nobody watching. You declare
it by saying "express" to `/lv-bug` or `/lv-brainstorm`, or with `--lane express`. That is the
existing answer to "submit a cosmetic change with an override for testing, acceptance, release
and deploy", and this proposal keeps it as it is. Under the split, the lane works like this:

| Stage | Without the lane | With an express lane that still passes `lv-lane.sh check` |
|-|-|-|
| `spec-approval` | per `specApproval.mode` | answered `express:` |
| `accept:auto` (`testing`) | runs in full | runs in full: suite, headless runs, every FAIL routes as normal |
| `testing → accept` | on `GATE='true'` | **never taken.** `lv-lane.sh answer PLN manual-test` moves the open eyes criteria to `## Post-ship checklist`, and the plan takes the ship exit from `testing` |
| release / deploy | unattended by default | unattended by default |
| `production-push` | grant, policy or a person | covered by `lv-lane.sh push-covered` |

So the `testing → accept` guard in `lv-registry-update.sh` also refuses for a plan whose lane
`status` reads `express`. That guard is what keeps the lane from parking for a human it was
declared to skip. A lane that downgrades (because the plan grew, picked up a disqualifier, or
was amended) is an ordinary plan again and enters `accept:manual` like any other.

The lane never skips `accept:auto`. A cosmetic change still gets its suite and its Playwright
runs. What it skips is the human.

## Invariants of `accept`

1. **Pinned to a build.** The gate's `BUILD=` and `test-progress.md`'s Build column name the
   feature-branch commit the automated half ran on. If `/lv-accept` finds the worktree's HEAD
   anywhere else, it commits `accept → testing` without asking and exits. A person never judges a
   build the automated half did not see.
2. **State ⇔ gate.** A plan is in `accept` exactly when it has an open `manual-test` gate. The
   gate is kept, as decided, because it carries the question text and `/lv-attend`'s
   blocked-closure ordering. **The state is the one dispatch reads; the gate is the one the
   queue reads.** `lv-registry-audit.sh` reports a mismatch in either direction:
   - `accept` with no gate: the queue is missing the plan. The audit offers to reopen the gate
     from `test-progress.md`.
   - an open `manual-test` gate on any other state: this is WFI-082. It is reported, never
     auto-closed.
3. **No code changes in `accept`.** Nothing commits to the feature branch while a plan is in
   `accept`. A fix means a FAIL, and a FAIL means `active`.

## `/lv-accept`, against the prompt contract

| Clause | Content |
|-|-|
| Role | The acceptance tester. Walks a person through the criteria that `/lv-test` proved need human eyes, on the build `/lv-test` tested. Writes no code and runs no suite |
| Done-condition | The plan has left `accept`: `→ testing` on a full pass, `→ active`/`draft` on findings, `→ testing` on a moved build. Its gate is closed and its claim released, in that order |
| Mode | Attended only. Under `LV_UNATTENDED=1` it prints one line and exits 0 without claiming |
| Inputs | `lv-list-acceptable.sh` (new: rows in `accept`), the gate's question and `BUILD=`, `lv-manual-lint.sh <PLN> --live` for numbering, and `test-progress.md` for what is already settled |
| Authority, writes | `test-progress.md` (human results, with attribution), findings in `plan.md`, deferrals through `lv-defer-criterion.sh`, `lv-registry-update.sh` for its three transitions, `lv-gate-close.sh --only manual-test` |
| Authority, reports only | The suite, the headless runs, merges, PRs. Those belong to `/lv-test` |
| Procedure | Claim with `--state accept` → check the build pin → bring up the container on that build → walk only the criteria the gate named (the current steps 5–7 of `/lv-test`, including the `[m]/[a]/[s]` menu) → exit |
| Catch-all | `lv-gate-open.sh <PLN> needs-input`. The plan stays in `accept` |

**Pass exit: hand back, don't ship.** On a full pass, `/lv-accept` commits the human PASSes to
`test-progress.md` and then commits `accept → testing`. The next sweep dispatches `/lv-test`.
That run finds every criterion recorded PASS on this build, gets `GATE='false'`, and takes the
existing ship exit: merge `release` in, `lv-post-merge-check.sh`, PR, `testing → complete`.

Shipping from `/lv-accept` instead would mean copying about 320 lines of `/lv-test`'s
"If all pass" exit into a second skill, or extracting it first. The hand-back costs one more
unattended run, and that run is cheap: the suite comes back `pass (reused …)` from its tree
receipt (LVI-035). It also keeps `testing → complete` as the only path to `complete`, so the
existing completion guard (`lv-registry-update.sh:496`) does not change.

**The hand-back needs no provenance marker** (as built). The worry was that an unattended
`/lv-test` could not tell a PASS a person recorded in `/lv-accept` from an eyes PASS it gave
itself. It does not have to. LVI-033 already counts only *committed* PASS rows unattended, and an
unattended run never commits a PASS on an eyes criterion of its own, so every committed eyes PASS
is a human's. `/lv-accept` commits its rows before it hands back, and writes `human (/lv-accept)`
in their Notes, but only for the record and the commit message; nothing parses it.

**A scope-out must leave nothing to re-gate.** `lv-manual-gate.sh` ignores answered gates, so a
criterion a person waived only in conversation would gate again on the hand-back. `/lv-accept`
files the rest as a bug (`lv-bug-new.sh --source agent:lv-accept`), ticks the criterion in
`plan.md` with `— SCOPED OUT by the operator (filed BUG-NNN)`, and records a SKIP row. `/lv-test`
never reduces scope.

**After a ship-time merge.** If merging `release` into the feature branch moves a
`renderingSurfaces` path, the existing carry rule (LVI-006) stops the human PASS from carrying.
`/lv-test` gets `GATE='true'` again and sends the plan back to `accept`, which is correct. The
gate question already names the path that moved (`SURFACE_MOVED`, LVI-021).

**Fail exit:** unchanged from `/lv-test`'s findings exit (`→ active` with findings, or `→ draft`
when escalated), then close the gate with `--only manual-test`, then unclaim. For now the
section is copied into `/lv-accept`, and later both skills share one extracted script (see
phasing).

## What `/lv-test` loses

Steps 5–7, the interactive criteria walk, move out. `/lv-test` no longer talks to a human in
either mode. An attended `/lv-test` does exactly what an unattended one does, and on
`GATE='true'` it ends with *"PLN-NNN is in `accept`. Run /lv-accept PLN-NNN"*, with no prompt
before it. Auto-test mode (the subagent that writes a real test for a recurring criterion) is
used by both skills. It stays in `/lv-test`, and `/lv-accept` points to it.

## Migration

No registry rewrite. A plan already sitting in `testing` with an open `manual-test` gate is the
old shape of "in `accept`":

- `/lv-accept`'s entry accepts that shape for one major version. It commits `testing → accept`
  first, then proceeds.
- `lv-registry-audit.sh` reports every plan in that shape as `PRE-SPLIT` (and an `accept` row
  with no gate as `UNQUEUED`, a `manual-test` gate on any other state as `STRAY GATE`). It stays
  report-only; the transition is `/lv-accept`'s.
- The dispatcher already parks these plans on the open gate, so nothing changes for them until
  someone acts.

## Touchpoints

| Area | Files |
|-|-|
| State set | `lv-states.sh` (plus `wf_state_label`); its two copies, the `case` in `lv-orchestrate.sh` and `lv-registry-audit.sh` |
| Transitions | `lv-registry-update.sh` (new `testing → accept` guard, `accept → testing`/`active`/`draft`), `lv-guard-write.sh`, `lv-findings-route.sh` |
| Lists | `lv-list-testable.sh` (unchanged: `testing` only), new `lv-list-acceptable.sh`, `lv-list-completable.sh`, `lv-list-gates.sh` (state ⇔ gate check) |
| Claim and recovery | `lv-claim.sh` (`--state accept`), `lv-rehydrate.sh` |
| Surfaces | `lv-tray.sh` (one acceptance row split `auto` / `manual`), `lv-tray-drill.sh`, `lv-rack.sh`. All of them label through `wf_state_label` |
| Parsers | `lv-orch-lib.sh` `wf_test_progress_passes` (provenance), `lv-manual-gate.sh` |
| Skills | new `skills/lv-accept/`; `lv-test` (step 6, steps 5–7 removed, attended ending); `lv-attend` (`manual-test` → `/lv-accept`; the leave-it-open rule stays but is no longer what keeps the daemon off); `lv-tray`, `lv-help` |
| Templates and docs | `templates/WORKFLOW*.md`, `docs/schema.md` (no schema bump — the plan document did not change), `docs/orchestrator.md` (gates table, state map), `docs/guard-ordering.md`, root `CLAUDE.md` pipeline table and terminal roles |
| Tests | below |

## Test plan

1. **Entry guard:** `testing → accept` refused with `PROGRESS_INCOMPLETE='true'`, refused with
   only non-human reasons left, allowed with one open `eyes:blocking`.
2. **Dispatch:** a plan in `accept` with its gate *closed* still gets no worker. This is the
   WFI-070 regression.
3. **Hand-back:** a human PASS recorded by `/lv-accept` and committed is counted by an
   unattended `lv-manual-gate.sh`; an unattended eyes PASS is not. `accept → testing → complete`
   ends in one sweep without returning to `accept`.
4. **Build pin:** moving the feature HEAD after entering `accept` sends the plan to `testing`.
5. **Audit:** both mismatch directions are reported, and the legacy `testing` + gate shape is
   listed.
6. **Ship-time re-gate:** a `release` merge that touches a rendering surface sends the plan back
   to `accept`, and the question names the path.
7. **Existing suites** for the manual gate, guard ordering and completion all pass unchanged.

## Phasing

1. **State and guards:** `lv-states.sh`, `lv-registry-update.sh`, the dispatcher `case`,
   provenance in `wf_test_progress_passes`, the audit, plus tests 1–5. Nothing enters `accept`
   yet.
2. **Skills:** `/lv-accept`; `/lv-test` step 6 switched over and steps 5–7 removed; `/lv-attend`,
   tray, templates and docs. This ships as the major release.
3. **Later, optional:** extract the findings exit, and possibly the ship exit, into scripts that
   both skills call, so the copy made in phase 2 goes away.

## Open questions

- ~~Provenance format~~ — not needed; see the hand-back above.
- ~~Model~~ — `/lv-accept` runs on Sonnet.
- ~~Coordinator view~~ — `lv-rack` reads the new `accept=` key from `lv-tray.sh --fields` (an
  older client emits none, and 0 stands) and labels the rows `acc:auto` / `acc:man`, because its
  label column is nine wide.
- **A full rename, later?** If the labels prove their worth, storing `accept:auto` /
  `accept:manual` (with `:`, never `|`) would close the label-versus-value gap. It would be a
  separate major release with a registry migration that asks the operator before it rewrites
  rows. This proposal does not depend on it.
