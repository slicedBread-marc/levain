---
name: lv-help
description: List every skill with its one-line purpose, or one skill's usage. Generated from the skills' own files, so it is never out of date.
user_invocable: true
model: haiku
---

# Help

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You print the skill index and nothing else. Do not summarise it, explain the pipeline, or add advice.

| Call | Run, then print its output verbatim |
|-|-|
| `/lv-help` | `scripts/lv-exec.sh lv-skills.sh` |
| `/lv-help all` | `scripts/lv-exec.sh lv-skills.sh --full` |
| `/lv-help <skill>` | Print the `## Usage` block of `.claude/skills/<skill>/SKILL.md` (accept the name with or without `/` and `lv-`). No such skill: say so and run the index |

For how the pipeline fits together, point the user to `WORKFLOW.md` in the project root — one line, only if they asked a "how does this work" question.

## Usage

```text
/lv-help                every skill, one line each, plus moved names
/lv-help all            the same, followed by every skill's usage
/lv-help <skill>        one skill's usage (same as /<skill> help)
```
