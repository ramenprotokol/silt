// silt: the page. UI, input and the animation loop. The simulation itself
// is the Zig kernel in silt.wasm; this file only drives it and draws.

import { loadEngine, PARAM, STAT, GRID_FULL, GRID_LIGHT, METRES_PER_UNIT, WORLD_UNITS } from './engine.js';
import { createRenderer, PALETTES } from './render.js';
import { stepTimeText } from './readout.js';

const YEARS_PER_STEP = 1.25; // playful scale, stated on the page
const STEP_BUTTON = 20; // +25 years
const ADVANCE_STEPS = 800; // reduced motion: +1,000 years per press
const GOAL_STEPS = 8000; // 10,000 years: Run halts here once per survey
const GOAL_NOTE = '10,000 years. Paint and press Run to keep going.';
const SLOW_STEP_MS = 10; // a 512² step slower than this falls back to 256²
const FRAME_BUDGET_MS = 9; // simulation time per animation frame
const MAX_SEED = 99999;
const DEFAULT_SEED = 1;
const RAIN_SCALE = 1000; // slider value / 1000 = kernel rain rate
const MAP_KM = (WORLD_UNITS * METRES_PER_UNIT) / 1000; // 10.24 km across

const $ = (id) => document.getElementById(id);
const params = new URLSearchParams(location.search);
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
const darkQuery = matchMedia('(prefers-color-scheme: dark)');

const ui = {
  canvas: $('map'),
  ring: $('ring'),
  status: $('status'),
  run: $('run'),
  step: $('step'),
  reset: $('reset'),
  years: $('years'),
  size: $('size'),
  sizeOut: $('size-out'),
  strength: $('strength'),
  strengthOut: $('strength-out'),
  rain: $('rain'),
  rainOut: $('rain-out'),
  seed: $('seed'),
  seedMsg: $('seed-msg'),
  form: $('survey-form'),
  newSurvey: $('new-survey'),
  gridNote: $('grid-note'),
  exportHeight: $('export-height'),
  exportMap: $('export-map'),
  exportMsg: $('export-msg'),
  legend: $('legend'),
  scale: $('scale'),
  ticks: $('ticks'),
  theme: $('theme'),
  tbGrid: $('tb-grid'),
  tbStep: $('tb-step'),
  tbLedger: $('tb-ledger'),
  tbWasm: $('tb-wasm'),
};

const state = {
  engine: null,
  renderer: null,
  grid: GRID_FULL,
  gridReason: '',
  seed: DEFAULT_SEED,
  running: false,
  advancing: 0, // reduced-motion steps still to run
  stepMs: null, // rolling average on the current grid; null until measured
  surveyMs: null, // drainage survey time on the current grid; null until measured
  pastGoal: false, // the 10,000-year halt has happened for this survey
  readoutsDue: false, // a first timing arrived: show it on the next draw
  lost: false, // the WebGL context is lost
  dirty: true,
  baseDirty: true,
  theme: 'light',
  books: null,
  stroke: null, // { x, y } last stamp in grid cells
  cursor: null, // { x, y } in grid cells (pointer or keyboard)
  frames: 0,
};

// ---------------------------------------------------------------------------
// Formatting

const fmtInt = (n) => Math.round(n).toLocaleString('en-GB');
const years = () => (state.engine ? state.engine.steps * YEARS_PER_STEP : 0);

function say(text) {
  ui.status.textContent = text;
}

// ---------------------------------------------------------------------------
// Survey lifecycle

function brushRadiusCells() {
  // The size slider is in 512-grid cells, so a brush covers the same ground on either grid.
  return (Number(ui.size.value) * state.grid) / GRID_FULL;
}

function applyRain() {
  state.engine.setParam(PARAM.rain, Number(ui.rain.value) / RAIN_SCALE);
}

// The kernel books every source and sink; the page checks that what is on
// the map still equals what the books say should be.
function openBooks() {
  const e = state.engine;
  state.books = { water: e.stat(STAT.water) - ledgerWater(), mass: ledgerMass() };
}

function ledgerWater() {
  const e = state.engine;
  return e.stat(STAT.rain) - e.stat(STAT.evaporation) + e.stat(STAT.seaExchange) + e.stat(STAT.brushWater) - e.stat(STAT.edgeWater);
}

/** Terrain plus suspended sediment, less painting, plus what ran off the edges: constant. */
function ledgerMass() {
  const e = state.engine;
  return e.stat(STAT.terrain) + e.stat(STAT.sediment) - e.stat(STAT.brushTerrain) + e.stat(STAT.edgeSediment);
}

function startSurvey(seed, grid) {
  state.seed = seed;
  state.grid = grid;
  state.engine.init(grid, seed);
  // Timings belong to a grid: show "measuring…" until this one is timed.
  state.stepMs = null;
  state.surveyMs = null;
  state.pastGoal = false;
  applyRain();
  openBooks();
  state.baseDirty = true;
  state.dirty = true;
  ui.seed.value = String(seed);
  for (const r of document.querySelectorAll('input[name="grid"]')) r.checked = Number(r.value) === grid;
  ui.tbGrid.textContent = `${grid} × ${grid} cells; the map is ${MAP_KM.toFixed(2)} km across`;
  ui.gridNote.textContent = state.gridReason;
  ui.exportMsg.textContent = '';
  const url = new URL(location.href);
  url.searchParams.set('seed', String(seed));
  history.replaceState(null, '', url);
  updateReadouts(true);
}

/** Time a few 512² steps; if this device is slow, run the lighter grid. */
function chooseGrid() {
  const forced = Number(params.get('grid'));
  if (forced === GRID_FULL || forced === GRID_LIGHT) {
    state.gridReason = `Grid ${forced}² chosen in the address bar.`;
    return forced;
  }
  const e = state.engine;
  e.init(GRID_FULL, state.seed);
  e.step(2); // warm up
  const times = [];
  for (let i = 0; i < 5; i++) {
    const t = performance.now();
    e.step(1);
    times.push(performance.now() - t);
  }
  times.sort((a, b) => a - b);
  const median = times[2];
  if (median > SLOW_STEP_MS) {
    state.gridReason = `A 512² step took ${median.toFixed(1)} ms on this device, so the survey runs on a 256² grid to stay smooth. You can switch back.`;
    return GRID_LIGHT;
  }
  state.gridReason = '';
  return GRID_FULL;
}

// ---------------------------------------------------------------------------
// Drawing and readouts

function palette() {
  return PALETTES[state.theme];
}

function draw() {
  if (!state.renderer.draw(state.engine, palette(), { baseDirty: state.baseDirty })) return false;
  state.baseDirty = false;
  return true;
}

function updateReadouts(force = false) {
  ui.years.textContent = fmtInt(years());
  state.frames++;
  // While running, the slower readouts refresh every 20th frame; when
  // halted (painting, stepping, resetting) they always refresh.
  if (!force && !state.readoutsDue && state.running && state.frames % 20 !== 0) return;
  state.readoutsDue = false;
  ui.tbStep.textContent = stepTimeText(state.stepMs, state.surveyMs, state.grid);
  // The kernel books every drop of water and grain of sediment; show how
  // closely the books balance (f32 fields, so a few parts per million).
  const e = state.engine;
  const b = state.books;
  const water = e.stat(STAT.water);
  const expected = b.water + ledgerWater();
  const scale = Math.abs(b.water) + e.stat(STAT.rain) + e.stat(STAT.evaporation) + Math.abs(e.stat(STAT.seaExchange)) + e.stat(STAT.edgeWater) + 1;
  const waterPpm = (Math.abs(water - expected) / scale) * 1e6;
  const massPpm = (Math.abs(ledgerMass() - b.mass) / (Math.abs(b.mass) + 1)) * 1e6;
  const worst = Math.max(waterPpm, massPpm);
  ui.tbLedger.textContent = `Water and rock balance to ${worst < 0.01 ? '< 0.01' : worst.toPrecision(2)} parts per million (checked live)`;
}

function resizeCanvas() {
  const c = state.renderer?.canvas ?? ui.canvas;
  const rect = c.getBoundingClientRect();
  const dpr = Math.min(window.devicePixelRatio || 1, 2);
  const px = Math.max(64, Math.min(2048, Math.round(rect.width * dpr)));
  if (c.width !== px || c.height !== px) {
    c.width = px;
    c.height = px;
    state.dirty = true;
  }
  drawTicks(rect.width);
  drawScaleBar(rect.width);
  placeRing();
}

function drawTicks() {
  // Kilometre ticks along the top and left of the neat line.
  const frame = ui.ticks.parentElement;
  const cs = getComputedStyle(frame);
  const pad = parseFloat(cs.paddingLeft);
  const top = parseFloat(cs.paddingTop);
  const frag = document.createDocumentFragment();
  const add = (cls, prop, value, text) => {
    const el = document.createElement('span');
    el.className = cls;
    el.style[prop] = value;
    if (text) el.textContent = text;
    frag.append(el);
  };
  for (let km = 0; km <= Math.floor(MAP_KM); km++) {
    const f = km / MAP_KM;
    const x = `calc(${pad + 5}px + (100% - ${pad + 10}px) * ${f})`;
    const y = `calc(${top + 5}px + (100% - ${top + 10}px) * ${f})`;
    add('tick tick-x', 'left', x);
    add('tick tick-y', 'top', y);
    if (km % 2 === 0) {
      add('tick-label tick-label-x', 'left', x, km === 0 ? '0 km' : String(km));
      if (km > 0) add('tick-label tick-label-y', 'top', y, String(km));
    }
  }
  ui.ticks.replaceChildren(frag);
}

function drawScaleBar(mapPx) {
  const avail = ui.scale.clientWidth || 180;
  const pxPerKm = mapPx / MAP_KM;
  let km = 4;
  while (km > 1 && km * pxPerKm > avail - 16) km /= 2;
  const w = km * pxPerKm;
  const seg = km <= 1 ? 4 : km;
  const segW = w / seg;
  const ns = 'http://www.w3.org/2000/svg';
  const svg = document.createElementNS(ns, 'svg');
  svg.setAttribute('width', String(Math.ceil(w + 16)));
  svg.setAttribute('height', '22');
  svg.setAttribute('aria-hidden', 'true');
  for (let i = 0; i < seg; i++) {
    const r = document.createElementNS(ns, 'rect');
    r.setAttribute('x', String(4 + i * segW));
    r.setAttribute('y', '14');
    r.setAttribute('width', String(segW));
    r.setAttribute('height', '5');
    r.setAttribute('class', i % 2 ? 'sc-open' : 'sc-fill');
    svg.append(r);
  }
  const label = (x, text) => {
    const t = document.createElementNS(ns, 'text');
    t.setAttribute('x', String(x));
    t.setAttribute('y', '10');
    t.setAttribute('text-anchor', 'middle');
    t.textContent = text;
    svg.append(t);
  };
  label(4, '0');
  if (km >= 2) label(4 + w / 2, String(km / 2));
  label(4 + w, `${km} km`);
  ui.scale.replaceChildren(svg);
  ui.scale.setAttribute('aria-label', `Scale bar: ${km} kilometres, as drawn on screen (illustrative)`);
}

function drawLegend() {
  const tints = palette().tints;
  const items = [];
  for (let i = tints.length - 1; i >= 0; i--) {
    const li = document.createElement('li');
    const sw = document.createElement('span');
    sw.className = 'sw';
    sw.style.background = tints[i];
    const label = document.createElement('span');
    label.textContent = i === tints.length - 1 ? `${i * 100} m and above` : `${i * 100}–${(i + 1) * 100} m`;
    li.append(sw, label);
    items.push(li);
  }
  ui.legend.replaceChildren(...items);
}

// ---------------------------------------------------------------------------
// Painting

function toGrid(clientX, clientY) {
  const r = state.renderer.canvas.getBoundingClientRect();
  return {
    x: ((clientX - r.left) / r.width) * state.grid,
    y: ((clientY - r.top) / r.height) * state.grid,
  };
}

function strengthPerStamp() {
  // 0.06 .. 0.6 world units (1.2 .. 12 m) per stamp.
  return Number(ui.strength.value) * 0.06;
}

function mode() {
  return document.querySelector('input[name="mode"]:checked').value;
}

function stamp(x, y, invert) {
  const raise = (mode() === 'raise') !== invert;
  state.engine.brush(x, y, brushRadiusCells(), raise ? strengthPerStamp() : -strengthPerStamp());
  state.baseDirty = true;
  state.dirty = true;
}

function strokeTo(p, invert) {
  const last = state.stroke;
  const spacing = Math.max(0.75, brushRadiusCells() * 0.3);
  if (!last) {
    stamp(p.x, p.y, invert);
    state.stroke = p;
    return;
  }
  const dx = p.x - last.x;
  const dy = p.y - last.y;
  const dist = Math.hypot(dx, dy);
  if (dist < spacing) return;
  const n = Math.min(64, Math.floor(dist / spacing));
  for (let i = 1; i <= n; i++) stamp(last.x + (dx * i) / n, last.y + (dy * i) / n, invert);
  state.stroke = p;
}

function placeRing() {
  const c = state.renderer?.canvas ?? ui.canvas;
  if (!state.cursor) {
    ui.ring.classList.remove('is-on');
    return;
  }
  const w = c.clientWidth;
  const off = c.offsetLeft;
  const top = c.offsetTop;
  const r = (brushRadiusCells() / state.grid) * w;
  ui.ring.style.left = `${off + (state.cursor.x / state.grid) * w}px`;
  ui.ring.style.top = `${top + (state.cursor.y / state.grid) * w}px`;
  ui.ring.style.width = `${2 * r}px`;
  ui.ring.style.height = `${2 * r}px`;
  ui.ring.classList.add('is-on');
  ui.ring.classList.toggle('is-lower', mode() === 'lower');
}

function wirePainting(canvas) {
  canvas.addEventListener('contextmenu', (e) => e.preventDefault());
  canvas.addEventListener('pointerdown', (e) => {
    if (!state.engine) return;
    canvas.setPointerCapture(e.pointerId);
    state.stroke = null;
    state.cursor = toGrid(e.clientX, e.clientY);
    strokeTo(state.cursor, e.altKey || e.button === 2);
    placeRing();
    e.preventDefault();
  });
  canvas.addEventListener('pointermove', (e) => {
    if (!state.engine) return;
    state.cursor = toGrid(e.clientX, e.clientY);
    if (state.stroke && canvas.hasPointerCapture(e.pointerId)) strokeTo(state.cursor, e.altKey || (e.buttons & 2) !== 0);
    placeRing();
  });
  const end = (e) => {
    state.stroke = null;
    if (canvas.hasPointerCapture?.(e.pointerId)) canvas.releasePointerCapture(e.pointerId);
  };
  canvas.addEventListener('pointerup', end);
  canvas.addEventListener('pointercancel', end);
  canvas.addEventListener('pointerleave', () => {
    if (!state.stroke) {
      state.cursor = null;
      placeRing();
    }
  });
  canvas.addEventListener('focus', () => {
    if (!state.cursor) state.cursor = { x: state.grid / 2, y: state.grid / 2 };
    placeRing();
  });
  canvas.addEventListener('blur', () => {
    state.cursor = null;
    placeRing();
  });
  canvas.addEventListener('keydown', (e) => {
    if (!state.engine) return;
    const c = state.cursor ?? { x: state.grid / 2, y: state.grid / 2 };
    const move = (e.shiftKey ? 32 : 8) * (state.grid / GRID_FULL);
    let handled = true;
    switch (e.key) {
      case 'ArrowLeft': c.x -= move; break;
      case 'ArrowRight': c.x += move; break;
      case 'ArrowUp': c.y -= move; break;
      case 'ArrowDown': c.y += move; break;
      case 'Enter':
        stamp(c.x, c.y, e.shiftKey || e.altKey);
        say('');
        break;
      case ' ':
        toggleRun();
        break;
      case '[':
        ui.size.value = String(Number(ui.size.value) - 2);
        ui.size.dispatchEvent(new Event('input'));
        break;
      case ']':
        ui.size.value = String(Number(ui.size.value) + 2);
        ui.size.dispatchEvent(new Event('input'));
        break;
      default:
        handled = false;
    }
    if (!handled) return;
    e.preventDefault();
    c.x = Math.max(0, Math.min(state.grid - 1, c.x));
    c.y = Math.max(0, Math.min(state.grid - 1, c.y));
    state.cursor = c;
    placeRing();
  });
}

// ---------------------------------------------------------------------------
// Time

function setRunning(on) {
  const was = state.running;
  state.running = on && !reducedMotion.matches;
  ui.run.setAttribute('aria-pressed', String(state.running));
  ui.run.textContent = runLabel();
  if (state.running && ui.status.textContent === GOAL_NOTE) say('');
  if (was && !state.running && state.engine) updateReadouts(true);
}

function runLabel() {
  if (reducedMotion.matches) return state.advancing > 0 ? 'Surveying…' : '+1,000 years';
  return state.running ? 'Halt' : 'Run';
}

function toggleRun() {
  if (!state.engine) return;
  if (reducedMotion.matches) {
    // No continuous animation: jump ahead in one go, drawn once at the end.
    if (state.advancing === 0) {
      state.advancing = ADVANCE_STEPS;
      ui.run.disabled = true;
      ui.run.textContent = runLabel();
    }
    return;
  }
  setRunning(!state.running);
}

function measureStep(ms, k, weight) {
  const per = ms / k;
  if (state.stepMs == null) state.readoutsDue = true;
  state.stepMs = state.stepMs == null ? per : state.stepMs + (per - state.stepMs) * weight;
}

/** Catch the sea and the drainage survey up (after painting, or every 16 steps). */
function settle() {
  const t = performance.now();
  const surveyed = state.engine.settle();
  const ms = performance.now() - t;
  if (surveyed) {
    if (state.surveyMs == null) state.readoutsDue = true;
    state.surveyMs = state.surveyMs == null ? ms : state.surveyMs + (ms - state.surveyMs) * 0.2;
    state.dirty = true;
  }
  return ms;
}

function reachedGoal() {
  if (state.pastGoal || state.engine.steps < GOAL_STEPS) return;
  state.pastGoal = true;
  if (state.running) setRunning(false);
  say(GOAL_NOTE);
}

function frame() {
  const e = state.engine;
  if (e && !state.lost) {
    // The survey (about as long as a few steps) comes out of this frame's
    // budget, so a frame that re-surveys runs fewer steps instead of stalling.
    const settleMs = state.advancing > 0 ? 0 : settle();
    if (state.running || state.advancing > 0) {
      const budget = Math.max(0, FRAME_BUDGET_MS - settleMs);
      // Until this grid is timed, run one step and time it.
      let k = state.stepMs == null ? 1 : Math.max(1, Math.min(32, Math.floor(budget / Math.max(state.stepMs, 0.05))));
      if (state.advancing > 0) k = Math.min(state.advancing, k * 2);
      else if (!state.pastGoal) k = Math.max(1, Math.min(k, GOAL_STEPS - e.steps));
      const t = performance.now();
      e.step(k);
      measureStep(performance.now() - t, k, 0.1);
      if (state.advancing > 0) {
        state.advancing -= k;
        say(state.advancing > 0 ? `Surveying… ${Math.round(100 - (100 * state.advancing) / ADVANCE_STEPS)}%` : '');
        if (state.advancing === 0) {
          settle();
          ui.run.disabled = false;
          ui.run.textContent = runLabel();
          state.dirty = true;
          reachedGoal();
        }
      } else {
        state.dirty = true;
        reachedGoal();
      }
    }
    if (state.dirty && state.advancing === 0 && draw()) {
      updateReadouts();
      state.dirty = false;
    }
  }
  requestAnimationFrame(frame);
}

// ---------------------------------------------------------------------------
// Exports

function download(blob, name) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = name;
  document.body.append(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

function exportName(kind) {
  return `silt-survey-${state.seed}-${Math.round(years())}yr-${kind}.png`;
}

function exportHeightmap() {
  const e = state.engine;
  const lo = e.stat(STAT.lowest);
  let hi = e.stat(STAT.highest);
  if (!(hi - lo > 1e-3)) hi = lo + 1;
  const loM = Math.round(lo * METRES_PER_UNIT);
  const hiM = Math.round(hi * METRES_PER_UNIT);
  const text = `silt heightmap, survey ${state.seed}, after ${fmtInt(years())} years (playful scale). ` +
    `16-bit grey: 0 = ${loM} m, 65535 = ${hiM} m. ${state.grid} x ${state.grid} cells of 20 m. Heights and distances are illustrative.`;
  const bytes = e.encodeHeightmapPng(lo, hi, text);
  download(new Blob([bytes], { type: 'image/png' }), exportName('heightmap'));
  ui.exportMsg.textContent = `Saved a ${state.grid} × ${state.grid} 16-bit PNG (${(bytes.length / 1024).toFixed(0)} KiB): black is ${loM} m, white is ${hiM} m.`;
}

function exportMap() {
  draw();
  state.renderer.canvas.toBlob((blob) => {
    if (!blob) {
      ui.exportMsg.textContent = 'This browser could not save the map image.';
      return;
    }
    download(blob, exportName('map'));
    ui.exportMsg.textContent = `Saved the map view (${state.renderer.canvas.width} px square).`;
  }, 'image/png');
}

// ---------------------------------------------------------------------------
// Controls

function parseSeed(raw) {
  const s = raw.trim().replace(/[,\s_]/g, '');
  if (!/^\d+$/.test(s)) return null;
  const n = Number(s);
  return n >= 1 && n <= MAX_SEED ? n : null;
}

function setTheme(theme, remember) {
  state.theme = theme;
  document.documentElement.dataset.theme = theme;
  ui.theme.textContent = theme === 'dark' ? 'Day sheet' : 'Night sheet';
  ui.theme.setAttribute('aria-pressed', String(theme === 'dark'));
  if (remember) {
    try { localStorage.setItem('silt-theme', theme); } catch { /* private mode */ }
  }
  drawLegend();
  state.dirty = true;
}

function initialTheme() {
  let saved = null;
  try { saved = localStorage.getItem('silt-theme'); } catch { /* private mode */ }
  if (saved === 'light' || saved === 'dark') return saved;
  return darkQuery.matches ? 'dark' : 'light';
}

function syncOutputs() {
  ui.sizeOut.textContent = `${Math.round(Number(ui.size.value) * 2 * 20)} m across`;
  ui.strengthOut.textContent = `${(strengthPerStamp() * METRES_PER_UNIT).toFixed(1)} m a dab`;
  const rain = Number(ui.rain.value);
  ui.rainOut.textContent = rain <= 3 ? 'drizzle' : rain <= 6 ? 'steady' : rain <= 9 ? 'heavy' : 'downpour';
}

function wireControls() {
  ui.run.addEventListener('click', toggleRun);
  ui.step.addEventListener('click', () => {
    if (!state.engine) return;
    const t = performance.now();
    state.engine.step(STEP_BUTTON);
    measureStep(performance.now() - t, STEP_BUTTON, 0.3);
    state.dirty = true;
  });
  ui.reset.addEventListener('click', () => {
    setRunning(false);
    startSurvey(state.seed, state.grid);
    say('');
  });
  for (const input of [ui.size, ui.strength]) input.addEventListener('input', () => { syncOutputs(); placeRing(); });
  ui.rain.addEventListener('input', () => {
    syncOutputs();
    if (state.engine) applyRain();
  });
  for (const r of document.querySelectorAll('input[name="mode"]')) r.addEventListener('change', placeRing);
  ui.form.addEventListener('submit', (e) => {
    e.preventDefault();
    const seed = parseSeed(ui.seed.value);
    if (seed === null) {
      ui.seed.setAttribute('aria-invalid', 'true');
      ui.seedMsg.textContent = `Survey numbers are whole numbers from 1 to ${fmtInt(MAX_SEED)}.`;
      return;
    }
    ui.seed.removeAttribute('aria-invalid');
    ui.seedMsg.textContent = '';
    setRunning(false);
    startSurvey(seed, state.grid);
  });
  ui.seed.addEventListener('input', () => {
    if (ui.seed.getAttribute('aria-invalid')) {
      ui.seed.removeAttribute('aria-invalid');
      ui.seedMsg.textContent = '';
    }
  });
  ui.newSurvey.addEventListener('click', () => {
    let seed = state.seed;
    while (seed === state.seed) seed = 1 + Math.floor(Math.random() * MAX_SEED);
    ui.seed.removeAttribute('aria-invalid');
    ui.seedMsg.textContent = '';
    setRunning(false);
    startSurvey(seed, state.grid);
  });
  for (const r of document.querySelectorAll('input[name="grid"]')) {
    r.addEventListener('change', () => {
      if (!r.checked) return;
      state.gridReason = Number(r.value) === GRID_LIGHT ? 'The lighter grid: a quarter of the work per step, with coarser rivers.' : '';
      setRunning(false);
      startSurvey(state.seed, Number(r.value));
    });
  }
  ui.exportHeight.addEventListener('click', () => state.engine && exportHeightmap());
  ui.exportMap.addEventListener('click', () => state.engine && exportMap());
  ui.theme.addEventListener('click', () => setTheme(state.theme === 'dark' ? 'light' : 'dark', true));
  darkQuery.addEventListener('change', () => {
    let saved = null;
    try { saved = localStorage.getItem('silt-theme'); } catch { /* private mode */ }
    if (!saved) setTheme(darkQuery.matches ? 'dark' : 'light', false);
  });
  reducedMotion.addEventListener('change', () => {
    setRunning(false);
    ui.run.textContent = runLabel();
  });
  new ResizeObserver(resizeCanvas).observe(ui.canvas.parentElement);
}

// ---------------------------------------------------------------------------
// Boot

async function boot() {
  setTheme(initialTheme(), false);
  syncOutputs();
  ui.run.textContent = runLabel();
  wireControls();

  const fromUrl = params.get('seed');
  if (fromUrl !== null) {
    const s = parseSeed(fromUrl);
    if (s === null) {
      ui.seedMsg.textContent = `“${fromUrl.slice(0, 20)}” is not a survey number (1 to ${fmtInt(MAX_SEED)}), so survey ${DEFAULT_SEED} is shown.`;
    } else {
      state.seed = s;
    }
  }

  if (typeof WebAssembly !== 'object') {
    say('This browser cannot run WebAssembly, which the simulation needs.');
    return;
  }
  let bytes;
  try {
    const res = await fetch('silt.wasm');
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    bytes = await res.arrayBuffer();
    state.engine = await loadEngine(bytes);
  } catch (err) {
    say(`The simulation could not be loaded (${err.message}). Try reloading the page.`);
    return;
  }
  ui.tbWasm.textContent = `silt.wasm, ${(bytes.byteLength / 1024).toFixed(1)} KiB as loaded`;

  const grid = chooseGrid();
  try {
    state.renderer = createRenderer(ui.canvas, params.get('renderer') === 'canvas2d' ? 'canvas2d' : 'webgl2', {
      onLost() {
        state.lost = true;
        say('The graphics card dropped the map. It will come back when the browser restores it.');
      },
      onRestored() {
        state.lost = false;
        state.dirty = true;
        state.baseDirty = true;
        say('');
      },
    });
  } catch (err) {
    say(err.message);
    return;
  }
  if (state.renderer.canvas !== ui.canvas) ui.canvas = state.renderer.canvas;
  wirePainting(state.renderer.canvas);
  document.documentElement.dataset.renderer = state.renderer.kind;
  startSurvey(state.seed, grid);
  resizeCanvas();
  say('');
  requestAnimationFrame(frame);
  // For the automated browser check only (headless automation or ?test=1).
  if (navigator.webdriver || params.get('test') === '1') window.__silt = { state, engine: state.engine, stepTimeText };
  // The rain starts on its own; with reduced motion nothing moves until asked.
  if (!reducedMotion.matches) setRunning(true);
}

boot();
