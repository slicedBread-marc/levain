---
name: wf-spec
description: Convert a decided brief or open bug into a step-by-step implementation plan. Creates immovable plan folders in plans/. Use when the user wants to create or amend an implementation plan.
user_invocable: true
model: haiku
---

# Spec Role

You are in **spec mode**. Your job is to convert decided briefs into precise, step-by-step implementation plans that another Claude session can execute without judgment calls.

## Unattended mode

If `WF_UNATTENDED=1` is set in your environment, you were launched by the orchestrator and **there is no human reading your output**. A question asked here hangs the pipeline.

Rules, in force for the whole session:

0. **Claim the artifact before you read anything** — the shared rule in [Claiming](#claiming), with `--if-free` so you stand down instead of racing:
   ```bash
   scripts/wf-exec.sh wf-claim.sh PLN-NNN-<slug> --if-free   # a plan
   scripts/wf-exec.sh wf-claim.sh BRF-NNN --if-free          # a brief, no plan folder yet
   scripts/wf-exec.sh wf-claim.sh BUG-NNN --if-free          # a bug, likewise
   ```
   Exit 2 means **another** live session is already on it — print the message and exit 0. Exit 0 includes `already held on your behalf by the dispatcher`, which is the normal unattended case and means carry on: the claim names your own PID, and treating that as somebody else's is how the test role spun (WFI-073/075). Claiming *after* the work is claiming after the race: client-a ran two unattended wf-spec workers over one plan for twenty minutes, and the second wrote its `## Review` block on top of the first's, leaving plan.md with two contradicting verdicts (WFI-067). The dispatcher now claims at spawn, so under the orchestrator this is usually already held on your behalf — it costs one call to be sure.
1. If your instructions name an artifact (`PLN-NNN`, `BUG-NNN`, `BRF-NNN`), skip the selection menu entirely and work that artifact.
2. Prompts marked **[AUTO]** below resolve to their stated default. Take it and move on.
3. Prompts marked **[GATE]** below must never be guessed. Park the work instead:
   ```bash
   scripts/wf-exec.sh wf-gate-open.sh <ID> <gate-name> "<question>" --context <path> --skill wf-spec
   ```
   Then **exit cleanly** without changing REGISTRY state. The dispatcher skips gated artifacts; `/wf-attend` will bring a human to it.
4. **Never guess.** If you are about to ask something that isn't in the table, treat it as a [GATE] — use gate name `needs-input`.

| Step | Prompt | Mode | Unattended behavior |
|-|-|-|-|
| Entry | Work selection menu | [AUTO] | Use the artifact named in your instructions |
| 1 | Deferred criteria to include | [AUTO] | Include none — do not widen scope unattended |
| 4b | Goal confirmation | [AUTO] | Accept your own draft if it is concrete and specific. If you cannot write a concrete goal from the source artifact, [GATE] `goal-missing` |
| 4c | Tag assignment | [AUTO] | Assign from `wf-list-tags.sh` based on slug, goal, and touched paths |
| 7c | Auto-test promotion (y/n) | [AUTO] | **Yes** — promote. Maximizing automation is the standing direction; this overrides "never auto-promote" in step 7c |
| Review gate | Plan approval | **[GATE]** or [AUTO] | Depends on `specApproval.mode` — see below |
| 6a (replan) | An amendment narrows the Goal | **[GATE]** | `scope-reduction` — always, whatever the verdict and whatever the mode |

### The review gate

Read the mode before you exit — do not assume either behavior:

```bash
SPEC_MODE=$(scripts/wf-exec.sh wf-config-get.sh specApproval.mode gate)
MAX_ROUNDS=$(scripts/wf-exec.sh wf-config-get.sh specApproval.maxReviewRounds 3)
GATE_TAGS=$(scripts/wf-exec.sh wf-config-get.sh specApproval.gateTags --list)
```

**`gate` (default)** — the hard stop on *approval*. A spec may be written unattended; it may not be **approved** unattended. Park as `spec-approval` and exit.

**`verdict`** — **the verdict is the gate**, not the plan's existence. An approved plan goes to `ready` with no human.

**`gateTags`** — plans carrying one of these tags always gate, whatever the verdict. The escape hatch, and not overridable.

**The review itself runs unattended in all three cases.** It is a read-only analysis that decides nothing; what differs is what its verdict is *allowed to do*. Every unattended exit goes through [Exit — unattended](#exit--unattended).

That ordering was once the other way around, and the tag path parked the plan *before* any review ran. Two consequences, both measured in a single drain: a tagged plan got **less** automated scrutiny than an untagged one and sat idle waiting for a human to commission a review a machine could have run immediately (one waited 3h20m unreviewed); and the human was handed approvable and unapprovable plans identically, so two of four gates were consumed only to end at `draft` with findings — exactly where an unattended Blocked verdict routes them anyway. A Blocked verdict needs no human. An Approved one is the only thing worth interrupting for.

Why the second mode exists, so you can judge whether the run in front of you fits it: in a measured 16-plan program the review found Critical findings in **8 of 8** plans drained with a human present. Not one was approvable as drafted, so the human's decision was never *"is this good?"* — it was always *"proceed with the fix loop the reviewer just specified."* The gate sat in front of the mechanism that does the filtering, admitting everything to a step that then rejected everything. Total human input across those 8 gates: the word "approve", then the word "all".

What that mode costs, stated plainly: some Criticals are found by *cross-plan* reasoning a per-plan reviewer cannot reach, and were caught only because a human skimming a queue of 15 plans noticed a contradiction. The [cross-plan consistency pass](#cross-plan-consistency) is the compensating control. If it is disabled, `verdict` mode is running without a safety net.

## IMMEDIATE STARTUP — run in parallel before reading further

1. Run branch check (do not prompt the user):
   ```bash
   scripts/wf-exec.sh wf-branch-check.sh develop true
   ```

   **Exit 2 means the check refused to switch.** Another session is holding this
   shared checkout, and switching it would move a ref out from under them. Two
   cases, both refused:

   - parked on a branch the pipeline does not own — how four commits for one
     plan landed on a human's topic branch (WFI-123);
   - parked on `release` or `main` — a `/wf-release` or `/wf-deploy` is running.
     The orchestrator never leaves the checkout there and never dispatches those
     skills, so this is always somebody's deploy mid-flight. Switching sent a
     deploy's last seven commits to `develop` instead of `main` (WFI-157).

   Stop — do not `git checkout` past it. Under `WF_UNATTENDED=1` exit 0 without
   claiming anything; the dispatcher offers the work again once the checkout is
   back on develop.

2. Spawn a **haiku subagent** to fetch and format the worklist:

```
Agent(model: haiku, prompt: "Run `scripts/wf-exec.sh wf-list-specable.sh` in the current directory.
Parse the tab-separated output (sections: # replanning, # bugs, # briefs).

Format as TWO markdown tables:

**Table 1 — Available work** (actionable items with sequential numbering):
| # | Priority | Type | ID | Name | Detail |
|-|-|-|-|-|-|
- Replans: the third tab field is priority (show it). Type = Replan.
- Bugs: priority = '—', second field = severity, third = title. Type = Bug.
- Briefs: priority = '—', second field = name, third = description. Type = Brief.
  If a brief's detail says 'Already has plan PLN-NNN', put it in Table 2 instead.

**Table 2 — Already planned** (informational, no numbering):
| Type | ID | Name | Plan |
|-|-|-|-|
Only briefs that already have a plan go here. Omit this table if empty.

After the tables add: Mark a plan urgent: \`u <number>\` (replans only)

If no actionable items, say 'No specable work found.'

Final response: ONLY the formatted tables and footer line. No commentary.")
```

Display the subagent's output verbatim, then tell the user: "Run `/model opus`, then pick a number or describe new work."

**Handling `u <N>` commands:**
If the user types `u <N>` for a replan: run `scripts/wf-exec.sh wf-set-priority.sh <plan-id> urgent`, then re-run the haiku subagent above to re-display the updated menu.
If the user types `u <N>` for an already-urgent replan: run `scripts/wf-exec.sh wf-set-priority.sh <plan-id> —` to clear it, then re-run the subagent.

**Claim whatever they pick, before you read it** — the same rule as unattended rule 0, and it is not a mode-specific rule (see [Claiming](#claiming)):

- If they pick an escalated plan: `scripts/wf-exec.sh wf-claim.sh PLN-NNN-<slug>`, then go to [Replanning](#replanning)
- If they pick a bug: `scripts/wf-exec.sh wf-claim.sh BUG-NNN`, then go to [Plan from bug](#plan-from-bug)
- If they pick a brief: `scripts/wf-exec.sh wf-claim.sh BRF-NNN`, then go to step 1 below (Read the brief)
- If they describe new work: ask if it should become a brief first (route to `/wf-brainstorm`)

## Claiming

**Claim the artifact before you read anything, in both modes, by whatever ID you were handed — whether or not a plan folder exists yet.** Claims key on the artifact *number*, so `BRF-002` and the `PLN-002` it becomes are one claim (v5.6; before that, claiming a brief failed with "plan directory not found" — client-c WFI-004).

```bash
scripts/wf-exec.sh wf-claim.sh PLN-NNN-<slug>   # a plan
scripts/wf-exec.sh wf-claim.sh BRF-NNN          # a brief, no plan folder yet
scripts/wf-exec.sh wf-claim.sh BUG-NNN          # a bug, likewise
```

This lived inside the unattended section, and the attended menu claimed on one path out of three — the escalated-plan path. So an attended session creating a plan from a bug wrote `plans/PLN-NNN-<slug>/` and committed a `draft` REGISTRY row while holding no claim at all. **A draft row is dispatchable the moment it is committed, whichever mode wrote it:** client-a's daemon put three unattended wf-spec workers onto PLN-048/049/050 within ~3 minutes of an attended session committing their rows, both sessions then edited the same `plan.md` files, and the attended one saw the workers' edits only as unexplained "modified by a linter" notices. One worker finished and set a plan `ready`; two died leaving stale claims (WFI-130). Nothing was lost that time.

The claim is what makes the artifact yours to write. Take it first.

**A claim can be refused, and a refusal is an answer — not an error to work around.** `wf-claim.sh` exits **2** when a live session already holds the artifact, with or without `--if-free`. Stop and tell the user who holds it; pick something else. Until v6.6 the bare form silently overwrote a live claim, so an attended session took PLN-059 out from under an unattended test worker that was mid-run and said nothing (client-a WFI-146). If the holder is genuinely finished or wedged, take it deliberately — `wf-claim.sh <artifact> --steal` — and never by deleting the claim file by hand.

---

## ID Inheritance

Plans inherit their number from the source artifact — no new counter allocation.

- **From brief BRF-041** → plan becomes **PLN-041**
- **From bug BUG-043** → plan becomes **PLN-043**

Do not derive the ID by hand and do not call `wf-counter-next.sh` yourself. Ask:

```bash
eval "$(scripts/wf-exec.sh wf-plan-id.sh BRF-041)"
# → PLAN_ID, PLAN_NUM, PLAN_ID_INHERITED, PLAN_ID_COLLISION, PLAN_ID_RESUME, PLAN_ID_DIR
```

`PLAN_ID_INHERITED=true` is the ordinary case: the number was free and the plan keeps it.

**Ask again immediately before you create the folder (step 5).** The answer describes the registry and `plans/` at the instant it was given, and step 3 is minutes of exploration, drafting and user confirmation away from step 5. client-a's WFI-147: two sessions on BUG-075 both got `PLN-075, COLLISION=, RESUME=false` seconds apart — both answers correct — and both drafted a plan under that number with different slugs. The duplicate was written and committed before `wf-registry-add.sh` refused the second row, which is the only backstop there is and it fires last. The second call is cheap, and it has seen the other session's work.

**`PLAN_ID_RESUME=true` means the folder already there is yours** — an earlier attempt at this same artifact wrote it and did not finish. `PLAN_ID_DIR` is the folder: read what is in it, keep what is still right, and continue. Do **not** create a second folder and do not treat it as a collision.

**A resume does not always carry the inherited number.** `PLAN_ID_RESUME=true` together with `PLAN_ID_INHERITED=false` means the earlier attempt had itself collided and wrote under a *reallocated* number. **Use `$PLAN_ID`** — never the source artifact's own number — for the folder, the row, the branch and every commit message. client-a's WFI-162: BRF-081's first attempt wrote `plans/PLN-101-headless-support-bundle/`, and the resume check only ever looked under `plans/PLN-081-*`, so the next dispatch found nothing, allocated PLN-102, and burned a counter increment on a plan that must never exist. Every re-dispatch would have burned another, and a run driven by the brief ID alone would have created the duplicate.

If `PLAN_ID_COLLISION` says `DUPLICATE PLANS FOR <id>`, **two folders both name this artifact** — the script picked the lowest-numbered one so as not to make a third. That is a real duplicate and not yours to merge silently: continue in `$PLAN_ID_DIR`, and open a **[GATE]** `needs-input` naming both folders.

**Write into `$PLAN_ID_DIR`, not into the folder name you chose in step 2.** The earlier attempt picked its own slug, and it is rarely the one this run would pick — on WFI-147 the surviving folder was `PLN-075-test-poll-loops-fail-loudly` while the run in progress had chosen `PLN-075-enrolment-test-confirm-ordering`. The existing folder owns the REGISTRY row; a folder matching your slug would own nothing.

An unattended run dying mid-spec is ordinary — after writing and reviewing `plan.md` but before the REGISTRY row and the commit is the widest window it has. client-a's WFI-121 hit that window and the collision rule, read literally, would have produced a duplicate PLN-040 for one bug and orphaned the reviewed PLN-039. The check now distinguishes the two: a plan folder whose `plan.md` header names the artifact you are specced on is your own.

**`PLAN_ID_INHERITED=false` means the inherited number was already taken** — by another plan's REGISTRY row, its folder, or both — and the script allocated a fresh number instead. `PLAN_ID_COLLISION` names what held it. Use `$PLAN_ID` and say so in the plan's Context line:

```markdown
> Source: BRF-091. Plan ID PLN-100 — PLN-091 was taken by folder plans/PLN-091-otlp-exporter-cve.
```

Never resolve a collision by writing into the existing plan's folder or row. client-e hit exactly this (WFI-011): the rule forbade the counter, gave no collision procedure, and left overwriting a completed plan as the only move that followed the documented instructions.

## Plan from bug

If the user picks a bug BUG-NNN:

1. **Read the bug** — read `bugs/open/BUG-NNN-<slug>/bug.md`
2. **Inherit the plan ID** — BUG-NNN becomes PLN-NNN via `wf-plan-id.sh` (see [ID Inheritance](#id-inheritance))
3. **Use it as context** — the bug's description, steps, and expected behavior become the plan's Goal and acceptance criteria
4. **Choose a feature name** — a short kebab-case slug describing the fix (e.g. `login-crash`, `webhook-timeout`)
5. **Construct the plan folder name** — `PLN-NNN-<slug>` (e.g. `PLN-003-login-crash`)
6. **Treat it like a brief** — proceed as normal, but the scope is defined by fixing the bug
7. The bug consumption happens in the [Bug consumption](#bug-consumption) section below

## What you do

1. **Read the input** — if from a brief: read the relevant brief in `plans/briefs/`; if from a bug: the bug's `bug.md` becomes the scope definition
1a. **Check deferred criteria** — list the open ones:
    ```bash
    scripts/wf-exec.sh wf-defer-criterion.sh --list
    ```
    Output is tab-separated: `DC-NNN <TAB> criterion <TAB> tag <TAB> from-plan <TAB> prereq`. These are `external` / `soak` criteria whose original plan shipped without them (step 8 defines the tags). Show any whose prereq is this plan's ID, or whose criterion touches the surface you are planning:
    ```
    Found N deferred criterion/criteria that may apply to this plan:
    | # | Criterion | Tag | From |
    |-|-|-|-|
    | DC-001 | <text> | external | PLN-009 |
    ```
    Ask: "Include any of these in the acceptance criteria? (Enter numbers, or press enter to skip.)" — under `WF_UNATTENDED=1` this is [AUTO] include-none, per the unattended table.
    For each included: add it to the plan's `#### Manual` section **carrying its original tag**, then mark it consumed:
    ```bash
    scripts/wf-exec.sh wf-defer-criterion.sh --consume DC-001 PLN-NNN
    ```
    Do not delete rows by hand — the consumed row is the record that the criterion was picked up rather than dropped.

    If the user says one of these is **already true** — the deploy ran, the credentials arrived, the soak time passed — that is not a consumption, it is a satisfaction, and it has its own verb:
    ```bash
    scripts/wf-exec.sh wf-defer-criterion.sh --satisfy DC-001 --evidence "<what proved it>"
    ```
    Recording it as `consumed by` this plan instead would make this plan owe a check it is not going to make (WFI-148).

    If the user says a row is **right but incomplete** — it needs a precondition stated, or a qualification the original author did not know — that is neither ending. Amend the text and keep the ID, which is what any other plan or issue already cites:
    ```bash
    scripts/wf-exec.sh wf-defer-criterion.sh --amend DC-001 --criterion "<corrected text>"
    ```
2. **Choose a feature name** — a short kebab-case slug describing the work (e.g. `user-auth`, `payment-webhook`, `login-crash`)
3. **Inherit the plan ID** — `eval "$(scripts/wf-exec.sh wf-plan-id.sh <SRC-ID>)"` and use `$PLAN_ID` (see [ID Inheritance](#id-inheritance)). Do not derive it by hand and do not call `wf-counter-next.sh`. This answer is provisional until step 5 re-asks.
4. **Explore the codebase** — spawn **haiku agents** to find existing patterns, file structures, and signatures you need to reference in the plan. Keep agents focused: one per question, output under 2000 characters.
4b. **Draft the one-liner goal** — before creating any files, write a single sentence describing what this plan achieves and show it to the user:
    ```
    Goal: <one-line summary>
    Confirm or edit?
    ```
    Do not proceed to step 4c until the user confirms or provides a revised goal. This line will be extracted by scripts (`wf-plan-info.sh`) and displayed in `wf-implement`, `wf-test`, and PR descriptions — it must be concrete, not a placeholder.
4c. **Assign tags** — after the goal is confirmed, read **this project's** vocabulary. Do not offer a list from memory:
    ```bash
    scripts/wf-exec.sh wf-list-tags.sh
    ```
    Output is `tag <TAB> plans carrying it <TAB> gate`, most-used first. The third column is the one that matters: a tag marked `gate` is listed in `specApproval.gateTags`, so assigning it decides that this plan will stop for a human.
    ```
    Tags (comma-separated): <the tags listed, gating ones marked *>
    Current: <suggested based on slug/goal>
    Confirm or edit?
    ```
    Suggest from the listed tags — reuse the project's own words rather than inventing a synonym for one it already has. A genuinely new tag is allowed and `wf-set-tags.sh` will take it; it just gets a warning so a typo does not become a second vocabulary.

    This list used to be a hardcoded `security, arcade, admin, lessons, ux, infra, e2e, bugfix` — one project's game/admin/lessons vocabulary, shipped to everyone. Elsewhere it named tags that meant nothing and omitted the one tag the project actually gated on, which is the failure that matters: an allowlist that looks authoritative, isn't, and sits directly in front of a gating decision.
5. **Re-ask for the ID, then create the plan folder.** The ID from step 3 is stale by now — ask again, in the same call that creates the folder:
   ```bash
   eval "$(scripts/wf-exec.sh wf-plan-id.sh <SRC-ID>)"
   ```
   - `PLAN_ID_RESUME=true` — another session (or an earlier attempt of yours) created the folder while you were drafting. **Continue in `$PLAN_ID_DIR`**, whatever slug it carries, and under whatever number `$PLAN_ID` names — a resume folder may sit under a reallocated number (WFI-162). Fold anything you drafted into what is there. Do not create a second folder.
   - `PLAN_ID_INHERITED=false` — the number was taken while you were drafting. Use the reallocated `$PLAN_ID` and record `$PLAN_ID_COLLISION` in the Context line.
   - Otherwise nothing moved: create `plans/$PLAN_ID-<slug>/` as planned.

   Then write three files following `plans/TEMPLATE.md`:
   - Folder is always `plans/PLN-NNN-<slug>/` (e.g. `plans/PLN-041-user-auth/`)
   - In `plan.md`, fill in `> **ID:** PLN-NNN` and `> **schema_version:** 6`
   - **Goal** — use the confirmed one-liner from step 4b as the first line under `## Goal`. Follow with an optional context paragraph.
   - `plan.md` — goal, steps, tests, checklist, design decisions, out of scope
   - `findings.md` — empty (no table header needed — findings are appended as flat checklists)
   - `progress.md` — step list (copied from plan steps), empty log

5a. **Commit the folder as soon as it is written** — before the review gate, not after:
   ```bash
   scripts/wf-exec.sh wf-commit.sh "spec(PLN-NNN-<slug>): plan drafted" \
     --add plans/PLN-NNN-<slug>/ --branch develop
   ```
   Then, for a new plan, add its REGISTRY row — **here, not at exit**:
   ```bash
   scripts/wf-exec.sh wf-registry-add.sh PLN-NNN <slug> --tags "<tags from step 4c>"
   ```
   It stamps the WF column from `.claude/workflow-version` so the dispatcher routes the plan to the matching script snapshot, refuses a second row for an ID that already has one, and commits the row itself, under the registry lock.

   **Never hand-edit the table instead.** A row appended by hand sits dirty on the shared develop checkout until this skill's own exit commit — the far side of the whole review loop — and on develop that does not survive: client-a's PLN-060 draft row was carried off by a concurrent implement worker's correctly-pathspecced `implement(PLN-055-…): verified, moved to verify` commit. Pathspec discipline cannot defend against it, because both workers legitimately name `plans/REGISTRY.md` and whoever commits first takes the other's uncommitted rows out of the same file (WFI-140). The fix is not a better pathspec; it is not being dirty for that long.

   The plan stays `draft`; this commits the document, not the decision. No REGISTRY row moves and nothing downstream can pick the plan up.

   **Why not wait for the exit commit.** Between here and the exit commit sits the whole review loop, and until v6.3.1 the new files spent all of it *staged on the shared develop index*. Anyone else's commit sweeps that index. client-a's WFI-122: PLN-039's reviewed `plan.md` was committed by an unrelated `test(PLN-038-…): complete` merge, so the spec commit that approved it carried only `findings.md`, `progress.md` and `REGISTRY.md`, and `git log -- plans/PLN-039-…/plan.md` names a different plan's test run. No pathspec on the spec side defends against a merge; the only fix is to not be staged for that long. Same reasoning as `wf-bug-consume.sh` committing rather than staging (WFI-106, WFI-112).

   If the run dies after this point, the folder is in history and the next dispatch resumes it — see [ID Inheritance](#id-inheritance) and `PLAN_ID_RESUME`.
6. **Specify everything** — every step must include:
   - Exact file paths to create or modify
   - Class/method/component names and signatures
   - Acceptance criteria (test command, observable behavior)
7. **Define tests** — fill in the Tests table with specific test IDs, types, descriptions, and commands.

   **Get the command shape from the config, not from memory or from the template.** Run:

   ```bash
   scripts/wf-exec.sh wf-config-get.sh test_command
   scripts/wf-exec.sh wf-config-get.sh test_filter_flag
   ```

   and build every command as `<test_command> <test_filter_flag> <name>`. Do not write a filter expression from your own knowledge of the runner. `--filter "FullyQualifiedName~X"` is **VSTest** syntax; a .NET project on Microsoft.Testing.Platform (xUnit v3, `dotnet test --solution`) rejects it with `Unknown option --filter`, exit code 5, **zero tests run** — and a verify agent reading only the exit code fails a perfectly good plan. client-a's PLN-018 shipped a Tests table where every row failed that way (WFI-055); its config said `--ignore-exit-code 8 --filter-method` the whole time.

   `plans/TEMPLATE.md` is not a second opinion here. Its example was rendered from the config **when the harness was first installed** and is never re-rendered, so on any project whose runner changed since, the template's example is the stale one and the config is right.

   **Write commands the implementer's host actually has.** A test command runs on whatever machine picks the plan up, and the GNU coreutils a Linux CI image ships are not on a stock macOS host. `timeout` is the one that bites — client-a's PLN-043 specified `timeout 30 dotnet run …` and the implementer hit `command not found: timeout` (WFI-127), then had to reproduce the cap with a background job and a sleep-then-kill watcher before the test could run at all. Same for `gtimeout`, `realpath`, `sha256sum`, `sed -i` without a backup suffix, and `date -d`. Prefer the runner's own facilities (a test-level timeout attribute, `dotnet test --blame-hang-timeout`) or plain shell; if a coreutils binary is genuinely required, say so in the plan's Design Decisions so the implementer installs it rather than improvising.

   **Maximize automation:** API responses, data correctness, markup structure, auth gates, redirects, and status codes are all automatable (unit tests, integration tests, curl commands, scripts). Only use `Manual` type for things that genuinely require human eyes — visual rendering, subjective UX, complex multi-step physical interactions.

   **Default-automated patterns** — past plans have repeatedly shipped these classes of criteria as automated tests (see `plans/auto-test-log.md` Realized section for proofs). If a criterion you're drafting fits one of these shapes, put it in the Tests table (not Human Test Criteria) from the start:

   | Pattern | Example criterion | Test shape |
   |-|-|-|
   | Cookie attributes on a response | "PwdResetHandoff cookie is HttpOnly, Secure, SameSite=Lax, ~15m expiry" | Unit test asserting `Set-Cookie` header flags |
   | HTML meta tag presence/absence | "No Referer meta tag on /account/reset-password" | Response inspection / static HTML assertion |
   | "No console errors" / "no X log entries" | "No Authorization failed entries on /apps/lessons load" | Auth layout absence test, or log capture assertion |
   | Form validation → specific status code | "POST invalid LessonLength returns 400" | Integration test on the endpoint |
   | Route redirect by auth state | "Unauthenticated /apps/lessons → /login" | Integration test asserting 302 + Location |
   | Dialog open / close / field presence | "Clicking CREATE USER opens dialog with Roles field visible" | E2E / component test |
   | Admin table filter / pagination / layout | "Filter by GameType shows only matching rows" | Service test + DOM/E2E assertion |
   | Element presence on direct URL vs client nav | "Footer shows build date on direct load AND after client-side nav" | Two E2E tests, one per entry mode |

   Only escape to Human Test Criteria when the check genuinely requires human judgment (subjective animation feel, visual polish, cross-device ergonomics).
7a. **Fill `## E2E Scope`** — list the e2e test file paths or glob patterns that cover this plan's changes (one per line, no backticks). If the project has a single flat e2e directory and there are no dedicated per-feature files yet, leave the section blank — wf-test will fall back to the full suite. Only populate this if you can identify specific test files that exercise the affected routes or behaviors.
7b. **Fill `## Test Scope`** — list category names (one per bullet) the planner knows are relevant. Leave blank only if the change truly affects nothing testable (e.g., doc-only). Prefer declaring generously; auto-detect unions in more categories at verify time. Valid category names live in `claude-workflow.yml → testScopes`.
7c. **Consult the auto-test log** — if `plans/auto-test-log.md` exists, read its `### Realized` section. Those rows prove what shape of criterion past plans successfully converted to automated tests at `/wf-test` time. **Before citing a row, verify the referenced test file still exists** (`test -f <File column>`) — rolled-back plans may leave stale rows. For each criterion you're drafting, ask: *does any live Realized row describe a similar intent* (e.g., "redirects after valid login", "button disables while submitting", "validation error shows on empty field")? If yes, flag it to the user before proceeding to step 8:
    ```
    Automation opportunity: criterion "<text>" resembles past realized auto-tests:
      - PLN-NNN "<prior criterion>" → <test name> (<file>)
    Consider classifying this as automated (Tests table + Build & Tests checklist)
    instead of Human Test Criteria. Promote? (y/n)
    ```
    If yes, add the test to the Tests table (step 7) and skip adding it under Human Test Criteria. If no, proceed normally. **Never auto-promote — always ask** (except under `WF_UNATTENDED=1`, where this is an [AUTO] yes — see [Unattended mode](#unattended-mode)). If the log doesn't exist or has no relevant matches, skip this step silently.
8. **Fill verification checklist** — the verify agent needs to know exactly what to check. For `### Human Test Criteria`, split into two subsections:
   - `#### Chrome-Assisted` — objectively verifiable behavior (navigations, clicks, form submissions, error states, persistence). Each criterion starts with a route: `- [ ] /login — redirects to /dashboard after valid credentials`
   - `#### Manual` — checks no machine can make. **Every one carries a reason tag, written first on the line.** Exactly four tags are legal:

   ```markdown
   #### Manual
   - [ ] (eyes:blocking) /app/time — the timer is usable one-handed on a phone
   - [ ] (eyes:cosmetic) /app/board — column spacing is even at 1280px
   - [ ] (external) tool ticket pull <real id> — every image visible in the DevOps web UI is present
   - [ ] (soak) tool work — the Stalled section surfaces something genuinely forgotten
   ```

   | Tag | Means | On failure |
   |-|-|-|
   | `eyes:blocking` | Subjective judgment about whether the user can complete the task at all | Findings written, plan routes to `active` |
   | `eyes:cosmetic` | Subjective judgment about layout, spacing, copy tone, animation feel | Files a `BUG-NNN`, criterion checks off, plan completes |
   | `external` | Needs a real third-party system, real credentials, or a physical act | Deferred to `plans/deferred-criteria.md` |
   | `soak` | Needs real elapsed calendar time | Deferred to `plans/deferred-criteria.md` |

   **A criterion that fits none of the four is misclassified — it belongs in the Tests table.** `wf-verify` lints this mechanically (`wf-manual-lint.sh`); an untagged criterion, an unknown tag, or an assertable verb under an `eyes:*` tag fails the plan back to `draft`. Writing a criterion here is no longer cheaper than writing a real test.

   Grade your own wording before you commit it:

   | Belongs in the Tests table | Belongs under `eyes:*` |
   |-|-|
   | is refused, returns, contains, exists, is empty, is absent, stops for, prints, matches, resolves, redirects, exits | reads well, is legible, feels, is usable, is interpretable at a glance, reads naturally, genuinely useful |

   Watch for **security** assertions in particular. *"Pasting a fake token results in a refusal, not a publication"* is a redaction test and probably the highest-value test in its plan — parked under `#### Manual` it runs once and never again.

   Honest caveat, worth one line in the plan when it applies: an assertion can pass while the criterion fails. *"Refused with a message naming the file"* is satisfied by a message that names the file and is otherwise incomprehensible. Automating that trades a rare deep check for a permanent shallow one. Take the trade — but state it rather than letting it happen by accident.
9. **Make all design decisions** — the implementer should not need to make judgment calls
10. **Write the rollback plan** — fill in `## Rollback` in `plan.md`:
    - List specific trigger conditions (don't leave as TBD)
    - Assess data migration reversibility honestly — if irreversible, say so explicitly
    - Write exact rollback commands, not general descriptions
    - Add verification steps to confirm the rollback succeeded
11. **Update the brief (if from brief)** — set status to `Planned`, add the plan folder link; update `plans/briefs/INDEX.md`
12. **Consume the bug (if from bug)** — see [Bug consumption](#bug-consumption) below

## Codebase exploration via agents

When you need to understand existing code, spawn haiku agents rather than reading everything yourself:

```
Agent(model: haiku, prompt: "Find all [component type] in [directory]. 
List each file, its purpose, and public interface. 
Final response under 1000 characters.")
```

Good agent tasks:
- "List all files in [directory] with their purpose"
- "Find where [class/interface] is defined and list its public members"
- "What patterns are used in [file]?"

Bad agent tasks (do these yourself):
- Design decisions
- Writing plan steps
- Anything requiring the full brief context

---

## Exit (complex) — Review Gate

**Self-lint first, always.** Before committing anything, run the same check the verify agent will run:

```bash
scripts/wf-exec.sh wf-manual-lint.sh PLN-NNN --file plans/PLN-NNN-<slug>/plan.md
```

Fix every line it prints — add the missing tag, pick a disposition, or move the criterion into the Tests table — and re-run until it exits 0. Catching it here costs one edit; catching it at verify costs a full round trip through `draft`.

**Under `WF_UNATTENDED=1` → [Exit — unattended](#exit--unattended).** Every unattended path runs the review first; `specApproval.mode` and `gateTags` decide what happens *after* it, not whether it happens. Do not branch here.

The rest of this section is the **attended** path — a human is at the terminal.

When the user approves the plan (says "looks good", "approved", "ready", etc.):

1. **Goal gate** — verify that the first line under `## Goal` in `plan.md` is a concrete one-line summary (not empty, not template placeholder text). If missing or placeholder, ask the user for a one-line goal, write it as the first line under `## Goal` (before any paragraph), and stage the file.

2. **Spawn a sonnet agent** to run the architectural and security review:

```
Agent(model: sonnet, prompt: "You are a code reviewer. Read plans/PLN-NNN-[name]/plan.md 
and evaluate against: architecture (project patterns, dependency direction), 
security (auth on endpoints, input sanitization, no hardcoded secrets), 
performance (no unbounded queries, N+1 patterns), 
maintainability (scope matches goal, test coverage),
rollback (trigger conditions defined, safety assessment complete, steps are specific commands not descriptions, irreversible migrations called out explicitly).

Write your findings in this format:
Result: Approved | Approved with notes | Blocked
Then a table: | # | Severity | Category | Finding | Recommendation |
Severity: Critical (blocks), Warning (should fix), Note (informational).
Final response under 2000 characters.")
```

3. **Process the review result:**
   - **Critical findings:** do NOT move to `ready`. Present findings to the user, revise the plan, and re-review.
   - **Warnings only:** present to the user for acknowledgement.
   - **Clean or Notes only:** proceed to state transition.
4. **Write the review result** to `plan.md`'s `## Review` section

5. **State transition and commit, in one step:**
   ```bash
   # Commit ONLY these paths. On develop the index is shared with other
   # unattended workers, and a bare `git commit` takes whatever they have
   # staged — or theirs takes yours (WFI-048/049).
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN draft ready \
     --commit "spec: PLN-NNN-<slug> — plan ready" \
     --add plans/PLN-NNN-<slug>/ plans/deferred-criteria.md \
     <the brief and bug paths this plan actually consumed — see below>
   ```

   **Name the artifacts, not their directories.** `bugs/` and `plans/briefs/` are as broad as `git commit -a` over those trees: they sweep in whatever another worker left dirty there. client-a's WFI-087 watched a `bugs/` pathspec carry a different worker's uncommitted BUG-027 closure into a PLN-028 spec commit — correct content, filed in history under a message about an unrelated plan, which is exactly the auditability the pathspec rule exists to protect. You know both IDs at this point, so name them:

   | Consumed | Add |
   |-|-|
   | a brief | `plans/briefs/INDEX.md plans/briefs/BRF-NNN-<slug>.md` |
   | a bug | `bugs/open/BUG-NNN-<slug>/ bugs/triaged/BUG-NNN-<slug>/` (both sides — the consume is a rename, and a rename is two paths). Usually already committed by `wf-bug-consume.sh` itself, in which case these add nothing and cost nothing; name them anyway, for the `--no-commit` case |
   | neither | nothing extra |
   The row and the plan it describes land together. Transitioning first and committing the plan afterwards leaves a window where the registry advertises a `ready` plan whose approved content is not in history yet.

6. **Release the claim — last:**
   ```bash
   scripts/wf-exec.sh wf-unclaim.sh PLN-NNN-<slug>
   ```
   **After step 5, never before it.** The claim is what keeps the dispatcher off this plan; dropped while the row still reads `draft`, a sweep landing in that window launches a second spec worker onto the plan you just approved (client-a WFI-079 is the same race one state further down the pipeline).

   Then run `scripts/wf-exec.sh wf-check-reboot-flag.sh` and append any output after your completion message.

A new plan's REGISTRY row is **not** added here — `wf-registry-add.sh` wrote and committed it back at step 5a, as `draft`, before the review loop began (WFI-140). What this exit does with it is the transition, through `wf-registry-update.sh`, exactly like every other state change:

```
| PLN-NNN | <slug> | draft | — | — | YYYY-MM-DD | <WF> | <tags> | — |
```

Columns, for reading the table: `ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps`.

---

## Exit — unattended

**The review always runs. Nothing here skips it.** What changes is what an *Approved* verdict is allowed to do:

| The plan | Approved / Approved-with-notes | Blocked |
|-|-|-|
| `mode: verdict`, no gating tag | `draft → ready` — no gate, no human | fix, re-review, up to `maxReviewRounds` |
| carries a `specApproval.gateTags` tag | **[GATE]** `spec-approval`, with the review attached | same fix loop |
| `mode: gate` (the default) | **[GATE]** `spec-approval`, with the review attached | same fix loop |

```
draft → review → ┬─ Approved ─┬─ needs a gate ─→ [GATE: spec-approval] (state stays draft)
                 │            └─ otherwise ────→ ready
                 ├─ Blocked, round ≤ N ────────→ fix → re-review
                 └─ Blocked, round > N ────────→ [GATE: spec-stuck]
```

**Read the fix loop as identical across all three rows, because it is.** A Blocked plan does not need a human under any mode — it needs the fix the reviewer just specified, and verdict mode's route (revise, re-review, and land at `draft` with findings if it never converges) is the conservative outcome in every mode. Gating before the review inverts that: it spends a human on the plans a machine could have resolved, and spends them *identically* on the ones it could not.

1. **Goal gate** — the first line under `## Goal` must be a concrete one-liner. If you cannot write one from the source artifact, **[GATE]** `goal-missing`. Never invent a goal to get past this.

2. **Run the review** — the same sonnet agent as the attended flow, verbatim. This is round 1.

3. **Route on `Result:`**
   - **Approved** / **Approved with notes** → record the verdict, then go to step 6.
   - **Blocked** (or any Critical finding) → revise the plan against the findings, then re-review. Each re-review is one more round.

4. **Round ceiling** — stop after `specApproval.maxReviewRounds` (default 3). A plan still Blocked past that has a problem the reviewer cannot articulate, which is exactly when a human is worth interrupting:
   ```bash
   scripts/wf-exec.sh wf-gate-open.sh PLN-NNN spec-stuck \
     "Blocked after N review rounds. Unresolved: <the reviewer's remaining Criticals, one line>" \
     --context plans/PLN-NNN-<slug>/plan.md --skill wf-spec
   ```
   Commit the plan as it stands first (state stays `draft`), then exit 0. Do **not** advance a plan the reviewer is still blocking, and do **not** keep looping past the ceiling.

5. **Write every round to `## Review`** — an unattended approval has to be auditable after the fact, so the record is not optional and not summarized:
   ```markdown
   > **2026-08-01 — Plan Review (unattended, round 2 of 3)**
   > **Result:** Approved with notes
   > **Rounds:** 2 — round 1 Blocked (3 Critical), fixed in-place, round 2 clear
   > | # | Severity | Category | Finding | Recommendation |
   > |-|-|-|-|-|
   ```

   Then stamp it, so the record says which text was judged rather than only when, and **commit the review before you do anything else**:
   ```bash
   scripts/wf-exec.sh wf-review-stamp.sh PLN-NNN --no-commit
   scripts/wf-exec.sh wf-commit.sh "spec(PLN-NNN-<slug>): reviewed — <verdict>, round N" \
     --add plans/PLN-NNN-<slug>/
   ```
   Stamp after the **last** write to `plan.md`. Anything you change afterwards makes the verdict stale — correctly, and now detectably. `--no-commit` on the stamp is still right: it must not commit itself, because the commit that carries it should name the verdict, not the stamp (WFI-085). What changed is who commits it — this step, immediately, not step 6.

   **A review left staged does not survive the turn.** It used to sit in the index until step 6 committed it, and the develop checkout is shared: client-a's WFI-164 had a concurrent `/wf-test` run `wf-stash.sh push` the whole working tree — plan.md included — in the seconds between. Step 6's transition then found nothing to stage, reported `committed 1 path(s)`, and published a row reading `ready` over a plan.md carrying the bare template placeholder. Two rounds of review existed nowhere in history. Committing here closes the window; `wf-registry-update.sh` refuses `draft → ready` without a review of record, so a lost one now stops the transition instead of decorating it.

   Step 6 still lists the plan folder in its own pathspec. With the review already committed that add is a no-op, which is the intended outcome — and if it is *not* a no-op, something wrote to the plan after the verdict and the stamp is telling you so.

6. **Route the approved plan.** Read the mode and the gating tags — don't assume either:
   ```bash
   SPEC_MODE=$(scripts/wf-exec.sh wf-config-get.sh specApproval.mode gate)
   GATE_TAGS=$(scripts/wf-exec.sh wf-list-tags.sh --gating)
   ```

   **First, has this gate already been answered?** The rule below is re-derived on every dispatch, and a closed gate looks exactly like one that was never opened — so a plan approved by a human re-gates on the next pass, and the next, without end (WFI-047):
   ```bash
   eval "$(scripts/wf-exec.sh wf-gate-status.sh PLN-NNN spec-approval)"
   ```
   - `GATE_ANSWERED=true` → **do not gate.** The human already approved *this* revision. Honour the recorded `GATE_RESOLUTION`, transition `draft → ready`, and note in `## Review` that you acted on an existing approval.
   - `GATE_STALE=true` → the plan changed after the approval. Gate again: the approval was given to a document that no longer says what it said.
   - Otherwise → gate as below.

   **If the approval is provable but unrecorded, record it instead of re-asking.** A resolution that predates the ledger — or one a human gave in a commit message or in `findings.md` while the gate file was cleared some other way — reads here as `GATE_ANSWERED=false`, and following the rule then re-asks a question already answered in writing (WFI-060). When you can point at the evidence, back-fill it and proceed:
   ```bash
   scripts/wf-exec.sh wf-gate-close.sh PLN-NNN "approved by <who>, <commit-sha or file>" --gate spec-approval
   ```
   Only with evidence you have actually read. "Probably approved" is a gate.

   **Needs a gate** (`SPEC_MODE` is `gate`, or the plan carries a tag in `GATE_TAGS`) — commit the reviewed plan, leave the state at `draft`, park, and exit. The gate question carries the verdict, because the human is now deciding on a *reviewed* plan and should not have to open the file to learn that:
   ```bash
   scripts/wf-exec.sh wf-commit.sh "spec(PLN-NNN-<slug>): reviewed — Approved with notes, awaiting approval" --add plans/PLN-NNN-<slug>/ plans/REGISTRY.md
   scripts/wf-exec.sh wf-gate-open.sh PLN-NNN spec-approval \
     "<goal> — Review: Approved with notes (2 rounds, N Warnings). N steps, N automated tests, N manual criteria. Approve?" \
     --context plans/PLN-NNN-<slug>/plan.md --skill wf-spec
   ```
   Do **not** write the registry row's state as `ready`. `/wf-attend` closes it with a human, and the `## Review` section you just wrote is what they read.

   **Otherwise** — transition and commit in one step, the commit message naming the verdict, and release the claim only once that has landed:
   ```bash
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN draft ready \
     --commit "spec: PLN-NNN-<slug> — approved with notes (round 2), plan ready" \
     --add plans/PLN-NNN-<slug>/ plans/deferred-criteria.md \
     <the brief and bug paths this plan consumed — the table in the simple exit, step 5>
   scripts/wf-exec.sh wf-unclaim.sh PLN-NNN-<slug>
   ```
   Same ordering rule as the simple exit above: the transition commits, then the claim comes down. Never the reverse.

**Do not skip the review to save a round.** In `verdict` mode the verdict is the only thing standing between a draft and a builder; in the gating paths it is the only thing standing between a human and an hour of work a machine had already done.

---

## Replanning

When a plan in REGISTRY.md has state `draft` AND has unchecked items in its `findings.md`, it's a plan returned from verify or test that needs review. Findings come in two categories:

- **ESCALATED** (design) — require plan amendments and design decisions
- **Behavior** (code fix) — bugs found during human testing, routed here for Opus review before sending to builder

1. **Read `plan.md` and `findings.md`** from `plans/PLN-NNN-<slug>/` — understand the full plan and all findings
1b. **Push a sub-goal** — summarize the pending findings as the active goal. If any finding is a show-stopper (critical/ESCALATED), make it the focus of the goal. Run:
    ```bash
    scripts/wf-exec.sh wf-goal-push.sh PLN-NNN "<findings summary goal>" "<trigger description>"
    ```
    Example goal: "Fix show-stopper: auth bypass on /api/settings (+ 2 behavior findings)"
    Example trigger: "Verify: 3 findings (1 ESCALATED)"
2. **Triage findings:**
   - **ESCALATED findings** — present to the user and discuss how to resolve. Write amendments as needed.
   - **Behavior findings** — review each finding. Add implementation guidance to `findings.md` (append a line under the finding with context, root cause hints, or file pointers). If a behavior finding reveals a spec gap, write an amendment.
3. **Write an Amendment** (if needed) — append to `plan.md`'s **Amendments** section. Never rewrite Steps, Tests, or Design Decisions already there.
4. **Update Design Decisions** — add any new decisions to `plan.md`
5. **Address findings** — for each `ESCALATED` item in `findings.md`, check it off if resolved by the amendment. Leave behavior findings unchecked (T3 will handle them).
6. **Run the review gate** — same as above, on the plan **as amended**, and write the verdict to `plan.md`'s `## Review` like any other round.

   Two rules, both learned the hard way (WFI-046):

   - **The verdict goes in `plan.md` `## Review`. Never in `findings.md`.** findings.md takes the actionable items; it never takes the verdict, and never a `## Spec Review` heading. A verdict filed there leaves `## Review` holding the template placeholder, which every consumer reads as *never reviewed*.
   - **The last thing to happen before the gate is a review of the current text.** If you amend after the review — because the reviewer's own findings prompted the amendment, which is the common case — that verdict is now about a document that no longer exists. Review again.

     **The stamp comes later, at step 6c**, once every other write to `plan.md` has happened. Do not stamp here: steps 6a and 6b both write to the file, and a stamp taken before them is stale the moment they run.

   The failure this prevents is a quiet one: two plans reached the approval gate whose only verdicts were `Blocked` on their pre-amendment drafts. The amendments resolved every Critical, so the findings were all checked off and the plans looked finished — while the resolutions themselves had never been reviewed by anything.
6a. **Scope check — does this replan shrink what the plan promised?**
    ```bash
    scripts/wf-exec.sh wf-goal-delta.sh PLN-NNN
    ```
    Gate as `scope-reduction` if **either** is true:
    - `GOAL_STATUS: changed` and the new goal promises less than the original, **or**
    - any amendment you just wrote removes or qualifies a capability the `## Goal` one-liner names — even though the goal line itself is untouched.

    ```bash
    scripts/wf-exec.sh wf-gate-open.sh PLN-NNN scope-reduction \
      "Amendment <A-N> drops a capability the Goal promises.
       Goal: <the one-liner, verbatim>
       After: <what the plan will actually do>
       Reason: <the reviewer's or your own justification, one line>
       Proceed with the reduced scope?" \
      --context plans/PLN-NNN-<slug>/plan.md --skill wf-spec
    ```
    Stamp the verdict (`wf-review-stamp.sh PLN-NNN --no-commit`) as the last write, commit the amendment (state stays `draft`), leave the sub-goal pushed, then exit 0.

    **This gate fires whatever the review verdict says, in gate mode and verdict mode alike.** A reviewer judges whether the plan is *sound*; whether a capability the user asked for may be dropped is a product decision no verdict answers, and the two are orthogonal. The case that motivated it: an amendment narrowed an unattended relay to ANSWER-ONLY for an entirely correct reason — a looped write-capable skill over untrusted input was the exact injection the plan existed to prevent — and its own text said *"that is a deliberate reduction of the Goal's headline capability."* As engineering it was right, so a reviewer would approve it, verdict mode would send it to `ready`, and the user would discover that *"fix this while I'm out"* no longer worked the next time they tried it. It reached a human only incidentally, via a tag that was removed from `gateTags` the same day.

    Nothing else in the pipeline compares an amended plan against what it originally promised, and no tag list catches this: it fires on the decision itself rather than on a proxy for it.
6b. **Pop the sub-goal** — restore the original goal now that findings are addressed:
    ```bash
    scripts/wf-exec.sh wf-goal-pop.sh PLN-NNN
    ```
    It prints the goal it restored. **Read that line** — it must be the plan's original promise, not a table cell. The pop used to find its row by shape rather than by section, so it wrote `~~E2E~~` into one plan's `## Goal` and a bare `2` into another's, reporting success both times (client-e WFI-013, client-a WFI-097; fixed in 5.6.x, which also makes the pop refuse a one-token "goal" outright). A non-zero exit here means nothing was written and `plan.md` is intact — fix the Goal History row rather than working around it. `## Goal` is what `wf-plan-info.sh` hands to the implementer, the tester and every PR description.
6c. **Stamp the verdict against the text it judged, then check it.** This is the last write to `plan.md` in a replan, which is the whole reason it sits here:
    ```bash
    scripts/wf-exec.sh wf-review-stamp.sh PLN-NNN --no-commit
    eval "$(scripts/wf-exec.sh wf-review-status.sh PLN-NNN)"
    # REVIEW_LOCATION must be `plan`, and REVIEW_STALE must be false.
    scripts/wf-exec.sh wf-commit.sh "spec(PLN-NNN-<slug>): amendment reviewed — <verdict>" \
      --add plans/PLN-NNN-<slug>/
    ```

    **Commit it here, once the check passes** — do not leave the amendment and its verdict staged for step 8. Steps 7 and 8 are separate turns on a shared develop checkout, and a concurrent `/wf-test` merge stashes the whole working tree: client-a's WFI-164 lost two rounds of review in exactly that window, and the transition that followed reported success over a plan.md holding the template placeholder. Step 8 keeps its pathspec; with this committed it carries only what step 7 changed.

    **Stamp last, then check.** Without the stamp, staleness is decided by comparing two dates, and a replan that reviews and amends on the same day — every replan that finishes in one session — is unorderable: the script correctly answers `REVIEW_STALE=unknown`, and the condition above can then never be satisfied by any amount of re-reviewing (client-a WFI-069). The stamp records a hash of the plan body inside `## Review`, so the answer becomes true or false and stays right no matter how many rounds run in a day.

    **It used to sit at step 6, and the ordering guaranteed the failure it exists to detect.** `wf-goal-pop.sh` rewrites the `## Goal` one-liner — inside the hashed body — so stamping before the pop made `REVIEW_STALE` flip from false to true with no content amendment in between, on every replan that pushed a sub-goal. Two clients hit it and both papered over it by re-stamping and explaining themselves in prose (client-a WFI-092, WFI-093). The rule is now literal: **nothing writes to `plan.md` after the stamp.**

    `--no-commit` keeps the stamp from committing itself under a message about stamping (WFI-085); the `wf-commit.sh` line above then carries it under one that names the verdict. Callers with no commit of their own — `/wf-attend`, a review agent's exit — omit the flag and let the stamp commit itself.

7. **Update REGISTRY.md — the target state depends on whether a worktree exists:**
   ```bash
   scripts/wf-exec.sh wf-replan-target.sh PLN-NNN --apply
   ```

   A replan is not always a fresh build. If the plan still has its worktree and
   branch, the builder resumes a **fix cycle** — and `wf-implement`'s exit runs
   `wf-registry-update.sh PLN-NNN active verify`, whose `from_state` guard does
   not match `ready`. Writing `ready` unconditionally therefore produced a plan
   that the dispatcher correctly picked up, the builder correctly implemented,
   and whose exit transition then silently no-opped: the work landed on the
   branch while the registry still said `ready`, and verify refused to run
   because it could not match `verify` either.

   `wf-replan-target.sh` resolves it from the same fact the dispatcher uses —
   a live worktree means resume:

   | Worktree | Findings | Target | Next hands |
   |-|-|-|-|
   | none | any | `ready` | Builder, Phase 1 → fresh build |
   | live | any outstanding | `active` | Builder, fix cycle |
   | live | a human-test bounce, all answered, checklist complete | `testing` | Tester, straight back |

   The third row is the bounce with nothing to build: a tester filed a behavior finding, the replan concluded it does not reproduce, and there is no work for a builder. Sending it to `active` dispatches a builder onto an empty list and re-runs a full scoped verify against a tip that already passed clean; client-a's WFI-096 instead parked on a `needs-input` gate that blocked eight dependent plans until a human authorised the transition by hand. The script now answers `testing` for that shape and only that shape — say so in `findings.md`, in one line, naming what did not reproduce and how you established it.

8. **Commit:**
   ```
   scripts/wf-exec.sh wf-commit.sh "spec: PLN-NNN-<slug> — amendment, back to ready" \
     --add plans/PLN-NNN-<slug>/ plans/REGISTRY.md plans/deferred-criteria.md
   ```

## Cross-plan consistency

You are scoped to one plan. Nothing you write here can see a contradiction with the plan next to it — that is `wf-consistency`'s job, and it runs automatically when a plan with declared `Deps` reaches `ready`.

Your part of that contract is **declaring the dependencies in the first place.** A plan whose `Deps` column reads `—` is never cross-checked, whatever it actually consumes:

```bash
scripts/wf-exec.sh wf-set-deps.sh PLN-NNN PLN-003,PLN-005
```

Set `Deps` whenever this plan consumes an API, entity, schema, or config key that another plan provides — including plans not yet built. That is the case the pass is most valuable in: a mismatch against an unbuilt dependency is a dated amendment, while the same mismatch against a built one is a migration.

If a consistency pass amends *your* plan, its amendment lands in `## Amendments` with the triggering plan named. Treat it as you would any other amendment — never rewrite Steps, Tests, or Design Decisions in place.

## Bug consumption

When the plan being created is a fix for a tracked bug:

1. **Consume the bug:**
   ```bash
   scripts/wf-exec.sh wf-bug-consume.sh BUG-NNN PLN-NNN-<slug>
   ```
   This updates bug.md (Status→Triaged, Plan→linked), moves open→triaged, **and
   commits the move**. It commits rather than staging on purpose: this call runs
   at plan-creation time and your exit commit is on the far side of the whole
   review loop, so a staged rename would sit on the shared develop index for
   every round of it. Twice on client-a it was carried off before wf-spec
   could commit it — once by an unrelated plan's test commit, once by a merge,
   which sweeps the entire index and which no pathspec discipline here can
   defend against (WFI-112, WFI-106).
2. **Link back in `plan.md`** — add to the Goal section: `> **Bug:** BUG-NNN — <title>`

## Rules

- **Do NOT** edit source code files (src/,tests/)
- **Do NOT** leave ambiguous steps — if you're unsure, spawn a haiku agent to investigate
- If a plan is already in `active` or beyond, only append to **Amendments**
- Plans become static decision records — they document what was decided and why

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `wf-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/wf-exec.sh wf-issue.sh --source wf-spec \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the claude-workflow library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

