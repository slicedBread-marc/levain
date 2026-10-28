# Project profile

**Status:** ships with no default tier. `lv-profile.sh --show` refuses until one
is declared.

Answers a pattern that showed up tuning five clients by hand in one session:
`specApproval.mode`, `manualTestGate`, and `orchestrator.autonomy` each get
decided project-by-project, from scratch, in conversation — and the reasoning
("this one has no real users yet") lives only in that conversation and evaporates
at the next session boundary, same shape as the gap `lv-autonomy.sh` closed for
standing release/deploy authorization.

---

## The one rule

`projectProfile` is a **recorded stance, not a runtime switch** — with two
exceptions, below. Nothing else in the pipeline reads `projectProfile.tier` to
change gate behavior — every other gate still runs on `specApproval.mode`,
`manualTestGate`, and `orchestrator.autonomy` exactly as it always has, read
directly, with their own explicit values.

**The exception (LVI-036): a pre-launch project pushes to production
unattended until it goes live.** `lv-autonomy.sh production-push` answers 0
by default while `tier: pre-launch` and `live_from` is unset or still in the
future, bounded by `max_unattended_per_day` like the release and deploy
defaults. From `live_from` on, the project behaves as governed: the push needs
a standing grant, the express lane, or a person at the `production-push` gate.
See [Going live](#going-live-live_from) for why this reverses the original
design.

**The second exception (a client's LVI-034): a pre-launch project does not stop
for questions.** While `wf_prelaunch` holds:

- `needs-input`, `spec-approval`, `scope-reduction` and `prior-work` are
  answered by the worker's own recommendation (`lv-gate-open.sh --recommend`),
  closed with `--basis pre-launch`, which `lv-gate-close.sh` verifies. A worker
  passes `--floor "<why>"` when a human must decide anyway: money, secrets,
  destroyed data, real people. More than `selfAnswerMaxPerDay` (default 3) on
  one artifact and gate in a day parks for a human, because that is a loop.
- `manual-test` does not gate: `lv-manual-gate.sh` answers `GATE=false` with
  `PRELAUNCH=true`, and `/lv-test` moves the open eyes criteria to the plan's
  post-ship checklist (`lv-lane.sh answer <PLN> manual-test`).
- Neither is dropped. `lv-end-state.sh` lists every self-answered decision and
  every unticked post-ship item, for a human to check **against the end state**
  — at the goal's milestone, and before `live_from` is set.

Circuit breakers (`stuck`, `spec-stuck`) and promotion gates are unchanged.
`governed` behaves exactly as before. The operator's reason, 2026-10-27: work
under development should reach its end state as fast as possible, and a
recommended answer is acceptable far more often than a parked question is
worth; only a live project keeps per-plan gates.

```yaml
projectProfile:
  tier: pre-launch
  selfAnswerMaxPerDay: 3      # optional
```

What the tier gives you is:

1. **A place to write down *why* a project is configured the way it is**, so
   the next session (human or agent) doesn't have to re-derive it from five
   scattered yaml values.
2. **A recommendation table** for what those values should be at each tier.
3. **A drift check** (`lv-profile.sh --check`) that flags when the actual
   values no longer match what the declared tier recommends — because someone
   tightened one knob without updating the others, or the project's real-world
   stakes changed and the config didn't follow.

It does **not** write `levain.yml` for you. Applying a tier is a
deliberate edit — ask Claude to "apply the `governed` profile" and it edits
`specApproval.mode` etc. by hand, the same way a human would, preserving the
rationale comments already there. A script that silently rewrote those blocks
would orphan exactly the kind of hand-written "why" comment every other gate in
this project carries, and a stale rationale sitting next to a value it no
longer explains is worse than no rationale at all.

---

## The two tiers

| Tier | Meaning | `specApproval.mode` | `manualTestGate.blockOnCosmetic` | `orchestrator.autonomy` |
|-|-|-|-|-|
| `pre-launch` | No real users yet, or negligible ones. A bad unattended call costs a redeploy or a rollback, not an incident. | `verdict` | `false` | none needed — `production-push` is unattended by default until `live_from` |
| `governed` | Real users depend on this. A bad unattended call is user-visible. | `gate` | `true` | scoped to `release`/`deploy` at most — `production-push` stays attended |

Two tiers, not a spectrum — the same reasoning `specApproval.mode` itself
uses: a third "mostly launched" tier would be a judgment call wearing a config
key's clothes. If a project sits ambiguously between them, that ambiguity is
itself the signal to pick `governed` and loosen specific knobs deliberately,
rather than inventing a tier that quietly means "governed, except when it's
inconvenient."

## The config

```yaml
projectProfile:
  tier: pre-launch
  reason: "No real users yet except client-j.example, which stays governed."
  set_by: "Marc Blais"
  set_on: 2026-09-10
  live_from: null          # YYYY-MM-DD the day real users arrive; null while there are none
```

`reason` is required in spirit, not enforced in code — `lv-profile.sh --show`
prints `(none recorded)` rather than refusing, because a missing reason is a
smaller problem than a missing tier and shouldn't block reading what tier is
declared. But a tier with no reason is a decision nobody can re-derive later,
so write one.

No `expires_on` on the tier itself. That's a deliberate difference from `orchestrator.autonomy`:
an autonomy grant authorizes a specific unattended *action* and is inherently
time-boxed by design — "a record of something a person said on a particular
day" that "should stop being true." A profile tier describes a project's
*current real-world stakes*, which stay true until the facts change, and the
facts — real users start depending on the thing — are what should trigger you
back here, not a calendar date. An expiring tier would either lapse on
schedule back to some default (which default, and is that actually safer?) or
get rubber-stamp-renewed the way a genuinely load-bearing date shouldn't be.

## Going live: `live_from`

`live_from` is not an expiry. It is the go-live fact, written down — the date
real users start depending on the project — and it is the only date the
profile carries.

**Why this reverses the original design.** This page used to argue that the
tier should gate nothing and carry no date, and that a pre-launch project
wanting unattended pushes should hold a standing grant. In practice that put
the date back in, in the wrong place: a grant *must* expire, so a pre-launch
project's pushes depended on a calendar date unrelated to whether users had
arrived. One client's grant lapsed on 2026-10-01 while its stated reason (no
users, nothing wired to main) was still true, and its pushes started parking on
`production-push` gates. Meanwhile the one portfolio site with real users was
declared pre-launch with a grant to December — the live site was the one
shipping to users unattended. The date that matters is go-live, so that is the
date that now gates.

The rules:

- **`null` or absent** — no real users. A `pre-launch` project pushes unattended.
- **A future date** — a go-live announced in advance. Pushes stay unattended
  until that day, then stop on their own.
- **Today or past** — live. `production-push` is attended whatever the tier
  says, and `lv-profile.sh --check` reports a `pre-launch` tier with a past
  `live_from` as drift: set `tier: governed` and apply its knobs.
- **Not a date** — malformed. `lv-autonomy.sh` refuses every action (exit 2)
  until it is fixed.

**Setting it only tightens, so an agent may set it** — `/lv-spec` writing a
go-live-prep plan, say, or any session that learns real users have arrived.
**Clearing it, or moving it later, loosens, and needs a human**, recorded with
`set_by` / `set_on` and a line in `reason`. Nothing enforces that in code; it
is the same kind of rule as applying a tier by hand.

`production-push` listed under `orchestrator.autonomy.attended_for` opts a
pre-launch project out of the default. It stays coherent after go-live, so
going live never turns a project's config malformed.

Irreversible external acts — creating buckets, setting secrets, data
migrations — stay behind their own controls regardless of tier. The default
covers pushing `main`, nothing else.

**The cost.** A live project still reading `pre-launch` with no `live_from`
now ships to users unattended. That was already true of a pre-launch project
holding a standing grant, and the express lane still refuses to trust the tier
for exactly this reason; the drift check and `./check-profiles.sh` are how it
gets caught.

---

## Reading it

```bash
scripts/lv-exec.sh lv-profile.sh --show     # tier, reason, who, when
scripts/lv-exec.sh lv-profile.sh --check    # drift against the recommendation table
```

`--check` exits 0 clean, 1 on drift, 2 if no tier is declared or the declared
tier isn't in the closed vocabulary above.

**A `pre-launch` project is no longer checked for a standing grant.** Until
LVI-036, `--check` wanted one covering `release`, `deploy` and
`production-push` whenever `production_url` was set; the pre-launch default
made that grant unnecessary. What it checks instead is the date: a `pre-launch`
tier whose `live_from` is today or past is drift, and so is a `live_from` that
is not `YYYY-MM-DD`. A `governed` tier still holding a `production-push` grant
is still flagged.

Across every client:

```bash
./check-profiles.sh              # tier + drift per client, deployments.txt order
./check-profiles.sh --count      # one line per client
```

mirrors `sweep-issues.sh`'s shape on purpose — same walk over `deployments.txt`,
same reason to run it periodically rather than only when something already
hurts.

---

## What this does *not* do

- **It grants exactly one thing.** The pre-launch `production-push` default
  above. Every other grant in `orchestrator.autonomy` still requires its own
  `granted_by` / `granted_on` / `expires_on`.
- **It does not gate anything else.** There is no `profile-mismatch` gate.
  Drift is reported, not enforced — the same restraint `lv-autonomy.sh --show`
  uses for an unread `standing_for` entry.
- **It is not retroactive.** Declaring `governed` today doesn't undo whatever
  ran unattended yesterday under `pre-launch`.
