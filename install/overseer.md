# Rung 3: the overseer

> Part of [START.md](../START.md). A **coordinator** is a small repository that runs no pipeline
> of its own. It holds the board for every project, files work into them, and holds the
> vision. Background: `$LIB/docs/coordinator.md`.

## 1. Which projects

Ask which projects it should oversee. Each one should already have rung 1. If one does not, run
`install/project.md` for it first, since that is its own project. Collect a short name and the
absolute path of each.

## 2. Create the coordinator

Ask where it should live. A sibling of the projects works well (for example `../overseer`).
Creating a repository needs their yes. Then:

```bash
mkdir -p <dir> && git -C <dir> init
```

and write `<dir>/claude-workflow.yml`:

```yaml
role: "coordinator"
project_slug: "<a short name for the coordinator>"

coordinates:
  - "<name>:<absolute path>"
  - "<name>:<absolute path>"
```

Then install it: `"$LIB/install.sh" <dir>`. A coordinator gets `/lv-dep-notify` (file work
into a project), `/lv-rack` (the board) and `/lv-vision`, and no plans, registry or worktrees.

## 3. Keep them all current

The `coordinates:` list is enough for the board. For `$LIB/deploy-all.sh`, which upgrades every
project at once, also list the same absolute paths, one per line, in `$LIB/deployments.txt`
(gitignored), and include the coordinator's path. A pack can supply this list instead
(`install/pack.md`).

## 4. Show the board

From the coordinator:

```bash
scripts/lv-exec.sh lv-rack.sh --plain --all
```

Show the output. For the live board, ask them to run `scripts/lv-exec.sh lv-rack.sh --watch` in a
terminal. Arrows move between cells and `Enter` opens one. Inside it, `t` starts `/lv-attend` in
that project on the highlighted item. The footer lists the other keys.

Say once that the coordinator's authority stops at filing: work is filed into a project with
`/lv-dep-notify`, and everything after that belongs to that project's own session.

## Report

In no more than 5 lines: where the coordinator is, which projects it watches, and how to open
the board. Then offer `install/vision.md`.
