#!/usr/bin/env bash
# lv-headless-session.sh <session-json|@file>
#
# Evaluates one assertion across SEVERAL concurrent browser contexts.
#
# WHY THIS EXISTS
#
# lv-headless-eval.sh and lv-headless-screenshot.sh each drive exactly one
# page, which covers every criterion about what one user sees. It covers none
# about what two users see of each other — the same account on two devices, a
# reload-rejoin with a live peer still connected, a second tab that must not
# receive a session cookie.
#
# client-b WFI-028: PLN-014's criteria 8 and 9 each needed two concurrent
# contexts. /lv-test step 3c offered no way to express that, so the unattended
# tester recorded both as untestable — "no interactive browser window can be
# opened" — and opened a manual-test gate for them. An attended session then
# wrote a ~120-line two-context Playwright driver by hand against the same
# cached browser, and both criteria passed. The capability was there; only the
# vocabulary was missing, and a criterion that is scriptable but has no verb
# reaches a human as if it were not scriptable at all.
#
# A CONTEXT IS A DEVICE
#
# Each named context is a separate Playwright browser context: its own cookie
# jar, its own storage, its own session — which is exactly what "the same
# account on two devices" means, and what two pages in one context could not
# have given. One browser process, so the cost is one launch.
#
# Usage: lv-headless-session.sh '<session-json>'
#        lv-headless-session.sh @/path/to/session.json
#
# A session is one JSON object. Everything but `contexts` and `expr` is
# optional:
#
#   {
#     "viewport": { "width": 390, "height": 844 },   // default for all contexts
#     "contexts": [
#       { "name": "phone",  "url": "http://localhost:8080/board" },
#       { "name": "laptop", "url": "http://localhost:8080/board",
#         "viewport": { "width": 1280, "height": 800 },
#         "actions": [ { "type": "click", "selector": "#join" } ] }
#     ],
#     "steps": [
#       { "context": "phone",  "actions": [ { "type": "fill", "selector": "#msg", "value": "hi" },
#                                           { "type": "press", "selector": "#msg", "key": "Enter" } ] },
#       { "context": "laptop", "actions": [ { "type": "reload" } ] },
#       { "context": "laptop", "wait": 500 }
#     ],
#     "expr": { "context": "laptop", "js": "document.querySelectorAll('.peer').length === 2" }
#   }
#
#   contexts[]  Created and navigated IN ORDER, each one fully settled before
#               the next opens. A context with no `url` is opened blank, for
#               a criterion whose first act is a navigation in `steps`.
#   steps[]     Run in order, across contexts. This is the whole point: the
#               interleaving is what a two-device criterion asserts about. The
#               action vocabulary is actions.mjs's, identical to
#               lv-headless-eval.sh's — click, fill, press, keyboard, hover, focus, mouse, selectOption,
#               check/uncheck, waitForSelector, waitForURL, waitForLoadState,
#               wait, goto, reload. A navigating click waits for the new page.
#   expr        ONE boolean expression, evaluated in ONE named context, after
#               every step. `consoleErrors` is in scope and holds that
#               context's errors only. One criterion, one invocation, one
#               verdict — the same output contract every other headless script
#               has, so a caller parses all three the same way.
#
# Exit codes (the output contract callers parse — identical to
# lv-headless-eval.sh, deliberately):
#   0 — expression returned true.     stdout: "PASS true"
#   1 — expression returned false.    stdout: "FAIL false"
#   2 — no result was produced: no node/npm, the browser install failed, a
#       navigation or action step failed, the session JSON is malformed, or
#       the expression threw or returned something other than true or false
#       (LVI-054). stdout: "ERROR <reason>". This is "a recorded
#       reason it could not run" (lv-test step 3c) — never a FAIL.

set -uo pipefail

SPEC="${1:-}"

if [ -z "$SPEC" ]; then
  echo "ERROR usage: lv-headless-session.sh '<session-json>' | @<file>"
  exit 2
fi

case "$SPEC" in
  @*)
    spec_file="${SPEC#@}"
    if [ ! -f "$spec_file" ]; then
      echo "ERROR session file not found: $spec_file"
      exit 2
    fi
    SPEC=$(cat "$spec_file")
    ;;
esac

# shellcheck source=lv-headless-common.sh
source "$(dirname "$0")/lv-headless-common.sh"
wf_headless_ensure_ready || exit 2

RUNNER="$CACHE_DIR/run-session.mjs"

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';
import { runActions, exprScope, exprFunction, verdict } from './actions.mjs';

const [, , specJson] = process.argv;

let browser;
try {
  let spec;
  try {
    spec = JSON.parse(specJson);
  } catch (e) {
    console.log(`ERROR session json is not valid JSON - ${String(e.message).split('\n')[0]}`);
    process.exit(2);
  }

  const defaultViewport = spec.viewport || { width: 390, height: 844 };
  const contexts = Array.isArray(spec.contexts) ? spec.contexts : [];
  if (contexts.length === 0) {
    console.log('ERROR session has no contexts - use lv-headless-eval.sh for a single page');
    process.exit(2);
  }
  if (!spec.expr || !spec.expr.js) {
    console.log('ERROR session has no expr.js - one boolean expression is the verdict');
    process.exit(2);
  }

  browser = await chromium.launch();

  // name -> { page, consoleErrors }. A separate browser context per entry, so
  // cookies and storage are NOT shared — that is what makes each one a device.
  const open = new Map();
  for (const c of contexts) {
    if (!c.name) {
      console.log('ERROR every context needs a "name" - steps and expr address them by it');
      process.exit(2);
    }
    if (open.has(c.name)) {
      console.log(`ERROR duplicate context name "${c.name}"`);
      process.exit(2);
    }
    const ctx = await browser.newContext({ viewport: c.viewport || defaultViewport });
    const page = await ctx.newPage();
    const consoleErrors = [];
    page.on('pageerror', (e) => consoleErrors.push(String(e)));
    page.on('console', (m) => { if (m.type() === 'error') consoleErrors.push(m.text()); });
    if (c.url) {
      await page.goto(c.url, { waitUntil: 'load', timeout: 15000 });
      await page.waitForTimeout(300);
    }
    if (c.actions) await runActions(page, c.actions);
    open.set(c.name, { page, consoleErrors });
  }

  const resolve = (name, where) => {
    const entry = open.get(name);
    if (!entry) throw new Error(`${where} names context "${name}", which was never opened`);
    return entry;
  };

  for (const [i, step] of (spec.steps || []).entries()) {
    const { page } = resolve(step.context, `steps[${i}]`);
    if (step.actions) await runActions(page, step.actions);
    if (step.wait) await page.waitForTimeout(Number(step.wait));
  }

  const target = resolve(spec.expr.context, 'expr');
  const value = await target.page.evaluate(exprFunction(spec.expr.js), exprScope(target.page, target.consoleErrors));

  await browser.close();
  process.exit(verdict(value));
} catch (err) {
  if (browser) { try { await browser.close(); } catch {} }
  console.log(`ERROR ${String((err && err.message) || err).split('\n')[0]}`);
  process.exit(2);
}
NODE

node "$RUNNER" "$SPEC"
exit $?
