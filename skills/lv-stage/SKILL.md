---
name: lv-stage
description: Start or stop the release-branch staging environment. `start` (the default) reports its URL and auto-stop deadline and returns immediately; `stop` tears it down and cancels the timer, saying truthfully whether anything was running.
user_invocable: true
model: haiku
---

# Stage Skill

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are in **stage mode**. Your job is to bring the release branch up in a local staging container, or take it down, report exactly what happened, and return. You do not edit source code, you do not change REGISTRY state, you do not claim anything, you do not touch any container that is not this project's staging stack, and you do not wait for the environment to expire.

## Arguments

| Call | Does |
|-|-|
| `/lv-stage` or `/lv-stage start` | Start staging (below: **Start**) |
| `/lv-stage stop` | Stop it and cancel the auto-stop (below: **Stop**) |

`/lv-stage-stop` is the old name for `stop` and still works.

## Operating mode

Either. A human usually runs this before `/lv-release` validation; the orchestrator may run it unattended. Nothing below differs between the two, because nothing below asks a question.

## Start

1. **Start it** — one call, which returns as soon as the container is healthy:
   ```bash
   eval "$(scripts/lv-exec.sh lv-stage-start.sh)"
   ```
   This sets `STAGE_URL`, `STAGE_PORT`, `STAGE_PROJECT`, `STAGE_TREE`, `STAGE_DEADLINE`, `STAGE_ALREADY`. Read the values out of the output — a later Bash call is a fresh shell and will not have them.

2. **Report to the user**, always including the deadline and which tree was staged:
   ```
   ✓ Staging <STAGE_TREE> at <STAGE_URL>
     Auto-stops at <STAGE_DEADLINE>. Stop early with /lv-stage stop.
   ```

That is the whole job. **The auto-stop is detached — do not sleep, wait, poll, or background a wait for it.** The script returns and so do you; the container's teardown is not your work and nothing is left running on your side. An agent that sits in a 60-minute wait produces no output and gets killed with the wait unfinished.

| Exit | Situation | Mode | Behavior |
|-|-|-|-|
| 0, `STAGE_ALREADY=false` | Up and healthy | [AUTO] | Report as above |
| 0, `STAGE_ALREADY=true` | A stack was already up | [AUTO] | Report it, say the deadline is **unchanged**, and offer `/lv-stage stop` then `/lv-stage` for a fresh build. Do not restart it — somebody may be testing against it |
| 1 | `docker compose up` failed | [AUTO] | Nothing is staged. Show compose's output verbatim and stop. Do not retry |
| 2 | Started, health probe silent | [AUTO] | The stack **is** running and still auto-stops. Report the URL, say health did not answer, and show the `logs --tail 50` line the script printed. Not a pass — say so plainly |
| 3 | No compose file | [AUTO] | This project has no staging stack, or it lives elsewhere. Report the path tried and name `staging.composeFile` |

## Stop

1. **Stop it:**
   ```bash
   eval "$(scripts/lv-exec.sh lv-stage-stop.sh)"
   ```
   Sets `STAGE_PROJECT` and `STAGE_WAS_RUNNING`.

2. **Report what actually happened** — the two cases read differently, and a tester who tore down a live environment must not get the same sentence as one who stopped nothing:
   - `STAGE_WAS_RUNNING=true` → `✓ Staging stopped (<STAGE_PROJECT>). Volumes removed.`
   - `STAGE_WAS_RUNNING=false` → `Nothing was running (<STAGE_PROJECT>). Any auto-stop timer is cancelled.`

| Exit | Situation | Mode | Behavior |
|-|-|-|-|
| 0 | Stopped, or nothing was running | [AUTO] | Report the matching line above. Both are success — the requested end state is "not running" |
| 1 | `docker compose down` failed | [AUTO] | The stack may still be up. Show the output and the `ps` line the script printed. Do not report a stop that did not happen |
| 3 | No compose file | [AUTO] | Nothing here to stop. Report the path tried and name `staging.composeFile` |

`down -v` removes the stack's volumes. That is correct for staging, which is disposable and rebuilt from `release` on every start — but say "volumes removed" when reporting, because the same words about any other stack would mean data loss.

## Anything else

**Never guess.** A start result not in its table is a [GATE]:
```bash
scripts/lv-exec.sh lv-gate-open.sh <PLN-ID> needs-input "<question>" --skill lv-stage
```
If no plan is in play, or it is a stop, there is nothing to gate — report the situation to the user and stop.

## Configuration

All optional, in `claude-workflow.yml`, all with working defaults: `staging.port` (8081), `staging.minutes` (60), `staging.composeFile` (`docker/docker-compose.yml`), `staging.healthPath` (`/health`). The compose project name is `<project_slug>-staging`, which keeps several projects' staging stacks off each other on one Docker daemon.

## Done

You are finished when the user has been told the URL **and** the deadline (start), or which of the two stop cases happened — or why none could be established. Nothing is claimed, nothing is committed, and nothing is still running on your side.

## Usage

```text
/lv-stage               start staging (same as: start)
/lv-stage start         bring release up locally; report URL and auto-stop deadline
/lv-stage stop          stop it and cancel the auto-stop
```
