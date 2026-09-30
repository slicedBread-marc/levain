#!/usr/bin/env bash
# headless.sh — lv-headless-eval.sh, lv-headless-screenshot.sh,
# lv-headless-session.sh and the lv-headless-common.sh they share. /lv-test
# step 3c resolves Chrome-Assisted criteria through these, unattended, and
# their exit code IS the verdict: 0 PASS, 1 FAIL, 2 "could not run" — never a
# FAIL. A script that confused 1 and 2 would fail plans for a missing browser,
# or pass them for a broken selector. None of them had a test before 14.2.x.
#
# Two tiers:
#   contract  always runs: usage errors, no node, a failed install — with the
#             cache pointed at a scratch dir and npm stubbed
#   live      runs the real cached Chromium against local pages; skipped (and
#             said so) on a machine where the browser was never installed
#
# Usage: ./tests/headless.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SD="${LV_TEST_SCRIPT_DIR:-$REPO_ROOT/scripts/v2.00}"
PASS=0
FAIL=0
TEST_DIR=$(mktemp -d)
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT

ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1"; [ $# -gt 1 ] && echo "      $2"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want [$2], got [$3]"; fi; }
has() { if printf '%s\n' "$2" | grep -qE -- "$3"; then ok "$1"; else bad "$1" "no /$3/ in: $2"; fi; }

# run <script> args… → "<exit>|<first stdout line>"
run() { local out rc; out=$(bash "$SD/$1" "${@:2}" 2>/dev/null); rc=$?; printf '%s|%s' "$rc" "$(printf '%s' "$out" | tail -1)"; }

echo "headless.sh"
echo "================"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "1. Contract (no browser needed)"
export LV_HEADLESS_CACHE="$TEST_DIR/empty-cache"

assert_eq "eval with no arguments: usage, exit 2"      "2|ERROR usage" \
  "$(run lv-headless-eval.sh | cut -c1-13)"
assert_eq "eval with a url but no expression"          "2|ERROR usage" \
  "$(run lv-headless-eval.sh http://x | cut -c1-13)"
assert_eq "screenshot with no output path"             "2|ERROR usage" \
  "$(run lv-headless-screenshot.sh http://x | cut -c1-13)"
assert_eq "session with no spec"                       "2|ERROR usage" \
  "$(run lv-headless-session.sh | cut -c1-13)"
assert_eq "session @file that does not exist"          "2|ERROR session file not found: $TEST_DIR/nope.json" \
  "$(run lv-headless-session.sh "@$TEST_DIR/nope.json")"

# No node: a PATH with the system tools and nothing else.
nonode=$(PATH=/usr/bin:/bin bash "$SD/lv-headless-eval.sh" http://x true 2>/dev/null); nonode="$nonode|$?"
has "no node/npm on the machine: ERROR, exit 2"        "$nonode" "^ERROR no node/npm.*\|2$"

# A failed first-use install: stub npm that fails, empty cache.
mkdir -p "$TEST_DIR/stub"
printf '#!/bin/sh\necho "npm ERR! network unreachable"\nexit 1\n' > "$TEST_DIR/stub/npm"
printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/stub/node"
chmod +x "$TEST_DIR/stub/npm" "$TEST_DIR/stub/node"
failed=$(PATH="$TEST_DIR/stub:/usr/bin:/bin" bash "$SD/lv-headless-eval.sh" http://x true 2>/dev/null); failed="$failed|$?"
has "install fails (no network): ERROR, exit 2"        "$failed" "^ERROR npm install playwright failed.*\|2$"
has "and the reason is the installer's own words"      "$failed" "network unreachable"
assert_eq "no install marker is left, so the next run retries" "false" \
  "$([ -f "$LV_HEADLESS_CACHE/.installed" ] && echo true || echo false)"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "2. Live (the cached Chromium)"
REAL_CACHE="$HOME/.cache/wf-headless-browser"
if ! command -v node >/dev/null 2>&1 || [ ! -f "$REAL_CACHE/.installed" ] || [ ! -d "$REAL_CACHE/node_modules/playwright" ]; then
  echo "  - skipped: no cached headless browser on this machine ($REAL_CACHE)"
  echo "    run any lv-headless-*.sh once with network to install it"
else
  # A scratch cache that borrows the real install, so the runners these
  # scripts write never touch the shared one.
  export LV_HEADLESS_CACHE="$TEST_DIR/cache"
  mkdir -p "$LV_HEADLESS_CACHE"
  ln -s "$REAL_CACHE/node_modules" "$LV_HEADLESS_CACHE/node_modules"
  touch "$LV_HEADLESS_CACHE/.installed"

  mkdir -p "$TEST_DIR/www"
  cat > "$TEST_DIR/www/index.html" <<'HTML'
<!doctype html><html><body>
<h1 id="t">hello</h1>
<button id="b" onclick="document.getElementById('t').textContent='clicked'">go</button>
<input id="i">
<button id="c" onclick="document.cookie='device=one; path=/'">cookie</button>
<div id="v"></div>
<span id="h" onmouseenter="this.textContent='hovered'">tray</span>
<x-menu id="m"></x-menu>
<script>
  customElements.define('x-menu', class extends HTMLElement {
    connectedCallback() { this.attachShadow({ mode: 'open' }).innerHTML = '<button id="s" onclick="this.textContent=\'shadow\'">in</button>'; }
  });
  const n = Number(localStorage.getItem('visits') || 0) + 1;
  localStorage.setItem('visits', n);
  document.getElementById('v').textContent = n;
  console.error('boom from the page');
</script>
</body></html>
HTML
  cat > "$TEST_DIR/www/files.html" <<'HTML'
<!doctype html><html><body>
<a id="dl" href="data:text/csv;charset=utf-8,name%2Cscore%0Aellie%2C9" download="scores.csv">export</a>
<input id="f" type="file" onchange="f.files[0].text().then(t => { out.textContent = f.files[0].name + ':' + t })">
<button id="pick" onclick="f.click()">choose</button>
<div id="out"></div>
<button id="copy" onclick="navigator.clipboard.writeText('share-code-42')">copy</button>
<textarea id="paste"></textarea>
</body></html>
HTML
  cat > "$TEST_DIR/www/tall.html" <<'HTML'
<!doctype html><html><body style="margin:0"><div style="height:2000px">tall</div></body></html>
HTML
  PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  ( cd "$TEST_DIR/www" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  SERVER_PID=$!; disown "$SERVER_PID" 2>/dev/null
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.1; done
  U="http://127.0.0.1:$PORT/index.html"

  echo "  eval"
  assert_eq "a true expression: PASS, exit 0"          '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('t').textContent === 'hello'")"
  assert_eq "a false one: FAIL, exit 1"                '1|FAIL false' \
    "$(run lv-headless-eval.sh "$U" "document.title === 'nope'")"
  assert_eq "the value is reported, not just its truth" '0|PASS "hello"' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('t').textContent")"
  r=$(run lv-headless-eval.sh "$U" "document.querySelector('#missing').textContent")
  assert_eq "an expression that throws is ERROR (2), never FAIL" "2" "${r%%|*}"
  assert_eq "actions run before the expression (click)" '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('t').textContent === 'clicked'" '[{"type":"click","selector":"#b"}]')"
  assert_eq "fill"                                     '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('i').value === 'typed'" '[{"type":"fill","selector":"#i","value":"typed"}]')"
  assert_eq "hover"                                    '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('h').textContent === 'hovered'" '[{"type":"hover","selector":"#h"}]')"
  assert_eq "a page-level Tab moves focus (no selector)" '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.activeElement.id === 'i'" '[{"type":"focus","selector":"#b"},{"type":"press","key":"Tab"}]')"
  assert_eq "keyboard: Shift+Tab goes back"            '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.activeElement.id === 'b'" '[{"type":"focus","selector":"#i"},{"type":"keyboard","key":"Shift+Tab"}]')"
  assert_eq "a CSS selector pierces open shadow DOM"   '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('m').shadowRoot.getElementById('s').textContent === 'shadow'" '[{"type":"click","selector":"x-menu button"}]')"
  assert_eq "reload: state that survives a refresh"    '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "document.getElementById('v').textContent === '2'" '[{"type":"reload"}]')"
  assert_eq "consoleErrors holds the page's errors"    '0|PASS true' \
    "$(run lv-headless-eval.sh "$U" "consoleErrors.some(e => e.includes('boom from the page'))")"
  assert_eq "the default viewport is mobile, 390 wide" '0|PASS 390' \
    "$(run lv-headless-eval.sh "$U" "window.innerWidth")"
  assert_eq "width and height set a breakpoint"        '0|PASS 1280' \
    "$(run lv-headless-eval.sh "$U" "window.innerWidth" '[]' 1280 800)"
  # Downloads, uploads and the clipboard: an unattended tester had no verb for
  # any of them and recorded all 7 of a plan's criteria as "needs: device"
  # (LVI-036).
  F="http://127.0.0.1:$PORT/files.html"
  assert_eq "download: the file is kept, with its name and text" '0|PASS true' \
    "$(run lv-headless-eval.sh "$F" "downloads.length === 1 && downloads[0].filename === 'scores.csv' && downloads[0].text.startsWith('name,score')" '[{"type":"download","selector":"#dl"}]')"
  assert_eq "download: its size is reported"          '0|PASS 18' \
    "$(run lv-headless-eval.sh "$F" "downloads[0].size" '[{"type":"download","selector":"#dl"}]')"
  assert_eq "upload: inline content into a file input" '0|PASS "a.csv:x,y"' \
    "$(run lv-headless-eval.sh "$F" "document.getElementById('out').textContent" '[{"type":"upload","selector":"#f","files":[{"name":"a.csv","mimeType":"text/csv","text":"x,y"}]},{"type":"waitForSelector","selector":"#out:not(:empty)"}]')"
  printf 'from disk' > "$TEST_DIR/note.txt"
  assert_eq "upload: a path, through the chooser a button opens" '0|PASS "note.txt:from disk"' \
    "$(run lv-headless-eval.sh "$F" "document.getElementById('out').textContent" '[{"type":"upload","click":"#pick","files":["'"$TEST_DIR/note.txt"'"]},{"type":"waitForSelector","selector":"#out:not(:empty)"}]')"
  assert_eq "clipboard: what a copy button wrote"     '0|PASS "share-code-42"' \
    "$(run lv-headless-eval.sh "$F" "clipboard" '[{"type":"click","selector":"#copy"},{"type":"clipboard"}]')"
  assert_eq "clipboardWrite seeds a paste"            '0|PASS "pasted-in"' \
    "$(run lv-headless-eval.sh "$F" "document.getElementById('paste').value" '[{"type":"clipboardWrite","text":"pasted-in"},{"type":"focus","selector":"#paste"},{"type":"keyboard","key":"ControlOrMeta+V"}]')"
  assert_eq "session exprs see downloads too"         '0|PASS "scores.csv"' \
    "$(run lv-headless-session.sh '{"contexts":[{"name":"a","url":"'"$F"'","actions":[{"type":"download","selector":"#dl"}]}],"expr":{"context":"a","js":"downloads[0].filename"}}')"
  r=$(run lv-headless-eval.sh "$U" "true" '[{"type":"wave"}]')
  assert_eq "an unknown action is ERROR, naming it"    "2|ERROR unknown action type: wave" "$r"
  r=$(run lv-headless-eval.sh "$U" "true" '[{"type":"waitForSelector","selector":"#never","timeout":300}]')
  assert_eq "a selector that never appears is ERROR"   "2" "${r%%|*}"
  DEAD=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  r=$(run lv-headless-eval.sh "http://127.0.0.1:$DEAD/" "true")
  assert_eq "a server that is not there is ERROR"      "2" "${r%%|*}"

  echo "  screenshot"
  png_size() { python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); print("%dx%d" % struct.unpack(">II", d[16:24]) if d[:8]==b"\x89PNG\r\n\x1a\n" else "not-a-png")' "$1"; }
  S="$TEST_DIR/shots/full.png"
  assert_eq "saves and says where: OK, exit 0"         "0|OK $S" \
    "$(run lv-headless-screenshot.sh "http://127.0.0.1:$PORT/tall.html" "$S")"
  assert_eq "full page by default (the whole 2000px)"  "390x2000" "$(png_size "$S")"
  S2="$TEST_DIR/shots/fold.png"
  run lv-headless-screenshot.sh "http://127.0.0.1:$PORT/tall.html" "$S2" --viewport >/dev/null
  assert_eq "--viewport stops at the fold (390x844)"   "390x844" "$(png_size "$S2")"
  S3="$TEST_DIR/shots/desk.png"
  run lv-headless-screenshot.sh --viewport "http://127.0.0.1:$PORT/tall.html" "$S3" '[]' 1280 800 >/dev/null
  assert_eq "flags go anywhere; width/height apply"     "1280x800" "$(png_size "$S3")"
  r=$(run lv-headless-screenshot.sh "http://127.0.0.1:$DEAD/" "$TEST_DIR/shots/none.png")
  assert_eq "a failed navigation is ERROR, and no file" "2|false" \
    "${r%%|*}|$([ -f "$TEST_DIR/shots/none.png" ] && echo true || echo false)"

  echo "  session"
  two='{"contexts":[{"name":"a","url":"'"$U"'"},{"name":"b","url":"'"$U"'"}],
        "steps":[{"context":"a","actions":[{"type":"click","selector":"#c"}]},
                 {"context":"b","actions":[{"type":"reload"}]}],'
  assert_eq "a cookie set in one context is there"     '0|PASS true' \
    "$(run lv-headless-session.sh "$two"'"expr":{"context":"a","js":"document.cookie.includes(\"device=one\")"}}')"
  assert_eq "and not in the other: each is a device"   '0|PASS true' \
    "$(run lv-headless-session.sh "$two"'"expr":{"context":"b","js":"!document.cookie.includes(\"device=one\")"}}')"
  assert_eq "a falsy verdict is FAIL, exit 1"          '1|FAIL false' \
    "$(run lv-headless-session.sh "$two"'"expr":{"context":"b","js":"document.cookie.includes(\"device=one\")"}}')"
  printf '%s' "$two"'"expr":{"context":"a","js":"true"}}' > "$TEST_DIR/s.json"
  assert_eq "@file reads the spec from a file"         '0|PASS true' "$(run lv-headless-session.sh "@$TEST_DIR/s.json")"
  r=$(run lv-headless-session.sh '{"contexts": [')
  has "malformed JSON is ERROR"                        "$r" "^2\|ERROR session json is not valid JSON"
  assert_eq "no contexts is ERROR, pointing at eval"   "2|ERROR session has no contexts - use lv-headless-eval.sh for a single page" \
    "$(run lv-headless-session.sh '{"contexts":[],"expr":{"context":"a","js":"true"}}')"
  assert_eq "no expr is ERROR"                         "2|ERROR session has no expr.js - one boolean expression is the verdict" \
    "$(run lv-headless-session.sh '{"contexts":[{"name":"a"}]}')"
  assert_eq "a duplicate context name is ERROR"        '2|ERROR duplicate context name "a"' \
    "$(run lv-headless-session.sh '{"contexts":[{"name":"a"},{"name":"a"}],"expr":{"context":"a","js":"true"}}')"
  assert_eq "an expr naming no opened context is ERROR" '2|ERROR expr names context "z", which was never opened' \
    "$(run lv-headless-session.sh '{"contexts":[{"name":"a"}],"expr":{"context":"z","js":"true"}}')"
fi

echo
echo "================"
echo "Passed: $PASS   Failed: $FAIL"
[ "$FAIL" -eq 0 ]
