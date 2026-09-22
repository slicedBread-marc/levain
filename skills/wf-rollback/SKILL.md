---
name: wf-rollback
description: Execute a rollback for a completed or active plan. Reads the plan's rollback section, walks through steps interactively, records the rollback in REGISTRY.md, and optionally files a bug. Use when a deployed feature needs to be reverted.
user_invocable: true
model: haiku
---

# Rollback Role

You are in **rollback mode**. A feature needs to be reverted. Your job is to guide the user through the rollback steps defined in the plan, confirm each step, and record the outcome.

## State context

```
plans/REGISTRY.md    → single source of truth for plan state
plans/PLN-NNN-*/     → immovable plan folders (never move)
```

Rollback candidates are plans in `complete` or `active` state in REGISTRY.md.

## IMMEDIATE STARTUP — run these two commands in parallel before reading further

```bash
scripts/wf-exec.sh wf-list-rollbacks.sh 2>/dev/null || true
```
```bash
grep -E "\| (complete|active) \|" plans/REGISTRY.md
```

Show rollback candidates as a numbered table. Then tell the user: "Run `/model sonnet`, then pick a plan to roll back."

---

## What you do

### 1. Identify the plan

The user has already selected a plan. Run `eval "$(scripts/wf-exec.sh wf-plan-info.sh PLN-NNN)"` to get its details.

### 2. Read the rollback section

Read `## Rollback` from `plan.md`. Present the following to the user before proceeding:

```
Feature:    [plan name]
Status:     [plan status]

--- Rollback Assessment ---
Trigger conditions:   [list]
Data migrations:      Reversible | Irreversible | N/A
Breaking changes:     Yes / No
Downstream impact:    [description]

--- Steps ---
1. [step]
2. [step]
...
```

**If data migrations are Irreversible:** stop and warn the user explicitly before proceeding:
> "⚠️ This plan has irreversible data migrations. Rolling back the code will NOT revert the data. Confirm you understand and want to proceed."

Wait for explicit confirmation before continuing.

### 3. Execute steps interactively

Walk through each rollback step one at a time:
- Present the step
- Ask the user to execute it (you cannot run deployment commands or push to remotes directly)
- Wait for confirmation that it's done before moving to the next step
- If a step fails or the user encounters an issue, stop and help diagnose before continuing

### 4. Verify the rollback

Once all steps are complete, work through the rollback verification checklist from `plan.md`:
- For each verification check, ask the user to confirm or observe the result
- If any check fails, note it and ask how the user wants to proceed

### 5. Record the rollback

Update `plan.md`:
- Set `Status` to `Rolled Back`
- Append to `## Amendments`:
  ```
  [date] — Rolled back. Reason: [user-provided reason]. Data migrations: [Reversible/Irreversible/N/A]. Verification: [passed/partial — notes].
  ```

Update REGISTRY.md — change the plan's state to `rolled-back` and commit:
```bash
scripts/wf-exec.sh wf-registry-update.sh PLN-NNN <current-state> rolled-back -
scripts/wf-exec.sh wf-commit.sh "rollback(PLN-NNN-<slug>): <reason>" \
  --add plans/PLN-NNN-<slug>/plan.md --branch develop
```

The plan folder stays in place — only the REGISTRY state changes.

### 6. File a bug (optional)

Ask the user:
> "Do you want to file a bug for the issue that triggered this rollback?"

If yes, guide them through the `/wf-bug` filing process with the rollback context pre-filled:
- Title: "Rollback: [feature name] — [brief reason]"
- Severity: based on user input
- Description: what went wrong that triggered the rollback
- Notes: link to the rolled-back plan folder

### 7. Recommend next action

After the rollback is recorded:
- If a bug was filed: "Run `/wf-spec` when ready to plan a fix — link it to [BUG-NNN]"
- If no bug was filed: "Run `/wf-status` to see the current pipeline state"

## Rules

- **Do NOT** execute deployment commands, git pushes, or database migrations yourself — guide the user to run them
- **Do NOT** skip the safety assessment for irreversible migrations — always surface this explicitly
- **Do NOT** move the plan folder. Ever. Plans are immovable (`CLAUDE.md` Design Principle 1): `plans/PLN-NNN-<slug>/` is the plan's address forever, and every script that resolves a plan builds that path literally — `wf-list-rollbacks.sh` among them. A `git mv` here permanently breaks path resolution for that plan and leaves an orphaned registry row that `wf-registry-audit.sh` reports at the top of every `/wf-status` thereafter. Rolling back changes the **state**, not the location
- Steps must be walked through in order — do not skip ahead
- If the user aborts mid-rollback, note the partial state in `plan.md` Amendments before exiting

## Partial rollback

If the user stops partway through:
1. Note which steps were completed in `plan.md` Amendments: `[date] — Partial rollback. Completed steps 1-N. Stopped at step N+1 due to: [reason].`
2. Do NOT update REGISTRY state — plan stays in its current state
3. Add `Rollback Partial` note to plan.md Amendments
4. Commit the partial state:
   ```
   scripts/wf-exec.sh wf-commit.sh "rollback: PLN-NNN-<slug> — partial, stopped at step N" \
     --add plans/PLN-NNN-<slug>/plan.md --branch develop
   ```
5. Recommend filing a bug and getting help before continuing

## Rolling back

When a plan is rolled back:
1. Assign it a `RBK-NNN` ID (next available — scan REGISTRY.md for existing rolled-back plans)
2. Optionally record the rollback in the plan's Amendments with a note like:
   ```
   [date] — Rolled back as RBK-001. Reason: [reason]. Verified: [passed/partial — notes].
   ```

## Committing work

The commit is done during step 5 (Record the rollback), after the registry row is
updated. **There is no `git mv`** — see the Rules above. The plan folder stays exactly
where it has always been; only the REGISTRY state and the plan's `## Amendments` change.
