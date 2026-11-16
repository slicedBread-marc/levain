# Intake groups: bugs that go to spec together

`lv-bug-group.sh` holds a batch of related bugs off `/lv-spec` until the
overseer says the batch is complete, then sends it to spec as one pass.
`lv-list-specable.sh` also pairs a bug with the open bugs that amend it, with
or without a group.

## Why it exists

One overseer conversation filed nine reports into a client inside a few hours
(LVI-024). Later reports corrected earlier ones: BUG-046 reversed the premise
of BUG-041 and BUG-043, and BUG-047/048/049 amended 041/043/046. The spec list
offered all nine as independent rows. By the time the corrections landed,
BUG-041 had become PLN-041, `active` on a feature branch and built against the
superseded model. The operator stopped the whole daemon by hand to hold the
rest. The handoff that followed ("run /lv-spec BUG-046, taking BUG-047 and
BUG-048 with it") was a human sequencing a group the harness could not
represent.

The verbs that already existed did not fit:

| Verb | Why it did not fit |
|-|-|
| `Blocked:` (`lv-brief-block.sh`) | One call per bug, no release-all, and it says "external blocker", not "still being written" |
| `hold` directive (`lv-direct.sh`) | Binds plans, not bugs in `bugs/open/` |
| `--amends` | Linked both bugs, but nothing read the link |
| Stopping the daemon | Stops every other piece of work too |

## The record

`bugs/groups/<slug>.md` is tracked on develop and written only by
`lv-bug-group.sh`. Its header holds Status, Opened, Why, Lead, Sealed, Holds,
and Consumed or Dissolved. A `## Members` list follows. Each member carries
`> **Group:** <slug>` in its own header, and that field is what the spec list
reads.

| Status | What `/lv-spec` is offered |
|-|-|
| `Open` | No member. Each one says on stderr that it is held and gives the seal command |
| `Sealed` | The lead, with the members still open carried in its detail column (`GROUP(<slug>) +BUG-a,BUG-b — spec together`). Other members are withheld while the lead is open or its spec run holds the claim |
| `Dissolved` | Each member as an independent bug. Their Group field is cleared |
| `Consumed` | Each remaining member as an independent bug. The lead's plan is recorded |

## Lifecycle

```bash
lv-bug-group.sh open she-wrote "BUG-046 reshapes 041/043"
lv-bug-group.sh add  she-wrote BUG-042 BUG-043 BUG-046 BUG-047 BUG-048
lv-bug-group.sh seal she-wrote [--lead BUG-046]
# /lv-spec takes the lead, decides every member, then:
lv-bug-group.sh consume she-wrote PLN-046
```

You can also file straight into a group: `lv-bug-new.sh --group <slug>` or
`lv-dep-notify.sh --group <slug>`. Either one opens the group if it does not
exist. A bug filed with `--links "Amends BUG-NNN"` joins BUG-NNN's Open group
without being told. Otherwise the correction would be the one member of the
batch offered on its own.

**The default lead** is the lowest-numbered open member that amends no other
member. That is the premise the rest are written against. If the members amend
each other in a ring, the lowest number is the lead. `--lead` overrides the
default.

**A member already in a plan.** Adding a bug that is already triaged into a
`draft` or `ready` plan places a `hold` directive on that plan, and seal
releases it. If the plan is `active` or later, the add is refused (exit 4). A
built plan changes only through a new plan with `Deps` on it, the same rule
`lv-direct.sh replan` follows. Leave that bug out of the group. The member that
changes its premise becomes the new plan.

**Finishing a group.** `consume` is refused (exit 2) while any member is still
in `bugs/open/`. The spec run that takes the lead decides how each member
leaves:

- folded into the lead's plan (`lv-bug-consume.sh --folded`)
- an amendment to a `draft`/`ready` plan (`--amends`)
- closed as superseded (`lv-bug-close.sh --superseded-by`)
- left for its own plan with `Deps` on the lead's

In the last case the lead's run records it with
`lv-bug-group.sh leave <slug> BUG-a --after PLN-L "<why>"`, which writes
`- BUG-a after PLN-L — <why>` under the group's `## Left for their own plans`
section and commits it. That line is the marker every script reads; the
Design Decision that says the same thing is for people. With it:

- `consume` passes while the member is still in `bugs/open/`;
- `lv-bug-consume.sh` refuses (exit 2) to fold, amend or consume the member
  into PLN-L, the plan it was left after; its own plan consumes it as usual;
- once the group is Consumed, `lv-bug-consume.sh` and `lv-plan-id.sh` treat
  it as independent, and the spec list offers it with
  `GROUP(<slug>) left for its own plan: Deps PLN-L`.

`leave` is a worker's, like `consume`. It refuses (exit 2) the lead, a member
not in `bugs/open/`, a group that is not Sealed, and an `--after` naming no
plan. Before it existed the decision was only prose: `consume` refused, the
group stayed Sealed, and `lv-plan-id.sh` withheld the member as carried with
the lead whenever anyone held the lead's number. See
`skills/lv-spec/SKILL.md`, Plan from bug step 1b (a client's LVI-005).

## A bug grouped after its spec run started

The spec list is read once, at dispatch. In a client's LVI-026 the daemon
spawned a spec worker on BUG-053 at 00:47:24Z. A coordinator grouped BUG-053
48 seconds later, and the worker drafted and triaged PLN-053 at 00:52. The
overseer had meant BUG-053 to lead the group, and `seal --lead BUG-053` was
refused because the bug was no longer open.

Three places now read the group again after dispatch:

| Where | What happens |
|-|-|
| `lv-plan-id.sh` (asked at spec step 3, and again just before the folder is written) | Exit 4 with `PLAN_ID` empty and `PLAN_ID_HELD` giving the reason. The worker writes nothing, unclaims and stops |
| `lv-bug-consume.sh` (triage) | Exit 3 for a member of an Open group, in every mode. Nothing moves |
| `lv-bug-group.sh add` | Says when a spec run holds the bug's claim. If that run has already registered a plan drafted from the bug, the add holds that plan, so the daemon does not respec it alone |

`wf_group_withholds` in `lv-orch-lib.sh` is the rule `lv-plan-id.sh` asks.
It withholds a member of an Open group, and a member of a Sealed group whose
lead is still open or being specced: claimed while no plan of its number has
got past `draft`. Claims key on the number, so the claim a tester holds on the
lead's plan in `testing` is not a spec run, and counting it made
`lv-plan-id.sh` say go at one step and stop at the next (LVI-005). It also withholds every member of a group
sealed onto a lead plan, because those members amend that plan.

**Sealing onto a lead that was already specced.** `seal --lead` may name a
member already triaged into a plan still in `draft` or `ready`. That plan
keeps a hold, and the group records it as `Lead plan`. The holds on other
members' plans are released. The spec list then offers the lowest-numbered
open member, carrying the rest:
`GROUP(<slug>) lead BUG-L is PLN-MMM draft: amend it with this +BUG-a`. That
run amends PLN-MMM with each member (step 2b) and runs
`consume <slug> PLN-MMM`. `consume` releases any hold the group still has
placed, in the sealer's name, because its condition has just been met: no
member is left in `bugs/open/`. A lead whose plan is `active` or later is
refused, because a built plan is never amended.

## Who may write one

`open`, `add`, `remove`, `seal` and `dissolve` belong to the overseer: the
operator at a terminal in the project, or a coordinator through `--project`.
`--project` runs the target's own `lv-bug-group.sh` through its own
`lv-exec.sh`, and the target records the author as `coordinator:<slug>`. Under
`LV_UNATTENDED=1` these commands refuse (exit 6). A worker that could seal its
own group could release its own hold.

`consume` belongs to the worker, because `/lv-spec` is what finishes a group.
`list`, `show` and `of` only read.

## Amendment pairs without a group

Outside any live group, `lv-list-specable.sh` reads `Amends BUG-NNN` in each
open bug's Links:

- If the target is still open, the amender is withheld and carried by the
  target (`+BUG-a (amending it) — spec together`). A chain such as 050 → 049 →
  046 resolves to its root.
- If the target's spec run holds the claim, the amender is withheld until that
  run ends.
- If the target was already consumed, the amender is offered alone. Its detail
  names the target's plan and state: `amendment (step 2b)` for a `draft` or
  `ready` plan, and `new plan with Deps PLN-NNN` for one already built.

## Forgotten groups

An Open group holds its members indefinitely, and they appear in no worklist.
Two places surface it:

- `/lv-tray` lists every unfinished group under "intake groups".
- `lv-bug-group.sh list --stale` lists Open groups older than
  `bugs.groupStaleAfter` hours (default 24). `/lv-attend` runs it and asks the
  human to seal or dissolve each one.

## Not built

The issue also proposed an optional quiet period (`intake.quietPeriod`): don't
offer a cross-project bug until some time has passed since the newest bug
from the same source. It would catch a batch filed without `--group`. It is
not built. File with `--group` instead.
