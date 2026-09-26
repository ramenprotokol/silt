// The built WebAssembly loads, runs and exports as the page expects.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';
import { statSync } from 'node:fs';
import { join } from 'node:path';
import { PARAM, STAT } from '../web/engine.js';
import { dist, engine, fnv1a, interior } from './helpers.mjs';

test('the wasm loads and one step changes the heightmap', async () => {
  const e = await engine();
  e.init(512, 1);
  assert.equal(e.size, 512);
  assert.equal(e.stride, 514);
  const before = interior(e.fields().height, 512);
  e.step(1);
  const after = interior(e.fields().height, 512);
  let changed = 0;
  for (let i = 0; i < before.length; i++) if (before[i] !== after[i]) changed++;
  assert.ok(changed > 1000, `only ${changed} cells changed in one step`);
  assert.equal(e.steps, 1);
});

test('the kernel is small', () => {
  const size = statSync(join(dist, 'silt.wasm')).size;
  assert.ok(size < 48 * 1024, `silt.wasm is ${size} bytes`);
});

test('the same seed gives the same survey, bit for bit', async () => {
  const run = async (seed) => {
    const e = await engine();
    e.init(128, seed);
    e.step(150);
    return fnv1a(new Uint8Array(interior(e.fields().height, 128).buffer));
  };
  assert.equal(await run(42), await run(42));
  assert.notEqual(await run(42), await run(43));
});

test('the water, material and sediment books balance after many steps', async () => {
  const e = await engine();
  e.init(128, 9);
  const S = (k) => e.stat(STAT[k]);
  const ledger = () => S('rain') - S('evaporation') + S('seaExchange') + S('brushWater') - S('edgeWater');
  const mass = () => S('terrain') + S('sediment') - S('brushTerrain') + S('edgeSediment');
  const water0 = S('water') - ledger();
  const mass0 = mass();
  const sed0 = S('sediment');
  e.step(300);
  e.brush(64, 40, 10, 3);
  e.step(300);
  const scale = Math.abs(water0) + S('rain') + S('evaporation') + Math.abs(S('seaExchange')) + S('edgeWater');
  assert.ok(Math.abs(S('water') - (water0 + ledger())) < 1e-5 * scale, 'water books');
  assert.ok(Math.abs(mass() - mass0) < 1e-5 * Math.abs(mass0), 'material books');
  // The suspended load, judged against the material that moved (not the whole map).
  assert.ok(Math.abs(S('sediment') - (sed0 + S('pickup') - S('edgeSediment'))) < 1e-6 * S('exchange'), 'sediment books');
  assert.ok(S('brushTerrain') > 0);
  assert.ok(S('edgeWater') > 0, 'water ran off the open land edges');
});

test('the drainage survey lists river segments after settle()', async () => {
  const e = await engine();
  e.init(256, 1);
  const v0 = e.surveyVersion;
  e.step(400);
  assert.equal(e.settle(), true);
  assert.ok(e.surveyVersion > v0);
  assert.equal(e.settle(), false, 'nothing was due');
  const segs = e.rivers();
  assert.ok(segs.length >= 5 * 50, `${segs.length / 5} segments`);
  for (let k = 0; k < segs.length; k += 5) {
    for (let j = 0; j < 4; j++) assert.ok(segs[k + j] >= -1 && segs[k + j] <= 257);
    assert.ok(segs[k + 4] >= 1, 'every river drains at least the threshold area');
  }
  // Painting marks the survey stale; settle() re-runs it once.
  e.brush(100, 100, 10, 2);
  e.brush(110, 100, 10, 2);
  assert.equal(e.settle(), true);
});

test('bad input is refused with an error, not a crash', async () => {
  const e = await engine();
  assert.throws(() => e.init(510, 1), /init failed/); // not a multiple of 4
  assert.throws(() => e.init(1024, 1), /init failed/);
  assert.throws(() => e.step(1), /step failed/); // no survey yet
  e.init(64, 1);
  assert.throws(() => e.brush(Number.NaN, 3, 4, 1), /brush failed/);
  assert.throws(() => e.brush(3, 3, 0, 1), /brush failed/);
  assert.throws(() => e.setParam(PARAM.rain, 5), /parameter/);
  assert.throws(() => e.setParam(99, 1), /parameter/);
  assert.equal(e.setParam(PARAM.rain, 0.008), 0);
  // A huge brush is clamped, not a hang or an out-of-bounds write.
  e.brush(32, 32, 1e9, 1e9);
  assert.ok(e.stat(STAT.highest) <= 80);
});

test('heightmap export is a valid 16-bit greyscale PNG of the terrain', async () => {
  const e = await engine();
  e.init(64, 5);
  e.step(20);
  const lo = e.stat(STAT.lowest);
  const hi = e.stat(STAT.highest);
  const png = e.encodeHeightmapPng(lo, hi, 'silt test export');
  assert.deepEqual([...png.subarray(0, 8)], [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const dv = new DataView(png.buffer, png.byteOffset, png.byteLength);
  let pos = 8;
  const chunks = {};
  while (pos < png.length) {
    const len = dv.getUint32(pos);
    const type = String.fromCharCode(...png.subarray(pos + 4, pos + 8));
    chunks[type] = png.subarray(pos + 8, pos + 8 + len);
    pos += 12 + len;
  }
  assert.equal(pos, png.length);
  const ihdr = new DataView(chunks.IHDR.buffer, chunks.IHDR.byteOffset);
  assert.equal(ihdr.getUint32(0), 64);
  assert.equal(ihdr.getUint32(4), 64);
  assert.equal(chunks.IHDR[8], 16); // bit depth
  assert.equal(chunks.IHDR[9], 0); // greyscale
  assert.match(new TextDecoder().decode(chunks.tEXt), /^Description\0silt test export$/);
  // tEXt is Latin-1 by the PNG spec: "×" is one byte (0xD7); what Latin-1
  // cannot hold becomes "?".
  const accented = e.encodeHeightmapPng(lo, hi, '512 × 512 — ok');
  const text = pngChunk(accented, 'tEXt');
  assert.deepEqual([...text.subarray(12)], [...Buffer.from('512 \xd7 512 ? ok', 'latin1')]);
  const raw = inflateSync(chunks.IDAT); // Node's zlib accepts the stored blocks
  assert.equal(raw.length, 64 * (1 + 2 * 64));
  const heights = interior(e.fields().height, 64);
  for (const [x, y] of [[0, 0], [63, 0], [31, 40], [63, 63]]) {
    const off = y * (1 + 128) + 1 + 2 * x;
    const v = (raw[off] << 8) | raw[off + 1];
    const expected = Math.round(((heights[y * 64 + x] - lo) / (hi - lo)) * 65535);
    assert.ok(Math.abs(v - expected) <= 1, `pixel ${x},${y}: ${v} vs ${expected}`);
  }
  assert.throws(() => e.encodeHeightmapPng(3, 3), /PNG export/); // empty range
});

function pngChunk(png, want) {
  const dv = new DataView(png.buffer, png.byteOffset, png.byteLength);
  for (let pos = 8; pos < png.length;) {
    const len = dv.getUint32(pos);
    if (String.fromCharCode(...png.subarray(pos + 4, pos + 8)) === want) return png.subarray(pos + 8, pos + 8 + len);
    pos += 12 + len;
  }
  return null;
}

test('grid 256 works too (the slow-device fallback)', async () => {
  const e = await engine();
  e.init(256, 1);
  e.step(10);
  assert.equal(e.size, 256);
  assert.ok(e.cellSize === 2);
  const f = e.fields();
  assert.ok(Number.isFinite(f.height[257 + 100]));
});
