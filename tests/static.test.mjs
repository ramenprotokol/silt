// Static checks on what dist/ serves: security headers, caching, privacy of the page.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { dist, root } from './helpers.mjs';

test('dist/ has the page, the kernel and the headers', () => {
  const files = readdirSync(dist).sort();
  for (const f of ['index.html', 'app.js', 'engine.js', 'render.js', 'styles.css', 'silt.wasm', '_headers', 'favicon.svg']) {
    assert.ok(files.includes(f), `${f} missing from dist/`);
  }
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
