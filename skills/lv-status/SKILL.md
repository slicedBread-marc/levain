---
name: lv-status
description: "Alias: now /lv-tray. Pipeline state, every plan by what it is waiting for, and the ranked next action."
user_invocable: true
model: haiku
---

# lv-status → lv-tray

`/lv-status` has merged into `/lv-tray`, which shows everything it did — the plan-by-plan picture and one ranked next action — alongside workers and gates, with or without the daemon.

1. Tell the user once, in one line: "`/lv-status` is now `/lv-tray`."
2. Read `.claude/skills/lv-tray/SKILL.md` and do exactly what it says for `/lv-tray` with no ID. If the user asked only for the recommendation, show only its `NEXT` block.

Do not follow any older instructions for `/lv-status`; the tray skill is the only source.
