#!/usr/bin/env bash
# lv-headless-eval.sh
# Evaluates one JS boolean expression against a page in a headless Chromium
# browser — no Claude-in-Chrome extension required. Exists so lv-test can
# resolve a `#### Chrome-Assisted` criterion itself: a literal DOM/JS
# assertion (getBoundingClientRect, scrollWidth <= innerWidth, computed
# style, cookie attributes, console errors, meta tag presence), optionally
# preceded by an interaction sequence (click, fill, submit, wait, refresh —
# see actions-json below), instead of leaving it at "-" for a human or a
# separate `/lv-test <ID> browser` run. client-f's WFI-008: with Chrome not
# connected, two Chrome-Assisted criteria sat untested through a full verify
# cycle and opened a manual-test gate a human had to drain by hand;
# installing playwright ad hoc and evaluating the same assertions took under
# a second. Favour this (and lv-headless-screenshot.sh for visual criteria)
# over lv-test's browser mode wherever the criterion can be scripted at all — the
# extension is the fallback, not the default.
#
# Usage: lv-headless-eval.sh <url> <js-boolean-expression> [actions-json] [width] [height]
#   The expression runs inside page.evaluate() after the page reaches
#   'load', a short settle wait, and any actions-json steps, and must
#   return something coercible to boolean. A `consoleErrors` array
#   (strings, collected from console and page errors since navigation
#   start, including any raised during the actions) is in scope for
#   "no console errors" style criteria.
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
#     {"type":"wait","ms":300}
#     {"type":"goto","url":"..."}   — navigate again (e.g. to check a redirect)
#     {"type":"reload"}             — for persistence checks (survives refresh)
#   Every step optionally takes "timeout" (ms, default 5000/15000 per type).
#   Selectors are Playwright's: CSS pierces open shadow roots on its own
#   (`my-menu button` finds a button inside <my-menu>'s shadow DOM), and
#   `text=Round 2` matches by visible text. For layering, evaluate
#   `document.elementFromPoint(x, y)` in the expression. A hover, a Tab
#   order or a shadow-DOM menu is scriptable, so it is never a reason to
#   leave a criterion for a human (LVI-029).
#   See lv-headless-common.sh's actions.mjs for the canonical definitions.
#
# Exit codes (this is the output contract callers parse):
#   0 — expression evaluated truthy.  stdout: "PASS <value>"
#   1 — expression evaluated falsy.   stdout: "FAIL <value>"
#   2 — no result was produced: no node/npm on this machine, the browser
#       install failed (no network), navigation failed, an action step
#       failed (e.g. selector never appeared), or the expression threw.
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
wf_headless_ensure_ready || exit 2

RUNNER="$CACHE_DIR/run-eval.mjs"

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';
import { runActions } from './actions.mjs';

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
  const fn = new Function('consoleErrors', `return (${expr});`);
  const value = await page.evaluate(fn, consoleErrors);
  await browser.close();
  if (value) {
    console.log(`PASS ${JSON.stringify(value)}`);
    process.exit(0);
  } else {
    console.log(`FAIL ${JSON.stringify(value)}`);
    process.exit(1);
  }
} catch (err) {
  if (browser) { try { await browser.close(); } catch {} }
  console.log(`ERROR ${String((err && err.message) || err).split('\n')[0]}`);
  process.exit(2);
}
NODE

node "$RUNNER" "$URL" "$EXPR" "$ACTIONS" "$WIDTH" "$HEIGHT"
exit $?
