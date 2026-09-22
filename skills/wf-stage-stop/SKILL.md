---
name: wf-stage-stop
description: Stop the running staging environment and cancel its auto-stop timer. Reports truthfully whether anything was running.
user_invocable: true
model: haiku
---

# Stage Stop Skill

You are in **stage-stop mode**. Your job is to tear down the staging stack and cancel its auto-stop watchdog. You do not edit source code, change REGISTRY state, claim anything, or touch any container that is not this project's staging stack.

## Operating mode

Either. Nothing below asks a question.

## What you do

1. **Stop it:**
   ```bash
   eval "$(scripts/wf-exec.sh wf-stage-stop.sh)"
   ```
   Sets `STAGE_PROJECT` and `STAGE_WAS_RUNNING`.

2. **Report what actually happened** — the two cases read differently, and saying the wrong one is the defect this skill was rewritten to fix:
   - `STAGE_WAS_RUNNING=true` → `✓ Staging stopped (<STAGE_PROJECT>). Volumes removed.`
   - `STAGE_WAS_RUNNING=false` → `Nothing was running (<STAGE_PROJECT>). Any auto-stop timer is cancelled.`

   The old version printed `✓ Staging container stopped` unconditionally, after a `down -v` that exits 0 on an empty project. A tester who had torn down a live environment and one who had typed this into a repo where nothing ever ran got the same sentence.

## Exit codes

| Exit | Situation | Mode | Behavior |
|-|-|-|-|
| 0 | Stopped, or nothing was running | [AUTO] | Report the matching line above. Both are success — the requested end state is "not running" |
| 1 | `docker compose down` failed | [AUTO] | The stack may still be up. Show the output and the `ps` line the script printed. Do not report a stop that did not happen |
| 3 | No compose file | [AUTO] | Nothing here to stop. Report the path tried and name `staging.composeFile` |

**Never guess.** Anything else: report it to the user and stop. There is no state to park and nothing to unclaim.

## Volumes

`down -v` removes the stack's volumes. That is correct for staging, which is disposable and rebuilt from `release` on every start — but say "volumes removed" when reporting, because the same words about any other stack would mean data loss.

## Done

You are finished when the user has been told which of the two cases happened, or why neither could be established.
