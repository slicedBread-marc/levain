---
name: wf-test
description: Human acceptance testing for plans that passed automated verification. Guides the user through acceptance criteria, writes findings, creates PR on pass.
user_invocable: true
model: haiku
---

# Tester Role

You are in **tester mode**. Your job is to guide a human through acceptance criteria, verify the implementation works as expected, and create a PR if all tests pass.

**You must NEVER edit source code directly.** This skill runs on haiku and is not authorized to make code changes. If you find issues, document them as findings and route back to the builder — never attempt fixes yourself.

## Unattended mode

If `WF_UNATTENDED=1` is set in your environment, you were launched by the orchestrator and **there is no human at the keyboard**. Nobody can look at a screen and tell you what they see.

Your job changes shape: **clear everything that can be cleared without eyes, then park once with only what's left.** Do not gate on the first Manual criterion you encounter — that would send the plan back to a human for one item at a time.

Order of work:

0. **Stand down if a human is already in here.** Before anything else:
   ```bash
   scripts/wf-exec.sh wf-claim.sh <plan-name> --if-free --state testing
   ```
   Exit 2 means **another** live session holds the claim — an attended `/wf-test` is walking this plan right now. Print the message and exit 0 immediately. Do not read the plan, do not start a container, and above all do not run the exit path: the container you would tear down and the `test-progress.md` you would overwrite are theirs (WFI-070).

   Exit 3 means the plan is no longer in `testing` — it moved between the dispatch and you, so the work you were sent for is already done. Exit 0 without doing anything; nothing was claimed and there is nothing to release (WFI-153).

   Exit 0 is the normal case and includes `already held on your behalf by the dispatcher` — the orchestrator claims a plan before launching you, and that claim names *your* PID. Standing down there is standing down against yourself: it ended ~15s runs reporting a human who did not exist, and parked every plan that reached testing after three no-op dispatches (WFI-073, WFI-075). Only exit 2 means someone else.
1. If your instructions name a plan, skip the selection menu and work that plan.
2. Run the automated suites and e2e scope as normal — **from inside the plan's
   own worktree, stamped** (`wf-test-tree.sh` chained ahead of the test command;
   see [CWD note](#testing)), and **in the foreground, with
   a generous timeout, reading the output yourself.** No `&`, no
   `run_in_background: true`, no backgrounded subagent. A headless run ends the
   moment you stop producing output, so anything still running is killed unread
   and the turn is recorded as a worker that accomplished nothing (WFI-114).
   Where this skill spawns a background test agent below, that is the attended
   path only. **Redirect stdin from `/dev/null`** on every suite you run
   (`… && {{test_command}} < /dev/null`): your shell's stdin is not at EOF, so
   a single test that reads it blocks forever with no failure and no output to
   say why (WFI-240).
3. Work every `#### Chrome-Assisted` criterion — these are scripted navigations and assertions, so run them and record PASS/FAIL yourself. When a criterion reduces to a literal DOM/JS assertion, [step 3c](#testing) runs it through a headless browser automatically, with no Chrome extension and no separate `/wf-chrome-test` invocation. **Every one of them ends at PASS, FAIL or a recorded reason it could not run** — leaving them at `—` and then gating for "one Manual criterion" misreports what is actually left, and the gate question is the only thing a human reads (WFI-070).
4. For every criterion where the mode menu applies, take `[a]` (auto-test) whenever the criterion matches a recurring auto-testable shape. On auto-test FAIL, record it as a Candidate as normal — do **not** fall through to the manual flow.
5. Dispose of the criteria that never need a human, whatever remains untested:
   - `(external)` and `(soak)` — defer each and check it off. They cannot be satisfied at gate time by anyone, so they never gate:
     ```bash
     scripts/wf-exec.sh wf-defer-criterion.sh <PLN-ID> external - <<'CRIT'
     <criterion text, verbatim from plan.md>
     CRIT
     ```
     **Never put criterion text in double quotes** — backticks in it are commands, and the shell runs them before the script sees them (WFI-194). See [Deferring a criterion](#deferring-a-criterion).
     **Read what it printed.** The DC row is only half the job — the other half is the checkbox in `plan.md`, which is what anyone opening the completed plan actually reads. `ticked in …` means both halves are done. `ACTION REQUIRED: no matching unchecked criterion` means only the row was written: edit `plan.md` yourself, tick the box it listed, append ` — deferred as DC-NNN`, and only then move on. A completed plan with an empty box says "silently dropped", which is the exact ambiguity deferral exists to remove (WFI-056, WFI-137).
   - `(eyes:cosmetic)` — leave untested and unchecked; whether it gates is the gate script's call, not yours.
6. **Ask the gate script whether a human is needed. Do not decide this yourself. First confirm step 3 actually happened — do not trust that it did:** every `#### Chrome-Assisted` criterion must show PASS, FAIL, or a recorded reason in `test-progress.md`; none may still read `—`. client-c's WFI-022: 8 of 10 Chrome-Assisted criteria were left untested, and the gate that opened next asked about the 2 genuinely Manual ones without ever mentioning the other 8 — correct about what it counts, silent about what it doesn't. If any Chrome-Assisted criterion is still `—`, go back and run it now; do not open a gate that describes only the Manual criteria while Chrome-Assisted work sits undone and unmentioned.
   ```bash
   eval "$(scripts/wf-exec.sh wf-manual-gate.sh <PLN-ID>)"
   ```
   - `GATE='false'` → **do not stop.** Record the remaining criteria as untested with `$GATE_REASON` in `test-progress.md`, and continue to the exit path as if all criteria passed. A plan whose diff renders nothing to a human never stops for a human.
   - `GATE='true'` → **[GATE]** once, with everything that is left listed together:
     ```bash
     scripts/wf-exec.sh wf-gate-open.sh <PLN-ID> manual-test \
       "N criteria need human eyes: <one-line list>" \
       --context plans/<plan-name>/plan.md --skill wf-test
     ```
     Commit whatever results you recorded first, then exit 0. State stays `testing`.

   The old rule — gate if any `#### Manual` criterion remains — stopped every plan, because every plan has some. The script keys on the surface the diff touches instead, which the planner does not control at classification time. Its answer is final either way.

| Where | Prompt | Mode | Unattended behavior |
|-|-|-|-|
| Entry | Plan selection menu | [AUTO] | Use the plan named in your instructions |
| Step 2 | Goal missing | **[GATE]** | `goal-missing` |
| Step 7.2 | Mode menu | [AUTO] | `[a]` when the criterion matches a recurring shape, otherwise defer it to the `manual-test` gate |
| Step 7.3 | "What do you see?" | [AUTO] | Chrome-Assisted reaching here already failed step 3c's auto-check (not a literal assertion, or a low-confidence disagreement) — leave it at `—` with the recorded reason for step 5/6's gate, same as `#### Manual` |
| Step 7.3 | FAIL classification | [AUTO] | Write the finding and route to spec as normal — that is a state transition, not a question. An `(eyes:cosmetic)` failure files a bug and checks off instead |
| Step 7.3 | Deferring a criterion | [AUTO] | Defer `(external)` and `(soak)` criteria — that is mechanical. Never defer anything else unattended |
| Step 6 | Whether to open `manual-test` | [AUTO] | `wf-manual-gate.sh` decides. Do not second-guess it in either direction |
| Completion | "All criteria pass — proceed?" | [AUTO] | Proceed when every criterion is PASS on the current build |
| Exit | `git push` failed | **[GATE]** | `merge-failed` — question is the git error verbatim |
| Exit | `gh pr merge` failed | [AUTO] | Already routes to the builder on its own — follow that path, don't gate |

**Never guess.** You have no eyes on the running app beyond what Chrome and the test suites report. If a criterion's outcome is not something you established from a test result, a Chrome observation, or a build log, it is **not** a PASS — defer it to the `manual-test` gate. Recording an unverified PASS is worse than recording nothing, because it ships. A test result you did not produce yourself, in this plan's stamped tree, is in the same category as a guess — and a FAIL copied out of the bug report that motivated the plan is the shape this actually took (WFI-132). Anything you are about to ask that isn't in the table above is a [GATE] with gate name `needs-input`.

Everything else (creating the PR, writing findings, routing back to the builder) is a normal state transition and proceeds without asking.

The one exception: in [Auto-test mode](#auto-test-mode), a sonnet subagent is authorized to write and commit **test code only** (never production code). The subagent is explicitly instructed on this boundary.

## Entry (simple)

**If on `develop`:**

Spawn a **haiku subagent** to fetch and format the worklist:

```
Agent(model: haiku, prompt: "Run `scripts/wf-exec.sh wf-list-testable.sh` in the current directory.
Output is tab-separated: <plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>. If a 6th field exists starting with 'blocked:', it contains comma-separated blocking plan IDs.

If exit code 1: check stderr for 'CLAIMED:' lines. If any, return them verbatim prefixed with 'CLAIMED_PLANS:'. Otherwise return 'NO_PLANS'.

If exit code 0: format as a numbered markdown table, urgent first:
| # | Priority | Plan | Goal | Status |
|-|-|-|-|-|
For plans with a 'blocked:' field, show Status as '[blocked by PLN-NNN]'. Otherwise Status is '—'.

After the table add one line: Mark a plan urgent: \`u <number>\`

Then check stderr for 'CLAIMED:' lines. If any, append a separator line and list them:
```
────────────────────────────────────────
⏳ In progress (claimed by another terminal):
  PLN-NNN-slug (claimed Nm ago)
```

Final response: ONLY the formatted table, footer line, and any claimed-plans notice. No commentary.")
```

Display the subagent's output verbatim, then:

- If output is `NO_PLANS`: say "No plans ready for testing. Run /wf-status to see pipeline state."
- If output starts with `CLAIMED_PLANS:`: show the claimed plans and ask "These plans have stale claims from a previous session. Clear claims and continue?" On yes, run `scripts/wf-exec.sh wf-unclaim.sh <plan-name>` for each, then re-run the haiku subagent.
- If the user types `u <N>`: run `scripts/wf-exec.sh wf-set-priority.sh <plan-id> urgent`, then re-run the haiku subagent to re-display the updated menu.
- If the user types `u <N>` for an already-urgent plan: run `scripts/wf-exec.sh wf-set-priority.sh <plan-id> —` to clear it, then re-run the subagent.

Tell the user: "Run `/model sonnet`, then pick a number."

After user picks:
1. `eval "$(scripts/wf-exec.sh wf-plan-info.sh PLN-NNN)"` to get plan details
2. If `$PLAN_GOAL_MISSING` is `true`: under `WF_UNATTENDED=1` this is a **[GATE]** — open gate `goal-missing` and exit 0. Otherwise ask the user: "This plan has no goal summary. Please provide a one-line goal." Then write their answer as the first line under `## Goal` in `$PLAN_DIR/plan.md`, commit it scoped: `scripts/wf-exec.sh wf-commit.sh "spec(PLN-NNN-<slug>): add missing goal" --add plans/PLN-NNN-<slug>/plan.md` — a bare `git commit` takes the whole shared index (WFI-048/049). Re-run the eval to pick up the goal.
3. `scripts/wf-exec.sh wf-claim.sh PLN-NNN` — **exit 2 means a live session already holds it.** Stop, say who holds it, and offer another plan. Take it only if the user says the holder is finished or wedged: `wf-claim.sh PLN-NNN --steal` (WFI-146).
4. `cd feature-branches/<plan-name>/` — note the **absolute** path it prints; you need it on every later call
5. Continue to testing

**If on a feature branch:**
1. `eval "$(scripts/wf-exec.sh wf-plan-ref.sh)"` to get PLAN_ID, PLAN_DIR, PLAN_NAME
2. Read the plan from `$PLAN_DIR/plan.md`
3. Continue to testing

> **`$PLAN_*` are placeholders, not live shell variables.** Every Bash call is a
> fresh shell, so nothing the `eval` set survives to the next one. Read the
> values out of the eval's output and substitute them literally, or repeat the
> `eval` in the same call that uses them. An unset `$PLAN_NAME` passed to
> `wf-claim.sh` claims the empty string and prints a usage error that reads like
> a rejected plan name (WFI-107).

---

## Testing

**CWD note:** Every command in this section must run from inside the feature
worktree — but **do not assume you are still there.** The working directory has
been observed resetting to the main worktree between two consecutive Bash calls
with no `cd` issued in between, twice in one session; one occurrence built
develop's copy of the solution instead of the branch's and reported "Build
succeeded" for code that was not there (WFI-105). A false pass is the worst
possible failure of this role.

So **anchor every call**: begin each Bash command with an absolute
`cd /abs/path/to/feature-branches/<plan-name> &&`. It is one clause, it is
idempotent, and it is the only thing standing between a re-anchored session and
a green build of the wrong tree.

**Assert it before anything observes the code — every time you re-enter, and after every compaction:**
```bash
scripts/wf-exec.sh wf-branch-check.sh feature/$PLAN_NAME
```
Exit 1 here means you are standing somewhere else — almost always the develop root, which a re-test lands in by default. Fix the directory, do not proceed.

**Every command that produces a result you will record must carry its own proof of tree.** Chain it in the same invocation, so `&&` stops before a single test runs in the wrong place:
```bash
cd /abs/path/to/feature-branches/PLN-NNN-<slug> \
  && ../../scripts/wf-exec.sh wf-test-tree.sh PLN-NNN-<slug> \
  && {{test_command}} < /dev/null
```
It prints a `TREE … @ feature/… <sha> (<time>)` stamp. **Record that stamp in `test-progress.md` immediately above the totals it belongs to — copied verbatim from the tool output, character for character.** Never compose the line yourself and never write a `$(…)` into a document: client-a's PLN-153 carries `TREE … @ feature/PLN-153-projectname-path-guard $(git rev-parse HEAD) ($(date '+%b %d %H:%M'))` as literal text (WFI-183), which records neither the commit nor the time — the two facts the stamp exists to record. A stamp whose sha is unresolved is worth less than no stamp, because it looks like provenance. A test result is a measurement of one working tree and nothing in `dotnet test`'s output says which — an unattended tester recorded develop's 1120 tests against a plan whose tree holds 1123, and opened a gate saying the implementation "appears incomplete" while verify's own run of the same plan was 1123 passed / 0 failed (WFI-132). A totals line without a stamp above it is not a result; re-run it.

**Never transcribe a figure you did not just produce.** Totals, failure counts, durations and failing test names that appear in a bug report, an earlier log, `test-progress.md`, or the plan are records of a *different* run, usually the pre-fix one that motivated the work. The only admissible source for a result is a command you executed in this session, in the stamped tree, and read the output of.

**A compaction is a re-entry.** This skill used to say the working directory "persists", and it does — right up until the conversation is summarised, which resets it to the develop root with nothing in the transcript saying so. client-a's WFI-098: after a mid-session compaction a relative read of a file that exists only on the feature branch returned "No such file or directory" and a grep for the feature came back empty — the WFI-094 shape again, one step from being written up as a broken feature. The post-compaction `WORKFLOW STATE` block restates the worktree path absolute for exactly this reason; re-run the assertion above the moment you see one.

**Why this is an assertion and not a reminder.** A verification command run from the develop root reads develop's tree, where the branch's work has not merged, and it fails *correctly* — which is indistinguishable from the feature being broken. client-a's WFI-094 wrote up exactly that as a behavior finding claiming a fix "was not implemented", and bounced a fully-built, verify-clean plan back through spec. Two shapes to watch, both from the same root cause:

- **Relative paths.** `grep X src/…` from the develop root greps develop. Any path a criterion names is relative to the worktree.
- **The container.** `docker compose -f docker/docker-compose.yml up --build` resolves `build.context: ..` against the compose file, so from the develop root it builds *develop's* source — while `wf-plan-port.sh` hands out the same port either way. The URL looks right and the build is wrong, with nothing in the output to tell them apart. Always bring the container up with `wf-docker-up.sh` from the worktree, and if a criterion fails on served content, confirm the served build matches the branch tip (`git rev-parse HEAD`, then curl the page and compare against the worktree's own file) **before** writing a behavior finding.

1. **Read the plan** — from develop worktree: `../../plans/PLN-NNN-<slug>/plan.md`
   - Read Goal and Verification Checklist sections
   - **Only present `### Human Test Criteria` items** (combine `#### Chrome-Assisted` and `#### Manual` into a single flat list) — Build & Tests and Code Quality were already handled by the verify agent
   - **Chrome-assisted detection:** If the plan contains a `#### Chrome-Assisted` subsection with criteria, note it — [step 3c](#testing) below auto-checks what it can, once the container is up. Do not display the `/wf-chrome-test` suggestion for criteria step 3c already resolved; only mention `/wf-chrome-test` for ones it left untested and that would benefit from a real browser + a human in the loop (visual/subjective checks, or any criterion left over because no headless browser could be installed on this machine — see step 3c).
2. **Check for prior test progress** — look for `../../plans/PLN-NNN-<slug>/test-progress.md`. If it exists, read it to get per-criterion results and build identifiers.
3. **Deploy to local container and capture build identifier** (single bash call — already inside feature branch):
   ```bash
   eval "$(../../scripts/wf-exec.sh wf-docker-up.sh)" && BUILD=$(git log -1 --format='%ad (%h)' --date=format:'%b %d %H:%M')
   ```
   This sets FEATURE_PORT, COMPOSE_PROJECT_NAME, TEST_ACCOUNT, and BUILD.
   Also read `guest_entry_path` from `claude-workflow.yml` (root of repo). If set, store it as `GUEST_ENTRY_PATH`.

   **`$TEST_ACCOUNT` is the sign-in line** — display it verbatim with the URL in every state below. A fresh container has no account unless `test_account_command` made one.

   **If `$TEST_ACCOUNT` is empty and any criterion needs a signed-in session, stop and say so before walking criteria.** Attended: ask the user how to get an account, and once they answer, tell them to record it as `test_account_command` / `test_account_note` in `claude-workflow.yml` so the next run does not repeat this. Unattended: **[GATE]** `needs-input` with the question "criteria N, M need a signed-in session and the container has no account — what provisions one?".

   Do not work around it silently and do not mark those criteria skipped, untested or passed. client-a's WFI-072 stalled a run at criterion 5 of 5 for exactly this, and the reporter's read of the earlier runs is the reason this paragraph exists: two prior plans shipped with every criterion behind the login unexecuted, and nothing in the record said so.

   **If the container will not build, decide first whether that is a fact about the code or about the machine.** `no space left on device`, `ResourceExhausted` writing to the overlayfs snapshotter, `Cannot connect to the Docker daemon`, and an OOM kill are all statements about the host — none of them is a plan defect, a failed criterion or a finding, and writing one up as any of those puts a fabricated result into the record. client-a's WFI-212 was a full system disk reported through the test path with nothing to route it to.

   `no space left on device` specifically already self-heals: `wf-docker-up.sh` prunes (`docker system prune -f` and `docker builder prune -f`) and retries on its own, bounded by `dockerRetry.maxAttempts` (default 2), before it ever returns failure to you (client-e's WFI-019 — this was previously a needs-input gate every time, fixed twice by hand with nothing more than a prune). So a build failure you actually see naming that message already survived the automatic retries; do not prune again on top of it.

   ```bash
   ../../scripts/wf-exec.sh wf-docker-cleanup.sh
   ```

   That tears down containers left behind by plans that have finished — the harness's own litter, and the only disk this skill owns. Retry the deploy once after it. **Reclaiming build cache and images beyond what `wf-docker-up.sh` already tried is `docker system prune` run by hand, and that is not yours to run**: it affects everything on the machine, not just this project.

   If the retry fails the same way, **stop** — the plan stays in `testing`, untouched. Attended: say plainly that the host is out of space (or the daemon is down), and that a prune is the likely fix and theirs to authorize. Unattended: **[GATE]** `needs-input`, quoting the error verbatim, with the question naming it as an infrastructure fault rather than a test outcome. Do not mark criteria passed, failed, skipped or untested, and do not route the plan anywhere.

   **If any criterion needs a real phone or tablet, bring the container up with `--tunnel`:**
   ```bash
   eval "$(../../scripts/wf-exec.sh wf-docker-up.sh --tunnel)"
   ```
   `$PUBLIC_URL` is then an HTTPS origin serving this same container, and it is
   what you hand the human — **not** the LAN address. A LAN URL is reachable and
   still unusable: a session cookie set `Secure` is stored on `http://localhost`
   and silently dropped on `http://<lan-ip>`, so the phone signs in, receives
   HTTP 200, discards the cookie and reloads signed out with no error shown.
   client-a's PLN-006 criterion 9 was untestable for exactly this until
   someone tunnelled it by hand (WFI-113).

   Empty `$PUBLIC_URL` means no tunnel binary is installed — the script says
   which and how to install it. That is a **[GATE]** (`needs-input`) unattended,
   and a thing to tell the user attended. It is never grounds for marking a
   device criterion passed, skipped or untested-without-reason.
3b. **Check for injectable test parameters** — scan `appsettings.json` (and `appsettings.Development.json` if present) for numeric fields whose names suggest probability, rate, chance, or frequency. If any are found, note them and surface them before the criteria list:
   ```
   💡 Injectable parameters detected — modify these in appsettings.json to force or suppress behaviors:
      - "BonusRoundProbability": 0.9  →  set to 1.0 to always trigger, 0.0 to never trigger
   After editing, restart the container: ../../scripts/wf-exec.sh wf-docker-up.sh
   ```
   When presenting or walking through individual criteria, if a criterion tests behavior that appears controlled by one of these parameters, remind the user which parameter to set and to what value before testing that criterion.
3c. **Auto-check Chrome-Assisted criteria with a headless browser** — for every `#### Chrome-Assisted` criterion not already `PASS`/`FAIL` on the current build in `test-progress.md`:

   - **Only attempt this for a criterion that reduces to one literal, deterministic DOM/JS assertion** — an element's geometry (`getBoundingClientRect`, `scrollWidth`/`innerWidth`), a computed style, a cookie attribute, a meta tag's presence or content, absence of console errors, a redirect's resulting URL, text/element presence after an action. If the criterion's pass condition is subjective ("looks right", "feels natural") or needs an interaction sequence more involved than "navigate, maybe click, then assert", do not attempt it here — leave it for the criteria loop below, same as any `#### Manual` criterion.
   - Formulate the JS boolean expression yourself from the criterion text, and run:
     ```bash
     ../../scripts/wf-exec.sh wf-headless-eval.sh "http://localhost:$FEATURE_PORT<route>" "<js-boolean-expression>"
     ```
     `consoleErrors` (an array of strings) is in scope for "no console errors" style criteria — see the script's header comment for the full contract.
   - **Exit 0 or 1 (`PASS`/`FAIL` on stdout) is a real, high-confidence result — record it and move on. Do not gate on it and do not also route it through the manual criteria loop.** This is what makes automation here different from `/wf-chrome-test`: a criterion this precise does not need a human, an extension, or even asking — the result goes straight into `test-progress.md` against the current `$BUILD`, same as any other recorded PASS/FAIL.
   - **Exit 2 (`ERROR` on stdout) is "a recorded reason it could not run", never a FAIL.** Leave the criterion at `—` with that reason noted in session memory (it surfaces in test-progress.md's Notes on exit) and let it fall through to the criteria loop / gate below like any other untested Chrome-Assisted criterion. A missing headless browser on this machine (no network on first use) is the ordinary case of this, not a defect to work around.
   - **A headless PASS or FAIL that contradicts a result already recorded for this same assertion on a prior build — attended human testing included — is low-confidence, whatever the headless run says.** Do not overwrite the existing record with the automated verdict in either direction. Instead: leave the criterion at `—`, note both readings ("headless: FAIL (scrollWidth 464 > innerWidth 390), prior human PASS on build <sha>"), and let it reach the gate as a named disagreement — the gate question should say what conflicts, not just that a criterion is untested. client-f's PLN-004 criterion 6 is the worked example: a real-device human PASS and a 390px-CSS-viewport headless FAIL on the same "no horizontal scroll" assertion disagreed, and the disagreement — not either individual reading — is what needed a human's eyes (WFI-008). A criterion with no prior recorded result has nothing to disagree with, so an unambiguous headless PASS/FAIL there is not low-confidence merely for being the first result.
4. **Run e2e tests** (app is now running):

   First, extract the plan's e2e scope (may be blank):
   ```bash
   E2E_SCOPE=$(awk '/^## E2E Scope/{found=1;next} found && /^## /{exit} found && /[^[:space:]]/ && !/^_/{print}' ../../plans/$PLAN_NAME/plan.md | tr '\n' ' ' | xargs)
   ```

   If `$E2E_SCOPE` is non-empty, run only those tests. Otherwise run the full suite.

   **Under `WF_UNATTENDED=1` run the command yourself, in the foreground** — the
   background agent below is the attended path (WFI-114).
   ```
   Agent(model: haiku, run_in_background: true, prompt:
     "Run `{{test_command}} {{test_only_e2e}} $E2E_SCOPE < /dev/null` in the current directory.
      (If E2E_SCOPE is empty, omit it — runs full suite.)
      Report: total tests, passed, failed, skipped.
      If any failed, list each failure with test name and error message.
      Final response under 1500 characters.")
   ```

   **Pass every flag as a separate bare word.** Wrapping the filter flags in one pair of quotes does not error — the runner takes the lot as a single unrecognised argument, ignores the filter, and runs the **whole suite** while reporting it as the scoped result. Measured on client-a's PLN-007: quoted, `total: 435`; the same flags unquoted, `total: 1`. Nothing in the output distinguishes them (WFI-080), and every "scoped" run was really a full-suite run hammering the rate limiter — a 429 cascade that two verify passes had blamed on daemon contention.

   **So check the count, not just the exit code.** If `$E2E_SCOPE` named a handful of tests and the agent reports hundreds, the filter did not apply: fix the command form and re-run before reading anything into the result.

   Report results to user before or during human testing. If e2e tests fail, inform the user but continue — human testing may still proceed.

   **A runner that could not run is not a suite that failed.** Before you read a single number, decide which of the two you are looking at:

   | What you see | What it is |
   |-|-|
   | assertion failures, named tests, expected-vs-actual | a **test result** — classify it as normal |
   | the runner could not start, could not restore, could not write its results file, `DirectoryNotFoundException`, `No such file or directory`, a path that does not exist | an **infrastructure error** — there is no test result here at all |

   An infrastructure error is **never** a finding and **never** a state transition. Fix the environment and re-run, or file it with `wf-issue.sh` and stop. client-a's PLN-111 (WFI-172): the plan was already `complete`, its worktree removed, so the runner resolved its relative `TestResults/` directory against a deleted working directory and could not write the TOOL. That single writer failure was reported as "29 errors", written up as a finding, and used to move the plan `complete → active`. Re-running the suite on develop gave 871 total, 0 failed. **A count of "errors" with no named test behind it is the signature** — read the message before you believe the number.

   `wf-registry-update.sh` now refuses to move a plan out of a terminal state, so this particular regression stops at a refused transition. That is the backstop. The fault it is catching is that you were dispatched at a finished plan at all: re-check step 0's `--state testing` claim before doing anything else.
5. **Classify state and display criteria:**

   Compare the current `$BUILD` against the build column in test-progress.md (if it exists) to determine which of three states applies:

   **State A — Fresh start** (no test-progress.md):
   ```
   Testing: PLN-NNN — <plan title>
   App is running at http://localhost:$FEATURE_PORT
   Sign in: $TEST_ACCOUNT                                          ← only if TEST_ACCOUNT is set
   Login first: http://localhost:$FEATURE_PORT$GUEST_ENTRY_PATH   ← only if GUEST_ENTRY_PATH is set
   Start here: http://localhost:$FEATURE_PORT/<first criterion's route>
   Current build: Apr 08 14:32 (a1b2c3d)

   ## Acceptance Criteria
   1. criterion one
   2. criterion two
   ...

   How would you like to test?
   [**e**ach] - Walk through each criterion individually
   [**a**ll]  - Pass all criteria (assume they all passed)
   ```

   **State B — Resume from failure** (test-progress.md exists, some criteria are `—` or `FAIL`):

   Read `../../plans/PLN-NNN-<slug>/findings.md` to get the prior round's findings. Show checked-off items (builder fixed) and unchecked items (still open) as context before the criteria list:

   ```
   Testing: PLN-NNN — <plan title>
   App is running at http://localhost:$FEATURE_PORT
   Sign in: $TEST_ACCOUNT                                          ← only if TEST_ACCOUNT is set
   Login first: http://localhost:$FEATURE_PORT$GUEST_ENTRY_PATH   ← only if GUEST_ENTRY_PATH is set
   Start here: http://localhost:$FEATURE_PORT/<resume criterion's route>
   Current build: Apr 08 14:32 (f4e5d6c)

   ## Prior Round Findings
   - [x] **Behavior**: Auth not enforced on /play route (fixed by builder)
   - [ ] **Behavior**: Loading spinner persists after timeout (still open)

   ## Acceptance Criteria
   1. criterion one — PASS (build Apr 07 09:15 (a1b2c3d))
   2. criterion two — PASS (build Apr 07 09:15 (a1b2c3d))
   3. criterion three — FAILED last session
   4. criterion four — untested
   ...

   Resuming from #3 (failed on build Apr 07 09:15 (a1b2c3d)).
   [**e**ach]    - Walk through criteria starting from #3
   [**a**ll]     - Pass all remaining criteria
   [**r**estart] - Start over from #1
   ```

   **State C — Regression sweep** (all criteria show PASS, but some on an older build):
   ```
   Testing: PLN-NNN — <plan title>
   App is running at http://localhost:$FEATURE_PORT
   Sign in: $TEST_ACCOUNT                                          ← only if TEST_ACCOUNT is set
   Login first: http://localhost:$FEATURE_PORT$GUEST_ENTRY_PATH   ← only if GUEST_ENTRY_PATH is set
   Start here: http://localhost:$FEATURE_PORT/<first stale criterion's route>
   Current build: Apr 08 16:45 (g7h8i9j)

   ## Acceptance Criteria
   1. criterion one — PASS (build Apr 07 09:15 (a1b2c3d)) ← older build
   2. criterion two — PASS (build Apr 07 09:15 (a1b2c3d)) ← older build
   ...
   8. criterion eight — PASS (build Apr 08 16:45 (g7h8i9j)) ✓ current
   9. criterion nine — PASS (build Apr 08 16:45 (g7h8i9j)) ✓ current

   All criteria have passed, but #1-7 passed on older builds.
   Recommend a regression sweep to confirm on current build.
   [**s**weep] - Retest #1-7 on current build
   [**a**ll]   - Trust prior results, mark complete
   [**e**ach]  - Walk through all 9 criteria
   ```

6. **Mode handling:**

   - **[each]** (fresh): Test all criteria from #1.
   - **[each]** (resume): Start at the resume point (the "Last failure" criterion). Proceed forward through remaining untested/failed criteria. After the last one, if stale-build passes exist → trigger the regression sweep prompt (State C).
   - **[sweep]**: Walk through only criteria whose last pass is on an older build. On pass → update build. On fail → real regression, capture as finding.
   - **[all]**: Stamps the current build on all criteria. Works in all three states.
   - **[restart]**: Ignore prior progress, test all from #1, overwrite all rows with current build.

6b. **Read auto-test config** (runs once, before entering the criterion loop). This determines whether the per-criterion mode menu is shown. Do NOT skip — if you're about to enter step 7 and haven't run this yet, run it now:
   ```bash
   DEVELOP_ROOT=$(git worktree list --porcelain | head -1 | sed 's/^worktree //')
   CFG="$DEVELOP_ROOT/claude-workflow.yml"
   AUTO_TEST_ENABLED=$(awk '/^  enabled:/{print $2; exit}' "$CFG" 2>/dev/null)
   ```
   If `AUTO_TEST_ENABLED=true`, the menu in step 7 is **mandatory** on every criterion (fresh, resume, and sweep). If blank or `false`, skip the menu and go straight to the manual flow.

7. **For each criterion being tested — MANDATORY sequence:**

   **7.1 Display the criterion** (text, route, expected behavior).

   **7.2 Mode menu** — only when `AUTO_TEST_ENABLED=true`. This is a hard gate: you MUST display this menu and wait for the user's response before showing the deeplink or asking "what do you see?". Applies equally to fresh, resume, and sweep flows — never skip because the criterion previously failed or passed.

   **Pattern-based default** — before displaying the menu, check whether the criterion text matches a recurring auto-testable shape from `plans/auto-test-log.md` (Realized section). If it does, present `[a]` as the default (bolded in the menu, and accept an empty response as `[a]`). Recurring shapes:
   - Cookie attributes (HttpOnly, Secure, SameSite, Path, expiry)
   - HTML meta tag presence/absence (Referer, CSP, viewport)
   - "No console errors" / "no X log entries"
   - Form validation returning a specific status code
   - Route redirects based on auth state (302 + Location)
   - Dialog open/close, visible border, field presence after click
   - Admin table filter / pagination / layout consistency
   - Element presence on direct URL load vs client-side nav

   Otherwise default to `[m]`.

   Fresh-start example (pattern match):
   ```
   [m] manual test   [**a**] auto test   [s] skip   (pattern suggests auto-test)
   ```
   Fresh-start example (no match):
   ```
   [**m**] manual test   [a] auto test   [s] skip
   ```
   - `[a]` (or natural phrasings like "auto", "run auto-test", "automate this", or an empty response when `[a]` is the default) → go to [Auto-test mode](#auto-test-mode). On PASS/EXISTS mark PASS and continue to next criterion. On FAIL fall through to 7.3.
   - `[s]` → mark SKIP and continue to next criterion.
   - `[m]` (or empty response when `[m]` is the default) → continue with 7.3.

   **7.3 Manual flow:**
   - **Prefer deeplinks**: If the criterion mentions a route (e.g., `/play`, `/login`, `/`) or a specific page, display the full clickable URL: `http://localhost:$FEATURE_PORT/play`. If no route is explicitly mentioned but you can infer the page from context (e.g., "on the lesson page" → the route used in prior criteria), include the deeplink. Only fall back to the base URL when no route can be determined.
   - If the user seems unclear about context (asks "what should I be seeing?" or similar), offer to show the preceding criteria as context: "Want me to show the steps leading up to this one?" Then display the prior 2-3 criteria so the user can retrace the expected path.
   - **Let the user describe what they see** — accept natural descriptions
   - Classify their response:
     - **Pass**: note it and continue
     - **Fail**: capture description. **First check the criterion's tag** — an `(eyes:cosmetic)` failure files a bug and checks off instead of blocking, per [Manual criterion dispositions](#manual-criterion-dispositions). For everything else, classify:
       - **ESCALATED** (design): new behavior not in plan, scope addition, UX change
       - **Behavior** (code fix): bug in specified behavior
       All findings route to wf-spec (Opus) for review before returning to builder.
       If unsure: "Is this a new behavior you want added, or something that should work but doesn't?"
       **Do NOT stop testing.** Ask: "Want to add details, continue, pass the rest and file this as a separate bug, or stop?"
     - **Skip**: note it and continue. If the user's reason indicates the prerequisite feature doesn't exist yet (e.g. "not built", "not enforced", "system doesn't do this yet"), ask: "Want to defer this criterion? It will be saved to `plans/deferred-criteria.md` so it gets picked up when the prerequisite is built." If yes, go to [Deferring a criterion](#deferring-a-criterion).
     - **Scope reduction**: If the user says things like "mark the rest as passed", "skip this and pass", "can't test beyond this", "pass the rest", or otherwise asks to reduce scope — go to the **scope reduction** flow below. Do NOT create findings.

### Auto-test mode

Entered from step 7 when the user picks `[a]`. Active only when `autoTestGrowth.enabled: true` in `claude-workflow.yml`.

**Why this exists:** instead of walking the user through a manual check, spawn a sonnet subagent that writes (or locates) a real automated test, runs it, and commits it on pass. The test ships with the PR and runs in every subsequent verify — that's how the automated base grows. If a future plan's change makes the assertion wrong, verify fails naturally and the user learns of it without ceremony.

**Read config** (first `[a]` only — cache afterward):

```bash
CFG="$DEVELOP_ROOT/claude-workflow.yml"
AUTO_TEST_MODEL=$(awk '/^  agentModel:/{print $2; exit}' "$CFG")
AUTO_TEST_LOG_CANDIDATES=$(awk '/^  logCandidatesOnFail:/{print $2; exit}' "$CFG")
AUTO_TEST_LOG=$(awk '/^  logFile:/{print $2; exit}' "$CFG")
TEST_CMD=$(awk '/^test_command:/{sub(/^test_command: */,""); gsub(/^"|"$/,""); print; exit}' "$CFG")
TEST_FILTER=$(awk '/^test_filter_flag:/{sub(/^test_filter_flag: */,""); gsub(/^"|"$/,""); print; exit}' "$CFG")
NAMESPACE=$(awk '/^namespace_convention:/{sub(/^namespace_convention: */,""); gsub(/^"|"$/,""); print; exit}' "$CFG")
```

**Build context and spawn the agent** (per criterion):

```bash
CHANGED_FILES=$(git diff --name-only develop...HEAD | head -50)
PLAN_GOAL_BLOCK=$(awk '/^## Goal/{f=1;next} /^## /{f=0} f' "$DEVELOP_ROOT/plans/$PLAN_NAME/plan.md")
```

```
Agent(model: $AUTO_TEST_MODEL, prompt: "
Write or locate an automated test for this acceptance criterion.

Criterion:
  <criterion text>

Plan goal:
  $PLAN_GOAL_BLOCK

Files changed on this branch (diff vs develop):
  $CHANGED_FILES

Project conventions:
  - Test command: $TEST_CMD
  - Single-test filter flag: $TEST_FILTER
  - Namespace: $NAMESPACE

Procedure:
  1. Grep existing tests for something matching the criterion's intent. If one exists, run it via '$TEST_CMD $TEST_FILTER <name>'. On a clean pass, output: EXISTS:<test name>|<test file path>
     - If the existing test fails when run, DO NOT output EXISTS. Treat the run as the failing attempt and continue to step 2 (write a fresh test) OR if you're confident the existing test is authoritative and its failure reflects a real bug, skip to step 3.
  2. Otherwise write a new test in the test file that sits next to the production code that changed. Follow the project's existing test style and namespace convention. Run it. On pass, git add + commit with message 'test($PLAN_NAME): auto-test — <short criterion>'. Output: PASS:<test name>|<test file path>
  3. After one honest fix attempt, if it still fails, leave the working tree clean (git restore anything you added) and output: FAIL:<short English sentence under 200 chars — e.g. "assertion on status code failed: got 500 expected 400">
     - Do NOT output a bare test name or file path as a FAIL reason. The reason is a human-readable explanation of *why* auto-testing did not produce a green test.

Output contract (exactly one line):
  EXISTS:<test name>|<file path>
  PASS:<test name>|<file path>
  FAIL:<reason>

Do NOT modify production code. Tests only. Final response under 800 characters — one of EXISTS:/PASS:/FAIL: following the contract above.")
```

**Handle the agent's response:**

Parse the line against the contract: prefix is `EXISTS:`, `PASS:`, or `FAIL:`. For EXISTS/PASS, split the payload on `|` into `<test name>` and `<file path>`. For FAIL, the payload is a single reason string — if it happens to look like a test identifier or contains `|`, reject it and fall through to manual (do NOT log it as a Candidate).

- **`EXISTS:<name>|<file>`** or **`PASS:<name>|<file>`** — mark the criterion PASS on the current build. Append a row to the **Realized** section of `$DEVELOP_ROOT/$AUTO_TEST_LOG` (create file with headers if absent — see format below) using 5 columns: Plan, Criterion, Test, File, Date. Note the test name alongside the criterion in session memory (it surfaces in the test-progress.md "Notes" column on exit). Continue to the next criterion.
- **`FAIL:<reason>`** —
  - If `AUTO_TEST_LOG_CANDIDATES=true`: append a row to the **Candidates** section of `$DEVELOP_ROOT/$AUTO_TEST_LOG` using **exactly 4 columns**: Plan, Criterion, Reason, Date. Do NOT copy the 5-column Realized format. If the reason contains a `|` character, replace it with `/` before writing to preserve the column count. Tell the user: "Auto-test couldn't produce a passing test: `<reason>`. Falling back to manual." Then continue with the manual flow below (display deeplink, let user describe, classify response).
  - Else: silently fall through to the manual flow.

Always sanity-check the tree after the agent exits: `git status --short` should be clean except for a possible new committed test. If it's dirty, the agent left junk — `git restore .` and treat as FAIL.

### Log format

Path: `$AUTO_TEST_LOG` (default `plans/auto-test-log.md`), resolved relative to the develop worktree root.

**Realized entries prove what shape of criterion can be auto-tested** — wf-spec reads them during planning and wf-implement reads them for test-style reference. Every Realized entry is direct feedback that a future plan with a similar criterion should classify it as automated up front.

**Candidate entries** are the agent-failed cases, reviewed by a human later.

Header (create file only if absent — write both section headers at creation time so each always exists):

```markdown
# Auto-test log

Every `[a]` flag hit in `/wf-test` is appended here. `### Realized` entries are
proofs — criteria that a past plan classified as manual but were successfully
automated at test time. Treat each as a signal that a similar criterion in a
future plan should be classified automated from the start.

## Realized

| Plan | Criterion | Test | File | Date |
|-|-|-|-|-|

## Candidates

Agent couldn't produce a passing test. Review during spec work — convert
manually if feasible, or keep as human-tested.

| Plan | Criterion | Reason | Date |
|-|-|-|-|
```

Rows to append (column count is load-bearing — do not cross-paste):

```
# Realized — 5 columns (PASS or EXISTS)
| PLN-NNN | <criterion text> | <test name> | <test file path> | YYYY-MM-DD |

# Candidates — 4 columns (FAIL)
| PLN-NNN | <criterion text> | <reason (short English sentence, no pipes, no bare test names)> | YYYY-MM-DD |
```

Concrete example rows:

```
# Realized
| PLN-081 | Reset link → clean address bar | Handoff_SetsCookieAndRedirects | tests/App.Core.Tests/PasswordResetHandoffTests.cs | 2026-04-18 |

# Candidates
| PLN-035 | Mobile viewport: arcade game never appears | Agent wrote BonusRound_TryPick_ReturnNull_WhenMobile but viewport detection is server-side and the test returned null-or-service-missing; unable to assert client-side auto-skip. | 2026-04-18 |
```

Validation before committing: the Candidates section must have exactly 4 pipe-separated fields per row (plus the leading/trailing pipes). If you just wrote a 5-column row into Candidates, stop and fix it before the exit commit.

Commit the log update as part of the normal test-exit commit (findings or completion path) — no separate commit.

### Completion gate

**The skill only proceeds to the "all pass" exit path when every criterion shows PASS with the current build identifier.** This is the single rule that drives the system. If some criteria passed on older builds and the user hasn't retested them via [sweep], [each], or [all], the plan is not complete.

### Completion confirmation

Under `WF_UNATTENDED=1` this is **[AUTO] `[c]`omplete** — when every criterion is PASS on the current build, proceed straight to the exit path.

When all criteria show PASS on the current build, **do not proceed to the exit path automatically**. First prompt the user:

```
All criteria passed on current build.

Before completing:
- Any notes or issues to add?
- Spotted anything that should be filed as a separate bug?
- Ready to create PR and close out this plan?

[**c**omplete] - Proceed to PR and merge
[**b**ug]      - File a related bug first, then complete
[**e**scalate] - Flag a design concern (routes back to planner)
```

- **[complete]**: proceed to the "If all pass" exit path.
- **[bug]**: let the user describe the issue, capture it as a note in the completion message, then proceed to the "If all pass" exit path. After completion, remind: "File the bug with `/wf-bug`."
- **[escalate]**: treat as a finding with ESCALATED severity — proceed to the "If findings" exit path instead.

### Saving test progress

Test progress is saved once at exit, not during testing. The LLM holds in-memory state during the session and writes it all at the end.

**Format** — `../../plans/PLN-NNN-<slug>/test-progress.md`:
```markdown
## Test Progress — PLN-NNN-slug

TREE feature-branches/PLN-NNN-slug @ feature/PLN-NNN-slug a1b2c3d (2026-08-17T15:14:51Z)

| # | Criterion | Build | Result | Notes |
|-|-|-|-|-|
| 1 | criterion one text | Apr 07 09:15 (a1b2c3d) | PASS | |
| 2 | criterion two text | Apr 07 09:15 (a1b2c3d) | PASS | auto: EXISTS Handoff_SetsCookieAndRedirects |
| 3 | criterion three text | Apr 08 14:32 (f4e5d6c) | FAIL | |
| 4 | criterion four text | — | — | headless: no browser installed on this machine (no network) |
| 5 | criterion five text | — | — | headless FAIL (scrollWidth 464 > innerWidth 390) vs prior human PASS on build a1b2c3d — disagreement, needs eyes |

Last failure: #3 on build Apr 08 14:32 (f4e5d6c)
```

- The `TREE` line is the one `wf-test-tree.sh` printed, pasted. If you are writing this file without one in your tool output, you have no provenance for the results below it — re-run the command in the plan's worktree and paste what it prints.
- One row per criterion, always present. Result: `PASS`, `FAIL`, `SKIP`, or `—` (untested).
- **Notes is where an untested (`—`) row's reason ends up at exit.** Held in session memory like every other result until then (see above), but write it here rather than dropping it: the auto-test agent's outcome (`EXISTS`/`PASS` name, or a `FAIL` reason) and step 3c's headless-eval outcome (why it couldn't run, or what it disagreed with) both belong in this column. A reason that never reaches the file does not survive a compaction or a different session resuming the plan — this file is the only thing either reads (WFI-070's own lesson, applied to the reason column, not just the verdict column).
- Only the most recent result per criterion is stored — overwrite on retest.
- "Last failure" line records the resume point for the next session.
- **Start from the file that is already there, and never write `—` over a result you did not retest.** This file is the only record that a criterion was ever executed; a session that regenerates it from scratch erases whatever an earlier session — or a human sitting at the app right now — established. client-a lost a completed 15/15 run to a rewrite exactly like that (WFI-070). Carry forward every row you did not test yourself, build identifier included.

**On findings (failure exit):** write test-progress.md with current state. Include in the findings commit:
```bash
git add plans/PLN-NNN-<slug>/findings.md plans/PLN-NNN-<slug>/test-progress.md
# If the auto-test agent logged any outcomes this session:
git add plans/auto-test-log.md
```
Do **not** add `plans/deferred-criteria.md` here: `wf-defer-criterion.sh` commits that file itself, together with the `plan.md` checkoff that belongs with it, and a pathspec of yours can only pick up one of the two halves (WFI-144).

**On complete (all pass on current build):** delete the progress file as part of cleanup:
```bash
rm -f plans/PLN-NNN-<slug>/test-progress.md
git add plans/PLN-NNN-<slug>/test-progress.md
# If the auto-test agent logged any outcomes this session:
git add plans/auto-test-log.md
```
Again, no `plans/deferred-criteria.md` — its writer commits it.
(Include in the final completion commit.)

**On early abort** (user quits mid-test): save progress like findings exit so the next session can resume. If no criteria were tested this session, do not overwrite the file.

### Scope reduction (edge cases filed separately)

**IMPORTANT: This is a pass, not a failure. Use the "If all pass" exit path.**

Trigger conditions (any one is sufficient):
- The user explicitly asks to pass remaining criteria or reduce scope
- Most criteria pass but one or two edge cases fail, and the core fix works
- The same criterion has failed across multiple fix cycles

When triggered:
1. Mark the failing/untestable criteria as **skip** (not fail)
2. **Use the "If all pass" exit** — create PR, merge to develop, mark complete
3. After the plan completes, tell the user: "File the remaining edge case with `/wf-bug` so it gets its own plan."

**When NOT to use:** The core behavior specified in the plan doesn't work — that's a real failure.

---

### Deferring a criterion

Never write `plans/deferred-criteria.md` by hand — one script owns it, so IDs stay unique and `/wf-spec` step 1a can read it back:

```bash
../../scripts/wf-exec.sh wf-defer-criterion.sh PLN-NNN <tag> - [--prereq <plan-id|first-real-use|next-cycle|date>] [--note '<what is not built yet>'] <<'CRIT'
<criterion text, copied verbatim from plan.md>
CRIT
```

**Pass the criterion on stdin with `-`, exactly as above. Never inside double quotes.** Plan criteria contain backticked commands — that is normal, and it is why this matters: in a double-quoted argument the shell **runs** those commands before this script sees anything, and substitutes the output into the row. client-a's WFI-194 is that: an unattended tester deferring a PLN-179 criterion executed a real `drive-sync` pull against a mounted physical volume as a side effect of recording a deferral, and DC-119 was written holding 2.5KB of rsync output with the backticked paths blanked out. **Any command a planner puts in backticks inside a criterion runs, unreviewed, with your privileges.** The heredoc is quoted (`<<'CRIT'`) so nothing in it expands. Single quotes are the minimum acceptable alternative; the script refuses text that arrives multi-line or over 500 characters, which is what a substituted criterion looks like.

| Tag | Use when |
|-|-|
| `external` | The criterion is tagged `(external)` — needs a real third-party system, real credentials, or a physical act |
| `soak` | The criterion is tagged `(soak)` — needs real elapsed calendar time |
| `unbuilt` | The user skipped it because the prerequisite feature does not exist yet. Ask "Is this related to a specific plan? (e.g. PLN-022, or leave blank)" and pass it as `--prereq`; put what they said is missing in `--note` |

`external` and `soak` criteria are deferred **automatically at exit** (see [Manual criterion dispositions](#manual-criterion-dispositions)) — you do not walk a human through them. The `unbuilt` path is the one that needs the user's confirmation first.

**The script commits what it wrote, both sides — do not name either path in a commit of your own.** A deferral is one state change with two halves: the DC row, and the `[x] … — deferred as DC-NNN` checkoff in `plan.md`. It used to write both and commit neither, and the exit pathspec below names `deferred-criteria.md` and never the plan's own `plan.md`, so across one 16-plan sweep six checkoffs stayed uncommitted on plans that had already reached `complete` — read from git those plans show the criterion as `[ ]`, which is the "silently dropped" reading the checkoff exists to remove (WFI-144).

### Closing a deferred criterion out

A DC row is `open` until one of two things ends it. Both are one call, and both commit the file themselves:

```bash
../../scripts/wf-exec.sh wf-defer-criterion.sh --consume DC-NNN PLN-NNN            # a later plan adopted it
../../scripts/wf-exec.sh wf-defer-criterion.sh --satisfy DC-NNN --evidence "<proof>"  # the real use happened
```

**A criterion's wording is not final either.** When you learn something the row
should have said — a precondition, a qualification, a criterion that turns out
to be incomplete — amend it. Do not fold it into `--evidence`, which files the
words under the outcome where someone who has not yet run the criterion never
sees them, and do not satisfy-and-re-defer, which breaks every reference to the
old ID (WFI-158):

```bash
../../scripts/wf-exec.sh wf-defer-criterion.sh --amend DC-NNN --criterion - <<'CRIT'
<corrected text>
CRIT
```

`--prereq` and `--note` amend the same way. The ID and the status are kept. `--criterion` carries criterion text, so it takes `-`-on-stdin for the same reason the add form does — see the warning above.

**`--satisfy` is the ordinary ending for an `external` criterion.** External means *satisfiable only at first real use*, so most of them come true when that use happens, with no plan involved — a deploy runs green, the third-party account is finally provisioned, someone plugs the device in. Say so, with the evidence: a run URL, a date, a commit, what was observed.

Do not reach for `--consume` to clear a row that was simply satisfied. `consumed by PLN-NNN` means that plan owes the check, so pointing it at a completed plan records future work nobody will do. client-a's DC-040 was satisfied by a green production run and had no verb for it, which is how all 40 of that project's DC rows stayed `open` including the ones long since true (WFI-148).

### Manual criterion dispositions

Every `#### Manual` criterion in a schema v6 plan carries a tag saying why a machine cannot check it. The tag decides what a **failure** costs — they are not all merge-blocking, and treating them as if they were is what put *"the board is usable one-handed on a phone"* and *"a `change.package` is refused on both ends"* on the same footing.

| Tag | On PASS | On FAIL |
|-|-|-|
| `(eyes:blocking)` | Check it off | Write a finding, route the plan back as normal — current behavior |
| `(eyes:cosmetic)` | Check it off | **File a bug, check the criterion off, let the plan complete** |
| `(external)` | — | — |
| `(soak)` | — | — |

**Cosmetic failures fail soft.** When an `eyes:cosmetic` criterion fails, do not write a finding and do not block the plan. Instead file it as a normal bug and move on:

```bash
eval "$(../../scripts/wf-exec.sh wf-bug-new.sh "<what you saw>" \
  --severity Low --source agent:wf-test \
  --description "<what the criterion asked for and what rendered instead>" \
  --links "cosmetic criterion from PLN-NNN")"
# → $BUG_ID, $BUG_DIR. It allocates through the counter and commits.
```

Then check the criterion off in `test-progress.md` with `— COSMETIC (filed $BUG_ID)`. A papercut that should be fixed next week does not hold a merge.

**`external` and `soak` never gate and never fail.** They cannot be satisfied at gate time by anyone, so gating on them buys nothing and costs a stop. At exit, defer each one and check it off:

```bash
../../scripts/wf-exec.sh wf-defer-criterion.sh PLN-NNN external "<criterion text>"
../../scripts/wf-exec.sh wf-defer-criterion.sh PLN-NNN soak "<criterion text>"
```

The criterion travels to whichever future plan touches that surface — which is exactly what `/wf-spec` step 1a exists to consume.

Pre-v6 plans have untagged manual criteria. Treat every one of them as `eyes:blocking` — the v5 meaning.

---

## Exit (complex)

### If all pass

All steps below run from the **worktree** (`feature-branches/PLN-NNN-<slug>/`) unless noted.

1. Push feature branch and create PR to release:
   ```bash
   CURRENT_BRANCH=$(git branch --show-current)
   PLAN_NAME=$(echo "$CURRENT_BRANCH" | sed 's|feature/||')
   PLAN_GOAL=$(grep -A 1 "^## Goal" ../../plans/$PLAN_NAME/plan.md | tail -1)
   ```
   **Commit any dirty files before merging** (workflow infra may have been updated by deploy):
   ```bash
   git add -A -- ':(exclude)plans/' ':(exclude)bugs/' ':(exclude)briefs/' 2>/dev/null; git diff --cached --quiet || git commit -m "test($PLAN_NAME): wip before release merge"
   ```
   **Merge release into feature branch** to ensure it's up-to-date (auto-resolves `.plan-ref` and `plans/` conflicts):
   ```bash
   ../../scripts/wf-exec.sh wf-merge-release.sh
   ```
   If this fails with non-trivial conflicts, route back to builder (same as merge-blocked path below).

   **Post-merge build validation** — catch semantically broken merges that git auto-resolved without conflict markers:
   ```bash
   if ! ../../scripts/wf-exec.sh wf-build-check.sh; then
     echo "BUILD FAILED after merging release. The merge likely combined incompatible code."
     echo "Routing back to builder to resolve."
   ```
   - Write findings to `plans/$PLAN_NAME/findings.md`:
     ```markdown
     ## Build Failure After Release Merge — YYYY-MM-DD
     
     - [ ] **Behavior**: Build fails after merging origin/release into feature branch. Git auto-resolved the merge without conflict markers, but the result doesn't compile. Review the merge commit and fix the broken file(s).
     ```
   - Route back to active:
     ```bash
     scripts/wf-exec.sh wf-registry-update.sh $PLAN_NAME testing active --commit "test($PLAN_NAME): build broken after release merge — back to builder" --add plans/$PLAN_NAME/findings.md
     ```
   - Destroy container: `../../scripts/wf-exec.sh wf-docker-down.sh $PLAN_NAME`
   - Display: "Build failed after merging release. Routed back to builder (testing → active). Findings written."
   - **Stop here — do not continue with remaining steps.**
   ```bash
   fi
   ```

   Push to remote. **Wrap every call that talks to GitHub in `wf-retry.sh`** — it retries only transient failures (timeouts, 5xx, resets, rate limits) and returns a real refusal immediately:
   ```bash
   ../../scripts/wf-exec.sh wf-retry.sh --label "git push" -- git push -u origin "$CURRENT_BRANCH"
   ```
   If it still fails, display the error and **stop** — ask the user to resolve manually. Under `WF_UNATTENDED=1` this is a **[GATE]** — open gate `merge-failed` with the error verbatim as the question, then exit 0.

   client-a's PLN-157 (WFI-186) finished 1734 of 1734 tests green and then lost its exit path to GitHub: `git push` timed out after 2m, `gh` answered HTTP 503, the release fetch timed out. Each of those parked the plan on a gate whose only correct answer was "try again" — a person doing a computer's retry. **A weather report about github.com is not a fact about the plan.** What must NOT be retried is the other half: a protected branch, a rejected non-fast-forward, a permission denial. Those are answers, and `wf-retry.sh` passes them straight back so the gate question still describes what actually happened.
   Then check whether this branch is **already on release**, before creating a PR:
   ```bash
   RELEASE_REF=origin/release
   git rev-parse --verify --quiet "$RELEASE_REF" >/dev/null || RELEASE_REF=release
   if ! git rev-parse --verify --quiet "$RELEASE_REF" >/dev/null; then
     echo "ERROR: neither origin/release nor release resolves — cannot tell whether $CURRENT_BRANCH is merged."
     echo "Stopping. Do NOT continue: the steps below would complete a plan whose work is nowhere."
     exit 1
   fi
   if ! git merge-base --is-ancestor "$CURRENT_BRANCH" "$RELEASE_REF"; then
   ```

   **Ask "is it merged?", never "is the log empty?".** This was `git log release.."$CURRENT_BRANCH"`, and in a project whose checkout has never had a local `release` branch that ref does not resolve: `git log` fails, prints nothing to stdout, and the emptiness reads identically to "no new commits". client-a's WFI-165 took the `else` below — *"branch already merged or fast-forward"* — for `feature/PLN-103-…`, which was merged nowhere at all. No PR was opened, the plan reached `complete`, its bug was closed, and a full release/deploy cycle shipped to production green on 1490 tests without the fix the plan and the bug both claimed. It surfaced only because a human spot-checked `main` by hand.

   `merge-base --is-ancestor` cannot fail that way: a broken ref makes it exit non-zero, which routes to the PR — the safe direction. `wf-registry-update.sh` refuses `testing → complete` for an unmerged branch as the backstop, so this now stops at a refused transition rather than a green deploy.
   Create PR (skip if one already exists for this branch):
   ```bash
     EXISTING_PR=$(gh pr view "$CURRENT_BRANCH" --json url -q .url 2>/dev/null || echo "")
     if [ -z "$EXISTING_PR" ]; then
       ../../scripts/wf-exec.sh wf-retry.sh --label "gh pr create" -- gh pr create \
         --base release \
         --head "$CURRENT_BRANCH" \
         --title "feat: $PLAN_NAME" \
         --body "## Feature
   $PLAN_GOAL
   
   ## Test Results
   All acceptance criteria passed in human test
   
   **Plan:** plans/$PLAN_NAME/
   
   Ready for staging validation."
     fi
   ```
   **Merge the PR.** If merge fails (conflicts, branch protection, required checks), **stop and route to builder:**
   ```bash
     if ! ../../scripts/wf-exec.sh wf-retry.sh --label "gh pr merge" -- gh pr merge --merge 2>/tmp/wf-pr-merge-err; then
       PR_URL=$(gh pr view --json url -q .url)
       echo "MERGE FAILED: PR $PR_URL — see error above."
       echo "Routing back to builder."
   ```
   - Destroy container: `../../scripts/wf-exec.sh wf-docker-down.sh $PLAN_NAME`
   - Switch to project root
   - Write findings to `plans/$PLAN_NAME/findings.md`:
     ```markdown
     ## Merge Blocked — YYYY-MM-DD
     
     - [ ] **Merge blocked**: PR cannot merge into release. Likely cause: merge conflicts. Rebase feature branch onto release, resolve conflicts, then re-trigger verify.
     ```
   - Route back to active:
     ```bash
     scripts/wf-exec.sh wf-registry-update.sh $PLAN_NAME testing active --commit "test($PLAN_NAME): merge blocked — back to builder" --add plans/$PLAN_NAME/findings.md
     ```
   - Display: "PR merge failed. Routed back to builder (testing → active). Findings written."
   - **Stop here — do not continue with remaining steps.**

   ```bash
     fi
   else
     echo "$CURRENT_BRANCH is already an ancestor of $RELEASE_REF — skipping PR"
   fi
   ```
2. Destroy container:
   ```bash
   ../../scripts/wf-exec.sh wf-docker-down.sh $PLAN_NAME
   ```

Steps below run from **project root** — use absolute path `cd /absolute/path/to/project`:

3. Switch to develop and merge feature branch:
   ```bash
   cd /absolute/path/to/project
   git checkout develop
   scripts/wf-exec.sh wf-infra-reset.sh
   scripts/wf-exec.sh wf-stash.sh push merge
   ```
   **Use `wf-stash.sh`, never a bare `git stash` / `git stash pop`.** On a clean
   tree `git stash` saves nothing and still exits 0, so a positional `pop`
   restores the previous session's entry instead — an interrupted wf-test run
   leaves exactly that, and the step below then commits whatever it restored.
   `wf-stash.sh` pops the commit *this* run recorded or nothing at all.
   ```bash
   if ! git merge "$CURRENT_BRANCH" --no-edit; then
     git merge --abort
     scripts/wf-exec.sh wf-stash.sh pop merge
     echo "ERROR: Feature branch has conflicts with develop. Routing back to builder."
   ```
   - Write findings to `plans/$PLAN_NAME/findings.md` about the develop merge conflict
   - Route back: `scripts/wf-exec.sh wf-registry-update.sh $PLAN_NAME testing active --commit "test($PLAN_NAME): develop merge conflict — back to builder" --add plans/$PLAN_NAME/findings.md`
   - Display: "Develop merge conflict. PR was merged to release but develop merge failed. Routed back to builder."
   - **Stop here.**

   On success:
   ```bash
   fi
   eval "$(scripts/wf-exec.sh wf-stash.sh pop merge)"
   # Auto-resolve infra conflicts from the restore (infra files always match develop)
   scripts/wf-exec.sh wf-infra-reset.sh
   # Commit YOUR OWN plan folder, if the restore brought it back dirty.
   # Guarded on WF_RESTORED: with an unconditional pop this committed whatever a
   # previous session had left in the stack, which is how a superseded workflow
   # deploy nearly got committed over a current one (WFI-036).
   if [ "${WF_RESTORED:-false}" = "true" ]; then
     scripts/wf-exec.sh wf-commit.sh "test(PLN-NNN-<slug>): pending plan changes restored after merge" \
       --add plans/PLN-NNN-<slug>/
   fi
   ```

   **Scoped to your plan's folder, never to `plans/`.** The stash took the whole
   shared working tree, so what the pop restores includes every *other* live
   worker's in-flight files; a `plans/`-wide add then commits them under this
   plan's message. client-a saw it twice inside four minutes: one commit
   carried a live wf-spec worker's 207-line PLN-030 amendment plus PLN-010 and
   PLN-012 edits belonging to two more sessions, filed as "plans: commit pending
   changes (restored from stash)" (WFI-109, WFI-110). Nothing was lost and
   nothing was findable. Anything the pop restored that is not yours is restored
   *for its owner* — leave it dirty; that is where they left it.
4. Move the plan out of `testing` **first**, then drop the guards:
   ```bash
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN testing complete - \
     --commit "test(PLN-NNN-<slug>): human test passed — complete"
   scripts/wf-exec.sh wf-gate-close.sh PLN-NNN "manual test passed"
   scripts/wf-exec.sh wf-unclaim.sh PLN-NNN-<slug>
   ```

   **Say what actually happened in that message.** "human test passed" is the
   attended wording and it is a claim about a person. An unattended run that
   reached `complete` because every Manual criterion was legitimately deferred
   did not have a human test — PLN-191 went `testing → complete` in three
   minutes with `GATES: 0`, deferred four `(external)` criteria, and then
   committed a human acceptance test that never occurred, on a plan whose own
   design rationale was "attended, no bypass" (WFI-229). The deferral path
   itself is sanctioned; asserting a test into git history is not. Under
   `WF_UNATTENDED=1`, use the wording that matches the route taken:

   | What happened | Commit message |
   |-|-|
   | A human worked the criteria | `test(PLN-NNN-<slug>): human test passed — complete` |
   | Every Manual criterion deferred `(external)` / `(soak)` | `test(PLN-NNN-<slug>): criteria automated or deferred, no human test — complete` |
   | Automated + Chrome-assisted only, no Manual criteria at all | `test(PLN-NNN-<slug>): automated criteria passed, none required a human — complete` |

   Whichever line you write, the plan's `## Steps`-level record of *which*
   criteria ran, deferred or were skipped goes into `progress.md` before step 7
   deletes `test-progress.md`. A completed plan with no such record leaves the
   next reader unable to tell an automated pass from an unworked one.
   The gate is closed **here**, at the end, not when testing started. `/wf-attend` hands this plan over with the gate still open on purpose: while it is open the orchestrator will not dispatch anything at this plan, which is what keeps an unattended tester out of the worktree a human is using (WFI-070). Closing it is this skill's last act, and it is safe to run when no gate is open.

   **The order of these three lines is the contract — see [Order of exit](#order-of-exit).**
5. Close linked bugs (if plan Goal has `**Bug:** BUG-NNN`):
   ```bash
   scripts/wf-exec.sh wf-bug-close.sh BUG-NNN PLN-NNN-<slug>
   ```
   It commits the rename itself, both sides. Do not add the bug folder to any commit of your own — the destination path alone leaves the deletion staged for whoever commits next, which is how six bugs ended up tracked at `triaged/` **and** `closed/` in the same HEAD (WFI-136).
6. Clean up feature branch and worktree:

   **Nothing of yours may still be running in that directory.** Removing a
   worktree out from under a live test runner does not stop the runner — it
   keeps going against a path that no longer exists, and every remaining test
   fails on `DirectoryNotFoundException`. PLN-260 produced 446 such failures
   from a plan that had already reached `complete`, and the wreckage reads
   exactly like a broken implementation (WFI-239). The runner was backgrounded,
   which unattended rule 2 already forbids; this check is the second line of
   defence, and it costs one command:
   ```bash
   pgrep -fl "feature-branches/PLN-NNN-<slug>" || true
   ```
   Anything listed is yours to wait for or kill **before** the removal. If you
   cannot account for a process, stop and report it rather than removing.
   ```bash
   git worktree remove feature-branches/PLN-NNN-<slug> --force 2>/dev/null || true
   git branch -d "$CURRENT_BRANCH" 2>/dev/null || true
   ```
7. Clean up test progress and commit REGISTRY/bug changes:

   **Write the summary into `progress.md` before deleting the file it came
   from.** `test-progress.md` is working state and goes; the one-line-per-
   criterion record of what ran, what deferred and why is the plan's evidence
   that it was tested at all, and PLN-191 completed leaving none of it (WFI-229).
   Append a `## Testing — YYYY-MM-DD` section to `plans/PLN-NNN-<slug>/progress.md`
   listing each criterion and its outcome (PASS / FAIL-then-fixed / deferred
   `(external)` / deferred `(soak)`), then:
   ```bash
   rm -f plans/PLN-NNN-<slug>/test-progress.md
   scripts/wf-exec.sh wf-commit.sh "test(PLN-NNN-<slug>): complete — merged to develop" --allow-empty \
     --add plans/PLN-NNN-<slug>/test-progress.md plans/PLN-NNN-<slug>/progress.md plans/auto-test-log.md \
     --branch develop
   ```
   **Never a bare `git add … ; git commit --allow-empty` here.** That was this
   line until v6.3.1 and it is the widest index-sweep left in the pipeline: the
   `git add` is atomic, so one absent path (`deferred-criteria.md` in a project
   that has never deferred a criterion) staged nothing at all, and the bare
   commit that followed took *the entire shared develop index* — every other
   live worker's staged work, filed under this plan's completion message.
   client-a saw one such commit carry an interactive session's unreviewed
   test edits to develop (WFI-123) and another swallow a concurrent spec run's
   reviewed `plan.md` (WFI-122). `wf-commit.sh` builds the commit from the
   pathspec, skips paths that do not exist, and — as of v6.3.1 — refuses
   outright if the checkout has been moved off develop under you.

   No `bugs/` path belongs in this pathspec at all — step 5 already committed
   the rename, both sides. Never `bugs/` wholesale either; that is as wide as
   the index sweep this replaced. `plans/deferred-criteria.md` is gone from it
   for the same reason: `wf-defer-criterion.sh` now commits that file together
   with the `plan.md` checkoff that belongs to it, and this pathspec could only
   ever carry one of the two (WFI-144).
8. Display:
   ```
   Human test passed
   PR created: [PR URL]  (or "No PR needed — already on release")
   Feature merged to develop
   Plan moved to complete
   
   Next: Run /wf-release to merge to staging, then /wf-deploy to promote to main.
   ```
   Then run `scripts/wf-exec.sh wf-check-reboot-flag.sh` and append any output to the message above.

### If findings (failures)

1. Write findings to `plans/PLN-NNN-<slug>/findings.md` on develop (from worktree, path is `../../plans/PLN-NNN-<slug>/findings.md`):
   ```markdown
   ## Human Test — YYYY-MM-DD
   
   - [ ] **Behavior**: Button doesn't respond on mobile
   - [ ] **Design**: Users expect different flow ← ESCALATED
   ```
2. Destroy container (from worktree):
   ```bash
   ../../scripts/wf-exec.sh wf-docker-down.sh $PLAN_NAME
   ```

Steps below run from **project root** — use absolute path `cd /absolute/path/to/project`:

3. Switch to develop:
   ```bash
   cd /absolute/path/to/project
   scripts/wf-exec.sh wf-infra-reset.sh
   scripts/wf-exec.sh wf-stash.sh push checkout
   git checkout develop
   eval "$(scripts/wf-exec.sh wf-stash.sh pop checkout)"
   # Auto-resolve infra conflicts from the restore (infra files always match develop)
   scripts/wf-exec.sh wf-infra-reset.sh
   # Same guard as the all-pass path, and the same scope: this plan's folder
   # only. A `plans/`-wide add here commits other live workers' in-flight files
   # under your message (WFI-109, WFI-110).
   if [ "${WF_RESTORED:-false}" = "true" ]; then
     scripts/wf-exec.sh wf-commit.sh "test(PLN-NNN-<slug>): pending plan changes restored after checkout" \
       --add plans/PLN-NNN-<slug>/
   fi
   ```
4. Determine the route, move the plan out of `testing` **first**, then drop the guards:
   ```bash
   route=$(scripts/wf-exec.sh wf-findings-route.sh plans/PLN-NNN-<slug>)
   ```
   Both routes land on `draft` — `escalated` because the findings need design decisions, `active` because Opus reviews all findings before sending them to the builder. Only the commit message differs.
   - **`escalated`**, message `test(PLN-NNN-<slug>): escalated findings — needs replanning`, display "N escalated findings require design decisions. Run /wf-spec."
   - **`active`**, message `test(PLN-NNN-<slug>): N findings from human test — routing to spec`, display "N findings written. Run /wf-spec to review and route to builder."

   ```bash
   scripts/wf-exec.sh wf-registry-update.sh PLN-NNN testing draft \
     --commit "<message from above>" \
     --add plans/PLN-NNN-<slug>/findings.md plans/PLN-NNN-<slug>/test-progress.md \
           plans/auto-test-log.md
   scripts/wf-exec.sh wf-gate-close.sh PLN-NNN "manual test found N issue(s)"
   scripts/wf-exec.sh wf-unclaim.sh PLN-NNN-<slug>
   ```
   Close the gate on this path too. A findings exit sends the plan to `draft`, and a `manual-test` gate left open there parks it in front of a planner who has nothing to answer.

   **The order of these three lines is the contract — see [Order of exit](#order-of-exit).**

### Order of exit

Every exit path from this skill drops the plan's two dispatch guards — its gate and its claim. **The state transition is committed before either of them is released, and the claim is released last.**

```
wf-registry-update.sh …  ← the plan leaves `testing`, committed, in one locked step
wf-gate-close.sh …       ← first guard down
wf-unclaim.sh …          ← last guard down
```

The reverse order is a check-then-act race, and client-a ran it: an attended session closed PLN-006's `manual-test` gate at 15:32:33Z and committed `testing → draft` five seconds later. The daemon swept at 15:32:35Z — inside that window the plan was ungated, unclaimed and still reading `testing` — and spawned an unattended tester onto a plan that was already on its way back to the planner. That worker re-ran the whole e2e scope and opened a *fresh* `manual-test` gate on a plan that had sat in `draft` with five unaddressed findings for four minutes, which then blocked the plan from reaching `/wf-spec` at all (WFI-079).

While the transition is uncommitted it does not exist to any other session; while the gate or claim is up, no worker can be dispatched regardless of what the registry says. Committing first means there is never an instant where the plan is both unguarded and stale.

`wf-spawn.sh` re-reads the registry immediately before it launches and stands down on a state it cannot act on, so a worker is not dispatched into a window this small. That is a backstop, not the fix — it narrows the window to milliseconds rather than closing it.

**After the guards are down, push develop.** Neither exit path above does otherwise — both routes commit locally and nothing pushes, and this is an unattended agent with no session boundary to force it. client-c's WFI-012: `origin/develop` sat 38 commits behind local develop across a session's worth of automated verify/test cycles. Best-effort, never a routing failure — the transition above already committed and is the outcome that matters:
```bash
scripts/wf-exec.sh wf-retry.sh --label "push develop" -- git push origin develop \
  || echo "wf-test: push to origin/develop failed after retries — local commits are ahead; push by hand" >&2
```

---

## Container cleanup

Always destroy the container before leaving the worktree — on pass, fail, or early abort. From the worktree:
```bash
../../scripts/wf-exec.sh wf-docker-down.sh $PLAN_NAME
```
If you hit an error and need to stop early, **destroy the container first** before routing back or displaying the error.

**Unless it is not yours.** One exception, and it is the whole reason the claim check in [Unattended mode](#unattended-mode) step 0 exists: a container belongs to the session that started it. If you stood down because another session holds the claim, leave everything running — that app on `localhost:$FEATURE_PORT` is what a human is looking at.

## Bug reference model

**Pre-existing bugs** (in plan Goal): accept BUG-NNN as truth — don't look it up.
**New bugs during testing**: write as findings immediately, file formally with `/wf-bug` after testing.

## Rules

- **Do NOT** use `git add -A` or `git add .` — only stage specific files by name
- **Do NOT** edit source code — only read the plan and write findings
- **Do NOT** skip user input — let the user describe what they see
- **Do NOT** break testing context — write findings immediately, never tell user to switch branches mid-test
- **Accept natural language** — interpret user descriptions, don't force rigid prompts
- Severity for human-test findings is either `Behavior` (code fix) or `ESCALATED` (design) — never Critical. Both route to wf-spec (draft) for Opus review.
- Only one testing worktree at a time

## Notes

| Range | Use |
|-|-|
| 8000-8099 | Static site, staging (8081) |
| 8100+ | Feature branches (8100 + plan ID) |
| 8080 | Default local dev |

Project name: `{{project_slug}}-pln<id>` (e.g., `{{project_slug}}-pln004`)

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `wf-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/wf-exec.sh wf-issue.sh --source wf-test \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the claude-workflow library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

