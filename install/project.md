# Rung 1: install into a project

> Part of [START.md](../START.md). The result is the pipeline installed in one project and a
> `levain.yml` that describes that project truthfully.

## 1. Write the config

`$LIB/config.example.yml` is the schema. Every key there has a comment saying what it is for
and where to find its value. Read the whole file. The user should never have to edit it.

1. **Detect** what the project can tell you: `build_command`, `test_command`,
   `test_filter_flag`, `source_dirs`, `solution_file` and `project_slug`. Use the hints in each
   key's comment (package.json scripts, a Makefile, `*.csproj`/`*.slnx`, `pyproject.toml`,
   `go.mod`, and so on). **Run the build and test commands once** to check they work. A wrong test
   command fails quietly later.
2. **Interview** for what only the user knows. Ask one or two questions at a time, and skip
   anything that does not apply:
   - Does it deploy anywhere? (`production_url`, `production_logs_url`)
   - How do they run it locally? (`local_start_command`, `local_deploy_command`, `local_stop_command`)
   - Is there a test account a browser check would sign in with? (`test_account_*`)
   - Any conventions an implementer must follow? (`conventions_note`, `namespace_convention`)
3. **Write** `levain.yml` at the project root: keys you know get their values, keys
   that do not apply keep the example's default, and the orchestrator block stays exactly as
   shipped (`enabled: false`). Show the user the values you chose, not the whole file.

## 2. Install

```bash
"$LIB/install.sh" .          # add --no-commit if they want to commit it themselves
```

It installs the skills into `.claude/skills/`, the scripts into `scripts/`, the `plans/` folder
with its registry and templates, and the permission guard in `.claude/settings.json`. It
also writes `WORKFLOW.md`, which is the entry point for any agent that arrives in this project
cold. It adds a workflow section to `CLAUDE.md` and does not touch the rest of that file.

If it stops with *"Created levain.yml — edit it"*, then no config existed when it ran.
Fill that file in as described in step 1, then run it again.

## 3. Check

```bash
scripts/lv-exec.sh lv-tray.sh         # the pipeline: empty, and with no errors
```

## Report

In no more than 5 lines: what was detected and what was asked, what was installed, and whether
it was committed. Then go on to `install/first-brainstorm.md`.
