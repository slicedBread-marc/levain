---
name: lv-sweep
description: Heal the library — run a blind sweep of the top open client issues, which deploys the fixes to every client and publishes the library through the library-publish hook, then report. The same sweep as `heal (N)` / `W` on the rack. Coordinators only.
---

# /lv-sweep

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

The blind library sweep (LVI-031), started from a session rather than the board. A headless session
fixes the top three open client issues in the library under the permission baseline. Then
`lv-library-sweep.sh` decides what happens to the fixes, not the session:

- a green suite deploys them (`deploy-all.sh`) and resolves the issues
- after a deploy, it runs the `library-publish` hook
  ([`docs/extension-hooks.md`](../../docs/extension-hooks.md)), which publishes the public copy when a
  pack provides one
- a fix to a guard file, a red suite or uncommitted changes leave the fixes **held for review**, and
  nothing is deployed or published

Don't ask before starting: the sweep holds the library lock, the suite gates the deploy, and the
script refuses anything unsafe on its own.

1. **Count:** run `scripts/lv-exec.sh lv-library-sweep.sh count "$(head -1 .claude/workflow-source)"`.
   If it prints `0`, say the library is healthy and stop.
2. **Start:** run `scripts/lv-exec.sh lv-library-sweep.sh start "$(head -1 .claude/workflow-source)" "$PWD/.claude/orchestrator/library-sweep"`.
   Exit 3 is a refusal, such as the lock being held, a sweep already running or a dirty library.
   Report the reason it prints and stop. Never steal the lock.
3. **Wait:** in the background, with a single notification, wait until
   `.claude/orchestrator/library-sweep/pid` is gone or names a dead process. Don't poll it in the
   foreground.
4. **Report** using `.claude/orchestrator/library-sweep/result` and the `SWEEP_FIXED` /
   `SWEEP_LEFT` lines of the log named in `latest`:
   - what was fixed, which client each issue came from, and how many are left
   - the version deployed, and whether it was published
   - what was left, its class (`needs-operator`, `not-library` or `unsure`) and why. The sweep
     writes each one onto the issue as a `**Sweep:** left` line, and later sweeps skip it until
     somebody writes an answer under that line
   - **decide (N):** run `scripts/lv-exec.sh lv-rack.sh --decide` and give its count. When N is
     above 0, list each issue's id, client and question, and say that an answer written under
     the `**Sweep:**` line in that client's `WORKFLOW-ISSUES.md` lets the next sweep take it again
   - whether the sweep was held, and the reason
   For a held sweep, the operator reviews it and presses `U` on the board, which deploys and
   publishes it. After a deploy, say that a running board shows **restart required** and that `X`
   restarts it.
5. **Log it** through the `activity-log` hook (`scripts/lv-exec.sh lv-hook.sh activity-log "<what
   was fixed, deployed and published>" --ref <library sha>`).

## Usage

```text
/lv-sweep            heal: sweep, deploy, publish, report
/lv-sweep help       this block
On the board:  heal (N) on the library line, Enter or W · decide (N), Enter lists the
               questions a sweep left for you · `,` settings → auto-heal
```
