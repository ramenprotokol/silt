// The delta measure used by the acceptance test (and scripts/bench.mjs):
// does the coast build out where the rivers bring water to it?
//
// For each map column: the coast is the first sea row from the north. Run
// the survey, then compare how far the coast moved (coast advance, cells)
// with the discharge that reached the original coastline (the kernel's
// smoothed pipe discharge, summed over the 8 rows above it). Both series
// are smoothed over N/64 columns, then correlated (Pearson r).
import { loadEngine } from '../web/engine.js';

export async function coastCorrelation(wasm, { seed = 1, n = 512, steps = 8000 } = {}) {
  const e = await loadEngine(wasm);
  e.init(n, seed);
  const p = n + 2;
  const coast = () => {
    const sea = e.fields().sea;
    const rows = [];
    for (let c = 0; c < n; c++) {
      let r = 0;
      while (r < n && !(sea[(r + 1) * p + c + 1] > 0.5)) r++;
      rows.push(r);
    }
    return rows;
  };
  const before = coast();
  e.step(steps);
  e.settle();
  const after = coast();
  const flow = e.fields().flow;
  const q = [];
  const advance = [];
  for (let c = 0; c < n; c++) {
    let s = 0;
    for (let r = Math.max(0, before[c] - 8); r < before[c]; r++) s += flow[(r + 1) * p + c + 1];
    q.push(s);
    advance.push(after[c] - before[c]);
  }
  const smooth = (a, w) => a.map((_, i) => {
    let s = 0;
    let k = 0;
    for (let j = i - w; j <= i + w; j++) if (j >= 0 && j < a.length) { s += a[j]; k++; }
    return s / k;
  });
  const Q = smooth(q, n / 64);
  const A = smooth(advance, n / 64);
  const mean = (a) => a.reduce((s, v) => s + v, 0) / a.length;
  const mq = mean(Q);
  const ma = mean(A);
  let sxy = 0;
  let sxx = 0;
  let syy = 0;
  for (let i = 0; i < n; i++) {
    sxy += (Q[i] - mq) * (A[i] - ma);
    sxx += (Q[i] - mq) ** 2;
    syy += (A[i] - ma) ** 2;
  }
  // The columns carrying the most water, against the rest.
  const top = [...Q.keys()].sort((a, b) => Q[b] - Q[a]).slice(0, n / 16);
  return {
    r: sxy / Math.sqrt(sxx * syy),
    advanceAtMouths: mean(top.map((i) => advance[i])),
    advanceOverall: mean(advance),
    maxAdvance: Math.max(...advance),
  };
}
