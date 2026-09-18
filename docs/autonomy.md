# Standing authorization

**Status:** ships **off**. Absent config means `mode: attended`, which is exactly the
behaviour every client had before this existed. Nothing changes on deploy until a project
writes a grant.

Answers client-a's WFI-159: a person granted standing merge/deploy authorization in
conversation, asked where to record it, and there was nowhere. The authorization survived
only as an instruction to whichever agent heard it and died at the next session boundary.

---

## The one rule

`wf-autonomy.sh` **answers a question. It never performs an action.**

It reads `claude-workflow.yml`, checks the grant, writes one line to the event log, and
exits. Whether anything then happens is entirely the caller's business. That separation is
what makes the grant auditable: the record of *what was authorized* is independent of the
record of *what was done*.

```
0  authorized      the caller may proceed unattended
1  not authorized  the caller parks a gate and stops   (reason on stderr)
2  malformed       the grant is broken — also stop, and say why
```

`--check` gives the same three answers and records none of them. A recorded question costs
a slot against the very ceiling it is asking about, so a caller that wants to know *before*
committing to the work — the dispatcher, deciding whether to spawn a release/deploy worker
at all — must ask this way, or its probe eats the budget the worker then needs and stamps
the log with a decision no skill ever acted on.

**Exit 2 is never "proceed".** A grant nobody can parse authorized nothing.

---

## What may be granted

Only promotions that have **no other config surface** — three of them, in pipeline order.
Each moves work that already passed its gates; none is a judgment about whether the work
is good.

| Action | Authorizes | Consumer |
|-|-|-|
| `release` | `develop` → `release` and the E2E suite | `/wf-release` step 4 |
| `deploy` | `release` → `main`, **locally** | `/wf-deploy` step 4 |
| `production-push` | `git push origin main` | `/wf-deploy` step 13 |

`deploy` and `production-push` are deliberately two grants. A wrong `main` that never left
the machine is fixed with `git reset`; a pushed one is already running for users.

### Not grantable, and why

| Name | Reason | Use instead |
|-|-|-|
| `merge` | **Already unattended.** `/wf-test`'s exit path runs `git push -u`, `gh pr create` and `gh pr merge --merge` with no human, and routes a failure back to the builder itself. A `merge` key would change nothing. | — |
| `spec-approval` | Has a surface, with rounds and tag escapes | `specApproval.mode: verdict` |
| `manual-test` | Has a surface, keyed on the rendering surface the diff touches | `manualTestGate` |
| `force-push`, `history-rewrite`, `claim-steal` | Not promotions. WFI-159's own framing: someone authorizing merges and deployments almost certainly does not mean these. | — |

WFI-159 lists merges among the blocked decisions. That part of the report is wrong, and
saying so is the substance of the fix — shipping a `merge` key would have been precisely
the defect the report warns against: *"an unread key … would look load-bearing and be
honoured by no script."*

---

## The config

```yaml
orchestrator:
  autonomy:
    # Granted 2026-08-16 for the tb deadline: releases run overnight while the
    # remote operator is asleep. Deploys and the production push are NOT covered —
    # those wait for a person, deliberately.
    mode: standing            # attended | standing   (default: attended)
    granted_by: "Marc Blais"
    granted_on: 2026-08-16
    expires_on: 2026-09-16
    max_per_day: 4
    standing_for:
      - release
```

While `mode: standing`, all of `granted_by`, `granted_on`, `expires_on` and a non-empty
`standing_for` are **required**. A missing one is exit 2, not a default.

`expires_on` is mandatory on purpose. An authorization with no end date is a permission,
and this is not a permissions system — it is a record of something a person said on a
particular day, and it should stop being true.

`max_per_day` (default 4) is counted from the event log **per action, per day** — four
releases, four deploys and four production pushes, not four in total. It bounds the blast
radius of a bad grant: a pipeline that has gone wrong otherwise spends the grant on forty
artifacts before anyone looks at the board.

**It used to be one counter shared across all three actions, and that was a defect.**
Shipping one batch costs three actions — `release`, then `deploy`, then `production-push` —
so a shared ceiling of 4 was smaller than a single day's work. A project with a full standing
grant got one shipment per day and then jammed, every promotion after it parking a gate for a
human. client-c on 2026-09-15 is the whole failure in one log: four `autonomy-use` lines
ending at 13:37 — one complete shipment plus one release — then twelve consecutive
`daily ceiling 4 reached` refusals through 16:56. Each of those parked a gate, and a refused
worker is structurally the one most likely to promote anyway (WFI-004, WFI-005, WFI-007,
WFI-032 and WFI-034 were every one of them a refused worker). client-d hit the same wall and
was worked around by raising `max_per_day` to 20 by hand mid-day — the tell that the knob was
measuring the wrong thing.

Per action, the runaway case the ceiling exists for is still caught: a role dispatching in a
loop burns only its own budget, and burning it no longer disarms the other two.

Audit it before trusting it:

```bash
scripts/wf-exec.sh wf-autonomy.sh --show   # 0 coherent, 2 has problems
scripts/wf-exec.sh wf-autonomy.sh --list   # the closed vocabulary
```

`--show` **names** every `standing_for` entry that nothing reads, and exits non-zero. A
grant that does not do what its author thinks it does is a defect, not a preference.

---

## Messaging: what crosses the wire, and when

Four channels. Nothing else is written.

### 1. `events.log` — one tab-separated line per question asked

`<utc>` `<type>` `<artifact>` `<message>`, appended to
`.claude/orchestrator/events.log`. Both outcomes are recorded; a refusal is as much a fact
as an approval.

```
2026-08-16T17:13:32Z  autonomy-use      PLN-103  release authorized by standing grant from Marc Blais (2026-08-16, expires 2026-09-16) — 1/4 release today
2026-08-16T17:13:32Z  autonomy-refuse   —        deploy: not in standing_for
2026-08-16T17:14:01Z  autonomy-refuse   PLN-104  release: daily release ceiling 4 reached
```

The message carries the grant's **identity** — who, when, expiry, and the running count —
so reconstructing "who authorized this and under what" needs only this file, not the
config as it happens to read today.

Read it with `wf-event.sh --for <ID>`, or `wf-board.sh`.

### 2. The gate file — when authorization is refused

A refused promotion parks like any other decision, at
`.claude/orchestrator/gates/<ID>.gate`:

```
GATE_NAME='release-approval'
GATE_QUESTION='<the commit list, verbatim>'
GATE_SKILL='wf-release'
```

`/wf-attend` grows a row for `release-approval` and `deploy-approval`, and — this is the
loop closure — if the human answers *"stop asking, you're authorized"*, the skill's
instruction is to **write the grant into `claude-workflow.yml`** rather than accept it as
conversation.

### 3. `wf-orchestrate.sh --json` — the posture, on every run

```json
{
  "artifact": "BUG-094",
  "plan": "PLN-094",
  "state": "testing",
  "result": "blocked-on-human",
  "gate": { "name": "manual-test", "question": "…", "context": "…" },
  "autonomy": { "mode": "standing", "covers": "release", "expires": "2026-09-16" },
  "steps": ["test:rc=0"]
}
```

An external driver reading exit `20` otherwise knows only *"a human owns this"*. It cannot
tell "nobody authorized anything here" from "the promotions after `complete` are
authorized until the 16th" — and those call for opposite behaviour. The field reports the
ceiling; **it does not move it.** Exit 20 remains a hard stop.

### 4. `stderr` — the human-readable reason

Always a full sentence naming the grant and what to do:

```
the standing grant covers 'release' — not deploy. Park a gate and stop.
the standing grant expired on 2026-09-16 (today is 2026-10-01). Ask for a fresh one.
'force-push' is never grantable through autonomy — see wf-autonomy.sh --list
```

Suppress with `--quiet` when a caller wants the exit code alone.

---

## The other way a promotion gets authorized: the answer at the gate

A standing grant is policy written in advance. It is not the only authorization that exists,
and for a long time it was the only one the harness could *read* — which is client-b WFI-005.
A human answered `release-approval` at `/wf-attend` with an approval; the daemon dispatched
`/wf-release` a minute later; that run asked `wf-autonomy.sh`, which knows nothing about gate
answers, was told no, and re-opened the gate it had just been let through. Twice, each
re-opening quoting a longer commit list so gate dedup saw a fresh question every time. The
approval was in the ledger and nothing between it and the merge could act on it.

So a promotion gate's answer is now recorded as a **value**, not as prose:

```bash
scripts/wf-exec.sh wf-gate-close.sh RELEASE "approved — ship it" --decision approve
scripts/wf-exec.sh wf-promote-approval.sh release   # 0 authorized · 1 no answer · 2 answer aged out
```

Three properties make this a one-off approval rather than a grant by the back door:

- **It is scoped to a commit set.** `wf-gate-open.sh` records the source branch's tip when the
  question is asked, `wf-gate-close.sh` carries it into the record, and
  `wf-promote-approval.sh` refuses (exit 2) once the branch has moved. A human approves *these
  commits*, exactly as a spec approval covers *that revision* of the plan.
- **It is spent by the promotion it authorizes.** Once the merge lands there is nothing left in
  the range, so the next dispatch has nothing to promote; once new work lands the tip has moved
  and the question is genuinely new.
- **It fails closed.** No `--decision`, a rejection, or a record from before this existed all
  read as "not authorized", and the gate re-opens exactly as it did before.

`wf-autonomy.sh` is unchanged by this: it still answers only about standing grants, and it is
still what `--show` reports. Both the dispatcher's pre-flight and the `/wf-release` and
`/wf-deploy` skills ask for the one-off approval **first**, and fall through to the grant.

### A third promotion gate, with no grant behind it

`/wf-deploy` step 4a asks a second question about the same batch — "these plans shipped with
`external`/`soak`/`unbuilt` criteria still open; promote anyway?" — at
`deploy-deferred-criteria`, read back with `wf-promote-approval.sh deferred`. It is
commit-set-scoped exactly like the two above, and for the same reason: client-a WFI-260 had
this gate open quoting 91 commits when a `/wf-release` two minutes later put 118 in the batch,
carrying two plans whose deferred criteria the question never showed.

It is the one promotion gate with **no** fall-through to a grant. `wf-gate-close.sh` refuses
`--basis autonomy` on it and the skill never asks `wf-autonomy.sh` there, because a standing
`deploy` grant is policy written before these criteria existed — and client-c's DC-014 was
the kind that crash-loops production when it goes unread (WFI-011). A human answers it or
nothing does.

Until it existed the step had no answer path at all: every unattended dispatch re-ran the
check, got the same exit 1, and re-opened a gate a human had already answered — WFI-005's loop
in a second place.

---

## What this does *not* do

- **The daemon does not decide policy — it only dispatches.** `wf-orchestrate.sh`'s sweep
  includes `release`/`deploy` in `SWEEP_ROLES` and spawns a `WF_UNATTENDED=1` worker for
  either when `wf-list-release.sh`/`wf-list-deploy.sh` says one is eligible **and** the action
  is authorized — by a standing grant, or by the answer at the gate (above) — see
  [`orchestrator.md`](orchestrator.md). Whether that
  worker actually promotes anything is still decided entirely inside the
  `/wf-release`/`/wf-deploy` **skills**, which ask again for real: the dispatch alone
  authorizes nothing, and a grant that lapses between the two is caught by the skill.

  The dispatcher's pre-flight asks `wf-promote-approval.sh <action>` first and
  `wf-autonomy.sh <action> --check` second, and it exists because
  spawning a worker that can only refuse is not free. It burns a worker, an hourly spawn
  slot and an attempt, and reopens a gate a human has often just answered; worse, a refused
  worker is structurally the one most likely to promote anyway — WFI-004, WFI-005, WFI-007,
  WFI-032 and WFI-034 are five incidents and five refused workers. `wf-guard-promote.sh`
  contains that class mechanically; not launching the worker removes the occasion for it.
  The skip is latched, so a sweep says *why* once rather than once a minute forever.
- **It does not answer judgment gates.** `spec-approval`, `manual-test`, `needs-input`,
  `scope-reduction`, `stuck` are untouched and still exit 20.
- **It grants nothing retroactively.** A grant written today does not legitimise a
  promotion that already happened.

---

## Failure modes it is built against

| Failure | Guard |
|-|-|
| A key that looks load-bearing and is read by nothing | Closed vocabulary; `--show` names unread entries and exits 2 |
| A grant outliving the situation that justified it | `expires_on` required; expiry checked per call |
| "I authorize deploys" silently covering the production push | Separate action, separate grant |
| A broken pipeline spending a grant across the whole board | `max_per_day`, counted from the event log, per action |
| One runaway role disarming the other two promotions | The ceiling is per action, so a loop burns only its own budget |
| A malformed grant read as permission | Malformed is exit 2, and every consumer treats 2 as stop |
| A typo answered as a deliberate refusal | An unknown action is exit 2, never exit 1 |
| Nobody able to reconstruct who authorized what | Grant identity in every `autonomy-use` line |
