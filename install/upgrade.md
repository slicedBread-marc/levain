# Upgrade

> Part of [START.md](../START.md). It brings installed projects up to the library's current
> version and reports what changed.

## 1. Where things stand

```bash
cat "$LIB/VERSION"                               # the library
cat .claude/workflow-version                     # this project
git -C "$LIB" status --short && git -C "$LIB" fetch && git -C "$LIB" log --oneline HEAD..@{u}
```

If the library has upstream commits, pull them. If a `local/platform` branch exists (from
`install/preflight.md`), rebase it onto the new version instead, and run the test suite before
going on.

## 2. What changed

Find the commit that set the project's version (`git -C "$LIB" log -S '<old version>' --oneline
-- VERSION`) and read the log since it. Summarise it for the user in no more than 8 lines, and
lead with anything that changes how they work: a renamed or merged skill, a new gate, or a config
key that is new or changed. Old skill names keep working as aliases.

## 3. Apply

| Their setup | Command |
|-|-|
| One project | `"$LIB/install.sh" .` in that project |
| Several (a registry exists) | `"$LIB/deploy-all.sh" --stop-daemons`. It stops running daemons, upgrades every listed project, and then restarts exactly the daemons it stopped |

Installs are atomic, so a running daemon never reads a half-written harness. Their templates and
`levain.yml` are left alone. New config keys take their defaults until they are set, and
`$LIB/config.example.yml` documents them.

## Report

In no more than 5 lines: from which version to which, the projects upgraded, and the changes
that matter to them.
