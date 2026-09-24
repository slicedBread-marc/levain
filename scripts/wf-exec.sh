#!/usr/bin/env bash
# wf-exec.sh <script-name> [args...]
#
# Compatibility entry point, kept after the 14.0.0 rename (wf- → lv-). It hands
# everything to lv-exec.sh, which also maps a wf-*.sh script name to its lv-*
# successor. Callers written before the rename — a client's own CLAUDE.md, a
# settings.json allow rule, an operator's habit, a daemon that has not been
# restarted — keep working. New callers use scripts/lv-exec.sh.
exec "$(cd "$(dirname "$0")" && pwd)/lv-exec.sh" "$@"
