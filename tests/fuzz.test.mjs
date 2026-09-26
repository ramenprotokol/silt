// Every parameter the kernel exports, across its whole accepted range, with
// painting: no NaN, no blow-up. Deterministic (a fixed PRNG).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { PARAM, PARAM_RANGE, STAT } from '../web/engine.js';
import { engine, interior } from './helpers.mjs';

function mulberry32(a) {
  return () => {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

test('fuzz: parameters across their exported ranges never produce NaN or blow up', async () => {
  const rnd = mulberry32(20260926);
  const e = await engine();
  assert.deepEqual(Object.keys(PARAM).sort(), Object.keys(PARAM_RANGE).sort());
  const n = 48;
  for (let round = 0; round < 40; round++) {
    e.init(n, round + 1);
    const chosen = {};
    for (const [name, [lo, hi]] of Object.entries(PARAM_RANGE)) {
      const pick = rnd();
      const v = pick < 0.25 ? lo : pick < 0.5 ? hi : lo + (hi - lo) * rnd() * rnd();
      chosen[name] = v;
      assert.equal(e.setParam(PARAM[name], Math.fround(v)), 0, `${name} = ${v} refused`);
    }
    for (let k = 0; k < 4; k++) {
      e.step(40);
      e.brush(rnd() * n, rnd() * n, 1 + rnd() * 60, rnd() * 8 - 4);
      e.settle();
    }
    const f = e.fields();
    for (const [label, field, bound] of [['height', f.height, 1000], ['water', f.water, 1e4], ['sediment', f.sediment ?? f.water, 1e4]]) {
      for (const v of interior(field, n)) assert.ok(Number.isFinite(v) && Math.abs(v) < bound, `${label} ${v} with ${JSON.stringify(chosen)}`);
    }
    for (const v of e.rivers()) assert.ok(Number.isFinite(v));
    for (const k of Object.values(STAT)) assert.ok(Number.isFinite(e.stat(k)), `stat ${k}`);
  }
  // The documented clamps: the highest evaporation and time step no longer
  // drive the water negative (Ke x dt is capped at 0.9 of a cell's water)...
  e.init(n, 3);
  e.setParam(PARAM.evaporation, 5);
  e.setParam(PARAM.dt, 0.5);
  e.step(200);
  assert.ok(interior(e.fields().water, n).every((d) => d >= 0 && Number.isFinite(d)));
  // ...and the strongest thermal weathering with the strongest creep stays
  // smooth rather than growing a checkerboard (creep is capped at 0.24 - thermal).
  e.init(n, 3);
  e.setParam(PARAM.thermal, 0.2);
  e.setParam(PARAM.creep, 2);
  e.setParam(PARAM.dt, 0.5);
  e.setParam(PARAM.talus, 0.01);
  e.step(600);
  const h = interior(e.fields().height, n);
  let lap = 0;
  for (let y = 1; y < n - 1; y++) for (let x = 1; x < n - 1; x++) {
    const i = y * n + x;
    lap += Math.abs(4 * h[i] - h[i - 1] - h[i + 1] - h[i - n] - h[i + n]);
  }
  assert.ok(lap / (n * n) < 1, `mean |laplacian| ${lap / (n * n)}`);
});
