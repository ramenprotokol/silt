// Static checks on what dist/ serves: security headers, caching, privacy of the page.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { dist, root } from './helpers.mjs';

test('dist/ has the page, the kernel and the headers', () => {
  const files = readdirSync(dist).sort();
  for (const f of ['index.html', 'app.js', 'engine.js', 'render.js', 'readout.js', 'styles.css', 'silt.wasm', '_headers', 'favicon.svg', 'THIRD-PARTY-NOTICES.txt']) {
    assert.ok(files.includes(f), `${f} missing from dist/`);
  }
});

test('third-party notices ship with the page and are linked from it', () => {
  const notices = readFileSync(join(dist, 'THIRD-PARTY-NOTICES.txt'), 'utf8');
  assert.match(notices, /Zig standard library and compiler-rt/);
  assert.match(notices, /Copyright \(c\) Zig contributors/);
  assert.match(notices, /musl/);
  assert.match(notices, /Rich Felker/);
  assert.match(notices, /Permission is hereby granted/);
  assert.match(readFileSync(join(dist, 'index.html'), 'utf8'), /href="THIRD-PARTY-NOTICES\.txt"/);
});

test('the notices cover the shipped EB Garamond files: version, copyright line and the OFL text', () => {
  const notices = readFileSync(join(dist, 'THIRD-PARTY-NOTICES.txt'), 'utf8');
  assert.match(notices, /EB Garamond 1\.003/);
  assert.match(notices, /Copyright 2017 The EB Garamond Project Authors \(https:\/\/github\.com\/octaviopardo\/EBGaramond12\)/);
  assert.match(notices, /SIL OPEN FONT LICENSE Version 1\.1/);
  assert.match(notices, /PERMISSION & CONDITIONS/);
  assert.ok(existsSync(join(dist, 'fonts')), 'dist/fonts/ is missing');
  for (const f of readdirSync(join(dist, 'fonts'))) assert.ok(notices.includes(`fonts/${f}`), `fonts/${f} has no notice`);
  assert.doesNotMatch(notices, /Google Fonts, not|not in dist\/|fetched by the browser at page load/);
});

// The typeface ships with the site: no Google Fonts host anywhere in what is
// served, the CSP allows styles and fonts from the site only, and every
// @font-face points at a WOFF2 file that is really in dist/.
const fontFaces = (css) =>
  [...css.matchAll(/@font-face\s*{([^}]*)}/g)].map(([, body]) => {
    const prop = (name) => new RegExp(`(?:^|;)\\s*${name}\\s*:\\s*([^;]+)`).exec(body)?.[1].trim();
    return {
      family: prop('font-family')?.replace(/["']/g, ''),
      style: prop('font-style') ?? 'normal',
      weight: prop('font-weight'),
      display: prop('font-display'),
      urls: [...body.matchAll(/url\(\s*["']?([^"')]+)["']?\s*\)/g)].map((m) => m[1]),
    };
  });

test('no shipped page, stylesheet or header names a Google Fonts host', () => {
  for (const f of ['index.html', 'styles.css', '_headers']) {
    assert.doesNotMatch(readFileSync(join(dist, f), 'utf8'), /googleapis|gstatic|fonts\.google/i, `${f} still names Google Fonts`);
  }
});

test("the CSP allows styles and fonts from this site only", () => {
  const csp = /Content-Security-Policy:\s*(.+)/.exec(readFileSync(join(dist, '_headers'), 'utf8'))[1];
  const directive = (name) => new RegExp(`(?:^|;)\\s*${name}\\s+([^;]+)`).exec(csp)?.[1].trim();
  assert.equal(directive('font-src'), "'self'");
  assert.equal(directive('style-src'), "'self'");
});

test('EB Garamond (roman 400-600 and italic 400) is self-hosted WOFF2, each file referenced from the stylesheet', () => {
  const faces = fontFaces(readFileSync(join(dist, 'styles.css'), 'utf8')).filter((f) => f.family === 'EB Garamond');
  const roman = faces.find((f) => f.style === 'normal');
  const italic = faces.find((f) => f.style === 'italic');
  assert.ok(roman, 'no roman @font-face for EB Garamond');
  assert.ok(italic, 'no italic @font-face for EB Garamond');
  const [lo, hi = lo] = roman.weight.split(/\s+/).map(Number);
  assert.ok(lo <= 400 && hi >= 600, `roman covers ${roman.weight}, the page uses 400, 500 and 600`);
  assert.equal(italic.weight, '400');
  const referenced = new Set();
  for (const face of faces) {
    assert.equal(face.display, 'swap');
    for (const url of face.urls) {
      assert.doesNotMatch(url, /^(https?:)?\/\//, `${url} is not on this site`);
      const file = join(dist, url);
      assert.ok(existsSync(file), `dist/${url} is missing`);
      assert.equal(readFileSync(file).subarray(0, 4).toString('latin1'), 'wOF2', `${url} is not WOFF2`);
      referenced.add(url);
    }
  }
  assert.ok(existsSync(join(dist, 'fonts')), 'dist/fonts/ is missing');
  const shipped = readdirSync(join(dist, 'fonts')).filter((f) => f.endsWith('.woff2')).map((f) => `fonts/${f}`);
  assert.deepEqual([...referenced].sort(), shipped.sort(), 'every shipped font file is used, and every used one ships');
});

test('a static site: no Worker secrets template in the repo', () => {
  assert.ok(!existsSync(join(root, '.dev.vars.example')));
});

test('_headers sets a CSP and no long cache on unhashed files', () => {
  const h = readFileSync(join(dist, '_headers'), 'utf8');
  assert.match(h, /Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'/);
  assert.match(h, /X-Content-Type-Options: nosniff/);
  assert.doesNotMatch(h, /max-age=[1-9]/);
  assert.doesNotMatch(h, /immutable/);
});

test('no deploy script bypasses the guarded deploy path', () => {
  const pkg = JSON.parse(readFileSync(join(root, 'package.json'), 'utf8'));
  for (const [name, cmd] of Object.entries(pkg.scripts)) {
    assert.doesNotMatch(cmd, /wrangler/, `npm script "${name}" calls wrangler`);
  }
  assert.doesNotMatch(readFileSync(join(root, 'wrangler.toml'), 'utf8'), /^\s*account_id\s*=/m);
});

test('the page makes no hard-coded speed claims', () => {
  const html = readFileSync(join(dist, 'index.html'), 'utf8');
  assert.doesNotMatch(html, /\b(instant|blazing|lightning|\d+\s*(x|×)\s*faster|under a second)\b/i);
});
