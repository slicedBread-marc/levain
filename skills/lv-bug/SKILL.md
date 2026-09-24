---
name: lv-bug
description: File a new bug report. Creates a bug folder in bugs/open/ with a structured report and optional file attachment. Use when the user wants to report a bug, quick-fire a known issue, or import a flag from the live product.
user_invocable: true
model: sonnet
---

# Bug Filer Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are in **bug filing mode**. Your job is to capture a bug clearly and completely so it can be triaged, planned, and fixed.

## Two modes

### Quick-fire mode
If the user provides a one-liner or brief description, extract what you can and fill in the rest as `TBD`. Create the bug immediately — don't interrogate them for every field.

### Structured mode
If the user says "new bug" or provides no description, prompt for:
1. **Title** — short, specific (e.g. "Login crashes on empty password")
2. **Project** — which repo or app
3. **Severity** — Critical / High / Medium / Low
4. **Description** — what's broken and the impact
5. **Steps to reproduce** — numbered list
6. **Expected vs actual** — what should happen, what does happen
7. **Links** (optional) — if related to another bug or plan (e.g. "caused by BUG-003", "discovered during debug of BUG-002", "regression from PLN-005")
8. **Attachment** — ask if there's a file to attach (screenshot, log, export)

## Folder structure

```
bugs/open/    → new bugs land here (you create here)
bugs/triaged/ → picked up by /lv-spec when a fix plan is created
bugs/closed/  → resolved by /lv-deploy when a plan completes
```

## What you do

1. **Check branch** — save current branch and switch to develop if needed:
   ```bash
   eval "$(scripts/lv-exec.sh lv-branch-check.sh develop true)"
   ```
   This sets CURRENT_BRANCH (original) and SWITCHED_FROM (if it switched).
2. **File it — one call.** This allocates the ID through the counter, writes `bug.md` in the shape the rest of the pipeline parses, and commits it:
   ```bash
   eval "$(scripts/lv-exec.sh lv-bug-new.sh "<title>" \
     --severity Critical|High|Medium|Low \
     --project "<repo or app>" \
     --description "<what's broken and the impact>" \
     --steps "<numbered list, or TBD>" \
     --expected "<what should happen>" \
     --actual "<what does happen>" \
     --links "<optional: caused by BUG-NNN, regression from PLN-NNN…>")"
   ```
   It sets `$BUG_ID` and `$BUG_DIR`. Omitted fields land as `TBD`, which is the right value for something the user did not say — never invent them. The slug comes from the title unless you pass `--slug`.

   **Do not hand-write the folder instead.** The counter is the only allocator, and it is only actually the only allocator if using it is easier than not: client-a filed two bugs by hand and pushed its counter into drift (WFI-133).
3. **Handle attachments** — if the user provides a file path:
   - Copy it into `$BUG_DIR` and append an `## Attachments` section to `$BUG_DIR/bug.md` referencing it relatively: `[filename.ext](./filename.ext)`
   - If the user describes a file they'll add later, add the placeholder `- [ ] Attach: <description>`
   - Then commit the addition: `scripts/lv-exec.sh lv-commit.sh "bug($BUG_ID): attach <filename>" --add "$BUG_DIR"`
4. **Push**:
   ```bash
   git push origin develop
   ```
5. **Restore branch** — if you switched branches in step 1, switch back:
   ```bash
   [ -n "${SWITCHED_FROM:-}" ] && git checkout "$SWITCHED_FROM"
   ```
6. **Confirm** — show the user the bug ID, folder path, and commit hash

## Filing against a dependency, not this project

Sometimes what you're hearing about is not a bug in *this* project — it's a defect or missing
capability in something this project depends on. The standing example: client-e integrating
client-c's OIDC hits a 401 on token refresh. That's client-c's bug, not client-e's,
even though client-e is where it was noticed.

**Recognize it first.** Ask whose code would actually change to fix this. If the answer is a
different repo, this is a dependency report — filing it here means nobody on the other side
ever sees it.

Check this project's `levain.yml` for a `dependencies:` block:
```yaml
dependencies:
  - "client-c:/path/to/client-c"
```
If the project the bug belongs to is listed there, file through the dependency instead of step 2:
```bash
eval "$(scripts/lv-exec.sh lv-dep-bug.sh --host client-c "<title>" \
  --kind bug|request \
  --severity Critical|High|Medium|Low \
  --description "<what's broken and the impact, written for the HOST's reader>" \
  --steps "<numbered list, or TBD>" \
  --expected "<what should happen>" \
  --actual "<what does happen>" \
  --notes "<how this project hit it — a plan ID, a page, a call it made>" \
  [--links "<ticket, decision record, related artifact over there>"] \
  [--amends <BUG-id>])"
```
`--amends <BUG-id>` is for a report that **corrects one already filed in that host** — a common
case, since a correction usually arrives before the host has triaged the original. It links both
sides through the host's own scripts (`Amends <ID>` on the new one, `Amended by <new ID>` on the
named one) rather than hand-editing `Links:` in another project's `bugs/open/`, which is the one
thing a cross-project filer must never do (coordinator WFI-001).
This `cd`s into the dependency's own checkout and runs **its own** `lv-bug-new.sh` through **its
own** `lv-exec.sh` — the bug is allocated through that project's counter and lands in that
project's `bugs/open/`, exactly where its own `/lv-spec` already looks. There is no second inbox
for anyone to learn. It sets `$DEP_BUG_ID`, `$DEP_BUG_HOST`, `$DEP_BUG_PATH`, `$DEP_BUG_DIR`.

It refuses (exit 2) rather than disturb a checkout a human on the other project has parked
somewhere of their own. When that happens nothing is written — say so and stop, don't retry.

**It commits in the host but does not push.** Tell the user a bug was filed in `<host>` at
`$DEP_BUG_PATH/$DEP_BUG_DIR`, and that project's `develop` still needs a `git push` from over
there — that push is that project's call, not something to do from here.

**FILING IS THE LAST ACT, whether it went through `lv-dep-bug.sh` or you `cd`'d into the
dependency by hand.** A session rooted in this project has no standing role in the host's own
pipeline — that project's `/lv-spec` is what turns its bug into a plan, its own `/lv-implement`
builds it, its own registry tracks it. Do not follow the filed bug with a claim, a hand-authored
`plan.md`/`findings.md`/`progress.md`, a `lv-registry-add.sh`, or a review agent run against the
host's checkout — every one of those is that project's own workflow loop, dispatched from a
session actually rooted there (or its own orchestrator), not from here. client-e's WFI-025 did
exactly this against client-c — filed the bug correctly, then kept going and had to revert
three commits' worth of hand-run spec work. The Skill tool cannot even see the host's `lv-spec`
from a session rooted elsewhere, which is likely *why* it happened by hand instead of being
refused outright — there is no tool-level guardrail past the filing call, only this one.

**If the dependency isn't listed**, or its local path doesn't exist, fall back to filing it in
*this* project's own `bugs/open/` (step 2), with `--links` naming the real dependency and
`--notes` explaining it belongs elsewhere, then tell the user to add a `dependencies:` entry so
next time it can go straight there. Never invent a path or file it silently in the wrong place.

See `docs/cross-project-reports.md` for the full convention — the dependency's own skills use
the identical mechanism in reverse, so both sides behave the same way.

**This is the inbound direction only** — this project reporting *into* a dependency. The
outbound direction — this project announcing a change *to* the projects that depend on it — is
`/lv-dep-notify` (`lv-dep-notify.sh`), not this skill. Reach for that when the code you just
changed here is what broke, or will break, someone else's integration.

## Closing a bug that duplicates something already filed

A duplicate has no fixing plan and is never triaged, so the normal close path — `/lv-deploy` closing a bug when its plan completes — never reaches it. Close it here, with the script, from `bugs/open/`:

```bash
scripts/lv-exec.sh lv-bug-close.sh BUG-NNN --duplicate-of <BRF-NNN|BUG-NNN|PLN-NNN> [--note "<...>"]
```

It writes `Status: Closed`, the date, and `Closed as duplicate of: <ID> — closed by decision, not fixed` into `bug.md`, then commits the move naming **both** sides of the rename.

**A bug that became a brief is superseded, not duplicated.** When triage reads a bug and folds
what it asked for into a new artifact, the new one did not exist first — the bug is its source:

```bash
scripts/lv-exec.sh lv-bug-close.sh BUG-NNN --superseded-by <BRF-NNN|BUG-NNN|PLN-NNN> [--note "<...>"]
```

`--duplicate-of` in that case records the relation backwards, in `bug.md` and in the commit
subject both — client-b closed BUG-007 as "duplicate of BRF-010" when BRF-010 was derived from
it and says so in its own text (WFI-008). Every reason takes `--note`; a close is a record. Do not do this by hand: a rename is two paths, only the caller's pathspec decides which of them land, and a hand-close that names one leaves the bug tracked at `open/` **and** `closed/` in the same HEAD (WFI-136, WFI-139). Confirm with the user before closing — deciding two artifacts are the same issue is their call, not yours.

**One narrow exception auto-closes without asking**, during `lv-spec`'s bug-triage step only: a bug `lv-verify` filed automatically, naming a concrete identifier already fixed by a plan at `verify` or later. See `skills/lv-spec/SKILL.md` § "Plan from bug", step 2. Everywhere else — including this section in general — the confirm-first rule above stands.

## Closing a bug that was fixed without a plan

Not every fix is worth a plan. A one-commit fix on develop — a typo, a wrong flag, a dozen lines in a script — has no plan to complete, so `/lv-deploy`'s close-by-plan path never reaches it and the bug stays `Open` forever while the code is fixed. client-a's BUG-076 sat exactly there: fixed in `b5fc375`, closeable only by inventing a plan ID that does not exist (WFI-149).

Close it against the commit instead:

```bash
scripts/lv-exec.sh lv-bug-close.sh BUG-NNN --fixed-in <sha> [--note "<what and why>"]
```

The commit is the evidence in place of the plan. The script resolves the sha and writes `Fixed directly in: <short-sha> <subject> — no plan` into `bug.md`, then commits the move naming both sides of the rename. A sha this repo cannot resolve is still recorded, with a warning that it was not verified.

**Ask before using this.** "This did not need a plan" is a judgement about scope, and it is the user's to make: if the fix wants acceptance criteria, a test, or a verify pass, it wants a plan. Never pass a plan name that does not exist to fake a close.

## Closing a bug that will not be fixed

A bug the user decides against — won't fix, or defer indefinitely — is decided and stuck in exactly the way the previous section describes, with none of the fixing reasons true. Do not reach for `--duplicate-of` to get at its "closed by decision, not fixed" wording; that writes a duplicate into the record that does not exist (WFI-195).

```bash
scripts/lv-exec.sh lv-bug-close.sh BUG-NNN --wont-fix --note "<why not>"
```

It writes `Closed as won't-fix: <reason> — closed by decision, not fixed` and commits both sides of the rename. **Give the `--note`**: the reason is the entire record of the decision, and a won't-fix without one is a bug that gets re-filed by the next person who hits it.

**Only on the user's word.** This is theirs to decide — a needs-input gate answered "won't fix", or a direct instruction. Never conclude it yourself from a bug being hard, old, or unreproducible.

## bug.md format

This is what `lv-bug-new.sh` writes. You do not write it by hand — it is here so
you know what the fields mean and what a later edit must preserve.

```markdown
# [Bug Title]

> **Status:** Open
> **ID:** BUG-NNN
> **Kind:** Bug | Request | Notice
> **Filed:** YYYY-MM-DD
> **Project:** [project]
> **Severity:** Critical | High | Medium | Low
> **Source:** human | cross-project:<reporting-project-slug>
> **Plan:** _(none — link added by /lv-spec when a fix plan is created)_
> **Links:** _(optional: caused by BUG-NNN, blocks BUG-NNN, regression from PLN-NNN, discovered during debug of BUG-NNN, etc.)_

## Description
...

## Steps to Reproduce
1. 
2. 

## Expected
...

## Actual
...

## Attachments
_(remove this section if no attachments)_
- [filename.ext](./filename.ext) — description

## Notes
_(context, workarounds, related information)_
```

## Attachment handling

When an attachment is provided:
- Place it in the bug folder alongside `bug.md`
- Reference it with a relative path: `[filename.ext](./filename.ext)`
- If it's a path outside the repo, note the full path as a non-relative reference with a warning that it may not be portable

## Rules

- Never invent reproduction steps — leave as `TBD` if unknown
- Severity is the user's call; suggest based on description but don't override
- Keep descriptions factual, not prescriptive (describe the problem, not the fix)
- One bug per folder — do not combine multiple issues

## Notes

- **Branch-aware:** You can run `/lv-bug` from any branch (develop, feature/*, release, main). It will:
  - Save your current branch
  - Switch to develop
  - Create the bug
  - Commit and push
  - Switch back to your original branch
  - This makes it safe to file bugs discovered during feature testing without affecting your worktree
- Bugs are committed immediately upon creation — no manual commit step needed
- Bugs are always created on develop (the planning branch)
- Attachments are co-located with `bug.md` in the bug folder
- The bug can be moved to `triaged/` by `/lv-spec` when a fix plan is created
- The bug moves to `closed/` by `/lv-deploy` when the fix plan completes
- A bug or request that actually belongs to a project this one depends on goes through `lv-dep-bug.sh` into that project's own `bugs/open/` — see [Filing against a dependency, not this project](#filing-against-a-dependency-not-this-project). It never gets filed here on that project's behalf.

## Usage

```text
/lv-bug                 file a bug, asked field by field
/lv-bug <description>   file it now from a one-liner; unknown fields become TBD
```
