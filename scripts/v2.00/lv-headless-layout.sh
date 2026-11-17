#!/usr/bin/env bash
# lv-headless-layout.sh <url> [actions-json] [--sizes WxH,WxH] [--min-target N]
#
# The standard layout audit /lv-test step 3c runs on every route a plan
# touches: the same four assertions at a phone width and a desktop width,
# instead of a screenshot somebody has to judge.
#
# WHY THIS EXISTS
#
# A client's tester judged 390px screenshots of a quiz "ambiguous" and passed
# them. A Playwright run from the coordinator then found, on the same build, a
# radio left alone on a line above its long label (the label was
# inline-block), 18px-tall guide links under every result, and a count that
# read "1 marbles today" (the coordinator's LVI-044). Three of those are
# geometry, and geometry is an assertion, not a judgement.
#
# WHAT IT ASSERTS, at each size (default 390x844 and 1280x800)
#
#   overflow   no horizontal page scroll: documentElement.scrollWidth <=
#              clientWidth. The widest elements past the edge are named.
#   target     every visible button, a, input, select, and every label of a
#              radio or checkbox, is at least --min-target px tall (default
#              24, WCAG 2.5.8). Exempt: a link inside running text (its
#              block has other text beside it), a radio or checkbox that has
#              a label (the label is the target and is checked instead), and
#              hidden inputs.
#   align      each visible radio and checkbox sits on the same line as the
#              first line of its label's text: that line's box overlaps the
#              input's box vertically.
#   text       no element whose own text overflows its box: scrollWidth >
#              clientWidth nominates, and the in-flow text itself
#              (absolute/fixed descendants left out) must reach past the
#              padding box, on an element that holds text directly, does not
#              scroll (overflow-x not auto/scroll) and does not truncate on
#              purpose (text-overflow: ellipsis).
#
#   Every check skips an element hidden on purpose: display none, visibility
#   hidden, opacity 0, and the visually-hidden (screen-reader-only) pattern —
#   a zero-area clip, clip-path inset(50%), or overflow hidden on a box 1px or
#   less — on the element or any ancestor.
#
# actions-json (optional) runs before the audit at every size, to reach the
# state in question; the vocabulary is lv-headless-eval.sh's (see its header).
#
# Output (the contract /lv-test parses — the LAST line is the verdict):
#   one line per problem:  "<WxH> <check>: <element> — <what>"
#   then the verdict:
#   0 — "PASS layout <sizes>: no overflow, targets >= Npx, radios and checkboxes on their label's line, no text overflow"
#   1 — "FAIL layout <sizes>: <n> problem(s) — <check counts>"
#   2 — "ERROR <reason>": no result (no browser, a navigation or action that
#       failed). Never a FAIL, and never a PASS.

set -uo pipefail

URL=""
ACTIONS="[]"
SIZES="390x844,1280x800"
MIN_TARGET=24
pos=0
while [ $# -gt 0 ]; do
  case "$1" in
    --sizes) SIZES="${2:-}"; shift 2 ;;
    --min-target) MIN_TARGET="${2:-}"; shift 2 ;;
    -*) echo "ERROR unknown option: $1"; exit 2 ;;
    *)
      pos=$((pos + 1))
      case $pos in
        1) URL="$1" ;;
        2) ACTIONS="$1" ;;
        *) echo "ERROR argument past the last one: ${1:0:60} - pass actions-json as ONE single-quoted argument"; exit 2 ;;
      esac
      shift ;;
  esac
done

if [ -z "$URL" ]; then
  echo "ERROR usage: lv-headless-layout.sh <url> [actions-json] [--sizes WxH,WxH] [--min-target N]"
  exit 2
fi
case "$SIZES" in
  ''|*[!0-9x,]*) echo "ERROR --sizes must be WxH[,WxH...], got: ${SIZES:0:40}"; exit 2 ;;
esac
case "$MIN_TARGET" in
  ''|*[!0-9]*) echo "ERROR --min-target must be a number, got: ${MIN_TARGET:0:20}"; exit 2 ;;
esac

# shellcheck source=lv-headless-common.sh
source "$(dirname "$0")/lv-headless-common.sh"
wf_headless_check_args "$ACTIONS" 1 1 0 || exit 2
wf_headless_ensure_ready || exit 2

RUNNER="$CACHE_DIR/run-layout.mjs"

cat > "$RUNNER" <<'NODE'
import { chromium } from 'playwright';
import { runActions } from './actions.mjs';

const [, , url, actionsJson, sizesArg, minTargetArg] = process.argv;
const minTarget = Number(minTargetArg);

// Runs in the page. Returns [{check, el, what}].
function audit(minTarget) {
  const out = [];
  const de = document.documentElement;
  // The visually-hidden pattern (position absolute, a 1px box, overflow
  // hidden, clip rect(0 0 0 0) or clip-path inset(50%)) keeps an element for
  // screen readers on purpose. Its text overflows a 1px box by design: a
  // client's landing <h1> failed every page it was on (LVI-047). Judged on
  // the element and every ancestor, since the text may sit inside one.
  const zeroClip = (cs) => {
    if (!['absolute', 'fixed'].includes(cs.position)) return false;
    const m = /^rect\(\s*(-?[\d.]+)px[ ,]+(-?[\d.]+)px[ ,]+(-?[\d.]+)px[ ,]+(-?[\d.]+)px\s*\)$/.exec(cs.clip || '');
    return !!m && (Number(m[3]) <= Number(m[1]) || Number(m[2]) <= Number(m[4]));
  };
  const visuallyHidden = (el) => {
    for (let a = el; a && a !== document.documentElement; a = a.parentElement) {
      const cs = getComputedStyle(a);
      if (zeroClip(cs)) return true;
      if (/^inset\(\s*(50|100)%/.test(cs.clipPath || '')) return true;
      const r = a.getBoundingClientRect();
      if (['hidden', 'clip'].includes(cs.overflowX) && ['hidden', 'clip'].includes(cs.overflowY)
          && (r.width <= 1 || r.height <= 1)) return true;
    }
    return false;
  };
  const visible = (el) => {
    const cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity) === 0) return false;
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0 && !visuallyHidden(el);
  };
  const name = (el) => {
    let s = el.tagName.toLowerCase();
    if (el.id) s += '#' + el.id;
    else if (el.classList.length) s += '.' + [...el.classList].slice(0, 2).join('.');
    if (el.type && el.tagName === 'INPUT') s += `[type=${el.type}]`;
    const t = (el.innerText || el.value || el.getAttribute('aria-label') || '').trim().replace(/\s+/g, ' ');
    return t ? `${s} "${t.slice(0, 40)}${t.length > 40 ? '…' : ''}"` : s;
  };
  const px = (n) => `${Math.round(n)}px`;

  // overflow
  if (de.scrollWidth > de.clientWidth) {
    const wide = [...document.body.querySelectorAll('*')]
      .filter((el) => visible(el) && el.getBoundingClientRect().right > de.clientWidth + 1)
      .filter((el) => !el.parentElement || el.parentElement.getBoundingClientRect().right <= de.clientWidth + 1)
      .slice(0, 3).map(name);
    out.push({ check: 'overflow', el: 'document',
      what: `scrollWidth ${de.scrollWidth} > clientWidth ${de.clientWidth}${wide.length ? ' (past the edge: ' + wide.join(', ') + ')' : ''}` });
  }

  // target
  const inRunningText = (a) => {
    if (getComputedStyle(a).display !== 'inline') return false;
    let block = a.parentElement;
    while (block && getComputedStyle(block).display === 'inline') block = block.parentElement;
    if (!block) return false;
    const own = (a.innerText || '').trim().length;
    const all = (block.innerText || '').trim().length;
    return all - own >= 10;
  };
  const toggles = (el) => el.tagName === 'INPUT' && (el.type === 'radio' || el.type === 'checkbox');
  const targets = [...document.querySelectorAll('button, a[href], input, select, label')];
  for (const el of targets) {
    if (!visible(el)) continue;
    if (el.tagName === 'INPUT' && el.type === 'hidden') continue;
    if (toggles(el) && el.labels && el.labels.length) continue;
    if (el.tagName === 'LABEL') {
      const c = el.control;
      if (!c || !toggles(c)) continue;
    }
    if (el.tagName === 'A' && inRunningText(el)) continue;
    const h = el.getBoundingClientRect().height;
    if (h + 0.5 < minTarget) out.push({ check: 'target', el: name(el), what: `${px(h)} tall (< ${minTarget}px)` });
  }

  // align
  const firstTextLine = (label, input) => {
    const walker = document.createTreeWalker(label, NodeFilter.SHOW_TEXT);
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      if (!n.textContent.trim()) continue;
      if (input.contains(n)) continue;
      const range = document.createRange();
      range.selectNodeContents(n);
      const rects = [...range.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
      if (rects.length) return rects[0];
    }
    return null;
  };
  for (const input of document.querySelectorAll('input[type=radio], input[type=checkbox]')) {
    if (!visible(input) || !input.labels || !input.labels.length) continue;
    const ib = input.getBoundingClientRect();
    const line = firstTextLine(input.labels[0], input);
    if (!line) continue;
    if (!(line.top < ib.bottom && line.bottom > ib.top)) {
      out.push({ check: 'align', el: name(input.labels[0]),
        what: `label text starts at y=${px(line.top)}, the ${input.type} spans y=${px(ib.top)}–${px(ib.bottom)}: not on the same line` });
    }
  }

  // text
  // scrollWidth counts absolutely positioned descendants, so a CTA holding
  // decorative corner spans at right:-6px read as text 6px too wide for a
  // label that fit (a client's LVI-017). scrollWidth only nominates; the
  // verdict is where the element's in-flow text actually lands, measured
  // from its padding box, skipping any absolute or fixed subtree.
  const textExtent = (el) => {
    const origin = el.getBoundingClientRect().left + el.clientLeft;
    let lo = Infinity, hi = -Infinity;
    const walk = (node) => {
      for (const c of node.childNodes) {
        if (c.nodeType === 3) {
          if (!c.textContent.trim()) continue;
          const range = document.createRange();
          range.selectNodeContents(c);
          for (const r of range.getClientRects()) {
            if (r.width > 0) { lo = Math.min(lo, r.left - origin); hi = Math.max(hi, r.right - origin); }
          }
        } else if (c.nodeType === 1 && !['absolute', 'fixed'].includes(getComputedStyle(c).position)) {
          walk(c);
        }
      }
    };
    walk(el);
    return hi === -Infinity ? null : { lo, hi };
  };
  for (const el of document.body.querySelectorAll('*')) {
    if (['INPUT', 'TEXTAREA', 'SELECT', 'SCRIPT', 'STYLE', 'SVG', 'svg'].includes(el.tagName)) continue;
    if (![...el.childNodes].some((n) => n.nodeType === 3 && n.textContent.trim())) continue;
    if (!visible(el)) continue;
    const cs = getComputedStyle(el);
    if (cs.display === 'inline' || cs.display === 'contents') continue;
    if (['auto', 'scroll'].includes(cs.overflowX) || cs.textOverflow === 'ellipsis') continue;
    if (el.clientWidth > 0 && el.scrollWidth > el.clientWidth + 1) {
      const t = textExtent(el);
      if (!t || (t.hi <= el.clientWidth + 1 && t.lo >= -1)) continue;
      const wide = Math.round(Math.max(t.hi, el.clientWidth) - Math.min(t.lo, 0));
      out.push({ check: 'text', el: name(el), what: `text is ${wide}px wide in a ${el.clientWidth}px box` });
    }
  }
  return out;
}

let browser;
try {
  const actions = JSON.parse(actionsJson || '[]');
  const sizes = sizesArg.split(',').filter(Boolean).map((s) => s.split('x').map(Number));
  browser = await chromium.launch();
  const problems = [];
  for (const [width, height] of sizes) {
    const page = await browser.newPage({ viewport: { width, height } });
    await page.goto(url, { waitUntil: 'load', timeout: 15000 });
    await page.waitForTimeout(300);
    await runActions(page, actions);
    for (const p of await page.evaluate(audit, minTarget)) problems.push({ size: `${width}x${height}`, ...p });
    await page.close();
  }
  await browser.close();
  const label = sizes.map(([w, h]) => `${w}x${h}`).join(' ');
  if (problems.length === 0) {
    console.log(`PASS layout ${label}: no overflow, targets >= ${minTarget}px, radios and checkboxes on their label's line, no text overflow`);
    process.exit(0);
  }
  const shown = problems.slice(0, 40);
  for (const p of shown) console.log(`${p.size} ${p.check}: ${p.el} — ${p.what}`);
  if (problems.length > shown.length) console.log(`… and ${problems.length - shown.length} more`);
  const counts = {};
  for (const p of problems) counts[p.check] = (counts[p.check] || 0) + 1;
  console.log(`FAIL layout ${label}: ${problems.length} problem(s) — ${Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(', ')}`);
  process.exit(1);
} catch (err) {
  if (browser) { try { await browser.close(); } catch {} }
  console.log(`ERROR ${String((err && err.message) || err).split('\n')[0]}`);
  process.exit(2);
}
NODE

node "$RUNNER" "$URL" "$ACTIONS" "$SIZES" "$MIN_TARGET"
exit $?
