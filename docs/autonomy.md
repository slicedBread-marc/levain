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

`max_per_day` (default 4) is counted from the event log across every action. It bounds the
blast radius of a bad grant: a pipeline that has gone wrong otherwise spends the grant on
forty artifacts before anyone looks at the board.

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
2026-08-16T17:13:32Z  autonomy-use      PLN-103  release authorized by standing grant from Marc Blais (2026-08-16, expires 2026-09-16) — 1/4 today
2026-08-16T17:13:32Z  autonomy-refuse   —        deploy: not in standing_for
2026-08-16T17:14:01Z  autonomy-refuse   PLN-104  release: daily ceiling 4 reached
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

## What this does *not* do

- **The daemon does not decide policy — it only dispatches.** `wf-orchestrate.sh`'s sweep
  includes `release`/`deploy` in `SWEEP_ROLES` and will spawn a `WF_UNATTENDED=1` worker
  for either the moment `wf-list-release.sh`/`wf-list-deploy.sh` says one is eligible — see
  [`orchestrator.md`](orchestrator.md). Whether that worker actually promotes anything is
  still decided entirely inside the `/wf-release`/`/wf-deploy` **skills**, by consulting a
  standing grant exactly as described above: no grant, or one that doesn't cover the
  action, opens a `release-approval`/`deploy-approval` gate and exits — the dispatch alone
  authorizes nothing.
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
| A broken pipeline spending a grant across the whole board | `max_per_day`, counted from the event log |
| A malformed grant read as permission | Malformed is exit 2, and every consumer treats 2 as stop |
| A typo answered as a deliberate refusal | An unknown action is exit 2, never exit 1 |
| Nobody able to reconstruct who authorized what | Grant identity in every `autonomy-use` line |
