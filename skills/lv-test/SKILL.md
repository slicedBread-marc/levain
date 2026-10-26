---
name: lv-test
description: Automated acceptance (accept:auto) for plans that passed verification. Runs the suite and headless Playwright on every criterion it can, moves the plan to accept:manual for /lv-accept only when a person is genuinely needed, and ships it — PR, merge, complete — when nothing is left.
user_invocable: true
model: haiku
---

# Tester Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are in **tester mode**: the automated half of acceptance, shown as `accept:auto` (the registry stores it as `testing`). Your job is to settle every criterion a machine can settle, hand the plan to a person **only** when what is left needs one, and ship it when nothing is left.

**You ask no one about a criterion, attended or not.** The human half — `accept:manual`, stored as `accept` — is `/lv-accept`'s, and it exists only for a plan you moved there. An attended run works the same [order of work](#unattended-mode) as an unattended one; it differs only in that the entry questions (a missing goal, a missing sign-in, a host fault) are asked instead of gated, and in what you tell the human at the end. A plan that is already in `accept`, or that sits in `testing` with an open `manual-test` gate (the shape before the split), is not yours: say `run /lv-accept PLN-NNN` and stop.

**You must NEVER edit source code directly.** This skill runs on haiku and is not authorized to make code changes. If you find issues, document them as findings and route back to the builder — never attempt fixes yourself.

## Unattended mode

If `LV_UNATTENDED=1` is set in your environment, you were launched by the orchestrator and **there is no human at the keyboard**. Nobody can look at a screen and tell you what they see.

Your job changes shape: **clear everything that can be cleared without eyes, then park once with only what's left.** Do not gate on the first Manual criterion you encounter — that would send the plan back to a human for one item at a time.

Order of work:

0. **Stand down if a human is already in here.** Before anything else:
   ```bash
   scripts/lv-exec.sh lv-claim.sh <plan-name> --if-free --state testing
   ```
   Exit 2 means **another** live session holds the claim — an attended `/lv-test` is walking this plan right now. Print the message and exit 0 immediately. Do not read the plan, do not start a container, and above all do not run the exit path: the container you would tear down and the `test-progress.md` you would overwrite are theirs (WFI-070).

   Exit 3 means the plan is no longer in `testing` — it moved between the dispatch and you, so the work you were sent for is already done. Exit 0 without doing anything; nothing was claimed and there is nothing to release (WFI-153).

   Exit 0 is the normal case and includes `already held on your behalf by the dispatcher` — the orchestrator claims a plan before launching you, and that claim names *your* PID. Standing down there is standing down against yourself: it ended ~15s runs reporting a human who did not exist, and parked every plan that reached testing after three no-op dispatches (WFI-073, WFI-075). Only exit 2 means someone else.
1. If your instructions name a plan, skip the selection menu and work that plan.
2. **Start the suite detached, then collect it before you ask anything** — [step 3a](#testing) starts it (`lv-suite-run.sh --detach --reuse`, from inside the plan's own worktree, stamped with `lv-test-tree.sh` in the same call) and [Testing step 4](#testing) waits for it with `lv-suite-wait.sh`, looping on exit 3. In both modes the join comes **after** step 3c and step 5 and **before** step 6 — so the suite overlaps the headless criteria, and a gate is never opened with a suite still running behind it. No `&`, no `run_in_background: true`, no backgrounded subagent: a headless run ends the moment you stop producing output, so anything still running is killed unread and the turn is recorded as a worker that accomplished nothing (WFI-114). The detached process plus the wait loop is the only form that survives that. The suite goes through `lv-suite-run.sh`, which redirects stdin from `/dev/null`; **anything else you run that could read stdin gets `< /dev/null` too**: your shell's stdin is not at EOF, so a single test that reads it blocks forever with no failure and no output to say why (WFI-240).
3. **Auto-test every criterion you can before anything reaches a human** — `#### Chrome-Assisted` *and* `#### Manual`. [Step 3c](#testing) drives them through headless Playwright: literal DOM/JS assertions, interaction sequences (click/fill/submit/refresh), two-browser sessions, and visual/subjective criteria via a saved screenshot you Read and judge yourself. There is no Chrome extension and no browser mode (LVI-001). The aim is that a human is asked only about what no automated run could settle (LVI-002):
   - **Chrome-Assisted** — every one ends at PASS, FAIL or a recorded reason it could not run. Leaving them at `—` and then gating for "one Manual criterion" misreports what is actually left, and the gate question is the only thing a human reads (WFI-070).
   - **Manual `(eyes:blocking)`, `(eyes:cosmetic)` and untagged** — run the same way: reach the state, screenshot it at the widths the criterion names (both widths when it names none), Read the PNG, judge. A non-browser surface is no different: CLI help text or a generated file is output you can produce and read. A clear PASS or FAIL is recorded like any other result, with Notes saying how you saw it (`headless screenshot 390+1280: …`). Ambiguous — you cannot honestly tell from what you captured — stays at `—` with a note on what was ambiguous, and reaches the gate. So does any reading that disagrees with a prior recorded result (step 3c's disagreement rule).
   - **`(external)`, `(soak)`, `(unbuilt)`** — not auto-tested; step 5 disposes of them.
4. For a criterion step 3c could not settle that matches a recurring auto-testable shape (`plans/auto-test-log.md`, Realized), run [Auto-test mode](#auto-test-mode). On auto-test FAIL, record it as a Candidate as normal and leave the criterion for `accept:manual`.
5. Dispose of the criteria that never need a human, whatever remains untested:
   - `(external)` and `(soak)` — defer each and check it off. They cannot be satisfied at gate time by anyone, so they never gate:
     ```bash
     scripts/lv-exec.sh lv-defer-criterion.sh <PLN-ID> external - <<'CRIT'
     <criterion text, verbatim from plan.md>
     CRIT
     ```
     **Never put criterion text in double quotes** — backticks in it are commands, and the shell runs them before the script sees them (WFI-194). See [Deferring a criterion](#deferring-a-criterion).
     **Read what it printed.** The DC row is only half the job — the other half is the checkbox in `plan.md`, which is what anyone opening the completed plan actually reads. `ticked in …` means both halves are done. `ACTION REQUIRED: no matching unchecked criterion` means only the row was written: edit `plan.md` yourself, tick the box it listed, append ` — deferred as DC-NNN`, and only then move on. A completed plan with an empty box says "silently dropped", which is the exact ambiguity deferral exists to remove (WFI-056, WFI-137).
   - `(eyes:cosmetic)` that step 3 could not settle — leave untested and unchecked; whether it gates is the gate script's call, not yours. When it says `GATE='false'`, the criterion stays that way and the plan completes (step 6).
6. **Collect the suite (Testing step 4) — then write `test-progress.md`, then ask the gate script whether a human is needed. Do not decide this yourself.**

   **The order is load-bearing: `lv-manual-gate.sh` reads that file.** A `#### Manual` criterion you judged and passed this session stays unchecked in `plan.md` — that is by design, you only ever tick a box on a deferral or a cosmetic failure — so the gate has no way to learn the criterion is settled except from the record. Ask it before writing, and you are asking about a plan whose results do not exist yet: client-b' PLN-011 had 8 of 8 criteria PASS on the current build and opened a manual-test gate naming an `eyes:blocking` criterion that had already been judged and passed (WFI-013). Write every result you hold — the full file, per [Saving test progress](#saving-test-progress), build identifiers included — then **commit it**, and only then run the script:
   ```bash
   scripts/lv-exec.sh lv-commit.sh "test(PLN-NNN-<slug>): headless results on <sha>" \
     --add plans/PLN-NNN-<slug>/test-progress.md
   ```
   Unattended, the gate reads `#### Manual` PASSes from the committed file only (LVI-033), so an eyes criterion you settled in step 3 and did not commit still stops for a human.

   **Then let the script confirm step 3 actually happened — do not trust that it did.** It counts every unchecked `#### Chrome-Assisted` criterion against `test-progress.md` on disk, not against what you remember writing:
   - `PROGRESS_INCOMPLETE='true'` → `$PROGRESS_MISSING` names criteria with no PASS, FAIL or recorded reason in the file — or the file does not exist at all (`$GATE_REASON` says which). That is your unfinished work, not a human's: go back to step 3c, run each one, rewrite `test-progress.md`, and ask the script again. Open the gate on an incomplete record only when a criterion genuinely could not be run *and* you failed to record why — never as a shortcut.
   - `CHROME_UNTESTED` > 0 → criteria you recorded as not runnable, with a reason. They force `GATE='true'` and are named in `$GATE_REASON`; the gate question must name them too.

   client-c's WFI-022: 8 of 10 Chrome-Assisted criteria were left untested, and the gate that opened next asked about the 2 genuinely Manual ones without ever mentioning the other 8. A client's LVI-040 is the same shape a second time, with the prose rule above already in place: all 6 Chrome-Assisted criteria unrun, a final report claiming *"Created test-progress.md"* for a file that never existed, and a gate asking about "1 eyes:blocking criterion". A file you did not `ls` is not a file you wrote — the script reads the disk, so it cannot be told otherwise.
   ```bash
   eval "$(scripts/lv-exec.sh lv-manual-gate.sh <PLN-ID>)"
   ```
   - **Any criterion recorded FAIL, whatever `GATE` says** → take the **findings** exit and route back to the builder. A FAIL is a result, not a question, and a person cannot un-fail an assertion a run made; scope is not reduced here. **The express lane does not change this.** (A reading that *disagrees* with a prior one is not a FAIL — step 3c leaves it at `—`, and it goes to `accept:manual` below.)
   - `GATE='false'` → **do not stop for a human.** A plan whose diff renders nothing to a human never stops for a human. But `GATE='false'` is a statement about *human eyes*, not about test results, and it does not turn an untested criterion into a PASS:
     - `LANE='express'` → a human declared this plan safe to ship unseen, and the lane check still passes on the plan as written (LVI-025). Instead of deferring the untested eyes criteria, move them to the plan's post-ship checklist — the script ticks each one, lists it under `## Post-ship checklist` for a human after it ships, logs the answer as `express`, and commits:
       ```bash
       scripts/lv-exec.sh lv-lane.sh answer <PLN-ID> manual-test
       ```
       Exit `0` → go to the all-pass exit. Exit `1` → the lane downgraded between the gate script and now (the plan changed): ask `lv-manual-gate.sh` again and follow its new answer. Never tick an eyes criterion by hand to get the same effect — the completion guard reads a ticked box as *settled*, and only the lane's own record says why it was.
     - An `(eyes:cosmetic)` criterion step 3 left at `—` → **leave it there**, unchecked, with the note on what was ambiguous. Cosmetic criteria never block completion (`blockOnCosmetic`, and the completion guard counts only `eyes:blocking`), `lv-defer-criterion.sh` refuses every `eyes:*` tag, and the gate has just said no human is needed — so it ships unseen, which is the documented trade. It counts as settled for the **Completion gate** below (a client's LVI-044).
     - Each remaining untested criterion → defer it with `lv-defer-criterion.sh`, giving `$GATE_REASON`, per [Deferring a criterion](#deferring-a-criterion) — and mind the quoting rule above (WFI-194). A deferral is the form the completion guard can read; a free-text "untested" note in `test-progress.md` is not, and `lv-registry-update.sh` refuses `testing → complete` when an `eyes:blocking` criterion has no PASS, no deferral and no answered gate (client-d WFI-009).
     - Only then take the all-pass exit path (step 4). The **Completion gate** below governs that exit, and this bullet is not an exception to it.
   - `GATE='true'` → **move the plan to `accept:manual`, once, with everything that is left listed together.** Results first (committed above), then the transition, then the gate, then the claim — the [Order of exit](#order-of-exit), unchanged:
     ```bash
     scripts/lv-exec.sh lv-registry-update.sh PLN-NNN testing accept \
       --commit "test(PLN-NNN-<slug>): accept:auto done on <sha> — N criteria need a human" \
       --add plans/PLN-NNN-<slug>/test-progress.md \
     && scripts/lv-exec.sh lv-gate-open.sh <PLN-ID> manual-test \
       "N criteria need human eyes on <sha>: <one-line list>" \
       --context plans/<plan-name>/plan.md --skill lv-test \
     && scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
     ```
     Tear the container down ([Container cleanup](#container-cleanup)) — `/lv-accept` brings its own up — and exit 0. The suite was collected before step 6, so nothing is left running; put its `SUITE_RESULT=` line in the gate question as a second sentence, so the human answering knows the automated half is settled. Attended, end with one line: `PLN-NNN is in accept:manual — run /lv-accept PLN-NNN`.

     **The row is what parks the plan, not the gate.** The dispatcher never sends a worker at `accept`, so a gate closed early can no longer put a tester into a container a human is using (WFI-070). The gate stands beside it because `/lv-attend`'s queue reads gates.

     **A refused transition is your unfinished work.** `lv-registry-update.sh` asks `lv-manual-gate.sh` itself and refuses `testing → accept` when the record is incomplete (`PROGRESS_INCOMPLETE`), when the express lane holds, or when no human is needed — `accept:manual` holds only what no machine can settle (LVI-040). Read its message, do what it names (usually: back to step 3c), and ask again. Never reach for `LV_ALLOW_ACCEPT=1`; it is a human's override. **Never open `manual-test` on a refused transition** — the `&&` above is why: a gate beside a `testing` row asks a human for work the record says is yours, and `/lv-accept` cannot enter a plan that is not in `accept`. Unattended, `lv-gate-open.sh` refuses it (exit 6). A client's PLN-061 tester did exactly that, after rewriting its rows from the pre-amendment criterion text and then restoring an older build's record over them (LVI-031). Two causes of that refusal are worth knowing by name: a row whose criterion text is not the `lv-manual-lint.sh --live` text, which matches nothing, and a `TREE` stamp or Build cell on another build (`PROGRESS_TREE_STALE`), which settles nothing on this one (LVI-029). Restoring an earlier record never fixes either.

     **The question states only what you verified.** Name a changed file only if `git diff --name-only <old-build> HEAD` in the worktree lists it; quote `$SURFACE_HIT` and `$GATE_REASON` as the script printed them; never describe what a build "changed" from a commit subject or a guess. A re-ask of a criterion that already has a PASS on an earlier build says which build that was and which surface path changed since: quote `$SURFACE_MOVED_FROM` and `$SURFACE_MOVED`, never `$SURFACE_HIT` — that one is the plan's whole diff against develop and can name a file identical on both builds (LVI-021). If `$SURFACE_MOVED` is empty, the script would have carried the PASS (`MANUAL_CARRIED`), so recheck before asking. A client's LVI-006 re-asked a print check claiming a CSS change the diff did not contain.

   The old rule — gate if any `#### Manual` criterion remains — stopped every plan, because every plan has some. The script keys on the surface the diff touches instead, which the planner does not control at classification time. Its answer is final either way.

| Where | Prompt | Mode | Unattended behavior |
|-|-|-|-|
| Entry | Plan selection menu | [AUTO] | Use the plan named in your instructions |
| Step 2 | Goal missing | **[GATE]** | `goal-missing` |
| Step 4 | A criterion 3c could not settle | [AUTO] | Auto-test it when it matches a recurring shape; otherwise leave it at `—` with the recorded reason, for `accept:manual` |
| Step 6 | A criterion recorded FAIL | [AUTO] | Write the finding and route to spec as normal — that is a state transition, not a question. An `(eyes:cosmetic)` failure files a bug and checks off instead |
| Step 5 | Deferring a criterion | [AUTO] | Defer `(external)` and `(soak)` criteria — that is mechanical. Never defer anything else; an `unbuilt` deferral is a human's call, in `/lv-accept` |
| Testing step 4 | `lv-suite-wait.sh` exits 3 | [AUTO] | Call it again with the same handle. Never end the turn on a running suite |
| Testing step 4 | Suite verdict is `pass (reused …)` | [AUTO] | Record it as reused under step 3a's `TREE` stamp, totals from `SUITE_REUSED_FROM=`. Do not re-run it to "confirm" |
| Step 6 | Whether a human is needed (`testing → accept`) | [AUTO] | `lv-manual-gate.sh` decides, and `lv-registry-update.sh` checks it again. Do not second-guess it in either direction |
| Completion | "All criteria pass — proceed?" | [AUTO] | Proceed when every criterion is PASS on the current build |
| Exit | `git push` still failing transiently (`lv-retry.sh --tempfail` exit 75) | [AUTO] | No gate. Leave the plan in `testing`, unclaim, exit 0 — the next sweep retries (coordinator WFI-006) |
| Exit | `git push` refused (protected branch, non-fast-forward, permission) | **[GATE]** | `merge-failed` — question is the git error verbatim |
| Exit | `gh pr merge` failed | [AUTO] | Already routes to the builder on its own — follow that path, don't gate |

**Never guess.** You have no eyes on the running app beyond what headless Playwright and the test suites report. If a criterion's outcome is not something you established from a test result, a headless run or screenshot you captured on this build, or a build log, it is **not** a PASS — leave it for `accept:manual`. Recording an unverified PASS is worse than recording nothing, because it ships. A test result you did not produce yourself, in this plan's stamped tree, is in the same category as a guess — and a FAIL copied out of the bug report that motivated the plan is the shape this actually took (WFI-132). Anything you are about to ask that isn't in the table above is a [GATE] with gate name `needs-input`. **Opening any gate ends the run:** unclaim and exit 0 in the same breath. Do not defer the criteria you just asked about and carry on to `complete` — a client's PLN-006 tester opened `needs-input` about the identity provider, did exactly that three minutes later, and left the question standing a day on a finished plan (LVI-008). **`manual-test` is no exception.** A client's PLN-003 tester opened `manual-test` on an `eyes:blocking` criterion, then 55 seconds later ruled that same criterion PASS itself — "verified on prior build; not affected" — overriding the gate script it had just obeyed, completed the plan, and had its closing `lv-gate-close.sh` refused for want of a `--basis`; the gate stood open on a finished plan (LVI-009). Its question also claimed the new build "adds RunPage route" when the diff touched only `NewSheet.tsx`. Unattended, `lv-registry-update.sh` now refuses `→ complete` while any gate is open, `manual-test` included. Since the accept split there is nothing to rule on here in the first place: a criterion only a person can settle is settled in `/lv-accept`, and the plan comes back to you with the record already written.

Everything else (creating the PR, writing findings, routing back to the builder) is a normal state transition and proceeds without asking.

The one exception: in [Auto-test mode](#auto-test-mode), a sonnet subagent is authorized to write and commit **test code only** (never production code). The subagent is explicitly instructed on this boundary.

## The `browser` argument (retired)

`/lv-test <ID> browser` (or `--browser`) used to drive criteria through the Claude in Chrome extension. It never worked reliably and is gone (LVI-001): headless Playwright ([step 3c](#testing)) is the only automated browser. If you are given the argument, say once "`browser` mode was retired — step 3c drives criteria with headless Playwright" and run as normal. What Playwright genuinely cannot be — real third-party OAuth, a physical device, an installed browser extension, the user's own logged-in profile — goes to the human through `accept:manual` (`/lv-accept`), with its `needs:` reason.

## Entry (simple)

**If on `develop`:**

Spawn a **haiku subagent** to fetch and format the worklist:

```
Agent(model: haiku, prompt: "Run `scripts/lv-exec.sh lv-list-testable.sh` in the current directory.
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

- If output is `NO_PLANS`: say "No plans ready for testing. Run /lv-tray to see pipeline state."
- If output starts with `CLAIMED_PLANS:`: show the claimed plans and stop — clearing another session's claim is a claim-steal, and that stays with a human (WFI-146). If the operator says those sessions are finished, run `scripts/lv-exec.sh lv-unclaim.sh <plan-name>` for each, then re-run the haiku subagent.
- If the user types `u <N>`: run `scripts/lv-exec.sh lv-set-priority.sh <plan-id> urgent`, then re-run the haiku subagent to re-display the updated menu.
- If the user types `u <N>` for an already-urgent plan: run `scripts/lv-exec.sh lv-set-priority.sh <plan-id> —` to clear it, then re-run the subagent.

**Do not wait for a pick (WFI-006).** Take the plan the invocation named, else the first row (urgent rows come first). Print one line saying which you took and proceed.

Then, for the chosen plan:
1. `eval "$(scripts/lv-exec.sh lv-plan-info.sh PLN-NNN)"` to get plan details
2. If `$PLAN_GOAL_MISSING` is `true`: under `LV_UNATTENDED=1` this is a **[GATE]** — open gate `goal-missing` and exit 0. Otherwise ask the user: "This plan has no goal summary. Please provide a one-line goal." Then write their answer as the first line under `## Goal` in `$PLAN_DIR/plan.md`, commit it scoped: `scripts/lv-exec.sh lv-commit.sh "spec(PLN-NNN-<slug>): add missing goal" --add plans/PLN-NNN-<slug>/plan.md` — a bare `git commit` takes the whole shared index (WFI-048/049). Re-run the eval to pick up the goal.
3. `scripts/lv-exec.sh lv-claim.sh PLN-NNN --state testing` — **exit 3 means the plan is not in `testing`**: if it is in `accept`, it is waiting on a human — say `run /lv-accept PLN-NNN` and stop. Ask **before** claiming whether `scripts/lv-exec.sh lv-list-gates.sh PLN-NNN` shows an open `manual-test` gate: that is the pre-split shape of `accept:manual` — say `run /lv-accept PLN-NNN` and stop; `/lv-accept` moves it across. **Exit 2 means a live session already holds it.** Stop, say who holds it, and offer another plan. Take it only if the user says the holder is finished or wedged: `lv-claim.sh PLN-NNN --steal` (WFI-146).
4. `cd feature-branches/<plan-name>/` — note the **absolute** path it prints; you need it on every later call
5. Continue to testing

**If on a feature branch:**
1. `eval "$(scripts/lv-exec.sh lv-plan-ref.sh)"` to get PLAN_ID, PLAN_DIR, PLAN_NAME
2. Read the plan from `$PLAN_DIR/plan.md`
3. Continue to testing

> **`$PLAN_*` are placeholders, not live shell variables.** Every Bash call is a
> fresh shell, so nothing the `eval` set survives to the next one. Read the
> values out of the eval's output and substitute them literally, or repeat the
> `eval` in the same call that uses them. An unset `$PLAN_NAME` passed to
> `lv-claim.sh` claims the empty string and prints a usage error that reads like
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
scripts/lv-exec.sh lv-branch-check.sh feature/$PLAN_NAME
```
Exit 1 here means you are standing somewhere else — almost always the develop root, which a re-test lands in by default. Fix the directory, do not proceed.

**Every command that produces a result you will record must carry its own proof of tree.** Chain it in the same invocation, so `&&` stops before a single test runs in the wrong place:
```bash
cd /abs/path/to/feature-branches/PLN-NNN-<slug> \
  && ../../scripts/lv-exec.sh lv-test-tree.sh PLN-NNN-<slug> \
  && ../../scripts/lv-exec.sh lv-suite-run.sh --label test-PLN-NNN --only-e2e --extra-args "$E2E_SCOPE" --reuse
```
It prints a `TREE … @ feature/… <sha> (<time>)` stamp. **Record that stamp in `test-progress.md` immediately above the totals it belongs to — copied verbatim from the tool output, character for character.** Never compose the line yourself and never write a `$(…)` into a document: client-a's PLN-153 carries `TREE … @ feature/PLN-153-projectname-path-guard $(git rev-parse HEAD) ($(date '+%b %d %H:%M'))` as literal text (WFI-183), which records neither the commit nor the time — the two facts the stamp exists to record. A stamp whose sha is unresolved is worth less than no stamp, because it looks like provenance. A test result is a measurement of one working tree and nothing in `dotnet test`'s output says which — an unattended tester recorded develop's 1120 tests against a plan whose tree holds 1123, and opened a gate saying the implementation "appears incomplete" while verify's own run of the same plan was 1123 passed / 0 failed (WFI-132). A totals line without a stamp above it is not a result; re-run it.

**Never transcribe a figure you did not just produce.** Totals, failure counts, durations and failing test names that appear in a bug report, an earlier log, `test-progress.md`, or the plan are records of a *different* run, usually the pre-fix one that motivated the work. The only admissible source for a result is a command you executed in this session, in the stamped tree, and read the output of.

**A compaction is a re-entry.** This skill used to say the working directory "persists", and it does — right up until the conversation is summarised, which resets it to the develop root with nothing in the transcript saying so. client-a's WFI-098: after a mid-session compaction a relative read of a file that exists only on the feature branch returned "No such file or directory" and a grep for the feature came back empty — the WFI-094 shape again, one step from being written up as a broken feature. The post-compaction `WORKFLOW STATE` block restates the worktree path absolute for exactly this reason; re-run the assertion above the moment you see one.

**Why this is an assertion and not a reminder.** A verification command run from the develop root reads develop's tree, where the branch's work has not merged, and it fails *correctly* — which is indistinguishable from the feature being broken. client-a's WFI-094 wrote up exactly that as a behavior finding claiming a fix "was not implemented", and bounced a fully-built, verify-clean plan back through spec. Two shapes to watch, both from the same root cause:

- **Relative paths.** `grep X src/…` from the develop root greps develop. Any path a criterion names is relative to the worktree.
- **The container** (when the project has a compose file). `docker compose -f docker/docker-compose.yml up --build` resolves `build.context: ..` against the compose file, so from the develop root it builds *develop's* source — while `lv-plan-port.sh` hands out the same port either way. The URL looks right and the build is wrong, with nothing in the output to tell them apart. Always bring the container up with `lv-docker-up.sh` from the worktree, and if a criterion fails on served content, confirm the served build matches the branch tip (`git rev-parse HEAD`, then curl the page and compare against the worktree's own file) **before** writing a behavior finding.

1. **Read the plan** — from develop worktree: `../../plans/PLN-NNN-<slug>/plan.md`
   - Read Goal and Verification Checklist sections
   - Read its live directives: `../../scripts/lv-exec.sh lv-direct.sh list PLN-NNN`. A `constraint` directive is binding — a build that contradicts it fails the criterion it touches, whatever the criterion's own wording says, and the finding quotes the directive (`D-n`).
   - **Only present `### Human Test Criteria` items** (combine `#### Chrome-Assisted` and `#### Manual` into a single flat list) — Build & Tests and Code Quality were already handled by the verify agent. **Get that list from `../../scripts/lv-exec.sh lv-manual-lint.sh PLN-NNN --live`, not by assembling it yourself:** its first column is the number to show, to write in test-progress.md's `#` column, and the one an amendment's `replace Chrome-Assisted N` / `Manual N` resolves against. A list built by hand put an amendment's replacement in the replaced criterion's slot, and the next amendment's numbers retired the wrong criterion (a client's LVI-013).
   - **Amendments change that list.** A `#### Human Test Criteria (A-N)` block's `##### Chrome-Assisted` / `##### Manual` criteria are live and are tested like the originals; the originals its heading or `**Supersedes:**` line retires are not tested and get no row. `lv-manual-gate.sh` counts the same live set (LVI-027).
   - **Nothing reaches a human before step 3c has tried it.** Once the container is up, [step 3c](#testing) runs every Chrome-Assisted criterion and every `#### Manual` eyes or untagged criterion through headless Playwright, attended or not (LVI-002). `/lv-accept` walks only what it left: an ambiguous screenshot, a disagreement with a prior reading, an eyes judgment, or something Playwright cannot be — real third-party OAuth, a physical device, an installed browser extension, the user's own logged-in profile, or no headless browser installable on this machine at all.
2. **Check for prior test progress** — look for `../../plans/PLN-NNN-<slug>/test-progress.md`. If it exists, read it to get per-criterion results and build identifiers.
3. **Deploy to local container and capture build identifier** (single bash call — already inside feature branch):
   ```bash
   eval "$(../../scripts/lv-exec.sh lv-docker-up.sh)" && BUILD=$(git log -1 --format='%ad (%h)' --date=format:'%b %d %H:%M')
   ```
   This sets FEATURE_PORT, COMPOSE_PROJECT_NAME, TEST_ACCOUNT, and BUILD.

   **A project with no `docker/docker-compose.yml` is not a Docker failure.** `lv-docker-up.sh` then runs the project's own `local_deploy_command` (else `local_start_command`) from `levain.yml` natively on `$FEATURE_PORT`, and sets `APP_LOG`; `lv-docker-down.sh` stops it the same way. Its exit 3 means the project declared no usable start command, and exit 1 prints the app's own log. Either is a `needs-input` question about **that command** — quote it and the log tail — never a remedy of "set up Docker" for a project that does not use it (a client's LVI-002).
   Also read `guest_entry_path` from `levain.yml` (root of repo). If set, store it as `GUEST_ENTRY_PATH`.

   **`$TEST_ACCOUNT` is the sign-in line** — display it verbatim with the URL in every state below. A fresh container has no account unless `test_account_command` made one. **Attended, whenever you hand the human the app, open it for them** with `../../scripts/lv-exec.sh lv-open-url.sh --fresh --as <account> <url>`, choosing the one account they need from the note, as `/lv-accept` step 6 does. Never print a list of accounts for them to pick from. The script opens nothing under `LV_UNATTENDED=1`.

   **`$TEST_ACCOUNT` is `test_account_note` verbatim, and it may be several paragraphs.** It is the project's durable sign-in recipe, written once by whoever worked it out. Read it in full and follow it, including when it tells you not to use the container at all — client-b' says to stop the container, run on the host at `:8083` against a local `client-c` at `:8084`, and gives a headless `/login` actions-json recipe.

   **Before you conclude it is empty, check the config yourself:**
   ```bash
   scripts/lv-exec.sh lv-config-get.sh test_account_note --text
   ```

   A non-empty note IS the answer, and asking anyway is the failure: client-b recorded the full recipe at a `/lv-attend` gate after PLN-012's tester asked, and PLN-014's tester opened `needs-input` with the identical question anyway, which a human answered a third time (WFI-021). The durable answer was present and unread. A note that exists satisfies the stop-and-say-so condition below — read it and carry on.

   **If `test_account_note` is genuinely empty and any criterion needs a signed-in session, stop and say so before walking criteria.** Attended: ask the user how to get an account, and once they answer, tell them to record it as `test_account_command` / `test_account_note` in `levain.yml` so the next run does not repeat this. Unattended: **[GATE]** `needs-input` with the question "criteria N, M need a signed-in session and the container has no account — what provisions one?".

   Do not work around it silently and do not mark those criteria skipped, untested or passed. client-a's WFI-072 stalled a run at criterion 5 of 5 for exactly this, and the reporter's read of the earlier runs is the reason this paragraph exists: two prior plans shipped with every criterion behind the login unexecuted, and nothing in the record said so.

   **If the container will not build, decide first whether that is a fact about the code or about the machine.** `no space left on device`, `ResourceExhausted` writing to the overlayfs snapshotter, `Cannot connect to the Docker daemon`, and an OOM kill are all statements about the host — none of them is a plan defect, a failed criterion or a finding, and writing one up as any of those puts a fabricated result into the record. client-a's WFI-212 was a full system disk reported through the test path with nothing to route it to.

   `no space left on device` specifically already self-heals: `lv-docker-up.sh` prunes (`docker system prune -f` and `docker builder prune -f`) and retries on its own, bounded by `dockerRetry.maxAttempts` (default 2), before it ever returns failure to you (client-e's WFI-019 — this was previously a needs-input gate every time, fixed twice by hand with nothing more than a prune). So a build failure you actually see naming that message already survived the automatic retries; do not prune again on top of it.

   ```bash
   ../../scripts/lv-exec.sh lv-docker-cleanup.sh
   ```

   That tears down containers left behind by plans that have finished — the harness's own litter, and the only disk this skill owns. Retry the deploy once after it. **Reclaiming build cache and images beyond what `lv-docker-up.sh` already tried is `docker system prune` run by hand, and that is not yours to run**: it affects everything on the machine, not just this project.

   If the retry fails the same way, **stop** — the plan stays in `testing`, untouched. Attended: say plainly that the host is out of space (or the daemon is down), and that a prune is the likely fix and theirs to authorize. Unattended: **[GATE]** `needs-input`, quoting the error verbatim, with the question naming it as an infrastructure fault rather than a test outcome. Do not mark criteria passed, failed, skipped or untested, and do not route the plan anywhere.

   **If any criterion needs a real phone or tablet, bring the container up with `--tunnel`:**
   ```bash
   eval "$(../../scripts/lv-exec.sh lv-docker-up.sh --tunnel)"
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
3a. **Start the suite section — detached, so nothing waits on it.** Once the app is up, and before step 3c drives a single criterion, in one call:
   ```bash
   cd /abs/path/to/feature-branches/PLN-NNN-<slug> \
     && E2E_SCOPE=$(awk '/^## E2E Scope/{found=1;next} found && /^## /{exit} found && /[^[:space:]]/ && !/^_/{print}' ../../plans/PLN-NNN-<slug>/plan.md | tr '\n' ' ' | xargs) \
     && ../../scripts/lv-exec.sh lv-test-tree.sh PLN-NNN-<slug> \
     && ../../scripts/lv-exec.sh lv-suite-run.sh --label test-PLN-NNN --only-e2e --extra-args "$E2E_SCOPE" --reuse --detach
   ```
   **Note the `TREE` line and the `SUITE_HANDLE=` it prints** — Testing step 4 collects the verdict with that handle, and nothing else will.

   It runs only what verify did not. The script appends `test_only_e2e` and the plan's E2E scope to `test_command`; with both empty that is the **full suite**, the same command `lv-verify` ran, and `--reuse` hands back verify's verdict at once instead of running it again — when the tree, the command, the toolchain and the Levain version all match and both trees were clean (LVI-035). Any change since verify, or a non-empty scope, runs for real, in a process that outlives this call. Where `test_only_e2e` matches no test and the plan names no scope (a project with no E2E-named tests), the script runs the full suite instead, and says so in the log. A run that executes no test is never a pass: a scope the plan named that matches nothing comes back `fail (no tests ran …)`. The suite needs the app up for its E2E tests, which is why this follows step 3 and not entry.

   **Do not wait for it here, and do not run it any other way.** This step used to run in the foreground after step 3c: a client's attended session was held through a whole unfiltered suite that verify had already run on the same tree, then through a second one at the exit's post-merge check, and the human waited through all of it (LVI-034). Go straight on to step 3b.
3b. **Check for injectable test parameters** — scan `appsettings.json` (and `appsettings.Development.json` if present) for numeric fields whose names suggest probability, rate, chance, or frequency. If any are found, note them and surface them before the criteria list:
   ```
   💡 Injectable parameters detected — modify these in appsettings.json to force or suppress behaviors:
      - "BonusRoundProbability": 0.9  →  set to 1.0 to always trigger, 0.0 to never trigger
   After editing, restart the container: ../../scripts/lv-exec.sh lv-docker-up.sh
   ```
   When presenting or walking through individual criteria, if a criterion tests behavior that appears controlled by one of these parameters, remind the user which parameter to set and to what value before testing that criterion.
3c. **Auto-check every criterion with headless Playwright** — every `#### Chrome-Assisted` criterion, and every `#### Manual` criterion tagged `(eyes:blocking)`, `(eyes:cosmetic)` or untagged, that is not already `PASS`/`FAIL` on the current build in `test-progress.md`. `(external)`, `(soak)` and `(unbuilt)` are skipped: no run today can settle them. This runs attended too, so `accept:manual` starts where automation stopped (LVI-002). There is no other automated browser — the Chrome-extension browser mode was retired (LVI-001). Three tools, pick by what the criterion needs:

   - **Assertion criteria** (element geometry, computed style, cookie attributes, meta tags, console errors, a redirect's resulting URL, text/element presence, state that must survive a refresh) — formulate the JS boolean expression yourself from the criterion text, and the interaction that leads to it (if any) as an `actions-json` array (`click`/`fill`/`press`/`keyboard`/`hover`/`focus`/`mouse`/`selectOption`/`check`/`uncheck`/`waitForSelector`/`wait`/`goto`/`reload`/`download`/`upload`/`clipboard`/`clipboardWrite` — see the script's header comment for the full vocabulary; `press` with no selector is a page-level key such as `Tab`, and CSS selectors pierce open shadow DOM), then run:
     ```bash
     ../../scripts/lv-exec.sh lv-headless-eval.sh "http://localhost:$FEATURE_PORT<route>" "<js-boolean-expression>" '<actions-json>'
     ```
     `actions-json` is optional (defaults to `[]`) — a plain "navigate then assert" criterion needs only the URL and expression. `consoleErrors` (an array of strings, collected across navigation and every action) is in scope for "no console errors" style criteria.

     **A file download, a file upload and the clipboard are scriptable.** `download` clicks and keeps the file, and the expression reads `downloads[i]` (`filename`, `size`, `text`, `sha256`). `upload` fills a file input or answers the file chooser a button opens, from a path or inline content. `clipboard` reads the clipboard into `clipboard` after a Copy click. A client's LVI-036: an unattended tester recorded all 7 of a plan's Chrome-Assisted criteria as `needs: device — file download requires real browser` and opened a gate, and an attended session then passed all 7 against the same cached browser. The gate now counts a `needs:` note that names a download, an upload or the clipboard as an excuse.

     **`lv-exec.sh` is not a prefix you can drop.** These scripts live in the build it resolves — `scripts/gen/<version>-<stamp>/v2.00/` — so `scripts/lv-headless-eval.sh` does not exist, `ls scripts/` shows no headless anything, and reading the file directly to learn its interface fails. client-d's WFI-019 concluded from exactly those two checks that the harness had shipped without them and rebuilt a Playwright driver by hand; both scripts were installed and working. The header comment is the manual, and the dispatcher serves it for every script whether or not that script parses the flag:
     ```bash
     ../../scripts/lv-exec.sh lv-headless-eval.sh --help
     ```
   - **Visual/subjective criteria** ("looks right", "layout correct on mobile", "feels natural") — run the same kind of `actions-json` to reach the state in question, then capture and judge it yourself instead of leaving it for a human:
     ```bash
     ../../scripts/lv-exec.sh lv-headless-screenshot.sh "http://localhost:$FEATURE_PORT<route>" "/tmp/wf-shots/<plan>-<n>.png" '<actions-json>'
     ```
     On exit 0, **Read the saved PNG and judge it against the criterion as a careful human looking at that screen would** — record PASS/FAIL with a one-line description of what you saw, same as any other result. Pass `width height` (5th/6th args) to check a specific breakpoint the criterion names; default is 390×844 mobile.

     **A criterion about the fold needs `--viewport`.** The default capture is `fullPage` — the whole scrollable document stitched into one tall image, so content the user would have to scroll to reach appears in the PNG exactly as if it were on screen. Any criterion phrased "without scrolling", "above the fold", "visible on landing" or "first thing you see" is unjudgeable from that image in either direction, and client-b read a 390×1196 full-page PNG as satisfying one (WFI-011). Add the flag, and the image stops where the viewport does:
     ```bash
     ../../scripts/lv-exec.sh lv-headless-screenshot.sh "http://localhost:$FEATURE_PORT<route>" "/tmp/wf-shots/<plan>-<n>.png" '<actions-json>' 390 844 --viewport
     ```
     Prefer `lv-headless-eval.sh` with a geometry expression when the criterion can be stated as one (`el.getBoundingClientRect().bottom <= window.innerHeight`) — an assertion beats a judged image. Use `--viewport` when the criterion is genuinely visual *and* about the fold.

     **A criterion that names NO viewport is not a mobile criterion — capture both.** The default is 390×844 because `lv-headless-eval.sh` shares it, not because an unqualified visual claim is about phones. Judging one at the default alone records a verdict about the one width the criterion did not ask about:
     ```bash
     ../../scripts/lv-exec.sh lv-headless-screenshot.sh "http://localhost:$FEATURE_PORT<route>" "/tmp/wf-shots/<plan>-<n>-390.png"  '<actions-json>'  390  844
     ../../scripts/lv-exec.sh lv-headless-screenshot.sh "http://localhost:$FEATURE_PORT<route>" "/tmp/wf-shots/<plan>-<n>-1280.png" '<actions-json>' 1280  800
     ```
     Read both. **PASS only if the claim holds at both widths**; if it holds at one and fails at the other, that is a FAIL, and the note says which width failed and by how much. client-b WFI-034: *"the composition reads as one full-screen warm background"* was judged from the 390px default and recorded PASS. The plate is 324px wide — near-full-bleed at 390, a narrow centred column with flat background either side at 1280. All 7 criteria went down as PASS on a build whose Goal (*"the warm grained plate fills the viewport below the appbar"*) was unmet, and only a human arriving at the manual-test gate caught it.

     Where a width genuinely cannot be reached, that is [a recorded reason it could not be run](#testing), not a PASS — the same rule as any other criterion this step cannot settle. "I measured it somewhere" is not "I measured it where the claim lives".
   - **Criteria needing TWO OR MORE concurrent browsers** ("the same account on two devices", "reload-rejoin while a peer is still connected", "the second tab does not get the session cookie") — `lv-headless-session.sh`. Each named context is a separate browser context with its own cookies and storage, which is what makes it a *device*; `steps` interleave across them, and one `expr` in one named context is the verdict:
     ```bash
     ../../scripts/lv-exec.sh lv-headless-session.sh '{
       "contexts": [ {"name":"phone",  "url":"http://localhost:'"$FEATURE_PORT"'<route>"},
                     {"name":"laptop", "url":"http://localhost:'"$FEATURE_PORT"'<route>"} ],
       "steps":    [ {"context":"phone",  "actions":[{"type":"click","selector":"#join"}]},
                     {"context":"laptop", "actions":[{"type":"reload"}]},
                     {"context":"laptop", "wait":500} ],
       "expr":     {"context":"laptop", "js":"document.querySelectorAll(\".peer\").length === 2"}
     }'
     ```
     Same exit contract as `lv-headless-eval.sh` — 0 `PASS`, 1 `FAIL`, 2 `ERROR` — and `--help` is the header. Pass a long session as `@/path/to/session.json` rather than fighting the quoting.

     **A criterion that needs two browsers is scriptable, not human-only.** client-b WFI-028: PLN-014's criteria 8 and 9 each needed two concurrent contexts, step 3c had no verb for it, and the unattended tester recorded both as untestable — *"no interactive browser window can be opened"* — and opened a manual-test gate. An attended session then wrote a two-context driver by hand against this same cached browser and both passed. The capability was always there; only the vocabulary was missing, and a criterion that is scriptable but has no verb reaches a human exactly as if it were not scriptable at all.
   - **Exit 0 or 1 from `lv-headless-eval.sh` or `lv-headless-session.sh` (`PASS`/`FAIL` on stdout), or a judged screenshot from `lv-headless-screenshot.sh`, is a real, high-confidence result — record it and move on. Do not gate on it and do not also route it through the manual criteria loop.** That holds for a `#### Manual` eyes criterion too: a screenshot you captured on this build and judged clearly is its result, and its Notes say so (`headless screenshot 390+1280: …`). Only a capture you cannot honestly judge either way stays at `—`, with what was ambiguous noted, for the human. A criterion this scriptable does not need a human, an extension, or even asking — the result goes straight into `test-progress.md` against the current `$BUILD`, same as any other recorded PASS/FAIL.
   - **A sign-in is not a reason a criterion cannot run headlessly when `$TEST_ACCOUNT` gives a recipe.** Put the recipe's `/login` steps at the front of the criterion's `<actions-json>` (or into an `lv-headless-session.sh` context) and run it. "OIDC sign-in cannot be completed headlessly in unattended mode" is not a result: a client's LVI-040 recorded exactly that for all 6 Chrome-Assisted criteria of a plan whose `test_account_note` spelled out the headless `/login` recipe, and a human was asked about work nobody tried. Only a recipe that was *run* and returned `ERROR` is a recorded reason — note the step that failed.
   - **Exit 2 (`ERROR` on stdout, any of the three scripts) is "a recorded reason it could not run", never a FAIL.** Leave the criterion at `—` with that `ERROR` line noted in session memory (it surfaces in test-progress.md's Notes on exit, verbatim: `lv-manual-gate.sh` reads a note with no `ERROR`, no disagreement and no `needs: oauth|device|extension|profile` as a criterion nobody ran) and let it fall through to the criteria loop / gate below like any other untested Chrome-Assisted criterion. A missing headless browser on this machine (no network on first use), a selector that never appears, or a criterion that genuinely needs real third-party OAuth, a physical device, a browser extension, or the user's own logged-in profile are the ordinary cases of this — not defects to work around, and the point at which a human is the right next step, not this step retried differently.
   - **A headless PASS or FAIL that contradicts a result already recorded for this same assertion on a prior build — attended human testing included — is low-confidence, whatever the headless run says.** Do not overwrite the existing record with the automated verdict in either direction. Instead: leave the criterion at `—`, note both readings ("headless: FAIL (scrollWidth 464 > innerWidth 390), prior human PASS on build <sha>"), and let it reach the gate as a named disagreement — the gate question should say what conflicts, not just that a criterion is untested. client-f's PLN-004 criterion 6 is the worked example: a real-device human PASS and a 390px-CSS-viewport headless FAIL on the same "no horizontal scroll" assertion disagreed, and the disagreement — not either individual reading — is what needed a human's eyes (WFI-008). A criterion with no prior recorded result has nothing to disagree with, so an unambiguous headless PASS/FAIL there is not low-confidence merely for being the first result.
4. **Join the suite section — but not here.** Step 3a started it, detached; this step collects it, and *when* is the point of the split (LVI-034). Step 3c's headless runs overlap the suite instead of following it:

   In both modes: after step 3c and the [order of work](#unattended-mode)'s step-5 dispositions, **before** its step 6 asks `lv-manual-gate.sh` anything. Moving the plan to `accept` ends the run, and a run may not end with its suite still going — so the suite is collected first and the gate question can quote its verdict.

   ```bash
   ../../scripts/lv-exec.sh lv-suite-wait.sh <SUITE_HANDLE>    # 0 pass, 1 fail, 3 still running
   ```
   On `3`, call it again with the same handle, as many times as it takes — each call is a foreground command under the cap and keeps the session alive. **`3` is neither a pass nor a failure.** No `run_in_background`, no scheduled wake-up, no "I'll check back": the loop is the only wait that exists, and ending the turn is abandoning the run (WFI-114, WFI-255, WFI-266).

   **Every exit joins it first** — findings, all-pass, `accept`, a gate, the merge-blocked path. The one exception is an attended early abort (the user interrupts the run): say the suite is still running and that the next `/lv-test` reuses its receipt if it passes, and leave it.

   Record the result in `test-progress.md` under step 3a's `TREE` stamp, with `SUITE_CMD=` and `SUITE_RESULT=` quoted verbatim. Report it to the user. **A reused result is recorded as reused**: `SUITE_RESULT=pass (reused …)` quoted as printed, totals from the `SUITE_REUSED_FROM=` log — never as a run you made.

   **Never type step 3a's scope flags yourself.** The script appends them through `eval`, which keeps several flags several arguments. Wrapped in one pair of quotes they do not error — the runner takes the lot as a single unrecognised argument, ignores the filter, and runs the **whole suite** while reporting it as the scoped result. Measured on client-a's PLN-007: quoted, `total: 435`; the same flags unquoted, `total: 1`. Nothing in the output distinguishes them (WFI-080), and every "scoped" run was really a full-suite run hammering the rate limiter — a 429 cascade that two verify passes had blamed on daemon contention.

   **So check the count, not just the exit code.** If `$E2E_SCOPE` named a handful of tests and the run reports hundreds, the filter did not apply: fix the command form and re-run before reading anything into the result.

   **A runner that could not run is not a suite that failed.** Before you read a single number, decide which of the two you are looking at:

   | What you see | What it is |
   |-|-|
   | assertion failures, named tests, expected-vs-actual | a **test result** — classify it as normal |
   | the runner could not start, could not restore, could not write its results file, `DirectoryNotFoundException`, `No such file or directory`, a path that does not exist | an **infrastructure error** — there is no test result here at all |

   An infrastructure error is **never** a finding and **never** a state transition. Fix the environment and re-run, or file it with `lv-issue.sh` and stop. client-a's PLN-111 (WFI-172): the plan was already `complete`, its worktree removed, so the runner resolved its relative `TestResults/` directory against a deleted working directory and could not write the TOOL. That single writer failure was reported as "29 errors", written up as a finding, and used to move the plan `complete → active`. Re-running the suite on develop gave 871 total, 0 failed. **A count of "errors" with no named test behind it is the signature** — read the message before you believe the number.

   `lv-registry-update.sh` now refuses to move a plan out of a terminal state, so this particular regression stops at a refused transition. That is the backstop. The fault it is catching is that you were dispatched at a finished plan at all: re-check step 0's `--state testing` claim before doing anything else.
5. **Finish the automated half — the same in both modes.** Run the [order of work](#unattended-mode)'s steps 4–6: auto-test what matches a recurring shape, dispose of `(external)` / `(soak)`, collect the suite, commit `test-progress.md`, and let `lv-manual-gate.sh` decide. Its answer leaves three ways out, and none of them is a question to a person about a criterion:

   | What the record says | Exit |
   |-|-|
   | Any criterion FAIL | [If findings](#if-findings-failures) |
   | `GATE='false'`, every criterion PASS on this build, settled by a tick, or an unsettled `(eyes:cosmetic)` | [If all pass](#if-all-pass) |
   | `GATE='true'` | `testing → accept`, gate, unclaim — the human half is `/lv-accept`'s |

   **A plan that comes back from `/lv-accept`** arrives in `testing` with the human's verdicts committed in `test-progress.md` against this build (Notes `human (/lv-accept)`). Step 3c skips what is already PASS on the current build, so those rows are not re-run and not overwritten, and the gate script counts them: the normal outcome is `GATE='false'` and the ship exit. If it says `true` again, something moved — a `release` merge touched a rendering surface (`SURFACE_MOVED`), or a row was paraphrased — and the plan goes back to `accept` with the question naming it.

### Auto-test mode

Entered from the [order of work](#unattended-mode)'s step 4, and from `/lv-accept` when the human picks `[a]`. Active only when `autoTestGrowth.enabled: true` in `levain.yml`.

**Why this exists:** instead of walking a person through a manual check, spawn a sonnet subagent that writes (or locates) a real automated test, runs it, and commits it on pass. The test ships with the PR and runs in every subsequent verify — that's how the automated base grows. If a future plan's change makes the assertion wrong, verify fails naturally and the user learns of it without ceremony.

**Read config** (first `[a]` only — cache afterward):

```bash
CFG="$DEVELOP_ROOT/levain.yml"
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

Parse the line against the contract: prefix is `EXISTS:`, `PASS:`, or `FAIL:`. For EXISTS/PASS, split the payload on `|` into `<test name>` and `<file path>`. For FAIL, the payload is a single reason string — if it happens to look like a test identifier or contains `|`, reject it and treat the criterion as unsettled (do NOT log it as a Candidate).

- **`EXISTS:<name>|<file>`** or **`PASS:<name>|<file>`** — mark the criterion PASS on the current build. Append a row to the **Realized** section of `$DEVELOP_ROOT/$AUTO_TEST_LOG` (create file with headers if absent — see format below) using 5 columns: Plan, Criterion, Test, File, Date. Note the test name alongside the criterion in session memory (it surfaces in the test-progress.md "Notes" column on exit). Continue to the next criterion.
- **`FAIL:<reason>`** —
  - If `AUTO_TEST_LOG_CANDIDATES=true`: append a row to the **Candidates** section of `$DEVELOP_ROOT/$AUTO_TEST_LOG` using **exactly 4 columns**: Plan, Criterion, Reason, Date. Do NOT copy the 5-column Realized format. If the reason contains a `|` character, replace it with `/` before writing to preserve the column count. Say: "Auto-test couldn't produce a passing test: `<reason>`." Then treat the criterion as unsettled (below).
  - Else: treat the criterion as unsettled, silently.

  Unsettled means: here, leave it at `—` with the reason for `accept:manual`; in `/lv-accept`, carry on with the human's walk.

Always sanity-check the tree after the agent exits: `git status --short` should be clean except for a possible new committed test. If it's dirty, the agent left junk — `git restore .` and treat as FAIL.

### Log format

Path: `$AUTO_TEST_LOG` (default `plans/auto-test-log.md`), resolved relative to the develop worktree root.

**Realized entries prove what shape of criterion can be auto-tested** — lv-spec reads them during planning and lv-implement reads them for test-style reference. Every Realized entry is direct feedback that a future plan with a similar criterion should classify it as automated up front.

**Candidate entries** are the agent-failed cases, reviewed by a human later.

Header (create file only if absent — write both section headers at creation time so each always exists):

```markdown
# Auto-test log

Every `[a]` flag hit in `/lv-test` is appended here. `### Realized` entries are
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

**The skill only proceeds to the "all pass" exit path when every criterion shows PASS with the current build identifier, or is settled by a tick (deferred, cosmetic-filed, or scoped out by a human in `/lv-accept`).** The one exception: under `GATE='false'`, an `(eyes:cosmetic)` criterion no run could settle stays at `—` and does not hold the exit (step 6). This is the single rule that drives the system. An earlier build's PASS counts only where `lv-manual-gate.sh` carried it (`MANUAL_CARRIED`); anything else is re-run by step 3c or, failing that, goes to `accept:manual`.

### Completion confirmation

**Join the suite first** ([Testing step 4](#testing)) if you have not — the confirmation quotes its verdict.

**[AUTO] in both modes** — when the [Completion gate](#completion-gate) holds, proceed straight to the exit path. There is no prompt: a person's notes, a related bug, or a design concern belong to `/lv-accept`, where the human is looking at the build. A plan that needed no human was never going to have one here either.

### Saving test progress

Test progress is written **twice**: once at step 6 before the gate script is asked anything, and again at exit with whatever changed after it. In between, the LLM holds in-memory state. `/lv-accept` writes the same file to the same rules — the human's rows carry Notes `human (/lv-accept)`.

The step 6 write is not bookkeeping. `lv-manual-gate.sh` decides whether to stop for a human by reading this file and subtracting every criterion it finds recorded PASS against the build standing in the worktree — that subtraction is the only thing that tells it a Manual criterion has been judged, because a passed criterion's checkbox in `plan.md` stays empty (WFI-013). A gate asked before the file is written is asked about a session whose work it cannot see.

**Format** — `../../plans/PLN-NNN-<slug>/test-progress.md`:
```markdown
## Test Progress — PLN-NNN-slug

TREE feature-branches/PLN-NNN-slug @ feature/PLN-NNN-slug a1b2c3d (2026-08-17T15:14:51Z)

| # | Criterion | Build | Result | Notes |
|-|-|-|-|-|
| 1 | criterion one text | Apr 07 09:15 (a1b2c3d) | PASS | |
| 2 | criterion two text | Apr 07 09:15 (a1b2c3d) | PASS | auto: EXISTS Handoff_SetsCookieAndRedirects |
| 3 | criterion three text | Apr 08 14:32 (f4e5d6c) | FAIL | |
| 4 | criterion four text | — | — | headless: ERROR playwright chromium install failed (no network) |
| 5 | criterion five text | — | — | headless FAIL (scrollWidth 464 > innerWidth 390) vs prior human PASS on build a1b2c3d — disagreement, needs eyes |
| 6 | criterion six text | Apr 08 14:32 (f4e5d6c) | PASS | headless screenshot: mobile 390px layout matches, no overlap |

Last failure: #3 on build Apr 08 14:32 (f4e5d6c)
```

- The `TREE` line is the one `lv-test-tree.sh` printed, pasted. If you are writing this file without one in your tool output, you have no provenance for the results below it — re-run the command in the plan's worktree and paste what it prints.
- One row per criterion, always present. Result: `PASS`, `FAIL`, `SKIP`, or `—` (untested).
- **An untested Chrome-Assisted row's Notes must be one of three things, or the gate counts the criterion as never run** (`CHROME_EXCUSED`, LVI-030/033): the `ERROR …` line a headless script printed; a headless reading that disagrees with a prior one (row 5); or `needs: oauth|device|extension|profile — <why>` for the four things Playwright cannot be. "Needs browser mode", "requires user interaction" or "needs eyes" describe a criterion you did not try — hover, Tab order, iframes, shadow DOM, file downloads, file uploads and the clipboard are all scriptable, and a `needs:` note naming a download, an upload or the clipboard is counted as an excuse (LVI-036).
- **Unattended, write `PASS` on a `#### Manual` eyes criterion only from a headless run or screenshot you captured on this build, with Notes saying which, and never change a result you did not produce this run.** A human's FAIL, or any prior reading, that your run contradicts is a disagreement (row 5), not something to overwrite. The gate counts an unattended worker's Manual PASS only from the committed file, which is why step 6 commits before it asks (LVI-033, LVI-002).
- **Notes is where an untested (`—`) row's reason ends up at exit.** Held in session memory like every other result until then (see above), but write it here rather than dropping it: the auto-test agent's outcome (`EXISTS`/`PASS` name, or a `FAIL` reason) and step 3c's headless-eval outcome (why it couldn't run, or what it disagreed with) both belong in this column. A reason that never reaches the file does not survive a compaction or a different session resuming the plan — this file is the only thing either reads (WFI-070's own lesson, applied to the reason column, not just the verdict column).
- Only the most recent result per criterion is stored — overwrite on retest.
- **The Criterion column is matched against `plan.md` by the gate script**, so copy the criterion text rather than summarizing it. Matching survives a dropped route prefix or a trimmed trailing clause; a criterion rewritten in your own words matches nothing, and the gate counts it open and stops for a human who has already judged it.
- "Last failure" line records the resume point for the next session.
- **Start from the file that is already there, and never write `—` over a result you did not retest.** This file is the only record that a criterion was ever executed; a session that regenerates it from scratch erases whatever an earlier session — or a human sitting at the app right now — established. client-a lost a completed 15/15 run to a rewrite exactly like that (WFI-070). Carry forward every row you did not test yourself, build identifier included.

**On findings (failure exit):** write test-progress.md with current state. Include in the findings commit:
```bash
git add plans/PLN-NNN-<slug>/findings.md plans/PLN-NNN-<slug>/test-progress.md
# If the auto-test agent logged any outcomes this session:
git add plans/auto-test-log.md
```
Do **not** add `plans/deferred-criteria.md` here: `lv-defer-criterion.sh` commits that file itself, together with the `plan.md` checkoff that belongs with it, and a pathspec of yours can only pick up one of the two halves (WFI-144).

**On complete (all pass on current build):** delete the progress file as part of cleanup:
```bash
rm -f plans/PLN-NNN-<slug>/test-progress.md
git add plans/PLN-NNN-<slug>/test-progress.md
# If the auto-test agent logged any outcomes this session:
git add plans/auto-test-log.md
```
Again, no `plans/deferred-criteria.md` — its writer commits it.
(Include in the final completion commit.)

**On early abort** (the run is interrupted): save progress like findings exit so the next session can resume. If no criteria were tested this session, do not overwrite the file.

### Scope reduction

**`/lv-test` never reduces scope.** Only a human may, by saying so, and that happens in `/lv-accept` — which files the edge case as a bug and ticks the criterion, so the record says who scoped it out and why. A criterion that has failed across several fix cycles is a failure, not grounds to ship: take the findings exit. You are a haiku model holding `gh pr merge` over `release`, and every guard in `/lv-deploy` rests on `release` containing only validated work.

---

### Deferring a criterion

Never write `plans/deferred-criteria.md` by hand — one script owns it, so IDs stay unique and `/lv-spec` step 1a can read it back:

```bash
../../scripts/lv-exec.sh lv-defer-criterion.sh PLN-NNN <tag> - [--prereq <plan-id|first-real-use|next-cycle|date>] [--note '<what is not built yet>'] <<'CRIT'
<criterion text, copied verbatim from plan.md>
CRIT
```

**Pass the criterion on stdin with `-`, exactly as above. Never inside double quotes.** Plan criteria contain backticked commands — that is normal, and it is why this matters: in a double-quoted argument the shell **runs** those commands before this script sees anything, and substitutes the output into the row. client-a's WFI-194 is that: an unattended tester deferring a PLN-179 criterion executed a real `drive-sync` pull against a mounted physical volume as a side effect of recording a deferral, and DC-119 was written holding 2.5KB of rsync output with the backticked paths blanked out. **Any command a planner puts in backticks inside a criterion runs, unreviewed, with your privileges.** The heredoc is quoted (`<<'CRIT'`) so nothing in it expands. Single quotes are the minimum acceptable alternative; the script refuses text that arrives multi-line or over 500 characters, which is what a substituted criterion looks like.

| Tag | Use when |
|-|-|
| `external` | The criterion is tagged `(external)` — needs a real third-party system, real credentials, or a physical act |
| `soak` | The criterion is tagged `(soak)` — needs real elapsed calendar time |
| `unbuilt` | `/lv-accept` only: the human skipped it because the prerequisite feature does not exist yet. Ask "Is this related to a specific plan? (e.g. PLN-022, or leave blank)" and pass it as `--prereq`; put what they said is missing in `--note` |

`external` and `soak` criteria are deferred **automatically at exit** (see [Manual criterion dispositions](#manual-criterion-dispositions)) — nobody walks a human through them. The `unbuilt` path is the one that needs a human's confirmation first, which is why only `/lv-accept` takes it.

**The script commits what it wrote, both sides — do not name either path in a commit of your own.** A deferral is one state change with two halves: the DC row, and the `[x] … — deferred as DC-NNN` checkoff in `plan.md`. It used to write both and commit neither, and the exit pathspec below names `deferred-criteria.md` and never the plan's own `plan.md`, so across one 16-plan sweep six checkoffs stayed uncommitted on plans that had already reached `complete` — read from git those plans show the criterion as `[ ]`, which is the "silently dropped" reading the checkoff exists to remove (WFI-144).

### Closing a deferred criterion out

A DC row is `open` until one of two things ends it. Both are one call, and both commit the file themselves:

```bash
../../scripts/lv-exec.sh lv-defer-criterion.sh --consume DC-NNN PLN-NNN            # a later plan adopted it
../../scripts/lv-exec.sh lv-defer-criterion.sh --satisfy DC-NNN --evidence "<proof>"  # the real use happened
```

**A criterion's wording is not final either.** When you learn something the row
should have said — a precondition, a qualification, a criterion that turns out
to be incomplete — amend it. Do not fold it into `--evidence`, which files the
words under the outcome where someone who has not yet run the criterion never
sees them, and do not satisfy-and-re-defer, which breaks every reference to the
old ID (WFI-158):

```bash
../../scripts/lv-exec.sh lv-defer-criterion.sh --amend DC-NNN --criterion - <<'CRIT'
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
| `(eyes:blocking)` | Record the PASS in `test-progress.md` | Write a finding, route the plan back as normal — current behavior |
| `(eyes:cosmetic)` | Record the PASS in `test-progress.md` | **File a bug, tick the box in `plan.md`, let the plan complete** |
| `(external)` | — | — |
| `(soak)` | — | — |

**On PASS you record; you do not tick.** This column used to read *"Check it off"*, which contradicts [Saving test progress](#saving-test-progress) — *"a `#### Manual` criterion you judged and passed this session stays unchecked in `plan.md` … you only ever tick a box on a deferral or a cosmetic failure"* — flatly, with no stated precedence, and `lv-manual-lint.sh` exits 0 either way so nothing disambiguated it (client-b WFI-032). **The absolute statement wins, and it is the one the machinery is built on:** `lv-manual-gate.sh` decides whether to stop for a human by subtracting the criteria recorded PASS in `test-progress.md` against the build in the worktree, and an empty checkbox is what makes that subtraction the only signal (WFI-013). Tick on PASS and the record the gate reads is the one you skipped writing.

Ticking on a **cosmetic failure** is not an exception to that — it is the opposite move for the opposite reason. There is no PASS to record, and the box is what tells `lv-registry-update.sh`'s `testing → complete` guard the criterion is settled. A deferral works the same way.

**Cosmetic failures fail soft.** When an `eyes:cosmetic` criterion fails, do not write a finding and do not block the plan. Instead file it as a normal bug and move on:

```bash
eval "$(../../scripts/lv-exec.sh lv-bug-new.sh "<what you saw>" \
  --severity Low --source agent:lv-test \
  --description "<what the criterion asked for and what rendered instead>" \
  --links "cosmetic criterion from PLN-NNN")"
# → $BUG_ID, $BUG_DIR. It allocates through the counter and commits.
```

Then check the criterion off in `test-progress.md` with `— COSMETIC (filed $BUG_ID)`. A papercut that should be fixed next week does not hold a merge.

**`external` and `soak` never gate and never fail.** They cannot be satisfied at gate time by anyone, so gating on them buys nothing and costs a stop. At exit, defer each one and check it off:

```bash
../../scripts/lv-exec.sh lv-defer-criterion.sh PLN-NNN external "<criterion text>"
../../scripts/lv-exec.sh lv-defer-criterion.sh PLN-NNN soak "<criterion text>"
```

The criterion travels to whichever future plan touches that surface — which is exactly what `/lv-spec` step 1a exists to consume.

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
   ../../scripts/lv-exec.sh lv-merge-release.sh
   ```
   If this fails with non-trivial conflicts, route back to builder (same as merge-blocked path below).

   **Post-merge validation** — catch semantically broken merges that git auto-resolved without conflict markers. **This runs the full suite by default, not a build.** Do not type a test command here; run the script:
   ```bash
   ../../scripts/lv-exec.sh lv-post-merge-check.sh --label "post-merge-$PLAN_NAME"
   ```
   It reads `postMergeCheck:` from `levain.yml` — `full` (default: `build_command` then `test_command`, whole and unfiltered) or `build` (build only, the pre-9.8 behavior). **Exit 0 good, 1 the merged tree is broken, 2 nothing is configured to check it with** — 2 is a gap to report, never a pass.

   **When `origin/release` had nothing new, the merge leaves the tree verify already measured**, and the check answers from that receipt in seconds — `SUITE_RESULT=pass (reused …)` (LVI-035). Any change the merge brought in runs the suite for real; that is the case this check exists for.

   **The suite may outlast a foreground Bash call** (the cap is 10 minutes). Detach and wait in slices, exactly as `/lv-release` step 7 does — never `run_in_background`:
   ```bash
   ../../scripts/lv-exec.sh lv-post-merge-check.sh --label "post-merge-$PLAN_NAME" --detach   # prints SUITE_HANDLE=
   ../../scripts/lv-exec.sh lv-suite-wait.sh <SUITE_HANDLE>                                   # 0 pass, 1 fail, 3 still running
   ```
   On `3`, call it again with the same handle, as many times as it takes.

   **Why the suite and not just a build.** The tree this creates is the tree that reaches `release` sixty seconds later, and the only other thing that ever runs a suite on it is `/lv-deploy` — after the plan is complete, its worktree destroyed, and a human already asked to approve the promotion. client-a, 2026-09-18: PLN-283 and PLN-284 were each green alone and together broke one CLI test (`CaptureTimingTests.SendNote_WithATicket…` — PLN-283 moved what the ticket folder holds, PLN-284's path asserted the old shape). Both compiled, so the build check passed both. Three deploys found it, one 20-minute suite each, and DEPLOY parked `stuck` with fifteen completed plans behind it. A semantic merge break is what the merging side is best placed to fix and worst placed to notice.

   On failure (exit 1):
   ```bash
     echo "POST-MERGE CHECK FAILED after merging release. The merge combined incompatible code."
     echo "Routing back to builder to resolve."
   ```
   - Write findings to `plans/$PLAN_NAME/findings.md`, **quoting `SUITE_RESULT=` and the failing test name verbatim** — the builder's whole starting point is which assertion broke:
     ```markdown
     ## Broken After Release Merge — YYYY-MM-DD
     
     - [ ] **Behavior**: <build failed | suite failed: N of M, `<failing test>`> after merging origin/release into the feature branch. Git auto-resolved the merge without conflict markers; the result is broken anyway. Review the merge commit and fix it here — this must not reach release.
     ```
   - Route back to active:
     ```bash
     scripts/lv-exec.sh lv-registry-update.sh $PLAN_NAME testing active --commit "test($PLAN_NAME): broken after release merge — back to builder" --add plans/$PLAN_NAME/findings.md
     ```
   - Destroy container: `../../scripts/lv-exec.sh lv-docker-down.sh $PLAN_NAME`
   - Display: "Post-merge check failed after merging release. Routed back to builder (testing → active). Findings written."
   - **Stop here — do not continue with remaining steps.** Nothing below this point may run: the push and the PR merge are what put the broken tree on `release`.

   Push to remote. **Wrap every call that talks to GitHub in `lv-retry.sh`** — it retries only transient failures (timeouts, 5xx, resets, rate limits) and returns a real refusal immediately:
   ```bash
   ../../scripts/lv-exec.sh lv-retry.sh --tempfail --label "git push" -- git push -u origin "$CURRENT_BRANCH"
   ```
   **Exit 75 means GitHub was still down after every retry — not a question for a person** (coordinator WFI-006). Leave the plan in `testing`, open no gate, and stop: `scripts/lv-exec.sh lv-unclaim.sh $PLAN_NAME`, then exit 0. The next sweep re-dispatches the tester, which is the retry; a plan relaunched too many times without progress still reaches the loop breaker's `stuck` gate, so a long outage does get to a human. Attended, say that GitHub is still failing and to re-run `/lv-test` later.

   **Any other non-zero exit is a refusal** (a protected branch, a rejected non-fast-forward, a permission denial). Display the error and **stop** — ask the user to resolve manually. Under `LV_UNATTENDED=1` this is a **[GATE]** — open gate `merge-failed` with the error verbatim as the question, then exit 0.

   client-a's PLN-157 (WFI-186) finished 1734 of 1734 tests green and then lost its exit path to GitHub: `git push` timed out after 2m, `gh` answered HTTP 503, the release fetch timed out. Each of those parked the plan on a gate whose only correct answer was "try again" — a person doing a computer's retry. **A weather report about github.com is not a fact about the plan.** What must NOT be retried is the other half: a protected branch, a rejected non-fast-forward, a permission denial. Those are answers, and `lv-retry.sh` passes them straight back so the gate question still describes what actually happened.
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

   `merge-base --is-ancestor` cannot fail that way: a broken ref makes it exit non-zero, which routes to the PR — the safe direction. `lv-registry-update.sh` refuses `testing → complete` for an unmerged branch as the backstop, so this now stops at a refused transition rather than a green deploy.
   Create PR (skip if one already exists for this branch):
   ```bash
     OPEN_PR=$(gh pr list --head "$CURRENT_BRANCH" --state open \
                 --json url -q '.[0].url' 2>/dev/null || echo "")
     if [ -z "$OPEN_PR" ]; then
       ../../scripts/lv-exec.sh lv-retry.sh --label "gh pr create" -- gh pr create \
         --base release \
         --head "$CURRENT_BRANCH" \
         --title "feat: $PLAN_NAME" \
         --body "## Feature
   $PLAN_GOAL
   
   ## Test Results
   All acceptance criteria passed — automated, and by a human where one was needed
   
   **Plan:** plans/$PLAN_NAME/
   
   Ready for staging validation."
       OPEN_PR=$(gh pr list --head "$CURRENT_BRANCH" --state open \
                   --json url -q '.[0].url')
     fi
   ```
   **"A PR exists" is not the test — "an OPEN PR exists" is.** `gh pr view <branch>` answers with that branch's most recent PR *in any state*, so a branch whose earlier PR was **merged** and which has since gained more commits reads as "already has a PR". client-d WFI-022: PR #17 was merged before Amendment A1 was written, the branch carried 9 further commits and was not an ancestor of `origin/release`, and following this step literally skipped `gh pr create` and then ran `gh pr merge` against an already-merged PR — which fails, and routes a **passing** plan back to the builder. `gh pr list --state open` returns `[]` there, which is the truth. Merge by URL, too: a bare `gh pr merge` re-resolves the branch through the same `gh pr view` semantics and lands back on the merged one.
   **Merge the PR.** Exit 75 is GitHub still down, the same as the push above: `scripts/lv-exec.sh lv-unclaim.sh $PLAN_NAME`, exit 0, and let the next sweep retry — routing a passing plan back to its builder over a 503 costs a whole build cycle (coordinator WFI-006). Any other failure (conflicts, branch protection, required checks) **stops and routes to builder:**
   ```bash
     ../../scripts/lv-exec.sh lv-retry.sh --tempfail --label "gh pr merge" -- gh pr merge "$OPEN_PR" --merge 2>/tmp/wf-pr-merge-err
     MERGE_RC=$?
     if [ "$MERGE_RC" -eq 75 ]; then
       echo "GitHub still failing after retries — leaving $PLAN_NAME in testing for the next sweep."
       # unclaim and exit 0: no gate, no route back (coordinator WFI-006)
     elif [ "$MERGE_RC" -ne 0 ]; then
       PR_URL="$OPEN_PR"
       echo "MERGE FAILED: PR $PR_URL — see error above."
       echo "Routing back to builder."
   ```
   - Destroy container: `../../scripts/lv-exec.sh lv-docker-down.sh $PLAN_NAME`
   - Switch to project root
   - Write findings to `plans/$PLAN_NAME/findings.md`:
     ```markdown
     ## Merge Blocked — YYYY-MM-DD
     
     - [ ] **Merge blocked**: PR cannot merge into release. Likely cause: merge conflicts. Rebase feature branch onto release, resolve conflicts, then re-trigger verify.
     ```
   - Route back to active:
     ```bash
     scripts/lv-exec.sh lv-registry-update.sh $PLAN_NAME testing active --commit "test($PLAN_NAME): merge blocked — back to builder" --add plans/$PLAN_NAME/findings.md
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
   ../../scripts/lv-exec.sh lv-docker-down.sh $PLAN_NAME
   ```

Steps below run from **project root** — use absolute path `cd /absolute/path/to/project`:

3. Switch to develop and merge feature branch:
   ```bash
   cd /absolute/path/to/project
   git checkout develop
   scripts/lv-exec.sh lv-infra-reset.sh
   scripts/lv-exec.sh lv-stash.sh push merge
   ```
   **Use `lv-stash.sh`, never a bare `git stash` / `git stash pop`.** On a clean
   tree `git stash` saves nothing and still exits 0, so a positional `pop`
   restores the previous session's entry instead — an interrupted lv-test run
   leaves exactly that, and the step below then commits whatever it restored.
   `lv-stash.sh` pops the commit *this* run recorded or nothing at all.
   ```bash
   if ! git merge "$CURRENT_BRANCH" --no-edit; then
     git merge --abort
     scripts/lv-exec.sh lv-stash.sh pop merge
     echo "ERROR: Feature branch has conflicts with develop. Routing back to builder."
   ```
   - Write findings to `plans/$PLAN_NAME/findings.md` about the develop merge conflict
   - Route back: `scripts/lv-exec.sh lv-registry-update.sh $PLAN_NAME testing active --commit "test($PLAN_NAME): develop merge conflict — back to builder" --add plans/$PLAN_NAME/findings.md`
   - Display: "Develop merge conflict. PR was merged to release but develop merge failed. Routed back to builder."
   - **Stop here.**

   On success:
   ```bash
   fi
   eval "$(scripts/lv-exec.sh lv-stash.sh pop merge)"
   # Auto-resolve infra conflicts from the restore (infra files always match develop)
   scripts/lv-exec.sh lv-infra-reset.sh
   # Commit YOUR OWN plan folder, if the restore brought it back dirty.
   # Guarded on LV_RESTORED: with an unconditional pop this committed whatever a
   # previous session had left in the stack, which is how a superseded workflow
   # deploy nearly got committed over a current one (WFI-036).
   if [ "${LV_RESTORED:-false}" = "true" ]; then
     scripts/lv-exec.sh lv-commit.sh "test(PLN-NNN-<slug>): pending plan changes restored after merge" \
       --add plans/PLN-NNN-<slug>/
   fi
   ```

   **Scoped to your plan's folder, never to `plans/`.** The stash took the whole
   shared working tree, so what the pop restores includes every *other* live
   worker's in-flight files; a `plans/`-wide add then commits them under this
   plan's message. client-a saw it twice inside four minutes: one commit
   carried a live lv-spec worker's 207-line PLN-030 amendment plus PLN-010 and
   PLN-012 edits belonging to two more sessions, filed as "plans: commit pending
   changes (restored from stash)" (WFI-109, WFI-110). Nothing was lost and
   nothing was findable. Anything the pop restored that is not yours is restored
   *for its owner* — leave it dirty; that is where they left it.
4. Move the plan out of `testing` **first**, then drop the guards:
   ```bash
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN testing complete - \
     --commit "test(PLN-NNN-<slug>): human test passed — complete"
   scripts/lv-exec.sh lv-gate-close.sh PLN-NNN "manual test passed" --only manual-test
   scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
   ```

   **If `lv-registry-update.sh` exits non-zero here, stop — do not run the two lines
   below it.** They are the guards, and dropping them on a plan the registry still
   reads as `testing` is the race `docs/guard-ordering.md` exists to prevent. A
   refusal naming an OPEN gate means a question is still waiting on a human
   (LVI-008; unattended that includes `manual-test`, LVI-009): unattended, unclaim and exit 0 — the gate holds
   dispatch; attended, put its question to the human and close it with their answer
   via `lv-gate-close.sh PLN-NNN "<answer>" --only <gate>`, then retry. Otherwise the
   refusal you will see here is the `eyes:blocking` completion guard: a Manual
   criterion has no PASS, no deferral and no answered gate, and by this point the
   PR is already merged to `release`, so the work is shipped and only the bookkeeping
   is wrong. Resolve what it names — `lv-manual-lint.sh PLN-NNN --open` lists the open
   criteria and, where `test-progress.md` holds a row that nearly matches one, says
   so. The bare `lv-manual-lint.sh PLN-NNN` grades criterion *wording* and exits 0
   with a criterion still open, which is a contradiction that has cost a diagnosis
   (client-b WFI-033) — **the most likely cause of this refusal is a
   `test-progress.md` Criterion column holding a paraphrase rather than `plan.md`'s
   exact text.** Then re-run this step. If you cannot resolve it, **[GATE]**
   `needs-input` naming the refusal verbatim and exit still holding the claim; a
   claimed plan a human is brought to beats an unguarded one in a state nobody owns.

   **Say what actually happened in that message.** "human test passed" is the
   attended wording and it is a claim about a person. An unattended run that
   reached `complete` because every Manual criterion was legitimately deferred
   did not have a human test — PLN-191 went `testing → complete` in three
   minutes with `GATES: 0`, deferred four `(external)` criteria, and then
   committed a human acceptance test that never occurred, on a plan whose own
   design rationale was "attended, no bypass" (WFI-229). The deferral path
   itself is sanctioned; asserting a test into git history is not. In both
   modes, use the wording that matches the route taken:

   | What happened | Commit message |
   |-|-|
   | A human accepted criteria in `/lv-accept` (rows with Notes `human (/lv-accept)`) | `test(PLN-NNN-<slug>): accepted by a human, automated half passed — complete` |
   | Every Manual criterion deferred `(external)` / `(soak)` | `test(PLN-NNN-<slug>): criteria automated or deferred, no human test — complete` |
   | Automated + Chrome-assisted only, no Manual criteria at all | `test(PLN-NNN-<slug>): automated criteria passed, none required a human — complete` |

   Whichever line you write, the plan's `## Steps`-level record of *which*
   criteria ran, deferred or were skipped goes into `progress.md` before step 7
   deletes `test-progress.md`. A completed plan with no such record leaves the
   next reader unable to tell an automated pass from an unworked one.
   The `lv-gate-close.sh` line is normally a no-op: a plan that went through `accept:manual` had its gate closed by `/lv-accept` on the hand-back. It stays because a pre-split plan can still reach here with one open, and it is safe to run when no gate is open.

   **The order of these three lines is the contract — see [Order of exit](#order-of-exit).**
5. Close linked bugs (if plan Goal has `**Bug:** BUG-NNN`):
   ```bash
   scripts/lv-exec.sh lv-bug-close.sh BUG-NNN PLN-NNN-<slug>
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

   **Then carry out what git will not.** `--force` deletes untracked and
   ignored files with the directory, and some projects keep real deliverables
   out of git on purpose — generated renders, media, anything too large to
   track. A project names those paths under `preserveIgnored:` in
   `levain.yml`; this copies them to the develop root, and is a no-op when
   nothing is named. PLN-027's 24 renders, the whole content of the gallery it
   built, were deleted here at completion (WFI-023, WFI-024).
   ```bash
   scripts/lv-exec.sh lv-worktree-preserve.sh feature-branches/PLN-NNN-<slug>; echo "preserve exit=$?"
   ```
   Exit `0` — go on. Exit `2` — **do not remove the worktree**: the files it
   names exist nowhere else, or a service the operator started from this
   worktree is still running there (it names the service and pid). Report
   them, leave the worktree and branch in place, and finish the rest of the
   exit; the plan is still complete. Never stop the operator's service
   yourself.

   **And check for source files git never saw.** `lv-registry-update.sh`
   refuses `active → verify` while one exists, but a fix cycle or a hand edit
   can add one later. The worktree holds the only copy, and the branch you just
   merged does not build without it (a client's BUG-065):
   ```bash
   scripts/lv-exec.sh lv-ignored-sources.sh PLN-NNN; echo "ignored exit=$?"
   ```
   Exit `1` — **do not remove the worktree or delete the branch.** File the
   paths it lists as a bug, so a clean checkout builds again:
   ```bash
   scripts/lv-exec.sh lv-bug-new.sh "PLN-NNN sources are git-ignored — a clean checkout does not build" \
     --description "<the lines lv-ignored-sources.sh printed>; the copies are in feature-branches/PLN-NNN-<slug>, which was kept"
   ```
   Then finish the rest of the exit, and say in the summary that the worktree
   was kept and why. Exit `0` or `3` — go on.
   ```bash
   git worktree remove feature-branches/PLN-NNN-<slug> --force 2>/dev/null || true
   git branch -d "$CURRENT_BRANCH" 2>/dev/null || true
   ```
7. Clean up test progress and commit REGISTRY/bug changes:

   **Write the summary into `progress.md` before deleting the file it came
   from.** `test-progress.md` is working state and goes; the one-line-per-
   criterion record of what ran, what deferred and why is the plan's evidence
   that it was tested at all, and PLN-191 completed leaving none of it (WFI-229).
   If the file is already gone, the `→ complete` transition took it: it moves
   `test-progress.md` into `progress.md` under `## Test record` whenever it
   completes a plan, so a plan completed any other way does not leave it
   tracked (a client's LVI-043). Write the summary from that section.
   Append a `## Testing — YYYY-MM-DD` section to `plans/PLN-NNN-<slug>/progress.md`
   listing each criterion and its outcome (PASS / FAIL-then-fixed / deferred
   `(external)` / deferred `(soak)`), then:
   ```bash
   rm -f plans/PLN-NNN-<slug>/test-progress.md
   scripts/lv-exec.sh lv-commit.sh "test(PLN-NNN-<slug>): complete — merged to develop" --allow-empty \
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
   reviewed `plan.md` (WFI-122). `lv-commit.sh` builds the commit from the
   pathspec, skips paths that do not exist, and — as of v6.3.1 — refuses
   outright if the checkout has been moved off develop under you.

   No `bugs/` path belongs in this pathspec at all — step 5 already committed
   the rename, both sides. Never `bugs/` wholesale either; that is as wide as
   the index sweep this replaced. `plans/deferred-criteria.md` is gone from it
   for the same reason: `lv-defer-criterion.sh` now commits that file together
   with the `plan.md` checkoff that belongs to it, and this pathspec could only
   ever carry one of the two (WFI-144).
8. Display:
   ```
   Acceptance passed
   PR created: [PR URL]  (or "No PR needed — already on release")
   Feature merged to develop
   Plan moved to complete
   
   Next: Run /lv-release to merge to staging, then /lv-deploy to promote to main.
   ```
   Then run `scripts/lv-exec.sh lv-check-reboot-flag.sh` and append any output to the message above.

### If findings (failures)

1. Write findings to `plans/PLN-NNN-<slug>/findings.md` on develop (from worktree, path is `../../plans/PLN-NNN-<slug>/findings.md`):
   ```markdown
   ## Acceptance — YYYY-MM-DD
   
   - [ ] **Behavior**: Button doesn't respond on mobile
   - [ ] **Design**: Users expect different flow ← ESCALATED
   ```
2. Destroy container (from worktree):
   ```bash
   ../../scripts/lv-exec.sh lv-docker-down.sh $PLAN_NAME
   ```

Steps below run from **project root** — use absolute path `cd /absolute/path/to/project`:

3. Switch to develop:
   ```bash
   cd /absolute/path/to/project
   scripts/lv-exec.sh lv-infra-reset.sh
   scripts/lv-exec.sh lv-stash.sh push checkout
   git checkout develop
   eval "$(scripts/lv-exec.sh lv-stash.sh pop checkout)"
   # Auto-resolve infra conflicts from the restore (infra files always match develop)
   scripts/lv-exec.sh lv-infra-reset.sh
   # Same guard as the all-pass path, and the same scope: this plan's folder
   # only. A `plans/`-wide add here commits other live workers' in-flight files
   # under your message (WFI-109, WFI-110).
   if [ "${LV_RESTORED:-false}" = "true" ]; then
     scripts/lv-exec.sh lv-commit.sh "test(PLN-NNN-<slug>): pending plan changes restored after checkout" \
       --add plans/PLN-NNN-<slug>/
   fi
   ```
4. Determine the route, move the plan out of `testing` **first**, then drop the guards:
   ```bash
   route=$(scripts/lv-exec.sh lv-findings-route.sh plans/PLN-NNN-<slug>)
   ```
   Both routes land on `draft` — `escalated` because the findings need design decisions, `active` because Opus reviews all findings before sending them to the builder. Only the commit message differs.
   - **`escalated`**, message `test(PLN-NNN-<slug>): escalated findings — needs replanning`, display "N escalated findings require design decisions. Run /lv-spec."
   - **`active`**, message `test(PLN-NNN-<slug>): N findings from acceptance — routing to spec`, display "N findings written. Run /lv-spec to review and route to builder."

   ```bash
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN testing draft \
     --commit "<message from above>" \
     --add plans/PLN-NNN-<slug>/findings.md plans/PLN-NNN-<slug>/test-progress.md \
           plans/auto-test-log.md
   scripts/lv-exec.sh lv-gate-close.sh PLN-NNN "acceptance found N issue(s)" --only manual-test
   scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
   ```
   Close the gate on this path too. A findings exit sends the plan to `draft`, and a `manual-test` gate left open there parks it in front of a planner who has nothing to answer.

   **`--only manual-test` is not optional, on either exit path.** The only gate this skill opens is `manual-test`, and without the flag the script closes whatever is open — which on a busy plan is somebody else's question. client-b' PLN-010 had an unattended worker open a `needs-input` gate asking about a test account while an attended `/lv-test` held the claim; the tester's exit closed that gate and recorded "manual test found 1 issue(s)" as the answer to it (WFI-010). With the flag, a different gate open is exit 5 and nothing is touched: go answer it deliberately, then retry. No gate open at all is a silent no-op, as before.

   **The order of these three lines is the contract — see [Order of exit](#order-of-exit).**

### Order of exit

Every exit path from this skill drops the plan's two dispatch guards — its gate and its claim. **The state transition is committed before either of them is released, and the claim is released last.**

```
lv-registry-update.sh …  ← the plan leaves `testing`, committed, in one locked step
lv-gate-close.sh …       ← first guard down
lv-unclaim.sh …          ← last guard down
```

The reverse order is a check-then-act race, and client-a ran it: an attended session closed PLN-006's `manual-test` gate at 15:32:33Z and committed `testing → draft` five seconds later. The daemon swept at 15:32:35Z — inside that window the plan was ungated, unclaimed and still reading `testing` — and spawned an unattended tester onto a plan that was already on its way back to the planner. That worker re-ran the whole e2e scope and opened a *fresh* `manual-test` gate on a plan that had sat in `draft` with five unaddressed findings for four minutes, which then blocked the plan from reaching `/lv-spec` at all (WFI-079).

While the transition is uncommitted it does not exist to any other session; while the gate or claim is up, no worker can be dispatched regardless of what the registry says. Committing first means there is never an instant where the plan is both unguarded and stale.

**One case needs the gate answered before the transition: the human's answer *is* the evidence.** It is rare since the accept split — a human's ruling on a criterion is normally made and recorded in `/lv-accept` (a scope-out ticks the box and files a bug) — but a pre-split plan, or an operator completing one by hand, can still reach it. `testing → complete` refuses while an `eyes:blocking` criterion is unchecked, has no PASS in `test-progress.md`, and its `manual-test` gate is unanswered. When the operator rules the plan complete *over* a FAIL — a spike whose failed criterion is the answer it was run to find — none of the first two can be written honestly; the gate's answer is the only record. Then, and only then, the order is:

```
(claim still held)
lv-gate-close.sh PLN-NNN "<the operator's ruling, in their words>" --only manual-test
lv-registry-update.sh PLN-NNN testing complete …
lv-unclaim.sh PLN-NNN
```

The claim is what makes this safe: the race above needs the plan unguarded, and a held claim is a guard. Do not tick the criterion or write a PASS row to get past the refusal — that records a test result nobody saw — and do not reach for `LV_ALLOW_UNTESTED=1`, which leaves no answer behind at all. Never release the claim between the two steps (WFI-025).

`lv-spawn.sh` re-reads the registry immediately before it launches and stands down on a state it cannot act on, so a worker is not dispatched into a window this small. That is a backstop, not the fix — it narrows the window to milliseconds rather than closing it.

**After the guards are down, push develop.** Neither exit path above does otherwise — both routes commit locally and nothing pushes, and this is an unattended agent with no session boundary to force it. client-c's WFI-012: `origin/develop` sat 38 commits behind local develop across a session's worth of automated verify/test cycles. Best-effort, never a routing failure — the transition above already committed and is the outcome that matters:
```bash
scripts/lv-exec.sh lv-retry.sh --label "push develop" -- git push origin develop \
  || echo "lv-test: push to origin/develop failed after retries — local commits are ahead; push by hand" >&2
```

---

## Container cleanup

Always destroy the container before leaving the worktree — on pass, fail, or early abort. From the worktree:
```bash
../../scripts/lv-exec.sh lv-docker-down.sh $PLAN_NAME
```
If you hit an error and need to stop early, **destroy the container first** before routing back or displaying the error.

**Unless it is not yours.** One exception, and it is the whole reason the claim check in [Unattended mode](#unattended-mode) step 0 exists: a container belongs to the session that started it. If you stood down because another session holds the claim, leave everything running — that app on `localhost:$FEATURE_PORT` is what a human is looking at.

## Bug reference model

**Pre-existing bugs** (in plan Goal): accept BUG-NNN as truth — don't look it up.
**New bugs during testing**: write as findings immediately, file formally with `/lv-bug` after testing.

## Rules

- **Do NOT** use `git add -A` or `git add .` — only stage specific files by name
- **Do NOT** edit source code — only read the plan and write findings
- **Do NOT** ask anyone to judge a criterion — that is `/lv-accept`'s, and it only exists for a plan you moved to `accept`
- **Do NOT** break testing context — write findings immediately, never tell the user to switch branches mid-test
- Severity for acceptance findings is either `Behavior` (code fix) or `ESCALATED` (design) — never Critical. Both route to lv-spec (draft) for Opus review.
- Only one testing worktree at a time

## Notes

| Range | Use |
|-|-|
| 8000-8099 | Static site, staging (8081) |
| 8100+ | Feature branches (8100 + plan ID) |
| 8080 | Default local dev |

Project name: `{{project_slug}}-pln<id>` (e.g., `{{project_slug}}-pln004`)

## When the workflow misbehaves

If the harness does something its own documentation does not describe — a `lv-*` script erroring unexpectedly, an instruction here referencing something that does not exist, the registry contradicting the worktree — record it, then carry on:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-test \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

These are swept into the Levain library and fixed upstream, so one report fixes it for every project. **Not** for application build/test failures or plan findings — those are normal work, not harness faults. Filing never justifies abandoning the run; work around it if you can and say so in `--notes`.

## Usage

```text
/lv-test                   pick a plan in testing (accept:auto) and run its automated acceptance
/lv-test <PLN-ID>          that plan: the suite (detached, or reused from verify's run on the
                           same tree) and headless Playwright on every criterion it can; ships
                           it when nothing is left, else moves it to accept:manual for /lv-accept
```
