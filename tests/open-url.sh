#!/usr/bin/env bash
# open-url.sh — /lv-accept opens the app for the human, signed in as the
# account a criterion needs, instead of printing a URL and a list of accounts.
#
#   1. A plain URL opens in the configured browser, in a guest profile.
#   2. --as with a test_signin_url template opens the sign-in URL (account
#      URL-encoded) in that account's own profile, then the target.
#   3. A template with {return} opens once, with the target encoded into it.
#   4. --as with no template opens the target and names the account.
#   5. --fresh empties the profile; LV_UNATTENDED=1 opens nothing.
#
# Usage: ./tests/open-url.sh
# Exit 0 if all pass, 1 on any failure.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$REPO_ROOT/scripts/v2.00"
TEST_DIR=""
PASS=0
FAIL=0

cleanup() { [ -z "${KEEP:-}" ] && [ -n "$TEST_DIR" ] && [ -d "$TEST_DIR" ] && rm -rf "$TEST_DIR"; return 0; }
trap cleanup EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_has() { if printf '%s' "$3" | grep -qF -- "$2"; then ok "$1"; else bad "$1" "no [$2] in: $(printf '%s' "$3" | head -c 600)"; fi; }
assert_not() { if printf '%s' "$3" | grep -qF -- "$2"; then bad "$1" "unexpected [$2]"; else ok "$1"; fi; }

TEST_DIR=$(mktemp -d)
CLIENT="$TEST_DIR/client"
export TMPDIR="$TEST_DIR/tmp"
mkdir -p "$TMPDIR"

git init -q -b develop "$CLIENT"
cd "$CLIENT" || exit 1
printf 'project_slug: "open-test"\ntest_browser: "Some Browser"\n' > levain.yml

echo "1. plain URL"
out=$("$S/lv-open-url.sh" --dry-run http://localhost:8091/learners/new 2>&1)
assert_has "opens in the configured browser" "open -na Some\\ Browser" "$out"
assert_has "in the guest profile" "lv-browser/open-test/guest" "$out"
assert_has "reports what it opened" "OPENED=http://localhost:8091/learners/new" "$out"
assert_not "names no account" "SIGN_IN_AS=" "$out"

echo "2. --as with a sign-in template"
printf 'test_signin_url: "http://localhost:8084/dev/login?fixture={account}"\n' >> levain.yml
out=$("$S/lv-open-url.sh" --dry-run --as parent@example.test http://localhost:8091/household 2>&1)
assert_has "names the account" "SIGN_IN_AS=parent@example.test" "$out"
assert_has "opens the sign-in URL, account encoded" "OPENED=http://localhost:8084/dev/login?fixture=parent%40example.test" "$out"
assert_has "then the target" "OPENED=http://localhost:8091/household" "$out"
assert_has "in the account's own profile" "lv-browser/open-test/parent@example.test" "$out"
first=$(printf '%s\n' "$out" | grep -n 'OPENED=http://localhost:8084' | cut -d: -f1)
second=$(printf '%s\n' "$out" | grep -n 'OPENED=http://localhost:8091' | cut -d: -f1)
if [ -n "$first" ] && [ -n "$second" ] && [ "$first" -lt "$second" ]; then ok "sign-in before target"; else bad "sign-in before target" "$out"; fi

echo "3. a template with {return}"
sed -i.bak 's|fixture={account}"|fixture={account}\&returnUrl={return}"|' levain.yml
out=$("$S/lv-open-url.sh" --dry-run --as parent@example.test http://localhost:8091/a?b=1 2>&1)
assert_has "target encoded into the one URL" "OPENED=http://localhost:8084/dev/login?fixture=parent%40example.test&returnUrl=http%3A%2F%2Flocalhost%3A8091%2Fa%3Fb%3D1" "$out"
n=$(printf '%s\n' "$out" | grep -c '^OPENED=')
if [ "$n" = "1" ]; then ok "opened once"; else bad "opened once" "$n opens: $out"; fi

# A client's LVI-044: the app's own sign-in route, on the plan's own port.
printf 'project_slug: "open-test"\ntest_browser: "Some Browser"\ntest_signin_url: "{origin}/dev/sign-in?as={account}&p={port}&r={return}"\n' > levain.yml
out=$("$S/lv-open-url.sh" --dry-run --as kid@example.test http://localhost:8179/room 2>&1)
assert_has "{origin} and {port} are the target's" "OPENED=http://localhost:8179/dev/sign-in?as=kid%40example.test&p=8179&r=http%3A%2F%2Flocalhost%3A8179%2Froom" "$out"

echo "4. --as with no template"
printf 'project_slug: "open-test"\ntest_browser: "Some Browser"\n' > levain.yml
out=$("$S/lv-open-url.sh" --dry-run --as parent@example.test http://localhost:8091/ 2>&1)
assert_has "opens the target" "OPENED=http://localhost:8091/" "$out"
assert_has "says which account to choose" "sign in as parent@example.test when asked" "$out"

echo "5. --fresh and unattended"
out=$("$S/lv-open-url.sh" --dry-run --fresh --as a@b.test http://localhost:8091/ 2>&1)
assert_has "--fresh empties the profile" "rm -rf $TMPDIR/lv-browser/open-test/a@b.test" "$out"
out=$(LV_UNATTENDED=1 "$S/lv-open-url.sh" --dry-run http://localhost:8091/ 2>&1)
assert_not "unattended opens nothing" "OPENED=" "$out"
assert_has "and says so" "unattended — not opening" "$out"

echo
echo "open-url: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
