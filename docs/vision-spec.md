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
| `/vision next` | next | Dispatcher: "what should I work on?" from the backlog plus `{{BOARD}}` |
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
| `{{TREE}}BACKLOG.md` | Ranked vision work to pick up: every path suggested and not taken, with its mode and theme |

**The tree grows.** When a passage in the root passes about 15 lines, its detail moves to a page
and the root keeps a one- or two-line claim plus the link. Root and page never disagree. Every
page is reachable from the root. A page opens with `# <name>` and `> Revised YYYY-MM-DD · last
session: …`, and ends with its own changelog.

**The backlog.** Whenever a session suggests something to explore, challenge, draft or file, it
goes into the backlog in the same turn. At close: remove what was finished, add what was opened,
re-rank. An item waiting on an event goes under *Triggered* with its trigger.

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
8. **Never a secret value**, and no path into a secrets store.

## Inquiry (explore, challenge)

Surface with open, pointed questions, one or two at a time, each built on the last answer. Pin a
converged thread down with multiple-choice rounds of up to four questions; mark an option
recommended only when the sources support it. Reflect back in a sentence or two before moving on.
In challenge, ask of every claim what would have to be true, what it costs and what it rules out.

## Procedures

- **status:** read the inputs and `{{BOARD}}`; output the north star in a line, when last revised,
  open threads, a count of drift signals, and one recommended mode. Writes only backlog rows.
- **next:** read the backlog and `{{BOARD}}`, check *Triggered* items against `{{LOG}}`. Output in
  ≤12 lines: what waits on `{{OWNER}}` (gates, needs-input, blocked), the top 3 backlog items with
  the command to start each, fired triggers, and one pick. Writes only backlog corrections.
- **explore / challenge / draft:** run the inquiry or proposal, apply what survives to the tree,
  write the session note. Challenge ends in a verdict per claim: holds, revise (applied), open.
- **drift:** compare the vision with `{{LOG}}` (about 60 days), `{{WORK}}`, `{{DECISIONS}}` and
  `{{PROJECT_MAP}}`, in three groups — built against the vision, vision without work, work without
  vision — each with evidence and a suggested action.

## Inputs

Always: `{{ROOT}}`, the latest 2–3 session notes, `{{TREE}}BACKLOG.md`, pages the theme touches,
`{{PROJECT_MAP}}`. When needed: `{{DECISIONS}}`, `{{WORK}}`, `{{LOG}}`, a project's own
`CLAUDE.md` or README to check a claim.

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

## Output format: session note

```markdown
# Vision session — <topic>

- Date: YYYY-MM-DD · Mode: <mode> · Target: <argument or "whole vision">

## Q&A
## Conclusions
## Changes to the vision
## Tensions & open threads
## Actions taken
```

## Closing a session

1. Write the session note (always).
2. Update the backlog.
3. Commit the changed vision files and the note together: `vision: <mode> — <topic>`.
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
description: Keeper of the vision for {{FAMILY}} — what the projects are for together, each one's job, where they head and what they will never become. Modes status, next, explore, challenge, draft, drift.
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
