#!/usr/bin/env node
// Times the built kernel in Node: a simulation step, and the drainage survey
// (pit filling, D8 routing, rivers, coast distance) that the page runs every
// 16 steps. Run `npm run build` first; `WASM_OPTIMIZE=ReleaseFast npm run
// build` to time the faster build. Prints the median of repeated runs.
import { readFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEngine } from '../web/engine.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const file = join(root, 'dist', 'silt.wasm');
const bytes = readFileSync(file);
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

console.log(`silt.wasm: ${statSync(file).size} bytes; Node ${process.versions.node}`);
for (const n of [512, 256]) {
  const e = await loadEngine(bytes);
  e.init(n, 1);
  e.step(200); // warm up the JIT and let the water spread
  const steps = [];
  for (let k = 0; k < 15; k++) {
    const t = performance.now();
    e.step(20);
    steps.push((performance.now() - t) / 20);
  }
  const surveys = [];
  for (let k = 0; k < 15; k++) {
    e.brush(8, 8, 1, 0); // a zero-strength dab: marks the survey stale, changes nothing
    const t = performance.now();
    e.settle();
    surveys.push(performance.now() - t);
  }
  console.log(`${n}² grid: ${median(steps).toFixed(2)} ms per step; ${median(surveys).toFixed(1)} ms per drainage survey (every 16 steps)`);
}
