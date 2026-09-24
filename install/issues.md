# Workflow issues: collect them, fix them, send them upstream

> Part of [START.md](../START.md). When a skill or script does something its own documentation
> doesn't describe, whoever hits it records it with `lv-issue.sh`, and the entry lands in that
> project's `WORKFLOW-ISSUES.md`. Unattended workers record them too. This prompt works through
> what has piled up. Run it every week or two. `scripts/lv-exec.sh lv-issue.sh --count` says how
> many are waiting in a project.

## 1. Collect

| Their setup | Command |
|-|-|
| One project | `scripts/lv-exec.sh lv-issue.sh --list` in that project |
| Several (a registry exists: `$LIB/deployments.txt`, or a pack that answers `project-registry`) | `"$LIB/sweep-issues.sh"`, which groups the open ones by project. `--count` gives one line each |

Show them the list in short: one line per issue, with its ID, project and what went wrong. Group
the ones that are the same fault seen from different places, because they get one fix.

## 2. Decide, one issue at a time

Read the whole entry, then the skill or script it names in `$LIB`, and say which kind it is:

| Kind | What to do |
|-|-|
| A fault in Levain | Fix it in the library (step 3) |
| Not a fault: the documentation was right and the caller was wrong, or it was a one-off (a network blip, a killed process) | Resolve it with that reason (step 4), and change nothing |
| Their own setup: config, a template, their pack | Fix it where it lives, never in the library, and resolve it |

Ask them before fixing anything that changes how they work, such as a gate, a state or a
skill's steps. A plain bug fix needs no question; say what you are fixing.

## 3. Fix it in the library

**Fix the library, never the project.** A project's `scripts/` and `.claude/skills/` are copies
written at install time, and the next install overwrites them.

1. Work on a local branch, so their changes and upstream's never tangle:
   `git -C "$LIB" switch local/fixes 2>/dev/null || git -C "$LIB" switch -c local/fixes`.
2. Make the fix. Add or extend a test under `$LIB/tests/` that fails without it, where one fits.
3. Run the suite: `for t in "$LIB"/tests/*.sh; do bash "$t" || echo "FAILED: $t"; done`.
   Do not go on while a test that passed before now fails.
4. Commit on `local/fixes`, one commit per fault, and say which issue each fixes.
5. Put it into their projects: `"$LIB/install.sh" .` for one project, or
   `"$LIB/deploy-all.sh" --stop-daemons` for several.

`install/upgrade.md` rebases `local/fixes` onto each new version. A fix that upstream has since
made the same way drops out of the branch during the rebase; that is expected.

## 4. Resolve

Resolve each issue with a note that says what was done, because the entry stays in the file as
the record of what was already reported:

| Their setup | Command |
|-|-|
| One project | `scripts/lv-exec.sh lv-issue.sh --resolve LVI-NNN "fixed in the library: <what>"`, then commit `WORKFLOW-ISSUES.md` |
| Several | `"$LIB/sweep-issues.sh" --resolve LVI-NNN --client <project> "<what>"`, which commits it in that project |

## 5. Send it upstream

Levain lives at `https://github.com/slicedBread-marc/levain`. A fault fixed only on their machine
stays broken for everyone else, and upstream may later fix it differently and clash with theirs.
Offer to send each Levain fault upstream. **Nothing goes out without their yes**, because a
public issue or pull request is published the moment it is made:

- **An issue**, always possible: what they expected, what happened, and the Levain version
  (`$LIB/VERSION`). Leave out their project's names, paths and anything private; the entry in
  `WORKFLOW-ISSUES.md` may hold all three, so rewrite it rather than paste it.
- **A pull request**, when they have a fix with its test. Fork the repository, cherry-pick the
  commit onto a branch from upstream's `main`, and open the pull request against `main`. Check
  the diff for the same private details first.

With the `gh` CLI signed in, `gh issue create -R slicedBread-marc/levain` and `gh pr create`
do both. Without it, give them the text and the web address to paste it into.

## Report

In no more than 6 lines: how many issues were open, what was fixed (and in which commits on
`local/fixes`), what was resolved without a change and why, and what they chose to send upstream.
