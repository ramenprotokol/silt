// Text colours reach WCAG AA (4.5:1) on the sheet, in both themes.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { root } from './helpers.mjs';

const css = readFileSync(join(root, 'web', 'styles.css'), 'utf8');

function block(selectorPattern) {
  const m = selectorPattern.exec(css);
  assert.ok(m, `no block for ${selectorPattern}`);
  const start = css.indexOf('{', m.index) + 1;
  let depth = 1;
  let i = start;
  while (depth > 0) {
    if (css[i] === '{') depth++;
    if (css[i] === '}') depth--;
    i++;
  }
  return css.slice(start, i - 1);
}

function tokens(text) {
  const out = {};
  for (const m of text.matchAll(/--([\w-]+):\s*(#[0-9a-fA-F]{6})\s*;/g)) out[m[1]] = m[2].toLowerCase();
  return out;
}

function luminance(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

export function contrast(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

const light = tokens(block(/^:root \{/m));
const dark = tokens(block(/^:root\[data-theme="dark"\] \{/m));
const darkAuto = tokens(block(/:root:not\(\[data-theme="light"\]\) \{/));

// [text, background, where it is used]
const pairs = [
  ['ink', 'sheet', 'body text'],
  ['ink-2', 'sheet', 'captions, notes, legend labels'],
  ['accent', 'sheet', 'error messages, the selected stamp'],
  ['btn-ink', 'ink', 'primary button, title-block header'],
  ['btn-ink', 'accent', 'pressed Run button'],
];

for (const [name, theme] of [['light', light], ['dark', dark]]) {
  test(`${name} theme: text contrast is at least 4.5:1`, () => {
    for (const [fg, bg, where] of pairs) {
      const ratio = contrast(theme[fg], theme[bg]);
      assert.ok(ratio >= 4.5, `${name}: --${fg} on --${bg} (${where}) is ${ratio.toFixed(2)}:1`);
    }
  });
}

test('the two copies of the dark tokens match', () => {
  assert.deepEqual(darkAuto, dark);
});
