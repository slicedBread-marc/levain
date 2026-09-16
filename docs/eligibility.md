# Plan Eligibility Rules

Canonical reference for what makes an artifact eligible at each workflow stage.
All eligibility is determined by `plans/REGISTRY.md` state. Scripts in `scripts/wf-list-*.sh` implement these rules.

> **Gap:** there is no terminal state for work that is *dropped*. A plan abandoned mid-flight stays eligible forever, and — because four dependency checks read `!= complete` as unsatisfied — permanently blocks anything that depends on it. Proposed in [abandoned-plans.md](abandoned-plans.md); already hit in production by `app`.

**The orchestrator does not reimplement any of this.** `wf-orchestrate.sh` parses the same list scripts a human terminal does, then applies its own *additional* skip rules on top — see [orchestrator.md](orchestrator.md#skip-rules). An artifact eligible here may still not be dispatched, because a gate is open on it, its role is at `max_concurrent`, it's over its attempt budget, or the hourly spawn budget is spent. Eligibility and dispatchability are different questions; this file only answers the first.

---

## wf-spec (T2 — Planner)

**Script:** `scripts/wf-list-specable.sh`

| Priority | Source | Eligible when |
|-|-|-|
| 1 | REGISTRY.md `draft` state | Plan has `ESCALATED` items in `findings.md` (returned from verify/test) |
| 2 | `bugs/open/*/bug.md` | Bug exists with `BUG-NNN` ID |
| 3 | `plans/briefs/INDEX.md` | Entry under `## Decided` heading |

**Not eligible:** Briefs under other headings. Bugs in `triaged/` or `closed/`. Draft plans without ESCALATED findings (new plans being written — T2 is already on them).

---

## wf-implement (T3 — Builder)

**Script:** `scripts/wf-list-implementable.sh`

| Type | REGISTRY State | Eligible when |
|-|-|-|
| `new` | `ready` | Plan exists, **no existing worktree** for its branch |
| `resume` | `active`, or `ready` with a worktree | No unchecked findings in `findings.md` |
| `fix` | `active`, or `ready` with a worktree | Has unchecked (non-ESCALATED) findings in `findings.md` |
| `gated` | any | A gate is open on the plan — a human owes it an answer |

`gated` outranks every other type, and it is emitted rather than silently
dropped so the reason is visible. It was added in v5.1: the dispatcher
checked gates before spawning but this script did not, so a plan carrying an
unanswered gate was listed as ordinary `new` work and an implementer landed on
it with nothing in the worklist to say otherwise (client-a WFI-063).

A plan sent back to `ready` for a replan keeps its branch and worktree, so state
alone does not distinguish a new build from a resumed one. The worktree does:
if one exists, there is nothing left to create and the implementer picks up
where it left off.

**Not eligible:**
- Plans in `draft`, `verify`, `testing`, `complete`, or `abandoned` state.
- Plans in `active` with only ESCALATED findings — these need T2 (wf-spec).

---

## Verify Agent (automatic)

**Trigger:** REGISTRY.md state change to `verify`

| Source | Eligible when |
|-|-|
| REGISTRY.md `verify` state | Automatic — triggered by hook |

The verify agent runs autonomously and auto-routes:
- Clean → `testing`
- Code/spec findings → `active` (back to T3)
- ESCALATED findings → `draft` (back to T2)

---

## wf-test (T4 — Human Testing)

**Script:** `scripts/wf-list-testable.sh`

| Source | Eligible when |
|-|-|
| REGISTRY.md `testing` state | Plan has passed automated verification |

**Not eligible:**
- Plans in any other state.
- Plans that haven't been through the verify agent yet.

**Output format:**
- **stdout:** `<plan-name>\t<worktree-path>\t<branch>\t<goal>` per eligible plan
- **stderr:** `TESTABLE: N`, `TOTAL: N`

---

## wf-release (T-any, or daemon)

**Script:** `scripts/wf-list-release.sh`

| Source | Eligible when |
|-|-|
| local `release` branch, diffed against `develop` | `git rev-list release..develop -1` is non-empty **and** at least one commit subject isn't `/wf-deploy` bookkeeping **and** the range's net diff is non-empty **and** at least one changed path falls outside `plans/` and `bugs/` |

**Not eligible:** `release` branch doesn't exist yet (bootstrapping the first release is left to a
human). `release` and `develop` already in sync. `develop` is only ahead by planning commits —
T2 commits spec drafts and review rounds straight to `plans/` on `develop`, outside any feature
branch, and reviewing a spec is not releasing one (WFI-001, client-d). `develop` is only ahead
by `/wf-deploy`'s own bookkeeping (the promote marker, completion and back-merge commits,
registry transitions, bug closes) — that lands on `develop` after every deploy and is not work
to release; `/wf-release` step 3 filters the same subjects and reports "nothing to release".

The net-diff check is not redundant with the path check: an empty range diff (an
`--allow-empty` marker commit, which is how the promote marker is written) used to *pass* the
path test, because the single blank line it produced didn't match `^(plans|bugs)/`. Together
with the missing subject filter, that is what dispatched three no-op `/wf-release` runs in three
minutes on client-c and tripped a `stuck` gate over three runs that were each correct
(WFI-035).

Not REGISTRY-keyed — `release`/`deploy` aren't plans, they're a fixed singleton pipeline stage
(artifact id `RELEASE`, capped at 1 in flight). Local-ref only, deliberately cheap: this is a
candidacy check for the dispatcher, not a source of truth — `/wf-release` itself fetches and
re-verifies before doing anything. Eligibility here says nothing about *authorization*; a
dispatched worker still checks `wf-autonomy.sh release` and opens `release-approval` if nothing
covers it (see [`autonomy.md`](autonomy.md)).

---

## wf-deploy (T-any, or daemon)

**Script:** `scripts/wf-list-deploy.sh`

| Source | Eligible when |
|-|-|
| local `main` branch, diffed against `release` | `git rev-list main..release -1` is non-empty **and** `release` has no commits `origin/release` hasn't got |

**Not eligible:** `main` and `release` already in sync. Local `release` holds unpushed commits.

Artifact id `DEPLOY`, capped at 1 in flight, same shape as `wf-list-release.sh` above. This
signal is only safe because `/wf-release` pushes `release` *after* its local E2E run passes, not
before — so "release is ahead of main" means "these commits passed E2E," for both attended and
unattended runs. See `skills/wf-release/SKILL.md` steps 7-8.

Which is why unpushed commits are part of the check rather than a nicety: they are, by
construction, commits `/wf-release` did *not* push — a failed suite, or a worker killed mid-run.
client-b WFI-007 is that state reaching production's doorstep: E2E failed 1/117, the run exited
without resetting the local merge, this check counted 30 commits 71 seconds later, and the
deploy worker it dispatched opened a `deploy-approval` gate quoting the whole red batch as ready
to promote. `/wf-release` now rolls that merge back (`wf-release-rollback.sh`), and this check
is the second line rather than the only one (coordinator WFI-002). Eligibility here is not
authorization either — `/wf-deploy` checks `wf-autonomy.sh deploy` itself.

---

## Summary: State Routing

| REGISTRY State | Who acts | Skill/Agent |
|-|-|-|
| `draft` (no findings) | T2 | wf-spec (new plan) |
| `draft` (ESCALATED findings) | T2 | wf-spec (replanning) |
| `ready` | T3 | wf-implement (new) |
| `active` (no findings) | T3 | wf-implement (resume) |
| `active` (unchecked findings) | T3 | wf-implement (fix cycle) |
| `verify` | Agent | wf-verify (automatic) |
| `testing` | T4 | wf-test (human acceptance) |
| `complete` | — | Done |
| `rolled-back` | — | Reverted |
| `abandoned` | — | Dropped on purpose. Terminal. Revivable only to `draft` |
