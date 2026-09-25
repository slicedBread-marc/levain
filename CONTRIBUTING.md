# Contributing to Levain

Levain improves when the faults people hit reach it. Two ways to send one: an issue, which is
always welcome, and a pull request, when you have a fix and a test for it.

If you work with Claude, say *"read ~/levain/START.md and go through my workflow issues"*.
[`install/issues.md`](install/issues.md) collects what your projects recorded, fixes it, and
drafts the issue or pull request, checking it for private details before anything is sent.

## Before you file

Search for it first: `gh issue list -R slicedBread-marc/levain --state all --search "<script> <symptom>"`.
If an open issue describes the same fault, add your version and anything new to it as a comment
instead of filing again. If a closed issue says it was fixed in a version later than yours,
upgrade ([`install/upgrade.md`](install/upgrade.md)).

## An issue

Use the template. It asks for:

- **The Levain version:** the `VERSION` file in your copy, or `.claude/workflow-version` in a
  project.
- **Which script or skill:** `lv-stage-start.sh`, `/lv-test`, and so on.
- **What you expected and what happened:** the command, the exit code, and the error text.
- **How to reproduce it**, if you know.

## What to leave out

An issue or pull request is public the moment it exists. Leave out:

- your projects' and your clients' names, and your paths, including your home directory and
  your login name
- secrets, tokens, keys and URLs that carry them
- logs, registry rows or `WORKFLOW-ISSUES.md` entries pasted whole. Rewrite them, because
  they hold all of the above

`./check-denylist.sh --outbound --text <file>`, run in your copy of the library, checks a draft
against your home path, your login name and every project in your registry. Clean means exit 0.

## A pull request

- **One fault per pull request**, with a test under `tests/` that fails without the fix. Run
  the suite: `for t in tests/*.sh; do bash "$t" || echo "FAILED: $t"; done`.
- **Skills are prompts that run unattended.** A change to a `skills/*/SKILL.md` is reviewed
  against [`docs/prompt-contract.md`](docs/prompt-contract.md). Read it first.
- **Check the diff** for the details listed above:
  `git format-patch --stdout origin/main..HEAD | ./check-denylist.sh --outbound --text -`.

**Your pull request will be closed, not merged, and that is how acceptance looks here.** The
public history is rebuilt from a private copy of the library, so a merge on GitHub would be
overwritten by the next publish. The maintainer reads the pull request, applies it there as a
patch with your authorship kept, and closes it with a comment naming the version that carries
it. A pull request that is declined gets a comment saying why.

Nothing a contributor sends is applied without the maintainer reading every line of it. Levain's
scripts and skills run unattended with wide permissions in every project that installs them, so
that read is where the review happens. Please keep a pull request small enough to read in one
sitting.
