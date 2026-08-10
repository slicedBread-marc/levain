# Rehydration — what happens to a skill when the conversation is compacted

A `wf-*` skill keeps its state on disk: `plans/REGISTRY.md`, the plan's
`progress.md`, gate files under `.claude/orchestrator/`. That is what lets a
session be interrupted at all.

It is not enough on its own. When a long session compacts, the model keeps a
**prose summary** of what it was doing, and a summary is the wrong shape for
state. It says "implementing PLN-041" with no step count, or repeats a step
count that was true four commits ago. The registry has the right answer the
whole time; nothing tells the model to go and look.

So the harness re-reads state from disk immediately after compaction and hands
it back. That is `wf-rehydrate.sh`.

## Compaction cannot be controlled from inside a skill

Worth stating plainly, because it is the first thing anyone tries.

A skill is instruction text injected into the running conversation. It is not a
process, it has no options of its own, and it cannot invoke `/compact` — slash
commands are user input. The compaction window is resolved **once at session
start** into the session's options, from `--autocompact`, the
`autoCompactWindow` setting, or `CLAUDE_CODE_AUTO_COMPACT_WINDOW`.

Subagents do not help either, in the way people expect. A subagent is a fresh
**context**, not a new session — same process, same settings, same permissions —
and the spawn path copies the parent's `autoCompactWindow` verbatim. No agent
frontmatter field overrides it. What a subagent genuinely gives you is a clean
context window whose whole run collapses to one tool result in the parent, which
is a good reason to delegate long mechanical work, and no reason to expect
different compaction behaviour inside it.

Hence: do not try to prevent compaction. Re-establish ground truth afterwards.

## PostCompact is not the hook that carries context

This is the trap, and it is worth being explicit because the wrong wiring
*looks* like it works.

| Hook | Fires | Where its stdout goes |
|-|-|-|
| `PreCompact` | before compaction | can add to the summarization prompt, or block |
| `PostCompact` | after compaction | `userDisplayMessage` — **the human, not the model** |
| `SessionStart` (`source: compact`) | after compaction, rebuilding context | `additionalContext` — **into the conversation** |

`PostCompact`'s handler collects each hook's output into a line printed to the
user. It never reads `hookSpecificOutput.additionalContext`. Put the state block
there and you will see the text in your terminal, conclude it is wired, and the
model will have received nothing.

`SessionStart` fires with `source: "compact"` as part of rebuilding the
post-compaction context — alongside `CLAUDE.md` and the other attachments — and
its `additionalContext` becomes a `hook_additional_context` attachment. That is
the load-bearing wiring.

Both are installed. `PostCompact` is the **receipt**: one line in the transcript
saying rehydration ran and what it found, so a human reading back can tell the
difference between "the hook did nothing" and "the hook found nothing".

## What gets re-read

`wf-rehydrate.sh` anchors to the **main worktree** — a worker compacting inside
a feature worktree must still read the real registry, not that worktree's
sparse-excluded shadow.

Inside a feature worktree (`.plan-ref` present) it emits that one plan: registry
row (state, priority, branch, WF, tags, deps), the Goal line, the **live
`## Steps` checklist from `progress.md` verbatim**, the amendment count and
latest amendment, plus any open gate or live claim.

The Steps checklist is the point. Which step is next is the single thing a prose
summary is most reliably wrong about, and `## Steps` is the v6 forward-progress
signal — so it goes back verbatim rather than as a count.

Amendments matter for a narrower reason: an amendment is a design change made
after the plan was written, and a summary has no reason to have kept it. A goal
quietly re-widened after compaction to something an amendment had deliberately
narrowed is the failure that line prevents.

From the develop root it emits the non-terminal pipeline instead — one line per
plan with state, priority, step progress and goal.

It also restates the plan's **feature worktree path, absolute**. The working
directory does not survive a compaction: it reverts to the develop root with
nothing in the transcript saying so, and a relative read from there fails
*correctly*, which is indistinguishable from the feature being broken
(client-a WFI-098, and WFI-094 before it).

**When there is nothing in flight it emits nothing at all.** A repo between
plans should not pay tokens on every compaction to be told the pipeline is
empty.

## The block is a snapshot, and has to say which one

The block wins over the prose summary. It does not win over a script.

That distinction is not pedantry — it is a defect the harness shipped. The block
used to say "re-read from disk just now. Where they disagree, these values win",
with no timestamp on it. But a block from an *earlier* compaction survives into
the *next* summary word for word, so a session can be holding an hour-old STATE
line under a sentence claiming it is current. client-a's WFI-099: a block
reading `PLN-007 draft` sat above a `wf-list-gates.sh` run that correctly said
`testing`. The attendant believed the block, treated an `ok`-fit gate as
stale-by-state, and closed a gate nobody had answered — which wrote a false
resolution record (WFI-100) and let the daemon dispatch onto a plan a human was
mid-test on (WFI-102). One stale line, three reports.

So every block now carries the UTC instant it was read, in its header and in the
precedence sentence, and states three things: it does not outrank anything run
after that instant, an older block above it is superseded, and
`wf-rehydrate.sh` re-reads it on demand. A skill that has to choose between a
block and a script it just ran should choose the script.

## Matchers

| Event | Matcher | Why |
|-|-|-|
| `SessionStart` | `compact\|clear\|resume` | the three ways a session ends up holding less than it had |
| `PostCompact` | `manual\|auto` | both compaction triggers |

Deliberately **not** `startup`. A fresh session reaches the registry through its
skill's entry grep anyway, so the block would be pure cost on every launch.

## Where the wiring lives

`.claude/settings.json`, written by `install.sh` via
`templates/hooks/settings-merge.py`.

That file is the **project's**, not the harness's — it holds their permissions,
env and their own hooks — so the install merges rather than overwrites. It
replaces only entries whose command names `wf-rehydrate.sh`, identified by that
script name rather than by matcher or position: a matcher change then updates in
place instead of stacking a second entry that runs the script twice on every
compaction. It writes nothing when the result is byte-identical, because a
deploy that dirties a clean tree is a deploy nobody can verify.

### It stays tracked, unlike the rest of the harness

Everything else `install.sh` writes into `.claude/` is generated build output
and gitignored in the client — see [`untracked-harness.md`](untracked-harness.md).
`.claude/settings.json` is the exception, for a reason specific to worktrees:

> git materialises **tracked** files into a new worktree. An untracked
> `settings.json` means every feature worktree starts **without** the
> rehydration hooks.

That is precisely the session most likely to compact mid-implementation. So the
install warns when it finds the file untracked, and the client should commit it.

The flip side: a **fresh clone** then has the hook and not the script it calls,
because `scripts/v*/` and `wf-exec.sh` *are* gitignored build output. Every hook
command therefore ends `2>/dev/null || true`, so a repo that has not been
deployed into yet is quiet rather than printing a dispatcher error on every
session start. Run the script directly to see real errors.

## Checking it works

```bash
scripts/wf-exec.sh wf-rehydrate.sh                     # the block, as plain text
printf '{"source":"compact"}' | \
  scripts/wf-exec.sh wf-rehydrate.sh --hook session-start   # the JSON the hook emits
./tests/rehydrate.sh                                   # in the library
```

The script exits 0 unconditionally, including on a repo with no registry. A hook
that fails is a hook that interrupts a user's session over bookkeeping, and
there is no state here worth that.
