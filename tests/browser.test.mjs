// End-to-end check of the built dist/ in headless Chrome: it loads without
// console errors at desktop and phone widths, in both themes, with reduced
// motion and with the Canvas 2D fallback, and the core loop works (it runs
// by itself, halts at 10,000 years, paints with a real pointer drag and with
// the keyboard, exports, survives a lost WebGL context). The page exposes
// window.__silt only to automation or with ?test=1.
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

async function open(opts, query = '') {
  const page = await chrome.openPage(opts);
  await page.navigate(`${base}?test=1${query}`);
  await page.waitFor(ready, 30000);
  return page;
}

// Every request the page made, other than inline data: URLs, is to this server.
const OFF_ORIGIN = `performance.getEntriesByType('resource').map((e) => e.name)
  .filter((u) => !u.startsWith('data:') && new URL(u).origin !== location.origin)`;

// The self-hosted EB Garamond faces load under the production CSP.
// document.fonts.load() rejects if a file is blocked or broken, and resolves
// with the faces it loaded; check() is then true for each descriptor.
const FACES = `(async () => {
  await document.fonts.ready;
  const out = {};
  for (const d of ['400 17px "EB Garamond"', '500 17px "EB Garamond"', '600 17px "EB Garamond"', 'italic 400 17px "EB Garamond"']) {
    const loaded = await document.fonts.load(d);
    out[d] = { faces: loaded.filter((f) => f.status === 'loaded').length, check: document.fonts.check(d) };
  }
  out.files = [...new Set(performance.getEntriesByType('resource').map((e) => new URL(e.name).pathname).filter((p) => p.endsWith('.woff2')))].sort();
  return out;
})()`;

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

test('browser: desktop page loads, runs by itself and paints without errors', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  const page = await open({ width: 1280, height: 800, scheme: 'light' });
  try {
    const l = JSON.parse(await page.evaluate(layout));
    assert.equal(l.scrollW, l.clientW, 'horizontal scroll at 1280 px');
    assert.ok(['webgl2', 'canvas2d'].includes(l.renderer));
    assert.equal(l.theme, 'light');
    assert.ok(await page.evaluate(inkOnMap) > 20, 'the map looks blank');

    // The typeface comes from this site: nothing is fetched from anywhere else.
    const faces = await page.evaluate(FACES);
    assert.deepEqual(await page.evaluate(OFF_ORIGIN), [], 'requests left the site');
    for (const [d, r] of Object.entries(faces)) {
      if (d === 'files') continue;
      assert.ok(r.faces >= 1 && r.check, `${d} did not load from a self-hosted face: ${JSON.stringify(r)}`);
    }
    assert.deepEqual(faces.files, ['/fonts/eb-garamond-italic-400.woff2', '/fonts/eb-garamond-variable.woff2']);

    // The rain starts by itself; the rivers are surveyed as it runs.
    assert.equal(await page.evaluate('window.__silt.state.running'), true, 'no autoplay');
    await page.waitFor('window.__silt.engine.steps > 60 && window.__silt.engine.rivers().length > 5 * 20', 20000);
    await page.waitFor(`/ms per step.*measured here \\(512² grid\\)/.test(document.getElementById('tb-step').textContent)`, 5000);
    // Halt.
    await page.evaluate(`document.getElementById('run').click()`);
    const halted = await page.evaluate('window.__silt.engine.steps');
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(await page.evaluate('window.__silt.engine.steps'), halted, 'still running after Halt');
    assert.match(await page.evaluate(`document.getElementById('years').textContent`), /^[\d,]+$/);

    // A new grid has no timing yet, never the other grid's number. Time is
    // halted, so the line says it has not been timed rather than "measuring…".
    await page.evaluate(`document.querySelector('input[name="grid"][value="256"]').click()`);
    assert.match(await page.evaluate(`document.getElementById('tb-step').textContent`), /^not timed yet; timed once the survey runs \(256² grid\)$/);
    await page.evaluate(`document.getElementById('step').click()`);
    await page.waitFor(`/ms per step.*\\(256² grid\\)/.test(document.getElementById('tb-step').textContent)`, 5000);
    await page.evaluate(`document.querySelector('input[name="grid"][value="512"]').click()`);
    assert.match(await page.evaluate(`document.getElementById('tb-step').textContent`), /^not timed yet; timed once the survey runs \(512² grid\)$/);

    // Run halts once at 10,000 years, with a note; Run again carries on.
    await page.evaluate('window.__silt.engine.step(7990)');
    await page.evaluate(`document.getElementById('run').click()`);
    await page.waitFor('!window.__silt.state.running', 20000);
    assert.equal(await page.evaluate('window.__silt.engine.steps'), 8000);
    assert.equal(await page.evaluate(`document.getElementById('years').textContent`), '10,000');
    assert.equal(await page.evaluate(`document.getElementById('status').textContent`), '10,000 years. Paint and press Run to keep going.');
    await page.evaluate(`document.getElementById('run').click()`);
    await page.waitFor('window.__silt.engine.steps > 8010', 20000);
    assert.equal(await page.evaluate(`document.getElementById('status').textContent`), '');
    await page.evaluate(`document.getElementById('run').click()`);

    // A real pointer drag across the map raises ground, and one drag with the
    // default brush is plainly visible: a ridge at least three 20 m contours tall.
    await page.evaluate('void (window.__h0 = Float32Array.from(window.__silt.engine.fields().height))');
    const box = JSON.parse(await page.evaluate(`JSON.stringify(window.__silt.state.renderer.canvas.getBoundingClientRect())`));
    const at = (fx, fy) => ({ x: box.x + box.width * fx, y: box.y + box.height * fy });
    const mouse = (type, p, buttons) => page.send('Input.dispatchMouseEvent', { type, x: p.x, y: p.y, button: 'left', buttons, clickCount: 1 });
    await mouse('mousePressed', at(0.3, 0.45), 1);
    for (let k = 1; k <= 10; k++) await mouse('mouseMoved', at(0.3 + k * 0.03, 0.45), 1);
    await mouse('mouseReleased', at(0.6, 0.45), 0);
    const painted = await page.evaluate('window.__silt.engine.stat(7)');
    assert.ok(painted > 1, `pointer painting added ${painted}`);
    const ridgeM = await page.evaluate(`(() => {
      const h = window.__silt.engine.fields().height;
      let max = 0;
      for (let i = 0; i < h.length; i++) max = Math.max(max, h[i] - window.__h0[i]);
      return max * 20;
    })()`);
    assert.ok(ridgeM >= 60, `one default drag raised the ground by only ${ridgeM.toFixed(1)} m`);
    assert.equal(await page.evaluate(`document.getElementById('strength-out').textContent`), '20.0 m a dab');

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

    // Losing the WebGL context says so, and the map comes back when it is restored.
    if (l.renderer === 'webgl2') {
      await page.evaluate(`(window.__lose = window.__silt.state.renderer.canvas.getContext('webgl2').getExtension('WEBGL_lose_context'), window.__lose.loseContext())`);
      await page.waitFor(`/graphics card dropped the map/.test(document.getElementById('status').textContent)`, 5000);
      await page.evaluate('window.__lose.restoreContext()');
      await page.waitFor(`document.getElementById('status').textContent === '' && !window.__silt.state.lost && !window.__silt.state.dirty`, 10000);
      assert.ok(await page.evaluate(inkOnMap) > 20, 'the map did not come back');
    }

    // Bad survey number: a clear message, nothing reset.
    const steps = await page.evaluate('window.__silt.engine.steps');
    await page.evaluate(`(() => { const i = document.getElementById('seed'); i.value = 'twelve'; document.getElementById('survey-form').requestSubmit(); })()`);
    assert.match(await page.evaluate(`document.getElementById('seed-msg').textContent`), /whole numbers from 1 to 99,999/);
    assert.equal(await page.evaluate(`document.getElementById('seed').getAttribute('aria-invalid')`), 'true');
    assert.equal(await page.evaluate('window.__silt.engine.steps'), steps);

    // Dabs are spaced along the path, not one batch per pointer event, so a
    // quick drag (3 events) paints as much as a slow one (60 events).
    const dragTotal = async (moves) => {
      await page.evaluate(`document.getElementById('reset').click()`);
      await page.evaluate(`document.querySelector('input[name="mode"][value="raise"]').click()`);
      await mouse('mousePressed', at(0.3, 0.45), 1);
      for (let k = 1; k <= moves; k++) await mouse('mouseMoved', at(0.3 + (0.3 * k) / moves, 0.45), 1);
      await mouse('mouseReleased', at(0.6, 0.45), 0);
      return page.evaluate('window.__silt.engine.stat(7)');
    };
    const quick = await dragTotal(3);
    const slow = await dragTotal(60);
    assert.ok(quick > 1 && Math.abs(quick - slow) <= 0.01 * slow, `a quick drag painted ${quick}, a slow one ${slow}`);

    // Reset while halted, on the same grid: the measured step time stays on show.
    await page.evaluate(`document.getElementById('reset').click()`);
    assert.equal(await page.evaluate('window.__silt.state.running'), false);
    assert.match(await page.evaluate(`document.getElementById('tb-step').textContent`), /^\d+\.\d\d ms per step.*measured here \(512² grid\)$/);
    assert.deepEqual(await page.evaluate(OFF_ORIGIN), [], 'requests left the site');
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
    assert.deepEqual(await page.evaluate(OFF_ORIGIN), [], 'phone: requests left the site');
    noProblems(page, 'phone');
  } finally {
    await page.close();
  }
});

test('browser: reduced motion never animates; the user steps it', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  const page = await open({ width: 1280, height: 800, reducedMotion: true });
  try {
    assert.equal(await page.evaluate('window.__silt.state.running'), false, 'autoplay under reduced motion');
    assert.equal(await page.evaluate('window.__silt.engine.steps'), 0);
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
  const page = await open({ width: 1024, height: 768 }, '&renderer=canvas2d&seed=abc&grid=256');
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

test('browser: the test hook is hidden from ordinary visitors', { skip: plan.skip }, async () => {
  if (plan.fail) assert.fail(plan.fail);
  // Look like a normal browser (not automation), and leave out ?test=1.
  const page = await chrome.openPage({ width: 1024, height: 768, initScript: "Object.defineProperty(Navigator.prototype, 'webdriver', { get: () => false })" });
  try {
    await page.navigate(base);
    await page.waitFor(`document.documentElement.dataset.renderer && document.getElementById('status').textContent === ''`, 30000);
    assert.equal(await page.evaluate('navigator.webdriver'), false);
    assert.equal(await page.evaluate('typeof window.__silt'), 'undefined');
    noProblems(page, 'no hook');
  } finally {
    await page.close();
  }
});
