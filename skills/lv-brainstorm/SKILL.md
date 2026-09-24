---
name: lv-brainstorm
description: Capture and explore ideas. Creates or updates briefs in plans/briefs/. Use when the user wants to brainstorm, explore an idea, or add to the backlog.
user_invocable: true
model: haiku
---

# Brainstorm Role

**`help` / `--help`:** if that is the whole argument, print the `## Usage` block at the end of this file verbatim and stop.

You are in **brainstorm mode**. Your job is to capture ideas, explore options, and help the user think through problems — NOT to write implementation steps or edit source code.

## What you do

1. **Assign a brief ID** — when the user describes something they want to build or change:
   ```bash
   new_id=$(scripts/lv-exec.sh lv-counter-next.sh BRF)
   ```
   This reads the counter, prints the prefixed ID (e.g., `BRF-021`), and increments. Create a brief in `plans/briefs/$new_id-<name>.md` following `plans/briefs/TEMPLATE.md`. New briefs must include `schema_version: 4` in their header.

   **Add its INDEX.md row in the same edit — never "later".** A brief file with no row in `plans/briefs/INDEX.md` is invisible: it is not in the backlog you display on startup, not in the board's brainstorm count, and not in anything `/lv-spec` reads. client-e accumulated 19 of them. The row is `- [<file>.md](<file>.md) — <one-line description>` under the section matching the brief's status.
2. **Capture ideas** — fill in Problem, Rationale, and initial approach from the conversation
3. **Explore options** — help the user think through tradeoffs, list alternatives, surface risks
4. **Track status** — set the brief status appropriately:
   - `Idea` — just captured, no exploration yet
   - `Exploring` — actively discussing options
   - `Decided` — user has confirmed an approach, ready for planning
   - `Parked` — nobody is carrying it forward. Never set this by hand: `scripts/lv-exec.sh lv-brief-park.sh BRF-NNN "<why>"` stamps the dated reason and moves the INDEX.md row, and `--clear` reverses it. Offer it when the user says an idea is dead, superseded, or "not now" — a parked brief stops counting as an incomplete brainstorm while staying on the record.
5. **Maintain the index** — after creating or updating any brief, update `plans/briefs/INDEX.md` to reflect the current state. Move items between sections as their status changes. `Planned` is a waypoint, not a resting place: once a brief's plan reaches `complete` in `plans/REGISTRY.md` (check with `grep`), **remove that brief's entry from INDEX.md** rather than leaving it under `Planned` — a brief with a shipped plan is not backlog, and `Planned` filling up with terminal entries buries anything still live under it (client-c WFI-028). The brief file itself and `plans/REGISTRY.md` keep the historical record; INDEX.md only needs to reflect what is still ahead.
6. **Commit** — when done exploring or deciding, commit changes:
   ```
   scripts/lv-exec.sh lv-commit.sh "brainstorm: BRF-NNN-<brief-name> — <Idea|Exploring|Decided>" --add plans/briefs/
   ```

## Rules

- **Do NOT** edit source code files (src/,tests/)
- **Do NOT** write implementation steps — that's the planner's job
- **Do NOT** make decisions for the user — present options and let them choose
- Briefs are living documents — rewrite freely until status is `Decided`
- When a brief reaches `Decided`, it becomes input for a `/lv-spec` session
- When a brief reaches `Planned`, add the plan link and move it in the index
- When that plan reaches `complete`, remove the brief's entry from the index — `Planned` holds work waiting to ship, not a shipped history
- Every brief has a row in INDEX.md from the moment it exists — creating one without a row is the one mistake in this skill nothing downstream can recover from
- An idea nobody will pick up gets **parked**, not left at `Exploring` forever — `lv-brief-park.sh` — and never deleted
- Quick ideas can start as lightweight entries (just Problem + a few sentences); they don't need every template section filled in immediately

## On startup

Run these three commands in parallel before reading further:
```bash
scripts/lv-exec.sh lv-branch-check.sh develop
```
```bash
cat plans/briefs/INDEX.md
```
```bash
scripts/lv-exec.sh lv-list-brainstorms.sh --drift
```

If branch check exits 1, stop and tell the user: "This skill must run on `develop`. Run `git checkout develop` first."

Display the current backlog from INDEX.md as a summary table. Then tell the user: "Run `/model sonnet`, then describe what you'd like to explore or create."

If `--drift` listed anything, those brief files exist with no row in INDEX.md — invisible to the backlog above and to every other surface. Say how many, and offer the repair once: `scripts/lv-exec.sh lv-brainstorm-reindex.sh` (dry run) then `--apply`. Don't run it unasked — it writes to the user's backlog.

## Committing work

After creating or updating a brief, commit:
```
scripts/lv-exec.sh lv-commit.sh "brainstorm: <brief-name> — <Idea|Exploring|Decided>" --add plans/briefs/
```

## Usage

```text
/lv-brainstorm          show the backlog, then capture or explore an idea
/lv-brainstorm <idea>   start straight on that idea (a new or existing brief)
```
