#!/usr/bin/env bash
# lv-hook.sh <hook> [args...]
# lv-hook.sh --list | --which <hook> | --help
#
# The extension-hook dispatcher (LVI-013). Library scripts never call a
# provider or a personal tool directly: they call a hook named for the job
# (secrets-deploy, not a named secrets tool; provider-deny, not a named host), and this resolves who
# implements it, at run time, in three layers:
#
#   1. project-local  .lv-local/hooks/<hook> in the project (gitignored)
#   2. packs          <pack>/hooks/<hook>, for each pack in the project's
#                     levain.yml `packs:` list, then each in $LV_PACKS
#                     (colon-separated) — or, when LV_PACKS is unset, each
#                     line of ~/.config/levain/packs
#   3. default        hooks.default/<hook>, beside this script: a neutral
#                     implementation or a no-op, which also declares the kind
#
# Packs are read where they sit and never copied into a client, so a deploy
# cannot overwrite one and a library contributor never touches one.
#
# KINDS — each default's header carries `# kind: <kind>`:
#
#   decide    the first layer that implements the hook runs, with the args and
#             stdin; its stdout and exit code are the hook's
#   observe   every layer runs, default last, with the args and no stdin; a
#             failure is reported on stderr and never breaks the caller, which
#             always gets exit 0
#   add-deny  every layer runs, no stdin, and their stdout is the union: a pack can add
#             rules to the permission baseline and never remove the library's.
#             Fails closed: a listed pack that is missing, a layer that is not
#             executable or exits non-zero, makes the whole call exit 3, and
#             the caller refuses. A pack that moved must not quietly take its
#             guards with it.
#
# A hook with no default is not a hook: exit 64.
# The project is $CLAUDE_PROJECT_DIR, else the git root of the cwd, else the cwd.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS="${LV_HOOK_DEFAULTS:-$HERE/hooks.default}"

usage() { sed -n '2,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

project_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "$CLAUDE_PROJECT_DIR" ]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
  else
    git rev-parse --show-toplevel 2>/dev/null || pwd
  fi
}
ROOT=$(project_root)

# The packs, one per line, in lookup order. `~/` is expanded; blank lines and
# comments are skipped.
packs() {
  local cfg="$ROOT/levain.yml" list p
  [ -f "$cfg" ] || [ ! -f "$ROOT/claude-workflow.yml" ] || cfg="$ROOT/claude-workflow.yml"
  if [ -f "$cfg" ]; then
    awk '
      /^packs:[ \t]*$/ { on = 1; next }
      on && /^[ \t]+-[ \t]/ { sub(/^[ \t]+-[ \t]+/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; next }
      on && /^[^ \t#]/ { on = 0 }
    ' "$cfg"
  fi
  if [ -n "${LV_PACKS+x}" ]; then
    list=$(printf '%s' "$LV_PACKS" | tr ':' '\n')
  else
    local f="$HOME/.config/levain/packs"
    list=$( [ -f "$f" ] && cat "$f" )
  fi
  printf '%s\n' "$list"
} 2>/dev/null

expand() { case "$1" in "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;; *) printf '%s\n' "$1" ;; esac; }

kind_of() { sed -n 's/^# kind:[ \t]*\([a-z-]*\).*/\1/p' "$DEFAULTS/$1" 2>/dev/null | head -1; }

# Every layer for <hook>, in order, as "<label>\t<path>". A listed pack that is
# not a directory is emitted as "missing\t<pack>" so add-deny can refuse on it.
layers() {
  local hook="$1" p d
  [ -e "$ROOT/.lv-local/hooks/$hook" ] && printf 'local\t%s\n' "$ROOT/.lv-local/hooks/$hook"
  while IFS= read -r p; do
    p=$(printf '%s' "$p" | sed 's/[[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$p" ] || continue
    d=$(expand "$p")
    if [ ! -d "$d" ]; then printf 'missing\t%s\n' "$d"; continue; fi
    [ -e "$d/hooks/$hook" ] && printf 'pack\t%s\n' "$d/hooks/$hook"
  done < <(packs)
  printf 'default\t%s\n' "$DEFAULTS/$hook"
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  --list)
    for f in "$DEFAULTS"/*; do
      [ -f "$f" ] || continue
      h=$(basename "$f")
      from=$(layers "$h" | awk -F'\t' '$1 != "missing" { print $1 " " $2; exit }')
      printf '%-24s %-9s %s\n' "$h" "$(kind_of "$h")" "$from"
    done
    exit 0 ;;
  --which)
    h="${2:-}"; [ -f "$DEFAULTS/$h" ] || { echo "lv-hook: no hook named '$h'" >&2; exit 64; }
    layers "$h"; exit 0 ;;
esac

hook="$1"; shift
case "$hook" in */*|.*) echo "lv-hook: bad hook name '$hook'" >&2; exit 64 ;; esac
[ -f "$DEFAULTS/$hook" ] || { echo "lv-hook: no hook named '$hook' (no hooks.default/$hook)" >&2; exit 64; }
kind=$(kind_of "$hook")

case "$kind" in
  decide)
    # The layer list comes in on fd 3: stdin belongs to the hook.
    while IFS=$'\t' read -r label path <&3; do
      [ "$label" = missing ] && { echo "lv-hook: pack $path is listed but missing — skipped" >&2; continue; }
      [ -x "$path" ] || { echo "lv-hook: $path is not executable" >&2; exit 3; }
      "$path" "$@" 3<&-; exit $?
    done 3< <(layers "$hook")
    exit 3 ;;

  observe)
    while IFS=$'\t' read -r label path; do
      [ "$label" = missing ] && { echo "lv-hook: pack $path is listed but missing — skipped" >&2; continue; }
      if [ -x "$path" ]; then
        "$path" "$@" </dev/null || echo "lv-hook: $hook ($label $path) exited $? — ignored" >&2
      else
        echo "lv-hook: $path is not executable — ignored" >&2
      fi
    done < <(layers "$hook")
    exit 0 ;;

  add-deny)
    out=""
    while IFS=$'\t' read -r label path; do
      [ "$label" = missing ] && { echo "lv-hook: $hook: pack $path is listed but missing; refusing (fail closed)" >&2; exit 3; }
      [ -x "$path" ] || { echo "lv-hook: $hook: $path is not executable; refusing (fail closed)" >&2; exit 3; }
      part=$("$path" "$@" </dev/null) \
        || { echo "lv-hook: $hook: $label $path failed; refusing (fail closed)" >&2; exit 3; }
      [ -n "$part" ] && out="$out$part"$'\n'
    done < <(layers "$hook")
    printf '%s' "$out"
    exit 0 ;;

  *) echo "lv-hook: hooks.default/$hook declares no kind" >&2; exit 64 ;;
esac
