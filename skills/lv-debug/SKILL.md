---
name: lv-debug
description: "Alias: now /lv-test (manual walkthrough) and /lv-bug. Confirms a completed implementation by hand, and files what fails."
user_invocable: true
model: sonnet
---

# Debug (alias)

This skill was folded into two others (skill audit, LVI-012):

- **Walking through a finished implementation by hand** is `/lv-test <ID>` — the acceptance walkthrough: headless Playwright checks every criterion it can, then you walk what it left.
- **Recording what went wrong** is `/lv-bug`.

If the user gave an ID, do exactly what `.claude/skills/lv-test/SKILL.md` says for that ID. If they described a failure instead, do what `.claude/skills/lv-bug/SKILL.md` says. Otherwise ask which of the two they want. Either way, tell the user once, in one line, which name to use from now on.
