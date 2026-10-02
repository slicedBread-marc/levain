# Directives: steering a plan without editing it

`lv-direct.sh` is how an overseer (the operator, or a coordinator acting for
them) tells the pipeline something about a plan that the plan does not yet say,
and how that instruction, and the decisions humans make at gates, reach the
plans that depend on it. It was added for LVI-033.

## The incident

A client's PLN-026 sat at `spec-approval`. The operator answered it at
`/lv-attend`: drop the allow-list. That answer went into the gate ledger under
`.claude/orchestrator/`, which is untracked and keyed to PLN-026. Minutes
later PLN-028, which depends on PLN-026, was respecced. It was specced against
PLN-026's *draft text*, which still described the allow-list, and it was then
presented for approval.

There were three faults:

1. **No way to steer.** The only thing an operator could do to a plan in flight
   was edit it by hand under a running pipeline, or answer whatever question
   the pipeline happened to ask.
2. **Decisions do not travel.** An answer given on PLN-026 was invisible to a
   worker on PLN-028. Nothing told the worker to look, and it could not have
   found the answer if it had.
3. **Approvals go stale silently.** PLN-028's question did not change when
   PLN-026 did, so a human was asked to approve a plan whose basis had already
   moved.

## Directives

```bash
scripts/lv-exec.sh lv-direct.sh add PLN-026 --kind constraint --text "No allow-list; tenant check only."
scripts/lv-exec.sh lv-direct.sh add PLN-026 --kind replan --text "Split step 4 into a migration plan."
scripts/lv-exec.sh lv-direct.sh add PLN-026 --kind hold --text "Wait for the vendor's answer."
scripts/lv-exec.sh lv-direct.sh add PLN-026 --kind release-hold
scripts/lv-exec.sh lv-direct.sh add PLN-026 --kind constraint --text "…" --supersedes D-1
scripts/lv-exec.sh lv-direct.sh list PLN-026          # live directives
scripts/lv-exec.sh lv-direct.sh status PLN-026        # eval-able counts
scripts/lv-exec.sh lv-direct.sh apply PLN-026 D-2 --sha <commit>
```

Each directive is a numbered section (`D-n`) in `plans/PLN-NNN-<slug>/directives.md`,
committed on develop and so tracked with the plan. It carries the kind, the
author (`operator` or `coordinator:<slug>`), the date, the directive it
supersedes and a status (`open`, `applied <sha> <time>` or `superseded`).

| Kind | Effect |
|-|-|
| `constraint` | Binding input for every worker: `/lv-spec` and its reviewer, `/lv-implement`, `lv-verify`, `/lv-test`, `lv-consistency`. Until `/lv-spec` has applied it, the plan is on the replanning list. |
| `replan` | Same as a constraint. A plan in `ready` also goes back to `draft`. Refused on a plan that is already being built (`active` or later), because by then a replan is a finding, not a directive. |
| `hold` | The dispatcher sends no work at the plan, and `lv-spawn.sh` refuses it (exit 2). |
| `release-hold` | Supersedes the live hold. |

**Who may direct.** Only the operator (`--from operator`, the default) or a
coordinator (`--from coordinator:<slug>`). Under `LV_UNATTENDED=1`, `add`
exits 6: a pipeline worker never directs itself. A `--project` call from a
project that is not `role: coordinator` also exits 6.

**From a coordinator.** `lv-direct.sh add PLN-NNN … --project <name>` resolves
`<name>` from `coordinates:` and runs the target project's own `lv-direct.sh`
through the target's `lv-exec.sh`. The commit lands in the target, written by
the target's harness, the same way filing does
([coordinator.md](coordinator.md)).

**Effects, in order.** First the commit. Then a `replan` on a `ready` plan
returns it to `draft`. Then a `constraint` or `replan` withdraws an open
`spec-approval`, because the question was asked about a plan the directive has
just changed.

## Withdrawal is never an answer

`lv-gate-close.sh <ID> "<why>" --only spec-approval --withdraw` closes a
question as **moot**. The resolved record carries `GATE_WITHDRAWN=true`, and
`lv-gate-status.sh` reports `GATE_ANSWERED=false` and `GATE_WITHDRAWN=true`.
Nothing that reads gates can take a withdrawal as an approval. `/lv-spec`
treats a withdrawn spec-approval as a replan trigger and asks again.

## Plan context: answers travel to dependents

`wf_plan_context` fingerprints what a plan was specced against:

- the body of every plan in its dependency closure;
- the revision-scoped gate answers on each of those plans (withdrawals excluded);
- the plan's own live `constraint` and `replan` directives.

`lv-gate-open.sh` records the fingerprint on every plan gate as
`GATE_PLAN_CONTEXT_AT_OPEN`. `lv-gate-status.sh` compares it with the plan's
current fingerprint:

| Gate | Context moved | Reported |
|-|-|-|
| open | yes | `GATE_QUESTION_STALE=true`, `GATE_PLAN_CONTEXT_STALE=true`, `GATE_PLAN_CONTEXT_CHANGED=<what>` |
| answered | yes | `GATE_ANSWERED=false`, `GATE_STALE=true`: the approval was given against a basis that has moved |

The dispatcher sweeps open `spec-approval` gates before it dispatches anything
(`withdraw_moot_approvals`):

- If a directive moved, it withdraws the gate at once.
- If an upstream plan moved and some plan in the closure is still `draft`, it
  waits and logs `moot` until the upstream settles. Without the wait, every
  revision of the upstream would withdraw the question again.
- Otherwise it withdraws the gate, naming what moved.

`lv-plan-context.sh PLN-NNN` prints all of this for a reader: the plan's own
directives, and each plan in its closure with that plan's state, directives and
decisions of record. It ends with what has moved since this plan's approval was
asked. `/lv-spec`, its reviewer, `lv-consistency` and `/lv-attend` read it
before they read the plans.

A `spec-approval` or `spec-stuck` question also carries a flux note when it is
asked:

- `[upstream still in flux: PLN-026 (draft)]`
- `[unbuilt dependents that move with this answer: PLN-028 (draft, spec-approval open)]`

A human answering it can then see that the plan's basis may still move.

## Consistency at spec-approval

`lv-list-consistency.sh` also lists a `draft` plan that has an open
`spec-approval` and Deps that are not all complete, with the goal prefixed
`at spec-approval —`. The pass then runs **before** a human is asked to approve
the plan, not after. A finding against the plan itself withdraws the question
and writes an unchecked finding. A clean pass leaves the gate open.
`lv-spawn.sh` and the dispatcher let a consistency worker through that one open
gate.
