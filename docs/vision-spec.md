# The vision skill: interface specification

The overseer rung's third part (LVI-014). A coordinator oversees several projects; a **vision
skill** keeps the answer to *what are these projects for, together, and what comes next*. The
library does not ship one — a vision is too much the owner's own — it ships this contract, and
`/lv-vision` either finds the owner's skill or interviews them and writes one from the template
at the end.

Any skill that meets this spec works, hand-written or generated. The library finds it through the
`overseer-vision` hook ([extension-hooks.md](extension-hooks.md)): the hook prints the absolute
path of the skill's `SKILL.md`. Its default looks for `.claude/skills/vision/SKILL.md` in the
coordinator.

Placeholders are written `{{LIKE_THIS}}`:

| Placeholder | Meaning | Example |
|-|-|-|
| `{{FAMILY}}` | What the projects are, together | "the Acme family of apps" |
| `{{OWNER}}` | Who the vision is for and who approves it | "the operator" |
| `{{CONCERNS}}` | The 2–5 concerns the vision covers | product direction, positioning, architecture, experience |
| `{{ROOT}}` | The vision root, relative to the coordinator | `VISION.md` |
| `{{TREE}}` | The folder under it | `vision/` |
| `{{PROJECT_MAP}}` | Where the list of projects and standing facts lives | `PORTFOLIO.md` |
| `{{DECISIONS}}` | Where cross-project decisions live, or "none" | `decisions/` |
| `{{WORK}}` | Where cross-project work in flight lives, or "none" | `initiatives/` |
| `{{LOG}}` | The command that shows what recently happened, or "none" | `git log --since=60.days` |
| `{{BOARD}}` | The command that shows the pipelines | `scripts/lv-exec.sh lv-rack.sh --plain` |
| `{{FILE}}` | How work is filed into a project | `/lv-dep-notify` (`lv-dep-notify.sh --kind request`) |

## Modes

| Call | Mode | Role |
|-|-|-|
| `/vision` | status | Reporter: summarise the vision, recent drift, recommend one mode |
| `/vision checkin` | checkin | Chief of staff: sweep every project since the last check-in, grade the goals set then, agree the next ones |
| `/vision next` | next | Dispatcher: "what should I work on?", top-down from the priorities, the backlog and `{{BOARD}}` |
| `/vision explore [theme]` | explore | Facilitator: draw the vision out of `{{OWNER}}`; hold opinions back |
| `/vision challenge [idea\|section]` | challenge | Challenging strategist: stress-test; a "both" to a real trade-off is unresolved |
| `/vision draft [section]` | draft | Proposing architect: write an opinionated revision, ask for reactions |
| `/vision drift` | drift | Auditor: what was built against what the vision says |

A session stays in its mode's role, and says so when it switches.

## Files

| Path | What it is |
|-|-|
| `{{ROOT}}` | The root: the whole vision at a glance, in the format below, ending in a dated changelog |
| `{{TREE}}apps/<project>.md` | One project's vision in depth |
| `{{TREE}}topics/<topic>.md` | A cross-cutting theme in depth |
| `{{TREE}}sessions/YYYY-MM-DD-<topic>.md` | One note per session, always written |
| `{{TREE}}PRIORITIES.md` | The ranked answer to "what next": priorities, the projects under each (or Parked), the latest check-in's goals by link, then the live board. Only `{{OWNER}}` re-ranks |
| `{{TREE}}checkins/YYYY-MM-DD.md` | One note per check-in: what changed across the projects, the last goals graded, the next goals. **The latest one is the baseline** for the next check-in |
| `{{TREE}}BACKLOG.md` | Ranked vision work to pick up: every path suggested and not taken, with its mode and theme |

**The tree grows.** When a passage in the root passes about 15 lines, its detail moves to a page
and the root keeps a one- or two-line claim plus the link. Root and page never disagree. Every
page is reachable from the root. A page opens with `# <name>` and `> Revised YYYY-MM-DD · last
session: …`, and ends with its own changelog.

**The backlog.** Whenever a session suggests something to explore, challenge, draft or file, it
goes into the backlog in the same turn. At close: remove what was finished, add what was opened,
re-rank. An item waiting on an event goes under *Triggered* with its trigger.

**The priority tree.** `{{TREE}}PRIORITIES.md` is read from the top, big picture to fine detail:

1. **Priorities** — a few ranked outcomes, each tied to the north star.
2. **Projects** — every project in `{{PROJECT_MAP}}` has one place: under a priority, or under
   **Parked** with why and when to unpark it. A supporting project (shared assets, the
   coordinator itself) takes the rank of whatever its work is for.
3. **Goals** — the checkable goals in the latest check-in note, linked, not copied.
4. **The board** — live from `{{BOARD}}`, never stored. A board item takes its project's rank.

So something stuck in a parked or low project stays stuck on purpose: `next` reports it in one
*Left alone* line and never recommends it.

## Rules

1. **No invented facts.** A claim about a project's current state cites a source (`{{PROJECT_MAP}}`,
   `{{DECISIONS}}`, `{{WORK}}`, `{{LOG}}`, a project file). Otherwise it is labelled aspiration or
   question.
2. **Edit the vision directly** as the session concludes; `{{OWNER}}` approves substance, not
   wording. Ask first only to reverse something `{{OWNER}}` said, rewrite the north star, or add
   or remove a principle or non-goal.
3. **Never write decisions.** Propose one in the output (Context, Decision, Consequences, Revisit
   trigger) for someone to record.
4. **The vision outranks decisions.** A conflicting decision is flagged with both sources and two
   options: supersede it, or change the vision.
5. **Filing is allowed** through `{{FILE}}`, when the request is specific enough to build. A vague
   direction goes under Horizons instead. Never hand-write into a project's pipeline.
6. **One project, one job.** Every project in `{{PROJECT_MAP}}` has a role in the root, even
   "experiment" or "retire". One without a role is a finding.
7. **Respect standing facts** in `{{PROJECT_MAP}}`; a vision that contradicts one says so and
   triggers rule 4.
8. **Ranking belongs to `{{OWNER}}`.** Propose a change to `{{TREE}}PRIORITIES.md` with its
   evidence, and apply it only once `{{OWNER}}` agrees. `next` never re-ranks.
9. **Never a secret value**, and no path into a secrets store.
10. **Guard the whole family.** Whenever `{{OWNER}}` moves to change one project (its role,
    scope, audience, data, auth, hosting, a feature, a filing), check that change against
    everything else *before* it is applied or filed. This is why the session runs in the
    coordinator and not as a brainstorm inside the project: a project session sees its own
    repo, and the overseer sees the interdependencies (LVI-030). Check against:
    - the principles and non-goals in `{{ROOT}}`
    - the standing facts and known risks in `{{PROJECT_MAP}}`
    - every accepted decision in `{{DECISIONS}}`, not only the ones that name the project
    - the other projects' roles and pages, especially what each one **deliberately does not**
      do
    - work in flight in `{{WORK}}`, and work already filed in other projects that the change
      would invalidate or duplicate
    - the coordinator's own standing conventions (its `CLAUDE.md`)

    **Raise every conflict as soon as you see it**, even mid-thread and even when `{{OWNER}}`
    seems settled. Cite both sources and say what the change would cost the other side.
    `{{OWNER}}` decides: drop or reshape the change, change the vision (rule 2), or supersede
    the decision (rule 4). Never resolve a conflict silently in either direction. When the check
    finds nothing, say so in one line, so `{{OWNER}}` knows it ran. Record the result in the
    session note's **Cross-portfolio check**.

## Inquiry (explore, challenge)

Surface with open, pointed questions, one or two at a time, each built on the last answer. Pin a
converged thread down with multiple-choice rounds of up to four questions; mark an option
recommended only when the sources support it. Reflect back in a sentence or two before moving on.
In challenge, ask of every claim what would have to be true, what it costs and what it rules out.

## Procedures

- **status:** read the inputs and `{{BOARD}}`; output the north star in a line, when last revised,
  open threads, a count of drift signals, the last check-in's date and how many of its goals are
  still open, and one recommended mode — `checkin` when there has been none or the last is more
  than two weeks old. Writes only backlog rows.
- **next:** `{{OWNER}}` comes back, maybe in plain words ("what are we doing next?"). Answer
  top-down from `{{TREE}}PRIORITIES.md`.
  1. Read the priorities, the latest check-in's goals, the backlog (ranked, Drift, Triggered) and
     `{{BOARD}}`; check *Triggered* items against `{{LOG}}`.
  2. Give every board item its project's rank. Waiting counts: gates, needs-input, blocked,
     deploys, work `ready` with no worker. Stuck in a ranked project means act now; stuck in a
     parked or unranked one means it can stay.
  3. Output in ≤15 lines: **Priorities** (top two or three, each with its open goal), **Move now**
     (stuck or waiting items in ranked projects, highest first, each with project, id, state and
     what would unstick it), **Vision work** (one or two backlog items serving a ranked priority,
     with their `/vision <mode> <theme>`), **Left alone** (one line counting stuck items in parked
     or low projects), and **one pick** with why it beats the next one down. A board item that
     suggests the ranking is wrong is not re-ranked silently: say so and propose the change.
  4. Write only backlog corrections: a fired trigger moves into the ranked list, a row the board
     shows done is removed. Never re-rank.
- **checkin:** `{{OWNER}}` checks in irregularly, maybe weeks apart, and wants what happened
  across all the projects since last time and what to aim at next. A review and a goal-setting
  conversation, not an audit (that is `drift`).
  1. **Baseline:** the latest `{{TREE}}checkins/*.md`; its commit time
     (`git log -1 --format=%cI -- <note>`) is the baseline. None yet: use the vision's first
     commit, and say so. Read its **Goals**; step 3 grades them.
  2. **Sweep** every project in `{{PROJECT_MAP}}` with a local path, harnessed or not (retired
     ones only if they have commits). Per project since the baseline: `git log --all --no-merges
     --since=<baseline>` (so unlogged work still shows), its `{{LOG}}` rows, its `{{BOARD}}` row
     and what waits on `{{OWNER}}`. Across the family: changes to `{{WORK}}`, `{{DECISIONS}}` and
     `{{PROJECT_MAP}}`. With more than three active projects, give each to a subagent in one
     parallel batch, briefed: "Final response under 1500 characters: shipped, in flight, stalled,
     surprises, each with a ref. Outcomes, not process." An idle project is one line, not a
     subagent.
  3. **Report** before any question: last goals graded (*done*, *partly*, *slipped*, *dropped*,
     each with evidence); per project, most active first, one to three lines with refs;
     surprises (unpredicted work, new risks, fired triggers); what waits on `{{OWNER}}`; and only
     what is obvious against the vision — anything bigger is a backlog row for `drift`.
  4. **Re-rank, then set goals**, in the inquiry style: what mattered, what the period ahead looks
     like, what `{{OWNER}}` will not get to. Walk `{{TREE}}PRIORITIES.md` top-down — does each
     priority hold its rank, should anything be parked or unparked — and apply what `{{OWNER}}`
     decides (rule 8). Then pin **three to five goals** in a multiple-choice round, proposed from
     the sweep, the board and the top of the backlog, most under the top priorities. A goal names
     the priority it serves, its project, and an outcome someone can check next time ("X has an
     external monitor"), never an activity ("work on monitoring"). A slipped goal carries over
     only if `{{OWNER}}` re-commits to it.
  5. **Close** with the check-in note instead of a session note; update the backlog (remove what
     the sweep shows done, move fired triggers in, add what surfaced). Change `{{ROOT}}` only when
     `{{OWNER}}` moved a horizon or a project's role (rule 2).
- **explore / challenge / draft:** run the inquiry or proposal, apply what survives to the tree,
  write the session note. Challenge ends in a verdict per claim: holds, revise (applied), open.
- **drift:** compare the vision with `{{LOG}}` (about 60 days), `{{WORK}}`, `{{DECISIONS}}` and
  `{{PROJECT_MAP}}`, in three groups — built against the vision, vision without work, work without
  vision — each with evidence and a suggested action.

## Inputs

Always: `{{ROOT}}`, the latest 2–3 session notes, `{{TREE}}BACKLOG.md`, `{{TREE}}PRIORITIES.md`
(it ranks projects, and so board items), the latest check-in note, pages the theme touches,
`{{PROJECT_MAP}}`. When needed: `{{DECISIONS}}`, `{{WORK}}`, `{{LOG}}`, a project's own
`CLAUDE.md` or README to check a claim. Whenever a session changes a project, rule 10's sources
are required reading, not optional.

## Output format: the root

```markdown
# <Family> Vision

> Revised YYYY-MM-DD · last session: <tree>sessions/YYYY-MM-DD-<topic>.md

## North star
<One sentence: what the projects are for, together.>

## Principles
<5–8 numbered: a line of claim, a line of "so we …". Cut one that never decides anything.>

## The family
| Project | Job | For whom | Deliberately does not |
|-|-|-|-|

## <one section per concern in {{CONCERNS}}>

## Horizons
### Now
### Next
### Later

## Non-goals
<Each with a one-line reason.>

## Open questions
<Each with the date raised and the session note it came from.>

## Changelog
- YYYY-MM-DD — <what changed> (<session note>)
```

## Output format: priorities

```markdown
# Priorities

> Revised YYYY-MM-DD · last session: <note>
> The ranked answer to "what next". `/vision next` reads it top-down; each check-in revisits it.
> Only <owner> re-ranks.

## Ranked
| # | Priority | Projects | Horizon | Why here |
|-|-|-|-|-|

**Supporting:** <projects that take the rank of what their work is for>

## Parked
| Project | Why parked | Unpark when |
|-|-|-|

## Changelog
- YYYY-MM-DD — <what moved> (<note>)
```

## Output format: check-in note

```markdown
# Check-in — YYYY-MM-DD

- Baseline: <previous check-in note, or "vision first commit"> · <baseline timestamp>
- Projects swept: <n active> of <n total>

## Last goals, graded
| Goal | Grade | Evidence |
|-|-|-|

## What changed
### <project>
<One to three lines: shipped, in flight, stalled, each with a ref.>

## Surprises & risks
## Conversation
<What the owner said about priorities and the period ahead, close to verbatim.>

## Goals until next check-in
| # | Priority | Project | Goal (a checkable outcome) | Why now |
|-|-|-|-|-|

## Actions taken
```

The **Goals** table is what the next check-in grades; keep its wording checkable.

## Output format: session note

```markdown
# Vision session — <topic>

- Date: YYYY-MM-DD · Mode: <mode> · Target: <argument or "whole vision">

## Q&A
## Conclusions
## Changes to the vision
## Cross-portfolio check
<Rule 10: each conflict found, its sources, and what {{OWNER}} decided. "Ran, none found" when
clean. Omit only when the session changed no project.>
## Tensions & open threads
## Actions taken
```

## Closing a session

1. Write the session note (always) — a check-in writes its check-in note instead.
2. Update the backlog.
3. Commit the changed vision files (priorities included) and the note together:
   `vision: <mode> — <topic>` (a check-in: `vision: checkin — <n> goals set, <n> of <n> met`).
4. If `{{LOG}}` has a writer, record the consequence once, after the commit — the
   `activity-log` hook does this where one is configured
   (`scripts/lv-exec.sh lv-hook.sh activity-log "<consequence>" --ref <sha>`).
5. Report in ≤10 lines: what changed, what was filed, open threads, a suggested next mode.

## Template

`/lv-vision` copies everything between the two markers into the owner's
`.claude/skills/vision/SKILL.md`, with every placeholder filled from the interview.

<!-- vision-template:begin -->
---
name: vision
description: Keeper of the vision for {{FAMILY}} — what the projects are for together, each one's job, where they head and what they will never become. Modes status, checkin, next, explore, challenge, draft, drift.
---

# Vision

You keep the **vision of {{FAMILY}}** for {{OWNER}}: {{CONCERNS}}. Write tersely and candidly so
an agent in any of the projects can steer by it.

This skill follows the library's vision specification (`docs/vision-spec.md`, installed with
`/lv-vision`): its modes, files, rules, procedures and output formats apply here as written, with

- root `{{ROOT}}`, tree `{{TREE}}`
- projects and standing facts in `{{PROJECT_MAP}}`
- decisions in `{{DECISIONS}}`, work in flight in `{{WORK}}`
- recent history from `{{LOG}}`
- the pipelines from `{{BOARD}}`
- filing through `{{FILE}}`

Read `.claude/docs/vision-spec.md` before the first action of every session, then run the mode
named in the arguments (none means status).

## Owner's notes

<Anything particular to this family: standing preferences of {{OWNER}}, what the vision must never
assume. Edit freely — this section is yours.>
<!-- vision-template:end -->
