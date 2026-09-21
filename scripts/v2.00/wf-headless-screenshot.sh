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
#                                  [--viewport]
#   Default viewport is 390x844 (mobile), matching wf-headless-eval.sh — pass
#   width/height to check a different breakpoint (e.g. 1280 800 for desktop).
#   output-path should live under the feature worktree (e.g.
#   /tmp/wf-screenshots/<plan>-<n>.png is fine too) — anywhere the Read tool
#   can reach it.
#
#   --viewport  Capture only what fits in the viewport, instead of the whole
#   (--no-full-page) scrollable page. THIS IS WHAT AN ABOVE-THE-FOLD CRITERION
#   NEEDS. The default capture is `fullPage`, which stitches the entire
#   document into one tall PNG: at 390x844 it returned a 390x1196 image, so a
#   criterion reading "the running effect is on screen without scrolling"
#   showed as passing whether or not it actually was. The viewport args size
#   the layout either way; only this flag decides where the image stops
#   (client-b WFI-011). Flags may appear anywhere in the argument list.
#
# Exit codes:
#   0 — screenshot saved.             stdout: "OK <output-path>"
#   2 — no result was produced: no node/npm, browser install failed,
#       navigation failed, or an action step failed. stdout: "ERROR <reason>"
#       — the same "recorded reason it could not run" contract as
#       wf-headless-eval.sh; never treat this as a failed visual check.

set -uo pipefail

FULL_PAGE=true
positional=()
for arg in "$@"; do
  case "$arg" in
    --viewport|--no-full-page) FULL_PAGE=false ;;
    --full-page)               FULL_PAGE=true ;;
    *)                         positional+=("$arg") ;;
  esac
done
set -- ${positional[@]+"${positional[@]}"}

URL="${1:-}"
OUT="${2:-}"
ACTIONS="${3:-[]}"
WIDTH="${4:-390}"
HEIGHT="${5:-844}"

if [ -z "$URL" ] || [ -z "$OUT" ]; then
  echo "ERROR usage: wf-headless-screenshot.sh <url> <output-path> [actions-json] [width] [height] [--viewport]"
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

const [, , url, out, actionsJson, width, height, fullPage] = process.argv;

let browser;
try {
  browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: Number(width), height: Number(height) } });
  await page.goto(url, { waitUntil: 'load', timeout: 15000 });
  await page.waitForTimeout(300);
  await runActions(page, JSON.parse(actionsJson || '[]'));
  await page.screenshot({ path: out, fullPage: fullPage !== 'false' });
  await browser.close();
  console.log(`OK ${out}`);
  process.exit(0);
} catch (err) {
  if (browser) { try { await browser.close(); } catch {} }
  console.log(`ERROR ${String((err && err.message) || err).split('\n')[0]}`);
  process.exit(2);
}
NODE

node "$RUNNER" "$URL" "$OUT" "$ACTIONS" "$WIDTH" "$HEIGHT" "$FULL_PAGE"
exit $?
