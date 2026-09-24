# Standing authorization

**Status:** `release` and `deploy` are **unattended by default** since coordinator WFI-006.
Absent config means `mode: attended`, which now stops only `production-push` for a human.
A project that wants the release or deploy gate back lists it under `attended_for`.

Answers client-a's WFI-159: a person granted standing merge/deploy authorization in
conversation, asked where to record it, and there was nowhere. The authorization survived
only as an instruction to whichever agent heard it and died at the next session boundary.

---

## The one rule

`lv-autonomy.sh` **answers a question. It never performs an action.**

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

## Unattended by default: release and deploy

`release` (develop → release, plus the E2E suite) and `deploy` (release → main, **locally**)
need no grant. `lv-autonomy.sh` answers 0 for them with no config, logs an `autonomy-use`
line that says *authorized by default*, and counts them against their own ceiling.

Why: neither leaves the machine. A wrong local `main` is undone with `git reset`, and a red
suite routes back to the builder as it always did. The pipeline stops for a person only
where security or an irreversible external act needs one, and since the permission
baseline (below, coordinator WFI-005) the security lives in code, not in a pause. The approval
gates in front of these two were answered "approve" every time they were asked.
`production-push` is the step that reaches users, so it keeps its gate.

```yaml
orchestrator:
  autonomy:
    # Taking a gate back. Say why in the comment — an unexplained attended_for
    # is a pause nobody can later judge the need for.
    attended_for:
      - release     # e.g. the E2E suite is shared and slow; batch releases by hand
    max_unattended_per_day: 12   # per action, default 12
```

- `attended_for` accepts only `release` and `deploy`; anything else is reported by
  `--show` as changing nothing.
- `max_unattended_per_day` bounds the default the way `max_per_day` bounds a grant: a role
  dispatching in a loop is still stopped, per action, per UTC day.
- A standing grant still works as before for anything listed under `attended_for`, and is
  still the only *standing* route to `production-push`. Without one, an unattended deploy
  that finishes the promotion opens a `production-push` gate naming `main`'s tip; approving
  it at `/lv-attend` (`--decision approve`) lets the next dispatch push exactly that commit
  (coordinator WFI-008). Before that gate existed, the finished deploy was re-dispatched until it
  parked as `stuck`.

## What may be granted

Only promotions that have **no other config surface** — three of them, in pipeline order.
Each moves work that already passed its gates; none is a judgment about whether the work
is good.

| Action | Authorizes | Consumer |
|-|-|-|
| `release` | `develop` → `release` and the E2E suite | `/lv-release` step 4 |
| `deploy` | `release` → `main`, **locally** | `/lv-deploy` step 4 |
| `production-push` | `git push origin main` | `/lv-deploy` step 14 — ungranted, an unattended run opens a `production-push` gate the operator accepts at `/lv-attend` |

`deploy` and `production-push` are deliberately two grants. A wrong `main` that never left
the machine is fixed with `git reset`; a pushed one is already running for users.

### Not grantable, and why

| Name | Reason | Use instead |
|-|-|-|
| `merge` | **Already unattended.** `/lv-test`'s exit path runs `git push -u`, `gh pr create` and `gh pr merge --merge` with no human, and routes a failure back to the builder itself. A `merge` key would change nothing. | — |
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
scripts/lv-exec.sh lv-autonomy.sh --show   # 0 coherent, 2 has problems
scripts/lv-exec.sh lv-autonomy.sh --list   # the closed vocabulary
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

Read it with `lv-event.sh --for <ID>`, or `lv-tray.sh`.

### 2. The gate file — when authorization is refused

A refused promotion parks like any other decision, at
`.claude/orchestrator/gates/<ID>.gate`:

```
GATE_NAME='release-approval'
GATE_QUESTION='<the commit list, verbatim>'
GATE_SKILL='lv-release'
```

`/lv-attend` grows a row for `release-approval` and `deploy-approval`, and — this is the
loop closure — if the human answers *"stop asking, you're authorized"*, the skill's
instruction is to **write the grant into `claude-workflow.yml`** rather than accept it as
conversation.

### 3. `lv-orchestrate.sh --json` — the posture, on every run

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
'force-push' is never grantable through autonomy — see lv-autonomy.sh --list
```

Suppress with `--quiet` when a caller wants the exit code alone.

---

## The other way a promotion gets authorized: the answer at the gate

A standing grant is policy written in advance. It is not the only authorization that exists,
and for a long time it was the only one the harness could *read* — which is client-b WFI-005.
A human answered `release-approval` at `/lv-attend` with an approval; the daemon dispatched
`/lv-release` a minute later; that run asked `lv-autonomy.sh`, which knows nothing about gate
answers, was told no, and re-opened the gate it had just been let through. Twice, each
re-opening quoting a longer commit list so gate dedup saw a fresh question every time. The
approval was in the ledger and nothing between it and the merge could act on it.

So a promotion gate's answer is now recorded as a **value**, not as prose:

```bash
scripts/lv-exec.sh lv-gate-close.sh RELEASE "approved — ship it" --decision approve
scripts/lv-exec.sh lv-promote-approval.sh release   # 0 authorized · 1 no answer · 2 answer aged out
```

Three properties make this a one-off approval rather than a grant by the back door:

- **It is scoped to a commit set.** `lv-gate-open.sh` records the source branch's tip when the
  question is asked, `lv-gate-close.sh` carries it into the record, and
  `lv-promote-approval.sh` refuses (exit 2) once the branch has moved. A human approves *these
  commits*, exactly as a spec approval covers *that revision* of the plan.
- **It is spent by the promotion it authorizes.** Once the merge lands there is nothing left in
  the range, so the next dispatch has nothing to promote; once new work lands the tip has moved
  and the question is genuinely new.
- **It fails closed.** No `--decision`, a rejection, or a record from before this existed all
  read as "not authorized", and the gate re-opens exactly as it did before.

`lv-autonomy.sh` is unchanged by this: it still answers only about standing grants, and it is
still what `--show` reports. Both the dispatcher's pre-flight and the `/lv-release` and
`/lv-deploy` skills ask for the one-off approval **first**, and fall through to the grant.

### A third promotion gate, with no grant behind it

`/lv-deploy` step 4a asks a second question about the same batch — "these plans shipped with
`external`/`soak`/`unbuilt` criteria still open; promote anyway?" — at
`deploy-deferred-criteria`, read back with `lv-promote-approval.sh deferred`. It is
commit-set-scoped exactly like the two above, and for the same reason: client-a WFI-260 had
this gate open quoting 91 commits when a `/lv-release` two minutes later put 118 in the batch,
carrying two plans whose deferred criteria the question never showed.

It is the one promotion gate with **no** fall-through to a grant. `lv-gate-close.sh` refuses
`--basis autonomy` on it and the skill never asks `lv-autonomy.sh` there, because a standing
`deploy` grant is policy written before these criteria existed — and client-c's DC-014 was
the kind that crash-loops production when it goes unread (WFI-011). A human answers it or
nothing does.

Until it existed the step had no answer path at all: every unattended dispatch re-ran the
check, got the same exit 1, and re-opened a gate a human had already answered — WFI-005's loop
in a second place.

### The tip an approval is scoped to has to be a tip that exists

Commit-set scoping only works if the tip stamped on the gate is the tip the promotion will
actually read. `wf_promote_tip` resolves `refs/remotes/origin/<ref>`, and a remote-tracking ref
only moves on a fetch — so a gate could be opened against a tip this checkout had simply not
heard about, and the human's answer was then discarded by the first worker that did fetch.

client-a WFI-264: the gate opened at 17:46 carrying an `origin/release` four hours and 69
commits stale, because `/lv-test` had merged a PR into release through GitHub. A human approved
it at 21:50. `/lv-deploy`'s step 2a fetched, `lv-promote-approval.sh` saw the mismatch, exited 2,
and the identical question re-opened 41 seconds later — indistinguishable, from where the human
sat, from the by-design "the batch changed" case above. They answered it twice.

Two changes, either of which would have caught it:

- **`wf_promote_fetch` on the open path.** `lv-gate-open.sh` refreshes the ref before stamping,
  so the question is asked about what is there. Best-effort: offline, the cached ref is still
  better than refusing to open a gate.
- **A close-time re-check.** `lv-gate-close.sh` refuses (**exit 5**) an `--decision approve`
  whose gate was opened against a tip the ref has since moved past, leaving the gate open and
  saying so — to the person standing there, who can still re-derive the batch — instead of
  writing an approval that is already dead. `--batch-moved-ok` records it against the current
  tip, for a caller (`/lv-attend`) that has re-derived the batch and is answering about *that*.

The batch a human is shown must also be counted against `origin/main`, not local `main`:
`lv-release-sync.sh` now fetches it and prints `DEPLOY_BASE=`. Local `main` legitimately holds
commits production does not between `/lv-deploy`'s merge and its push, and an unrecovered one of
those is what made the same gate quote "205 commits" for a batch of 353.

---

## Permission baseline: what an unattended worker may never do

Standing grants decide when the pipeline may act **without asking**. The baseline decides
what an unattended worker may **never** do, asked or not. It exists because every worker
runs `claude -p --dangerously-skip-permissions` (`lv-spawn.sh`), and until it shipped no
client had a single deny rule (coordinator WFI-005). The pipeline is meant to stop for a person
only when security needs one, so security lives here, in code, and not in pauses.

Two layers, both installed into every client's `.claude/settings.json` by
`templates/hooks/settings-merge.py`:

| Layer | Applies to | Refuses |
|-|-|-|
| `permissions.deny` | every session, attended or not | reading `~/.ssh`, cloud and CLI credential files, and every secret path your packs name |
| `lv-guard-baseline.sh` (PreToolUse, every tool) | unattended workers only (`LV_UNATTENDED=1`) | the rules below |

| Rule id | Refuses |
|-|-|
| `secret-read` | `.env` files (not `.example`/`.sample`/`.template`/`.dist`), private keys and certificates, credential stores, and every path the `secrets-deny-patterns` hook names, by any tool |
| `provider-secrets` | `gh secret set/delete`, plus your provider's secret-setting commands from the `provider-deny` hook; secrets are deployed through the `secrets-deploy` hook |
| `provider-shell` | your provider's shell into a running app (`provider-deny` hook) |
| `provider-destroy` | deleting, archiving, renaming or re-publishing a GitHub repo; `gh api` DELETE; plus your provider's app, volume and storage destruction (`provider-deny` hook) |
| *(a pack's own)* | anything else a pack names, such as a secrets tool's print-a-value command |
| `force-push` | `git push` with `--force`, `-f`, `--force-with-lease`, `--mirror`, `--delete`, `--prune`, a `+refspec` or a `:branch` |
| `history-rewrite` | `git filter-repo`, `git filter-branch` |
| `rm-outside` | `rm -r` on anything outside the worktree and the temp dirs, or on a path it cannot check (`$VAR`) |
| `pipe-to-shell` | `curl`/`wget` piped into a shell or interpreter |

**Your own secret stores and provider.** The library names only generic ones and GitHub. Yours
come from two add-deny hooks, `secrets-deny-patterns` and `provider-deny`, usually implemented by
a private pack ([extension-hooks.md](extension-hooks.md)). `secret-read` refuses workers anything
under a path they name, the next deploy adds matching `Read` deny rules for every session, and
their command rules refuse like the built-in ones and are lifted by the same ids. A hook can only
add rules. A listed pack that has gone, or a hook that fails, makes the guard refuse every worker
call, so a moved pack cannot silently take its guards with it.

**Fail closed, for workers only.** A worker's guard that crashes, times out, cannot parse its
payload or is not on disk refuses. The hook command's wrapper turns any non-zero exit into
2 when `LV_UNATTENDED=1`. `lv-guard-promote.sh` now runs under the same wrapper. An
interactive session is never blocked by a broken guard: its own permission prompts still
stand, and a bricked editor is worse than the prompt.

**Proven, not assumed.** On Claude Code 2.1.280, under `--dangerously-skip-permissions`, both a
PreToolUse exit 2 and a `permissions.deny` rule refuse the call, and a Read deny also
refuses a Bash `cat`/`head` of the same file. `tests/permission-baseline.sh` covers every
rule; `LV_LIVE_CLAUDE=1 tests/permission-baseline.sh` starts a real skip-permissions worker
in a fixture client and checks it is refused `.env`. Re-run the live check after a Claude
Code upgrade.

**Lifting a rule** is the client's call, in its own `claude-workflow.yml`, and only with all
four keys. A partial block lifts nothing, and the refusal says so:

```yaml
permissionBaseline:
  allow:
    - provider-shell
  reason: "deploy smoke test needs a shell on staging"
  set_by: "A. Operator"
  set_on: 2026-09-23
```

**What it is not.** A text match stops a mistaken or misled agent, not a hostile one: a
command assembled at run time (`eval`, base64, variables) can get past it. The deny rules and
each provider's own credential scoping are the deeper layers.

## What this does *not* do

- **The daemon does not decide policy — it only dispatches.** `lv-orchestrate.sh`'s sweep
  includes `release`/`deploy` in `SWEEP_ROLES` and spawns a `LV_UNATTENDED=1` worker for
  either when `lv-list-release.sh`/`lv-list-deploy.sh` says one is eligible **and** the action
  is authorized — by a standing grant, or by the answer at the gate (above) — see
  [`orchestrator.md`](orchestrator.md). Whether that
  worker actually promotes anything is still decided entirely inside the
  `/lv-release`/`/lv-deploy` **skills**, which ask again for real: the dispatch alone
  authorizes nothing, and a grant that lapses between the two is caught by the skill.

  The dispatcher's pre-flight asks `lv-promote-approval.sh <action>` first and
  `lv-autonomy.sh <action> --check` second, and it exists because
  spawning a worker that can only refuse is not free. It burns a worker, an hourly spawn
  slot and an attempt, and reopens a gate a human has often just answered; worse, a refused
  worker is structurally the one most likely to promote anyway — WFI-004, WFI-005, WFI-007,
  WFI-032 and WFI-034 are five incidents and five refused workers. `lv-guard-promote.sh`
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
