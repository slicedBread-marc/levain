---
name: wf-dep-notify
description: Announce a change in this project to the projects that depend on it. Use after shipping a change here (a contract change, a breaking API shift, a migration) that other declared projects need to react to — not for reporting a bug or asking for a capability in a dependency, that's /wf-bug.
user_invocable: true
model: haiku
---

# Dependent Notification Role

You are in **notify mode**. Your job is to tell the projects that depend on this one about a
change here they need to account for — the mirror image of `/wf-bug`'s "Filing against a
dependency" flow, run from the other side of the same relationship.

## Recognize when this applies

Ask: does this change touch a contract another project relies on — an API shape, an auth flow,
a schema, a required config key, anything a dependent's own code calls or assumes? If yes, and
this project has declared dependents, they need to hear about it from here — nobody on the other
side is watching this project's commits for them.

This is **not** for:
- A bug or capability request *against* a dependency — that's `/wf-bug`'s "Filing against a
  dependency" section (`wf-dep-bug.sh`), the opposite direction.
- Routine internal changes nothing outside this project observes — most commits. Don't notify on
  every deploy; that trains dependents to ignore the notices when it matters.

## Setup: this project needs a `dependents:` list

Check this project's `claude-workflow.yml` for a `dependents:` block:
```yaml
dependents:
  - "client-e:/Users/you/dev/client-e"
  - "client-f:/Users/you/dev/client-f"
```
One name, one absolute local path, joined by the first `:` — the same shape as the
`dependencies:` key a consuming project declares about *this* one, just declared here in
reverse. If it's missing or empty, tell the user which projects they'd need to add and stop —
never invent a path.

## What you do

1. **Confirm scope with the user first** if it wasn't already explicit — which dependents does
   this change actually affect: all of them, or just one? Broadcasting to a dependent a change
   doesn't touch is noise, and noise is how the next real notice gets ignored.

2. **File it — one call.** This runs, per dependent, in the dependent's own checkout via its own
   `wf-exec.sh wf-bug-new.sh`, filed with `--kind notice` — exactly where that project's own
   `/wf-spec` already looks:
   ```bash
   scripts/wf-exec.sh wf-dep-notify.sh "<title>" \
     [--to <name>] \
     --severity Critical|High|Medium|Low \
     --description "<what changed, written for the DEPENDENT's reader>" \
     --expected "<what their integration should do now — the new contract>" \
     --actual "<what breaks, or changes, if they don't update>" \
     --notes "<deploy reference, migration guide, timeline>"
   ```
   Omit `--to` to broadcast to every declared dependent; pass it to reach just one. Omitted
   fields land as `TBD` — never invent them.

   **Severity is urgency to act, not how bad the change is in the abstract.** `Critical`/`High`
   for something that breaks a dependent's integration now or on its next deploy; `Low` for a
   heads-up with no required action yet (a deprecation notice, a future-dated change).

3. **This is not an eval contract — it's a report.** Each line on stdout is either
   `NOTIFIED <name> <bug-id> <path> <dir>` or `SKIPPED <name> <reason>`. Read it, don't eval it,
   and relay the outcome per dependent to the user — including which ones were skipped and why
   (usually: not on `develop` right now, so nothing was written there — that's normal, not an
   error, and no retry is needed from here).

4. **Tell the user what's NOT done yet.** Each notice is filed and committed in the dependent's
   own checkout but **not pushed** — same as `wf-dep-bug.sh`. Pushing another project's `develop`
   is that project's own call. Say so plainly: "Filed in client-e at
   `bugs/open/BUG-041-...`, still needs a push from over there."

## Filing is the terminal action for this session, same as the inbound direction

Once a notice lands in a dependent's `bugs/open/`, everything downstream — triage, a plan, a
build — belongs to a session actually rooted in *that* project, via its own `/wf-spec` and its
own `/wf-implement` (or its own orchestrator). Do not follow this call with a claim, a
hand-authored plan, or a registry edit in the dependent's checkout from here. See
`skills/wf-bug/SKILL.md § Filing against a dependency, not this project` — the same rule, stated
for the direction that section covers; it applies identically in reverse.

## If a dependent has no local checkout

`wf-dep-notify.sh` only reaches a project checked out locally at a known path (see
`docs/cross-project-reports.md § Limitation: no local checkout`). For a dependent that's
genuinely elsewhere, there's no shortcut: tell the user directly (a message, an issue in that
project's own tracker) — don't invent a `dependents:` entry to force it through.
