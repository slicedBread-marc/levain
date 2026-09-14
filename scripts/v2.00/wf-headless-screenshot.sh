#!/usr/bin/env bash
# wf-headless-screenshot.sh
# Navigates to a URL, optionally runs an actions-json interaction sequence
# (same vocabulary as wf-headless-eval.sh — see wf-headless-common.sh's
# actions.mjs), and saves a screenshot. Exists so a `#### Chrome-Assisted`
# or `#### Manual` criterion whose pass condition is genuinely visual
# ("layout correct on mobile", "looks right") can still be resolved without
# the Claude-in-Chrome extension: wf-test runs this, then Reads the saved
# PNG itself and judges it the way it would judge a Chrome-extension
# screenshot — no human, no extension connection required. Reserve
# /wf-chrome-test for what this genuinely can't do: real third-party OAuth,
# a physical device, browser extensions, or the user's own logged-in
# profile.
#
# Usage: wf-headless-screenshot.sh <url> <output-path> [actions-json] [width] [height]
#   Default viewport is 390x844 (mobile), matching wf-headless-eval.sh — pass
#   width/height to check a different breakpoint (e.g. 1280 800 for desktop).
#   output-path should live under the feature worktree (e.g.
#   /tmp/wf-screenshots/<plan>-<n>.png is fine too) — anywhere the Read tool
#   can reach it.
#
# Exit codes:
#   0 — screenshot saved.             stdout: "OK <output-path>"
#   2 — no result was produced: no node/npm, browser install failed,
#       navigation failed, or an action step failed. stdout: "ERROR <reason>"
#       — the same "recorded reason it could not run" contract as
#       wf-headless-eval.sh; never treat this as a failed visual check.

set -uo pipefail

URL="${1:-}"
OUT="${2:-}"
ACTIONS="${3:-[]}"
WIDTH="${4:-390}"
HEIGHT="${5:-844}"

if [ -z "$URL" ] || [ -z "$OUT" ]; then
  echo "ERROR usage: wf-headless-screenshot.sh <url> <output-path> [actions-json] [width] [height]"
  exit 2
fi

# shellcheck source=wf-headless-common.sh
source "$(dirname "$0")/wf-headless-common.sh"
wf_headless_ensure_ready || exit 2

mkdir -p "$(dirname "$OUT")"

RUNNER="$CACHE_DIR/run-screenshot.mjs"

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';
import { runActions } from './actions.mjs';

const [, , url, out, actionsJson, width, height] = process.argv;

let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: Number(width), height: Number(height) } });
  await page.goto(url, { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(300);
  await runActions(page, JSON.parse(actionsJson || '[]'));
  await page.screenshot({ path: out, fullPage: true });
  await browser.close();
  console.log(`OK ${out}`);
  process.exit(0);
} catch (err) {
  if (browser) { try { await browser.close(); } catch {} }
  console.log(`ERROR ${String((err && err.message) || err).split('\n')[0]}`);
  process.exit(2);
}
NODE

node "$RUNNER" "$URL" "$OUT" "$ACTIONS" "$WIDTH" "$HEIGHT"
exit $?
