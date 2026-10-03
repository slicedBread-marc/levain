---
name: lv-debug
description: "Alias: now /lv-accept (manual walkthrough) and /lv-bug. Confirms a completed implementation by hand, and files what fails."
user_invocable: true
model: sonnet
---

# Debug (alias)

This skill was folded into two others (skill audit, LVI-012):

- **Walking through a finished implementation by hand** is `/lv-accept <ID>` — the human half of acceptance (`accept:manual`). `/lv-test <ID>` runs the automated half first and parks the plan in `accept` when a human is needed.
- **Recording what went wrong** is `/lv-bug`.

If the user gave an ID, do exactly what `.claude/skills/lv-accept/SKILL.md` says for that ID — or, if that plan is still in `testing` with no `manual-test` gate open, what `.claude/skills/lv-test/SKILL.md` says. If they described a failure instead, do what `.claude/skills/lv-bug/SKILL.md` says. Otherwise ask which of the two they want. Either way, tell the user once, in one line, which name to use from now on.
