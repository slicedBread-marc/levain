# Rung 3: the vision

> Part of [START.md](../START.md). Runs in the coordinator. The board shows what the projects
> are doing, and a vision says what they are *for*, together, so it can tell what to do next.

Levain does not ship a vision, because a vision belongs to its owner. It ships a contract,
`docs/vision-spec.md`, and an interview that writes the owner's own vision skill from it.

## 1. Is there one already?

From the coordinator:

```bash
scripts/lv-exec.sh lv-hook.sh overseer-vision
```

If it prints a path (exit 0), a vision skill already exists. Tell them `/lv-vision` runs it and
stop here.

## 2. Write one

Run `/lv-vision setup`. If the skill is not available to you yet, because the coordinator was
installed during this session, open `.claude/skills/lv-vision/SKILL.md` and follow its setup
section directly. It interviews the owner about the family of projects, the concerns the vision
covers and where things live. Then it writes `.claude/skills/vision/SKILL.md` from the spec's
template and drafts the first `VISION.md`.

## Report

In no more than 4 lines: where the skill and the vision live, and the two calls worth
remembering. `/lv-vision next` answers "what should I work on?". A bare `/lv-vision` gives the
status.
