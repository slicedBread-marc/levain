#!/usr/bin/env bash
# wf-headless-eval.sh
# Evaluates one JS boolean expression against a page in a headless Chromium
# browser — no Claude-in-Chrome extension required. Exists so wf-test can
# resolve a `#### Chrome-Assisted` criterion itself: a literal DOM/JS
# assertion (getBoundingClientRect, scrollWidth <= innerWidth, computed
# style, cookie attributes, console errors, meta tag presence), optionally
# preceded by an interaction sequence (click, fill, submit, wait, refresh —
# see actions-json below), instead of leaving it at "-" for a human or a
# separate /wf-chrome-test invocation. client-f's WFI-008: with Chrome not
# connected, two Chrome-Assisted criteria sat untested through a full verify
# cycle and opened a manual-test gate a human had to drain by hand;
# installing playwright ad hoc and evaluating the same assertions took under
# a second. Favour this (and wf-headless-screenshot.sh for visual criteria)
# over /wf-chrome-test wherever the criterion can be scripted at all — the
# extension is the fallback, not the default.
#
# Usage: wf-headless-eval.sh <url> <js-boolean-expression> [actions-json]
#   The expression runs inside page.evaluate() after the page reaches
#   'load', a short settle wait, and any actions-json steps, and must
#   return something coercible to boolean. A `consoleErrors` array
#   (strings, collected from console and page errors since navigation
#   start, including any raised during the actions) is in scope for
#   "no console errors" style criteria.
#
#   actions-json (optional, default "[]"): a JSON array of steps run in
#   order before the expression is evaluated, so a criterion needing
#   "navigate, click, then assert" doesn't have to be left for a human.
#   Each step is {"type": ..., ...}:
#     {"type":"click","selector":"..."}
#     {"type":"fill","selector":"...","value":"..."}
#     {"type":"press","selector":"...","key":"Enter"}
#     {"type":"selectOption","selector":"...","value":"..."}
#     {"type":"check","selector":"..."}  /  {"type":"uncheck",...}
#     {"type":"waitForSelector","selector":"...","state":"visible"}
#     {"type":"wait","ms":300}
#     {"type":"goto","url":"..."}   — navigate again (e.g. to check a redirect)
#     {"type":"reload"}             — for persistence checks (survives refresh)
#   Every step optionally takes "timeout" (ms, default 5000/15000 per type).
#   See wf-headless-common.sh's actions.mjs for the canonical definitions.
#
# Exit codes (this is the output contract callers parse):
#   0 — expression evaluated truthy.  stdout: "PASS <value>"
#   1 — expression evaluated falsy.   stdout: "FAIL <value>"
#   2 — no result was produced: no node/npm on this machine, the browser
#       install failed (no network), navigation failed, an action step
#       failed (e.g. selector never appeared), or the expression threw.
#       stdout: "ERROR <reason>". This is "a recorded reason it could not
#       run" (wf-test SKILL.md step 3) — never a FAIL, and never silently
#       treated as untested.

set -uo pipefail

URL="${1:-}"
EXPR="${2:-}"
ACTIONS="${3:-[]}"

if [ -z "$URL" ] || [ -z "$EXPR" ]; then
  echo "ERROR usage: wf-headless-eval.sh <url> <js-boolean-expression> [actions-json]"
  exit 2
fi

# shellcheck source=wf-headless-common.sh
source "$(dirname "$0")/wf-headless-common.sh"
wf_headless_ensure_ready || exit 2

RUNNER="$CACHE_DIR/run-eval.mjs"

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';
import { runActions } from './actions.mjs';

const [, , url, expr, actionsJson] = process.argv;

let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
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

node "$RUNNER" "$URL" "$EXPR" "$ACTIONS"
exit $?
