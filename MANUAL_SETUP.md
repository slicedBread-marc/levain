# Manual Multi-Terminal Setup

## Overview

This is the ideal setup for running the workflow with maximum throughput. It enables **parallel planning and implementation** without bottlenecks by using 4 dedicated terminals, each with a fixed model and assigned skills.

## Terminal Layout

```
┌──────────────────────┬──────────────────────┐
│  T1: Sonnet Intake   │  T2: Opus Planner    │
│  /lv-tray          │  /lv-spec            │
│  /lv-brainstorm      │                      │
│  /lv-bug             │                      │
├──────────────────────┼──────────────────────┤
│  T3: Opus Builder    │  T4: Sonnet Validator│
│  /lv-implement       │  /lv-verify          │
│                      │  /lv-test           │
│                      │  /lv-rollback        │
└──────────────────────┴──────────────────────┘
```

## Logging & Session Tracking

All terminals append to a single unified log file: `.logs/workflow.log`

### Setup (one time)
```bash
source .logs-utils.sh
init_session "2026-04-02-A"  # or let it auto-generate
```

### Session ID format
`YYYY-MM-DD-TERMINAL-ID` (e.g., `2026-04-02-T1`, `2026-04-02-A`)

### Each skill logs on start and completion
```bash
log_start "lv-spec" "BRF-001"
# ... do work ...
log_done "lv-spec" "PLN-001→ready"
```

### Log format
```
[HH:MM:SS] SESSION_ID | SKILL | ACTION | METRIC | Q: ready=N verify=N active=N open=N triaged=N
```

### Useful commands
```bash
source .logs-utils.sh
log_tail 20              # show last 20 lines
log_watch                # stream log in real-time (tail -f)
log_summary 2026-04-02   # show all lines from a session
```

### File locking (automatic)
- Uses `flock` to serialize writes
- Prevents line interleaving if multiple terminals log simultaneously
- Blocking: processes wait their turn (~1ms overhead per write)

---

## Terminal Setup

### T1: Sonnet Intake
**Purpose:** Feed work into the pipeline, maintain visibility, capture new ideas.

- **Model:** Sonnet 4.6
- **Skills:** `/lv-tray`, `/lv-brainstorm`, `/lv-bug`
- **Startup sequence:**
  ```bash
  source .logs-utils.sh
  init_session "2026-04-02-T1"  # or auto-generate
  /model sonnet
  /loop 10m /lv-tray
  ```
- **Responsibilities:**
  - Run `/lv-tray` every 10–15 minutes to check pipeline health
  - Run `/lv-brainstorm` to capture new ideas as briefs
  - Run `/lv-bug` to file bugs discovered during `/lv-test`
  - Ensure `plans/briefs/` has at least 3 Decided briefs ready for T2
  - Alert if bottleneck detected (T3 idle, waiting for ready plans)

### T2: Opus Planner
**Purpose:** Convert decided briefs and bugs into implementation plans.

- **Model:** Opus 4.6
- **Skills:** `/lv-spec` (primary)
- **Startup sequence:**
  ```bash
  source .logs-utils.sh
  init_session "2026-04-02-T2"  # or match T1's date for same session
  /model opus
  ```
- **Responsibilities:**
  - Read `plans/briefs/INDEX.md` for Decided briefs (fed by T1)
  - List open bugs in `bugs/open/`
  - Create plans in `plans/drafts/`
  - Move approved plans to `plans/ready/`
  - Always keep 2-3 ready plans ahead of T3's pace

### T3: Opus Builder
**Purpose:** Implement ready plans and produce working code.

- **Model:** Opus 4.6
- **Skills:** `/lv-implement` (primary)
- **Startup sequence:**
  ```bash
  source .logs-utils.sh
  init_session "2026-04-02-T3"
  /model opus
  /loop 2m /lv-implement
  ```
- **Responsibilities:**
  - Pick plans from `plans/ready/`
  - Execute steps and write tests
  - Move completed plans to `plans/verify/`
  - If idle waiting for a ready plan, signal T2 to spec faster

### T4: Sonnet Validator
**Purpose:** Test implementations, debug issues, handle rollbacks.

- **Model:** Sonnet 4.6
- **Skills:** `/lv-verify`, `/lv-test`, `/lv-rollback`
- **Startup sequence:**
  ```bash
  source .logs-utils.sh
  init_session "2026-04-02-T4"
  /model sonnet
  /loop 3m /lv-verify
  ```
- **Responsibilities:**
  - Run `/lv-verify` on plans in `plans/verify/`
  - Run `/lv-test` on completed plans if manual testing needed
  - Run `/lv-rollback` if issues found
  - Can run in parallel with T3's implementation
  - Monitor for completed plans and pull them proactively

## Workflow Rhythm

### Pre-Session (5 min)
1. **T1:** Run `/lv-tray` — assess current state
   - Are there ready plans for T3?
   - Are there plans waiting in verify/ for T4?
   - How many briefs are Decided?
2. **T1:** If < 3 Decided briefs exist, start `/lv-brainstorm`
3. **T2:** If Decided briefs exist, start `/lv-spec`
4. **T3:** If ready plans exist, start `/lv-implement`
5. **T4:** If plans in verify/, start `/lv-verify`

### Concurrent Work (during session)
- **T1** captures new briefs while T2 specs PLN-003
- **T2** specs PLN-003 while T3 implements PLN-001
- **T4** verifies PLN-001 (completed) while T3 is on step 5/8 of PLN-002

### Handoff Pattern
```
T1 completes /lv-brainstorm (BRF-003 → Decided)
  ↓
T2 pulls BRF-003 and runs /lv-spec (PLN-003 → ready/)
  ↓
T3 pulls PLN-003 from plans/ready/ and runs /lv-implement
  ↓
T4 picks up completed plans from verify/ and runs /lv-verify
  ↓
T1 notified of completion, can capture more ideas for next cycle
```

## Bottleneck Prevention

### Rule 1: T3 (Builder) should never be idle
If T3 finishes a plan and no ready plans exist:
- **Action:** Drop to T2 and run `/lv-spec` immediately
- **Reason:** T3 is the bottleneck. Empty the ready/ queue is wasteful.

### Rule 2: T2 should stay 2-3 plans ahead
Before T2 finishes a spec session:
- Check `plans/ready/` — if < 2 plans, start another spec
- **Reason:** T3 should never wait for T2's next output

### Rule 3: T4 validates in parallel
Don't wait for T3 to finish before T4 validates. As soon as a plan moves to `plans/verify/`:
- **Action:** T4 picks it up immediately
- **Reason:** Validation can happen while T3 builds the next plan

### Rule 4: T1 keeps the intake flowing
If `/lv-tray` shows < 3 Decided briefs:
- **Action:** T1 runs `/lv-brainstorm` to create more briefs
- **Reason:** T2 should never run out of input

## Context-Switching Guide

### When T1 is done with brainstorm/status (10–15 min)
- **If plans/briefs/ has 3+ Decided briefs:** Idle or check for new issues
- **If plans/briefs/ has < 3 Decided briefs:** Brainstorm more
- **If new bugs discovered:** File them with `/lv-bug`

### When T2 is done speccing (5–10 min per plan)
- **If plans/ready/ is full (3+):** Idle or help T1 brainstorm
- **If plans/ready/ is low (< 2):** Spec another brief immediately
- **If a brief is Decided but not spec'd:** Spec it now

### When T3 is done implementing (15–30 min per plan)
- **If plans/ready/ is empty:** Switch to T2 and help spec
- **If plans/ready/ has 2+:** Start `/lv-implement` on next plan
- **If new plans appear while implementing:** Commit current step and pick up next plan

### When T4 is done verifying (10–20 min per plan)
- **If plans/verify/ is empty:** Wait or check for completed plans
- **If plans/complete/ exists:** Run `/lv-test` for manual verification
- **If issues found:** Run `/lv-bug` to file the issue (feeds back to T1)

## Logging Examples

### Sample log output
```
[14:20:00] 2026-04-02-T1 | lv-tray | start | check-queue | Q: ready=1 verify=1 active=1 open=3 triaged=1
[14:20:30] 2026-04-02-T1 | lv-brainstorm | start | BRF-001 | Q: ready=1 verify=1 active=1 open=3 triaged=1
[14:23:15] 2026-04-02-T1 | lv-brainstorm | done | BRF-002→Decided | Q: ready=1 verify=1 active=1 open=3 triaged=1
[14:25:00] 2026-04-02-T2 | lv-spec | start | BRF-002 | Q: ready=1 verify=1 active=1 open=3 triaged=1
[14:33:42] 2026-04-02-T2 | lv-spec | done | PLN-001→ready | Q: ready=2 verify=1 active=1 open=3 triaged=1
[14:35:10] 2026-04-02-T3 | lv-implement | start | PLN-001 | Q: ready=1 verify=1 active=1 open=3 triaged=1
[14:52:30] 2026-04-02-T3 | lv-implement | done | PLN-001→verify | Q: ready=1 verify=2 active=0 open=3 triaged=1
[14:53:00] 2026-04-02-T4 | lv-verify | start | PLN-001 | Q: ready=1 verify=1 active=0 open=3 triaged=1
[15:08:45] 2026-04-02-T4 | lv-verify | done | PLN-001→complete | Q: ready=1 verify=0 active=0 open=3 triaged=1
[15:10:00] 2026-04-02-T1 | lv-bug | create | BUG-004 | Q: ready=1 verify=0 active=0 open=4 triaged=1
```

### Watch log in real-time
```bash
source .logs-utils.sh
log_watch
# Streams new lines as they're appended
```

### Check recent activity
```bash
log_tail 50  # last 50 lines
log_summary 2026-04-02  # all lines from that date
```

---

## Example Session (90 minutes)

```
T1 [00:00] /lv-tray
  → 2 briefs Decided (BRF-001, BRF-002), 1 ready plan, 0 verifying

T1 [00:00] /lv-brainstorm capture BRF-003 [5 min]
T2 [00:05] /lv-spec BRF-001 → PLN-001 ready [10 min]

T3 [00:10] /lv-implement PLN-001 [T2 just moved it to ready/]
T2 [00:15] /lv-spec BRF-002 → PLN-002 ready [10 min]
T1 [00:15] /lv-tray check (pipeline healthy, wait)

T3 [00:20] PLN-001 step 3/7
T2 [00:20] PLN-002 ready [T2 → ready/]
T4 [00:20] Nothing to verify yet, wait

T3 [00:25] Step 5/7 of PLN-001
T2 [00:25] /lv-spec PLN-003 from BRF-003 [T1 just captured it]
T1 [00:25] /lv-brainstorm — explore new feature idea
T4 [00:25] Still waiting for verify/

T3 [00:30] PLN-001 → verify/ [moving to T4]
  Immediately pulls PLN-002 from ready/ → starts
T4 [00:30] /lv-verify PLN-001 [15 min]
T2 [00:30] Still speccing PLN-003

T3 [00:40] Step 3/8 of PLN-002
T2 [00:35] PLN-003 ready [→ ready/]
T4 [00:35] Verifying PLN-001, step 3/4
T1 [00:40] /lv-tray — pipeline healthy

T4 [00:45] PLN-001 complete → plans/complete/
T3 [00:55] PLN-002 → verify/ [moves to T4]
T4 [00:55] /lv-verify PLN-002
T2 [00:55] /lv-spec PLN-004 from remaining brief [if available]

T3 [00:55] Pulls PLN-003 from ready/ → starts /lv-implement

[Loop continues: T1 monitors and feeds, T2 plans, T3 builds, T4 validates]
```

## Checklist: Before Each Session

**Logging setup (all terminals):**
- [ ] All: `source .logs-utils.sh`
- [ ] All: `init_session "YYYY-MM-DD-TN"` (T1, T2, T3, T4 — same date)
- [ ] One: `log_watch` (in a 5th window) to monitor log in real-time

**Terminal startup:**
- [ ] T1: `/model sonnet` + `/loop 10m /lv-tray`
- [ ] T2: `/model opus` (manual, runs /lv-spec)
- [ ] T3: `/model opus` + `/loop 2m /lv-implement`
- [ ] T4: `/model sonnet` + `/loop 3m /lv-verify`

**Pipeline health check:**
- [ ] T1: Run `/lv-tray` to see current state
- [ ] T1: Check if Decided briefs exist (> 3) for T2
- [ ] T2: Check if ready plans exist to spec from (briefs)
- [ ] T3: Check if ready plans exist to implement
- [ ] T4: Check if plans in verify/ to validate

## Checklist: Monitoring Health

During a session, watch for these signs of bottlenecks:

| Symptom | Cause | Fix |
|-|-|-|
| T3 idle, no ready plans | T2 too slow | T2 spec faster or switch to T2 and help |
| T2 idle, ready briefs full | T3 too slow | Normal — let T3 work; T2 waits |
| T4 always idle | No plans completing | Check if T3 is moving plans to verify |
| T1 can't feed work | No decided briefs | T1 should brainstorm more ideas |

## Notes

- **Model switching cost:** Each terminal does `/model X` once at startup. Don't switch models mid-terminal.
- **Session length:** Typically 60–90 minutes per session. After that, review metrics and start a new session.
- **Logging:** All terminals append to `.logs/workflow.log` with file locking (flock). Safe for concurrent writes.
- **Metrics:** Parse `.logs/workflow.log` to analyze queue trends, bottlenecks, throughput. `/wf-metrics` skill (TODO) will automate this.
- **Parallel limits:** Realistically, T2 and T3 can run in true parallel only if you have 2+ physical terminals or split-screen. If sharing one screen, context-switch between them every 5–10 minutes.
- **Idle time is OK:** T1, T2, or T4 being idle briefly is fine. T3 (builder) being idle is a sign to help T2.
- **.logs directory:** Gitignored (local only). Logs persist across sessions for historical analysis.
