---
name: wf-bug
description: File a new bug report. Creates a bug folder in bugs/open/ with a structured report and optional file attachment. Use when the user wants to report a bug, quick-fire a known issue, or import a flag from the live product.
user_invocable: true
model: sonnet
---

# Bug Filer Role

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
bugs/triaged/ → picked up by /wf-spec when a fix plan is created
bugs/closed/  → resolved by /wf-deploy when a plan completes
```

## What you do

1. **Check branch** — save current branch and switch to develop if needed:
   ```bash
   eval "$(scripts/wf-exec.sh wf-branch-check.sh develop true)"
   ```
   This sets CURRENT_BRANCH (original) and SWITCHED_FROM (if it switched).
2. **File it — one call.** This allocates the ID through the counter, writes `bug.md` in the shape the rest of the pipeline parses, and commits it:
   ```bash
   eval "$(scripts/wf-exec.sh wf-bug-new.sh "<title>" \
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
   - Then commit the addition: `scripts/wf-exec.sh wf-commit.sh "bug($BUG_ID): attach <filename>" --add "$BUG_DIR"`
4. **Push**:
   ```bash
   git push origin develop
   ```
5. **Restore branch** — if you switched branches in step 1, switch back:
   ```bash
   [ -n "${SWITCHED_FROM:-}" ] && git checkout "$SWITCHED_FROM"
   ```
6. **Confirm** — show the user the bug ID, folder path, and commit hash

## bug.md format

This is what `wf-bug-new.sh` writes. You do not write it by hand — it is here so
you know what the fields mean and what a later edit must preserve.

```markdown
# [Bug Title]

> **Status:** Open
> **ID:** BUG-NNN
> **Filed:** YYYY-MM-DD
> **Project:** [project]
> **Severity:** Critical | High | Medium | Low
> **Source:** human
> **Plan:** _(none — link added by /wf-spec when a fix plan is created)_
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

- **Branch-aware:** You can run `/wf-bug` from any branch (develop, feature/*, release, main). It will:
  - Save your current branch
  - Switch to develop
  - Create the bug
  - Commit and push
  - Switch back to your original branch
  - This makes it safe to file bugs discovered during feature testing without affecting your worktree
- Bugs are committed immediately upon creation — no manual commit step needed
- Bugs are always created on develop (the planning branch)
- Attachments are co-located with `bug.md` in the bug folder
- The bug can be moved to `triaged/` by `/wf-spec` when a fix plan is created
- The bug moves to `closed/` by `/wf-deploy` when the fix plan completes
