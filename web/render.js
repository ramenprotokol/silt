// Survey-sheet renderer. Reads the kernel's height, "wet" and base fields
// straight out of WebAssembly memory and draws, per screen pixel:
//   hypsometric layer tints (olive -> ochre -> chalk), faint relief shading,
//   hairline contours with heavier index contours, flat ultramarine water
//   with a crisp coastline, and a stipple on alluvium (ground raised by
//   deposition since the survey began).
// WebGL2 when available; otherwise a Canvas 2D fallback at grid resolution.

import { METRES_PER_UNIT } from './engine.js';

/** Contour interval and index interval, in metres. */
export const CONTOUR_M = 20;
export const INDEX_M = 100;
/** Deposit thickness (metres) above which ground is stippled as alluvium. */
export const ALLUVIUM_M = 5;

export const PALETTES = {
  light: {
    // 0-100 m, 100-200 m, ... 800 m and above.
    tints: ['#a0a56a', '#b3ae6f', '#c3b172', '#cfae6b', '#d7b877', '#dec48e', '#e6d2aa', '#ece0c5', '#f3ecdc'],
    water: '#2b479f',
    coast: '#1b2c6e',
    contour: '#6b4222',
    stipple: '#5e3f25',
    lineAlpha: 0.5,
    indexAlpha: 0.85,
    shade: 0.16,
    grain: 0.018,
  },
  dark: {
    tints: ['#2c301e', '#353621', '#3f3b24', '#4a4027', '#54492f', '#5e533d', '#685e4d', '#736b5f', '#7f796f'],
    water: '#2f4aad',
    coast: '#a9b8f0',
    contour: '#efe2c4',
    stipple: '#e2cb9f',
    lineAlpha: 0.4,
    indexAlpha: 0.78,
    shade: 0.22,
    grain: 0.022,
  },
};

const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);

// ---------------------------------------------------------------------------
// WebGL2

const VERT = `#version 300 es
in vec2 aPos;
out vec2 vUv;
void main() {
  vUv = vec2(aPos.x * 0.5 + 0.5, 0.5 - aPos.y * 0.5); // row 0 of the grid is north
  gl_Position = vec4(aPos, 0.0, 1.0);
}`;

const FRAG = `#version 300 es
precision highp float;
precision highp sampler2D;
uniform sampler2D uH;
uniform sampler2D uW;
uniform sampler2D uB;
uniform sampler2D uS;
uniform int uN;
uniform float uLineScale;
uniform float uSea;
uniform float uUnitsPerPx;
uniform float uDpr;
uniform float uContour;   // contour interval, world units
uniform float uAlluvium;  // world units
uniform vec3 uTint[9];
uniform vec3 uWater;
uniform vec3 uCoast;
uniform vec3 uLine;
uniform vec3 uStip;
uniform float uLineAlpha;
uniform float uIndexAlpha;
uniform float uShade;
uniform float uGrain;
in vec2 vUv;
out vec4 outColor;

float at(sampler2D t, ivec2 p) {
  return texelFetch(t, clamp(p, ivec2(0), ivec2(uN - 1)), 0).r;
}

float bilinear(sampler2D t, vec2 g) {
  vec2 q = g - 0.5;
  vec2 fl = floor(q);
  ivec2 i = ivec2(fl);
  vec2 f = q - fl;
  float a = at(t, i), b = at(t, i + ivec2(1, 0));
  float c = at(t, i + ivec2(0, 1)), d = at(t, i + ivec2(1, 1));
  return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Cubic B-spline: smooth (C2) terrain, so contours are clean curves rather
// than the kinked polylines bilinear interpolation gives.
vec4 bspline(float t) {
  float t2 = t * t, t3 = t2 * t;
  return vec4((1.0 - t) * (1.0 - t) * (1.0 - t), 3.0 * t3 - 6.0 * t2 + 4.0,
              -3.0 * t3 + 3.0 * t2 + 3.0 * t + 1.0, t3) / 6.0;
}

float smoothHeight(vec2 g) {
  vec2 q = g - 0.5;
  vec2 fl = floor(q);
  ivec2 i = ivec2(fl);
  vec4 wx = bspline(q.x - fl.x);
  vec4 wy = bspline(q.y - fl.y);
  float h = 0.0;
  for (int y = 0; y < 4; y++) {
    float row = 0.0;
    for (int x = 0; x < 4; x++) row += wx[x] * at(uH, i + ivec2(x - 1, y - 1));
    h += wy[y] * row;
  }
  return h;
}

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

// Coverage of a line of the given width (device px) at the integer values of v.
float isoLine(float v, float widthPx) {
  float fw = max(fwidth(v), 1e-6);
  float d = abs(fract(v + 0.5) - 0.5) / fw;
  return 1.0 - smoothstep(widthPx * 0.5 - 0.5, widthPx * 0.5 + 0.5, d);
}

void main() {
  vec2 g = vUv * float(uN);
  float h = smoothHeight(g);
  float m = h * ${METRES_PER_UNIT.toFixed(1)};

  // Layer tints in 100 m bands, softened slightly towards the next band.
  float bandF = clamp(m / 100.0, 0.0, 8.999);
  int band = int(floor(bandF));
  vec3 lo = uTint[band];
  vec3 hi = uTint[min(band + 1, 8)];
  vec3 col = mix(lo, hi, 0.28 * smoothstep(0.0, 1.0, fract(bandF)));
  if (m < 0.0) col = uTint[0] * 0.93;

  // Relief shading from the north-west, kept faint so the tints read.
  vec2 grad = vec2(dFdx(h), dFdy(h)) / (uUnitsPerPx * uDpr);
  vec3 n = normalize(vec3(-grad * 2.2, 1.0));
  float lambert = dot(n, normalize(vec3(-0.6, 0.6, 0.55)));
  col *= 1.0 + uShade * (lambert - 0.72);

  // Alluvium: dots where deposition has raised the ground.
  float dep = bilinear(uH, g) - bilinear(uB, g);
  if (dep > uAlluvium && h > uSea) {
    vec2 cell = floor(gl_FragCoord.xy / (4.5 * uDpr));
    vec2 centre = (cell + 0.25 + 0.5 * vec2(hash(cell), hash(cell + 17.0))) * 4.5 * uDpr;
    float r = 0.62 * uDpr;
    float keep = step(hash(cell + 3.1), clamp(dep / (uAlluvium * 4.0), 0.35, 0.9));
    float dot_ = 1.0 - smoothstep(r - 0.5, r + 0.5, length(gl_FragCoord.xy - centre));
    col = mix(col, uStip, 0.8 * dot_ * keep);
  }

  // Contours: hairlines every interval, heavier index lines every fifth.
  // Where they would crowd closer than ~2 px they fade out.
  float v = h / uContour;
  float crowd = 1.0 - smoothstep(0.22, 0.5, fwidth(v) / uDpr);
  float line = isoLine(v, 0.75 * uDpr * uLineScale) * uLineAlpha;
  float idx = isoLine(v / 5.0, 1.45 * uDpr * uLineScale) * uIndexAlpha;
  float ink = max(line * crowd, idx * mix(0.55, 1.0, crowd));
  if (h > uSea) col = mix(col, uLine, ink);

  // Water: one flat ultramarine. Rivers and lakes come from the kernel's
  // "wet" field; the sea is the connected sea mask cut exactly at the
  // sea-level contour of the smooth terrain, so the coastline is clean.
  float w = bilinear(uW, g);
  float aw = max(fwidth(w), 1e-4);
  float river = smoothstep(1.0 - aw * 0.7, 1.0 + aw * 0.7, w);
  float riverEdge = 1.0 - smoothstep(0.3 * uDpr, 0.3 * uDpr + 1.0, abs(w - 1.0) / aw);
  float near = bilinear(uS, g);
  float fh = max(fwidth(h), 1e-5);
  float sea = near > 0.02 ? 1.0 - smoothstep(-0.7 * fh, 0.7 * fh, h - uSea) : 0.0;
  float seaEdge = near > 0.02 ? 1.0 - smoothstep(0.35 * uDpr * uLineScale, 0.35 * uDpr * uLineScale + 1.0, abs(h - uSea) / fh) : 0.0;
  col = mix(col, uWater, max(river, sea));
  float edge = max(riverEdge * (1.0 - sea), seaEdge * (1.0 - river));
  col = mix(col, uCoast, edge * 0.85);

  // Paper grain.
  col += (hash(gl_FragCoord.xy) - 0.5) * uGrain;
  outColor = vec4(col, 1.0);
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) {
    const log = gl.getShaderInfoLog(s);
    gl.deleteShader(s);
    throw new Error(`shader: ${log}`);
  }
  return s;
}

function createGL(canvas) {
  const gl = canvas.getContext('webgl2', { antialias: false, alpha: false, preserveDrawingBuffer: true });
  if (!gl) return null;
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, VERT));
  gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, FRAG));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS)) throw new Error(`link: ${gl.getProgramInfoLog(prog)}`);
  gl.useProgram(prog);

  const buf = gl.createBuffer();
  gl.bindBuffer(gl.ARRAY_BUFFER, buf);
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
  const loc = gl.getAttribLocation(prog, 'aPos');
  gl.enableVertexAttribArray(loc);
  gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);

  const u = {};
  for (const name of ['uH', 'uW', 'uB', 'uS', 'uLineScale', 'uN', 'uSea', 'uUnitsPerPx', 'uDpr', 'uContour', 'uAlluvium', 'uTint',
    'uWater', 'uCoast', 'uLine', 'uStip', 'uLineAlpha', 'uIndexAlpha', 'uShade', 'uGrain']) {
    u[name] = gl.getUniformLocation(prog, name);
  }
  const textures = [0, 1, 2, 3].map((unit) => {
    const t = gl.createTexture();
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, t);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return t;
  });
  gl.uniform1i(u.uH, 0);
  gl.uniform1i(u.uW, 1);
  gl.uniform1i(u.uB, 2);
  gl.uniform1i(u.uS, 3);

  let texSize = 0;
  // Upload the interior n x n of an (n+2)-strided field, skipping the ghost ring.
  function upload(unit, field, n, stride) {
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, textures[unit]);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, stride);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, 1);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, 1);
    if (texSize !== n) gl.texImage2D(gl.TEXTURE_2D, 0, gl.R32F, n, n, 0, gl.RED, gl.FLOAT, field);
    else gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, n, n, gl.RED, gl.FLOAT, field);
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, 0);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, 0);
  }

  return {
    kind: 'webgl2',
    draw(engine, palette, { baseDirty }) {
      const n = engine.size;
      const f = engine.fields();
      if (texSize !== n) baseDirty = true;
      upload(0, f.height, n, engine.stride);
      upload(1, f.wet, n, engine.stride);
      if (baseDirty) upload(2, f.base, n, engine.stride);
      upload(3, f.sea, n, engine.stride);
      texSize = n;
      const dpr = canvas.width / Math.max(1, canvas.clientWidth || canvas.width);
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.uniform1i(u.uN, n);
      gl.uniform1f(u.uSea, engine.seaLevel);
      gl.uniform1f(u.uUnitsPerPx, (engine.cellSize * n) / (canvas.width / dpr));
      gl.uniform1f(u.uDpr, dpr);
      // Thinner linework on small maps (phones), so contours don't clot.
      gl.uniform1f(u.uLineScale, Math.max(0.6, Math.min(1, (canvas.clientWidth || 700) / 700)));
      gl.uniform1f(u.uContour, CONTOUR_M / METRES_PER_UNIT);
      gl.uniform1f(u.uAlluvium, ALLUVIUM_M / METRES_PER_UNIT);
      gl.uniform3fv(u.uTint, palette.tints.flatMap(hex));
      gl.uniform3fv(u.uWater, hex(palette.water));
      gl.uniform3fv(u.uCoast, hex(palette.coast));
      gl.uniform3fv(u.uLine, hex(palette.contour));
      gl.uniform3fv(u.uStip, hex(palette.stipple));
      gl.uniform1f(u.uLineAlpha, palette.lineAlpha);
      gl.uniform1f(u.uIndexAlpha, palette.indexAlpha);
      gl.uniform1f(u.uShade, palette.shade);
      gl.uniform1f(u.uGrain, palette.grain);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
    },
    lost: () => gl.isContextLost(),
  };
}

// ---------------------------------------------------------------------------
// Canvas 2D fallback: one pixel per grid cell, scaled up by the browser.

function createCanvas2D(canvas) {
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;
  let img = null;
  let scratch = null;
  return {
    kind: 'canvas2d',
    draw(engine, palette) {
      const n = engine.size;
      const p = engine.stride;
      const { height: H, wet: W, base: B, sea: SEA } = engine.fields();
      if (!img || img.width !== n) {
        img = new ImageData(n, n);
        scratch = new OffscreenCanvasOrCanvas(n);
      }
      const tints = palette.tints.map(hex);
      const water = hex(palette.water);
      const line = hex(palette.contour);
      const stip = hex(palette.stipple);
      const cu = CONTOUR_M / METRES_PER_UNIT;
      const d = img.data;
      for (let y = 0; y < n; y++) {
        for (let x = 0; x < n; x++) {
          const i = (y + 1) * p + x + 1;
          const h = H[i];
          let c;
          if (W[i] > 1 || (SEA[i] > 0.5 && h < engine.seaLevel)) c = water;
          else {
            const m = h * METRES_PER_UNIT;
            c = tints[Math.max(0, Math.min(8, Math.floor(m / 100)))];
            const k = Math.floor(h / cu);
            const kr = Math.floor(H[i + 1] / cu);
            const kd = Math.floor(H[i + p] / cu);
            if (h > 0 && (k !== kr || k !== kd)) {
              const isIndex = Math.max(k, kr, kd) % 5 === 0;
              c = mix(c, line, isIndex ? palette.indexAlpha : palette.lineAlpha * 0.8);
            } else if (h - B[i] > ALLUVIUM_M / METRES_PER_UNIT && (x + 2 * y) % 5 === 0) {
              c = mix(c, stip, 0.7);
            }
          }
          const o = (y * n + x) * 4;
          d[o] = c[0] * 255;
          d[o + 1] = c[1] * 255;
          d[o + 2] = c[2] * 255;
          d[o + 3] = 255;
        }
      }
      scratch.ctx.putImageData(img, 0, 0);
      ctx.imageSmoothingEnabled = true;
      ctx.drawImage(scratch.canvas, 0, 0, canvas.width, canvas.height);
    },
    lost: () => false,
  };
}

function mix(a, b, t) {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
}

function OffscreenCanvasOrCanvas(n) {
  const c = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(n, n) : Object.assign(document.createElement('canvas'), { width: n, height: n });
  return { canvas: c, ctx: c.getContext('2d') };
}

/**
 * Pick the best renderer. `prefer` may be 'webgl2' or 'canvas2d'. A canvas
 * keeps the first context type it hands out, so if WebGL2 half-starts and
 * then fails, the canvas is swapped for a fresh one (see `renderer.canvas`).
 */
export function createRenderer(canvas, prefer = 'webgl2') {
  if (prefer !== 'canvas2d') {
    try {
      const gl = createGL(canvas);
      if (gl) return Object.assign(gl, { canvas });
    } catch (err) {
      console.warn('WebGL2 unavailable, using Canvas 2D:', err.message);
      const fresh = canvas.cloneNode(false);
      canvas.replaceWith(fresh);
      canvas = fresh;
    }
  }
  const c2d = createCanvas2D(canvas);
  if (!c2d) throw new Error('This browser cannot draw to a canvas.');
  return Object.assign(c2d, { canvas });
}
