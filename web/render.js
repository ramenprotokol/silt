// Survey-sheet renderer. Reads the kernel's fields and river segments
// straight out of WebAssembly memory and draws, per screen pixel:
//   hypsometric layer tints (olive -> ochre -> chalk), faint relief shading,
//   hairline contours with heavier index contours, a pale sea with three
//   waterlines hugging the coast, lakes, and a stipple on alluvium near the
//   coast (ground raised by deposition since the survey began).
// Then the rivers, as anti-aliased lines along the kernel's drainage network,
// wider where they drain more ground.
// WebGL2 when available; otherwise a Canvas 2D fallback at grid resolution.

import { METRES_PER_UNIT, SEGMENT_FLOATS } from './engine.js';

/** Contour interval and index interval, in metres. */
export const CONTOUR_M = 20;
export const INDEX_M = 100;
/** Deposit thickness (metres) above which ground is stippled as alluvium... */
export const ALLUVIUM_M = 5;
/** ...if it is within this distance of the coast (metres). */
export const ALLUVIUM_REACH_M = 900;
/** Waterlines: distance from the coast (CSS px), width (CSS px) and strength. */
const WATERLINES = [[2.6, 0.8, 0.85], [5.8, 0.7, 0.6], [10.2, 0.6, 0.38]];

/** River line width in CSS px for a segment draining `ratio` times the threshold. */
export function riverWidth(ratio) {
  return Math.min(3.5, Math.max(0.8, 0.6 + 0.35 * Math.log2(Math.max(ratio, 1))));
}

export const PALETTES = {
  light: {
    // 0-100 m, 100-200 m, ... 800 m and above.
    tints: ['#a0a56a', '#b3ae6f', '#c3b172', '#cfae6b', '#d7b877', '#dec48e', '#e6d2aa', '#ece0c5', '#f3ecdc'],
    paper: '#f4eedf',
    river: '#2b479f',
    // Sea and lakes: ultramarine thinned with paper; shoals paler still.
    seaMix: 0.45,
    shoal: '#c0c2ce',
    // New land built out into the sea.
    silt: '#cdd0a0',
    waterline: '#2b479f',
    coast: '#1b2c6e',
    contour: '#6b4222',
    stipple: '#5e3f25',
    lineAlpha: 0.5,
    indexAlpha: 0.85,
    shade: 0.16,
    grain: 0.018,
  },
  dark: {
    // A wider lightness ramp than the day sheet's, so the low bands part.
    tints: ['#27301d', '#353d22', '#454829', '#565231', '#665c3b', '#756849', '#83765b', '#91866f', '#a09887'],
    paper: '#1a1813',
    river: '#7b95ea',
    seaMix: 0.4,
    shoal: '#353c55',
    silt: '#5f6444',
    waterline: '#6f88d8',
    coast: '#9fb0ea',
    contour: '#efe2c4',
    stipple: '#e8d3a8',
    lineAlpha: 0.4,
    indexAlpha: 0.78,
    shade: 0.22,
    grain: 0.022,
  },
};

const hex = (h) => [1, 3, 5].map((i) => parseInt(h.slice(i, i + 2), 16) / 255);
const mixRgb = (a, b, t) => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t];
/** Sea and lake fill: `seaMix` of ultramarine, the rest paper. */
export const seaColour = (palette) => mixRgb(hex(palette.paper), hex(PALETTES.light.river), palette.seaMix);

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
uniform sampler2D uD;
uniform int uN;
uniform float uLineScale;
uniform float uSea;
uniform float uUnitsPerPx;
uniform float uPxPerUnit;
uniform float uDpr;
uniform float uContour;   // contour interval, world units
uniform float uAlluvium;  // world units
uniform float uReach;     // world units
uniform vec3 uTint[9];
uniform vec3 uSeaFill;
uniform vec3 uShoal;
uniform vec3 uSilt;
uniform vec3 uWaterline;
uniform vec3 uCoast;
uniform vec3 uLine;
uniform vec3 uStip;
uniform vec3 uWl[3];      // waterlines: distance px, width px, strength
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

// Coverage of a line of the given width (device px) where v == level.
float levelLine(float v, float level, float widthPx) {
  float d = abs(v - level) / max(fwidth(v), 1e-6);
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

  float coast = bilinear(uD, g); // signed distance to the coast, world units (land > 0)
  float base = bilinear(uB, g);
  float dep = bilinear(uH, g) - base;

  // New land: ground that was sea floor when the survey began (a delta).
  if (h > uSea && base < uSea) col = mix(col, uSilt, 0.45);

  // Alluvium near the coast: dots where deposition has raised the ground,
  // within reach of the sea (deltas and the lower valleys), or on new land.
  if (dep > uAlluvium && h > uSea && (coast < uReach || base < uSea)) {
    vec2 cell = floor(gl_FragCoord.xy / (4.5 * uDpr));
    vec2 centre = (cell + 0.25 + 0.5 * vec2(hash(cell), hash(cell + 17.0))) * 4.5 * uDpr;
    float r = 0.62 * uDpr;
    float keep = step(hash(cell + 3.1), clamp(dep / (uAlluvium * 4.0), 0.35, 0.9));
    keep *= 1.0 - smoothstep(uReach * 0.7, uReach, coast) * step(uSea, base);
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

  // Lakes: standing water in a closed hollow (the kernel's "wet" > 1).
  float w = bilinear(uW, g);
  float aw = max(fwidth(w), 1e-4);
  float lake = smoothstep(1.0 - aw * 0.7, 1.0 + aw * 0.7, w);
  float lakeEdge = 1.0 - smoothstep(0.3 * uDpr, 0.3 * uDpr + 1.0, abs(w - 1.0) / aw);

  // Sea: the connected sea mask cut exactly at the sea-level contour of the
  // smooth terrain, so the coastline is clean. Pale, with waterlines.
  float near = bilinear(uS, g);
  float fh = max(fwidth(h), 1e-5);
  float sea = near > 0.02 ? 1.0 - smoothstep(-0.7 * fh, 0.7 * fh, h - uSea) : 0.0;
  float seaEdge = near > 0.02 ? 1.0 - smoothstep(0.35 * uDpr * uLineScale, 0.35 * uDpr * uLineScale + 1.0, abs(h - uSea) / fh) : 0.0;
  col = mix(col, uSeaFill, max(lake, sea));
  // Shoals: sediment laid down on the sea floor (a delta front building
  // towards the surface), paler water with a fine dot, as charts show it.
  float shoal = sea * (1.0 - lake) * smoothstep(uAlluvium * 0.6, uAlluvium * 2.0, dep);
  if (shoal > 0.0) {
    col = mix(col, uShoal, shoal);
    vec2 sc = floor(gl_FragCoord.xy / (3.2 * uDpr));
    vec2 sp = (sc + 0.3 + 0.4 * vec2(hash(sc + 5.0), hash(sc + 9.0))) * 3.2 * uDpr;
    float sd = 1.0 - smoothstep(0.45 * uDpr - 0.5, 0.45 * uDpr + 0.5, length(gl_FragCoord.xy - sp));
    col = mix(col, uWaterline, 0.45 * sd * shoal * step(hash(sc + 1.7), 0.7));
  }
  // CSS px out from the coast, held flat beyond the last waterline so the
  // unmeasured far sea (a jump in the field) cannot draw a line.
  float offPx = min(-coast, 40.0) * uPxPerUnit;
  float lines = 0.0;
  for (int k = 0; k < 3; k++) {
    lines = max(lines, levelLine(offPx, uWl[k].x * uLineScale, uWl[k].y * uDpr * max(uLineScale, 0.8)) * uWl[k].z);
  }
  col = mix(col, uWaterline, lines * sea * (1.0 - lake));
  float edge = max(lakeEdge * (1.0 - sea), seaEdge * (1.0 - lake));
  col = mix(col, uCoast, edge * 0.85);

  // Paper grain.
  col += (hash(gl_FragCoord.xy) - 0.5) * uGrain;
  outColor = vec4(col, 1.0);
}`;

// Rivers: one instanced quad per segment, expanded in the vertex shader to
// cover a round-capped line; the fragment shader measures each pixel's
// distance to the segment, so lines are anti-aliased and joined end to end.
const RIVER_VERT = `#version 300 es
in vec2 aCorner;   // x: 0..1 along the segment, y: -1..1 across it
in vec4 aSeg;      // x0, y0, x1, y1 in grid cells
in float aRatio;   // upstream area over the river threshold
uniform float uN;
uniform vec2 uCanvas;  // device px
uniform float uDpr;
uniform float uWidthScale;
out vec2 vP;
flat out vec2 vA;
flat out vec2 vB;
flat out float vR;
void main() {
  float wCss = clamp(0.6 + 0.35 * log2(max(aRatio, 1.0)), 0.8, 3.5) * uWidthScale;
  float r = 0.5 * wCss * uDpr;
  vec2 a = aSeg.xy / uN * uCanvas;
  vec2 b = aSeg.zw / uN * uCanvas;
  vec2 d = b - a;
  float len = length(d);
  vec2 t = len > 1e-4 ? d / len : vec2(1.0, 0.0);
  vec2 nrm = vec2(-t.y, t.x);
  float pad = r + 1.0;
  vec2 p = a + t * (aCorner.x * (len + 2.0 * pad) - pad) + nrm * (aCorner.y * pad);
  vP = p;
  vA = a;
  vB = b;
  vR = r;
  gl_Position = vec4(p.x / uCanvas.x * 2.0 - 1.0, 1.0 - p.y / uCanvas.y * 2.0, 0.0, 1.0);
}`;

const RIVER_FRAG = `#version 300 es
precision highp float;
in vec2 vP;
flat in vec2 vA;
flat in vec2 vB;
flat in float vR;
uniform vec3 uRiver;
out vec4 outColor;
void main() {
  vec2 pa = vP - vA;
  vec2 ba = vB - vA;
  float k = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);
  float cover = clamp(vR + 0.5 - length(pa - ba * k), 0.0, 1.0);
  if (cover <= 0.0) discard;
  outColor = vec4(uRiver * cover, cover); // premultiplied
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS) && !gl.isContextLost()) {
    const log = gl.getShaderInfoLog(s);
    gl.deleteShader(s);
    throw new Error(`shader: ${log}`);
  }
  return s;
}

function program(gl, vs, fs) {
  const prog = gl.createProgram();
  gl.attachShader(prog, compile(gl, gl.VERTEX_SHADER, vs));
  gl.attachShader(prog, compile(gl, gl.FRAGMENT_SHADER, fs));
  gl.linkProgram(prog);
  if (!gl.getProgramParameter(prog, gl.LINK_STATUS) && !gl.isContextLost()) throw new Error(`link: ${gl.getProgramInfoLog(prog)}`);
  return prog;
}

const MAP_UNIFORMS = ['uH', 'uW', 'uB', 'uS', 'uD', 'uLineScale', 'uN', 'uSea', 'uUnitsPerPx', 'uPxPerUnit', 'uDpr', 'uContour',
  'uAlluvium', 'uReach', 'uTint', 'uSeaFill', 'uShoal', 'uSilt', 'uWaterline', 'uCoast', 'uLine', 'uStip', 'uWl', 'uLineAlpha', 'uIndexAlpha',
  'uShade', 'uGrain'];
const RIVER_UNIFORMS = ['uN', 'uCanvas', 'uDpr', 'uWidthScale', 'uRiver'];

function createGL(canvas, { onLost, onRestored } = {}) {
  const gl = canvas.getContext('webgl2', { antialias: false, alpha: false, preserveDrawingBuffer: true });
  if (!gl) return null;

  // Everything the GPU holds, rebuilt from scratch if the context is lost.
  let res = null;
  function setup() {
    const map = program(gl, VERT, FRAG);
    const river = program(gl, RIVER_VERT, RIVER_FRAG);
    const u = {};
    for (const name of MAP_UNIFORMS) u[name] = gl.getUniformLocation(map, name);
    const ur = {};
    for (const name of RIVER_UNIFORMS) ur[name] = gl.getUniformLocation(river, name);

    const mapVao = gl.createVertexArray();
    gl.bindVertexArray(mapVao);
    const quad = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, quad);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    const posLoc = gl.getAttribLocation(map, 'aPos');
    gl.enableVertexAttribArray(posLoc);
    gl.vertexAttribPointer(posLoc, 2, gl.FLOAT, false, 0, 0);

    const riverVao = gl.createVertexArray();
    gl.bindVertexArray(riverVao);
    const corners = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, corners);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, -1, 1, -1, 0, 1, 1, 1]), gl.STATIC_DRAW);
    const cLoc = gl.getAttribLocation(river, 'aCorner');
    gl.enableVertexAttribArray(cLoc);
    gl.vertexAttribPointer(cLoc, 2, gl.FLOAT, false, 0, 0);
    const segs = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, segs);
    const stride = SEGMENT_FLOATS * 4;
    const sLoc = gl.getAttribLocation(river, 'aSeg');
    gl.enableVertexAttribArray(sLoc);
    gl.vertexAttribPointer(sLoc, 4, gl.FLOAT, false, stride, 0);
    gl.vertexAttribDivisor(sLoc, 1);
    const rLoc = gl.getAttribLocation(river, 'aRatio');
    gl.enableVertexAttribArray(rLoc);
    gl.vertexAttribPointer(rLoc, 1, gl.FLOAT, false, stride, 16);
    gl.vertexAttribDivisor(rLoc, 1);
    gl.bindVertexArray(null);

    const textures = [0, 1, 2, 3, 4].map((unit) => {
      const t = gl.createTexture();
      gl.activeTexture(gl.TEXTURE0 + unit);
      gl.bindTexture(gl.TEXTURE_2D, t);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
      gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
      return t;
    });
    gl.useProgram(map);
    ['uH', 'uW', 'uB', 'uS', 'uD'].forEach((name, unit) => gl.uniform1i(u[name], unit));
    res = { map, river, u, ur, mapVao, riverVao, segs, textures, texSize: 0, survey: -1, segCount: 0 };
  }

  canvas.addEventListener('webglcontextlost', (e) => {
    e.preventDefault(); // ask the browser to give the context back
    res = null;
    onLost?.();
  });
  canvas.addEventListener('webglcontextrestored', () => {
    try {
      setup();
      onRestored?.();
    } catch (err) {
      console.warn('Could not restore the map after losing the graphics context:', err.message);
    }
  });
  setup();

  // Upload the interior n x n of an (n+2)-strided field, skipping the ghost ring.
  function upload(unit, field, n, stride, fresh) {
    gl.activeTexture(gl.TEXTURE0 + unit);
    gl.bindTexture(gl.TEXTURE_2D, res.textures[unit]);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 4);
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, stride);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, 1);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, 1);
    if (fresh) gl.texImage2D(gl.TEXTURE_2D, 0, gl.R32F, n, n, 0, gl.RED, gl.FLOAT, field);
    else gl.texSubImage2D(gl.TEXTURE_2D, 0, 0, 0, n, n, gl.RED, gl.FLOAT, field);
    gl.pixelStorei(gl.UNPACK_ROW_LENGTH, 0);
    gl.pixelStorei(gl.UNPACK_SKIP_PIXELS, 0);
    gl.pixelStorei(gl.UNPACK_SKIP_ROWS, 0);
  }

  return {
    kind: 'webgl2',
    /** Draws the map; returns false if the GPU context is lost. */
    draw(engine, palette, { baseDirty }) {
      if (!res || gl.isContextLost()) return false;
      const n = engine.size;
      const f = engine.fields();
      const fresh = res.texSize !== n;
      const survey = engine.surveyVersion;
      const surveyed = fresh || res.survey !== survey;
      upload(0, f.height, n, engine.stride, fresh);
      upload(3, f.sea, n, engine.stride, fresh);
      if (baseDirty || fresh) upload(2, f.base, n, engine.stride, fresh);
      if (surveyed) {
        upload(1, f.wet, n, engine.stride, fresh);
        upload(4, f.dist, n, engine.stride, fresh);
        const segs = engine.rivers();
        gl.bindBuffer(gl.ARRAY_BUFFER, res.segs);
        gl.bufferData(gl.ARRAY_BUFFER, segs, gl.DYNAMIC_DRAW);
        res.segCount = segs.length / SEGMENT_FLOATS;
        res.survey = survey;
      }
      res.texSize = n;

      const cssW = canvas.clientWidth || canvas.width;
      const dpr = canvas.width / Math.max(1, cssW);
      // Thinner linework on small maps (phones), so contours don't clot.
      const lineScale = Math.max(0.6, Math.min(1, (canvas.clientWidth || 700) / 700));
      const u = res.u;
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.disable(gl.BLEND);
      gl.useProgram(res.map);
      gl.bindVertexArray(res.mapVao);
      gl.uniform1i(u.uN, n);
      gl.uniform1f(u.uSea, engine.seaLevel);
      gl.uniform1f(u.uUnitsPerPx, (engine.cellSize * n) / (canvas.width / dpr));
      gl.uniform1f(u.uPxPerUnit, (canvas.width / dpr) / (engine.cellSize * n));
      gl.uniform1f(u.uDpr, dpr);
      gl.uniform1f(u.uLineScale, lineScale);
      gl.uniform1f(u.uContour, CONTOUR_M / METRES_PER_UNIT);
      gl.uniform1f(u.uAlluvium, ALLUVIUM_M / METRES_PER_UNIT);
      gl.uniform1f(u.uReach, ALLUVIUM_REACH_M / METRES_PER_UNIT);
      gl.uniform3fv(u.uTint, palette.tints.flatMap(hex));
      gl.uniform3fv(u.uSeaFill, seaColour(palette));
      gl.uniform3fv(u.uShoal, hex(palette.shoal));
      gl.uniform3fv(u.uSilt, hex(palette.silt));
      gl.uniform3fv(u.uWaterline, hex(palette.waterline));
      gl.uniform3fv(u.uCoast, hex(palette.coast));
      gl.uniform3fv(u.uLine, hex(palette.contour));
      gl.uniform3fv(u.uStip, hex(palette.stipple));
      gl.uniform3fv(u.uWl, WATERLINES.flat());
      gl.uniform1f(u.uLineAlpha, palette.lineAlpha);
      gl.uniform1f(u.uIndexAlpha, palette.indexAlpha);
      gl.uniform1f(u.uShade, palette.shade);
      gl.uniform1f(u.uGrain, palette.grain);
      gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

      if (res.segCount > 0) {
        const ur = res.ur;
        gl.enable(gl.BLEND);
        gl.blendFunc(gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
        gl.useProgram(res.river);
        gl.bindVertexArray(res.riverVao);
        gl.uniform1f(ur.uN, n);
        gl.uniform2f(ur.uCanvas, canvas.width, canvas.height);
        gl.uniform1f(ur.uDpr, dpr);
        gl.uniform1f(ur.uWidthScale, Math.max(0.75, lineScale));
        gl.uniform3fv(ur.uRiver, hex(palette.river));
        gl.drawArraysInstanced(gl.TRIANGLE_STRIP, 0, 4, res.segCount);
        gl.disable(gl.BLEND);
      }
      gl.bindVertexArray(null);
      return true;
    },
    lost: () => !res || gl.isContextLost(),
  };
}

// ---------------------------------------------------------------------------
// Canvas 2D fallback: one pixel per grid cell, scaled up by the browser, with
// the rivers stroked on top.

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
      const { height: H, wet: W, base: B, sea: SEA, dist: D } = engine.fields();
      if (!img || img.width !== n) {
        img = new ImageData(n, n);
        scratch = new OffscreenCanvasOrCanvas(n);
      }
      const tints = palette.tints.map(hex);
      const water = seaColour(palette);
      const line = hex(palette.contour);
      const stip = hex(palette.stipple);
      const cu = CONTOUR_M / METRES_PER_UNIT;
      const reach = ALLUVIUM_REACH_M / METRES_PER_UNIT;
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
              c = mixRgb(c, line, isIndex ? palette.indexAlpha : palette.lineAlpha * 0.8);
            } else if (h - B[i] > ALLUVIUM_M / METRES_PER_UNIT && (D[i] < reach || B[i] < engine.seaLevel) && (x + 2 * y) % 5 === 0) {
              c = mixRgb(c, stip, 0.7);
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

      // Rivers, batched into a few width classes (one path each).
      const segs = engine.rivers();
      const s = canvas.width / n;
      const dpr = canvas.width / Math.max(1, canvas.clientWidth || canvas.width);
      const classes = new Map();
      for (let k = 0; k < segs.length; k += SEGMENT_FLOATS) {
        const w = Math.round(riverWidth(segs[k + 4]) * 4) / 4;
        if (!classes.has(w)) classes.set(w, []);
        classes.get(w).push(k);
      }
      ctx.strokeStyle = palette.river;
      ctx.lineCap = 'round';
      ctx.lineJoin = 'round';
      for (const [w, list] of classes) {
        ctx.lineWidth = w * dpr;
        ctx.beginPath();
        for (const k of list) {
          ctx.moveTo(segs[k] * s, segs[k + 1] * s);
          ctx.lineTo(segs[k + 2] * s, segs[k + 3] * s);
        }
        ctx.stroke();
      }
      return true;
    },
    lost: () => false,
  };
}

function OffscreenCanvasOrCanvas(n) {
  const c = typeof OffscreenCanvas !== 'undefined' ? new OffscreenCanvas(n, n) : Object.assign(document.createElement('canvas'), { width: n, height: n });
  return { canvas: c, ctx: c.getContext('2d') };
}

/**
 * Pick the best renderer. `prefer` may be 'webgl2' or 'canvas2d'. A canvas
 * keeps the first context type it hands out, so if WebGL2 half-starts and
 * then fails, the canvas is swapped for a fresh one (see `renderer.canvas`).
 * `hooks.onLost` / `hooks.onRestored` hear about a lost WebGL context.
 */
export function createRenderer(canvas, prefer = 'webgl2', hooks = {}) {
  if (prefer !== 'canvas2d') {
    try {
      const gl = createGL(canvas, hooks);
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
