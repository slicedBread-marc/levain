# lv-headless-common.sh
# Shared setup for lv-headless-eval.sh and lv-headless-screenshot.sh. Not
# directly executable — sourced by both.
#
# wf_headless_ensure_ready():
#   - Verifies node/npm exist.
#   - Installs Playwright + Chromium once per machine, cached at
#     $LV_HEADLESS_CACHE (default ~/.cache/wf-headless-browser) and shared
#     across every client project — the download is ~90MB and paying for it
#     per-plan is wasteful.
#   - Writes actions.mjs into that cache dir: a shared action-runner module
#     (`runActions(page, actions)`) both scripts import, so the interaction
#     vocabulary (click, fill, press, keyboard, hover, focus, mouse,
#     selectOption, check/uncheck, waitForSelector, wait, goto, reload,
#     download, upload, clipboard, clipboardWrite) is defined in exactly one
#     place. It also exports exprScope(page, consoleErrors): what an
#     expression can name — consoleErrors, downloads, clipboard — and
#     exprFunction(js), which builds the function evaluated in the page.
#   - Sets (unprefixed, in the caller's shell — this is sourced, not
#     subshelled) CACHE_DIR for the caller to build runner/output paths from.
#
# Returns 0 when ready. On failure prints "ERROR <reason>" to stdout (the
# same contract both callers use for their own exit-2 case) and returns 2 —
# the caller must check the return and exit, not just call this and continue.
#
# wf_headless_check_args <actions-json> <width> <height> <extra-count> [<output-path>]:
#   Refuses the shapes an unquoted or misplaced actions-json produces, before
#   anything touches the disk: actions that are not one JSON array, a width or
#   height that is not a number, positional arguments past the last one, and
#   an output path that is JSON or has no image extension. A shell splits an
#   unquoted '[{"type":"goto","url":"/a/b"}]' into several words, so a
#   fragment lands in a later slot, and the screenshot's mkdir -p of its
#   dirname made a fragment-named directory in the worktree, which then made
#   lv-suite-run --reuse refuse the tree (a client's LVI-026). Prints
#   "ERROR <reason>" and returns 2, like wf_headless_ensure_ready.

wf_headless_check_args() {
  local actions="$1" width="$2" height="$3" extra="$4" out="${5-}"
  if [ "$extra" -gt 0 ]; then
    echo "ERROR $extra argument(s) past the last one - pass actions-json as ONE single-quoted argument: '[{\"type\":...}]'"
    return 2
  fi
  case "$actions" in
    \[*\]) ;;
    *) echo "ERROR actions-json must be one single-quoted JSON array, got: ${actions:0:60}"; return 2 ;;
  esac
  case "$width$height" in
    ''|*[!0-9]*) echo "ERROR width and height must be numbers, got: ${width:0:30} ${height:0:30} - is actions-json quoted?"; return 2 ;;
  esac
  if [ $# -ge 5 ]; then
    case "$out" in
      \{*|\[*|*\"*) echo "ERROR output path looks like JSON: ${out:0:60} - pass <url> <output-path> [actions-json]"; return 2 ;;
      *.png|*.jpg|*.jpeg) ;;
      *) echo "ERROR output path must end in .png, .jpg or .jpeg, got: ${out:0:60}"; return 2 ;;
    esac
  fi
  return 0
}

wf_headless_ensure_ready() {
  CACHE_DIR="${LV_HEADLESS_CACHE:-$HOME/.cache/wf-headless-browser}"
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
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve as resolvePath } from 'node:path';

// What the actions learned that the page cannot see: a file the browser
// saved, what the clipboard held. Kept per page and handed to the expression
// through exprScope(). Downloads, uploads and the clipboard used to have no
// verb, so an unattended tester recorded every such criterion as "needs:
// device" and gated, and an attended session then passed all of them with a
// hand-written script against this same cached browser (LVI-036).
const STATE = new WeakMap();
function stateOf(page) {
  if (!STATE.has(page)) STATE.set(page, { downloads: [], clipboard: null });
  return STATE.get(page);
}

export function exprScope(page, consoleErrors) {
  const st = stateOf(page);
  return { consoleErrors, downloads: st.downloads, clipboard: st.clipboard };
}

// `return (<js>)`, with every exprScope() name in scope. A promise is awaited,
// so `navigator.clipboard.readText().then(t => t === "x")` works as well.
export function exprFunction(js) {
  return new Function('__lv', `const { consoleErrors, downloads, clipboard } = __lv; return (${js});`);
}

// A file for setInputFiles: a path (relative to the cwd), or inline content
// {name, mimeType, text} / {name, mimeType, base64}.
function uploadFile(f) {
  if (typeof f === 'string') return resolvePath(f);
  const buffer = f.base64 != null ? Buffer.from(f.base64, 'base64') : Buffer.from(f.text ?? '', 'utf8');
  return { name: f.name || 'upload.txt', mimeType: f.mimeType || 'text/plain', buffer };
}

async function grantClipboard(page) {
  await page.context().grantPermissions(['clipboard-read', 'clipboard-write']);
  await page.bringToFront();
}

export async function runActions(page, actions) {
  // Granted before the first step, not at the clipboard step: the page's own
  // "Copy" button calls writeText, and without the permission that write
  // fails silently and the read after it finds nothing.
  if ((actions || []).some((a) => a.type === 'clipboard' || a.type === 'clipboardWrite')) {
    await grantClipboard(page);
  }
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
        // No selector: the key goes to whatever has focus, the way a user's
        // Tab does. Needing a selector made Tab traversal unscriptable (LVI-029).
        if (step.selector) await page.press(step.selector, step.key, { timeout });
        else await page.keyboard.press(step.key);
        break;
      case 'keyboard':
        await page.keyboard.press(step.key);
        break;
      case 'hover':
        await page.hover(step.selector, { timeout });
        break;
      case 'focus':
        await page.focus(step.selector, { timeout });
        break;
      case 'mouse':
        await page.mouse.move(step.x, step.y);
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
      case 'download': {
        // Click what starts it and keep what arrives. The expression reads
        // downloads[i]: {name, filename, size, sha256, text, failure}. text is
        // the file as UTF-8, up to 1 MB; null past that.
        const [dl] = await Promise.all([
          page.waitForEvent('download', { timeout: step.timeout || 15000 }),
          page.click(step.selector, { timeout }),
        ]);
        const failure = await dl.failure();
        const entry = { name: step.name || dl.suggestedFilename(), filename: dl.suggestedFilename(),
                        url: dl.url(), size: 0, sha256: null, text: null, failure };
        if (!failure) {
          const buf = readFileSync(await dl.path());
          entry.size = buf.length;
          entry.sha256 = createHash('sha256').update(buf).digest('hex');
          entry.text = buf.length <= 1048576 ? buf.toString('utf8') : null;
        }
        stateOf(page).downloads.push(entry);
        break;
      }
      case 'upload': {
        // {"selector": "input[type=file]"} sets the input directly; {"click":
        // "#pick"} answers the file chooser a button opens instead.
        const files = (step.files || []).map(uploadFile);
        if (step.click) {
          const [chooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout }),
            page.click(step.click, { timeout }),
          ]);
          await chooser.setFiles(files);
        } else {
          await page.setInputFiles(step.selector, files, { timeout });
        }
        break;
      }
      case 'clipboard':
        // Read the clipboard into `clipboard` for the expression — after a
        // "Copy" click, say.
        await grantClipboard(page);
        stateOf(page).clipboard = await page.evaluate(() => navigator.clipboard.readText());
        break;
      case 'clipboardWrite':
        // Seed the clipboard, for a paste criterion.
        await grantClipboard(page);
        await page.evaluate((t) => navigator.clipboard.writeText(t), step.text ?? '');
        break;
      default:
        throw new Error(`unknown action type: ${step.type}`);
    }
  }
}
NODE

  return 0
}
