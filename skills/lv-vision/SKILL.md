---
name: lv-vision
description: The overseer's vision — find the owner's vision skill and run it, or interview the owner and write one. Coordinators only.
---

# /lv-vision

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

The third part of the overseer rung (LVI-014). A coordinator oversees several projects; a vision
skill keeps what they are for together, and what comes next. The library ships the contract,
[`docs/vision-spec.md`](../../docs/vision-spec.md) (installed at `.claude/docs/vision-spec.md`), not
a vision — that is the owner's.

## 1. Find the owner's skill

```bash
scripts/lv-exec.sh lv-hook.sh overseer-vision
```

- **Exit 0:** it printed the path of the owner's vision `SKILL.md` (from their pack, or
  `.claude/skills/vision/SKILL.md` here). Read that file in full and follow it, passing on every
  argument you were given (`/lv-vision next` → its `next` mode). You are now that skill; this
  file has nothing more to say. If it is also installed here as `/vision`, tell the owner once
  that `/vision` reaches it directly.
- **Exit 3:** there is none. Go to 2, unless the argument was a mode (`next`, `explore`, …): then
  say there is no vision skill yet and offer `/lv-vision setup`.
- **Anything else:** report the hook's error and stop.

## 2. Set one up (`/lv-vision setup`, or no skill found)

Refuse if step 1 finds a skill: a second one would compete with it. Otherwise:

1. **Read** `.claude/docs/vision-spec.md` in full, then what the coordinator already knows:
   `claude-workflow.yml` (`coordinates:`), `CLAUDE.md`, a project map if there is one, and the
   board (`scripts/lv-exec.sh lv-rack.sh --plain`).
2. **Interview the owner** for every placeholder in the spec's table, one or two questions at a
   time, proposing an answer from what you read wherever you can. Ask above all for the north star
   and the concerns: those decide what the vision is for.
3. **Write the skill:** copy the spec's template (between `vision-template:begin` and `:end`) into
   `.claude/skills/vision/SKILL.md`, every placeholder filled. It sits outside the `lv-` names, so
   no deploy overwrites it.
4. **Write the first vision** with the skill's `draft` procedure: the root, `BACKLOG.md`, and a
   session note recording this interview. Every claim about a project's current state cites a
   source; the rest is marked aspiration.
5. **Check:** `scripts/lv-exec.sh lv-hook.sh overseer-vision` now prints the new file.
6. Commit the skill and the vision together, and tell the owner: `/vision` and `/lv-vision` both
   reach it, and `/vision next` answers "what should I work on?".

A skill kept elsewhere (a private pack shared across machines) is wired the other way: the pack's
`hooks/overseer-vision` prints its path. See `.claude/docs/extension-hooks.md`.

## Usage

```text
/lv-vision                 run the owner's vision skill (its status mode)
/lv-vision <mode> [arg]    run one of its modes: next, explore, challenge, draft, drift
/lv-vision setup           no vision skill yet: interview the owner and write one
/lv-vision help            this block
```
