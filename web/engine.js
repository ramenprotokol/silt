// Thin wrapper around silt.wasm (the Zig simulation kernel). Works in the
// browser and in Node: pass a URL, a fetch Response or raw bytes.
//
// The kernel owns every buffer. This file only reads the height, water and
// base fields in place, as Float32Array views of the module's memory.

export const PARAM = Object.freeze({
  rain: 0, capacity: 1, dissolve: 2, deposit: 3, evaporation: 4, dt: 5,
  friction: 6, minTilt: 7, depthRef: 8, maxErode: 9, talus: 10, thermal: 11,
  pipeArea: 12, maxSpeed: 13, threshold: 14, seaRelax: 15, flowSmooth: 16,
  lakeDepth: 17, riverFlow: 18, frictionDepth: 19, creep: 20,
});

export const STAT = Object.freeze({
  water: 0, terrain: 1, sediment: 2, rain: 3, evaporation: 4, seaExchange: 5,
  brushWater: 6, brushTerrain: 7, lowest: 8, highest: 9,
});

/** Grid sizes the page offers. The kernel accepts any multiple of 4, 8..512. */
export const GRID_FULL = 512;
export const GRID_LIGHT = 256;

/** World units per metre: 1 unit is 20 m (an illustrative scale). */
export const METRES_PER_UNIT = 20;
/** The map is 512 world units across whatever the grid, i.e. 10.24 km. */
export const WORLD_UNITS = 512;

async function instantiate(source) {
  if (typeof source === 'string' || source instanceof URL) source = await fetch(source);
  if (typeof Response !== 'undefined' && source instanceof Response) {
    if (!source.ok) throw new Error(`could not load the simulation (${source.status})`);
    if (WebAssembly.instantiateStreaming && source.headers.get('content-type')?.startsWith('application/wasm')) {
      return (await WebAssembly.instantiateStreaming(source, {})).instance;
    }
    source = await source.arrayBuffer();
  }
  return (await WebAssembly.instantiate(source, {})).instance;
}

export async function loadEngine(source) {
  const instance = await instantiate(source);
  const x = instance.exports;
  const check = (code, what) => {
    if (code < 0) throw new Error(`${what} failed (code ${code})`);
    return code;
  };
  let views = null;
  const view = (ptr) => new Float32Array(x.memory.buffer, ptr, x.silt_stride() ** 2);

  return {
    exports: x,
    /** Start a survey: an n x n grid with the default terrain for `seed`. */
    init(n, seed) {
      check(x.silt_init(n, seed >>> 0), 'init');
      views = null;
    },
    /** Run `count` steps (split into chunks the kernel accepts). */
    step(count) {
      let left = count;
      while (left > 0) left -= check(x.silt_step(Math.min(left, 1000)), 'step');
      views = null; // height and scratch swap every step
    },
    brush(gx, gy, radius, strength) {
      check(x.silt_brush(gx, gy, radius, strength), 'brush');
      views = null;
    },
    setParam(id, value) {
      return check(x.silt_set_param(id, value), `parameter ${id}`);
    },
    get size() { return x.silt_size(); },
    get stride() { return x.silt_stride(); },
    get steps() { return x.silt_steps(); },
    get seaLevel() { return x.silt_sea_level(); },
    get cellSize() { return x.silt_cell_size(); },
    stat(which) { return x.silt_stat(which); },
    /** Views of the (n+2)^2 fields; valid until the next step/brush/init. */
    fields() {
      if (!views || views.height.buffer !== x.memory.buffer) {
        views = {
          height: view(x.silt_height_ptr()),
          wet: view(x.silt_wet_ptr()),
          base: view(x.silt_base_ptr()),
          water: view(x.silt_water_ptr()),
          sea: view(x.silt_sea_ptr()),
        };
      }
      return views;
    },
    /** 16-bit greyscale PNG of the terrain, encoded by the kernel. */
    encodeHeightmapPng(lo, hi, text = '') {
      const bytes = new TextEncoder().encode(text).subarray(0, 512);
      new Uint8Array(x.memory.buffer, x.silt_text_ptr(), bytes.length).set(bytes);
      const len = check(x.silt_encode_png(lo, hi, bytes.length), 'PNG export');
      return new Uint8Array(x.memory.buffer, x.silt_png_ptr(), len).slice();
    },
  };
}
