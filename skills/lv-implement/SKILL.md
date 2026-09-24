---
name: lv-implement
description: Execute a ready plan from start to finish. Creates feature branch and worktree, codes all steps, performs code review and architecture review, updates REGISTRY to verify (triggering the verify agent), and returns to develop.
user_invocable: true
model: haiku
---

# Implementer Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

## Unattended mode

If `LV_UNATTENDED=1` is set in your environment, you were launched by the orchestrator and **there is no human reading your output**. A question asked here hangs the pipeline.

Rules, in force for the whole session:

1. If your instructions name a plan, skip the entry menu entirely and work that plan. Determine its Type (`new` / `resume` / `fix`) from `lv-list-implementable.sh` output for that plan and follow the matching phase path.
2. Prompts marked **[AUTO]** below resolve to their stated default.
3. Prompts marked **[GATE]** must never be guessed. Park and exit cleanly:
   ```bash
   scripts/lv-exec.sh lv-gate-open.sh <PLN-ID> <gate-name> "<question>" --skill lv-implement
   ```
4. **Never guess.** Anything not in the table is a [GATE] with gate name `needs-input`.
5. **Never leave work running when you stop.** Run every build, test suite and
   long job in the **foreground** with a generous timeout, and read its output
   before you say anything about it. No `&`, no `run_in_background: true`, no
   backgrounded subagent, no "I'll wait for the completion notification."

   **There is no notification.** An unattended session is a headless `claude -p`
   run: it ends the moment you stop producing output, and everything you
   backgrounded is killed unread. client-a's PLN-030 was dispatched three
   times and produced three byte-identical two-line logs, each announcing that
   the suite was running in the background and that the worker would wait. Each
   session then ended. Three launches, zero forward progress, attempt budget
   spent, plan parked `stuck` — for a step whose only problem was that it takes
   longer than one turn (WFI-114).

   A step that genuinely cannot finish inside one foreground call — three
   sequential full-suite runs, a soak — is **not** a thing to background. Run
   what fits, `lv-progress-tick.sh` what completed, and record the remainder in
   `progress.md` so the next dispatch resumes instead of restarting. Recorded
   partial progress is what makes the attempt budget mean something.

6. **Redirect stdin from `/dev/null` on every build, test and tool command:
   `<command> < /dev/null`.** Your shell's stdin is not at EOF, so anything the
   command reads from it blocks forever instead of getting the immediate EOF a
   non-interactive run should see. It is one test doing this that hangs the
   whole suite, and it looks nothing like a hang from the outside — no failure,
   no crash, no output, just a build that never returns. client-a's PLN-264
   burned the 5-minute *and* 10-minute timeouts twice over on a suite whose only
   stdin reader was a single CLI test waiting on a token prompt; the same test
   finished in 0.8s under `< /dev/null` (WFI-240). Apply it to the whole
   invocation, including the attended forms below.

| Where | Prompt | Mode | Unattended behavior |
|-|-|-|-|
| Entry | Plan selection menu | [AUTO] | Use the plan named in your instructions |
| Entry | Plan Type is `processing` | [AUTO] | Another session owns it — exit 0 without doing anything. `lv-list-implementable.sh` no longer reports a plan as `processing` on the strength of the claim your own dispatcher took out for you (WFI-076), so this type now genuinely means somebody else. |
| Migration notes | Pending MIGRATION-NOTES actions | **[GATE]** | `migration` — question is the notes text verbatim |
| Phase 2 step 3 | Goal missing (`$PLAN_GOAL_MISSING`) | **[GATE]** | `goal-missing` — the goal is what the tester and PR description quote; do not invent it |
| Phase 3 | Plan ambiguous mid-implementation | [AUTO] | Note it in `progress.md` and continue with the most conservative reading. Only [GATE] (`needs-input`) if you cannot proceed at all |
| Any | Escalation to spec | [AUTO] | Follow the normal escalation path — write ESCALATED findings and set state to `draft`. This is a state transition, not a question |
| Fix cycle | A finding is a real bug in code this plan never touched | [AUTO] | Not a gate and not an escalation: file an independent bug, tag the finding `← BROAD-SCOPE` naming it, leave the box unchecked (WFI-081) |
| Fix cycle | A finding has **no code to write** — it restates an open `#### Manual` criterion needing human eyes | [AUTO] | Not a gate: tag it `← MANUAL-TEST`, leave the box unchecked, and exit to `verify` as normal. It travels to `testing` and is resolved at the manual gate (WFI-203) |

Exiting to `verify` is unchanged: it is a normal state transition, and the verify agent already runs unattended.

## IMMEDIATE STARTUP — run in parallel before reading further

1. Run branch check (do not prompt the user):
   ```bash
   scripts/lv-exec.sh lv-branch-check.sh develop true
   ```

   **Exit 2 means the check refused to switch.** Another session is holding this
   shared checkout, and switching it would move a ref out from under them. Two
   cases, both refused:

   - parked on a branch the pipeline does not own — how four commits for one
     plan landed on a human's topic branch (WFI-123);
   - parked on `release` or `main` — a `/lv-release` or `/lv-deploy` is running.
     The orchestrator never leaves the checkout there and never dispatches those
     skills, so this is always somebody's deploy mid-flight. Switching sent a
     deploy's last seven commits to `develop` instead of `main` (WFI-157).

   Stop — do not `git checkout` past it. Under `LV_UNATTENDED=1` exit 0 without
   claiming anything; the dispatcher offers the work again once the checkout is
   back on develop.

2. Spawn a **haiku subagent** to fetch and format the worklist:

```
Agent(model: haiku, prompt: "Run `scripts/lv-exec.sh lv-list-implementable.sh` in the current directory.
Output is tab-separated: <type>\t<plan-name>\t<goal>\t<priority>. Processing type has a 5th field: <claim-age>. Blocked type has a 5th field: <blocking-plan-ids>. Gated type has a 5th field: <gate-name>.
Exit code 1 means no plans.

You MUST format output as markdown tables using pipe syntax. Do NOT use paragraphs, bullet lists, or plain text.

Table 1 — Ready to implement (types: new/resume/fix, numbered, urgent first):

| # | Priority | Plan | Type | Goal |
|-|-|-|-|-|
| 1 | urgent | PLN-001-example | new | Example goal |

Table 2 — Blocked (type: blocked, no row numbers):

| Plan | Goal | Blocked by |
|-|-|-|
| PLN-009-api-gateway | Example goal | PLN-003 |

Table 3 — In progress (types: processing only, no row numbers):

| Priority | Plan | Goal | Claimed |
|-|-|-|-|
| — | PLN-002-example | Example goal | 15m ago |

Table 4 — Waiting on a human (type: gated, no row numbers):

| Plan | Goal | Gate |
|-|-|-|
| PLN-019-example | Example goal | consistency-migration |

Omit Table 2 if no blocked items. Omit Table 3 if no processing items. Omit Table 4 if no gated items. After the tables add:
Mark a plan urgent: \`u <number>\`
Force-take a stale claim: \`force <plan-id>\` (e.g. \`force PLN-022-lesson-deeplink-urls\`)

If no actionable items (or exit code 1), output: 'No plans ready to implement. Run /lv-tray to see pipeline state.'

Final response: ONLY the formatted tables. No commentary. No paragraphs.")
```

Display the subagent's output verbatim, then take a row as described in Entry below.

---

You are in **implementer mode**. Your job is to execute an implementation plan completely: lock the plan, create a worktree, code all steps, perform code and architecture review, run tests, then update the REGISTRY to `verify` — which triggers the autonomous verify agent. You also handle fix cycles when the verify agent sends a plan back.

Do NOT use agents for writing code — implementation is inherently sequential and context-dependent. Agents are used for:

- **Build and test verification (step 18):** *Attended only* — launch haiku agents in the background to run build, unit tests, and E2E tests while you do code/architecture review in parallel. Under `LV_UNATTENDED=1` run them in the foreground yourself; see rule 5 above.
- **Lookups:** Sparingly, to find specific signatures or patterns:
  ```
  Agent(model: haiku, prompt: "What is the exact method signature of [method] in [file]? Response under 500 chars.")
  ```

---

## Entry (simple)

**If on `develop`:**

Display the subagent output from IMMEDIATE STARTUP. **`lv-list-implementable.sh` is the ONLY source of truth for plan availability. Do NOT write your own detection logic, check worktree ages, or query claim files manually.**

**Do not wait for a pick (WFI-006).** If the invocation named a plan (`/lv-implement PLN-NNN`), take that row. Otherwise take the **first selectable row** — `new`, `resume` or `fix`; the script already lists urgent before normal. Print one line saying which you took and why (`Taking PLN-NNN (urgent, resume) — first selectable row.`) and proceed. The operator can interrupt and name another; a menu that waits for a number is a pause security does not justify. Then check the **Type** column for that row:

| Type | Action |
|-|-|
| `new` | **Phase 1** (setup) → Phase 2 → Phase 3 |
| `resume` | **Skip Phase 1 entirely** → jump to Phase 2 step 9 |
| `fix` | **Skip Phase 1 entirely** → jump to Fix Cycle |
| `processing` | Not selectable — claimed by another session |
| `gated` | Not selectable — a human owes it an answer. Say which gate, and point at `/lv-attend` |

**CRITICAL — resume/fix plans already have a worktree and branch.** Do NOT run Phase 1 for them. Do NOT run `git worktree add`, `lv-registry-update.sh ready active`, or create a new branch. Jump directly to Phase 2 step 9 (which claims the plan, cd's to the existing worktree, and merges develop).

If the user types `u <N>`: run `scripts/lv-exec.sh lv-set-priority.sh <plan-id> urgent`, then re-run the haiku subagent to re-display the updated menu.
If the user types `u <N>` for an already-urgent plan: run `scripts/lv-exec.sh lv-set-priority.sh <plan-id> —` to clear it, then re-run the subagent.

If the user types `force <plan-id>`:
```bash
scripts/lv-exec.sh lv-claim.sh <plan-id> --steal
```
One call, not `lv-unclaim.sh` followed by `lv-claim.sh`: releasing a claim is also a **trigger** — `lv-unclaim.sh` flushes any spawn the orchestrator deferred behind that claim, so unclaiming to take a plan for yourself can dispatch a worker onto it in the same breath. `--steal` takes the claim without releasing it, and records the takeover in the event log.
Then treat the plan as a `fix` entry (has unchecked findings) or `resume` entry, and proceed to Phase 2.

**If on a feature branch:**
- Run `eval "$(scripts/lv-exec.sh lv-plan-ref.sh)"` to get PLAN_ID, PLAN_DIR, PLAN_NAME
- Read the plan from `$PLAN_DIR/plan.md`
- Continue Phase 2

---

## Migration notes check (after plan is selected)

Before Phase 1 or Phase 2 runs, check for pending workflow-upgrade migration actions for this plan:

```bash
DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
notes="$DEVELOP_ROOT/plans/MIGRATION-NOTES.md"
if [ -f "$notes" ]; then
  awk -v plan="PLN-NNN-<slug>" '
    /^### / { printing = (index($0, plan) > 0) }
    printing { print }
  ' "$notes"
fi
```

Substitute the actual plan name for `PLN-NNN-<slug>`. If the command prints anything, display it to the user verbatim and tell them:

> This plan has pending migration actions from a workflow upgrade (see above). Complete them, then remove the plan's section from `plans/MIGRATION-NOTES.md` before resuming.

Then STOP. Do NOT proceed to Phase 1 / Phase 2 until the user confirms the actions are complete.

Under `LV_UNATTENDED=1` this is a **[GATE]** — open gate `migration` with the notes text as the question, then exit 0.

If the command prints nothing, continue to Phase 1 / Phase 2 as normal.

---

## Phase 1: Setup (on `develop` branch)

1. **Confirm you are on `develop`** — `scripts/lv-exec.sh lv-branch-check.sh develop true`
1b. **Check for an open gate on this plan — before writing anything:**
   ```bash
   scripts/lv-exec.sh lv-list-gates.sh PLN-NNN
   ```
   Exit 0 means a gate is open and a human owes it an answer. **Stop.** Display the gate line and exit 0 without transitioning the registry or creating a branch. Under `LV_UNATTENDED=1`, say which gate and exit — the dispatcher will offer the plan again once it is answered.

   A gate can open after you were dispatched: `lv-consistency` runs against `ready` plans and opens one the moment it finds a cross-plan contradiction. client-a's WFI-063 had an implementer land on a plan carrying an unanswered `consistency-migration` gate, with the worklist showing it as ordinary `new` work; it implemented three steps before discovering the gate by reading `.claude/orchestrator/gates/` by hand. The worklist names this now (`gated` rows in `lv-list-implementable.sh`), and this check is the second line of defence for a gate that opened between the dispatch and you.
2. **Read the plan** — `eval "$(scripts/lv-exec.sh lv-plan-info.sh PLN-NNN)"` then read `$PLAN_DIR/plan.md`
3. **Goal check** — if `$PLAN_GOAL_MISSING` is `true`: under `LV_UNATTENDED=1` this is a **[GATE]** — open gate `goal-missing` and exit 0. Otherwise ask the user: "This plan has no goal summary. Please provide a one-line goal describing what this achieves." Write their answer as the first line under `## Goal` in `$PLAN_DIR/plan.md`, then commit it scoped: `$DEVELOP_ROOT/scripts/lv-exec.sh lv-commit.sh "spec(PLN-NNN-<slug>): add missing goal" --add plans/PLN-NNN-<slug>/plan.md` — a bare `git commit` takes the whole shared index (WFI-048/049). Re-run `eval "$(scripts/lv-exec.sh lv-plan-info.sh $PLAN_NAME)"` to pick up the goal.
3b. **Check whether someone already built this** — before you take the plan, and before you cut a branch off develop:
   ```bash
   scripts/lv-exec.sh lv-prior-work.sh PLN-NNN
   ```
   Exit 0 means it found commits on `develop` naming this plan or its bug that touch code, not just `plans/`. **Stop.**

   **First ask whether this was already decided** — a commit on develop is a durable fact, so this check reports it on every dispatch, and the gate below would be opened afresh every time:
   ```bash
   eval "$(scripts/lv-exec.sh lv-gate-status.sh PLN-NNN prior-work)"
   ```
   `GATE_ANSWERED=true` with `GATE_STALE=false` means **a human has already answered this**. `$GATE_RESOLUTION` is the decision of record: act on it — build per plan.md over the accepted commit, revert it on the feature branch, or leave an unrelated commit alone and implement per plan.md unchanged, whichever it says — and carry on to step 4. Do not re-ask, and do not re-derive the question from what you can see now.

   client-a's PLN-135 re-opened this gate **four times** (WFI-180, WFI-181, WFI-182). The fourth was thirty minutes after the decision had been committed to `findings.md`, and by then the question had drifted: it offered an option the human never authorized and described a `HashSet` that had been a `Dictionary` since a merge two plans earlier. **A re-asked question does not come back the same** — it comes back re-derived from whatever the next worker happens to read, and a human answering it is answering something else. `lv-gate-open.sh` now refuses this gate outright when it is answered (exit **3**), but arriving there means you have already skipped this step.

   Otherwise, under `LV_UNATTENDED=1` this is a **[GATE]**:
   ```bash
   scripts/lv-exec.sh lv-gate-open.sh PLN-NNN prior-work \
     "<sha> '<subject>' is already on develop and came in outside the pipeline — no feature branch, no verify. It touches <N> file(s); <the overlap line lv-prior-work.sh printed>. (1) accept it as this plan's work — straight to verify; (2) revert it on the feature branch and implement per plan.md; or (3) it is unrelated work that stands — leave it on develop and implement per plan.md unchanged?" \
     --context plans/PLN-NNN-<slug>/plan.md --skill lv-implement
   ```
   Then exit 0 without transitioning the registry or creating a branch. Attended, put the same question to the user.

   **Offer all three, and quote the overlap line `lv-prior-work.sh` printed under the commit.** A commit that merely mentions the ID while doing something else is common, and for it neither of the first two answers is true. client-a's PLN-206 had one touching only `docs/plan/reference/` while the plan's four steps target `RedactionGuards.cs` and two test files — zero file overlap, and Step 4 saying in as many words "No `docs/` change". With only two options offered, answering `accept` literally would have moved a plan at step 0 of 4, with no worktree and no code written, straight to `verify` (WFI-208). If answer (3) keeps recurring for the same paths, the durable fix is `priorWork.ignorePaths` in `claude-workflow.yml`, which the script prints.

   **Exit 3 from `lv-gate-open.sh` is not a failure.** It means the gate was refused because an answer of record already covers this revision of the plan; the resolution is printed. Act on it and continue — never work around it by re-opening under another name.

   client-a's WFI-155: PLN-092's plan.md told the builder that the BUG-092 prototype was untracked scratch that "won't follow a git worktree add". By dispatch time `fix(BUG-092): …` was a real commit on develop touching all five files the plan's steps target, with no branch, no `.plan-ref` and no MUTATION marker — so the worktree inherited it and the note was wrong through no fault of the planner. Neither answer is the builder's to pick: implementing per plan.md fights code that is already there, and calling it done accepts unreviewed work as the deliverable. **A plan's description of what is on develop is a claim about the past, and this is how you check it.** Exit 1 means clean — say nothing and carry on.
4. **Update REGISTRY.md** — lock the plan:
   ```bash
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN ready active feature/PLN-NNN-<slug>
   ```
5. **Create feature branch and worktree:**
   ```bash
   mkdir -p feature-branches
   git worktree add -b feature/PLN-NNN-<slug> feature-branches/PLN-NNN-<slug> develop
   scripts/lv-exec.sh lv-worktree-sparse.sh feature-branches/PLN-NNN-<slug>
   ```
   **`develop`, not `HEAD`.** `HEAD` means "whatever this shared checkout happens to be on", and that is not yours to assume: client-a's WFI-123 had a concurrent interactive session park the main worktree on a topic branch, so plans branched off a stranger's work and their commits stacked on a hand-made commit. Naming `develop` makes the base a fact about the pipeline instead of a fact about the moment.

   If this fails with `already exists`, the branch is **not** yours to take — stop. Under `LV_UNATTENDED=1` open a **[GATE]** `branch-exists` naming the branch; attended, show it to the user. Never `git checkout` an existing branch and build on it: a branch this plan did not create belongs to another plan, another session, or a human, and reusing it is how four PLN-038 commits landed on someone else's `fix/BUG-039-…` (WFI-123).
6. **Write `.plan-ref` in the worktree:**
   ```bash
   echo "PLN-NNN" > feature-branches/PLN-NNN-<slug>/.plan-ref
   ```
   **Do not commit it.** As of v6.0.0 `.plan-ref` is gitignored — it says which plan *this worktree* is building, and a merge has no business carrying that anywhere. It used to be added and committed here, and every merge then took it along: feature → release → main → develop, until develop itself tracked a pointer to a finished plan (client-a WFI-103). `git worktree add` materialises tracked files, so the next worktree cut from develop started out pointing at that plan. See [`docs/worktrees.md`](../../docs/worktrees.md).

   Whenever a step here does need git in another directory, reach for `git -C <path>`, **never `cd <path> && git …`.** The two are equivalent to git and are not equivalent to the auto-mode permission classifier, which refuses the compound form outright — client-e's WFI-015 lost three separate steps to `Blocked by classifier` and had to substitute `git -C` by hand mid-run. Use `git -C` in every example that touches a directory other than the current one; the one place a real `cd` is required is step 9, where the session's working directory itself has to move.
7. **Give the worktree its session permissions:**
   ```bash
   scripts/lv-exec.sh lv-worktree-harness.sh feature-branches/PLN-NNN-<slug>
   ```
   This also refreshes the skills, `workflow.md` and `lv-exec.sh` the worktree needs. It writes `.claude/settings.local.json` granting `Read(//**)`, `Edit(//**)` and `Bash(*)`, and will not overwrite one the project already has.

   `Edit(//**)`, not `Write(//**)`: Edit rules cover every file-editing tool, and a `Write(...)` rule is matched by nothing. Claude Code says so on startup — *"Write(//\*\*) is not matched by file permission checks — only Edit(path) rules are"* — and that warning was the first of the two lines an entire stranded verify run wrote to its log (client-e WFI-012). Writing the file from the skill as a heredoc is what WFI-015 saw refused by the permission classifier; a script the harness owns is not refusable in the same way.

---

## Phase 2: Implementation (in the worktree)

**CWD RULE: After step 9 runs `cd` into the worktree, you are INSIDE the worktree for the rest of Phase 2. The path `feature-branches/...` does not exist from inside the worktree. Never `cd feature-branches/...` again. Use `$DEVELOP_ROOT` (resolved via `git worktree list`) for any path back to develop.**

**`$DEVELOP_ROOT` is for the HARNESS, and only for the harness.** `lv-*.sh` and `lv-exec.sh` live on develop because deploy writes them there and they are gitignored in your worktree — that is the whole reason the prefix exists. **A project's own scripts are tracked, so they are in your worktree, and running develop's copy of one builds develop's tree.** client-a's PLN-191 ran `$DEVELOP_ROOT/scripts/build-installer.sh` to satisfy a Verification Checklist item; that script begins `cd "$(dirname "${BASH_SOURCE[0]}")/.."`, so it relocated to the develop checkout and staged a payload from develop's code, not the feature branch's. It exited clean and reported success, and the mistake surfaced only when the worktree's own copy was run and produced a different manifest (WFI-225 — the same wrong-tree-reported-as-success class as WFI-105).

Two rules follow, and neither is optional:

- **Harness script → `$DEVELOP_ROOT/scripts/lv-exec.sh <lv-script>`.** Never a bare relative path; `scripts/` does not exist where you are standing.
- **Project script → `./scripts/<name>.sh` from the worktree.** Never `$DEVELOP_ROOT`-prefixed. If it is not there, that is a fact about the branch worth reporting — not a reason to reach for develop's copy.

A build or test command that succeeds says nothing about *which tree* it built until you check. When a verification step's output is a build artifact, confirm it came from your branch (`git rev-parse HEAD` against whatever the artifact stamps) before recording the step done.

**And do not trust that you are still there.** The working directory has been
observed resetting from the worktree back to the main worktree between two
consecutive Bash calls with no `cd` in between — twice in one session. One
occurrence built develop's copy of the solution instead of the branch's and
reported *"Build succeeded"* for code that was not in that tree at all
(WFI-105). A false green from the wrong worktree is the most expensive thing
this role can produce, because everything downstream believes it.

So **anchor every build, test, or run command** with an absolute prefix in the
same call:

```bash
cd /abs/path/to/feature-branches/PLN-NNN-<slug> && git branch --show-current && <build or test command>
```

`git branch --show-current` in the same call is the receipt: if it does not name
`feature/PLN-NNN-<slug>`, the output that follows describes someone else's tree
and must be discarded, not reported.

8. **Claim the plan — on its own, before anything with a `cd` in it:**
   ```bash
   scripts/lv-exec.sh lv-claim.sh PLN-NNN-<slug> --state ready,active
   ```
   Its own call on purpose. Bundled into step 9 it went down with that block when the permission classifier refused the compound (client-e WFI-015), and the run continued unclaimed — which is what lets a second worker start on the same plan. If this one call is refused, that is worth a `lv-issue.sh`, not a shrug.

   `--state ready,active` are the only two states this skill has anything to do. **Exit 3** means the plan left them between the dispatch and now — verified, tested, replanned, abandoned. Exit 0 without doing anything; nothing was claimed, and building against a plan that has moved on is worse than not building (WFI-153).
9. **Set develop root, change to worktree, confirm branch, and merge develop — all in a single bash call:**
   Workflow files may appear modified after a deploy — they belong to develop and **must NOT be committed as plan work**. The pathspec exclusions below keep them out of your commit; `lv-merge-develop.sh` then commits them separately as `chore: sync workflow infra from develop` so the tree is clean enough to merge.
   ```bash
   DEVELOP_ROOT=$(pwd)
   cd $DEVELOP_ROOT/feature-branches/PLN-NNN-<slug>
   git branch --show-current
   $DEVELOP_ROOT/scripts/lv-exec.sh lv-branch-check.sh feature/PLN-NNN-<slug> || exit 1
   git add -A -- ':(exclude)scripts/lv-*.sh' ':(exclude).claude/' ':(exclude)plans/' ':(exclude)templates/' 2>/dev/null; git diff --cached --quiet || git commit -m "implement(PLN-NNN-<slug>): wip before merge"
   $DEVELOP_ROOT/scripts/lv-exec.sh lv-merge-develop.sh
   ```
   Shell variables do NOT persist across bash calls — run these together so `DEVELOP_ROOT` and `cd` stay in scope.

   **Every later bash call that uses `$DEVELOP_ROOT` must set it in that same call.** Not "should" — an unset `$DEVELOP_ROOT` expands to nothing, so `$DEVELOP_ROOT/scripts/lv-exec.sh` becomes `/scripts/lv-exec.sh` and the call dies with `no such file or directory`, exit 127 (client-a WFI-251, on the docker teardown at step 23). The blocks below therefore carry this line themselves; keep it when you copy them:
   ```bash
   DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
   ```
   The working directory *does* carry over between calls, and `git worktree list` answers the same from anywhere inside the repo, so this line is safe to repeat and costs nothing.

   **`git add -A`, not `git add -u`.** This commit exists to capture everything a previous session left behind before the merge rewrites the tree, and `-u` stages only changes to files git already tracks — a new file it has never seen is not one of them. client-a's PLN-246 resumed a crashed session that had written four new test files covering 10 of the plan's 13 tests; the documented wip commit skipped every one of them silently, and they would have reached verify and testing with no coverage at all had a `git status` not caught them by hand (WFI-223). The pathspec exclusions do the work of keeping develop's harness files out; `-u` was never what made this commit safe.

   **The branch check is a hard stop, not a receipt.** Printing `git branch --show-current` only helps if something reads it; the explicit check refuses to go on. A resume that finds anything other than `feature/PLN-NNN-<slug>` here is standing in the wrong directory or on a branch that is not this plan's, and everything after this line commits code (WFI-123).
12. **Set the Docker project name and port:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    eval "$($DEVELOP_ROOT/scripts/lv-exec.sh lv-plan-port.sh PLN-NNN-<slug>)"
    ```
13. **Read the plan** — from develop worktree: `$DEVELOP_ROOT/plans/PLN-NNN-<slug>/plan.md`
14. **Execute steps in order** — follow each step exactly as specified
    - After each step, commit, record the step, and refresh the claim:
      ```bash
      DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
      git add src/ tests/ && git commit -m "implement(PLN-NNN-<slug>): step N — <desc>"
      $DEVELOP_ROOT/scripts/lv-exec.sh lv-progress-tick.sh PLN-NNN N "<desc>"
      $DEVELOP_ROOT/scripts/lv-exec.sh lv-claim.sh PLN-NNN-<slug>
      ```
      Refreshing the claim on every commit means the claim age reflects time since last activity. Sessions that crash without committing will have their claims auto-expire (TTL: 2 hours).

      **`lv-progress-tick.sh` is not optional.** It ticks `Step N` in `progress.md`'s `## Steps` checklist and writes the Log line in one call. `N` is the step's **whole label**, exactly as the checklist writes it — where a plan sub-letters its steps, `1a-i` and `1b` are separate rows that are ticked separately, and passing the bare `1` is an error rather than a tick of the whole family. The same holds for an amendment's steps, which carry the amendment in the label (`A1.1` … `A1.8`): tick each by its whole label, never the bare `A1`. That checklist is the pipeline's only record of forward progress: the orchestrator resets a plan's attempt budget when the checked count climbs, which is what tells a **resume** of a long plan apart from a **retry** of a thrashing one. A plan whose checklist never moves gets parked as `stuck` no matter how much work landed on the branch. If a step ends blocked, call it as `lv-progress-tick.sh PLN-NNN N "<why>" --blocked` — that logs without ticking.
    - **Config-driven randomness**: If a step introduces probabilistic or random behavior (e.g., a spawn chance, drop rate, trigger probability), store the controlling value in `appsettings.json` (or equivalent config) rather than as a hardcoded constant. This lets testers force or suppress the behavior via override values (e.g., `1.0` to always trigger, `0.0` to never trigger) without modifying source code.
15. **Write tests** — implement all tests listed in the Tests table. Before drafting a new test, if `$DEVELOP_ROOT/plans/auto-test-log.md` exists, skim its `### Realized` section for rows whose criterion or test file looks relevant. Use them as a style reference (naming, file location, assertion shape) to match house convention without reinvention.
16. **Log progress** — handled by `lv-progress-tick.sh` in step 14; do not hand-edit the `## Steps` checklist. For anything that is not a step completion (a note, an ambiguity you resolved conservatively), append directly to `$DEVELOP_ROOT/plans/PLN-NNN-<slug>/progress.md` under `## Log`. **Never use relative paths** — `plans/` only exists on the develop worktree.
17. **Deploy to local container for testing:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    $DEVELOP_ROOT/scripts/lv-exec.sh lv-docker-up.sh PLN-NNN-<slug>
    ```

    **`$DEVELOP_ROOT` is not decoration — the harness does not exist in your worktree.** `scripts/` is generated by deploy and gitignored, so a feature worktree contains none of it. Probing `scripts/lv-docker-up.sh` from where you are standing finds nothing and proves nothing; client-a's WFI-083 read that as "no docker tooling is present" and skipped the deploy on a project that has both a compose file and the script.

    **The real test for "there is nothing to deploy" is the config:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    $DEVELOP_ROOT/scripts/lv-exec.sh lv-config-get.sh local_deploy_command
    ```
    Empty means this project has no local container — skip the step and say so in `progress.md`. Non-empty means the container is expected; a failure there is a failure to report, not a step to drop.
18. **Run build and tests.**

    **Under `LV_UNATTENDED=1`, run both commands yourself, in the foreground,
    with stdin redirected from `/dev/null`, and read the output** — see rules 5
    and 6 in [Unattended mode](#unattended-mode). A suite containing one test
    that reads stdin hangs indefinitely without that redirect (WFI-240).
    Backgrounding here is what ended three PLN-030 dispatches with nothing done
    (WFI-114). Steps 19–20 are then done after the output is in hand rather
    than alongside it; that costs wall-clock and nothing else.

    Attended only — a human is present to receive the completion notification,
    so the reviews in steps 19–20 can run in parallel:
    ```
    Agent(model: haiku, run_in_background: true, prompt:
      "Run `{{build_command}} < /dev/null` in the current directory.
       Report: success or failure. If failure, list all errors (not warnings).
       Final response under 1000 characters.")

    Agent(model: haiku, run_in_background: true, prompt:
      "Run `{{test_command}} {{test_exclude_e2e}} < /dev/null` in the current directory.
       Report: total tests, passed, failed, skipped.
       If any failed, list each failure with test name and error message.
       Final response under 1500 characters.")
    ```

    **Pass the exclusion flags as written — bare words, no quotes around them.** The value is several flags (`--ignore-exit-code 8 --filter-not-namespace "*E2E*"`), and wrapping the lot in one pair of quotes fuses them into a single unrecognised argument: the runner silently ignores the filter and runs the whole suite, then fails on an e2e test this step exists to exclude. client-a hit it twice on one plan (WFI-088, WFI-090) — an out-of-scope Playwright failure charged against an Infrastructure change.
19. **Code review** (while agents run):
    - Read through all changed source files
    - Verify logic matches the plan's design decisions
    - Check for edge cases, error handling
    - Ensure no debugging code, console.logs, or temporary hacks remain
    - If issues found, fix before proceeding
20. **Architecture review** (while agents run):
    - Re-read the plan's "Design Decisions" section
    - Confirm the implementation follows those decisions
    - If scope changes are needed that **cannot be resolved by editing code alone**:
      1. Write `ESCALATED` findings to `$DEVELOP_ROOT/plans/PLN-NNN-<slug>/findings.md`:
         ```markdown
         ## Implement — YYYY-MM-DD
         
         - [ ] **Design**: <description of design issue> ← ESCALATED
         ```
      2. Destroy the docker container (step 23)
      3. Return to develop (Phase 3) and update REGISTRY state to `draft`
      4. Display: "Design issue found. Run `/lv-spec` to amend the plan."
    - If issues are minor (code-level fixes), fix them and note in `progress.md`
21. **Collect agent results** — check each result:
    - **Build failed:** fix errors, re-verify via haiku agent
    - **Tests failed:** fix failures, re-verify via haiku agent
    - Log results in `progress.md`
    - **Tick off automated checklist sections** in `plan.md` — mark `### Build & Tests`, `### Code Quality`, `### Regression Scope` items as `[x]`
22. **When all steps, reviews, and tests pass** — commit on feature branch (skip if nothing to commit — all changes may already be committed per-step):
    ```
    git add -A -- ':(exclude)scripts/lv-*.sh' ':(exclude)scripts/v*/lv-*.sh' ':(exclude)scripts/version-map.txt' ':(exclude).claude/' ':(exclude)plans/' ':(exclude)templates/'
    git diff --cached --quiet || git commit -m "implement(PLN-NNN-<slug>): all steps complete"
    ```

    Never a bare `git add -A` here. A deploy landing mid-plan rewrites the
    workflow files this worktree carries; a bare `-A` commits develop's
    infrastructure onto the feature branch as if the plan had changed it. The
    same exclusions appear on every other `git add` in this skill.
23. **Destroy the docker container:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    $DEVELOP_ROOT/scripts/lv-exec.sh lv-docker-down.sh PLN-NNN-<slug>
    ```
    Resolved in this call, not inherited from step 9 — steps 9 and 23 are many bash calls apart and nothing carries a shell variable that far (WFI-251).

---

## Phase 3: Exit (complex) — return to develop

**A criterion is accepted only in `testing`, by `/lv-test` — never by holding the plan at `active` for an out-of-band human look.** When step 22's checklist passes, advance to `verify` (step 25); do not stay at `active` waiting for a human to eyeball the running container and accept criteria there instead. That acceptance happens outside every gate this pipeline has: it is not written to `findings.md`, not visible to `lv-list-*` or the orchestrator, and its only record is whatever prose the builder happens to put in `progress.md` — unauditable, and invisible to anyone who did not read that file (client-f WFI-002). If a criterion is genuinely subjective and likely to take a few rounds of human judgment (a visual layout, a wording call), that is exactly what the `verify → testing → active` fix cycle is for: tag it `← MANUAL-TEST` if it has no code-level finding, exit to `verify` as normal, and let `/lv-test` record PASS/FAIL. Iterating through the full cycle for a subjective judgment costs a round trip, not a redesign.

**IMPORTANT:** All commands in this phase must run from the develop root (`DEVELOP_ROOT`). Set it **in every bash call that uses it** — "set it once" is not a thing a shell variable does across separate calls (WFI-251):
```bash
DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
```

24. **Return to develop:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    cd "$DEVELOP_ROOT"
    ```
25. **Move the plan to `verify` and commit it, in one step:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    cd "$DEVELOP_ROOT" && scripts/lv-exec.sh lv-registry-update.sh PLN-NNN active verify \
      --commit "implement(PLN-NNN-<slug>): verified, moved to verify" \
      --add plans/PLN-NNN-<slug>/ \
      || { echo "REGISTRY REFUSED THE TRANSITION — do NOT run step 26"; grep "^| PLN-NNN |" plans/REGISTRY.md; }
    ```

    **If that fails, stop here.** The `from_state` guard did not match, which
    means the row is not where this path assumed — most often `ready`, because
    a replan left it there while the worktree made the builder take the fix
    path. Anything downstream would announce a transition that never happened,
    and the verify agent it claims to trigger would refuse to run for the same
    reason. Report the row the grep printed; under `LV_UNATTENDED=1` this is a
    **[GATE]** with gate name `needs-input`.

    The whole plan folder, not just `progress.md` and `findings.md` — step 21
    ticks the automated sections of `plan.md`'s Verification Checklist, and
    those ticks are what the verify agent reads as already-done.

    **This one commit both carries the transition and triggers the verify
    agent** (the post-commit hook matches `moved to verify` in the message).
    They used to be two commits — an implicit `registry(...)` one from
    `lv-registry-update.sh`, then a separate `--allow-empty` commit whose only
    job was to say the words the hook looks for. Fusing them removes the window
    where the hook could fire against a state that had not landed yet, and the
    `--add` makes the plan folder part of the same atomic commit.
26. **Release the claim — last:**
    ```bash
    DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
    cd "$DEVELOP_ROOT" && scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
    ```

    **After step 25, never before it.** The claim is what keeps the dispatcher
    off this plan; released while the row still reads `active`, a sweep landing
    in that window sees free, unclaimed, implementable work and launches a
    second implementer into the worktree you are standing in. An uncommitted
    transition does not exist to any other session, so the guards come down
    only once it has landed (client-a WFI-079).

27. **Post completion message:**
    ```
    Implementation complete — all steps, code review, architecture review, and tests passed.
    Plan moved to verify — the verify agent will run automated checks.
    
    If the verify agent finds issues, the plan will return to active (check /lv-tray).
    If clean, it moves to testing for T4 human acceptance test.
    ```
    Then run `scripts/lv-exec.sh lv-check-reboot-flag.sh` and append any output to the message above.

---

## Fix cycle (plan returned to `active` by verify agent)

The verify agent found code/test/spec issues and set the REGISTRY state back to `active`.

**The worktree and branch already exist. Do NOT run Phase 1. Do NOT create a branch or worktree.**

1. **Entry** — `grep "| active |" plans/REGISTRY.md` shows the plan
2. **Read findings** — `plans/PLN-NNN-<slug>/findings.md` has unchecked items
3. **Set develop root, claim the plan, cd to the feature worktree, and merge develop — all in a single bash call:**
   Workflow files may appear modified after a deploy — they belong to develop and **must NOT be committed as plan work**. The pathspec exclusions below keep them out of your commit; `lv-merge-develop.sh` then commits them separately as `chore: sync workflow infra from develop` so the tree is clean enough to merge.
   ```bash
   DEVELOP_ROOT=$(pwd)
   scripts/lv-exec.sh lv-claim.sh PLN-NNN-<slug>
   eval "$(scripts/lv-exec.sh lv-plan-info.sh PLN-NNN)"
   [ "$PLAN_STATE" = "ready" ] && scripts/lv-exec.sh lv-registry-update.sh PLN-NNN ready active
   cd $DEVELOP_ROOT/feature-branches/PLN-NNN-<slug>
   git add -A -- ':(exclude)scripts/lv-*.sh' ':(exclude).claude/' ':(exclude)plans/' ':(exclude)templates/' 2>/dev/null; git diff --cached --quiet || git commit -m "implement(PLN-NNN-<slug>): wip before merge"
   $DEVELOP_ROOT/scripts/lv-exec.sh lv-merge-develop.sh
   ```
   Shell variables do NOT persist across bash calls — keep these together so `DEVELOP_ROOT` stays in scope. After this call, you are INSIDE the worktree — never `cd feature-branches/...` again.

   **`git add -A`, not `git add -u`** — see Phase 2 step 9. A fix cycle is entered on a worktree somebody else left, so this is the path where uncommitted new files are *most* likely to be sitting (WFI-223).

   **The `ready → active` line is not optional, and it is why step 1 says "shows the plan" rather than "shows it as `active`".** A fix cycle is entered on the *type* `lv-list-implementable.sh` computes — worktree present plus unchecked findings — and that type is `fix` whatever the registry row says. A replan leaves a plan at `ready` while its worktree survives, so the fix path is reached with the row still reading `ready`, and every fix in the cycle then lands correctly right up until the Phase 3 exit refuses: `PLN-NNN is in state ready, not active` (client-a WFI-202). The transition belongs at entry, where the work actually starts, not at the exit that discovers it missing. `lv-list-implementable.sh` already treats `ready`-with-a-worktree as `active` internally; this makes the registry agree.
4. **Set the Docker project name and port** — same as Phase 2 step 12, and for the same reason:
   ```bash
   DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
   eval "$($DEVELOP_ROOT/scripts/lv-exec.sh lv-plan-port.sh PLN-NNN-<slug>)"
   ```
   **Not optional, and not covered by Phase 2 having done it** — these are shell
   variables and this is a new session. The `on-implement-commit.sh` post-commit
   hook fires on every `implement(` commit and reads `FEATURE_PORT` /
   `COMPOSE_PROJECT_NAME` from the environment; unset, `docker-compose.yml`
   falls back to its defaults, which are another plan's container name and
   port. One fix-cycle commit deployed a PLN-002 build as `...-pln001` on 8101
   — a live collision if PLN-001's own container is up.
5. **Fix each unchecked finding** — address the issue, then check it off in `$DEVELOP_ROOT/plans/PLN-NNN-<slug>/findings.md`:
   ```markdown
   - [x] **Code**: Login endpoint returns 500 on empty password (src/auth.ts:42)
   ```

   **A finding you cannot fix without editing `plan.md` is not yours, whether or not it says ESCALATED.** Before fixing, name the file the fix edits. If that file is the plan — a Step, a Tests-table row, an acceptance criterion, a Design Decision, the Rollback section — stop: the Rules bar you from those sections, and no amount of re-reading resolves the contradiction between "fix every finding" and "do not edit the plan". Leave it unchecked, mark it `← ESCALATED` so `lv-findings-route.sh` routes it correctly next time, append a line to `progress.md` naming the finding and the section it would have to touch, and send the plan back:

   ```bash
   DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
   cd $DEVELOP_ROOT
   $DEVELOP_ROOT/scripts/lv-exec.sh lv-docker-down.sh PLN-NNN-<slug>   # if you started a container
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN active draft \
     --commit "implement(PLN-NNN-<slug>): finding needs a plan amendment — back to spec" \
     --add plans/PLN-NNN-<slug>/findings.md plans/PLN-NNN-<slug>/progress.md
   scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
   ```
   Fix any other findings that *are* code-level first — one round trip carrying every code fix beats a bounce per finding. The planner amends the plan and sends it back.

   Verify is supposed to mark these `← ESCALATED` so they route to `draft` rather than to you, and every `**Spec**` finding now does. This rule is what you apply when one arrives unmarked anyway — client-a's PLN-007 got one whose only fix was rewording a Tests-table row, and the implementer was left choosing which rule to break (WFI-078). Escalating is always the safe choice: a plan sent back for a one-line amendment costs a planner turn, a plan silently edited by its implementer costs the review that the amendment would have had.

   **A real bug in code this plan never touched is a third case, and it is neither of the first two.** Fixing it violates "no unrelated refactoring"; escalating it is wrong because there is nothing for a planner to amend — the plan is not contradicted by a defect somewhere else. client-a's WFI-081 had no route for it and opened a `needs-input` gate rather than guess, which is the right instinct and the wrong cost. The route is the one verify already uses for out-of-scope security work: **file it, tag it, move on.**

   ```bash
   DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
   cd $DEVELOP_ROOT
   # One call: allocates through the counter, writes bug.md in the shape the
   # rest of the pipeline parses, and commits it pathspec-scoped. Hand-writing
   # the folder is how two bugs bypassed the counter entirely (WFI-133).
   eval "$(scripts/lv-exec.sh lv-bug-new.sh "<short title>" \
     --severity "<the severity you actually observed>" --source agent:lv-implement \
     --description "<the finding text>" \
     --steps "<how you reproduced it, and how reliably>" \
     --links "surfaced during the fix cycle of PLN-NNN; owning code belongs to PLN-MMM")"
   # → $BUG_ID, $BUG_DIR
   ```
   Then in `findings.md`, mark the finding `← BROAD-SCOPE` and name the bug on the same line. `lv-findings-route.sh` deliberately does not route on a `BROAD-SCOPE` finding, so it neither holds the plan in `active` nor sends it to a planner — which is exactly right for work that is now tracked somewhere else. Leave the box unchecked: you did not fix it.

   ```markdown
   - [ ] **Code**: AttemptLimit test fails 3/3 under the full suite, passes 5/5 in isolation — EnrolmentTests.cs belongs to PLN-005, filed as BUG-041 ← BROAD-SCOPE
   ```

   The bar is that all three hold: it reproduces, the code is outside this plan's declared scope, and the plan's own text is not wrong. If the failure is in code this plan *did* touch, it is yours however unrelated it feels.

5b. **A finding with nothing to implement — `← MANUAL-TEST`**

   A fix cycle sometimes arrives with no fix in it: the only unchecked findings restate an open `#### Manual` acceptance criterion that needs a human at a real keyboard — real hardware, real credentials, a state no unattended session can produce. There is no code to write, and there is nothing to escalate either: the plan is not wrong.

   Tag it and leave the box unchecked, exactly as with `BROAD-SCOPE`:

   ```markdown
   - [ ] **Manual**: (eyes:blocking) criterion 3 needs a real terminal with 4+ pending packages — not producible unattended ← MANUAL-TEST
   ```

   `lv-findings-route.sh` does not route on it, so the plan reaches `testing`, where the manual gate is the mechanism that resolves it. **Do this rather than opening a gate to ask what to do.** Untagged, the item routes the plan to `active` — back to you, with the same nothing to do — and the cycle repeats: client-a's PLN-204 went round three times on two such lines, re-asking a human the identical question each pass (WFI-203, WFI-204, WFI-205).

   The bar is the same one as above, applied to a different axis: **name the file the fix edits.** If there is no file — only a person and a machine you do not have — it is a `MANUAL-TEST` item. If there is a file under `src/` or `tests/`, it is yours.

6. **Re-run build/tests** via haiku agents
7. **When all findings are checked off** — commit and return to Phase 3 exit:
   ```bash
   DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
   eval "$($DEVELOP_ROOT/scripts/lv-exec.sh lv-plan-port.sh PLN-NNN-<slug>)"
   git add src/ tests/
   git commit -m "implement(PLN-NNN-<slug>): fix findings"
   $DEVELOP_ROOT/scripts/lv-exec.sh lv-claim.sh PLN-NNN-<slug>
   # Then follow Phase 3 steps 23-26 (uses $DEVELOP_ROOT)
   ```
   The first two lines are here because this is the one step in the fix cycle
   that both commits and is routinely run in its own bash call — step 4's eval
   is two steps and possibly hours behind, and shell variables do not survive
   that. Without them the post-commit hook deployed a PLN-003 build as
   `...-pln001` on 8101 (WFI-041). This re-triggers the verify agent.

---

## Worktree workflow

```
(develop)
  /lv-implement
    → Phase 1: lock plan (REGISTRY ready→active), create worktree
    → Phase 2 (in worktree): code all steps, review, test
    → Phase 3: REGISTRY active→verify (triggers verify agent), return to develop
(develop) done

(verify agent runs automatically)
  → clean: REGISTRY verify→testing (T4 picks up)
  → findings: REGISTRY verify→active (T3 fix cycle)
  → escalated: REGISTRY verify→draft (T2 replans)
```

## Docker port configuration

| Range | Use |
|-|-|
| 8000-8099 | Static site, staging (8081) |
| 8100+ | Feature branches (8100 + plan ID) |
| 8080 | Default local dev |

Project name: `{{project_slug}}-pln<id>` (e.g., `{{project_slug}}-pln004`)

## Rules

- **Do NOT** make design decisions not covered by the plan
- **Do NOT** add features, refactoring, or improvements beyond what the plan specifies
- If the plan is ambiguous, note it in progress.md and continue — or ask the user
- You may edit src/, tests/ and update progress.md / check off findings
- **Do NOT** edit the plan's Steps, Tests, Design Decisions, acceptance criteria or Rollback sections — this holds even when a finding assigned to you can only be resolved there. That finding is misrouted; escalate it (see [Fix cycle](#fix-cycle-plan-returned-to-active-by-verify-agent) step 5) rather than picking one of the two rules to break.
- **Do NOT** raise findings — a finding is a verdict on the work, and only the verify agent and `/lv-test` deliver those. Checking an existing one off is yours; opening a new one is not.

  This is narrower than the old "do NOT add findings", which read as a ban on writing to `findings.md` at all and collided with plans whose own checklist told the implementer to record something there (client-a WFI-068, where a Regression Scope item said to note in findings.md that another plan's criterion had become testable again). **When a plan instructs you to record an observation, write it to `progress.md` and check the item off with a pointer to it** — that is the implementer's notebook, and it is read by verify. If the observation is "this criterion can now be tested", the right home is neither file: `lv-defer-criterion.sh` already owns `plans/deferred-criteria.md`, and `/lv-spec` reads it back.

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `lv-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-implement \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the claude-workflow library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

## Usage

```text
/lv-implement           take the first selectable plan (new, resume or fix) and build it
/lv-implement <PLN-ID>  build that plan
  in the menu:  u <N>            mark row N urgent (again to clear)
                force <PLN-ID>   take a plan the menu would not offer
```
