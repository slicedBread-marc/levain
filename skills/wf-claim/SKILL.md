---
name: wf-claim
description: Take, release, or inspect the claim on a plan, bug, or brief — the lease that keeps another session off an artifact you are driving.
user_invocable: true
model: haiku
---

# Claim Mode

You are in **claim mode**. Your job is to take, release, or report the lease on one artifact. You do not read plans, edit files, or move pipeline state.

## On startup

Run this first and show the output verbatim:

```bash
scripts/wf-exec.sh wf-claim.sh --list
```

Then present the menu — do not read anything else before the user picks:

```
Claims

  <the --list output, or "No live claims.">

  claim <ID>     take the lease on PLN-NNN / BUG-NNN / BRF-NNN
  release <ID>   give it back
  steal <ID>     take one a live session is holding
  refresh <ID>   push out the 2h expiry on one you already hold
```

If the user's invocation already names an artifact (`/wf-claim PLN-042`), skip the menu and treat it as `claim PLN-042`.

## What a claim is

A **lease on an artifact number**, not a lock on a file. `BRF-041` and the `PLN-041` it becomes are one claim, and it covers everything under that number: `plans/PLN-041-*/`, `bugs/`, `briefs/`, and the plan's `feature-branches/PLN-041-*/` worktree.

Two things honour it:

- **The dispatcher.** `wf-spawn.sh` will not launch a worker onto a claimed artifact, and `wf-list-{implementable,specable,testable}.sh` filter it out of their menus.
- **The write guard.** `wf-guard-write.sh` runs as a `PreToolUse` hook and refuses any `Edit`/`Write` under a claimed artifact's paths.

It expires after **2 hours**, and the moment its owning process dies. That is deliberate — a crashed session must not park an artifact forever. Long attended work refreshes it by claiming again.

## Commands

**claim** — the ordinary case:

```bash
scripts/wf-exec.sh wf-claim.sh <ID>
```

Exit 0 claimed. **Exit 2 means another live session already holds it** — that is an answer, not an error. Say who holds it and offer something else. Do not retry, and never delete the claim file by hand.

Exit 0 also covers `already held on your behalf by the dispatcher`: that claim names your own PID and means carry on.

**`--state <s>[,<s>...]`** adds a precondition: claim only if the plan is in one of those registry states, **exit 3** otherwise with nothing claimed. Every dispatched role passes the states it can actually work — a dispatch describes the registry when it was read, and a worker acts on it later. A verify worker was handed PLN-078 whose verify, human test, PR merge and bug close were already committed; had it not noticed, it would have routed a `complete` plan back to `testing` (WFI-153). Exit 3 is a stand-down: exit 0, do nothing, release nothing.

**release** — on the way out:

```bash
scripts/wf-exec.sh wf-unclaim.sh <ID>
```

Releasing is also a **trigger**: `wf-unclaim.sh` flushes any spawn the orchestrator deferred behind that claim, so a worker may start the instant you let go. Release when you are actually done.

**steal** — only when the holder is finished or wedged:

```bash
scripts/wf-exec.sh wf-claim.sh <ID> --steal
```

Confirm with the user first, naming the holder from `--list`. This writes a `claim-steal` event. Prefer it over release-then-claim: unclaiming would flush a deferred spawn onto the artifact you are trying to take.

**refresh** — re-run plain `wf-claim.sh <ID>`. A claim you already hold is recognised as yours and its timestamp is pushed out.

## Rules

- **Do NOT** edit plans, code, or the registry. This skill only moves claims.
- **Do NOT** delete a `.wf-claim` file directly — it skips the event log and the deferred-spawn flush.
- A claim is not a state change. It does not move a plan through the pipeline, and releasing one does not mean the work is done.
- If `wf-claim.sh` exits 2 and the user insists the holder is dead, check `--list` first: a dead holder's claim is reaped automatically and would no longer be listed. A claim still showing means a live process.

## Exit

Report what changed in one line — what you took or released, and who held it if you stole it. Then stop. There is no state transition to commit and no handoff to make.

Run `scripts/wf-exec.sh wf-check-reboot-flag.sh` afterward and append any output to your completion message.
