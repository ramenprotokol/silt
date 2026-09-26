// Acceptance: after the standard run (8,000 steps, the page's 10,000
// "years"), the coast has built out where the rivers meet it. Deterministic:
// same seed, same wasm, same answer.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { wasmBytes } from './helpers.mjs';
import { coastCorrelation } from './coast.mjs';

for (const n of [512, 256]) {
  test(`deltas: on survey 1 at ${n}², coast advance follows river discharge (r > 0.5)`, async (t) => {
    const m = await coastCorrelation(wasmBytes(), { seed: 1, n, steps: 8000 });
    t.diagnostic(`r = ${m.r.toFixed(3)}; mean advance at the wettest 1/16 of columns ${m.advanceAtMouths.toFixed(1)} cells vs ${m.advanceOverall.toFixed(1)} overall (max ${m.maxAdvance})`);
    assert.ok(m.r > 0.5, `correlation ${m.r.toFixed(3)}`);
    // The mouths build out more than the coast as a whole.
    assert.ok(m.advanceAtMouths > 2 * Math.max(0.5, m.advanceOverall));
  });
}
