#!/usr/bin/env bash
# headless.sh — lv-headless-eval.sh, lv-headless-screenshot.sh, lv-headless-layout.sh,
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
NAV_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; [ -n "$NAV_PID" ] && kill "$NAV_PID" 2>/dev/null; rm -rf "$TEST_DIR"' EXIT

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
assert_eq "layout with no url"                         "2|ERROR usage" \
  "$(run lv-headless-layout.sh | cut -c1-13)"
has "layout: --sizes that are not WxH" \
  "$(run lv-headless-layout.sh http://x --sizes big)" '^2\|ERROR --sizes must be'
has "layout: a third positional (split actions-json)" \
  "$(run lv-headless-layout.sh http://x '[{"type":"click"' '"selector":"x"}]')" '^2\|ERROR argument past the last one'
assert_eq "session with no spec"                       "2|ERROR usage" \
  "$(run lv-headless-session.sh | cut -c1-13)"
assert_eq "session @file that does not exist"          "2|ERROR session file not found: $TEST_DIR/nope.json" \
  "$(run lv-headless-session.sh "@$TEST_DIR/nope.json")"

# A misquoted actions-json is refused before anything touches the disk
# (LVI-026: a fragment in the output-path slot became a directory in the tree).
mkdir -p "$TEST_DIR/cwd"
r=$(cd "$TEST_DIR/cwd" && run lv-headless-screenshot.sh http://x '{"type":"goto","url":"/a/b"}')
has "screenshot: JSON in the output-path slot is refused" "$r" '^2\|ERROR output path looks like JSON'
assert_eq "  and no directory is made from it"           "" "$(ls -A "$TEST_DIR/cwd")"
has "screenshot: an output path with no image extension" \
  "$(run lv-headless-screenshot.sh http://x /tmp/shot)" '^2\|ERROR output path must end'
has "eval: split actions-json (extra arguments)" \
  "$(run lv-headless-eval.sh http://x true '[{"type":"click"' '"selector":"x"}]' 1 2)" '^2\|ERROR 1 argument\(s\) past'
has "eval: actions that are not one JSON array" \
  "$(run lv-headless-eval.sh http://x true 'type:click')" '^2\|ERROR actions-json must be'
has "eval: a width that is not a number" \
  "$(run lv-headless-eval.sh http://x true '[]' '"x"}]')" '^2\|ERROR width and height'

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
  # The layout audit's two fixtures (LVI-044): one that passes at both widths,
  # and one with each defect a client's phone-width screenshots let through.
  cat > "$TEST_DIR/www/layout-good.html" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
body{margin:0;padding:16px;font:16px/1.5 sans-serif} button,a.btn{display:inline-block;min-height:44px;padding:10px} label{display:flex;gap:8px;align-items:center;min-height:32px}
.sr{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}
.cp{position:absolute;clip-path:inset(50%);width:1px;height:1px;white-space:nowrap}
</style></head><body>
<h1 class="sr">A landing heading kept for screen readers only (LVI-047)</h1>
<div class="cp">Skip to the main content of this page</div>
<p>Read the <a href="/g">guide</a> before you start the round today.</p>
<a class="btn" href="/x">Start</a> <button>Check</button>
<form><label><input type="radio" name="q"> A long answer that wraps over more than one line at phone width easily enough</label>
<label for="e">Email</label><input id="e" style="height:40px"></form>
</body></html>
HTML
  cat > "$TEST_DIR/www/layout-bad.html" <<'HTML'
<!doctype html><html><head><meta name="viewport" content="width=device-width"><style>
body{margin:0;font:16px/1.2 sans-serif} form.q label{display:inline-block} .wide{width:600px} .box{width:80px;white-space:nowrap}
a.guide{font-size:13px;display:block;line-height:18px}
</style></head><body>
<form class="q"><input type="radio" id="r1" name="q"><label for="r1">A long answer that wraps over more than one line at phone width, so the inline-block label drops below the radio</label></form>
<div><a class="guide" href="/guide">Guide</a></div>
<div class="box">marbles marbles marbles today</div>
<div class="wide">wide</div>
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

  echo "  navigation (LVI-043)"
  # A submit the page starts a moment after the click (a POST, then 302 to a
  # new page). The next step used to run on the page being left: the
  # expression read the old URL, and a goto aborted the POST in flight, so no
  # mail was sent — a client's sign-in criterion recorded exactly that ERROR.
  cat > "$TEST_DIR/nav.py" <<'PY'
import http.server, sys, time
LATE = ("<input id='e'><button id='go' onclick=\"setTimeout(function(){var f=document.createElement('form');"
        "f.method='post';f.action='/signin';document.body.appendChild(f);f.submit();},120)\">Send</button>"
        "<button id='stay' onclick=\"this.textContent='stayed'\">x</button>")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def page(self, body):
        self.send_response(200); self.send_header('Content-Type', 'text/html'); self.end_headers()
        self.wfile.write(body.encode())
    def do_GET(self):
        if self.path.startswith('/signin/sent'):
            self.page("<h1 id='sent'>sent</h1>")
        elif self.path.startswith('/mail'):
            self.page("<p id='mail'>%s</p>" % ('got' if 'signed=1' in (self.headers.get('Cookie') or '') else 'none'))
        elif self.path.startswith('/js'):
            self.page(LATE)
        else:
            self.page("<form method='post' action='/signin'><input id='e' name='e'><button id='go'>Send</button></form>")
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length') or 0))
        time.sleep(0.4)
        self.send_response(302); self.send_header('Location', '/signin/sent')
        self.send_header('Set-Cookie', 'signed=1; Path=/'); self.end_headers()
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
PY
  NPORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  python3 "$TEST_DIR/nav.py" "$NPORT" >/dev/null 2>&1 &
  NAV_PID=$!; disown "$NAV_PID" 2>/dev/null
  for _ in $(seq 1 50); do curl -fsS "http://127.0.0.1:$NPORT/" >/dev/null 2>&1 && break; sleep 0.1; done
  N="http://127.0.0.1:$NPORT"
  assert_eq "a click whose submit starts late: the expression sees the new page" '0|PASS "/signin/sent"' \
    "$(run lv-headless-eval.sh "$N/js" "location.pathname" '[{"type":"click","selector":"#go"}]')"
  assert_eq "…and a goto after it does not abort the POST"  '0|PASS "got"' \
    "$(run lv-headless-eval.sh "$N/js" "document.getElementById('mail').textContent" '[{"type":"click","selector":"#go"},{"type":"goto","url":"'"$N"'/mail"}]')"
  assert_eq "a form submit by Enter lands too"              '0|PASS "/signin/sent"' \
    "$(run lv-headless-eval.sh "$N/" "location.pathname" '[{"type":"fill","selector":"#e","value":"a@b"},{"type":"press","selector":"#e","key":"Enter"}]')"
  assert_eq "waitForURL names where it lands"               '0|PASS true' \
    "$(run lv-headless-eval.sh "$N/js" "!!document.getElementById('sent')" '[{"type":"click","selector":"#go","navGrace":0},{"type":"waitForURL","url":"**/signin/sent"}]')"
  assert_eq "waitForURL takes a /regex/"                    '0|PASS true' \
    "$(run lv-headless-eval.sh "$N/js" "!!document.getElementById('sent')" '[{"type":"click","selector":"#go","navGrace":0},{"type":"waitForURL","url":"/signin.sent$/"}]')"
  r=$(run lv-headless-eval.sh "$N/js" "true" '[{"type":"waitForURL","url":"**/never","timeout":400}]')
  assert_eq "waitForURL that never arrives is ERROR"        "2" "${r%%|*}"
  assert_eq "a click that navigates nowhere still just clicks" '0|PASS "stayed"' \
    "$(run lv-headless-eval.sh "$N/js" "document.getElementById('stay').textContent" '[{"type":"click","selector":"#stay"}]')"
  assert_eq "a session step waits for the navigation too"   '0|PASS "/signin/sent"' \
    "$(run lv-headless-session.sh '{"contexts":[{"name":"a","url":"'"$N"'/js"}],"steps":[{"context":"a","actions":[{"type":"click","selector":"#go"}]}],"expr":{"context":"a","js":"location.pathname"}}')"
  kill "$NAV_PID" 2>/dev/null

  echo "  layout (LVI-044)"
  L="http://127.0.0.1:$PORT"
  assert_eq "a clean page passes at both widths, visually-hidden text included"          "0|PASS layout 390x844 1280x800: no overflow, targets >= 24px, radios and checkboxes on their label's line, no text overflow" \
    "$(run lv-headless-layout.sh "$L/layout-good.html")"
  lay=$(bash "$SD/lv-headless-layout.sh" "$L/layout-bad.html" 2>/dev/null); rc=$?
  assert_eq "a page with defects is FAIL, exit 1"          1 "$rc"
  has "…the verdict is the last line, with counts"          "$(printf '%s' "$lay" | tail -1)" '^FAIL layout 390x844 1280x800: 7 problem\(s\) — overflow 1, target 3, align 1, text 2$'
  has "horizontal overflow, naming what is past the edge"   "$lay" '^390x844 overflow: document — scrollWidth 600 > clientWidth 390 \(past the edge: div.wide'
  has "an 18px link is under the 24px target"               "$lay" '^390x844 target: a.guide "Guide" — 18px tall'
  has "a radio left alone above its inline-block label"     "$lay" '^390x844 align: label "A long answer'
  has "text wider than its box"                             "$lay" '^390x844 text: div.box "marbles'
  has "a link inside running text is exempt"                "$(bash "$SD/lv-headless-layout.sh" "$L/layout-good.html" --min-target 30 2>/dev/null)" '^PASS'
  assert_eq "--sizes picks the widths"                      "1|FAIL layout 1280x800: 3 problem(s) — target 2, text 1" \
    "$(run lv-headless-layout.sh "$L/layout-bad.html" --sizes 1280x800)"
  has "actions run before the audit"                        "$(run lv-headless-layout.sh "$U" '[{"type":"click","selector":"#b"}]' --sizes 390x844)" '^[01]\|(PASS|FAIL) layout 390x844'
  r=$(run lv-headless-layout.sh "http://127.0.0.1:$DEAD/")
  assert_eq "a server that is not there is ERROR"           "2" "${r%%|*}"

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
