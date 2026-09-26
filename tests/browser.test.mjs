// End-to-end check of the built dist/ in headless Chrome: it loads without
// console errors at desktop and phone widths, in both themes, with reduced
// motion and with the Canvas 2D fallback, and the core loop works (run,
// paint with a real pointer drag, paint with the keyboard, export).
import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { serve } from '../scripts/serve.mjs';
import { browserPlan, findChrome, launchChrome } from './cdp.mjs';
import { dist } from './helpers.mjs';

const chromePath = findChrome();
const plan = browserPlan(chromePath);
let server;
let chrome;
let base;

before(async () => {
  if (!plan.run) return;
  server = await serve(dist, 0);
  base = `http://127.0.0.1:${server.address().port}/`;
  chrome = await launchChrome(chromePath);
  await chrome.send('Browser.setDownloadBehavior', { behavior: 'deny' });
});

after(async () => {
  await chrome?.close();
  await new Promise((r) => (server ? server.close(r) : r()));
});

const ready = 'window.__silt && window.__silt.state.renderer && window.__silt.state.engine.size > 0';

async function open(opts, path = '') {
  const page = await chrome.openPage(opts);
  await page.navigate(base + path);
  await page.waitFor(ready, 30000);
  return page;
}

function noProblems(page, label) {
  // Chrome may log a GPU-stall performance warning in headless; that is not an error.
  const real = page.problems.filter((p) => !/GPU stall due to ReadPixels/.test(p.text));
  assert.deepEqual(real, [], `${label}: ${JSON.stringify(real)}`);
}

const layout = `JSON.stringify({
  scrollW: document.documentElement.scrollWidth,
  clientW: document.documentElement.clientWidth,
  renderer: document.documentElement.dataset.renderer,
  theme: document.documentElement.dataset.theme,
  grid: window.__silt.state.grid,
})`;

// Distinct colours in a sample of the map canvas: a blank canvas has one.
const inkOnMap = `(() => {
  const c = window.__silt.state.renderer.canvas;
  const t = document.createElement('canvas');
  t.width = 64; t.height = 64;
  const g = t.getContext('2d');
  g.drawImage(c, 0, 0, 64, 64);
  const d = g.getImageData(0, 0, 64, 64).data;
  const seen = new Set();
  for (let i = 0; i < d.length; i += 4) seen.add((d[i] >> 3) << 10 | (d[i + 1] >> 3) << 5 | (d[i + 2] >> 3));
  return seen.size;
})()`;

test('browser: desktop page loads, runs and paints without errors', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  const page = await open({ width: 1280, height: 800, scheme: 'light' });
  try {
    const l = JSON.parse(await page.evaluate(layout));
    assert.equal(l.scrollW, l.clientW, 'horizontal scroll at 1280 px');
    assert.ok(['webgl2', 'canvas2d'].includes(l.renderer));
    assert.equal(l.theme, 'light');
    assert.ok(await page.evaluate(inkOnMap) > 20, 'the map looks blank');

    // Run for a moment, then halt.
    await page.evaluate(`document.getElementById('run').click()`);
    await page.waitFor('window.__silt.engine.steps > 30', 20000);
    await page.evaluate(`document.getElementById('run').click()`);
    const halted = await page.evaluate('window.__silt.engine.steps');
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(await page.evaluate('window.__silt.engine.steps'), halted, 'still running after Halt');
    assert.match(await page.evaluate(`document.getElementById('years').textContent`), /^[\d,]+$/);

    // A real pointer drag across the map raises ground.
    const box = JSON.parse(await page.evaluate(`JSON.stringify(window.__silt.state.renderer.canvas.getBoundingClientRect())`));
    const at = (fx, fy) => ({ x: box.x + box.width * fx, y: box.y + box.height * fy });
    const mouse = (type, p, buttons) => page.send('Input.dispatchMouseEvent', { type, x: p.x, y: p.y, button: 'left', buttons, clickCount: 1 });
    await mouse('mousePressed', at(0.3, 0.45), 1);
    for (let k = 1; k <= 10; k++) await mouse('mouseMoved', at(0.3 + k * 0.03, 0.45), 1);
    await mouse('mouseReleased', at(0.6, 0.45), 0);
    const painted = await page.evaluate('window.__silt.engine.stat(7)');
    assert.ok(painted > 1, `pointer painting added ${painted}`);

    // Keyboard painting: focus the map, move, press Enter.
    await page.evaluate(`document.querySelector('input[name="mode"][value="lower"]').click()`);
    await page.evaluate(`window.__silt.state.renderer.canvas.focus()`);
    const k = (key, code) => Promise.all([
      page.send('Input.dispatchKeyEvent', { type: 'keyDown', key, code, windowsVirtualKeyCode: code === 'Enter' ? 13 : 37 }),
      page.send('Input.dispatchKeyEvent', { type: 'keyUp', key, code }),
    ]);
    await k('ArrowLeft', 'ArrowLeft');
    await k('Enter', 'Enter');
    const afterKey = await page.evaluate('window.__silt.engine.stat(7)');
    assert.ok(afterKey < painted, 'keyboard Enter with "Lower" did not remove ground');

    // Export the heightmap (downloads are denied in the test browser).
    await page.evaluate(`document.getElementById('export-height').click()`);
    assert.match(await page.evaluate(`document.getElementById('export-msg').textContent`), /16-bit PNG/);

    // Bad survey number: a clear message, nothing reset.
    const steps = await page.evaluate('window.__silt.engine.steps');
    await page.evaluate(`(() => { const i = document.getElementById('seed'); i.value = 'twelve'; document.getElementById('survey-form').requestSubmit(); })()`);
    assert.match(await page.evaluate(`document.getElementById('seed-msg').textContent`), /whole numbers from 1 to 99,999/);
    assert.equal(await page.evaluate(`document.getElementById('seed').getAttribute('aria-invalid')`), 'true');
    assert.equal(await page.evaluate('window.__silt.engine.steps'), steps);
    noProblems(page, 'desktop');
  } finally {
    await page.close();
  }
});

test('browser: phone width (400 px, device emulation), dark theme', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  const page = await open({ width: 400, height: 860, mobile: true, scale: 2, scheme: 'dark' });
  try {
    const l = JSON.parse(await page.evaluate(layout));
    assert.equal(l.clientW, 400);
    assert.equal(l.scrollW, 400, 'horizontal scroll at 400 px');
    assert.equal(l.theme, 'dark');
    assert.ok(await page.evaluate(inkOnMap) > 20, 'the map looks blank');
    noProblems(page, 'phone');
  } finally {
    await page.close();
  }
});

test('browser: reduced motion never animates; the user steps it', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  const page = await open({ width: 1280, height: 800, reducedMotion: true });
  try {
    assert.equal(await page.evaluate(`document.getElementById('run').textContent`), '+1,000 years');
    await page.evaluate(`document.getElementById('run').click()`);
    await page.waitFor('window.__silt.engine.steps === 800 && !document.getElementById("run").disabled', 30000);
    assert.equal(await page.evaluate('window.__silt.state.running'), false);
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(await page.evaluate('window.__silt.engine.steps'), 800, 'kept running after the jump');
    noProblems(page, 'reduced motion');
  } finally {
    await page.close();
  }
});

test('browser: Canvas 2D fallback and a bad seed in the address', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  const page = await open({ width: 1024, height: 768 }, '?renderer=canvas2d&seed=abc&grid=256');
  try {
    const l = JSON.parse(await page.evaluate(layout));
    assert.equal(l.renderer, 'canvas2d');
    assert.equal(l.grid, 256);
    assert.equal(l.scrollW, l.clientW, 'horizontal scroll at 1024 px');
    assert.ok(await page.evaluate(inkOnMap) > 10, 'the fallback map looks blank');
    assert.match(await page.evaluate(`document.getElementById('seed-msg').textContent`), /not a survey number/);
    noProblems(page, 'canvas2d');
  } finally {
    await page.close();
  }
});
