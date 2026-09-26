#!/usr/bin/env node
// Builds dist/ from a clean clone: compiles the Zig kernel to WebAssembly,
// then copies the static page next to it. Needs Zig 0.16 on PATH.
import { execFileSync } from 'node:child_process';
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');
const optimize = process.env.WASM_OPTIMIZE ?? 'ReleaseSmall';

try {
  execFileSync('zig', ['build', `-Dwasm-optimize=${optimize}`], { cwd: root, stdio: 'inherit' });
} catch (err) {
  console.error(err.code === 'ENOENT' ? 'zig was not found on PATH (Zig 0.16 is required).' : 'zig build failed.');
  process.exit(1);
}

const wasm = join(root, 'zig-out', 'bin', 'silt.wasm');
if (!existsSync(wasm)) {
  console.error('zig-out/bin/silt.wasm is missing after the build.');
  process.exit(1);
}

rmSync(dist, { recursive: true, force: true });
mkdirSync(dist, { recursive: true });
for (const name of readdirSync(join(root, 'web'))) cpSync(join(root, 'web', name), join(dist, name), { recursive: true });
cpSync(wasm, join(dist, 'silt.wasm'));

const size = statSync(join(dist, 'silt.wasm')).size;
const files = readdirSync(dist);
console.log(`dist/ ready (${files.length} files). silt.wasm is ${size} bytes (${(size / 1024).toFixed(1)} KiB, ${optimize}).`);
