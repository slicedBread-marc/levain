#!/usr/bin/env bash
# intake-groups.sh — a batch of related bugs goes to /lv-spec together (LVI-024)
#
#   1. Who may group: a pipeline worker is refused (exit 6).
#   2. open / add / seal / dissolve, committed; members carry Group:.
#   3. lv-list-specable.sh: an Open group's members are not offered; once
#      sealed, only the lead, carrying the rest; the default lead amends no
#      other member.
#   4. A member already consumed into a draft plan holds that plan until seal;
#      one whose plan is active is refused (exit 4).
#   5. consume refuses while a member is still in bugs/open.
#   6. Amends without a group: the amender is carried by its open target, a
#      chain resolves to its root, and a consumed target is named with its
#      plan's state.
#   7. lv-bug-new.sh --group files into a group; an amender joins its target's
#      open group unasked; a worker's --group is refused before allocation.
#   8. A coordinator files into a group through lv-dep-notify --group and
#      seals it with --project.
#   9. dissolve releases members; list --stale finds a forgotten group.
#  10. The skills say how.
#  11. A bug grouped after its spec run was dispatched (LVI-026): the run
#      stands down at lv-plan-id.sh (exit 4) or lv-bug-consume.sh (exit 3);
#      a plan already drafted is held; seal --lead may name a member whose
#      plan is still in spec, and the rest amend it together.
#
# Usage: ./tests/intake-groups.sh     Exit 0 if all pass, 1 on any failure.

set -uo pipefail

LIB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_FOLDER=$(awk '{sub(/#.*/, "")} NF >= 2 {folder = $2} END {print folder}' "$LIB_ROOT/scripts/version-map.txt")
S="${LV_TEST_SCRIPT_DIR:-$LIB_ROOT/scripts/$SCRIPT_FOLDER}"
PASS=0
FAIL=0
TEST_DIR=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }
section() { echo "── $1 ──"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset LV_UNATTENDED LV_DIRECT_FROM LV_GROUP_FROM

P="$TEST_DIR/proj"
mkdir -p "$P/plans" "$P/scripts" "$P/bugs/open" "$P/.claude/orchestrator/gates/resolved"
cd "$P" || exit 1
git init -q -b develop
cat > levain.yml <<'YML'
project_slug: "proj"
orchestrator:
  enabled: true
  max_spawns_per_hour: 0
YML
printf '.claude/orchestrator/\n' > .gitignore
printf '#!/usr/bin/env bash\nn="$1"; shift; exec "%s/$n" "$@"\n' "$S" > scripts/lv-exec.sh
chmod +x scripts/lv-exec.sh
cat > plans/REGISTRY.md <<'SEED'
# Plan Registry

| ID | Slug | State | Priority | Branch | Updated | WF | Tags | Deps |
|-|-|-|-|-|-|-|-|-|
| PLN-041 | open-answers | active | — | — | 2026-10-02 | 2.00 | — | — |
| PLN-044 | wide-page | draft | — | — | 2026-10-02 | 2.00 | — | — |

<!-- Counter: 60 -->
SEED
for p in 041-open-answers 044-wide-page; do
  mkdir -p "plans/PLN-$p"; printf '# PLN-%s\n\n## Goal\nx\n' "$p" > "plans/PLN-$p/plan.md"
done

# bug <id> <slug> [stage] [links] [plan]
bug() {
  local stage="${3:-open}"
  mkdir -p "bugs/$stage/$1-$2"
  printf '# %s\n\n> **Status:** Open\n> **ID:** %s\n> **Severity:** Medium\n> **Plan:** %s\n> **Links:** %s\n\n## Description\nx\n' \
    "$2" "$1" "${5:-_(none)_}" "${4:-_(none)_}" > "bugs/$stage/$1-$2/bug.md"
}
bug BUG-041 open-answers triaged "_(none)_" PLN-041-open-answers
bug BUG-042 rubric
bug BUG-043 hints
bug BUG-044 wide-page triaged "_(none)_" PLN-044-wide-page
bug BUG-046 she-wrote
bug BUG-047 amend-041 open "Amends BUG-041"
bug BUG-048 amend-043 open "Amends BUG-043"
bug BUG-049 amend-046 open "Amends BUG-046"
git add -A >/dev/null; git commit -qm seed

G() { "$S/lv-bug-group.sh" "$@"; }
spec_out() { "$S/lv-list-specable.sh" 2>/dev/null; }
spec_err() { "$S/lv-list-specable.sh" 2>&1 >/dev/null; }
row() { spec_out | awk -F'\t' -v id="$1" '$1 == id'; }

section "1. who may group"
LV_UNATTENDED=1 G open batch "x" >/dev/null 2>&1
assert_eq "a pipeline worker is refused" "$?" "6"
assert_eq "and nothing was written" "$([ -e bugs/groups/batch.md ] && echo yes || echo no)" "no"
G open "Not A Slug" "x" >/dev/null 2>&1
assert_eq "a slug is kebab-case" "$?" "1"

section "6. Amends without a group"
# Before any group exists: 047 amends 041 (consumed into an ACTIVE plan),
# 048 amends 043 (open), 049 amends 046 (open).
out=$(spec_out); err=$(spec_err)
assert_eq "an amender whose target is open is not offered on its own" "$(row BUG-048)" ""
has "and says it is carried" "$err" "BUG-048 not offered — amends BUG-043, still open"
has "the target carries it" "$(row BUG-043)" "+BUG-048 (amending it)"
has "an amender of a consumed target is offered, naming the built plan" "$(row BUG-047)" "target PLN-041 active: new plan with Deps PLN-041"
bug BUG-050 amend-049 open "Amends BUG-049"
has "a chain resolves to its root" "$(row BUG-046)" "BUG-049,BUG-050"
assert_eq "and the middle of the chain is not offered" "$(row BUG-049)" ""
rm -rf bugs/open/BUG-050-amend-049

# A client's LVI-027: the chain's end was blocked on another bug, and the
# amender sat unoffered saying only "still open". The block is named, both in
# the withheld line and on the board.
bug BUG-050 amend-049 open "Amends BUG-049"
sed -i.bak 's/^> \*\*Links:\*\*/> **Blocked:** BUG-023 — needs the photo hand-in first\n&/' bugs/open/BUG-046-she-wrote/bug.md
rm -f bugs/open/BUG-046-she-wrote/bug.md.bak
err=$(spec_err)
has "an amender of a blocked chain names the block" "$err" "BUG-046 is blocked (BUG-023 — needs the photo hand-in first)"
has "and the way out" "$err" "drop this bug's Amends link"
has "the board shows the wait" "$("$S/lv-tray.sh" --plans --plain 2>/dev/null)" "waits on BUG-046, blocked: BUG-023"
git checkout -- bugs/open/BUG-046-she-wrote/bug.md
rm -rf bugs/open/BUG-050-amend-049

section "2. open, add, seal"
out=$(G open she-wrote "BUG-046 reshapes 041/043" 2>&1); rc=$?
assert_eq "open" "$rc" "0"
has "committed" "$(git log -1 --format=%s)" "bug-group(she-wrote): opened"
out=$(G add she-wrote BUG-042 BUG-043 BUG-046 BUG-047 BUG-048 BUG-049 2>&1); rc=$?
assert_eq "add" "$rc" "0"
has "members carry Group:" "$(cat bugs/open/BUG-046-she-wrote/bug.md)" "> **Group:** she-wrote"
assert_eq "one commit, members and record together" "$(git show --name-only --format= HEAD | grep -c .)" "7"
assert_eq "the tree is clean after add" "$(git status --porcelain | grep -v '^??' | grep -c .)" "0"

section "3. an Open group is not offered"
for b in BUG-042 BUG-043 BUG-046 BUG-047 BUG-048 BUG-049; do
  assert_eq "$b withheld while open" "$(row "$b")" ""
done
has "and says how to release it" "$(spec_err)" "held in intake group she-wrote, open since"
has "with the seal command" "$(spec_err)" "lv-bug-group.sh seal she-wrote"

section "4. members already in a plan"
G add she-wrote BUG-041 >/dev/null 2>&1
assert_eq "a member whose plan is active is refused" "$?" "4"
hasnt "and is not added" "$(cat bugs/triaged/BUG-041-open-answers/bug.md)" "Group:"
out=$(G add she-wrote BUG-044 2>&1); rc=$?
assert_eq "a member whose plan is draft is added" "$rc" "0"
has "and its plan is held" "$out" "PLN-044 (draft) held until the group is sealed"
has "a hold directive is on the plan" "$("$S/lv-direct.sh" status PLN-044)" "DIRECTIVE_HOLD='D-1'"
has "the group records the hold" "$(cat bugs/groups/she-wrote.md)" "PLN-044:D-1"

section "3b. seal"
out=$(G seal she-wrote 2>&1); rc=$?
assert_eq "seal" "$rc" "0"
has "the default lead amends no other member" "$out" "takes BUG-042"
G show she-wrote >/dev/null 2>&1 || true
# Re-seal with the lead the overseer named: dissolve is not needed — remove
# the Sealed state by hand-free route: a fresh group in section 7 tests --lead.
assert_eq "the hold is released at seal" "$("$S/lv-direct.sh" status PLN-044 | grep DIRECTIVE_HOLD)" "DIRECTIVE_HOLD=''"
has "the lead is offered" "$(row BUG-042)" "GROUP(she-wrote) +BUG-043,BUG-046,BUG-047,BUG-048,BUG-049"
for b in BUG-043 BUG-046 BUG-047 BUG-048 BUG-049; do
  assert_eq "$b carried, not offered alone" "$(row "$b")" ""
done
has "and the reason names the lead" "$(spec_err)" "carried with BUG-042, the lead of sealed group she-wrote"

section "5. consume"
G consume she-wrote PLN-042 >/dev/null 2>&1
assert_eq "refused while members are open" "$?" "2"
for b in 042-rubric 043-hints 046-she-wrote 047-amend-041 048-amend-043 049-amend-046; do
  mkdir -p bugs/closed; git mv "bugs/open/BUG-$b" "bugs/closed/BUG-$b"
done
git commit -qm "members leave open"
LV_UNATTENDED=1 G consume she-wrote PLN-042 >/dev/null 2>&1
assert_eq "a worker may consume (lv-spec finishes a group)" "$?" "0"
has "Consumed, naming the plan" "$(cat bugs/groups/she-wrote.md)" "> **Consumed:**"
hasnt "a consumed group is not listed" "$(G list 2>/dev/null)" "she-wrote"

section "7. lv-bug-new --group"
LV_UNATTENDED=1 "$S/lv-bug-new.sh" "worker report" --group late >/dev/null 2>&1
assert_eq "a worker's --group is refused" "$?" "1"
assert_eq "before a number is allocated" "$(grep -o 'Counter: [0-9]*' plans/REGISTRY.md)" "Counter: 60"
eval "$("$S/lv-bug-new.sh" "first of a batch" --group late 2>/dev/null)"
first="$BUG_ID"
has "--group opens the group and joins it" "$(cat "$BUG_DIR/bug.md")" "> **Group:** late"
assert_eq "the group is Open" "$("$S/lv-bug-group.sh" of "$first" | grep GROUP_STATUS)" "GROUP_STATUS='Open'"
eval "$("$S/lv-bug-new.sh" "corrects the first" --links "Amends $first" 2>/dev/null)"
has "an amender joins its target's open group unasked" "$(cat "$BUG_DIR/bug.md")" "> **Group:** late"
second="$BUG_ID"
out=$(G seal late --lead "$second" 2>&1)
has "--lead overrides the default" "$out" "takes $second, carrying $first"
has "the named lead is offered" "$(row "$second")" "GROUP(late) +$first"
assert_eq "the tree is clean" "$(git status --porcelain | grep -v '^??' | grep -c .)" "0"

section "9. dissolve, stale"
eval "$("$S/lv-bug-new.sh" "forgotten" --group forgotten 2>/dev/null)"
f="$BUG_ID"
assert_eq "not offered while open" "$(row "$f")" ""
sed -i.bak 's/^> \*\*Opened:\*\* [^ ]*/> **Opened:** 2026-01-01T00:00:00Z/' bugs/groups/forgotten.md && rm -f bugs/groups/forgotten.md.bak
has "list --stale finds a forgotten open group" "$(G list --stale)" "forgotten"
hasnt "and not a sealed one" "$(G list --stale)" "late"
G dissolve forgotten "never sealed" >/dev/null 2>&1
assert_eq "dissolve" "$?" "0"
hasnt "members lose Group:" "$(cat bugs/open/$f-*/bug.md)" "Group:"
has "and are offered on their own" "$(row "$f")" "$f"

section "8. from a coordinator"
C="$TEST_DIR/coord"
mkdir -p "$C"; git -C "$C" init -q
printf 'project_slug: "overseer"\nrole: coordinator\ncoordinates:\n  - "proj:%s"\n' "$P" > "$C/levain.yml"
out=$(cd "$C" && "$S/lv-dep-notify.sh" "request one" --kind request --to proj --group coord-batch 2>&1); rc=$?
assert_eq "lv-dep-notify --group files" "$rc" "0"
has "and prints the group and how to seal it" "$out" "held from /lv-spec until: lv-bug-group.sh --project proj seal coord-batch"
has "recorded as the coordinator" "$(cat bugs/groups/coord-batch.md)" "by coordinator:overseer"
out=$(cd "$C" && "$S/lv-bug-group.sh" --project proj seal coord-batch 2>&1); rc=$?
assert_eq "the coordinator seals it through the target's harness" "$rc" "0"
has "committed in the target" "$(git log -1 --format=%s)" "bug-group(coord-batch): sealed"
(cd "$C" && LV_UNATTENDED=1 "$S/lv-bug-group.sh" --project proj open x "y" >/dev/null 2>&1)
assert_eq "a worker in the coordinator is refused" "$?" "6"
"$S/lv-bug-group.sh" --project proj open x "y" >/dev/null 2>&1
assert_eq "--project from a project that is not a coordinator is refused" "$?" "6"

section "11. grouped after its spec run was dispatched (LVI-026)"
bug BUG-070 raced
bug BUG-071 drafted-first
bug BUG-072 lead-in-spec triaged "_(none)_" PLN-072-lead-in-spec
bug BUG-073 amends-lead
for p in 071-drafted-first 072-lead-in-spec; do
  mkdir -p "plans/PLN-$p"; printf '# PLN-%s\n\n## Goal\n> **Bug:** BUG-%s\nx\n' "$p" "${p%%-*}" > "plans/PLN-$p/plan.md"
done
awk '/^<!-- Counter/ { print "| PLN-071 | drafted-first | draft | — | — | 2026-10-02 | 2.00 | — | — |"; print "| PLN-072 | lead-in-spec | draft | — | — | 2026-10-02 | 2.00 | — | — |"; print ""; } { print }' \
  plans/REGISTRY.md | awk 'NF || !blank { print } { blank = !NF }' > plans/REGISTRY.tmp && mv plans/REGISTRY.tmp plans/REGISTRY.md
git add -A >/dev/null; git commit -qm "race seed"
sleep 300 & holder=$!
"$S/lv-claim.sh" BUG-070 --pid "$holder" >/dev/null 2>&1
out=$(G add race BUG-070 BUG-071 BUG-072 BUG-073 --create "BUG-072 leads; the rest amend it" 2>&1); rc=$?
assert_eq "add a bug a spec run has claimed" "$rc" "0"
has "add says a spec run holds it and where it stands down" "$out" "BUG-070: a spec run holds its claim"
has "a plan drafted from an open member is held" "$out" "BUG-071: PLN-071 (draft) held"
pid_out=$("$S/lv-plan-id.sh" BUG-070 2>/dev/null); rc=$?
assert_eq "lv-plan-id.sh refuses an Open group's member" "$rc" "4"
has "with PLAN_ID empty" "$pid_out" "PLAN_ID=''"
has "and the reason" "$pid_out" "PLAN_ID_HELD='in intake group race, still Open"
"$S/lv-plan-id.sh" BUG-070 --peek >/dev/null 2>&1
assert_eq "--peek still answers" "$?" "0"
"$S/lv-bug-consume.sh" BUG-071 PLN-071-drafted-first >/dev/null 2>&1
assert_eq "lv-bug-consume.sh refuses an Open group's member" "$?" "3"
assert_eq "and nothing moved" "$([ -d bugs/open/BUG-071-drafted-first ] && echo open)" "open"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
"$S/lv-unclaim.sh" BUG-070 >/dev/null 2>&1 || true

G seal race --lead BUG-041 >/dev/null 2>&1
assert_eq "--lead naming a non-member is refused" "$?" "1"
out=$(G seal race --lead BUG-072 2>&1); rc=$?
assert_eq "--lead may name a member whose plan is still in spec" "$rc" "0"
has "and says the rest amend it" "$out" "lead BUG-072 is PLN-072 (draft, held); /lv-spec amends it with BUG-070, BUG-071, BUG-073"
has "the lead plan stays held" "$("$S/lv-direct.sh" status PLN-072)" "DIRECTIVE_HOLD='D-"
assert_eq "the other members' plans are released" "$("$S/lv-direct.sh" status PLN-071 | grep DIRECTIVE_HOLD)" "DIRECTIVE_HOLD=''"
has "the group names its lead plan" "$(cat bugs/groups/race.md)" "> **Lead plan:** PLN-072"
has "the lowest open member carries the rest as an amendment" "$(row BUG-070)" "GROUP(race) lead BUG-072 is PLN-072 draft: amend it with this +BUG-071,BUG-073"
assert_eq "the others are not offered alone" "$(row BUG-073)" ""
has "and say who carries them" "$(spec_err)" "carried with BUG-070, amending PLN-072"
"$S/lv-plan-id.sh" BUG-073 >/dev/null 2>&1
assert_eq "a member is not drafted as a plan of its own while the lead plan is in spec" "$?" "4"
for b in 070-raced 071-drafted-first 073-amends-lead; do git mv "bugs/open/BUG-$b" "bugs/closed/BUG-$b"; done
git commit -qm "members amend PLN-072"
LV_UNATTENDED=1 G consume race PLN-072 >/dev/null 2>&1
assert_eq "a worker consumes the group" "$?" "0"
assert_eq "and consume releases the lead plan's hold" "$("$S/lv-direct.sh" status PLN-072 | grep DIRECTIVE_HOLD)" "DIRECTIVE_HOLD=''"

section "10. the skills say how"
grep -q 'lv-bug-group.sh' "$LIB_ROOT/skills/lv-spec/SKILL.md" && ok "lv-spec consumes a sealed group" || bad "lv-spec consumes a sealed group"
grep -q -- '--group' "$LIB_ROOT/skills/lv-dep-notify/SKILL.md" && ok "lv-dep-notify files a batch into a group" || bad "lv-dep-notify files a batch into a group"
grep -q -- '--group' "$LIB_ROOT/skills/lv-bug/SKILL.md" && ok "lv-bug files a batch into a group" || bad "lv-bug files a batch into a group"
grep -q 'lv-bug-group.sh' "$LIB_ROOT/install.sh" && ok "a coordinator gets lv-bug-group.sh" || bad "a coordinator gets lv-bug-group.sh"

echo
echo "intake-groups: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
