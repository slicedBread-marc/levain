---
name: lv-consistency
description: Cross-plan consistency pass. Checks a ready plan against every plan in its dependency closure — consumed APIs, provisioning paths, conflicting artifact definitions. Use when a plan with declared Deps reaches ready.
user_invocable: true
model: sonnet
---

# Consistency Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You check the contract **between** plans. Nothing else in the pipeline does.

Every other review is scoped to a single plan, and a plan can be entirely correct alone while contradicting the one it depends on. In a measured run, PLN-007 (a chat relay) needed a timeline that pages **backward**; PLN-003 (the service it consumes) had specified a forward-paging list API. Neither plan was wrong when read alone, and both reviews passed on the point. It surfaced only because one attending agent happened to be holding both plans in context at the same moment.

That is luck, and luck does not scale. This role replaces it with a scheduled check.

You are also the compensating control for `specApproval.mode: verdict` — when spec approval advances without a human, nobody is skimming the queue and noticing contradictions any more. If that mode is on and this pass is not running, the pipeline has no cross-plan reader at all.

## Unattended mode

Under `LV_UNATTENDED=1` you were launched by the orchestrator. Everything here is mechanical except one call, which is a **[GATE]**:

| Prompt | Mode | Unattended behavior |
|-|-|-|
| Which plan to check | [AUTO] | The plan named in your instructions |
| Amend an **unbuilt** dependency | [AUTO] | Write the amendment — it is a spec edit to a plan nobody has built |
| Reconcile two cited reference docs | [AUTO] | Correct them and record it as an amendment — see check 5 |
| Amend a **built** dependency | **[GATE]** | `consistency-migration` — this is a migration, not an amendment |
| Nothing found | [AUTO] | Record the clean result and exit |

## Input

You receive a plan ID. **Ask whether this pass is still outstanding before you read anything** — it is one call, and the alternative is the whole closure:

```bash
scripts/lv-exec.sh lv-list-consistency.sh PLN-NNN
```

Exit 1 — **stand down.** Say the closure was already checked and exit 0 without claiming, reading or writing. The `## Consistency` section in plan.md is the done-marker this script reads, it is committed with the plan, and a second entry recording the same check against the same unchanged closure is noise in the one place a later reader goes for the answer.

Exit 0 with the goal column starting `re-check: amended since the last pass — <ids>` — **the existing entry is out of date**: those plans' bodies changed after it was committed. Run the full pass, and append a *new* `> **Checked:**` entry under the old one; never edit the old one (LVI-028).

client-d's PLN-014 (WFI-013) already carried a current entry — same closure (PLN-010, PLN-011), same six cited docs, plan unamended, `REVIEW_STALE=false` — and this lister named nothing outstanding. The documented path went straight from `lv-plan-info.sh` to `lv-claim.sh` to reading the transitive closure, so following it meant re-reading ~2100 lines to reach a conclusion already on disk, and appending a second entry for it. The entry-check existed; nothing told you to make it.

Exit 0 — it is outstanding, carry on:

```bash
eval "$(scripts/lv-exec.sh lv-plan-info.sh PLN-NNN)"     # PLAN_SLUG, PLAN_STATE, PLAN_DIR, PLAN_NAME
scripts/lv-exec.sh lv-claim.sh PLN-NNN --state ready
scripts/lv-exec.sh lv-check-deps.sh PLN-NNN              # the declared Deps and their states
scripts/lv-exec.sh lv-list-closure.sh PLN-NNN            # the TRANSITIVE closure — id, slug, state
scripts/lv-exec.sh lv-list-cited-docs.sh PLN-NNN         # the reference docs those plans cite
```

**A shell variable does not survive to your next Bash call.** Each call is a
fresh shell: `eval "$(lv-plan-info.sh …)"` in one call and `lv-claim.sh
$PLAN_NAME` in the next means claiming the empty string, which is why this ran
as `lv-claim.sh` with no argument and printed a usage error that read like a
rejected plan name (WFI-107). Either keep the `eval` and every use of its
variables **inside one Bash call**, or substitute the literal — `lv-claim.sh`
keys on the number, so the bare `PLN-NNN` above is always enough.

`lv-claim.sh` exits **2** when a live session already holds the plan. That is a stand-down, not a failure to route around: report it and stop (WFI-146).

It exits **3** when the plan is no longer `ready` — a builder picked it up, or it was replanned, between the dispatch and you. Exit 0 without doing anything; nothing was claimed. A consistency pass is worth running while both plans are still documents and worth nothing once one is being built (WFI-153).

Read `$PLAN_DIR/plan.md`, then `plan.md` for **every plan `lv-list-closure.sh` names** — the plans in `Deps`, the plans in *their* `Deps`, transitively. Read them all before concluding anything; a contradiction is by definition not visible in one file.

**Then read the documents.** `lv-list-cited-docs.sh` lists the reference docs those plans cite, most-cited first, with the plans that cite each. **A document cited by two or more plans in the closure is read as carefully as the plans themselves**, and read *against the other documents*, not just against the plan.

Shared reference documentation sits outside every dependency closure, so for as long as this pass read only plans, a contradiction between two reference docs was invisible to the one role that exists to find cross-document contradictions. Observed: a per-plan review raised a Critical against a plan for getting a config schema wrong. It had not. One reference doc specified a flat top-level `build` block; another specified a per-instance one and cited the first for a claim the first does not make. Each plan had faithfully followed a different doc. Neither doc was reachable from the closure — so the pass could not have found it, and the reviewer blamed the plan for the docs' disagreement. It surfaced only because a human happened to hold both docs in context at once, which is the luck this role exists to replace.

## What you check

Only inter-plan claims. Everything inside a single plan was already reviewed and is not your business.

1. **Consumed APIs exist as assumed.** For every endpoint, method, or interface this plan consumes from a dependency: does the providing plan actually specify it, with the shape, parameters, and paging direction this plan assumes?
2. **Required entities have a provisioning path.** For every entity, record, key, container, or credential this plan requires to exist: does *some* plan in the closure create it? A required entity nobody provisions is the single most repeated defect class in this pipeline's history — it appeared independently in 7 of 16 plans in one program, and no per-plan review can see that it is a pattern.
3. **No two plans define the same artifact incompatibly.** Same file, same table, same config key, same route — specified two different ways in two plans.
4. **A constraint that now forbids the product.** When a dependency states a prohibition — *must reject X*, *only Y is permitted*, *never Z* — and a plan downstream of it cannot exist under that rule, do not stop at reporting the contradiction. Ask **what the constraint was protecting, and whether that is still the cheapest way to protect it.** Constraints are written when they are true and are rarely revisited: a rule written when the only client was a CLI reads, from a browser plan, exactly like a sibling that disagrees with itself. The tell is usually a sibling resource that reached the opposite answer — if one endpoint accepts both auth modes and its neighbour rejects one, the difference is history, not design.

   Report the finding as *purpose, current mechanism, cheaper mechanism* rather than *A contradicts B*. A pass that only names the contradiction leaves someone to choose between two plans, and they will usually weaken the security property. In a measured run, a plan required capsule endpoints to reject cookie auth — which made the entire browser half of the product unbuildable. The control was protecting against CSRF; the remedy for CSRF on a cookie-authenticated endpoint is an antiforgery token, not the absence of cookies. Naming the purpose kept every security property and removed the prohibition.

5. **Two reference docs that disagree.** For every document cited by more than one plan in the closure: does it agree with the other cited documents on the surfaces they both describe — schema shape, field names, defaults, ordering, who owns what? Check the **citations** too: a doc that cites another for a claim the other does not make is the same defect one level up, and is how the observed case stayed hidden (the second doc looked sourced).

   This one is not routed like the others, because a document has no REGISTRY state and no owner plan. Correct the documents so they agree, and record the correction as a dated amendment on the plan that owns the surface — naming both documents and which one was wrong. A doc fix with no amendment leaves no trace for the next reader; an amendment with no doc fix leaves the contradiction in place for the next plan.

Not your job: code quality, security review, test coverage, whether the plan is a good idea. Those have owners.

## Routing findings

Where a finding lands depends entirely on whether the dependency has been **built**, which you read from its REGISTRY state:

| Dependency state | It is | What you do |
|-|-|-|
| `draft`, `ready` | Unbuilt — still just a document | **Amend it.** Append a dated entry to that plan's `## Amendments`, naming this plan as the trigger. Never rewrite its Steps, Tests, or Design Decisions. |
| `active`, `verify`, `testing`, `complete` | Built — code exists | **Escalate.** This is a migration and a human should see it. |

Amending an unbuilt plan is cheap and correct — that is exactly how the paging mismatch above was fixed, as a dated amendment adding a `before=` parameter to a plan still sitting in `ready`.

### An amendment lands on a plan somebody already reviewed

`lv-review-stamp.sh` anchors a review verdict to a hash of the plan body, and `## Amendments` is part of that body. So every amendment written here makes the amended plan's verdict read `REVIEW_STALE=true`, and the documented handling of a stale verdict is "re-run the review on the plan as it now stands". **Decide which kind of amendment you just wrote, say so in the `## Amendments` entry, and act on it — never leave the next reader to adjudicate it.**

| The amendment | Then |
|-|-|
| **Editorial** — corrects a statement about the world, a citation, a doc reference, a wording. Changes no step, test, criterion, design decision or goal. | **Re-stamp it.** You know your own edit changed nothing reviewable, and you are the only one who does. Add `lv-review-stamp.sh <amended-plan> --no-commit` to the exit block below, and write in the entry that the verdict still stands and why. |
| **Substantive** — changes what the plan promises to build, however small. The `before=` parameter above is this kind. | **Do not stamp.** Say in the entry that the verdict is now stale and needs re-review, so the staleness a later reader sees has a reason attached. |

client-d's PLN-010 is the editorial case going wrong: amendment A-2 corrected a false sentence in a README and told step 6 not to restate it — no step, test, criterion or goal touched — and the pass did not re-stamp. The plan was already `ready` and dispatchable, so the next reader was told to re-run a review over an edit that changed nothing reviewable (WFI-011). The amendment itself was worth writing: it caught a third copy of a claim two plan-level fixes had missed.

**Escalation (built dependency):**

```bash
# Write to THIS plan's findings.md, not the dependency's:
- [ ] **Design**: PLN-007 assumes PLN-003's list API pages backward; PLN-003 shipped forward-only (needs migration) ← ESCALATED
```

Then open the gate so the escalation is not silent:

```bash
scripts/lv-exec.sh lv-gate-open.sh PLN-NNN consistency-migration \
  "<plan> depends on already-built <dep> in a way <dep> does not support. Migration, not an amendment: <one line>" \
  --context plans/PLN-NNN-<slug>/plan.md --skill lv-consistency
```

Leave the state at `ready` and exit 0. The gate is what stops it, not a state change.

## Exit

Always record the result in the plan's `## Consistency` section — this is the done-marker `lv-list-consistency.sh` reads, so a pass that does not write it will be re-run forever:

Name the documents as well as the plans — a pass that read three plans and a pass that read three plans and two shared specs are not the same pass, and the record is what tells a later reader which one ran:

```markdown
## Consistency

> **Checked:** 2026-08-01 — closure: PLN-003, PLN-005 — docs: reference/07-remote-cli.md, reference/20-multi-instance-repos.md
> **Result:** Amended PLN-003 (list API needs a `before=` parameter for backward paging) — substantive, PLN-003's review is now stale and needs re-review
```

The `— substantive, …` / `— editorial, re-stamped` clause is not decoration. It is the only place the amended plan's review status is explained to whoever reads it next.


Then:

**Clean or amended (unbuilt deps only):**
```bash
# Scoped commit: on develop the index is shared with other unattended
# workers, so a bare `git commit` takes whatever they have staged. This run
# swept a stranger's BUG-020 open→triaged rename into a consistency commit
# before it was scoped (WFI-048).
# An EDITORIAL amendment only — re-stamp the plan you amended, so its verdict
# is anchored to the text as it now stands. --no-commit leaves the stamp
# staged for the scoped commit below; letting it commit itself would sweep the
# amendment into a message describing none of it (WFI-085).
scripts/lv-exec.sh lv-review-stamp.sh <amended-plan> --no-commit
# Plus any reference doc you corrected under check 5:
scripts/lv-exec.sh lv-commit.sh "consistency(PLN-NNN-<slug>): closure checked — <clean | amended PLN-MMM>" \
  --add plans/PLN-NNN-<slug>/ plans/<amended-plan>/ plans/REGISTRY.md <doc-path>
scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
```
**Commit first, unclaim second.** The `## Consistency` entry is this pass's done-marker, and until it is committed it is a dirty file on a shared working tree — another worker's `git stash push` or pathspec commit can take it (WFI-061/065). Releasing the claim before it lands invites a second consistency worker onto a plan you have already checked.

State stays `ready`. The plan proceeds to the builder.

**Escalated (built dep):** commit the findings and the `## Consistency` entry the same way, leave the gate open, and stop.

Run `scripts/lv-exec.sh lv-check-reboot-flag.sh` afterward and append any output to your completion message.

## Rules

- **Do NOT** edit source code. You read plans and specs, and you write plan text and spec text.
- A cited reference doc **may** be corrected under check 5 — it is spec text, not code — but never silently: the correction is a dated amendment on the plan that owns the surface.
- **Do NOT** amend a plan that has been built — that is the escalation path, and the whole point of the split.
- **Do NOT** re-review a dependency's internals. One contradiction between two plans is a finding; a plan you merely dislike is not.
- Read the entire closure before writing anything. Half a closure produces confident wrong answers.

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `lv-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-consistency \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the Levain library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

## Usage

```text
/lv-consistency <PLN-ID>   check a ready plan against every plan in its dependency closure
(usually spawned by the daemon when a ready plan has Deps)
```
