// Shared test helpers.
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEngine } from '../web/engine.js';

export const root = join(dirname(fileURLToPath(import.meta.url)), '..');
export const dist = join(root, 'dist');

export function wasmBytes() {
  const file = join(dist, 'silt.wasm');
  if (!existsSync(file)) throw new Error('dist/silt.wasm is missing: run `npm run build` first');
  return readFileSync(file);
}

export async function engine() {
  return loadEngine(wasmBytes());
}

export function fnv1a(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) {
    h ^= bytes[i];
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** Copy of the interior n x n of an (n+2)-strided field. */
export function interior(field, n) {
  const p = n + 2;
  const out = new Float32Array(n * n);
  for (let y = 0; y < n; y++) out.set(field.subarray((y + 1) * p + 1, (y + 1) * p + 1 + n), y * n);
  return out;
}
