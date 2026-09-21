# Cross-project bugs, requests, and notices

Projects on this harness depend on each other — client-e integrates
client-c's OIDC, for example. Nothing before this made it possible to
report a problem or ask for a capability change against the *other* side of
an integration except by hand: a Slack message, a memory, a note nobody else
in that project's pipeline would ever see. `wf-dep-bug.sh` and the
`dependencies:` config key are the workaround. Read this before adding a
`dependencies:` entry or filing across one.

The same gap exists in the other direction: a project making a change that
affects its dependents had no way to tell them either, short of the same
Slack-message-nobody-tracks fallback. `wf-dep-notify.sh` and the
`dependents:` config key — [below](#notifying-dependents-of-a-change) — are
that workaround, built on the identical mechanism reversed.

## The core idea

A report about a dependency belongs in the **dependency's own** `bugs/open/`,
allocated through the **dependency's own** counter, so it is picked up by the
**dependency's own** `/wf-spec` exactly like any bug filed there by hand.
There is no second inbox, no new triage path, no cross-project registry to
keep in sync. The only new thing is *how the file gets there*.

This holds for both directions. A notice about a change lands in the
**dependent's own** `bugs/open/` the same way — the direction of the arrow
changes, the mechanism doesn't.

## Setup: declare the dependency

In the **reporting** project's `claude-workflow.yml`:

```yaml
dependencies:
  - "client-c:/Users/you/dev/client-c"
```

One entry per dependency, `name:absolute-path`, joined on the first `:`. The
name is what `--host` takes; the path is where that project is checked out
**on this machine**. This only works for a dependency you have a local
checkout of — see [Limitation](#limitation-no-local-checkout) below.

`dependencies:` is read with `wf_cfg_list`, the same simple sequence-of-scalars
parser every other list-shaped config key uses (`source_dirs`, `tags`,
`renderingSurfaces`). No `yq`, no nesting past one level, one line per entry.

## Filing a report

From the reporting project:

```bash
scripts/wf-exec.sh wf-dep-bug.sh --host client-c "OIDC refresh token rejected before real expiry" \
  --kind bug \
  --severity High \
  --description "..." --steps "..." --expected "..." --actual "..." \
  --notes "hit integrating PLN-004's token refresh"
```

`/wf-bug` is the entry point a human or an agent actually uses — see
[skills/wf-bug/SKILL.md § Filing against a dependency, not this project](../skills/wf-bug/SKILL.md#filing-against-a-dependency-not-this-project).
`wf-dep-bug.sh` is what it calls.

`--kind bug|request` (default `bug`) distinguishes a defect from a capability
ask — both land in the same place, tagged `> **Kind:** Bug` or
`> **Kind:** Request` in the host's `bug.md`, because both go through the
host's own `/wf-spec` the same way.

## What actually happens

`wf-dep-bug.sh` does not write into the dependency's files directly. It:

1. Resolves `--host` against the reporting project's own `dependencies:` list.
2. Confirms the path exists and has `scripts/wf-exec.sh` — a local checkout
   actually running this harness, not a stale clone or a typo.
3. Reads (never writes) the host's current branch. If it isn't `develop`,
   refuses outright (exit 2, nothing written) — see
   [Why the host's branch is never touched](#why-the-hosts-branch-is-never-touched).
4. Runs `scripts/wf-exec.sh wf-bug-new.sh` there, exactly as that project's
   own `/wf-bug` would, with `--source cross-project:<reporting-slug>` so the
   origin is always on the record.

Every one of those calls is the **host's own** deployed copy of the script,
resolved through the **host's own** `wf-exec.sh` — so a host on an older
harness version files the bug the way its own version writes it, not the way
the reporting project's version would. Nothing about this assumes both sides
are on the same `workflow-version`.

## What doesn't happen: it never pushes

`wf-dep-bug.sh` commits in the host but does not `git push`. Pushing another
project's `develop` is that project's call — made by a human there, or by its
own orchestrator — not something a script acting on a dependency's behalf
should decide. The reporting agent's job ends at telling the user a bug landed
in `<host>` at a given path and still needs a push from over there.

## Filing is the terminal action for the reporting session

"The reporting agent's job ends at telling the user a bug landed in `<host>`" above is not a
detail about pushing — it is the general rule. Once the bug exists in the host's `bugs/open/`,
everything downstream of it — claiming, writing a plan, updating the host's registry, reviewing —
belongs to a session actually rooted in the host project (its own `/wf-spec`, its own
`/wf-implement`, its own orchestrator), never to the session that filed the report. This holds
whether the filing went through `wf-dep-bug.sh` or a human/agent `cd`'d into the host by hand and
ran its `wf-bug-new.sh` directly — the mechanism doesn't change who owns what happens next.

client-e's WFI-025 crossed this line: it filed a client-c bug correctly (by hand, since
`wf-dep-bug.sh` wasn't used), then continued — claimed it, hand-authored `plan.md`/`findings.md`/
`progress.md` in client-c's `plans/`, ran `wf-registry-add.sh`, and spawned a review agent —
effectively running client-c's own `/wf-spec` from a session with no standing role in that
project's pipeline. Everything past the filing had to be reverted. Nothing refused it: a session
is not confined to the project it's rooted in by anything at the tool level, only by this
convention. See [skills/wf-bug/SKILL.md § Filing against a dependency, not this
project](../skills/wf-bug/SKILL.md#filing-against-a-dependency-not-this-project) for the same
rule stated where the filing actually happens.

## Why the host's branch is never touched

This used to `cd` into the host, run `wf-branch-check.sh develop true` with
`WF_UNATTENDED=1` forced to switch the host onto `develop`, file, then switch
back to whatever branch it found. `WF_UNATTENDED=1` made that call refuse
(exit 2) rather than warn-and-switch for a checkout parked on a branch the
pipeline didn't create or on `release`/`main` — right, since the session
running `wf-dep-bug.sh` is working in the *reporting* project, and the
checkout it was about to move belongs to someone else's session in the
*host* project entirely.

But `wf-branch-check.sh`'s `develop|feature/*` case was — and still is, for
its normal, local callers — a silent no-op switch: exactly the branches a
human's own in-progress work sits on. A cross-project filer landed there
too, so the one case that most needed refusing was the one case that wasn't.
`wf-dep-bug.sh` moved a host's own feature branch out from under it for the
duration of a filing that had nothing to do with that work.

The fix isn't a stricter switch-and-restore — any switch, even a restored
one, is a window where something else looking at the host's checkout (a
human, the host's own orchestrator) sees the wrong branch. So there is no
switch at all: `wf-dep-bug.sh` reads the host's current branch and proceeds
only if it is already `develop`, its stated permanent home for the shared
checkout (`docs/release-worktrees.md`). Anything else refuses (exit 2,
nothing written), unconditionally, feature work included. A report that
can't land right now is a no-op; a report that silently moved a stranger's
branch out from under them is a WFI-123 in a different project's name.

A dedicated worktree for incoming reports — the same fix
`release-branches/{release,main}` got for the analogous problem
(`docs/release-worktrees.md`) — does not generalize to this case. `develop`
is the shared checkout's own home branch, so pinning a second worktree to it
fails outright in the host's normal state (git refuses to check the same
branch out twice). And `wf-bug-new.sh`'s counter allocation
(`wf-counter-next.sh`) resolves `plans/REGISTRY.md` via `wf_develop_root()` —
always the host's main worktree, never wherever `wf-bug-new.sh` itself is
invoked from — so a second worktree would not even decouple the write from
the shared checkout's state. Refusing cleanly is the fix actually available
without redefining what `wf_develop_root()` means project-wide.

## Limitation: no local checkout

This mechanism assumes the dependency is checked out on the same machine at a
known path — true for a single developer coordinating several repos under one
`~/dev`, false for a dependency that's genuinely only hosted elsewhere (a
third-party service, a team you don't have a clone from). For that case,
there's no shortcut: file the report as a local bug in the reporting
project's own `bugs/open/` instead, with `--links` naming the real dependency
and `--notes` saying it belongs elsewhere, and coordinate by hand (an issue in
the dependency's own tracker, a message to whoever owns it). `/wf-bug`
documents this fallback next to the `wf-dep-bug.sh` path so an agent doesn't
invent a fake `dependencies:` path to force it through.

## Why this isn't a brief

A capability *request* against a dependency uses `--kind request`, not a
brief filed through `/wf-brainstorm`. Briefs have no allocator script (they're
hand-written from `plans/briefs/TEMPLATE.md`) and are meant for the kind of
open-ended exploration a planner does with the person who wants the thing —
neither of which fits a report arriving from a different project's pipeline
with no planner in the loop on either side. A bug-shaped request still reaches
the host's `/wf-spec`, which can turn it into a real brief there if it turns
out to need one.

## Notifying dependents of a change

`wf-dep-bug.sh` above is inbound: a project reporting a problem *into* a
dependency. `wf-dep-notify.sh` is the same mechanism run the other way —
outbound, a project announcing a change *to* the projects that depend on it.
client-c shipping an OIDC contract change that client-e and client-f both
integrate against is the standing case: nothing before this told either of
them it happened except however client-c's owner remembered to mention
it.

### Why push, not a changelog

The obvious alternative — client-c publishes a changelog, dependents pull
from it — was considered and rejected. It's the second-inbox pattern [the
core idea](#the-core-idea) above already ruled out for the other direction,
just relocated: a changelog needs a "last-seen" cursor per dependent, a
script to diff against it, and something that actually triggers the check
(a hook, a `/wf-status` addition), and if that trigger auto-files an unread
entry into `bugs/open/` anyway, you've built push with an extra layer in
front of it. Filing directly into the dependent's own `bugs/open/` — same
mechanism as `wf-dep-bug.sh`, same guarantee that the dependent's own
`/wf-spec` picks it up — has no such gap: there's nothing to forget to check.

### Setup: declare dependents

In the **notifying** project's `claude-workflow.yml`:

```yaml
dependents:
  - "client-e:/Users/you/dev/client-e"
  - "client-f:/Users/you/dev/client-f"
```

Same shape as `dependencies:` — `name:absolute-path`, one entry per line,
read with the same `wf_cfg_list` parser — just declared on the notifying
project's side instead of the reporting project's side. **Nothing scans for
this automatically.** A project appears in another's `dependents:` only
because a human put it there, which means it can drift from what the
dependent itself declares in its own `dependencies:` — client-c could
list a client that quietly dropped the integration, or miss one that added
it without telling client-c's owner. That drift is a stale path failing
loudly at filing time, not a silent gap, which is the trade this design
makes deliberately: see [Why push, not a changelog](#why-push-not-a-changelog)
above.

### Filing a notice

From the notifying project, broadcasting to every declared dependent:

```bash
scripts/wf-exec.sh wf-dep-notify.sh "<title>" \
  --severity Critical|High|Medium|Low \
  --description "..." --expected "..." --actual "..." --notes "..."
```

Add `--to <name>` to reach just one dependent instead of all of them. `/wf-bug`
is *not* the entry point here — filing a notice isn't reporting a bug in the
notifying project, it's announcing one that doesn't exist yet in a project
that hasn't built against the change. `/wf-dep-notify` is the entry point a
human or agent uses — see
[`skills/wf-dep-notify/SKILL.md`](../skills/wf-dep-notify/SKILL.md).
`wf-dep-notify.sh` is what it calls.

Notices land with `--kind notice` — a third value alongside `bug`/`request`
on `wf-bug-new.sh`, so a dependent reading their own `bugs/open/` can tell at
a glance "this is an upstream announcement" apart from a defect found
locally or a capability someone there asked for.

### What actually happens

For each target dependent, `wf-dep-notify.sh`:

1. Resolves it against the notifying project's own `dependents:` list.
2. Confirms the path exists and has `scripts/wf-exec.sh`.
3. Reads (never writes) the dependent's current branch. If it isn't
   `develop`, that one dependent is **skipped**, not refused wholesale —
   see [It's a broadcast](#its-a-broadcast-not-an-all-or-nothing-call) below.
4. Runs `scripts/wf-exec.sh wf-bug-new.sh` there, with
   `--source cross-project:<notifying-slug>` and `--kind notice`.

Same as `wf-dep-bug.sh`: it commits in each dependent but does **not**
push — that's each dependent's own call, made by a human or its own
orchestrator over there, not by a script filing on this project's behalf.

### It's a broadcast, not an all-or-nothing call

`wf-dep-bug.sh` has exactly one host and refuses outright (exit 2, nothing
written) if that host isn't on `develop` right now. `wf-dep-notify.sh`
usually has several targets, and the entire point is keeping every consumer
in sync — so one dependent parked on a feature branch must not block the
notice from landing in the others. Each dependent is attempted
independently; a skip is reported (`SKIPPED <name> <reason>`) rather than
aborting the run, and the script exits `0` once every target has been
attempted, whether or not all of them landed. The caller — `/wf-dep-notify`
or whoever invoked the script — is responsible for reading which dependents
were skipped and telling the user, since nothing else retries them.

### Coordinators file the same way, downward

A third direction reuses this identical mechanism: a **coordinator** — a project
with `role: coordinator` that oversees others and runs no pipeline of its own
(`~/dev/coordinator`) — files work *down* into the projects it directs.

`wf-dep-notify.sh` is the script for that too. It resolves targets from
`coordinates:` as well as `dependents:` (both keys are read and concatenated),
and takes `--kind request` — a coordinator is asking for work, not announcing a
change it already shipped. Everything else holds unchanged: the target's own
`wf-bug-new.sh` allocates the ID, the report lands in the target's own
`bugs/open/`, the target's branch is read and never written, the filing is
committed but not pushed, and **filing is the terminal action** — the section
above applies to a coordinator with more force than to anyone, since it has no
standing in any of those pipelines at all.

See [`docs/coordinator.md`](coordinator.md) for what a coordinator install
contains and why it needs the harness at all.

### Why this isn't `/wf-bug`

`/wf-bug`'s dependency section files a report about *this* project's problem
into someone else's inbox. A notice is the reverse: this project already
knows what changed, and is telling someone else's inbox about *their*
problem before it becomes one. Both end up as a `bug.md` filed through the
counter, because both need the same guarantee — landing in the target's own
pipeline with no second inbox — but conflating the entry points would mean
`/wf-bug` asking "is this a bug in this project, in a dependency, or an
announcement to a dependent?" on every invocation, for a distinction that's
usually obvious to whoever is already typing the request.

## Waiting on the report you filed

Filing is terminal — the section above says why — but the plan you filed *for*
is still sitting here, and until now there was nowhere to say what it was
waiting on. That is client-b WFI-015: PLN-011 was blocked on client-d's
BRF-009 / BUG-011, `wf-set-deps.sh` took plan IDs only, and `--gating` offered
`security`, which would have been a false label. The one mechanism that
actually kept a live daemon off the plan was a `wf-claim.sh` lease, explicitly
documented as stealable by any session that judges it stale. The plan sat in
`draft` — a dispatchable state — with a daemon that would have replanned it
against tokens that did not exist yet.

The `Deps` column takes the same `<project>:<ID>` shape this file's `--host`
does, resolved through the same `dependencies:` entry:

```bash
scripts/wf-exec.sh wf-set-deps.sh PLN-011 client-d:BRF-009
scripts/wf-exec.sh wf-check-deps.sh PLN-011
# EXTERNAL client-d:BRF-009 (PLN-009 draft)
```

**It is checked, not declared.** Identity is the *number* — `BRF-009` becomes
`PLN-009` becomes a closed `BUG-009`, all one artifact — so this reads the other
project's own `plans/REGISTRY.md` and `bugs/closed/`, and the block lifts by
itself the moment the work lands there. Nobody has to remember to clear a
column, which is the whole reason it isn't a flag: a marker only a human can
clear is the same stall wearing different clothes.

A ref that cannot be resolved — project not in `dependencies:`, checkout
missing, no registry there — **blocks**. An unresolvable dependency is not a
satisfied one, and reporting it clear would dispatch exactly the plan somebody
parked. `wf-set-deps.sh` refuses an undeclared project name outright, for the
same reason: a typo that blocks forever is indistinguishable from the bug this
fixes.

The [Limitation](#limitation-no-local-checkout) above applies here unchanged —
without a local checkout of the dependency there is nothing to read, and the
dep reports `EXTERNAL … (no registry at …)` rather than pretending to know.
