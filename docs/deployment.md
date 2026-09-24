# Deployment: what the pipeline assumes, and what is yours

Levain ships code as far as a branch. What happens after a push, meaning CI, the host and the
provider, belongs to your project, and the library assumes nothing about any of it.

## The branches

```
feature/PLN-NNN-<slug>   one per plan, in its own worktree        /lv-implement
        ↓ merge
develop                  integration; where plans are registered
        ↓ /lv-release    merge develop into release, run E2E; /lv-stage serves it locally
release
        ↓ /lv-deploy     promote to main, mark plans complete, back-merge to develop
main                     production
```

`/lv-release` and `/lv-deploy` each work in a pinned worktree of their own
([release-worktrees.md](release-worktrees.md)). Whether a push to `release` or `main` deploys
anything is up to your CI. A common arrangement is for `release` (or `develop`) to go to
staging and `main` to production, each on push, with a manual trigger kept for
emergencies.

## What the library reads

| Key in `claude-workflow.yml` | Used by |
|-|-|
| `production_url`, `production_logs_url` | `/lv-deploy`'s completion message. Leave them blank when there is no production |
| `local_start_command`, `local_deploy_command`, `local_stop_command` | Local runs and browser checks |
| `staging.*` (`composeFile`, `port`, `minutes`, `healthPath`) | `/lv-stage`. This is the one place a tool is assumed: staging runs `docker compose` on the release worktree. Without a compose file, skip `/lv-stage` |

The provider's commands and secrets never appear in the library. The permission guard refuses
the dangerous ones through the `provider-deny` and `secrets-deny-patterns` hooks, and a pack can
set secrets through `secrets-deploy` ([extension-hooks.md](extension-hooks.md)).

## Keep the pipeline out of production images

Plans, briefs, bugs and the harness are tracked in git as history, but they have no place in a
build artifact. If you build container images, exclude them in `.dockerignore`, or use your
builder's equivalent:

```
plans/
bugs/
.claude/
scripts/lv-*
scripts/gen/
scripts/current
feature-branches/
release-branches/
WORKFLOW.md
WORKFLOW-ISSUES.md
```
