#!/usr/bin/env bash
# lv-config-get.sh <dotted.path> [default] [--list] [--text]
#
# Reads one value out of levain.yml, so a skill can branch on config
# without hand-rolling awk in a markdown code block (which is how the same
# parser ended up written four slightly different ways).
#
#   lv-config-get.sh specApproval.mode gate           → gate
#   lv-config-get.sh specApproval.gateTags --list     → security
#                                                       infra
#   lv-config-get.sh test_account_note --text         → the whole `|` block
#
# Scalars print on one line; --list prints one item per line and ignores the
# default. Same deliberate limits as wf_cfg: no yq dependency, 2-space
# indentation, scalars only.
#
# --text reads a value that may be a `|` or `>` block scalar and prints it
# whole, falling back to the one-line read. For PROSE only — a sign-in recipe,
# a note to a tester. Never for a command: wf_cfg refuses a block opener
# precisely because client-c once ran the literal string ">" as its
# account-provisioning command (WFI-016). client-b hit the other half of that
# trade, a fifteen-line test_account_note that read as empty and sent a tester
# to ask a human a question the file already answered (WFI-021).
#
# Exit 0 always when the path resolves or a default is supplied.

set -euo pipefail

# shellcheck source=lv-orch-lib.sh
source "$(dirname "$0")/lv-orch-lib.sh"

path=""
default=""
as_list=false
as_text=false

while [ $# -gt 0 ]; do
  case "$1" in
    --list) as_list=true; shift ;;
    --text) as_text=true; shift ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) if [ -z "$path" ]; then path="$1"; else default="$1"; fi; shift ;;
  esac
done

[ -n "$path" ] || { echo "Usage: $0 <dotted.path> [default] [--list] [--text]" >&2; exit 2; }

if $as_list; then
  wf_cfg_list "$path"
elif $as_text; then
  printf '%s\n' "$(wf_cfg_text "$path" "$default")"
else
  printf '%s\n' "$(wf_cfg "$path" "$default")"
fi
