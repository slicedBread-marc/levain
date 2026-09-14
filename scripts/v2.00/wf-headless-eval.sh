#!/usr/bin/env bash
# wf-headless-eval.sh
# Evaluates one JS boolean expression against a page in a headless Chromium
# browser — no Claude-in-Chrome extension required. Exists so wf-test can
# resolve a `#### Chrome-Assisted` criterion that reduces to a literal
# DOM/JS assertion (getBoundingClientRect, scrollWidth <= innerWidth,
# computed style, cookie attributes, console errors, meta tag presence)
# itself, instead of leaving it at "-" for a human or a separate
# /wf-chrome-test invocation. client-f's WFI-008: with Chrome not connected,
# two Chrome-Assisted criteria sat untested through a full verify cycle and
# opened a manual-test gate a human had to drain by hand; installing
# playwright ad hoc and evaluating the same assertions took under a second.
#
# Usage: wf-headless-eval.sh <url> <js-boolean-expression>
#   The expression runs inside page.evaluate() after the page reaches
#   'load' plus a short settle wait, and must return something coercible
#   to boolean. A `consoleErrors` array (strings, collected from console
#   and page errors since navigation start) is in scope for "no console
#   errors" style criteria.
#
# Exit codes (this is the output contract callers parse):
#   0 — expression evaluated truthy.  stdout: "PASS <value>"
#   1 — expression evaluated falsy.   stdout: "FAIL <value>"
#   2 — no result was produced: no node/npm on this machine, the browser
#       install failed (no network), navigation failed, or the expression
#       threw. stdout: "ERROR <reason>". This is "a recorded reason it
#       could not run" (wf-test SKILL.md step 3) — never a FAIL, and never
#       silently treated as untested.
#
# The browser install is cached at $WF_HEADLESS_CACHE (default
# ~/.cache/wf-headless-browser) and shared across every client project on
# this machine — the chromium download is ~90MB and paying for it per-plan
# is wasteful. A machine with no network on first use gets exit 2 every
# time until something installs it by hand; that is expected, not a bug.

set -uo pipefail

URL="${1:-}"
EXPR="${2:-}"

if [ -z "$URL" ] || [ -z "$EXPR" ]; then
  echo "ERROR usage: wf-headless-eval.sh <url> <js-boolean-expression>"
  exit 2
fi

if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
  echo "ERROR no node/npm on this machine - headless evaluation unavailable"
  exit 2
fi

CACHE_DIR="${WF_HEADLESS_CACHE:-$HOME/.cache/wf-headless-browser}"
mkdir -p "$CACHE_DIR"
MARKER="$CACHE_DIR/.installed"
RUNNER="$CACHE_DIR/run.mjs"

if [ ! -f "$MARKER" ]; then
  echo "Installing headless browser (first use on this machine, cached at $CACHE_DIR)..." >&2
  if ! npm install --prefix "$CACHE_DIR" playwright@1 --no-save --no-audit --no-fund --loglevel=error > "$CACHE_DIR/.install.log" 2>&1; then
    echo "ERROR npm install playwright failed - $(tail -3 "$CACHE_DIR/.install.log" | tr '\n' ' ')"
    exit 2
  fi
  if ! npx --prefix "$CACHE_DIR" playwright install chromium >> "$CACHE_DIR/.install.log" 2>&1; then
    echo "ERROR playwright chromium install failed - $(tail -3 "$CACHE_DIR/.install.log" | tr '\n' ' ')"
    exit 2
  fi
  touch "$MARKER"
fi

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';

const [, , url, expr] = process.argv;

let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
  const consoleErrors = [];
  page.on('pageerror', (e) => consoleErrors.push(String(e)));
  page.on('console', (msg) => { if (msg.type() === 'error') consoleErrors.push(msg.text()); });
  await page.goto(url, { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(300);
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

node "$RUNNER" "$URL" "$EXPR"
exit $?
