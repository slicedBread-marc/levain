# The prompt contract

Every `skills/*/SKILL.md` in this repo is a **prompt that runs unattended**. It is not advice
to a human and not the opening line of a conversation: the orchestrator dispatches it by
registry state, at a plan it picked, in a worktree nobody is watching, against a repository
nine clients share. Whatever the prompt leaves unsaid, the model decides — once, differently
each time, holding a claim and a commit bit.

So a prompt here is a contract with the same standing as `docs/guard-ordering.md` or the
schema, and this file is the contract it is written against. New skills are authored to it;
existing skills are reviewed against it.

**A prompt satisfies this contract when an agent that knows nothing but the prompt and the
repository can start the work, finish it, and hand it back — without asking a question,
without guessing, and without leaving anything running.**

Each clause below is a requirement, a reason, and the shape of the failure when it is missing.
Most of them are here because the failure already happened; those carry the WFI number.

---

## 1. Role — a position, not a personality

**Open with one sentence in the second person saying what the agent is, what dispatched it,
and what it owns.** It goes immediately after the `#` heading, before any other section.

A role is a position in a system, not a character. "You are a careful senior engineer" tells
the model nothing it can act on. `wf-verify`'s "You are the **autonomous verify agent**. You
are triggered automatically when a plan's REGISTRY state changes to `verify`" tells it three
things it will need: its identity for the log, the fact that no human typed anything, and the
state it is allowed to be running in.

The role sentence is also the scope fence. `wf-claim`'s "You do not read plans, edit files, or
move pipeline state" is one clause long and prevents an entire class of overreach.

**Fails as:** a skill that opens on its first procedural section. The agent infers its role
from the steps, and an inferred role has no boundary — everything adjacent to the work looks
in scope.

## 2. Goal — a done-condition, not an activity

**State the terminal condition, as a list of facts that must be true when the agent stops.**

"Check the implementation" is an activity, and an activity has no end. "`findings.md` written,
the plan moved out of `verify`, the claim released" is a done-condition, and an agent can tell
whether it has reached it. Where order matters between them, give the order.

Say what the empty case is, explicitly: *an empty findings section is a result, and must be
written as one*. An unstated empty case is where an agent does nothing and reports success.

**Fails as:** WFI-012. A `wf-verify` worker exited rc=0 after six minutes having written two
lines, the second of which was "Waiting for the background test run to complete." It was still
waiting. `findings.md` was never written, REGISTRY still read `verify`, and the plan sat in a
state whose only owner had just exited.

## 3. Operating mode — say whether anyone is reading

**Declare attended, unattended, or both, and if both, what switches between them.**

The mode changes the correct answer to every other question in the prompt. An unattended agent
that asks hangs the pipeline; an attended one that guesses corrupts state that a human thought
they were supervising. Skills that can run either way say so and name the switch
(`WF_UNATTENDED=1`); skills that cannot say that too — `wf-verify`'s "this skill is **always**
unattended … `WF_UNATTENDED=1` changes nothing here" closes off a question the reader would
otherwise have to answer by inference.

**Fails as:** a prompt with interactive prose ("ask the user which option they prefer") that
the dispatcher runs at 3am.

## 4. Inputs — name the source of truth and the command that reads it

**Every fact the agent acts on comes from a command in the prompt, never from memory, never
from the conversation.**

Write `eval "$(scripts/wf-exec.sh wf-plan-info.sh PLN-NNN)"`, not "the plan you are working
on". Sessions get compacted, workers get dispatched with almost no context, and a prompt that
assumes recall produces an agent that invents state confidently.

Where a value does not survive to the next step, say so. `wf-verify` spends a blockquote on
exactly that — `$PLAN_*` are placeholders, every Bash call is a fresh shell — because the
alternative is WFI-107, where an unset `$PLAN_NAME` claimed the empty string and printed a
usage error that reads like a rejected plan name.

**Fails as:** an agent that is confidently working the wrong plan, or the right plan in the
wrong state.

## 5. Authority — two lists: what it writes, what it only reports

**Name what the agent may change and what belongs to somebody else.**

This is the highest-value guardrail in the file, because a capable model asked to find
problems will fix them. `wf-verify` draws the line precisely: if the spec is wrong the finding
is `ESCALATED` and goes to the planner; if the code does not match a correct spec, it is the
implementer's. Neither is the verifier's to fix.

Include the out-of-scope rule, since "I noticed something else" is the most common way an
agent leaves its lane: out of scope and security-relevant → flag it and file it independently;
out of scope and not → leave it out.

**Fails as:** scope creep with commit access — a verify worker that "helpfully" rewrites the
spec it was meant to report on, and a plan whose findings no longer describe what shipped.

## 6. Procedure — ordered, imperative, with the load-bearing order justified

**Numbered steps, each with the command to run. Where the order is a contract, say why, or
point at the doc that does.**

An ordering rule with no reason attached gets improved away by the next agent or author who
reads it and sees redundancy. "Commit the state transition, then close the gate, then unclaim"
survives because `docs/guard-ordering.md` explains the two-second window that WFI-079 opened
when it was done backwards — a false gate that blocked a plan from being dispatched at all.

A prompt may point at a doc for depth, but it must carry the contract itself. The pointer
needs a reason to be followed, not just a path.

**Fails as:** a correct-looking reordering that opens a race nobody can see in the diff.

## 7. A decision table for foreseeable ambiguity

**Enumerate the situations where the agent would otherwise have to choose, and choose for it.**

This is the single most load-bearing structure in the strong skills here, and the one most
often missing elsewhere. The columns that work:

| Where | Situation | Mode | Behavior |
|-|-|-|-|

*Where* anchors it to a point in the procedure, so the agent finds the row when it is actually
stuck. *Mode* is `[AUTO]` or `[GATE]`. *Behavior* is what to do, not a consideration to weigh.

Each row should be a real observed ambiguity. WFI-196 is one: a Tests-table command that ran
**zero tests** and exited 0. Without a row, that is a pass. With one, it is a `**Spec**`
finding, escalated, naming the row — because only the planner can fix it.

"Use your judgment" is not a row. Judgment is variable by construction, and the table exists
precisely to spend it only where nothing cheaper will do.

**Fails as:** an agent that resolves the same ambiguity differently on every run, so the
pipeline's behavior is unreproducible and its bugs are unfileable.

## 8. One catch-all escalation, and it is a command

**State what to do with everything the table does not cover, as a runnable command with a
destination.**

`wf-verify`'s is two sentences: "Never guess. Anything not covered above is a [GATE] with gate
name `needs-input`" — plus the invocation, `wf-gate-open.sh <ID> needs-input "<question>"
--skill wf-verify`. The gate parks the work, the question reaches a human through `/wf-attend`,
and the agent exits cleanly holding nothing.

"Ask the user if unsure" is not an escalation path in an unattended system. There is no user.

**Fails as:** a guess, made silently, that the pipeline then treats as a decision.

## 9. Guardrails carry the incident that produced them

**Write each prohibition with the failure that earned it: what happened, what it looked like,
and the WFI number.**

"Never background a test run" is a rule a capable model will reason its way around when it
seems inefficient. The same rule with WFI-012 attached — six minutes, two lines, nothing
written, plan stranded — is one it will not. The narrative is not decoration; it is what makes
the rule survive contact with a model that thinks it has a better idea.

This is negative few-shot, and it is more informative than a success example, because the
model already knows what success looks like. It does not know your failure modes.

**Fails as:** a `never` that reads as a default, and gets optimized away in the moment.

## 10. Output contract — shape, destination, and the empty case

**Say what the agent writes, in what structure, to which path — and what it writes when there
is nothing to report.**

Where the output is consumed by a script rather than a human, say so and say which script.
`wf-verify` does: "Routing is not a judgment call. `wf-findings-route.sh` decides the exit
state from what you wrote in `findings.md`; write the findings honestly and let it route."
That sentence converts a routing decision into an honest-reporting problem, which is the kind
of problem a model is actually good at.

**Fails as:** output a downstream script cannot parse, or a silent no-op that looks like
a clean pass.

## 11. Environment hazards, indexed by what the agent will see

**List the failures the model cannot deduce, each with its symptom first, then cause, then the
one-line fix.**

Three live examples, all of which cost real time before they were written down:

- `fatal: .git/index: index file open failed: Not a directory` — leaked `GIT_INDEX_FILE` from
  the launching hook, in a linked worktree where `.git` is a file (WFI-071). Looks like a
  corrupt repository and is nothing of the kind.
- A test suite that hangs with no failure and no output — stdin is not at EOF, so a test
  reading from it blocks forever. `< /dev/null` on every build and test command. Two 10-minute
  timeouts became 0.8 seconds (WFI-240).
- A runner that prints "Zero tests ran" and exits **0** (WFI-196).

Index by symptom, because the symptom is the only handle the agent has when it is stuck.

**Fails as:** an agent that diagnoses a solved problem from scratch, badly, and files a bug
about the wrong thing.

## 12. Evidence rules — how a check can look like it passed

**Name the specific ways success can be counterfeit, and rule on each.**

A model's default is to treat exit 0 as truth. Say otherwise where it matters: zero tests ran
is never a pass whatever it exited with; an unrunnable check is a *result*, recorded with the
command and its output verbatim, not a blocker.

And give the partial-failure rule as a first-class outcome rather than leaving it to the
catch-all. `wf-verify`'s is one line and does the whole job: routing on incomplete evidence is
recoverable; exiting on none is not.

**Fails as:** a green pipeline over a suite that never ran.

## 13. Assume reasonably — then validate the end state against the goal

**Give the agent permission to choose a sensible reading and proceed, and require it to
check the result against clause 2 before it stops.**

Two halves, and the first is a counterweight to clause 8.

**Assume reasonably.** "Never guess" governs *state and authority* — what the registry says,
what the agent may change, whose finding this is. It does not govern *method*. A prompt that
routes every ambiguity to a gate is as broken as one that guesses at all of them, because a
gate costs a human and the pipeline stalls until one arrives. Where several readings all
arrive at the same place, the agent picks one and continues. Say which kind of ambiguity is
which, and where the assumption is load-bearing, require it recorded — in `findings.md`, in a
plan's Amendments, in the gate question — so it can be audited later instead of reconstructed.

**Then validate against the goal.** Before exit, the agent re-reads the done-condition and
compares it against what is *now actually true* — not against the list of steps it performed.
Those are different checks, and only the second one catches a procedure that ran to completion
and produced the wrong end state. A mismatch is the agent's remaining work, or its finding; it
is not something to leave for the next gate to discover.

This closes the loop the other twelve clauses open. Clause 2 states the goal; this one spends
it. Without it a prompt can be fully compliant and still hand back an artifact nobody checked,
which is how a completed step list and a broken outcome end up looking identical from outside.

**Fails as:** every step green, the end state wrong, discovered two gates downstream — or
never, because everything that would have noticed was reading the step list too. Its opposite
failure is an agent that gates on everything and turns the human into the scheduler, which is
the condition the harness exists to remove.

---

## Three principles that cut across all thirteen

**Determinism belongs in bash, not in the prompt.** Every decision expressible as a script
should be one, and the prompt's job shrinks to producing honest input to it. Routing, ID
allocation, scope filtering, approval checks — all of these are code here, and none of them
vary between runs. Judgment is the expensive and variable part; the contract's purpose is to
spend it only where nothing else will do.

**Progressive disclosure, with a reason to follow the pointer.** The prompt carries the
contract; `docs/` carries the depth. A pointer needs to say what it protects — "the flip's
position relative to the dispatcher replacement is load-bearing" — or it does not get
followed. Watch total length: a prompt long enough that the middle gets skimmed has lost the
guarantees in the middle, whatever they say.

**Imperative for rules, prose for rationale, and don't mix them.** Requirements read as
commands; the incident that motivated them reads as narrative. A requirement phrased as a
story gets treated as context.

---

## The authoring checklist

Run down this list before committing a new or edited `SKILL.md`:

1. Does the first sentence after the `#` say what the agent is and what dispatched it?
2. Is there a scope fence — something it explicitly does **not** do?
3. Is the goal a list of facts that must be true at exit, in order where order matters?
4. Is the empty case written down?
5. Is the operating mode declared, with its switch?
6. Does every input come from a named command rather than from memory?
7. Is it clear which findings the agent fixes and which it reports?
8. Are the steps numbered and imperative, with load-bearing order justified or linked?
9. Is there a decision table, and is every row a real ambiguity with a behavior, not a
   consideration?
10. Is there exactly one catch-all, and is it a runnable command?
11. Does every `never` carry its incident?
12. Is the output's shape, path and consumer named?
13. Are the environment hazards indexed by symptom?
14. Is there a rule for a check that cannot run, and one for partial failure?
15. Could the agent reach a state where it stops with something still running?
16. Is the agent told where to assume and proceed, rather than routing every ambiguity to a
    gate — and told to record the assumptions that mattered?
17. Does anything require it to compare the end state against the goal before it stops?

Questions 15 and 17 are the ones to answer last and hardest. It is the failure that leaves the pipeline
stuck rather than wrong, and stuck is worse: a wrong result gets found by the next gate, and a
stranded plan waits for a human to notice.

## Reviewing an existing skill against this

Read it once as the agent would — top to bottom, with no context — and stop at the first place
you would have to make something up. That place is the finding. Prompts fail at the first
ambiguity, not the worst one, so the order matters more than the severity.

The clauses are not equally cheap to violate. In rough order of what it costs when it is
missing:

| Clause | Cost of omission |
|-|-|
| 2 Goal / done-condition | Plan stranded in a state with no owner |
| 8 Catch-all escalation | Silent guess, treated downstream as a decision |
| 13 Validate against goal | Every step green, end state wrong, found late or never |
| 5 Authority | Scope creep with commit access |
| 12 Evidence rules | Green pipeline over a suite that never ran |
| 6 Procedure order | Race opened by a plausible-looking reorder |
| 3 Operating mode | Unattended worker asks a question, hangs |
| 7 Decision table | Unreproducible behavior, unfileable bugs |
| 10 Output contract | Downstream script cannot route |
| 4 Inputs | Confident work on the wrong artifact |
| 1 Role | Boundaryless scope |
| 11 Hazards | Re-diagnosing a solved problem |
| 9 Incident narratives | Rules that erode over time |

## What this contract deliberately does not say

It does not set a house style, a length, or a section order. `wf-claim` is 60 lines and
complete; `wf-test` is over a thousand and needs to be. What it requires is that the twelve
things are *findable* — not that they appear as thirteen headings.

It also does not cover the client-facing `templates/WORKFLOW.md`, which is a different
document with a different reader: an agent that has landed in a client repo cold and needs the
map, not the job.
