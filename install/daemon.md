# Rung 2: the daemon

> Part of [START.md](../START.md). The same skills, run by unattended workers. The user only
> handles what a machine should not decide.

## Before

Check `plans/REGISTRY.md`. If nothing has reached `complete` yet, say so, and recommend taking one
item through by hand first. The daemon runs the same pipeline, and it is easier to trust once
they have seen it once. Go ahead if they still want to.

## 1. Explain the grant

In no more than 6 lines:

- A daemon sweeps the registry every minute and starts a worker for each plan that can move:
  spec on opus, implement and verify on sonnet, test on haiku. The routing is plain bash. Only
  the workers cost tokens.
- Workers run with `--dangerously-skip-permissions`. The permission guard installed in rung 1
  still refuses secrets and destructive commands (`docs/autonomy.md`). Everything else is
  allowed.
- Anything that needs a human (approving a spec, a manual acceptance criterion, a release)
  becomes a **gate**. The worker stops there and waits. It does not guess.
- The caps in the `orchestrator:` block (concurrency, attempts per plan, spawns per hour) are the
  guardrails. Never raise one to get past it.

## 2. Preview

```bash
scripts/lv-exec.sh lv-orchestrate.sh --sweep --dry-run
```

Show the output and explain what it would start.

## 3. Turn it on (their decision)

Ask directly: *turn the orchestrator on for this project?* Only after a yes, set
`orchestrator.enabled: true` in `levain.yml` and commit that one line.

The daemon does not return, so do not run it yourself. Ask them to start it in a terminal of
its own:

```bash
scripts/lv-exec.sh lv-orchestrate.sh --daemon
```

## 4. Show them the controls

| What | How |
|-|-|
| Watch it | `scripts/lv-exec.sh lv-tray.sh --watch` in a terminal, or `/lv-tray` here |
| Clear the gates | `/lv-attend` walks the queue, one decision at a time |
| Drive one item now | `/lv-orchestrate <ID>` |
| Stop it | `/lv-orchestrate daemon stop` (workers finish) or `kill-all` |

## Report

In no more than 4 lines: whether it is on, how to watch it, and that `/lv-attend` is how they
answer it. If they run more than one project, mention rung 3.
