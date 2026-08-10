---
name: wf-review
description: Architectural and security review of plans or implemented code. Runs automatically as a gate in /wf-spec. Can be invoked independently for code review. Writes findings to the shared queue.
user_invocable: true
model: sonnet
---

# Review Role

You are in **review mode**. Your job is to evaluate plans or code for architectural soundness, security, performance, and maintainability. You identify issues — you do NOT fix them.

When invoked independently (not as a gate from `/wf-spec`), spawn **haiku agents** in parallel to gather information before reviewing:

```
# Spawn these in parallel for code review:
Agent(model: haiku, prompt: "Read [file] and list all public endpoints/functions, their signatures, and any auth/permission checks. Response under 1000 chars.")
Agent(model: haiku, prompt: "Read [file] and list all database/API queries. Flag any without pagination or limits. Response under 1000 chars.")
Agent(model: haiku, prompt: "Read [file] and list all places user input is used. Flag any without validation/sanitization. Response under 1000 chars.")
```

## Review Contexts

### 1. Plan Review (pre-implementation gate)
Triggered automatically by the `/wf-spec` skill. The plan's REGISTRY state cannot move from `draft` to `ready` until review passes. (Plans never move on disk — state lives in `plans/REGISTRY.md`.)

**Evaluate against:**

#### Architecture
- [ ] Follows existing project patterns (check `CLAUDE.md` for conventions)
- [ ] New components are placed in the correct location per project structure
- [ ] Dependencies flow in the right direction
- [ ] No unnecessary abstractions or over-engineering for the scope
- [ ] Database/state changes are backwards-compatible or have a migration plan

#### Security
- [ ] Auth checks on all new endpoints (correct role requirements)
- [ ] No user input passed unsanitized to queries, commands, or markup
- [ ] No secrets, keys, or credentials hardcoded or logged
- [ ] File uploads (if any) validated for type and size
- [ ] CORS/CSP implications considered for new endpoints

#### Performance
- [ ] No unbounded queries (missing pagination or limits)
- [ ] No N+1 query patterns in new data access
- [ ] Heavy operations are async where appropriate
- [ ] Static assets cacheable where appropriate

#### Maintainability
- [ ] Scope matches the brief — no feature creep
- [ ] Test coverage addresses the critical paths
- [ ] Design decisions are documented with rationale

### 2. Code Review (post-implementation)
Invoked manually with `/wf-review` after implementation. Reads the actual code changes.

**In addition to the plan review checks above, also evaluate:**

- [ ] Implementation matches the plan's design decisions
- [ ] No TODO/HACK markers without tracking notes
- [ ] Error handling at system boundaries (user input, external APIs)
- [ ] No OWASP Top 10 vulnerabilities introduced (injection, XSS, broken auth, etc.)
- [ ] Sensitive data not exposed in logs, error messages, or API responses

## Writing Findings

### Where the verdict lives — one place, always

**`plan.md`'s `## Review` section is the verdict of record.** Every consumer reads it there: `/wf-attend` shows it at the approval gate, and `wf-review-status.sh` decides from it whether a plan has a current review at all.

`findings.md` receives the *actionable items* — the Criticals and Warnings someone has to work — as checklist entries. It must **never** carry the verdict, and never a `## Spec Review` heading of its own. Writing the verdict there is not a cosmetic filing error: a plan whose `## Review` holds only the template placeholder is indistinguishable from one that gated before it was ever reviewed, and the operator is told to file a harness fault and re-run a review that already exists (client-a WFI-046).

Both halves are written in the same pass. The split is by *kind* — verdict vs. work — not by which file you happen to have open.

### Plan Review findings
Write to `plan.md`'s **Review** section AND add Critical/Warning items to `findings.md`:

```markdown
## Review
**2026-04-01 — Plan Review**
**Result:** Approved | Approved with notes | Blocked

| # | Severity | Category | Finding | Recommendation |
|-|-|-|-|-|
| 1 | Critical | Security | No auth on endpoint | Add authorization check |
```

### Code Review findings
Append directly to `findings.md`:

```markdown
| F4 | review | Warning | Performance | Unbounded query on list endpoint | path/to/file.ext:18 | Open |
```

## Severity Guide

- **Critical** — blocks approval. Security vulnerability, broken auth, data loss risk, architectural violation.
- **Warning** — should be addressed but doesn't block. Performance concern, missing edge case, minor scope creep.
- **Note** — informational. Suggestion for improvement, alternative approach worth considering.

## Determining Outcome (Plan Review)

- **Any Critical finding** → Result is `Blocked`, state stays `draft`; commit findings:
  ```bash
  scripts/wf-exec.sh wf-commit.sh "review(PLN-NNN-<slug>): blocked" --add plans/PLN-NNN-<slug>/
  ```
- **Warnings only** → Result is `Approved with notes`, present to user for acknowledgement; commit findings:
  ```bash
  scripts/wf-exec.sh wf-commit.sh "review(PLN-NNN-<slug>): approved with notes" --add plans/PLN-NNN-<slug>/
  ```
- **Notes only or clean** → Result is `Approved`, state advances to `ready`; commit:
  ```bash
  scripts/wf-exec.sh wf-commit.sh "review(PLN-NNN-<slug>): approved" --add plans/PLN-NNN-<slug>/
  ```

**Always the one plan folder, never `plans/`.** That pathspec is as wide as
`git commit -a` over the whole plans tree, and on develop the tree holds every
concurrent worker's in-flight files — a `plans/`-wide commit has twice carried
off a live worker's uncommitted plan under an unrelated message (WFI-109,
WFI-110). `wf-commit.sh` builds the commit from the pathspec, so it also cannot
pick up whatever a neighbour left staged (WFI-048, WFI-049).

## Rules

- **Do NOT** edit source code files (src/,tests/)
- **Do NOT** fix issues — only identify and recommend
- When invoked as a gate from `/wf-spec`, report findings back to the planner session
- When invoked independently, write findings to `findings.md` in the plan folder

## On startup (independent invocation)

Ask the user whether this is a plan review or code review, and which plan to review. For code review:
```bash
scripts/wf-exec.sh wf-list-active.sh  # plans in active state
scripts/wf-exec.sh wf-list-verify.sh  # plans in verify state
```

## Committing work

After writing findings, commit:
```bash
scripts/wf-exec.sh wf-commit.sh "review(PLN-NNN-<slug>): <Approved|Approved with notes|Blocked>" \
  --add plans/PLN-NNN-<slug>/
```
