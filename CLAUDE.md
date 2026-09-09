# Project Purpose

This project is a development workflow library. All `wf-*` skills are designed to be deployed to other projects — they form a reusable workflow harness that can be dropped into any codebase to provide a structured, multi-terminal development pipeline.

Work in this repo is about building, improving, and maintaining that library, not about implementing features for this repo itself.

## Interaction Rules

- When given content, **diagnose and correct** issues in skills (`SKILL.md`) or associated scripts.
- **Never run skills** directly.
- Fixing pipeline data (registry, plan files, etc.) is secondary — **always prompt the user** before modifying data.

## Clients

- Deployment targets are listed in `deployments.txt` (one absolute path per line). Each receives copies of skills and scripts via `deploy-all.sh`.
- To add a new client: append its path to `deployments.txt`, ensure its `claude-workflow.yml` sets a unique `project_slug` (prevents Docker compose collisions), then run `./deploy-all.sh`.

### Clients depending on each other

Two clients can depend on one another (client-e integrating client-c's OIDC is the standing
case). A bug or request that belongs to the *other* side of an integration is filed through
`wf-dep-bug.sh` — it runs the dependency's own `wf-bug-new.sh` through the dependency's own
`wf-exec.sh`, so the report lands in that project's own `bugs/open/`, allocated by its own
counter, picked up by its own `/wf-spec`. Declared per-client in that client's own
`claude-workflow.yml` under `dependencies:`, never in this repo. See
[`docs/cross-project-reports.md`](docs/cross-project-reports.md).

### The client copy of the harness is generated

Everything `deploy-all.sh` writes into a client — `scripts/v*/`, `.claude/skills/wf-*/`,
`.claude/workflow.md`, the hooks — is **gitignored there** as of v5.0.0. The library is the
source of truth; the client copy is build output. A client's own config
(`claude-workflow.yml`), its `WORKFLOW.md`, its `.claude/workflow-version` stamp and all of
`plans/` + `bugs/` stay tracked. See [`docs/untracked-harness.md`](docs/untracked-harness.md).

### Inbound: workflow issues from clients

Clients report harness problems as they hit them — a `wf-*` script erroring unexpectedly, a skill instruction referencing something that doesn't exist, the registry contradicting the worktree. Each lands in that project's root `WORKFLOW-ISSUES.md` via `wf-issue.sh`.

**Sweep them periodically — this is the main source of process-bug reports:**

```bash
./sweep-issues.sh              # open issues, grouped by client
./sweep-issues.sh --count      # one line per client
```

Fix the cause **here**, in the library — never in the client, where the next deploy overwrites it. Then:

```bash
./deploy-all.sh
./sweep-issues.sh --resolve WFI-NNN --client <name> "fixed in vX.Y.Z"
```

Resolved entries stay in the client's file as the record of what was already reported. `sweep-issues.sh` exits 0 when there is work and 1 when every client is clean.

### VERSION is bumped by a hook, and you state the level

`.git/hooks/pre-commit` bumps `VERSION` into every commit. It bumps a **patch** unless told otherwise:

```bash
WF_BUMP=minor git commit -m "feat(x): a new script, a new flag"     # 0.x.0
WF_BUMP=major git commit -m "breaking(x): a changed contract"       # x.0.0
```

The level is not read from the commit message, and cannot be: `pre-commit` is the only hook whose `git add` git re-reads into the commit, and it is the one hook that has no access to the message — `.git/COMMIT_EDITMSG` still holds the *previous* commit's message when it runs. So an unstated bump understates by design; say `WF_BUMP` when a commit adds a script, a flag, or changes a contract.

---

## Process Flow

### Terminal Roles

The workflow is designed to run across 4 terminal sessions, each with a dedicated role:

| Terminal | Role | Primary Skills | Model |
|-|-|-|-|
| T1 | Intake | `/wf-status`, `/wf-brainstorm`, `/wf-bug` | Sonnet |
| T2 | Planner | `/wf-spec` | Opus |
| T3 | Builder | `/wf-implement` | Sonnet |
| T4 | Tester | `/wf-test` | Haiku |
| Agent | Verifier | `wf-verify` (auto-triggered) | Sonnet |
| Agent | Consistency | `wf-consistency` (auto-triggered on `ready` + Deps) | Sonnet |
| Any | Claims | `/wf-claim` | Haiku |
| Any | Release | `/wf-release`, `/wf-deploy` | Haiku |

Each terminal runs `/wf-init` once per session to establish its role. `/wf-next` auto-routes to the correct skill based on `TERMINAL_ROLE`.

### Orchestrated mode (one terminal)

The four-terminal layout above is the **manual** mode. With the orchestrator enabled, a daemon dispatches those same skills as unattended workers by REGISTRY state, and the human works a single terminal:

| Surface | Purpose |
|-|-|
| `wf-orchestrate.sh --daemon` | Continuous dispatch (its own terminal; never returns) |
| `wf-orchestrate.sh <ID>` | Drive one bug/brief/plan end to end — the hook for an external project |
| `/wf-board` | What's in flight: workers, gates, pipeline, events |
| `/wf-attend` | Drain the queue of decisions the orchestrator refused to make |
| `wf-autonomy.sh --show` | What this project has authorized the harness to do unattended |

Routing is deterministic bash — the orchestrator never calls a model. Ships **disabled**; see `docs/orchestrator.md`.

The promotions *after* `complete` — `/wf-release`, `/wf-deploy`, the production push — are the
one place a human's standing authorization can be recorded rather than re-asked each session.
`wf-autonomy.sh` answers whether an action is authorized and never performs one; the vocabulary
is closed, and a grant carries an author, a date and a required expiry. Also ships **off**. Read
[`docs/autonomy.md`](docs/autonomy.md) before adding a key.

Each client also gets a generated `WORKFLOW.md` at its project root (from `templates/WORKFLOW.md`) — the entry-point contract for any agent or script that lands in that repo cold: pipeline shape, hooks that fire automatically, and the `wf-orchestrate.sh` exit codes.

---

### Design Principles

1. **Immovable plans** — each plan lives at `plans/PLN-NNN-<slug>/` forever. No folder movement.
2. **Registry as state machine** — `plans/REGISTRY.md` is the single source of truth for plan state. Tracked and committed on develop; excluded from every feature worktree, so it has one writer and transitions never become merge conflicts.
3. **Simple entry, complex exit** — every skill starts with one `grep` on REGISTRY.md. Exit logic handles state transitions, commits, and handoffs.
4. **No plan content on feature branches** — only a `.plan-ref` file (one line: the plan ID). Skills read plan content from the develop worktree.

---

### Plan Pipeline

State is tracked in `plans/REGISTRY.md`, not by folder location:

```
draft → ready → active → verify ──[agent]──→ testing → complete
                  ↑          |
                  |          ├→ active  (fix cycle)
                  |          └→ draft   (escalation)
                  └→ draft  (implementer escalation)
```

| State | Meaning | Who acts next |
|-|-|-|
| `draft` | Being written or needs replanning | T2 (wf-spec) |
| `ready` | Spec approved, waiting for builder | T3 (wf-implement) |
| `active` | Being implemented or in fix cycle | T3 |
| `verify` | Verify agent running automated checks | (automatic) |
| `testing` | Passed automated checks, needs human test | T4 (wf-test) |
| `complete` | Done | — |
| `abandoned` | Dropped on purpose — terminal, but not successful | — |

Bugs move through: `bugs/open/` → `bugs/triaged/` → `bugs/closed/`

---

### Full Workflow

1. **T1 (Intake)** runs `/wf-status` to see the pipeline (reads REGISTRY.md). Files bugs with `/wf-bug`. Brainstorms and decides briefs with `/wf-brainstorm`.

2. **T2 (Planner)** runs `/wf-spec` — greps REGISTRY for `draft` state. Converts briefs/bugs into plans, or reviews findings (escalated and behavior) routed from testing/verify. Review gate promotes `draft→ready`.

3. **T3 (Builder)** runs `/wf-implement` — greps REGISTRY for `ready` or `active` state. Creates feature branch worktree with `.plan-ref`, codes all steps. Exit sets `active→verify`, triggering the verify agent.

4. **Verify agent** (automatic) — triggered by REGISTRY state change to `verify`. Checks code, spec completeness, and design soundness. Auto-routes: clean→`testing`, findings→`active`, escalated→`draft`.

5. **T4 (Tester)** runs `/wf-test` — greps REGISTRY for `testing` state. Guides human through acceptance criteria. On pass, creates PR to release.

6. **Release** — `/wf-release` merges approved PRs into the release branch and runs E2E tests to validate staging.

7. **Deploy** — `/wf-deploy` promotes the validated release branch to `main`. Marks plans complete, closes bugs, and back-merges to develop.

---

### Branch Strategy

```
main        → production
release     → staging / pre-production
develop     → integration branch (all plans land here)
feature/*   → one branch per plan (e.g. feature/PLN-005-bug-002-guest-logout)
```

T3 creates a `feature/<plan-name>` branch and worktree from `develop`. On completion, the worktree merges back to `develop` and the feature branch is deleted.

`release` and `main` each live in their own persistent worktree too — `release-branches/release` and `release-branches/main`, pinned by `/wf-release` and `/wf-deploy` respectively (`wf-worktree-pin.sh`). Neither skill checks out its branch in the shared develop worktree anymore, so a release or a deploy in progress no longer moves what a parallel session, or the orchestrator, reads as `develop`. Read `docs/release-worktrees.md` before changing either skill's worktree step.

What a feature worktree may and may not contain is a contract, not a preference — a path that is both sparse-excluded and written by deploy breaks git outright. Read `docs/worktrees.md` before changing either list. Release and main worktrees are **not** sparse — they need the real `plans/**` content, which is the entire point of merging into them — see `docs/release-worktrees.md`.

How a skill hands a plan back is also a contract: **commit the state transition, then close the gate, then unclaim** — never the reverse. Read `docs/guard-ordering.md` before editing any skill's exit path.

State survives a compacted conversation because `wf-rehydrate.sh` re-reads it from the registry afterwards, wired to `SessionStart(compact)` — **not** `PostCompact`, whose output reaches the human and never the model. Read `docs/rehydration.md` before touching either hook.

---

### Artifact ID System

All artifacts (plans, bugs, briefs) use a **global shared counter** embedded in `plans/REGISTRY.md` as `<!-- Counter: N -->`.

- When creating a **brief or bug**, allocate a new counter number (`wf-counter-next.sh`). It advances past any live artifact first, so a counter left behind by a migration or a bad merge cannot hand out a number already in use.
- When converting a brief/bug to a **plan**, the plan **inherits the same number** — no new allocation. BRF-041 → PLN-041, BUG-043 → PLN-043. `wf-plan-id.sh` decides this; when the inherited number is already taken it allocates a fresh one and says so, because the alternative is overwriting a live plan (WFI-011).
- IDs are type-prefixed: `PLN-NNN`, `BUG-NNN`, `BRF-NNN`.
- Numbers are globally unique across all types, and the number is what the orchestrator treats as identity — one claim and one already-running guard cover a brief and the plan it becomes.

**Schema version:** `6` (see `docs/schema.md`). Registry-based model — plans never move, state in REGISTRY.md, `.plan-ref` on feature branches. v5 added Tags and Deps columns plus the goal stack. v6 adds typed reason tags on `#### Manual` criteria (`eyes:blocking`, `eyes:cosmetic`, `external`, `soak`, linted by `wf-manual-lint.sh`), a live `## Steps` checklist in progress.md as the forward-progress signal, a `## Consistency` section, and a producer for `plans/deferred-criteria.md`.
