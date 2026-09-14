# wf-headless-common.sh
# Shared setup for wf-headless-eval.sh and wf-headless-screenshot.sh. Not
# directly executable — sourced by both.
#
# wf_headless_ensure_ready():
#   - Verifies node/npm exist.
#   - Installs Playwright + Chromium once per machine, cached at
#     $WF_HEADLESS_CACHE (default ~/.cache/wf-headless-browser) and shared
#     across every client project — the download is ~90MB and paying for it
#     per-plan is wasteful.
#   - Writes actions.mjs into that cache dir: a shared action-runner module
#     (`runActions(page, actions)`) both scripts import, so the interaction
#     vocabulary (click, fill, press, selectOption, check/uncheck,
#     waitForSelector, wait, goto, reload) is defined in exactly one place.
#   - Sets (unprefixed, in the caller's shell — this is sourced, not
#     subshelled) CACHE_DIR for the caller to build runner/output paths from.
#
# Returns 0 when ready. On failure prints "ERROR <reason>" to stdout (the
# same contract both callers use for their own exit-2 case) and returns 2 —
# the caller must check the return and exit, not just call this and continue.

wf_headless_ensure_ready() {
  CACHE_DIR="${WF_HEADLESS_CACHE:-$HOME/.cache/wf-headless-browser}"
  mkdir -p "$CACHE_DIR"
  MARKER="$CACHE_DIR/.installed"

  if ! command -v npm >/dev/null 2>&1 || ! command -v node >/dev/null 2>&1; then
    echo "ERROR no node/npm on this machine - headless evaluation unavailable"
    return 2
  fi

  if [ ! -f "$MARKER" ]; then
    echo "Installing headless browser (first use on this machine, cached at $CACHE_DIR)..." >&2
    if ! npm install --prefix "$CACHE_DIR" playwright@1 --no-save --no-audit --no-fund --loglevel=error > "$CACHE_DIR/.install.log" 2>&1; then
      echo "ERROR npm install playwright failed - $(tail -3 "$CACHE_DIR/.install.log" | tr '\n' ' ')"
      return 2
    fi
    if ! npx --prefix "$CACHE_DIR" playwright install chromium >> "$CACHE_DIR/.install.log" 2>&1; then
      echo "ERROR playwright chromium install failed - $(tail -3 "$CACHE_DIR/.install.log" | tr '\n' ' ')"
      return 2
    fi
    touch "$MARKER"
  fi

  cat > "$CACHE_DIR/actions.mjs" <<'NODE'
export async function runActions(page, actions) {
  for (const step of actions || []) {
    const timeout = step.timeout || 5000;
    switch (step.type) {
      case 'click':
        await page.click(step.selector, { timeout });
        break;
      case 'fill':
        await page.fill(step.selector, step.value ?? '', { timeout });
        break;
      case 'press':
        await page.press(step.selector, step.key, { timeout });
        break;
      case 'selectOption':
        await page.selectOption(step.selector, step.value, { timeout });
        break;
      case 'check':
        await page.check(step.selector, { timeout });
        break;
      case 'uncheck':
        await page.uncheck(step.selector, { timeout });
        break;
      case 'waitForSelector':
        await page.waitForSelector(step.selector, { state: step.state || 'visible', timeout });
        break;
      case 'wait':
        await page.waitForTimeout(step.ms || 300);
        break;
      case 'goto':
        await page.goto(step.url, { waitUntil: 'load', timeout: step.timeout || 15000 });
        break;
      case 'reload':
        await page.reload({ waitUntil: 'load', timeout: step.timeout || 15000 });
        break;
      default:
        throw new Error(`unknown action type: ${step.type}`);
    }
  }
}
NODE

  return 0
}
