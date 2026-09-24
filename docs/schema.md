# Workflow Document Schema Versions

All workflow artifacts (plans, bugs, briefs) carry a `schema_version` field in their header. Skills use this field to handle documents correctly.

## Version History

### v1 (legacy)
- `schema_version` field is **absent**
- Each type has its own independent counter — numbers are not globally unique
- Plans move between stage folders (`drafts/` → `ready/` → `active/` → etc.)

### v2 (legacy)
- `schema_version: 2`
- **Global counter:** `plans/.counter` file, shared across all artifact types
- Plans still move between stage folders

### v3 (legacy)
- `schema_version: 3`
- `.plan/` isolation on feature branches, `plans/` on develop only for pipeline stages
- Plans still move between stage folders on develop

### v4 (legacy)
- `schema_version: 4`
- **Registry-based model** — plans never move. State is tracked in `plans/REGISTRY.md`.
- **Counter embedded** in REGISTRY.md as `<!-- Counter: N -->` — no separate `.counter` file
- **No folder movement** — each plan lives at `plans/PLN-NNN-<slug>/` forever
- **No plan content on feature branches** — only a `.plan-ref` file containing the plan ID, and
  that file is gitignored as of v6.0.0, so the branch carries nothing but code
  (see [`worktrees.md`](worktrees.md))
- **Verify agent** replaces manual lv-verify skill — triggered automatically on state change to `verify`
- **Simplified findings** — flat checklists instead of FND-NNN tables with status columns

### v5 (legacy)
- `schema_version: 5`
- **Tags column** in REGISTRY.md — comma-separated category tags per plan (e.g. `security,admin`)
- **Deps column** in REGISTRY.md — comma-separated plan IDs that must be `complete` before this plan is workable (e.g. `PLN-045,PLN-073`), or another project's artifact as `<project>:<ID>` (e.g. `client-d:BRF-009`)
- **Goal stack** in `plan.md` — `### Goal History` table tracks goal overrides during fix cycles. When findings come back, lv-spec pushes a focused sub-goal; when resolved, the original goal is restored.
- Allowed tags (extensible): `security`, `arcade`, `admin`, `lessons`, `ux`, `infra`, `e2e`, `bugfix`

### v6 (current)
- `schema_version: 6`
- **Tagged manual criteria** — every `#### Manual` criterion in `plan.md` declares why a machine cannot check it, using exactly one of `(eyes:blocking)`, `(eyes:cosmetic)`, `(external)`, `(soak)`, `(unbuilt)`. Enforced by `lv-manual-lint.sh` at spec time and again at verify; an untagged or misclassified criterion routes the plan back to `draft`. See [Manual criterion tags](#manual-criterion-tags-v6).
- **Deferred criteria have a producer** — `plans/deferred-criteria.md` is written by `lv-defer-criterion.sh` when a plan completes with `external` / `soak` criteria outstanding. It was read by `lv-spec` step 1a in v5 but nothing ever created it. The script commits both halves of the deferral together — the DC row and the `[x] … — deferred as DC-NNN` checkoff in that plan's `plan.md` — because a caller's pathspec cannot name a path the script chose (WFI-144). A row is `open` until `--consume DC-NNN PLN-NNN` (a later plan adopted it) or `--satisfy DC-NNN --evidence "…"` (the real use happened and it is true, with no plan involved). Only `--consume` existed at first, so criteria that simply came true had no verb and stayed `open` forever — 40 of them in one project, including ones long since satisfied (WFI-148). Neither verb can fix what a row *says*, so `--amend DC-NNN --criterion "…"` corrects the text in place, keeping the ID that other plans already cite; without it a criterion found incomplete could only be hand-edited in a file that forbids hand-editing, or satisfied and re-deferred under a new number (WFI-158). Deferring text that matches an open row reuses that row rather than adding a second — two rows saying one thing are two work items that are one.
- **Progress checklist is live** — `progress.md`'s `## Steps` checklist is ticked per step by `lv-progress-tick.sh` and read by `lv-progress-count.sh`. It is the pipeline's forward-progress signal; the orchestrator resets a plan's attempt budget when it climbs.
- **Consistency section** — `plan.md` gains `## Consistency`, written by the cross-plan consistency pass for plans with declared `Deps`. Machine-owned, and excluded from the review/gate fingerprint for that reason (WFI-151).

**Registry tracking (workflow v3.2.0, no schema bump).** Nothing in the plan document changed, so `schema_version` stays at 6. What changed is where the registry lives:

- **`plans/REGISTRY.md` is tracked.** It was gitignored as "operational state", which left the pipeline's single source of truth as the one artifact in `plans/` that git did not hold: `plan.md`, `findings.md` and `progress.md` were versioned while the state machine indexing them was not, and a lost develop worktree took the whole pipeline's state with it. It also made the documented row-based auto-merge rationale describe a mechanism that could not occur in an untracked file.
- `lv-registry-update.sh --commit` stages the registry itself, so a transition and the findings that justify it land in one commit.
- **Every write to the registry goes through a script, creation included.** `lv-registry-add.sh` appends a new plan's row and commits it in the same locked step; `lv-registry-update.sh` moves it thereafter. Neither leaves a row dirty on the shared develop checkout, because a dirty row does not survive concurrency: no pathspec can defend a file two workers both legitimately name, so whichever commits first carries the other's uncommitted rows under the wrong message (WFI-061, WFI-065, WFI-140). Never hand-edit the table.
- Feature branches are unaffected: `lv-worktree-sparse.sh` already excludes `plans/**` from every feature worktree, so registry churn never reaches a feature branch or arrives as a conflict when one merges back.
- **Migration:** `install.sh` removes the `plans/REGISTRY.md` line from `.gitignore` and tells the project to commit the file. Nothing else changes.

## Manual criterion tags (v6)

`#### Manual` criteria are the only checks in the pipeline a machine never runs, so each one states the reason it is exempt:

| Tag | Means | Can a machine ever check it? | On failure |
|-|-|-|-|
| `eyes:blocking` | Subjective judgment about whether the user can complete the task | No | Findings written, plan routes to `active` |
| `eyes:cosmetic` | Subjective judgment about layout, spacing, copy tone, animation feel | No | Files a `BUG-NNN`, criterion checks off, plan completes |
| `external` | Needs a real third-party system, real credentials, or a physical act | Not in CI | Deferred to `plans/deferred-criteria.md` |
| `soak` | Needs real elapsed calendar time | Not at gate time | Deferred to `plans/deferred-criteria.md` |
| `unbuilt` | The prerequisite feature does not exist yet | Once it is built | Deferred to `plans/deferred-criteria.md` |

```markdown
#### Manual
- [ ] (eyes:blocking) /app/time — the timer is usable one-handed on a phone
- [ ] (eyes:cosmetic) /app/board — column spacing is even at 1280px
- [ ] (external) tool ticket pull <real id> — every image in the DevOps web UI is present
- [ ] (soak) tool work — the Stalled section surfaces something genuinely forgotten
- [ ] (unbuilt) the export button — the screen it lives on ships in PLN-112
```

`unbuilt` is the one tag a planner does not write by hand: `lv-defer-criterion.sh` stamps it when `lv-test` defers a criterion whose prerequisite has not shipped. It is listed here because the plan still has to lint afterwards.

A criterion fitting none of the five is misclassified and belongs in the Tests table. `lv-manual-lint.sh` also flags an `eyes:*` criterion written with an assertable verb (*is refused, returns, contains, exists, stops for, prints, matches, resolves*) unless the same line carries a subjective marker (*reads, feels, legible, usable, at a glance*).

**Migration from v5.** No migration script is needed and no in-flight plan changes behavior. `lv-manual-lint.sh` reads the plan's `schema_version` and skips linting anything below 6, so a v5 plan already in the pipeline is never failed back to `draft` for lacking tags. When counting criteria (for the manual-test gate) a v5 plan falls back to v5 semantics: every unchecked manual criterion counts as `eyes:blocking`, which is what "any Manual criterion gates" already meant. Plans drafted or re-drafted after the upgrade are written as v6 and must carry tags.

## Skill Behaviour

| `schema_version` | Model | State tracking | Plan on feature branch | Counter |
|-|-|-|-|-|
| absent | v1 | Folder location | `plans/{stage}/` | Per-type files |
| `2` | v2 | Folder location | `plans/{stage}/` | `plans/.counter` |
| `3` | v3 | Folder location | `.plan/` | `plans/.counter` |
| `4` | v4 | REGISTRY.md row | `.plan-ref` (ID only) | REGISTRY.md comment |
| `5` | v5 | REGISTRY.md row + Tags/Deps | `.plan-ref` (ID only) | REGISTRY.md comment |
| `6` | v6 | REGISTRY.md row + Tags/Deps | `.plan-ref` (ID only) | REGISTRY.md comment |

When creating new artifacts, always write `schema_version: 6`.

## REGISTRY.md

Single source of truth for plan state. Lives at `plans/REGISTRY.md` on develop, **tracked and committed** with the plan folders it indexes.

Only develop carries it. `lv-worktree-sparse.sh` excludes `plans/**` from every feature worktree, so there is exactly one writer at a time and a state transition never turns into a merge conflict. Write to it only through the `lv-*.sh` scripts — they take the `registry` lock for the whole read-modify-write and commit the transition atomically.

```markdown
| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-001 | user-auth | complete | — | — | 2026-04-01 | 1.33 | security | — |
| PLN-003 | payment-hook | active | urgent | feature/PLN-003-payment-hook | 2026-04-06 | 2.00 | infra | PLN-001 |

<!-- Counter: 4 -->
```

The `Priority` column is optional per-plan. Default value is `—` (normal). Set to `urgent` to surface plans at the top of workable item menus. Use `scripts/lv-set-priority.sh <plan-id> urgent` to mark a plan urgent, or `scripts/lv-set-priority.sh <plan-id> —` to clear it.

The `WF` column stamps the workflow version the plan was spec'd against. `scripts/lv-exec.sh` uses it to dispatch to the matching generation (see `scripts/version-map.txt`, and `docs/atomic-deploy.md` for where that generation sits on disk), so a plan keeps running the scripts it was built against. Empty WF routes to `v1.x` (pre-v2.00 baseline).

The `Tags` column holds comma-separated category tags (no spaces). Default `—`. Use `scripts/lv-set-tags.sh <plan-id> <tags>` to set, and `scripts/lv-list-tags.sh` to read the vocabulary.

**The vocabulary is the project's, not the schema's.** It is derived from the tags plans already carry, plus anything declared in `levain.yml` (`tags:`, `specApproval.gateTags`). A name outside it is accepted with a warning — this was once a hardcoded allowlist, and a project whose gating tag was not on it could not assign the one tag that gates. Tags are free-form labels; the only one with mechanical meaning is a match against `specApproval.gateTags`.

The `Deps` column holds comma-separated plan IDs that must reach `complete` state before this plan is workable. Default `—`. A plan with incomplete deps shows `[blocked]` in worklist menus. Use `scripts/lv-set-deps.sh <plan-id> <deps>` to set.

**A dep can name another project's artifact**: `client-d:BRF-009`, where the project is one declared under `dependencies:` in this project's `levain.yml` — the same key `lv-dep-bug.sh` files through, and the same local checkout. client-b WFI-015: PLN-011 was blocked on client-d's BRF-009 / BUG-011 and there was nowhere to record it. `lv-set-deps.sh` took plan IDs only, and the one mechanism that actually kept the daemon off the plan was a `lv-claim.sh` lease — explicitly stealable by any session that judges it stale. The plan sat in `draft`, a dispatchable state, with a live daemon that would have replanned it against tokens that did not exist yet.

It is **checked, not declared**. Identity is the number, per the ID system above — `BRF-009`, `PLN-009` and a closed `BUG-009` are one artifact — so the other project's own `plans/REGISTRY.md` and `bugs/closed/` answer directly, and the block lifts by itself when the work lands there. A marker only a human could clear would be the same stall in a different column. An unresolvable ref (project not declared, checkout missing, no registry there) **blocks**, because an unresolvable dependency is not a satisfied one. `lv-check-deps.sh` reports `EXTERNAL <ref> (<why>)` when the only thing outstanding is elsewhere, and `BLOCKED` when there is also work here — the nearer truth, since something in this pipeline has to happen either way.

### States

| State | Meaning | Who acts next |
|-|-|-|
| `draft` | Being written or needs replanning | T2 (lv-spec) |
| `ready` | Spec approved, waiting for builder | T3 (lv-implement) |
| `active` | Being implemented or in fix cycle | T3 |
| `verify` | Verify agent running automated checks | (automatic) |
| `testing` | Passed automated checks, needs human test | T4 (lv-test) |
| `complete` | Done | — |
| `rolled-back` | Reverted | — |
| `abandoned` | Dropped on purpose — terminal, not successful | — |

### State machine

```
draft → ready → active → verify ──[agent]──→ testing → complete
                  ↑          |
                  |          ├→ active  (fix cycle)
                  |          └→ draft   (escalation)
                  └→ draft  (implementer escalation)

any state ──[lv-abandon.sh]──→ abandoned ──[--revive]──→ draft
```

**`abandoned` is terminal like `complete`, but not successful.** Every other state means someone still owes work; `complete` means it shipped. Without a third option a dropped plan can only be left in a working state (and re-dispatched forever) or marked `complete` (claiming code that never shipped). It is reachable from anywhere, because work is dropped from wherever it happened to be, and revivable only to `draft` — a branch left months ago is not safe to resume mid-pipeline.

A dependency that is abandoned **will never be satisfied**. `lv-check-deps.sh` reports it as `DEAD` rather than `BLOCKED`, and the list scripts label it, so the dependent gets replanned instead of waiting forever.

**States are validated on write.** `lv-registry-update.sh` rejects any value outside the set above. It used to accept anything, so a typo — or a state someone invented under deadline — became a live value in the pipeline's single source of truth, unroutable by the orchestrator and permanently blocking to dependents. Use `lv-abandon.sh <ID> --reason "..."`, which records why in the plan's `progress.md`; the reason is the part that would otherwise be lost.

**Two transitions carry preconditions, checked on write.** The registry is what every other skill trusts, so the two states that make a *claim about work someone else did* verify it rather than take the caller's word:

| Transition | Refused when | Override |
|-|-|-|
| `draft → ready` | `plan.md` records no review verdict — `lv-review-status.sh` reports `REVIEW_LOCATION=none`, or the plan folder does not exist | `LV_ALLOW_UNREVIEWED=1` |
| `draft → ready` | a `spec-approval` gate is open and unanswered | `LV_ALLOW_UNGATED=1` |
| `testing → complete` | an unchecked `eyes:blocking` criterion with no PASS in `test-progress.md` and no answered `manual-test` gate | `LV_ALLOW_UNTESTED=1` |
| `* → complete` | the Branch column names a branch that still exists and is an ancestor of none of `release`, `main`, `develop` (or their `origin/` counterparts) | `LV_ALLOW_UNMERGED=1` |

The two added in v9.19.0 come from the same shape of failure on opposite ends of the pipeline: a transition written as if it *were* the judgement it is supposed to record. client-b' PLN-011 went `draft → ready` on an unattended review's "Approved", leaving the human's own spec-approval gate standing as the last thing between a daemon and a build nobody had signed off (WFI-012). client-d's PLN-004, PLN-005 and PLN-006 went `testing → complete` within minutes of their spec gates closing, 9 human criteria unchecked between them, two of the commits carrying the subject "human test passed — complete" and changing only `REGISTRY.md` (WFI-009). Neither is caught by the review check above: a review says the plan is sound, which is a different question from whether a human approved it or whether anyone tested it.

`testing → complete` asks a deliberately weak question — *did anyone ever execute this*, on any build — because that is the one the three client-d plans could not answer. The stronger per-build question belongs to `lv-manual-gate.sh`, which needs a plan diff and so cannot be asked at completion, by which time the worktree is usually gone. An `eyes:blocking` criterion is the only kind that blocks: somebody judged it as needing eyes *and* as blocking release without them, and `eyes:cosmetic` explicitly files a bug and ships.

`ready` tells a builder the plan was reviewed and approved, and a review that never reached disk turns that into a lie the pipeline cannot detect downstream — client-a's WFI-164 published a `ready` row over a `plan.md` holding the bare template placeholder, because a concurrent worker's stash had swept the review out of the shared checkout seconds before the transition committed. `complete` closes the plan, closes its bug, and licenses a release; WFI-165 reached it with the feature branch merged nowhere at all, and a full deploy shipped green without the fix the plan and the bug both claimed.

A *missing* branch is accepted for `complete`: `git branch -d` refuses to delete an unmerged branch, so its absence is evidence, and `lv-deploy` runs long after `lv-test` removed it. For work that will never land, `lv-abandon.sh` is the answer — not the override.

`lv-registry-audit.sh` checks the registry against `plans/` from the other direction — folders with no row, rows with no folder, duplicate IDs, a counter that would collide, unroutable states, and pre-implementation states sitting on branches that are ahead of develop.

## Findings Format (v4)

Flat checklist appended per session:

```markdown
## Verify — 2026-04-06

- [ ] **Code**: Description (file:line)
- [ ] **Spec**: Description
- [ ] **Design**: Description ← ESCALATED
```

Routing rules:
- Any `ESCALATED` → state goes to `draft`
- Any unchecked non-escalated → state goes to `active`
- All checked or no findings → state advances

Every finding's opening `- [ ]`/`- [x]` must start at column 0 — `lv-findings-route.sh` never treats an indented checkbox as a finding, so one nested under a paragraph or sub-list is invisible to routing regardless of its tag (client-e WFI-024).

## Goal Stack (v5)

Plans track goal overrides during fix cycles via `### Goal History` in `plan.md`:

```markdown
## Goal
Fix flicker on re-render after viewport resize (show-stopper from verify)

### Goal History
| Date | Previous Goal | Trigger | Resolution |
|-|-|-|-|
| 2026-04-16 | Fix bonus round to reactively suppress arcade games on mobile viewports | Verify: 2 findings (1 show-stopper) | — |
```

- **Push**: when findings return a plan to `draft`, lv-spec calls `lv-goal-push.sh` to archive the current goal and write a new one summarizing pending items. If a finding is a show-stopper, it becomes the goal's focus.
- **Pop**: when replanning resolves all findings and the plan returns to `ready`, lv-spec calls `lv-goal-pop.sh` to restore the original goal and mark the history row resolved.
- **Amend**: `lv-goal-amend.sh` corrects what a plan promises without pushing or popping. It writes the *archived* goal by default — the text a pop will restore verbatim — because that is the promise a scope reduction contradicts while the live one-liner is still a fix-cycle sub-goal. `--active` targets the live line instead. This is the only supported way to change an archived row; the block says "do not edit manually" and means it (WFI-084).
- `lv-plan-info.sh` always reads the first non-empty line after `## Goal` — downstream consumers (lv-implement, lv-test, lv-tray) see the active goal automatically.
- **Not part of the review fingerprint.** `lv-review-stamp.sh` hashes the plan body minus `## Review`, minus `### Goal History`, minus `## Consistency`, and with checkbox marks normalised: a push, a pop, a ticked criterion or a consistency done-marker is bookkeeping, not a specification change, and staleness that fires on bookkeeping costs a full review round to re-approve identical text (WFI-092, WFI-093, WFI-095, WFI-151). The same fingerprint backs `GATE_STALE`, so a bookkeeping write also re-opened approvals a human had already given. The `## Goal` one-liner *is* hashed, which is why lv-spec stamps after the pop rather than before it.

## Counter

Embedded in `plans/REGISTRY.md` as `<!-- Counter: N -->`. To allocate a new number (briefs and bugs only):
1. Read N from the comment
2. Use N as the new artifact ID
3. Write N+1 back in the same commit

**Number inheritance:** When a brief or bug is converted to a plan, the plan reuses the same number — no new counter allocation. BRF-041 → PLN-041, BUG-043 → PLN-043. The counter is only incremented when creating new briefs or bugs.
