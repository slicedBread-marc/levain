#!/usr/bin/env bash
# lv-headless-eval.sh
# Evaluates one JS boolean expression against a page in a headless Chromium
# browser — no Claude-in-Chrome extension required. Exists so lv-test can
# resolve a `#### Chrome-Assisted` criterion itself: a literal DOM/JS
# assertion (getBoundingClientRect, scrollWidth <= innerWidth, computed
# style, cookie attributes, console errors, meta tag presence), optionally
# preceded by an interaction sequence (click, fill, submit, wait, refresh —
# see actions-json below), instead of leaving it at "-" for a human.
# client-f's WFI-008: with Chrome not
# connected, two Chrome-Assisted criteria sat untested through a full verify
# cycle and opened a manual-test gate a human had to drain by hand;
# installing playwright ad hoc and evaluating the same assertions took under
# a second. This (and lv-headless-screenshot.sh for visual criteria) is
# lv-test's only automated browser: the Chrome-extension browser mode was
# retired (LVI-001).
#
# Usage: lv-headless-eval.sh <url> <js-boolean-expression> [actions-json] [width] [height]
#   The expression runs inside page.evaluate() after the page reaches
#   'load', a short settle wait, and any actions-json steps, and must
#   return true or false (a promise of one is awaited). Any other value — a
#   string, a number, an element, null — is ERROR, not a truthy PASS: write
#   the comparison (`el.textContent === 'x'`, `n > 0`, `!!el`) (LVI-054). A `consoleErrors` array
#   (strings, collected from console and page errors since navigation
#   start, including any raised during the actions) is in scope for
#   "no console errors" style criteria. `downloads` (what download steps
#   saved) and `clipboard` (what a clipboard step read) are in scope too.
#
#   Default viewport is 390x844 (mobile), matching lv-headless-screenshot.sh
#   — pass width/height to check a different breakpoint (e.g. 1280 800 for
#   desktop). A criterion naming a specific width (client-f's WFI-009) could
#   not be reproduced before this and had to carry forward a prior result.
#
#   actions-json (optional, default "[]"): a JSON array of steps run in
#   order before the expression is evaluated, so a criterion needing
#   "navigate, click, then assert" doesn't have to be left for a human.
#   Each step is {"type": ..., ...}:
#     {"type":"click","selector":"..."}
#     {"type":"fill","selector":"...","value":"..."}
#     {"type":"press","selector":"...","key":"Enter"}
#     {"type":"press","key":"Tab"}   — no selector: to whatever has focus
#     {"type":"keyboard","key":"Shift+Tab"}  — same, spelled as a page key
#     {"type":"hover","selector":"..."}      — hover trays, tooltips, :hover
#     {"type":"focus","selector":"..."}
#     {"type":"mouse","x":640,"y":12}        — move the pointer to a point
#     {"type":"selectOption","selector":"...","value":"..."}
#     {"type":"check","selector":"..."}  /  {"type":"uncheck",...}
#     {"type":"waitForSelector","selector":"...","state":"visible"}
#     {"type":"waitForURL","url":"**/signin/sent"}  — or "/regex/": wait until
#                                   the page has arrived there and loaded
#     {"type":"waitForLoadState","state":"networkidle"}
#     {"type":"wait","ms":300}
#     {"type":"goto","url":"..."}   — navigate again (e.g. to check a redirect)
#     {"type":"reload"}             — for persistence checks (survives refresh)
#     {"type":"download","selector":"#export","name":"csv"}
#                                   — click, keep the file: downloads[i] is
#                                     {name, filename, size, sha256, text, failure}
#     {"type":"upload","selector":"input[type=file]","files":["fixtures/a.png"]}
#     {"type":"upload","click":"#pick","files":[{"name":"a.csv","mimeType":"text/csv","text":"x,y"}]}
#                                   — a path, or inline {name, mimeType, text|base64};
#                                     "click" answers the file chooser a button opens
#     {"type":"clipboard"}          — read the clipboard into `clipboard`
#     {"type":"clipboardWrite","text":"..."} — seed it, for a paste criterion
#   Every step optionally takes "timeout" (ms, default 5000/15000 per type).
#   A click, press, keyboard, check/uncheck or selectOption that starts a
#   navigation (a form submit: POST, 302, a new page) waits for the new page
#   to load before the next step runs, so a following goto or assertion never
#   lands on the page being left (LVI-043). The wait begins if a navigation
#   starts within "navGrace" ms of the action (default 250; 0 turns it off)
#   and lasts up to "navTimeout" (default 15000). Name the destination with
#   waitForURL when the criterion is about where the submit lands.
#   Selectors are Playwright's: CSS pierces open shadow roots on its own
#   (`my-menu button` finds a button inside <my-menu>'s shadow DOM), and
#   `text=Round 2` matches by visible text. For layering, evaluate
#   `document.elementFromPoint(x, y)` in the expression. A hover, a Tab
#   order or a shadow-DOM menu is scriptable, so it is never a reason to
#   leave a criterion for a human (LVI-029). Neither is a file download, an
#   upload or the clipboard: all three have verbs above, and a criterion about
#   them is never "needs: device" (LVI-036).
#   See lv-headless-common.sh's actions.mjs for the canonical definitions.
#
# Exit codes (this is the output contract callers parse):
#   0 — expression returned true.     stdout: "PASS true"
#   1 — expression returned false.    stdout: "FAIL false"
#   2 — no result was produced: no node/npm on this machine, the browser
#       install failed (no network), navigation failed, an action step
#       failed (e.g. selector never appeared), the expression threw, or
#       it returned something other than true or false (the value is in
#       the reason).
#       stdout: "ERROR <reason>". This is "a recorded reason it could not
#       run" (lv-test SKILL.md step 3) — never a FAIL, and never silently
#       treated as untested.

set -uo pipefail

URL="${1:-}"
EXPR="${2:-}"
ACTIONS="${3:-[]}"
WIDTH="${4:-390}"
HEIGHT="${5:-844}"

if [ -z "$URL" ] || [ -z "$EXPR" ]; then
  echo "ERROR usage: lv-headless-eval.sh <url> <js-boolean-expression> [actions-json] [width] [height]"
  exit 2
fi

# shellcheck source=lv-headless-common.sh
source "$(dirname "$0")/lv-headless-common.sh"
wf_headless_check_args "$ACTIONS" "$WIDTH" "$HEIGHT" $(( $# > 5 ? $# - 5 : 0 )) || exit 2
wf_headless_ensure_ready || exit 2

RUNNER="$CACHE_DIR/run-eval.mjs"

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';
import { runActions, exprScope, exprFunction, verdict } from './actions.mjs';

const [, , url, expr, actionsJson, width, height] = process.argv;

let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: Number(width), height: Number(height) } });
  const consoleErrors = [];
  page.on('pageerror', (e) => consoleErrors.push(String(e)));
  page.on('console', (msg) => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  await page.goto(url, { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(300);
  await runActions(page, JSON.parse(actionsJson || '[]'));
  const value = await page.evaluate(exprFunction(expr), exprScope(page, consoleErrors));
  await browser.close();
  process.exit(verdict(value));
} catch (err) {
  if (browser) { try { await browser.close(); } catch {} }
  console.log(`ERROR ${String((err && err.message) || err).split('\n')[0]}`);
  process.exit(2);
}
NODE

node "$RUNNER" "$URL" "$EXPR" "$ACTIONS" "$WIDTH" "$HEIGHT"
exit $?
