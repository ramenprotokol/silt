# silt

**Paint a mountain, watch 10,000 years of rain carve a river delta.**

![Sheet 4 after 10,000 (playful) years: rivers cut into the hills, a painted ridge turns them aside, and a delta tongue pushes out into the sea](docs/screenshot.png)

silt is a hydraulic-erosion model drawn as a geological survey sheet. The whole
simulation is written in Zig and runs in your browser as a 22 KiB WebAssembly
module. JavaScript only handles the controls and draws the map straight from the
kernel's memory.

## The 30-second experience

1. The sheet opens on a procedurally generated coast: a mountain range in the
   north, a winding valley draining south, a coastal plain and a shallow sea.
2. Drag on the map to raise ground (or switch to **Lower**, or hold <kbd>Alt</kbd>).
   Brush size and strength are rulers in the margin.
3. Press **Run**. Rain falls, flows, picks up sediment and lays it down again.
   Contours redraw live, rivers cut into the hills, and where they meet the sea
   the coast builds out into deltas. Stippled ground is alluvium: more than 5 m
   laid down since the survey began.
4. The years counter ticks up on a stated, playful scale (each model step is
   counted as 1¼ years; it is not geology).
5. Export the terrain as a **16-bit greyscale PNG heightmap**, or save the map view.

Keyboard: with the map focused, the arrow keys move the brush (Shift for bigger
jumps), <kbd>Enter</kbd> paints, <kbd>Shift</kbd>+<kbd>Enter</kbd> paints the
opposite way, <kbd>[</kbd>/<kbd>]</kbd> change the size and <kbd>Space</kbd>
runs or halts. With `prefers-reduced-motion`, nothing animates: the Run button
becomes **+1,000 years**, which jumps ahead and draws once.

## How it works

### The kernel (Zig, `src/`)

The method is the grid-based **virtual-pipe model** of Mei, Decaudin & Hu,
*Fast Hydraulic Erosion Simulation and Visualization on GPU* (Pacific Graphics
2007). Water sits in cells and moves through four virtual pipes to its
neighbours, driven by differences in water-surface height. The flow sets a
velocity field, the velocity sets how much sediment the water can carry, and
each cell erodes or deposits towards that capacity. Each step:

1. **rain** on land (more on high ground, in passing showers from a seeded PRNG);
2. **flux** through the pipes, scaled so no cell sends more water than it holds;
3. **water**: depth and velocity from the fluxes, and the sediment capacity;
4. **erode**: pick up or lay down sediment towards capacity;
5. **transport** the suspended sediment with the water, then **evaporate**;
6. **slump + creep**: thermal weathering (talus slumping, after Musgrave,
   Kolb & Mace, *The synthesis and rendering of eroded fractal terrains*,
   SIGGRAPH 1989) and a light linear creep;
7. hold the **sea** at sea level.

Changes from the paper, each made for a reason you can see on the map (they are
also documented at the top of `src/sim.zig`):

- **Conservative sediment transport.** Sediment moves with the same pipe fluxes
  as the water (a finite-volume, donor-cell scheme) instead of semi-Lagrangian
  advection. Water and material are then conserved to float rounding, and
  every source and sink (rain, evaporation, sea exchange, painting) is booked.
  The page shows the live balance of those books in its title block.
- **Stream-power capacity.** Capacity is tilt × speed × min(depth, d_ref) above a
  small threshold, and averaged over 3×3 cells. Shallow flow behaves like
  discharge × slope; deep, slow water (a lake, the sea) drops its load, which
  is what builds deltas. The 3×3 average stops the one-cell rills the plain
  model grows on a fine grid.
- **Depth-dependent friction.** Pipe flux carries over between steps with a
  friction that is strong in thin films and weak in deep water, so sheet-wash
  stays calm and channels carry a lot.
- **A soft sea.** The sea connected to the map edge (found by a flood fill every
  few steps) is pulled towards sea level rather than clamped, so a river's
  momentum carries out past its mouth before the sediment settles.
- **Closed map edges.** A ghost ring around the grid is a wall to water and a
  mirror to the terrain, so nothing leaks off the map.

Engineering notes:

- **No allocation per step.** All fields are flat `f32` arrays in static
  WebAssembly memory (15 fields of 514² for the 512² grid, about 16 MB), handed
  to the simulation once at `init`.
- **SIMD.** The hot loops use `@Vector(4, f32)`, which compiles to WebAssembly
  `simd128`. Rows are a multiple of 4 wide, so there is no scalar tail. The same
  kernels are generic over the lane count, and a test checks that the 4-lane
  and 1-lane builds give **bit-identical** results.
- **A measured SIMD pitfall.** Zig's `@max`/`@min` lower to LLVM's
  NaN-ignoring `maxnum`/`minnum`, which WebAssembly SIMD has no instruction
  for, so LLVM scalarises them. Replacing them with compare-and-select took a
  512² step from 10.5 ms to 1.3 ms in Node 22 during development (on an Apple
  M5 Pro, ReleaseFast build).
- **Deterministic.** Terrain and rain come from integer hashes and a splitmix64
  PRNG seeded by the survey number. The same survey number gives the same map,
  bit for bit.
- **PNG export in Zig.** `src/png.zig` writes a 16-bit greyscale PNG (CRC-32,
  Adler-32, zlib stored blocks, a `tEXt` chunk giving the height range). It is
  uncompressed, so a 512² export is about 513 KiB.

### The page (JavaScript, `web/`)

- `engine.js` loads `silt.wasm` and exposes the fields as `Float32Array` views of
  WebAssembly memory. Nothing is copied.
- `render.js` is a WebGL2 fragment shader that draws, per screen pixel:
  - hypsometric layer tints (olive → ochre → chalk in 100 m bands) with faint
    relief shading;
  - hairline contours every 20 m and heavier index contours every 100 m
    (anti-aliased with `fwidth`, fading where they crowd);
  - flat ultramarine water;
  - a coastline cut exactly at the sea-level contour of a cubic B-spline of the
    terrain, so it is a clean curve;
  - an alluvium stipple.

  It uploads the fields straight from WebAssembly memory with
  `UNPACK_ROW_LENGTH`/`SKIP_*`, skipping the ghost ring. If WebGL2 is missing,
  a Canvas 2D fallback draws at grid resolution.
- `app.js` holds the controls, painting (pointer and keyboard) and the loop.
  - The loop runs as many steps per frame as fit in about 9 ms, measured as it
    goes.
  - On load it times a few 512² steps. If a step takes over 10 ms, it switches
    to the 256² grid and says so, with the measured time. The grid can be
    switched back in the margin.
  - The step time and the kernel's size in the title block are measured on
    the page, not typed in.

## Why Zig

The kernel is a set of tight stencil loops over flat arrays: exactly what Zig is
good at.

- `@Vector` gives portable SIMD without intrinsics.
- `comptime` lets one kernel be instantiated at 4 lanes (production) and 1
  lane (the reference the tests compare against).
- There is no runtime or allocator to ship, and a freestanding `wasm32` build
  is two lines in `build.zig`.
- The result is a 22 KiB module that does all the physics. The native test
  build runs the same code under `zig build test`.

## Build and test

Toolchain: **Zig 0.16.0** and **Node 20+** (22 was used). Chrome or Chromium is
used by the browser test if it is installed.

```sh
npm run build      # zig build (wasm, ReleaseSmall) + copy web/ -> dist/
npm test           # zig build test, then build, then the Node tests
npm run serve      # serve dist/ locally (PORT=... to pick a port)
```

- `zig build` alone produces `zig-out/bin/silt.wasm`.
- `zig build test` runs the kernel's unit tests natively.
- `WASM_OPTIMIZE=ReleaseFast npm run build` trades size for speed.

Measured on the build machine (Apple M5 Pro, Node 22). These numbers are for
this README only; the page measures its own.

| build | silt.wasm | 512² step | 256² step |
| --- | --- | --- | --- |
| ReleaseSmall (default) | 22,136 bytes | 2.1 ms | 0.54 ms |
| ReleaseFast | 36,007 bytes | 1.8 ms | 0.41 ms |

What the tests cover:

- **Zig (`src/tests.zig`, plus tests in `terrain.zig` and `png.zig`).**
  - Conservation: the water books (rain − evaporation + sea exchange + painting)
    and the material books (terrain + suspended sediment) balance after every
    step, including with painting mid-run.
  - Determinism: a fixed seed gives bit-identical runs, and the SIMD and scalar
    kernels agree bit for bit.
  - Boundaries: no pipe carries water off the map; the ghost ring stays a wall
    and mirrors the edge; the sea is held at sea level; an inland hollow is a
    lake, not sea, until a channel connects it.
  - Brush: shape, symmetry, radius, texture, clamping, bad input, off-map
    strokes, and water displaced by rising ground.
  - Erosion really cuts and deposits.
  - PNG: structure, CRCs, multi-block output.
- **Node (`tests/*.test.mjs`).**
  - The built wasm loads and one step changes the heightmap.
  - Size budget, determinism across instances, books after 600 steps.
  - Bad input is refused with an error, not a trap.
  - The PNG export decodes (with `zlib`) to the right pixels.
  - Headers (CSP, no long cache), no deploy script, text contrast (WCAG AA, both
    themes).
- **Browser (`tests/browser.test.mjs`, headless Chrome over the DevTools
  protocol).** No console errors or failed requests at 1280×800 and at a true
  400 px phone width (device emulation), in both themes. It also checks:
  - no horizontal scroll;
  - Run and Halt;
  - a real pointer drag paints, and keyboard painting works;
  - export, and the bad-survey-number message;
  - reduced motion (jumps, never animates);
  - the Canvas 2D fallback.

  Without Chrome it skips; set `REQUIRE_BROWSER=1` (for CI) to make that a
  failure.

## Running on Cloudflare (free)

silt is a static site: `dist/` holds 8 files, about 84 KiB in all (the kernel
and the page script are about 22 KiB each). There is no server, no Worker, no storage and no API
calls. It fits Cloudflare Pages' free tier (unlimited requests, 20,000 files,
25 MiB per file) with a very wide margin.

`dist/_headers` sets a Content-Security-Policy (`'wasm-unsafe-eval'` is the only
relaxation, needed to compile WebAssembly), `nosniff`, `no-referrer` and a
locked-down `Permissions-Policy`. It sets no long `Cache-Control`, because the
file names are not content-hashed.

To deploy your own copy: `npm run build`, then
`npx wrangler pages deploy dist --project-name silt`. This repository
deliberately has no deploy script and no `account_id`. The owner deploys
through a separate guarded script, so no machine-wide Cloudflare login is ever
used by accident.

## Honest limitations

- **Illustrative, not geology.**
  - One cell is called 20 m and one step 1¼ years, for flavour.
  - The map is 10.24 km across at that scale, and the scale bar is true to the
    map as drawn.
  - The parameters were tuned by eye for a legible sheet, not fitted to data.
- **Rivers are wide.**
  - The pipe model has no bank strength, so big rivers spread into wide,
    braided channels and estuaries.
  - Drawn rivers are cells whose smoothed discharge passes a threshold, so small
    streams on the plain can look broken into segments.
- **Deltas build as lobes and tongues** of new land and alluvium, not as
  textbook bird's-foot deltas. A painted smooth mountain erodes mostly by
  slumping and wash: rivers go around it rather than carving deep gullies into
  it within 10,000 steps.
- **The water is `f32`.** The books balance to parts per million, not exactly.
- **The 256² fallback** is chosen from a quick timing at load. A coarser grid
  gives coarser, differently shaped rivers.
- **Browser support.** It needs WebAssembly SIMD (Chrome 91+, Firefox 89+,
  Safari 16.4+). WebGL2 is preferred; the Canvas 2D fallback is coarser.
- **The simulation runs on the main thread.** The loop keeps each frame's
  share to about 9 ms.
- **Fonts.** The page loads EB Garamond from Google Fonts, which is a
  third-party request. Nothing you paint leaves the browser.

## Next

- Short GIF or time-lapse export.
- Rivers as vector lines (traced from the flow field) for a crisper
  hydrography.
- Time-lapse sharing: survey number, strokes and years in a URL.
- Undo for painting; a smoothing brush.
- Import a heightmap PNG to erode.
- Run the kernel in a Web Worker.

## Credits

Built by Ramen Protocol with AI assistance (Claude). Method after Mei, Decaudin
& Hu (2007) and Musgrave, Kolb & Mace (1989), with the changes listed above.

MIT licence: see `LICENSE`.
