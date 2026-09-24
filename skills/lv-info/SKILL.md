---
name: lv-info
description: "Alias: now /lv-tray <ID>. The full history and current status of one plan, bug or brief (PLN-NNN, BUG-NNN, BRF-NNN)."
user_invocable: true
model: haiku
---

# lv-info → lv-tray <ID>

`/lv-info <ID>` has merged into `/lv-tray <ID>`, which shows the same history — and more — for a plan, bug or brief.

1. Tell the user once, in one line: "`/lv-info` is now `/lv-tray <ID>`."
2. If no ID was given, ask: **"Which item? (PLN-NNN, BUG-NNN, or BRF-NNN)"** and wait.
3. Read `.claude/skills/lv-tray/SKILL.md` and do exactly what its **One artifact's history** section says for that ID.

Do not follow any older instructions for `/lv-info`; the tray skill is the only source.
