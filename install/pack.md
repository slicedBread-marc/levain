# A pack: your own tools behind the hooks

> Part of [START.md](../START.md). The library never names anyone's secrets tool, hosting
> provider, activity log or list of projects. It calls a **hook** named for the job, and a
> **pack** is a private directory that answers those hooks. Background:
> `$LIB/docs/extension-hooks.md`, which has the full table of hooks.

## 1. What do they have?

Run `"$LIB/scripts/v2.00/lv-hook.sh" --list` and show which hooks exist and who answers each
today. Then ask about the ones that matter:

| Hook | Ask |
|-|-|
| `secrets-deny-patterns` | Where do secrets live on this machine that no agent should ever read? |
| `provider-deny` | Which provider commands must an agent never run (a remote shell, printing secrets)? |
| `secrets-deploy` | Is there a tool that sets a secret on the host without printing it? |
| `activity-log` | Do you keep a log of work across projects? |
| `project-registry` | Where is your list of projects kept? |
| `overseer-vision` | Does your vision skill live somewhere other than the coordinator? |

Implement only what they answer. A hook left out keeps the library's neutral default.

## 2. Create it

Creating the repository needs their yes. Keep it private, and outside every project:

```bash
mkdir -p <pack>/hooks && git -C <pack> init
```

Each hook is an executable file at `<pack>/hooks/<hook>`. Copy the default's header from
`$LIB/scripts/v2.00/hooks.default/<hook>`, which gives its arguments, stdin, stdout and exit codes,
and write the body. An `add-deny` hook can only **add** rules, and if it fails, every guarded
action is refused (it fails closed). Test each one by hand before going on.

## 3. Register it

```bash
mkdir -p ~/.config/levain && echo "<absolute path to pack>" >> ~/.config/levain/packs
"$LIB/scripts/v2.00/lv-hook.sh" --list      # each hook now names its answerer
```

A pack is read where it sits and is never copied into a project, so upgrades cannot overwrite
it. A single project can also list packs under `packs:` in its own `claude-workflow.yml`.

## Report

In no more than 4 lines: which hooks the pack answers, where it lives, and that it must stay
where it is: moving it without updating `~/.config/levain/packs` makes the guard refuse
everything.
