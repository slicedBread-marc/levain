# [Brief Title]

> **ID:** BRF-NNN
> **schema_version:** 4
> **Status:** Idea | Exploring | Decided | Planned | Parked | Reference
> **Created:** YYYY-MM-DD
> **Plan:** (link to plan once one exists, e.g., PLN-NNN-slug)

<!-- A brief that cannot be converted to a plan yet — blocked on another repo,
     or one that sequences several future plans rather than becoming one — adds
     a `> **Blocked:** <reason>` field to the header above. Write it with
     `lv-brief-block.sh BRF-NNN "<why>" [--on <artifact>] [--repo <name>]` and
     clear it with `--clear`. The brief stays Decided and stops being offered to
     /lv-spec; short of a plan existing, it is the only exit a brief has. -->

<!-- A brief that absorbs open bugs — its plan fixes them, and their own
     designs must not be built — lists them in a `> **Folds:** BUG-NNN, BUG-NNN`
     field in the header above. While the brief is Decided or Planned, only
     those bugs are withheld from /lv-spec, shown as `folded into BRF-NNN`, and
     the brief's plan consumes them with `lv-bug-consume.sh --folded`. Naming a
     bug anywhere else in the brief folds nothing. -->

<!-- A brief nobody is carrying forward is PARKED, not deleted:
     `lv-brief-park.sh BRF-NNN "<why>"` sets Status to Parked, stamps a dated
     reason, and moves its INDEX.md row to `## Parked`. It stops counting as an
     incomplete brainstorm on the board and stays one command away
     (`lv-list-brainstorms.sh --parked`). `--clear` puts it back. -->


## Problem
What's wrong, missing, or desired? Who does it affect?

## Context
Background the planner needs to understand — existing code, prior attempts, constraints.

## Options Considered
### Option A: [name]
- How it works
- Pros
- Cons

### Option B: [name]
- ...

## Decision
Which option (if decided). Why. What tradeoffs are accepted.

## Open Questions
- Things still unresolved that the planner should address or ask about.

## Scope Boundaries
What this does NOT include — helps the planner avoid scope creep.

## References
Links to related briefs, external docs, examples, inspiration.
