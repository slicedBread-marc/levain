#!/usr/bin/env bash
# lv-ids.sh — the artifact ID prefix map.
#
# Every artifact kind has one prefix it ISSUES and any number it still
# ACCEPTS, so a prefix can be renamed at any time without renumbering or
# rewriting history: new IDs carry the new prefix, old ones keep resolving, and
# the counter is keyed by kind, so the numbering simply carries on.
#
#   kind      default    what it names
#   plan      PLN        a plan (PLN-NNN)
#   bug       BUG        a bug (BUG-NNN) — shares the plan/brief counter
#   brief     BRF        a brief from a brainstorm (BRF-NNN) — same counter
#   deferred  DC         a deferred criterion (DC-NNN)
#   issue     LVI WFI    a harness issue (LVI-NNN; WFI-NNN before 14.0.0)
#   test      T          a test ID (T75 — no hyphen)
#   rollback  RBK        a rollback record (RBK-NNN)
#
# A project overrides a kind in claude-workflow.yml, issued prefix first:
#
#   ids:
#     plan: LOAF PLN
#     issue: LVI WFI
#
# The library default for a kind is always accepted too, so an override never
# strands IDs issued under the default. Deliberately not advertised: the
# defaults are what the documentation shows.
#
# Prefixes are 1–5 capital letters and must be unique across kinds; `check`
# refuses a map that breaks either rule, because a prefix claimed by two kinds
# makes every lookup ambiguous. install.sh runs `check` on every deploy, and
# renders the issued prefixes into the skills, templates and docs it installs,
# so what an agent reads names the IDs this project actually uses.
#
# SOURCED (by lv-orch-lib.sh, so by nearly every script) it defines the lv_id_*
# functions and sets, for each kind, three variables named after its default:
#
#   LV_PLN        the issued prefix               PLN      (or LOAF)
#   LV_PLN_ALL    issued first, then accepted     PLN      (or LOAF PLN)
#   LV_PLN_RE     an ERE alternation              PLN      (or LOAF|PLN)
#
# for PLN, BUG, BRF, DC, RBK, LVI (issue) and T (test), plus LV_WORK_RE and
# LV_WORK_ALL for the three kinds that share one counter (plan, bug, brief).
# Scripts match with the _RE form, glob with a loop over _ALL, and build new IDs
# with the bare one: "$LV_PLN-$num", "^($LV_WORK_RE)-[0-9]+".
#
# RUN, it answers:
#   lv-ids.sh prefix <kind>          the prefix issued for <kind>
#   lv-ids.sh prefixes <kind>        issued first, then every accepted prefix
#   lv-ids.sh match <kind>... | all  an ERE alternation: PLN|LOAF
#   lv-ids.sh kind <id>              the kind an ID belongs to (exit 1: none)
#   lv-ids.sh canon <id>             the ID under its kind's issued prefix
#   lv-ids.sh check                  validate the map (exit 1 on a conflict)
#   lv-ids.sh render < in > out      rewrite default prefixes in prose to the issued ones
#   lv-ids.sh list                   the whole map, one kind per line

LV_ID_KINDS="plan bug brief deferred issue test rollback"

# The frozen v1.x generation is not on the map, and needs not be: it serves only
# plans stamped before 2.0, whose IDs carry the defaults, which stay accepted.

_lv_id_default() { local dd; _lv_id_default_into dd "$1" || return 1; printf '%s\n' "$dd"; }

# _lv_id_default_into <var> <kind> — the same, into a variable, with no fork.
_lv_id_default_into() {
  # A local here would shadow a caller's variable of the same name, and
  # printf -v would write the local. So: no locals, and a name nobody uses.
  case "$2" in
    plan) _lv_id_dflt=PLN ;; bug) _lv_id_dflt=BUG ;; brief) _lv_id_dflt=BRF ;;
    deferred) _lv_id_dflt=DC ;; issue) _lv_id_dflt="LVI WFI" ;; test) _lv_id_dflt=T ;;
    rollback) _lv_id_dflt=RBK ;;
    *) return 1 ;;
  esac
  printf -v "$1" '%s' "$_lv_id_dflt"
}

# lv_id_load — read the whole map once into _LV_ID_<kind> shell variables, so
# lookups after it are free. One awk pass over claude-workflow.yml. Not
# exported, on purpose: a process that walks several projects (lv-rack) must
# not carry one project's map into the next, so each process reads its own.
lv_id_load() {
  local root="" cfg k v d dflt line
  # The main worktree's config, as lv-orch-lib.sh finds it. Its cached answer
  # when it is loaded (no fork); otherwise ask git once.
  if declare -F wf_develop_root >/dev/null 2>&1; then
    wf_develop_root >/dev/null          # in this shell, so its cache is filled
    root="$_WF_DEVELOP_ROOT"
  else
    # Not a repo reads ./ — git's failure must not end a pipefail caller.
    root=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') || root=""
  fi
  cfg="${root:-.}/claude-workflow.yml"
  for k in $LV_ID_KINDS; do printf -v "_LV_ID_$k" '%s' ""; done
  # One awk for the whole map, read back without a fork per kind: this runs
  # at the start of nearly every script.
  if [ -f "$cfg" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        testprefix) [ -n "${_LV_ID_test// }" ] || _LV_ID_test="$v" ;;  # predates the map
        plan|bug|brief|deferred|issue|test|rollback) printf -v "_LV_ID_$k" '%s' "$v" ;;
      esac
    done < <(awk '
      /^[^ #]/ { sec = $0; sub(/:.*/, "", sec); next }
      sec == "ids" && /^  [a-z]+:/ || sec == "testIds" && /^  prefix:/ {
        key = $0; sub(/^  /, "", key); sub(/:.*/, "", key)
        if (sec == "testIds") key = "testprefix"
        val = $0; sub(/^  [a-zA-Z]+:[ \t]*/, "", val); sub(/[ \t]+#.*$/, "", val)
        gsub(/[,\[\]"\047]/, " ", val); print key "=" val
      }' "$cfg")
  fi
  for k in $LV_ID_KINDS; do
    line="_LV_ID_$k"; v="${!line}"
    _lv_id_default_into dflt "$k"
    [ -n "${v// }" ] || v="$dflt"
    for d in $dflt; do
      case " $v " in *" $d "*) ;; *) v="$v $d" ;; esac
    done
    # Squeeze the spacing without `echo $v` (a fork inside $()).
    set -f; set -- $v; set +f
    printf -v "_LV_ID_$k" '%s' "$*"
  done
  _LV_ID_LOADED=1
}

# lv_id_prefixes <kind> — issued prefix first, then every accepted one.
lv_id_prefixes() {
  local var="_LV_ID_$1"
  _lv_id_default "$1" >/dev/null || { echo "lv-ids: unknown kind '$1'" >&2; return 1; }
  [ -n "${_LV_ID_LOADED:-}" ] || lv_id_load
  printf '%s\n' "${!var}"
}

lv_id_prefix() { local p; p=$(lv_id_prefixes "$1") || return 1; printf '%s\n' "${p%% *}"; }

# lv_id_match <kind>... | all — "PLN|LOAF|BUG", for grep -E / [[ =~ ]] / awk.
lv_id_match() {
  local kinds="$*" k out=""
  [ "$kinds" = all ] && kinds="$LV_ID_KINDS"
  for k in $kinds; do out="$out $(lv_id_prefixes "$k")" || return 1; done
  out=$(echo $out); printf '%s\n' "${out// /|}"
}

# lv_id_kind <id> — which kind this ID is, from its prefix.
lv_id_kind() {
  local id="$1" k p
  for k in $LV_ID_KINDS; do
    for p in $(lv_id_prefixes "$k"); do
      if [ "$k" = test ]; then
        [[ "$id" =~ ^${p}[0-9]+$ ]] && { echo "$k"; return 0; }
      else
        [[ "$id" =~ ^${p}-[0-9]+ ]] && { echo "$k"; return 0; }
      fi
    done
  done
  return 1
}

# lv_id_canon <id> — the same number under the kind's issued prefix, so a
# lookup by an old ID finds an artifact filed under the new one and back.
lv_id_canon() {
  local id="$1" k p
  k=$(lv_id_kind "$id") || { printf '%s\n' "$id"; return 1; }
  for p in $(lv_id_prefixes "$k"); do
    case "$id" in "$p"*) printf '%s%s\n' "$(lv_id_prefix "$k")" "${id#"$p"}"; return 0 ;; esac
  done
}

# lv_id_check — the map is valid: well-formed and unambiguous.
lv_id_check() {
  local k p seen="" bad=0 owner
  for k in $LV_ID_KINDS; do
    for p in $(lv_id_prefixes "$k"); do
      if ! [[ "$p" =~ ^[A-Z]{1,5}$ ]]; then
        echo "lv-ids: '$p' ($k) is not 1–5 capital letters" >&2; bad=1
      fi
      owner=$(printf '%s\n' $seen | awk -F= -v p="$p" '$1 == p { print $2; exit }')
      if [ -n "$owner" ] && [ "$owner" != "$k" ]; then
        echo "lv-ids: '$p' is claimed by both $owner and $k" >&2; bad=1
      fi
      seen="$seen $p=$k"
    done
  done
  return $bad
}

# lv_id_vars — set LV_<DEFAULT>, LV_<DEFAULT>_ALL and LV_<DEFAULT>_RE for every
# kind (see the header). Not exported, for the same reason as lv_id_load.
lv_id_vars() {
  local k d all var
  [ -n "${_LV_ID_LOADED:-}" ] || lv_id_load
  for k in $LV_ID_KINDS; do
    _lv_id_default_into d "$k"; d="${d%% *}"
    var="_LV_ID_$k"; all="${!var}"
    printf -v "LV_$d" '%s' "${all%% *}"
    printf -v "LV_${d}_ALL" '%s' "$all"
    printf -v "LV_${d}_RE" '%s' "${all// /|}"
  done
  LV_WORK_ALL="$LV_PLN_ALL $LV_BUG_ALL $LV_BRF_ALL"
  LV_WORK_RE="$LV_PLN_RE|$LV_BUG_RE|$LV_BRF_RE"
}

# lv_id_render — a sed-free filter (perl) that rewrites the default prefixes in
# prose to the issued ones, for install.sh to pass skills, templates and docs
# through. Only a kind whose issued prefix differs is touched, and only as a
# whole word, so a default map is a straight copy. The test kind is left out:
# a bare T is too common a word to rewrite, and its skills ask lv-test-id-next.
lv_id_render() {
  local k d p subst=""
  for k in $LV_ID_KINDS; do
    [ "$k" = test ] && continue
    d=$(_lv_id_default "$k"); d="${d%% *}"
    p=$(lv_id_prefix "$k") || return 1
    [ "$p" = "$d" ] || subst="${subst}s/\\b${d}\\b/${p}/g;"
  done
  if [ -z "$subst" ]; then cat; else perl -pe "$subst"; fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  lv_id_load
  cmd="${1:-}"; shift || true
  case "$cmd" in
    prefix)   lv_id_prefix "${1:?kind}" ;;
    prefixes) lv_id_prefixes "${1:?kind}" ;;
    match)    lv_id_match "${@:-all}" ;;
    kind)     lv_id_kind "${1:?id}" ;;
    canon)    lv_id_canon "${1:?id}" ;;
    check)    lv_id_check && echo "ids: ok" ;;
    render)   lv_id_render ;;
    list)     for k in $LV_ID_KINDS; do printf '%-9s %s\n' "$k" "$(lv_id_prefixes "$k")"; done ;;
    -h|--help|"") awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0" ;;
    *) echo "lv-ids.sh: unknown command '$cmd'" >&2; exit 2 ;;
  esac
else
  lv_id_vars
fi
