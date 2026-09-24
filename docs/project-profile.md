# Project profile

**Status:** ships with no default tier. `lv-profile.sh --show` refuses until one
is declared.

Answers a pattern that showed up tuning five clients by hand in one session:
`specApproval.mode`, `manualTestGate`, and `orchestrator.autonomy` each get
decided project-by-project, from scratch, in conversation — and the reasoning
("this one has no real users yet") lives only in that conversation and evaporates
at the next session boundary, same shape as the gap `lv-autonomy.sh` closed for
standing release/deploy authorization.

---

## The one rule

`projectProfile` is a **recorded stance, not a runtime switch.** Nothing in the
pipeline reads `projectProfile.tier` to silently change gate behavior — every
gate still runs on `specApproval.mode`, `manualTestGate`, and
`orchestrator.autonomy` exactly as it always has, read directly, with their own
explicit values.

What the tier gives you is:

1. **A place to write down *why* a project is configured the way it is**, so
   the next session (human or agent) doesn't have to re-derive it from five
   scattered yaml values.
2. **A recommendation table** for what those values should be at each tier.
3. **A drift check** (`lv-profile.sh --check`) that flags when the actual
   values no longer match what the declared tier recommends — because someone
   tightened one knob without updating the others, or the project's real-world
   stakes changed and the config didn't follow.

It does **not** write `levain.yml` for you. Applying a tier is a
deliberate edit — ask Claude to "apply the `governed` profile" and it edits
`specApproval.mode` etc. by hand, the same way a human would, preserving the
rationale comments already there. A script that silently rewrote those blocks
would orphan exactly the kind of hand-written "why" comment every other gate in
this project carries, and a stale rationale sitting next to a value it no
longer explains is worse than no rationale at all.

---

## The two tiers

| Tier | Meaning | `specApproval.mode` | `manualTestGate.blockOnCosmetic` | `orchestrator.autonomy` |
|-|-|-|-|-|
| `pre-launch` | No real users yet, or negligible ones. A bad unattended call costs a redeploy or a rollback, not an incident. | `verdict` | `false` | standing, through `production-push` |
| `governed` | Real users depend on this. A bad unattended call is user-visible. | `gate` | `true` | scoped to `release`/`deploy` at most — `production-push` stays attended |

Two tiers, not a spectrum — the same reasoning `specApproval.mode` itself
uses: a third "mostly launched" tier would be a judgment call wearing a config
key's clothes. If a project sits ambiguously between them, that ambiguity is
itself the signal to pick `governed` and loosen specific knobs deliberately,
rather than inventing a tier that quietly means "governed, except when it's
inconvenient."

## The config

```yaml
projectProfile:
  tier: pre-launch
  reason: "No real users yet except client-j.example, which stays governed."
  set_by: "Marc Blais"
  set_on: 2026-09-10
```

`reason` is required in spirit, not enforced in code — `lv-profile.sh --show`
prints `(none recorded)` rather than refusing, because a missing reason is a
smaller problem than a missing tier and shouldn't block reading what tier is
declared. But a tier with no reason is a decision nobody can re-derive later,
so write one.

No `expires_on`. That's a deliberate difference from `orchestrator.autonomy`:
an autonomy grant authorizes a specific unattended *action* and is inherently
time-boxed by design — "a record of something a person said on a particular
day" that "should stop being true." A profile tier describes a project's
*current real-world stakes*, which stay true until the facts change, and the
facts — real users start depending on the thing — are what should trigger you
back here, not a calendar date. An expiring tier would either lapse on
schedule back to some default (which default, and is that actually safer?) or
get rubber-stamp-renewed the way a genuinely load-bearing date shouldn't be.

---

## Reading it

```bash
scripts/lv-exec.sh lv-profile.sh --show     # tier, reason, who, when
scripts/lv-exec.sh lv-profile.sh --check    # drift against the recommendation table
```

`--check` exits 0 clean, 1 on drift, 2 if no tier is declared or the declared
tier isn't in the closed vocabulary above.

**A `pre-launch` project with a non-blank `production_url` is checked against
the full autonomy recommendation** — `orchestrator.autonomy.mode: standing`
with `standing_for` covering `release`, `deploy` and `production-push` —
not just `specApproval.mode` and `manualTestGate.blockOnCosmetic`. A blank
`production_url` (no deploy configured yet, e.g. `client-i`, `client-b`)
exempts a project from this half of the check entirely: there is no push path
to be autonomous about, and demanding a grant for one would be a rubber stamp
`docs/autonomy.md` already warns against. This is the direction that let
`client-c` go unchecked for a period even though its own grant was
already in place — `--check` only compared the *over*-permissive case
(`governed` still holding `production-push`) until this was added.

Across every client:

```bash
./check-profiles.sh              # tier + drift per client, deployments.txt order
./check-profiles.sh --count      # one line per client
```

mirrors `sweep-issues.sh`'s shape on purpose — same walk over `deployments.txt`,
same reason to run it periodically rather than only when something already
hurts.

---

## What this does *not* do

- **It does not grant autonomy.** `orchestrator.autonomy` still requires its
  own `granted_by` / `granted_on` / `expires_on` — a profile tier can tell you
  what scope is reasonable to grant, but writing the grant is still the
  deliberate, dated act `docs/autonomy.md` describes.
- **It does not gate anything itself.** There is no `profile-mismatch` gate.
  Drift is reported, not enforced — the same restraint `lv-autonomy.sh --show`
  uses for an unread `standing_for` entry.
- **It is not retroactive.** Declaring `governed` today doesn't undo whatever
  ran unattended yesterday under `pre-launch`.
