# Cross-project bugs and requests

Projects on this harness depend on each other — client-e integrates
client-c's OIDC, for example. Nothing before this made it possible to
report a problem or ask for a capability change against the *other* side of
an integration except by hand: a Slack message, a memory, a note nobody else
in that project's pipeline would ever see. `wf-dep-bug.sh` and the
`dependencies:` config key are the workaround. Read this before adding a
`dependencies:` entry or filing across one.

## The core idea

A report about a dependency belongs in the **dependency's own** `bugs/open/`,
allocated through the **dependency's own** counter, so it is picked up by the
**dependency's own** `/wf-spec` exactly like any bug filed there by hand.
There is no second inbox, no new triage path, no cross-project registry to
keep in sync. The only new thing is *how the file gets there*.

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
3. `cd`s into it and runs `scripts/wf-exec.sh wf-branch-check.sh develop true`,
   **with `WF_UNATTENDED=1` forced** — see [Why WF_UNATTENDED](#why-wf_unattended-is-forced).
4. Runs `scripts/wf-exec.sh wf-bug-new.sh` there, exactly as that project's
   own `/wf-bug` would, with `--source cross-project:<reporting-slug>` so the
   origin is always on the record.
5. Restores whatever branch the host was on before switching.

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

## Why WF_UNATTENDED is forced

`wf-branch-check.sh`'s attended path (a human running a skill in their own
project) *warns* about a shared checkout parked on a branch the pipeline
didn't create, then switches anyway — right for a human who owns the mistake
they're about to make. `wf-dep-bug.sh` is never that human: the session
running it is working in the *reporting* project, and the checkout it's about
to switch belongs to someone else's session in the *host* project. Forcing
`WF_UNATTENDED=1` for that one call makes the same condition **refuse** (exit
2, nothing written) instead of warn-and-proceed. A report that can't land
right now is a no-op; a report that silently moved a stranger's branch out
from under them is a WFI-123 in a different project's name.

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
