#!/usr/bin/env bash
# lv-skills.sh [--full] [--check] [--dir <skills-dir>]
#
# The skill index: every installed skill with its one-line purpose, built from
# the skills' own files so it cannot go stale. lv-help drifted for months
# because it was a second copy of what the skills said; this reads the
# originals every time (skill audit, LVI-012).
#
#   (default)   one line per skill, then the moved names and where they went
#   --full      the same, followed by each skill's ## Usage block
#   --check     exit 1, naming each skill that has no ## Usage block (tests)
#   --dir DIR   read DIR instead of the project's .claude/skills/ (or, in the
#               library itself, skills/)
#
# The purpose line is the first sentence of the frontmatter description. An
# alias is a skill whose description starts "Alias:" — an old name kept so
# muscle memory still works; it is listed under "Moved", not as a skill.
set -euo pipefail

full=false check=false dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --full)  full=true; shift ;;
    --check) check=true; shift ;;
    --dir)   dir="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "lv-skills.sh: unknown argument '$1'" >&2; exit 1 ;;
  esac
done

if [ -z "$dir" ]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  if [ -d "$root/.claude/skills" ]; then dir="$root/.claude/skills"; else dir="$root/skills"; fi
fi
[ -d "$dir" ] || { echo "lv-skills.sh: no skills directory at $dir" >&2; exit 1; }

# One awk per file: name, description, and the Usage block, 0x1f-separated.
read_skill() {
  awk '
    NR == 1 && /^---$/ { fm = 1; next }
    fm && /^---$/      { fm = 0; next }
    fm && /^name:/        { sub(/^name:[ \t]*/, ""); name = $0 }
    fm && /^description:/ { sub(/^description:[ \t]*/, ""); gsub(/^"|"$/, ""); desc = $0 }
    /^## Usage[ \t]*$/ { inu = 1; next }
    inu && /^```/      { if (open) { inu = 0; open = 0 } else open = 1; next }
    inu && open        { usage = usage (usage == "" ? "" : "\n") $0 }
    END { printf "%s\x1f%s\x1f%s", name, desc, usage }
  ' "$1"
}

skills=() aliases=() missing=()
for f in "$dir"/*/SKILL.md; do
  [ -f "$f" ] || continue
  rec=$(read_skill "$f")
  name=${rec%%$'\x1f'*}; rest=${rec#*$'\x1f'}
  desc=${rest%%$'\x1f'*}; usage=${rest#*$'\x1f'}
  [ -n "$name" ] || name=$(basename "$(dirname "$f")")
  case "$desc" in
    Alias:*) aliases+=("$name"$'\x1f'"${desc#Alias: }") ;;
    *)       skills+=("$name"$'\x1f'"$desc"$'\x1f'"$usage")
             [ -n "$usage" ] || missing+=("$name") ;;
  esac
done

if $check; then
  [ ${#missing[@]} -eq 0 ] && { echo "lv-skills: every skill has a usage block"; exit 0; }
  printf 'lv-skills: no ## Usage block in: %s\n' "${missing[*]}" >&2
  exit 1
fi

# The first sentence: up to ". " or the end, never mid-word.
first_sentence() { printf '%s' "$1" | sed -E 's/([.!?])[[:space:]].*$/\1/'; }

echo "Skills — run /<skill> help for any one of them"
echo
for s in "${skills[@]}"; do
  name=${s%%$'\x1f'*}; rest=${s#*$'\x1f'}; desc=${rest%%$'\x1f'*}
  printf '  /%-16s %s\n' "$name" "$(first_sentence "$desc")"
done
if [ ${#aliases[@]} -gt 0 ]; then
  echo
  echo "Moved — the old name still works:"
  for a in "${aliases[@]}"; do
    name=${a%%$'\x1f'*}; to=${a#*$'\x1f'}
    printf '  /%-16s %s\n' "$name" "$(first_sentence "$to")"
  done
fi
if $full; then
  for s in "${skills[@]}"; do
    name=${s%%$'\x1f'*}; rest=${s#*$'\x1f'}; usage=${rest#*$'\x1f'}
    [ -n "$usage" ] || continue
    printf '\n── /%s ──\n%s\n' "$name" "$usage"
  done
fi
