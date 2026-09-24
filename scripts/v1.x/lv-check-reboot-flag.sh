#!/usr/bin/env bash
# lv-check-reboot-flag.sh
# Outputs a restart reminder if .claude/reboot-flag exists. Silent otherwise.
[ -f .claude/reboot-flag ] || exit 0

echo ""
echo "---"
echo "⚠️  Restart reminder: $(cat .claude/reboot-flag)"
echo "   Dismiss: scripts/lv-clear-reboot-flag.sh"
