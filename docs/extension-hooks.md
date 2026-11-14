# Extension hooks

The library is general. Your secrets tool, your hosting provider, your activity log and the list
of projects you deploy to are yours, and the library never names them. Wherever it needs one, it
calls a **hook** named for the job, not the tool (LVI-013):

```bash
scripts/lv-exec.sh lv-hook.sh <hook> [args]
scripts/lv-exec.sh lv-hook.sh --list            # every hook, its kind, who answers it
scripts/lv-exec.sh lv-hook.sh --which <hook>    # every layer, in lookup order
```

## Where a hook is found

`lv-hook.sh` resolves each call at run time, in this order:

1. **Project-local:** `.lv-local/hooks/<hook>` in the project. For one machine and one project;
   add `.lv-local/` to the project's `.gitignore`.
2. **Packs:** `<pack>/hooks/<hook>`, for each pack in the project's `levain.yml`
   `packs:` list, then each in `$LV_PACKS` (colon-separated). When `LV_PACKS` is unset, each
   line of `~/.config/levain/packs` is read instead (a `~/` path and `#` comments are fine).
3. **Default:** `hooks.default/<hook>` in the library. It is a neutral implementation or a
   no-op, and its header declares the hook's kind.

A **pack** is a directory, usually its own private repo, holding `hooks/<name>` executables. It
is read where it is and never copied into a client, so a deploy cannot overwrite it and a library
contributor never sees it.

## Kinds

| Kind | Behaviour |
|-|-|
| `decide` | The first layer that has the hook runs, with the args and stdin. Its stdout and exit code are the hook's |
| `observe` | Every layer runs, default last, with the args. A failure is reported on stderr and never reaches the caller |
| `add-deny` | Every layer runs, and the output is the union. A pack can add rules to the permission baseline and never remove the library's. **Fails closed:** a listed pack that has gone, or a layer that fails or is not executable, exits 3 and the caller refuses |

## The hooks

| Hook | Kind | Called by | Contract | Default |
|-|-|-|-|-|
| `secrets-deny-patterns` | add-deny | `lv-guard-baseline.sh`, `settings-merge.py` | stdout: `path<TAB><path>` for a secret file or directory, or `command<TAB><rule-id><TAB><regex><TAB><why>` for a command a worker must not run | nothing |
| `provider-deny` | add-deny | `lv-guard-baseline.sh` | same format; your host's secret-setting, shell and destroy commands, usually under ids `provider-secrets`, `provider-shell`, `provider-destroy` | nothing (GitHub's rules are built in) |
| `secrets-deploy` | decide | you, a skill, a deploy step | `<id> <location> [...]`: set archived secrets on a deployed app. Nothing secret may reach stdout, stderr or argv | refuses (exit 3): no secrets tool |
| `activity-log` | observe | you, a skill | `"<what changed and why>" [--ref <commit/plan/file>]` | keeps no log |
| `project-registry` | decide | `deploy-all.sh`, `sweep-issues.sh`, `check-profiles.sh`, `lv-rack.sh` | stdout: one absolute project path per line | `$LV_DEPLOYMENTS`, else `deployments.txt` in the library root, else a coordinator's `coordinates:` |
| `publish-denylist` | add-deny | `check-denylist.sh` | stdout: one Perl regex per line, a name that must never reach a public copy of a repository (a client, a private project, a personal path). The list lives only in a pack | nothing |
| `overseer-vision` | decide | `/lv-vision` | stdout: the absolute path of a `SKILL.md` meeting [vision-spec.md](vision-spec.md) | `.claude/skills/vision/SKILL.md` in the project, else exit 3 |
| `dev-port` | decide | `lv-plan-port.sh` (and so every step that sets `FEATURE_PORT`) | `<project_slug> <plan-folder> <worktree-path>` → stdout: one port. Must be idempotent per project and plan. Exit 3 means no allocator; any other non-zero exit is a refusal, and `lv-plan-port.sh` fails rather than fall back | exit 3: `8100 + N` |
| `dev-port-release` | observe | `lv-registry-update.sh` at a terminal state, `lv-bug-close.sh` | `<project_slug> <plan-folder>`: the plan or bug is finished, so free the port `dev-port` gave it. Needed by any allocator whose leases outlive their worktree, as a lease taken from the develop root does | nothing to release |
| `library-publish` | decide | `lv-library-sweep.sh` after a sweep deploys, the rack's `U` after a deploy | `<library-dir>`: publish the library somewhere public (a scrubbed copy, a mirror). Exit 0 published, 3 no publisher; any other exit is reported and never undoes the deploy | exit 3: publishes nothing |

The format of every add-deny rule is in `hooks.default/secrets-deny-patterns`. The permission
baseline is described in [autonomy.md](autonomy.md#permission-baseline-what-an-unattended-worker-may-never-do). A rule-id from a
pack is lifted the same way as a built-in one, under `permissionBaseline` in the project's
config.

`LV_DEPLOYMENTS` still names a client list file directly, and wins over any registry hook. It
is the test suite's seam, so a test never walks your real projects.

## Writing a pack

```
my-pack/
  hooks/
    secrets-deny-patterns   # executable; prints path/command lines
    provider-deny
    project-registry
  README.md
```

List it in `~/.config/levain/packs`, then check it with `lv-hook.sh --list`. Redeploy after
changing `secrets-deny-patterns`, because the `Read` deny rules for every session are written at
install time. The worker guard reads the hooks on every call, so its rules take effect at once.

Never put a secret value in a pack. A hook calls your secrets tool by key id or purpose.
