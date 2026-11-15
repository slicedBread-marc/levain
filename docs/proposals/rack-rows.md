# Proposal: a rack row says who is holding the work

**Status:** proposal, nothing built. Written 2026-11-14 from a coordinator session.
**Release level:** minor. The grid changes shape, but `lv-tray.sh --fields` keeps every key it
emits today and only gains new ones, so nothing that parses it breaks.
**Build after LVI-048** (the collector/UI split). LVI-048 asks for one pass over `lv-rack.sh`
with no concurrent rack feature work. This proposal changes what the collector emits and what
the UI paints, so it lands on `grid.json`, not on today's single script.
**Absorbs LVI-050** (filed bug intake is invisible; the running cell names no IDs). When this
ships, resolve LVI-050 against it.

## Why

The grid has 17 rows. Most of them count the same item twice, and the one queue that matters
most before a plan exists isn't drawn at all.

The overlap, found by reading `lv-tray.sh`, `lv-list-gates.sh` and `lv-tray-drill.sh`:

| Row | Where the same item already shows |
|-|-|
| `attn` | It is `gates` with IDs. Enter on either opens the same list (`gates\|attn) row_gates`) |
| `draft` | Being specced, it's a worker (`running`). Awaiting approval, it has a `spec-approval` gate (`gates`). Approved, it moves to `ready` at the next dispatch. Only an **escalated** draft ("nothing else moves it") appears nowhere else, and that is a stuck item that belongs in `attn` |
| `acc:man` | It is a plan in `accept` with a `manual-test` gate beside it (`lv-list-gates.sh`, `want="accept testing"`), so it's always in `gates` |
| `active`, `verify`, `acc:auto` | Mostly a worker, so already in `running`. When no worker holds it, it's waiting for the daemon, which no row says plainly |
| `complete`, `abandoned` | Lifetime history. Never an action. 100 in one column tells the operator nothing today |
| `harness` | Identical in every column whenever the portfolio is in sync, which is the normal case |

What is missing: an open bug, or a sealed intake group's carried members, counts on no row
until each is specced into a plan. A client filed eight bugs as one group, and the operator could
not find them on the board while its daemon was working them (LVI-050).

## The rule

**Every open item (an unspecced bug or a plan that isn't terminal) counts on exactly one of
three rows, first match wins:**

1. **running**: a worker or an attended claim holds it.
2. **needs you**: a gate is open on it, or it is stuck with nothing that will move it (an
   escalated draft, a stuck gate, a stale daemon's orphan).
3. **queued**: everything else, i.e. work the machine will reach. That covers open bugs (a
   group's carried members included), drafts waiting for dispatch, `ready`, and
   `active`/`verify`/`testing` with no worker.

`release` and `deploy` sit beside these on a different axis: plans that are done and waiting
to be promoted between branches. They stay separate rows because `t` starts a different skill on
each.

The test that proves the rule is the sum: running + needs you + queued equals the count of
open bugs plus non-terminal plans, per project. A row that double-counts fails it.

## The grid, before and after

```text
BEFORE (17 rows)                         AFTER (9 rows)
  daemon        cooking                    daemon        cooking
  services          1/1                    services          1/1
  running             2                    running       2 121 122
  gates               0                    needs you     -
  attn                -                    queued        6 prep-surface
  ideas               1                    ideas         1
  draft               0                    release       5
  ready               0                    deploy        0
  active              1                    registry      15
  verify              0
  acc:auto            0                  library 15.29.0 · all clients in sync · heal (20)
  acc:man             0
  complete          100
  abandoned           0
  release             5
  deploy              0
  registry           15
  harness       15.29.0
```

### Each row after the change

| Row | Cell | Enter opens |
|-|-|-|
| `daemon` | unchanged: `cooking` / `idle` / `off` / `stale`. **New:** `off` or `stale` turns red when `queued` > 0, which is the skill's "Idle: daemons off with queued work" check made visible | daemon menu (unchanged) |
| `services` | unchanged | services screen (unchanged) |
| `running` | count, then bare IDs (bugs and the plans specced from them share a number), widest first: `2 121 122`; `+RELEASE` as today | the worker list (unchanged) |
| `needs you` | the old `attn` cell: count, then IDs, with `!` `~` `*` and the colours as today. **New:** an escalated draft joins it, marked `!` | gate list (`row_gates`), plus the escalated drafts |
| `queued` | count, then the lead intake group's name when one is open or sealed: `6 prep-surface`. A `⏸` suffix when any are blocked on a dependency | **new** `row_queued`: one line per item, grouped by stage (intake → draft → ready → built, no worker), with group lead first and carried members indented, so the operator can see the queue's order |
| `ideas` | unchanged | unchanged |
| `release`, `deploy` | unchanged | unchanged |
| `registry` | unchanged, but dimmed when `clean` so only a dirty count draws the eye | audit (unchanged) |

**Removed from the grid:** `gates` (merged into `needs you`), `attn` (renamed `needs you`),
`draft`, `ready`, `active`, `verify`, `acc:auto`, `acc:man` (all inside `queued`, `running` or
`needs you`), `complete`, `abandoned` (history: `history` drill and the tray), `harness`.

**Harness moves to the library line.** It reads `all clients in sync` when every column matches,
and otherwise names the out-of-step clients, e.g. `2 clients behind`, and tints those columns'
headers yellow. `U` is unchanged.

## Build

### Phase 1: the tray emits the buckets (`lv-tray.sh --fields`)

- Add `running_ids`: the IDs `running` counts, in the order the cell draws them.
- Add `queued` and `queued_blocked`, computed by the rule above, plus `queued_group`: the name
  of the lead open or sealed intake group (`bugs/groups/*.md`), or empty. Use `lv-list-bugs.sh`
  for intake, which the tray's full view already calls.
- Add escalated drafts to `attn` with a `!` suffix. Today they are reported only in the tray's
  own "stuck" line.
- Keep every existing key. The old per-state counts stay, because `lv-tray.sh --plain` still
  shows the full pipeline. The project-level board is where state detail belongs.
- Test: per fixture project, `running + needs-you + queued` equals open bugs plus non-terminal
  plans. Fixtures cover a draft in each of its four situations, an `accept` plan with its gate,
  a sealed group with carried members, and a blocked `ready` plan.

### Phase 2: the rack paints nine rows (`lv-rack.sh`, collector and UI after LVI-048)

- `ROW_LABELS` becomes `daemon services running needs-you queued ideas release deploy registry` (the gutter draws `needs-you` as `needs you`). It is
  also the drill vocabulary, so the row set and the rows Enter can open stay one list.
- `lv-tray-drill.sh row`: add `needs-you` (→ `row_gates` + escalated drafts) and `queued`
  (→ new `row_queued`). Keep the old metrics (`gates`, `attn`, `draft`, …, `abandoned`) as
  accepted aliases for one minor release, so a saved command doesn't fail, then remove them.
- Move harness into the library line; tint mismatched column headers.
- `daemon` turns red on `off`/`stale` with queued work.
- Update `tests/rack.sh` snapshots for the new grid.

### Phase 3: words

- `skills/lv-rack/SKILL.md` step 2 already reports In progress / Waiting on a human / Ready to
  ship / Idle. Point each at its row (`running`, `needs you`, `release`+`deploy`, red `daemon`),
  and add **Queued**: name a group when one is open, so "where are the tasks I filed" has an
  answer.
- `docs/coordinator.md`: the row table.

## Decided

Self-answered under the pre-launch default; the operator may overturn any of them.

- **`release` and `deploy` stay two rows.** Merging them into one `ship` cell saves a line but
  makes `t` ambiguous about which skill it starts.
- **`ideas` stays.** It is the only row for thinking that never became a decision, and the
  vision process reads it.
- **`complete` leaves the grid entirely**, not to the footer. A lifetime total isn't a signal on
  a board about what to do next.
- **The label is `needs you`, not `gates`.** It says whose move it is, which is the point of the
  whole change. The gutter fits nine characters.

## Not in scope

- The project-level tray (`lv-tray.sh --plain`) keeps its full pipeline section. One project's
  detail belongs there; the rack is for comparing projects.
- Intake group mechanics (`lv-bug-group.sh`, sealing, lead selection) don't change. This only
  draws what they already record.
