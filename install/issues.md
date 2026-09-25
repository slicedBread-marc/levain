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
public issue or pull request is published the moment it is made. [`CONTRIBUTING.md`](../CONTRIBUTING.md)
says what upstream needs in each.

1. **Look for it first.** Search with the script or skill's name and two or three words from
   what went wrong:
   `gh issue list -R slicedBread-marc/levain --state all --search "lv-stage port"`.
   - An **open** issue describes the same fault: add to it instead of filing a second one. Put
     their Levain version and anything new in a comment (steps 2 and 3 apply to the comment too),
     and send it with `gh issue comment <N> -R slicedBread-marc/levain --body-file <file>`.
   - A **closed** one fixed it in a version later than theirs (`$LIB/VERSION`): it is already
     fixed. Offer `install/upgrade.md` instead of filing.
   - Nothing that matches: go on.
2. **Write it to a file**, never straight into a command line:
   - **An issue** says what they expected, what happened, which script or skill did it, and the
     Levain version. Rewrite it from the `WORKFLOW-ISSUES.md` entry rather than paste it, because
     the entry may hold their project's names, paths and private details.
   - **A pull request** is for a fix that has a test. Fork the repository, cherry-pick the
     commit onto a branch from upstream's `main`, and write a description the way
     `.github/pull_request_template.md` asks.
3. **Check it** before anything is sent. Run it from `$LIB`, where the check finds their
   project registry:
   ```bash
   cd "$LIB" && ./check-denylist.sh --outbound --text <file>                   # issue or comment
   git -C "$LIB" format-patch --stdout origin/main..<branch> \
     | (cd "$LIB" && ./check-denylist.sh --outbound --text -)                  # pull request
   ```
   `--outbound` denies their home path, their login name and every project in their registry,
   by folder name and `project_slug`, plus whatever their pack's `publish-denylist` hook lists.

   | Exit | Meaning | Do |
   |-|-|-|
   | 0 | Clean | Go on to step 4 |
   | 1 | It lists line numbers that name something of theirs | Rewrite those lines and check again. Do not get around the match by splitting or misspelling the name; that publishes the name anyway. If a flagged line uses an ordinary word that happens to be a project's name, show them the line and let them decide. That is their call, not yours |
   | 2 | The check could not run | Say why, and send nothing until it runs |

4. **Send it**: `gh issue create -R slicedBread-marc/levain --title "<script>: <what went wrong>"
   --body-file <file>`, or `gh pr create --body-file <file>` for a pull request. Without `gh`,
   give them the checked text and the web address to paste it into.

A pull request is not merged as it stands. The public history is rebuilt from a private copy, so
upstream applies it there as a patch, keeping the author, and closes the pull request with the
version that carries it. Tell them this, so a closed pull request does not read as a rejection.

## Report

In no more than 6 lines: how many issues were open, what was fixed (and in which commits on
`local/fixes`), what was resolved without a change and why, and what they chose to send upstream.
