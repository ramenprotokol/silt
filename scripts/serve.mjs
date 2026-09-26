#!/usr/bin/env node
// Tiny static server for dist/ (local preview and the browser smoke test).
// Serves .wasm as application/wasm so streaming compilation works.
import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { dirname, extname, join, normalize, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.json': 'application/json',
  '.txt': 'text/plain; charset=utf-8',
};

// Apply the global "/*" block of dist/_headers (Cloudflare Pages format) so
// local runs see the same Content-Security-Policy as production.
async function globalHeaders(dir) {
  const text = await readFile(join(dir, '_headers'), 'utf8').catch(() => '');
  const out = {};
  let inGlobal = false;
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    if (!/^\s/.test(line)) {
      inGlobal = line.trim() === '/*';
      continue;
    }
    const m = /^\s+([^:]+):\s*(.*)$/.exec(line);
    if (inGlobal && m) out[m[1].toLowerCase()] = m[2];
  }
  return out;
}

export async function serve(dir, port = 0) {
  const extra = await globalHeaders(dir);
  const server = createServer(async (req, res) => {
    try {
      const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);
      let file = normalize(join(dir, path));
      if (!file.startsWith(normalize(dir + sep)) && file !== normalize(dir)) {
        res.writeHead(403).end();
        return;
      }
      if ((await stat(file).catch(() => null))?.isDirectory()) file = join(file, 'index.html');
      const body = await readFile(file);
      res.writeHead(200, { ...extra, 'content-type': TYPES[extname(file)] ?? 'application/octet-stream' });
      res.end(body);
    } catch {
      res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
    }
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve(server)));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
  const port = Number(process.env.PORT ?? 0);
  const server = await serve(dir, port);
  console.log(`serving dist/ at http://127.0.0.1:${server.address().port}`);
}
