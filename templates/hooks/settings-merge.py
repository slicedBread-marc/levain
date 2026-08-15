#!/usr/bin/env python3
"""Merge the workflow's session hooks into a client's .claude/settings.json.

Run by install.sh. Prints one word to stdout — created / updated / unchanged,
or `unparseable:<reason>` — and always exits 0: a deploy must not die because a
project's settings file has a stray comma in it.

WHY A MERGE AND NOT A TEMPLATE

Everything else install.sh writes into .claude/ is generated harness the library
owns outright, so it can be overwritten wholesale. settings.json is not that
file. It is where a project keeps its own permissions, env and hooks, and it
existed before the workflow arrived in most repos. So this replaces exactly the
entries whose command names wf-rehydrate.sh and leaves the rest alone.

Ours are identified by that script name rather than by matcher or position. A
matcher change then updates in place; identifying them by matcher would stack a
second entry running the same script twice on every compaction.

Writes nothing when the result is byte-identical to what is already there — a
deploy that dirties a clean tree is a deploy nobody can verify afterwards.

Usage: SETTINGS_PATH=... REHYDRATE_CMD=... GUARD_CMD=... settings-merge.py
"""

import json
import os
import sys

# SessionStart matches on the SOURCE. These three are the ways a session ends up
# holding less than it had: compaction, /clear, and a resume whose transcript
# already carries a summary written for a different moment.
#
# Deliberately NOT "startup": a fresh session reaches the registry through its
# skill's entry grep anyway, so the block would be pure cost on every launch.
#
# PreToolUse matches on the TOOL. The three that write a file in place are the
# three that can land a second writer on a claimed artifact.
MATCHERS = {
    "SessionStart": "compact|clear|resume",
    "PostCompact": "manual|auto",
    "PreToolUse": "Edit|Write|NotebookEdit",
}

# The argument each event passes to wf-rehydrate.sh. SessionStart gets the
# state block as additionalContext because it is the only one of the two whose
# output reaches the model; PostCompact gets the one-line human receipt.
ARGS = {
    "SessionStart": "session-start",
    "PostCompact": "post-compact",
}

# Silence and a zero exit if the harness is not on disk.
#
# settings.json is TRACKED in the client while scripts/v*/ and wf-exec.sh are
# gitignored build output. A fresh clone therefore has the hook and not the
# script it calls, and without this suffix every session start and every
# compaction would print a dispatcher error until someone ran deploy-all.sh.
#
# wf-rehydrate.sh already exits 0 on its own failures; this covers the case
# where it is absent entirely. Run it directly to see real errors:
#   scripts/wf-exec.sh wf-rehydrate.sh
TOLERATE_MISSING = " 2>/dev/null || true"

# The write guard tolerates a missing harness the same way, but it CANNOT use
# the suffix above: `|| true` rewrites every exit to 0, and exit 2 is the whole
# mechanism — it is how PreToolUse blocks. A guard installed with TOLERATE_MISSING
# is a guard that reports the collision and permits the write anyway. So absence
# is tested up front instead, leaving the exit status untouched.
GUARD_EVENT = "PreToolUse"


def guard_command(cmd):
    exe = cmd.split()[0]
    return f"[ -x {exe} ] || exit 0; {cmd}"


# Every script this file installs. Entries are matched by script NAME so a
# matcher or wrapper change updates in place rather than stacking a duplicate.
OURS = ("wf-rehydrate.sh", "wf-guard-write.sh")


def is_ours(entry):
    hooks = entry.get("hooks", []) if isinstance(entry, dict) else []
    return any(
        isinstance(h, dict) and any(s in h.get("command", "") for s in OURS)
        for h in hooks
    )


def main():
    path = os.environ["SETTINGS_PATH"]
    cmd = os.environ["REHYDRATE_CMD"]
    guard = os.environ.get("GUARD_CMD", "")

    try:
        with open(path) as fh:
            original = fh.read()
        data = json.loads(original) if original.strip() else {}
    except FileNotFoundError:
        original, data = None, {}
    except json.JSONDecodeError as exc:
        print(f"unparseable:{exc}")
        return
    except OSError as exc:
        print(f"unparseable:{exc}")
        return

    if not isinstance(data, dict):
        print("unparseable:top level is not an object")
        return

    hooks = data.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        print("unparseable:'hooks' is not an object")
        return

    for event, matcher in MATCHERS.items():
        existing = hooks.get(event, [])
        if not isinstance(existing, list):
            print(f"unparseable:'hooks.{event}' is not an array")
            return
        entries = [e for e in existing if not is_ours(e)]
        if event == GUARD_EVENT:
            # No GUARD_CMD — leave the event as the project had it. An older
            # install.sh must not install a half-configured blocking hook.
            if not guard:
                if entries or event in hooks:
                    hooks[event] = entries
                continue
            command, timeout = guard_command(guard), 10
        else:
            command, timeout = f"{cmd} {ARGS[event]}{TOLERATE_MISSING}", 10
        entries.append(
            {
                "matcher": matcher,
                "hooks": [{"type": "command", "command": command, "timeout": timeout}],
            }
        )
        hooks[event] = entries

    updated = json.dumps(data, indent=2) + "\n"
    if original is not None and original == updated:
        print("unchanged")
        return

    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as fh:
        fh.write(updated)
    print("created" if original is None else "updated")


if __name__ == "__main__":
    main()
    sys.exit(0)
