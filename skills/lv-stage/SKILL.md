---
name: lv-stage
description: Start the release-branch staging environment and report its URL and auto-stop deadline. Returns immediately; the timer runs detached.
user_invocable: true
model: haiku
---

# Stage Skill

You are in **stage mode**. Your job is to bring the release branch up in a local staging container, report where it is and when it stops, and return. You do not edit source code, you do not change REGISTRY state, you do not claim anything, and you do not wait for the environment to expire.

## Operating mode

Either. A human usually runs this before `/lv-release` validation; the orchestrator may run it unattended. Nothing below differs between the two, because nothing below asks a question.

## What you do

1. **Start it** — one call, which returns as soon as the container is healthy:
   ```bash
   eval "$(scripts/lv-exec.sh lv-stage-start.sh)"
   ```
   This sets `STAGE_URL`, `STAGE_PORT`, `STAGE_PROJECT`, `STAGE_TREE`, `STAGE_DEADLINE`, `STAGE_ALREADY`. Read the values out of the output — a later Bash call is a fresh shell and will not have them.

2. **Report to the user**, always including the deadline and which tree was staged:
   ```
   ✓ Staging <STAGE_TREE> at <STAGE_URL>
     Auto-stops at <STAGE_DEADLINE>. Stop early with /lv-stage-stop.
   ```

That is the whole job. **The auto-stop is detached — do not sleep, wait, poll, or background a wait for it.** The script returns and so do you; the container's teardown is not your work and nothing is left running on your side. An agent that sits in a 60-minute wait produces no output and gets killed with the wait unfinished (WFI-012's shape, one hour wide) — which is exactly what the previous version of this skill described when it said "when 60 minutes elapse, the container auto-stops".

## Exit codes

| Exit | Situation | Mode | Behavior |
|-|-|-|-|
| 0, `STAGE_ALREADY=false` | Up and healthy | [AUTO] | Report as above |
| 0, `STAGE_ALREADY=true` | A stack was already up | [AUTO] | Report it, say the deadline is **unchanged**, and offer `/lv-stage-stop` then `/lv-stage` for a fresh build. Do not restart it — somebody may be testing against it |
| 1 | `docker compose up` failed | [AUTO] | Nothing is staged. Show compose's output verbatim and stop. Do not retry |
| 2 | Started, health probe silent | [AUTO] | The stack **is** running and still auto-stops. Report the URL, say health did not answer, and show the `logs --tail 50` line the script printed. Not a pass — say so plainly |
| 3 | No compose file | [AUTO] | This project has no staging stack, or it lives elsewhere. Report the path tried and name `staging.composeFile` |

**Never guess.** Anything not in that table is a [GATE]:
```bash
scripts/lv-exec.sh lv-gate-open.sh <PLN-ID> needs-input "<question>" --skill lv-stage
```
If no plan is in play, there is nothing to gate — report the situation to the user and stop.

## Configuration

All optional, in `claude-workflow.yml`, all with working defaults: `staging.port` (8081), `staging.minutes` (60), `staging.composeFile` (`docker/docker-compose.yml`), `staging.healthPath` (`/health`). The compose project name is `<project_slug>-staging`, which is what keeps nine clients' staging stacks off each other on one Docker daemon.

## Done

You are finished when the user has been told the URL **and** the deadline, or told why there is neither. Nothing is claimed, nothing is committed, and nothing is still running on your side.
