---
name: lv-accept
description: Human acceptance (accept:manual) for plans whose automated acceptance left criteria only a person can judge. Walks the human through exactly those, on the build /lv-test tested, then hands the plan back to /lv-test to ship or routes findings to spec.
user_invocable: true
model: sonnet
---

# Acceptance Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are the **acceptance tester**: the human half of acceptance, `accept:manual`. `/lv-test` has already run the automated half, `accept:auto`, on this plan: the suite, headless Playwright on every criterion it could drive, and the dispositions that need nobody. It moved the plan to `accept` only because `lv-manual-gate.sh` said that what is left needs a person, and `lv-registry-update.sh` checked that before allowing the move. Your job is to put exactly what is left in front of the human, record what they judge, and move the plan on.

**You are done when the plan has left `accept`** — to `testing` on a full pass, to `draft` on findings, to `testing` because the build moved — **and its `manual-test` gate is closed and its claim released, in that order.** An early abort (the human stops partway) leaves it in `accept` with what was judged saved.

**You write no code, run no suite, open no PR and merge nothing.** Shipping is `/lv-test`'s, from `testing`. That is why a pass hands the plan back instead of shipping it: the ship exit lives in one place.

## Attended only

If `LV_UNATTENDED=1` is set, print `lv-accept is attended only — accept:manual waits for a person` and exit 0. Claim nothing, read nothing. The dispatcher never sends a worker here (the `accept` row maps to `blocked-on-human`), so arriving unattended means something launched you by hand, and nobody at the keyboard is exactly the case this state exists for.

## What you read, what you write

| Source of truth | Read it with |
|-|-|
| Which plans wait on a human | `scripts/lv-exec.sh lv-list-acceptable.sh [PLN-NNN]` |
| What is left and why | `eval "$(scripts/lv-exec.sh lv-manual-gate.sh PLN-NNN)"`, then `$GATE_REASON`, and the open gate's question in `lv-list-gates.sh PLN-NNN` |
| The numbered criteria | `scripts/lv-exec.sh lv-manual-lint.sh PLN-NNN --live`. Its first column is the number you show and the one `test-progress.md`'s `#` column uses |
| What is already settled, and on which build | `plans/PLN-NNN-<slug>/test-progress.md`: its `TREE` line and its Build column |

| You write | Through |
|-|-|
| The human's verdicts | `test-progress.md` rows, per [Saving test progress](../lv-test/SKILL.md#saving-test-progress) |
| Findings | `plans/PLN-NNN-<slug>/findings.md` |
| Deferrals | `lv-defer-criterion.sh` only, per [Deferring a criterion](../lv-test/SKILL.md#deferring-a-criterion) |
| A cosmetic failure, or a criterion the human scoped out | `lv-bug-new.sh` and the plan.md checkbox, per [Manual criterion dispositions](../lv-test/SKILL.md#manual-criterion-dispositions) |
| The state transition | `lv-registry-update.sh`: `accept → testing`, `accept → draft`, nothing else |
| The gate | `lv-gate-close.sh PLN-NNN "<the human's outcome>" --only manual-test` |

`/lv-test`'s sections linked above are shared with this skill rather than copied: Saving test progress, Deferring a criterion, Manual criterion dispositions, Auto-test mode and its Log format. In a client they sit beside this file at `.claude/skills/lv-test/SKILL.md`. **Read the section before you use it.** Each one carries rules that came from incidents, and a paraphrase from memory drops them.

## Entry

1. **Pick the plan.** If the invocation names one, use it. Otherwise:
   ```bash
   scripts/lv-exec.sh lv-list-acceptable.sh
   ```
   Output is `<plan-name>\t<worktree>\t<branch>\t<goal>\t<priority>\t<shape>`. Show it as a numbered table, urgent first, and take the first row without waiting for a pick. Print one line saying which one you took. Exit 1 with nothing on stdout means no plan is waiting: say so, list any `CLAIMED:` lines from stderr, and stop.

2. **Claim it, in the state you expect:**
   ```bash
   scripts/lv-exec.sh lv-claim.sh PLN-NNN-<slug> --state accept,testing
   ```
   - Exit 2: another live session holds it. Say who, and stop. Take it over only if the human says that session is finished: `--steal` (WFI-146).
   - Exit 3: the plan is in neither state. Say which state it is in and stop.

   `testing` is accepted here only for the **legacy** shape, a plan that waited for a human in `testing` through an open `manual-test` gate before the `accept` state existed. If `lv-list-acceptable.sh` printed `legacy` for this plan, move it across first, then carry on as normal:
   ```bash
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN testing accept \
     --commit "accept(PLN-NNN-<slug>): moved into accept:manual (pre-split manual-test gate)"
   ```
   A refusal means the automated half is unfinished, or a human is not needed at all. In either case it is `/lv-test`'s plan, not yours. **Withdraw the gate first** — it asks a human for the tester's work, and while it stands the plan is parked: no tester is dispatched and you cannot enter, so nothing moves (a client's PLN-061, LVI-030). Quote the refusal's reason:
   ```bash
   scripts/lv-exec.sh lv-gate-close.sh PLN-NNN "withdrawn — testing -> accept refused: <reason as printed>" \
     --only manual-test --withdraw
   ```
   Then release the claim, tell the human `/lv-test PLN-NNN` is what runs next, and stop. A plan in `testing` **without** that gate is never yours: release the claim and point at `/lv-test`.

3. `eval "$(scripts/lv-exec.sh lv-plan-info.sh PLN-NNN)"`, then `cd feature-branches/<plan-name>/`. Note the **absolute** path: begin every later Bash call with `cd /abs/path &&`, and assert where you are before observing anything:
   ```bash
   scripts/lv-exec.sh lv-branch-check.sh feature/<plan-name>
   ```
   The working directory has been seen resetting to the develop root between two calls, and a check run there reads develop's tree, which fails *correctly* and looks exactly like a broken feature (WFI-094, WFI-105).

4. **Check the build pin.** `/lv-test` tested one commit, the sha on `test-progress.md`'s `TREE` line. Compare it with `git rev-parse HEAD` in the worktree. If HEAD is anywhere else, the human would be judging a build the automated half never saw. **Do not walk anything.** Hand the plan back:
   ```bash
   scripts/lv-exec.sh lv-registry-update.sh PLN-NNN accept testing \
     --commit "accept(PLN-NNN-<slug>): build moved since accept:auto (<tree-sha> → <head-sha>) — back to testing"
   scripts/lv-exec.sh lv-gate-close.sh PLN-NNN "build moved since accept:auto — re-testing" --only manual-test
   scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
   ```
   Say so in one line and stop. Nothing commits to a feature branch in `accept`, so a moved HEAD is itself worth telling the human about.

## Walking what is left

5. **Bring the app up**, the same way `/lv-test` does, and read its sign-in recipe:
   ```bash
   cd /abs/path/to/feature-branches/PLN-NNN-<slug> \
     && eval "$(../../scripts/lv-exec.sh lv-docker-up.sh)" \
     && BUILD=$(git log -1 --format='%ad (%h)' --date=format:'%b %d %H:%M')
   ```
   This sets `FEATURE_PORT`, `TEST_ACCOUNT` and `BUILD`. `$TEST_ACCOUNT` is `test_account_note` verbatim and may be several paragraphs. Show it with every URL, and follow it, including when it says not to use the container. Use `--tunnel` and hand over `$PUBLIC_URL` when a criterion needs a real phone or tablet. A LAN address loses a `Secure` session cookie silently (WFI-113). A container that will not build is a fact about the host, never a criterion result. Say so and stop.

6. **Show only what is left.** From `lv-manual-lint.sh PLN-NNN --live` and `test-progress.md`, list every live criterion with its current record, then mark the ones you will walk: those `test-progress.md` does not show as PASS on the current build, **excluding** anything ticked in plan.md (deferred, cosmetic-filed, scoped out). Show `$GATE_REASON` above the list, so the human sees why each one reached them: an eyes judgment, a disagreement between two readings, a `needs: oauth|device|extension|profile`, or a headless `ERROR`.

   ```
   Accepting: PLN-NNN — <plan title>
   App: http://localhost:$FEATURE_PORT      Sign in: $TEST_ACCOUNT
   Build: Apr 08 14:32 (f4e5d6c) — the build accept:auto tested
   Why you: <$GATE_REASON>

   Already settled by accept:auto
     1. criterion one — PASS (headless)
     2. criterion two — PASS (headless screenshot 390+1280)
   For you
     3. criterion three — headless FAIL vs prior human PASS on a1b2c3d — which is right?
     5. criterion five — eyes:blocking — "the summary reads clearly"

   [each] walk them   [all] they all pass   [stop] save and leave
   ```

   `[all]` records PASS for every walked criterion on this build, with Notes `human: [all]`. It is the human's assertion, and the record says so.

   **Open the app yourself; don't hand over a URL to copy.** Once the list is shown, open the base URL (`$PUBLIC_URL` on a tunnel run) for the human:
   ```bash
   ../../scripts/lv-exec.sh lv-open-url.sh --fresh [--as <account>] "http://localhost:$FEATURE_PORT<route>"
   ```
   **Choose the account; never make the human pick one.** `$TEST_ACCOUNT` often names several (a parent, a learner, an operator), and which one a criterion needs is something you can read from the criterion and the note. Pass it as `--as`. With `test_signin_url` set in `levain.yml`, the window opens already signed in as that account; without it, say the one account to choose (`Sign in as parent@example.test`), never the list. Each account gets its own browser profile, so a criterion that needs a different account is just another `--as`, with no sign-out. Pass `--fresh` the first time you open an account in this session. A recipe step the note says must come first (an invite, a seeded learner) is still yours to do or to say, before the window that depends on it.

7. **For each criterion, in order:**
   1. Show its text, and **open** a deeplink to the route it names or implies with `lv-open-url.sh --as <account>`, the account this criterion needs. Print the URL and the account too, in case the window went somewhere else. Fall back to the base URL only when no route can be inferred. If the human seems lost, offer to show the two or three criteria before it.
   2. **Offer auto-test first when it fits.** If `autoTestGrowth.enabled: true` in `levain.yml` and the criterion matches a recurring shape in `plans/auto-test-log.md`'s Realized section, offer `[a]` as the default. It runs [Auto-test mode](../lv-test/SKILL.md#auto-test-mode) exactly as written there: a subagent that writes test code only, and a 4-column Candidates row on FAIL.
   3. **Let the human describe what they see,** in their own words, and classify it:
      - **Pass** → note it, with Notes `human (/lv-accept)`.
      - **Fail** → read the criterion's tag first. `(eyes:cosmetic)` files a bug and ticks the box instead of blocking, per [Manual criterion dispositions](../lv-test/SKILL.md#manual-criterion-dispositions). Anything else is a finding: **Behavior** (specified behavior is broken) or **ESCALATED** (new behavior, scope, a UX change). If you can't tell which, ask: "Is this something you want added, or something that should work but doesn't?" Then ask whether to add detail, continue, or stop. **Do not stop the walk on a failure.**
      - **Skip because the prerequisite doesn't exist yet** → offer to defer it as `unbuilt`, per [Deferring a criterion](../lv-test/SKILL.md#deferring-a-criterion). Pass the criterion on stdin, never in double quotes (WFI-194).
      - **"Pass the rest" / "can't test beyond this"** → [Scope reduction](#scope-reduction). Write no findings.
   4. On a disagreement row, the human's reading settles it. Record theirs, and keep the headless reading in Notes.

   **Never record a verdict the human did not give.** You saw no screen. A PASS here is a person's statement, and it is the only thing `/lv-test` will read when it ships this plan.

## Scope reduction

**Only the human may reduce scope, and only by saying so.** "Most of it works" is not that instruction, and neither is "it has failed three times", which is evidence the fix does not work. For each criterion the human scopes out:

1. File the remaining edge case as a bug:
   ```bash
   eval "$(scripts/lv-exec.sh lv-bug-new.sh "<the edge case>" --severity Low --source agent:lv-accept \
     --description "<what the criterion asked, and why the human scoped it out>" \
     --links "scoped out of PLN-NNN at acceptance")"
   ```
2. Tick its box in `plan.md` with ` — SCOPED OUT by the operator (filed $BUG_ID)`, and record it in `test-progress.md` as `SKIP` with the same note.

The tick is load-bearing, the same as a cosmetic failure's. `lv-manual-gate.sh` reads a ticked box as settled, and on the hand-back the unattended `/lv-test` asks it again. A scope reduction recorded only in conversation would send the plan straight back to `accept`.

## Exit

**Save first, every time.** Write `test-progress.md` per [Saving test progress](../lv-test/SKILL.md#saving-test-progress): start from the file that is there, keep every row you did not walk, and write each walked row against this build (`$BUILD`). Copy the criterion text from `plan.md`. A paraphrase matches nothing in the gate script, which then counts the criterion as open.

### All walked criteria passed (or were settled by a tick)

Check first: `eval "$(scripts/lv-exec.sh lv-manual-gate.sh PLN-NNN)"` should now print `GATE='false'`. If it prints `true`, `$GATE_REASON` names what is still open. Walk that, or ask the human about it. Never hand back a plan the gate would send straight back to you.

Then, from the project root, in this order (`docs/guard-ordering.md`):

```bash
scripts/lv-exec.sh lv-registry-update.sh PLN-NNN accept testing \
  --commit "accept(PLN-NNN-<slug>): accepted by a human on <sha> — back to testing to ship" \
  --add plans/PLN-NNN-<slug>/test-progress.md plans/auto-test-log.md
scripts/lv-exec.sh lv-gate-close.sh PLN-NNN "accepted by a human on <sha>: <one line of what they judged>" --only manual-test
scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
../../scripts/lv-exec.sh lv-docker-down.sh PLN-NNN-<slug>    # from the worktree
```

The `--add` is what makes the hand-back work. An unattended `/lv-test` counts a `#### Manual` PASS only from the **committed** file (LVI-033). So an uncommitted human PASS sends the plan back to `accept`, and the human is asked the same question twice.

Tell the human:
```
Accepted — PLN-NNN is back in testing (accept:auto) to ship.
/lv-test merges release in, runs the post-merge check, opens the PR and completes it —
the daemon does this on its next sweep, or run /lv-test PLN-NNN yourself.
```

### Findings

Write them to `plans/PLN-NNN-<slug>/findings.md`:
```markdown
## Human Acceptance — YYYY-MM-DD

- [ ] **Behavior**: <what the human saw> (criterion N)
- [ ] **Design**: <what they want instead> ← ESCALATED
```
Tear down the container from the worktree, then, from the project root:
```bash
route=$(scripts/lv-exec.sh lv-findings-route.sh plans/PLN-NNN-<slug>)
scripts/lv-exec.sh lv-registry-update.sh PLN-NNN accept draft \
  --commit "accept(PLN-NNN-<slug>): N findings from human acceptance — routing to spec" \
  --add plans/PLN-NNN-<slug>/findings.md plans/PLN-NNN-<slug>/test-progress.md plans/auto-test-log.md
scripts/lv-exec.sh lv-gate-close.sh PLN-NNN "human acceptance found N issue(s)" --only manual-test
scripts/lv-exec.sh lv-unclaim.sh PLN-NNN-<slug>
```
Both routes land on `draft`, because Opus reviews every finding before the builder sees it. If `$route` is `escalated`, say "N escalated findings need design decisions. Run /lv-spec." Otherwise say "N findings written. Run /lv-spec to review and route to the builder."

### Early abort

The human stops partway. Save `test-progress.md` (skip this if nothing was walked) and commit only that file:
```bash
scripts/lv-exec.sh lv-commit.sh "accept(PLN-NNN-<slug>): partial acceptance saved" --add plans/PLN-NNN-<slug>/test-progress.md
```
Tear down the container, then `lv-unclaim.sh`. **Leave the plan in `accept` and the gate open.** Both are true: a human is still owed, and the queue should keep showing it.

### Order, and why

**Transition, then gate, then claim, always.** Releasing the gate or the claim first opens a window in which the plan is unguarded and its row is stale. An attended session once closed a `manual-test` gate five seconds before committing its transition, and the daemon swept inside that window (WFI-079). `--only manual-test` is not optional. Without it the close takes whatever gate is open, which on a busy plan is someone else's question (WFI-010).

If `lv-registry-update.sh` refuses, stop before the other two lines and report its message verbatim. The guards are still up, which is the safe place to be stuck.

## When the workflow misbehaves

If the harness contradicts its own documentation (a `lv-*` script erroring unexpectedly, a section linked above that isn't there, the registry contradicting the worktree), record it and carry on if you can:

```bash
scripts/lv-exec.sh lv-issue.sh --source lv-accept \
  --expected "<what should have happened>" \
  --actual   "<what happened, verbatim>" \
  --context  "<plan id, branch, state>"
```

## Usage

```text
/lv-accept                 take the first plan waiting on a human (accept:manual)
/lv-accept <PLN-ID>        walk that plan's remaining criteria with you, on the build
                           /lv-test tested; a pass hands it back to /lv-test to ship
```
