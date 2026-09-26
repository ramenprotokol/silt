//! Grid-based hydraulic erosion: the "virtual pipe" shallow-water model of
//! Mei, Decaudin & Hu (2007), "Fast Hydraulic Erosion Simulation and
//! Visualization on GPU" (Pacific Graphics 2007). Each step:
//!
//!   1. rain            water falls on land (more on high ground, in showers)
//!   2. flux            outflow through four virtual pipes, driven by the
//!                      water-surface height difference, scaled so no cell
//!                      sends more than it holds
//!   3. water           depth update and velocity field from the fluxes;
//!                      local sediment transport capacity
//!   4. erode           pick up or lay down sediment towards capacity
//!   5. transport       move suspended sediment with the water
//!   6. evaporate
//!   7. slump + creep   thermal weathering
//!   8. sea             hold the sea at sea level
//!
//! The drainage survey in hydro.zig (fill pits, route water D8, trace the
//! rivers the page draws) runs in `settle`, when painting has changed the
//! ground or `survey_every` steps have passed. It is for drawing only:
//! nothing in the physics reads it. Keeping it out of `step` lets the page
//! charge its cost to a frame's budget instead of stalling a batch of steps.
//!
//! Changes from the paper, each for a reason visible on the map:
//!
//!  * Sediment moves with the same pipe fluxes as the water (finite-volume,
//!    donor cell) instead of semi-Lagrangian advection, so it is conserved
//!    to float rounding and the books can be checked every step.
//!  * Capacity is tilt x speed x min(depth, depth_ref) above a small
//!    threshold (a stream-power form: it tracks discharge in shallow flow,
//!    and falls off in deep, slow water such as the sea, where rivers drop
//!    their load). It is averaged over 3x3 cells before use, so a channel
//!    cannot be narrower than a few cells: this stops the one-cell rills the
//!    plain model grows on a fine grid.
//!  * Pipe flux carries over between steps with a friction that is strong
//!    in thin films and weak in deep water, so sheet-wash stays calm and
//!    channels carry a lot.
//!  * Thermal weathering (talus slumping, after Musgrave, Kolb & Mace 1989,
//!    "The synthesis and rendering of eroded fractal terrains") plus a light
//!    linear creep keep painted cliffs from standing forever.
//!  * The sea is a fixed-level reservoir, held softly so a river's momentum
//!    carries out past the mouth before the sediment settles.
//!  * Deltas: sea level is the base level. Nothing is eroded below it, so a
//!    river cannot scour a drowned estuary; and in the sea the capacity dies
//!    away with depth (x exp(-depth/sea_depth)) while deposition is fast
//!    (sea_deposit), so a river drops its load at the mouth.
//!  * Open land edges: beyond a land edge the ground continues the edge
//!    slope, so water that runs off the map leaves (booked as edge outflow,
//!    with the sediment it carries) instead of ponding against a wall. Sea
//!    edges stay closed.
//!
//! Every change of water and material is booked (rain, evaporation, sea
//! exchange, edge outflow, painting, and the sediment picked up and laid
//! down), so tests can check the accounting after each step.
//!
//! Layout: every field is an (n+2) x (n+2) array of f32. The outer ring is a
//! ghost ring. Ghost terrain copies the nearest edge cell (so slopes and
//! slumping see a flat continuation and no material crosses the edge by
//! creep). Ghost water is a very tall wall beside the sea; beside land it
//! sets the ghost's water surface to the edge slope carried on one cell, so
//! the pipes drain off the map only where the ground falls away. Interior
//! rows are n cells wide, and n is a multiple of the SIMD width, so the hot
//! loops never need a scalar tail.
//!
//! No allocation happens after `init`: all buffers are handed in.

const std = @import("std");
const terrain = @import("terrain.zig");
const hydro = @import("hydro.zig");

/// SIMD width used in production. Tests also run the same kernels at width 1
/// and check the results are bit-identical.
pub const lanes = 4;

/// Horizontal extent of the map in world units, whatever the grid size.
pub const world_size: f32 = 512.0;

/// Ghost-ring water depth: a wall no flow can climb.
pub const wall: f32 = 1.0e6;

/// Painting limits (world units).
pub const min_height: f32 = -40.0;
pub const max_height: f32 = 80.0;
pub const max_brush_radius: f32 = 64.0;
pub const max_brush_strength: f32 = 4.0;

/// Spatial frequencies (per cell) of the brush texture: broad swells, and
/// finer ridges with hollows between them for the rain to gather in.
const texture_freq: f32 = 0.09;
const ridge_freq: f32 = 0.16;

/// How often (in steps) the connected sea is re-flooded from the map edge.
pub const sea_every: u64 = 4;
/// How many steps may pass before `settle` re-runs the drainage survey.
pub const survey_every: u64 = 16;

pub const Params = struct {
    dt: f32 = 0.1,
    gravity: f32 = 9.81,
    /// Pipe cross-section as a fraction of the cell area.
    pipe_area: f32 = 1.0,
    /// Bed friction: the fraction of last step's flux lost per step in a
    /// thin film. Deeper water loses less (friction / (1 + depth/friction_depth)),
    /// so channels carry far more than sheet-wash.
    friction: f32 = 0.05,
    friction_depth: f32 = 0.2,
    /// Rain, in depth per unit time, before the orographic factor.
    rain: f32 = 0.005,
    /// Sediment capacity constant (Kc).
    capacity: f32 = 1.0,
    /// Dissolving constant (Ks).
    dissolve: f32 = 0.1,
    /// Deposition constant (Kd) on land.
    deposit: f32 = 0.1,
    /// Evaporation constant (Ke), per unit time. The fraction removed per
    /// step, Ke x dt, is capped at `max_evaporation_step`.
    evaporation: f32 = 0.012,
    /// Lower bound on the local tilt, so flat ground still carries a little.
    min_tilt: f32 = 0.01,
    /// Capacity grows with speed x depth (the discharge per unit width, a
    /// stream-power measure) up to this depth; deeper, slower water (a lake,
    /// the sea) carries less.
    depth_ref: f32 = 0.5,
    /// Stream power below which nothing is picked up, so sheet-wash on
    /// hillsides and the plain does not rill or raise the whole map.
    threshold: f32 = 0.12,
    /// Most terrain one cell can lose in one step.
    max_erode: f32 = 0.08,
    /// Speed cap, a guard against the model's rare flux spikes.
    max_speed: f32 = 8.0,
    /// Steepest stable slope (rise over run) before material slumps.
    talus: f32 = 2.0,
    /// Fraction of the excess height moved per step by slumping.
    thermal: f32 = 0.08,
    /// Hillslope creep: linear diffusion of the terrain (soil creep in
    /// landscape-evolution models), in world units squared per unit time.
    /// It rounds off one-cell rills; channels, which keep cutting, survive.
    /// The per-step coefficient is capped at 0.24 - thermal, which keeps the
    /// explicit update stable.
    creep: f32 = 0.04,
    /// Sea level (world units).
    sea_level: f32 = 0.0,
    /// Fraction of the gap to sea level closed per step in sea cells (1 holds
    /// the surface exactly; less lets a river's momentum carry out to sea).
    sea_relax: f32 = 0.1,
    /// Smoothing of the measured discharge `flow` (fraction of the new value).
    flow_smooth: f32 = 0.02,
    /// Painted ground is not perfectly smooth: each dab is modulated by fixed
    /// value noise (broad swells) and finer ridged noise (sharp crests,
    /// rounded hollows), scaled by this, so a painted mountain has hollows
    /// for the rain to find (a perfect dome sheds water evenly).
    brush_texture: f32 = 0.4,
    /// Display: standing water in a filled pit deeper than this is a lake.
    lake_depth: f32 = 0.6,
    /// Display: a cell draining more than this area (world units squared)
    /// is a river...
    river_area: f32 = 300,
    /// ...drawn where the smoothed discharge per unit width passes this
    /// (half this to carry on downstream), or where it drains 30 times the
    /// area (see hydro.zig).
    river_flow: f32 = 0.8,
    /// In the sea, capacity falls off as exp(-depth / sea_depth)...
    sea_depth: f32 = 0.3,
    /// ...and suspended load settles at this rate (Kd in the sea).
    sea_deposit: f32 = 0.5,
    /// On land, grains take longer to settle through deeper water: Kd is
    /// divided by (1 + depth / settle_depth), so a deep channel carries its
    /// load across the plain while a thin sheet drops it. 0 turns this off.
    settle_depth: f32 = 0.3,
};

/// Largest fraction of a cell's water evaporated in one step.
pub const max_evaporation_step: f32 = 0.9;
/// Largest thermal + creep coefficient per step (explicit stability < 1/4).
pub const max_diffusion_step: f32 = 0.24;

/// A tunable parameter and the range the page (and the fuzz tests) accept.
pub const ParamSpec = struct { field: []const u8, lo: f32, hi: f32 };
/// Tunable parameters, by index.
pub const param_specs = [_]ParamSpec{
    .{ .field = "rain", .lo = 0, .hi = 0.2 },
    .{ .field = "capacity", .lo = 0, .hi = 10 },
    .{ .field = "dissolve", .lo = 0, .hi = 1 },
    .{ .field = "deposit", .lo = 0, .hi = 1 },
    .{ .field = "evaporation", .lo = 0, .hi = 5 },
    .{ .field = "dt", .lo = 0.001, .hi = 0.5 },
    .{ .field = "friction", .lo = 0, .hi = 1 },
    .{ .field = "min_tilt", .lo = 0, .hi = 1 },
    .{ .field = "depth_ref", .lo = 0.001, .hi = 10 },
    .{ .field = "max_erode", .lo = 0, .hi = 10 },
    .{ .field = "talus", .lo = 0.01, .hi = 100 },
    .{ .field = "thermal", .lo = 0, .hi = 0.2 },
    .{ .field = "pipe_area", .lo = 0.01, .hi = 100 },
    .{ .field = "max_speed", .lo = 0.01, .hi = 1000 },
    .{ .field = "threshold", .lo = 0, .hi = 100 },
    .{ .field = "sea_relax", .lo = 0.001, .hi = 1 },
    .{ .field = "flow_smooth", .lo = 0.001, .hi = 1 },
    .{ .field = "lake_depth", .lo = 0.001, .hi = 100 },
    .{ .field = "river_area", .lo = 1, .hi = 1.0e6 },
    .{ .field = "friction_depth", .lo = 0.001, .hi = 100 },
    .{ .field = "creep", .lo = 0, .hi = 2 },
    .{ .field = "sea_depth", .lo = 0.01, .hi = 100 },
    .{ .field = "sea_deposit", .lo = 0, .hi = 1 },
    .{ .field = "brush_texture", .lo = 0, .hi = 0.6 },
    .{ .field = "settle_depth", .lo = 0, .hi = 100 },
    .{ .field = "river_flow", .lo = 0, .hi = 1000 },
};

/// Set parameter `which` to `value`; false if unknown or out of range.
pub fn setParam(params: *Params, which: u32, value: f32) bool {
    if (!std.math.isFinite(value)) return false;
    inline for (param_specs, 0..) |spec, k| {
        if (which == k) {
            if (value < spec.lo or value > spec.hi) return false;
            @field(params, spec.field) = value;
            return true;
        }
    }
    return false;
}

/// Running totals, in "depth summed over cells" units (multiply by the
/// cell area for a volume). f64 so the books stay exact enough.
pub const Ledger = struct {
    rain: f64 = 0,
    evaporation: f64 = 0,
    sea_exchange: f64 = 0,
    /// Water that ran off the open land edges.
    edge_water: f64 = 0,
    brush_water: f64 = 0,
    brush_terrain: f64 = 0,
    /// Material picked up from the bed minus material laid down: what the
    /// suspended load gained from the terrain.
    pickup: f64 = 0,
    /// Material picked up plus material laid down (the scale of the traffic
    /// between bed and load, for judging how well the books balance).
    exchange: f64 = 0,
    /// Suspended sediment carried off the open land edges.
    edge_sediment: f64 = 0,
};

/// Number of f32 fields a simulation needs.
pub const field_count = 20;

pub fn cellsFor(n: u32) usize {
    const p: usize = n + 2;
    return p * p;
}

/// u32 scratch a simulation needs: receivers, queue links, the flood-fill
/// queue (n^2) and the bucket queue's heads and tails.
pub fn u32sFor(n: u32) usize {
    return 2 * cellsFor(n) + @as(usize, n) * n + 2 * hydro.bucket_count;
}

/// f32s for the river segment list (up to one segment per cell).
pub fn segFloatsFor(n: u32) usize {
    return @as(usize, n) * n * hydro.seg_floats;
}

pub const Error = error{ BadSize, BufferTooSmall };

pub const Sim = struct {
    n: u32,
    p: u32,
    cell: f32,
    params: Params,
    seed: u32,
    steps: u64,
    rng: u64,
    ledger: Ledger,
    /// Painting changed the ground: the sea mask and the survey are stale.
    sea_dirty: bool,
    survey_dirty: bool,
    /// Bumped by every drainage survey (the page re-uploads rivers on change).
    survey_version: u32,
    /// Steps since the last drainage survey.
    survey_age: u64,

    /// Terrain height (current and scratch; they swap).
    b: []f32,
    bn: []f32,
    /// Water depth.
    d: []f32,
    /// Suspended sediment (as a height of material).
    s: []f32,
    /// Sediment after erosion/deposition, before transport (scratch).
    s1: []f32,
    /// Sediment per unit of water volume (scratch).
    phi: []f32,
    /// Outflow flux to the left, right, top and bottom neighbours.
    fl: []f32,
    fr: []f32,
    ft: []f32,
    fb: []f32,
    /// 1 where the cell belongs to the sea connected to the map edge.
    sea: []f32,
    /// Terrain as surveyed (initial terrain plus painting); b - base is the
    /// net erosion (negative) or deposition (positive).
    base: []f32,
    /// Smoothed discharge per unit width (a measurement; tests use it).
    flow: []f32,
    /// Display field: > 1 on a lake (see hydro.zig).
    wet: []f32,
    /// Sediment capacity before smoothing (scratch).
    cap: []f32,
    /// Drainage survey (hydro.zig): pit-filled terrain, upstream area,
    /// signed distance to the coast, and scratch for the distance transform.
    filled: []f32,
    acc: []f32,
    dist: []f32,
    sx: []f32,
    sy: []f32,
    /// D8 receiver of each cell (hydro.zig).
    recv: []u32,
    /// Queue links, then each cell's main tributary (hydro.zig).
    next: []u32,
    /// Flood-fill queue for the sea mask; the survey's cell order.
    queue: []u32,
    order: []u32,
    heads: []u32,
    tails: []u32,
    /// Land cells in `order` after a survey.
    land: usize,
    /// River segments (hydro.seg_floats each) and how many there are.
    segs: []f32,
    seg_count: usize,

    /// `pool` must hold `field_count * cellsFor(n)` floats, `upool`
    /// `u32sFor(n)` entries and `segs` `segFloatsFor(n)`. n must be a
    /// multiple of `lanes` from 8 to 512.
    pub fn init(pool: []f32, upool: []u32, segs: []f32, n: u32, seed: u32) Error!Sim {
        if (n < 8 or n > 512 or n % lanes != 0) return error.BadSize;
        const cells = cellsFor(n);
        if (pool.len < field_count * cells or upool.len < u32sFor(n) or segs.len < segFloatsFor(n)) return error.BufferTooSmall;
        var fields: [field_count][]f32 = undefined;
        for (&fields, 0..) |*f, k| f.* = pool[k * cells .. (k + 1) * cells];
        const nn = @as(usize, n) * n;
        const queue = upool[2 * cells .. 2 * cells + nn];
        var sim = Sim{
            .n = n,
            .p = n + 2,
            .cell = world_size / @as(f32, @floatFromInt(n)),
            .params = .{},
            .seed = seed,
            .steps = 0,
            .rng = @as(u64, seed) *% 0x9E3779B97F4A7C15 +% 0x2545F4914F6CDD1D,
            .ledger = .{},
            .sea_dirty = true,
            .survey_dirty = true,
            .survey_version = 0,
            .survey_age = 0,
            .b = fields[0],
            .bn = fields[1],
            .d = fields[2],
            .s = fields[3],
            .s1 = fields[4],
            .phi = fields[5],
            .fl = fields[6],
            .fr = fields[7],
            .ft = fields[8],
            .fb = fields[9],
            .sea = fields[10],
            .base = fields[11],
            .flow = fields[12],
            .wet = fields[13],
            .cap = fields[14],
            .filled = fields[15],
            .acc = fields[16],
            .dist = fields[17],
            .sx = fields[18],
            .sy = fields[19],
            .recv = upool[0..cells],
            .next = upool[cells .. 2 * cells],
            .queue = queue,
            .order = queue,
            .heads = upool[2 * cells + nn ..][0..hydro.bucket_count],
            .tails = upool[2 * cells + nn + hydro.bucket_count ..][0..hydro.bucket_count],
            .land = 0,
            .segs = segs[0..segFloatsFor(n)],
            .seg_count = 0,
        };
        for (fields) |f| @memset(f, 0);
        sim.generate();
        return sim;
    }

    fn generate(self: *Sim) void {
        const n = self.n;
        const inv = 1.0 / @as(f32, @floatFromInt(n));
        for (0..n) |y| {
            const v = (@as(f32, @floatFromInt(y)) + 0.5) * inv;
            for (0..n) |x| {
                const u = (@as(f32, @floatFromInt(x)) + 0.5) * inv;
                const i = self.idx(@intCast(x), @intCast(y));
                self.b[i] = terrain.height(self.seed, u, v);
            }
        }
        // Ghost water is a wall; every other ghost field stays 0.
        self.forEachGhost(struct {
            fn f(s: *Sim, g: usize, _: usize) void {
                s.d[g] = wall;
                s.sea[g] = 1; // treated as "already visited" by the flood fill
            }
        }.f);
        self.refreshGhosts();
        @memcpy(self.base, self.b);
        self.updateSea();
        self.clampSea(lanes, 1);
        hydro.survey(self);
    }

    pub inline fn idx(self: *const Sim, x: u32, y: u32) usize {
        return (@as(usize, y) + 1) * self.p + x + 1;
    }

    /// Calls f(self, ghost_index, nearest_interior_index) for the ghost ring.
    fn forEachGhost(self: *Sim, comptime f: fn (*Sim, usize, usize) void) void {
        const p: usize = self.p;
        const n: usize = self.n;
        for (0..p) |x| {
            const cx = std.math.clamp(x, 1, n);
            f(self, x, p + cx); // top row
            f(self, (p - 1) * p + x, n * p + cx); // bottom row
        }
        for (1..p - 1) |y| {
            f(self, y * p, y * p + 1); // left column
            f(self, y * p + p - 1, y * p + n); // right column
        }
    }

    /// Ghost terrain copies the nearest edge cell. Ghost water is a wall
    /// beside the sea; beside land it puts the ghost's water surface where
    /// the edge slope, carried on one cell, would put the ground, so water
    /// runs off the map only where the ground falls away.
    pub fn refreshGhosts(self: *Sim) void {
        self.forEachGhost(struct {
            fn f(s: *Sim, g: usize, c: usize) void {
                s.b[g] = s.b[c];
            }
        }.f);
        const p: usize = self.p;
        const n: usize = self.n;
        for (1..n + 1) |k| {
            self.openEdge(k, p + k, 2 * p + k); // north
            self.openEdge((p - 1) * p + k, n * p + k, (n - 1) * p + k); // south
            self.openEdge(k * p, k * p + 1, k * p + 2); // west
            self.openEdge(k * p + p - 1, k * p + n, k * p + n - 1); // east
        }
    }

    inline fn openEdge(self: *Sim, ghost: usize, edge: usize, inner: usize) void {
        self.d[ghost] = if (self.sea[edge] > 0.5) wall else self.b[edge] - self.b[inner];
    }

    fn nextRandom(self: *Sim) f32 {
        // splitmix64
        self.rng +%= 0x9E3779B97F4A7C15;
        var z = self.rng;
        z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
        z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
        z ^= z >> 31;
        return @as(f32, @floatFromInt(z >> 40)) * (1.0 / 16777216.0);
    }

    // ------------------------------------------------------------------
    // One step
    // ------------------------------------------------------------------

    pub fn step(self: *Sim) void {
        self.stepLanes(lanes);
    }

    pub fn stepLanes(self: *Sim, comptime L: comptime_int) void {
        if (self.sea_dirty) self.settleSea(L);
        const storm = 0.4 + 1.2 * self.nextRandom(); // passing showers, mean 1
        self.rain(L, storm);
        self.flux(L);
        self.water(L);
        self.bookEdgeWater();
        self.erode(L);
        self.refreshGhosts(); // erode swapped in a buffer with stale ghosts
        self.transport(L);
        self.bookEdgeSediment();
        if (self.params.thermal > 0 or self.params.creep > 0) self.slump(L);
        self.refreshGhosts();
        self.steps += 1;
        self.survey_age += 1;
        if (self.steps % sea_every == 0) self.updateSea();
        self.clampSea(L, self.params.sea_relax);
    }

    /// Bring the sea mask up to date after painting, and re-run the drainage
    /// survey if painting changed the ground or `survey_every` steps have
    /// passed. The page calls this once per frame (not once per dab).
    pub fn settle(self: *Sim) void {
        if (self.sea_dirty) self.settleSea(lanes);
        if (self.surveyDue()) hydro.survey(self);
    }

    pub fn surveyDue(self: *const Sim) bool {
        return self.survey_dirty or self.survey_age >= survey_every;
    }

    fn settleSea(self: *Sim, comptime L: comptime_int) void {
        self.updateSea();
        self.clampSea(L, 1);
    }

    /// Water that left through the open land edges this step (the pipes
    /// pointing off the map), booked in depth-sum units.
    fn bookEdgeWater(self: *Sim) void {
        var out: f64 = 0;
        const n = self.n;
        for (0..n) |k| {
            const kk: u32 = @intCast(k);
            out += self.fl[self.idx(0, kk)];
            out += self.fr[self.idx(n - 1, kk)];
            out += self.ft[self.idx(kk, 0)];
            out += self.fb[self.idx(kk, n - 1)];
        }
        self.ledger.edge_water += out * self.params.dt / (self.cell * self.cell);
    }

    /// Suspended sediment carried off the map with that water.
    fn bookEdgeSediment(self: *Sim) void {
        var out: f64 = 0;
        const n = self.n;
        for (0..n) |k| {
            const kk: u32 = @intCast(k);
            const w = self.idx(0, kk);
            const e = self.idx(n - 1, kk);
            const t = self.idx(kk, 0);
            const b = self.idx(kk, n - 1);
            out += self.phi[w] * self.fl[w];
            out += self.phi[e] * self.fr[e];
            out += self.phi[t] * self.ft[t];
            out += self.phi[b] * self.fb[b];
        }
        self.ledger.edge_sediment += out * self.params.dt;
    }

    fn Vec(comptime L: comptime_int) type {
        return @Vector(L, f32);
    }

    inline fn ld(comptime L: comptime_int, a: []const f32, i: usize) Vec(L) {
        return a[i..][0..L].*;
    }

    inline fn st(comptime L: comptime_int, a: []f32, i: usize, v: Vec(L)) void {
        a[i..][0..L].* = v;
    }

    inline fn sp(comptime L: comptime_int, x: f32) Vec(L) {
        return @splat(x);
    }

    // Plain compare-and-select min/max. LLVM's @max/@min follow C's fmax
    // (NaN-ignoring), which WebAssembly SIMD has no instruction for, so they
    // get scalarised; a select lowers to f32x4 compare + bitselect.
    inline fn vmax(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        return @select(f32, a > b, a, b);
    }

    inline fn vmin(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
        return @select(f32, a < b, a, b);
    }

    /// exp(-x) for x >= 0, as 2^(-x log2 e): the integer part goes straight
    /// into the float's exponent bits and the fraction through a cubic
    /// (relative error under 1e-4). Plain SIMD arithmetic, where a real exp
    /// would be a scalar call per lane.
    inline fn expNeg(comptime L: comptime_int, x: Vec(L)) Vec(L) {
        const I = @Vector(L, i32);
        const y = vmax(-x * sp(L, std.math.log2e), sp(L, -126));
        const whole = @floor(y);
        const f = y - whole;
        const frac = sp(L, 1) + f * (sp(L, 0.6960656) + f * (sp(L, 0.2244943) + f * sp(L, 0.0794402)));
        const e: I = @as(I, @intFromFloat(whole)) + @as(I, @splat(127));
        const scale: Vec(L) = @bitCast(e << @as(@Vector(L, u5), @splat(23)));
        return frac * scale;
    }

    /// 1. Rain on land. More rain falls on high ground (orographic factor).
    fn rain(self: *Sim, comptime L: comptime_int, storm: f32) void {
        const V = Vec(L);
        const amount = self.params.dt * self.params.rain * storm;
        const zero = sp(L, 0);
        var total: f64 = 0;
        for (1..self.n + 1) |y| {
            var acc: V = zero;
            const row = y * self.p;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const b = ld(L, self.b, i);
                const oro = vmin(vmax(sp(L, 0.1) + b * sp(L, 1.5 / 40.0), sp(L, 0.1)), sp(L, 1.6));
                const add = @select(f32, ld(L, self.sea, i) > sp(L, 0.5), zero, oro * sp(L, amount));
                st(L, self.d, i, ld(L, self.d, i) + add);
                acc += add;
            }
            total += @reduce(.Add, acc);
        }
        self.ledger.rain += total;
    }

    /// 2. Outflow flux through the four virtual pipes, scaled so a cell never
    /// sends more water than it holds.
    fn flux(self: *Sim, comptime L: comptime_int) void {
        const P = self.params;
        const p: usize = self.p;
        const area = self.cell * self.cell;
        const k = sp(L, P.dt * P.gravity * P.pipe_area * self.cell); // dt*g*A/l with A = pipe_area*l^2
        const zero = sp(L, 0);
        const one = sp(L, 1);
        const fric = sp(L, P.friction);
        const inv_fd = sp(L, 1.0 / P.friction_depth);
        for (1..self.n + 1) |y| {
            const row = y * p;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const dc = ld(L, self.d, i);
                const h = ld(L, self.b, i) + dc;
                const keep = one - fric / (one + dc * inv_fd);
                const hl = ld(L, self.b, i - 1) + ld(L, self.d, i - 1);
                const hr = ld(L, self.b, i + 1) + ld(L, self.d, i + 1);
                const ht = ld(L, self.b, i - p) + ld(L, self.d, i - p);
                const hb = ld(L, self.b, i + p) + ld(L, self.d, i + p);
                const fl = vmax(zero, ld(L, self.fl, i) * keep + k * (h - hl));
                const fr = vmax(zero, ld(L, self.fr, i) * keep + k * (h - hr));
                const ft = vmax(zero, ld(L, self.ft, i) * keep + k * (h - ht));
                const fb = vmax(zero, ld(L, self.fb, i) * keep + k * (h - hb));
                const sum = fl + fr + ft + fb;
                const vol = dc * sp(L, area);
                const scale = vmin(sp(L, 1), vol / vmax(sum * sp(L, P.dt), sp(L, 1e-20)));
                st(L, self.fl, i, fl * scale);
                st(L, self.fr, i, fr * scale);
                st(L, self.ft, i, ft * scale);
                st(L, self.fb, i, fb * scale);
            }
        }
    }

    /// 3. Water update from the fluxes, the velocity field, and the local
    /// sediment capacity (stored for the erosion pass).
    fn water(self: *Sim, comptime L: comptime_int) void {
        const P = self.params;
        const p: usize = self.p;
        const l = self.cell;
        const area = l * l;
        const zero = sp(L, 0);
        const one = sp(L, 1);
        const dt = sp(L, P.dt);
        const inv_area = sp(L, 1.0 / area);
        const inv_2l = sp(L, 0.5 / l);
        for (1..self.n + 1) |y| {
            const row = y * p;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const fl = ld(L, self.fl, i);
                const fr = ld(L, self.fr, i);
                const ft = ld(L, self.ft, i);
                const fb = ld(L, self.fb, i);
                const fr_left = ld(L, self.fr, i - 1);
                const fl_right = ld(L, self.fl, i + 1);
                const fb_up = ld(L, self.fb, i - p);
                const ft_down = ld(L, self.ft, i + p);

                const inflow = fr_left + fl_right + fb_up + ft_down;
                const outflow = fl + fr + ft + fb;
                const d1 = ld(L, self.d, i);
                const d2 = vmax(zero, d1 + dt * (inflow - outflow) * inv_area);

                // Velocity from the mean flux through the cell.
                const wx = (fr_left - fl + fr - fl_right) * sp(L, 0.5);
                const wy = (fb_up - ft + fb - ft_down) * sp(L, 0.5);
                const denom = vmax((d1 + d2) * sp(L, 0.5 * l), sp(L, 1e-4 * l));
                const u = wx / denom;
                const v = wy / denom;
                const speed = vmin(@sqrt(u * u + v * v), sp(L, P.max_speed));

                // Local tilt from the terrain gradient (central differences).
                const b = ld(L, self.b, i);
                const gx = (ld(L, self.b, i + 1) - ld(L, self.b, i - 1)) * inv_2l;
                const gy = (ld(L, self.b, i + p) - ld(L, self.b, i - p)) * inv_2l;
                const g2 = gx * gx + gy * gy;
                const sin_a = @sqrt(g2 / (one + g2));
                const tilt = vmax(sin_a, sp(L, P.min_tilt));
                const stream = tilt * speed * vmin(d2, sp(L, P.depth_ref));
                st(L, self.cap, i, sp(L, P.capacity) * vmax(zero, stream - sp(L, P.threshold)));

                // Discharge per unit width, smoothed over steps, for drawing.
                const q = @sqrt(wx * wx + wy * wy) * sp(L, 1.0 / l);
                const fo = ld(L, self.flow, i);
                st(L, self.flow, i, fo + (q - fo) * sp(L, P.flow_smooth));

                st(L, self.d, i, d2);
                // The volume the fluxes were scaled against, for transport.
                st(L, self.phi, i, vmax(d1 * sp(L, area), sp(L, 1e-12)));
                _ = b;
            }
        }
    }

    /// 4. Erosion or deposition towards the sediment capacity, taken as a
    /// 3x3 binomial average: a channel narrower than a few cells cannot
    /// out-compete its banks, which stops one-cell rills without blurring
    /// the terrain itself. Writes the new terrain into the scratch buffer
    /// and swaps.
    ///
    /// Sea level is the base level: nothing is picked up below it, so a
    /// river cannot scour a drowned estuary. In the sea, capacity dies away
    /// with depth and the load settles fast, so rivers drop it at the mouth.
    fn erode(self: *Sim, comptime L: comptime_int) void {
        const V = Vec(L);
        const P = self.params;
        const p: usize = self.p;
        const zero = sp(L, 0);
        const level = sp(L, P.sea_level);
        const inv_sea_depth = sp(L, 1.0 / P.sea_depth);
        var pickup: f64 = 0;
        var exchange: f64 = 0;
        for (1..self.n + 1) |y| {
            const row = y * p;
            var acc_e: V = zero;
            var acc_a: V = zero;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const c = self.cap;
                const edges = ld(L, c, i - 1) + ld(L, c, i + 1) + ld(L, c, i - p) + ld(L, c, i + p);
                const corners = ld(L, c, i - p - 1) + ld(L, c, i - p + 1) + ld(L, c, i + p - 1) + ld(L, c, i + p + 1);
                const blurred = (ld(L, c, i) * sp(L, 4) + edges * sp(L, 2) + corners) * sp(L, 1.0 / 16.0);
                const in_sea = ld(L, self.sea, i) > sp(L, 0.5);
                const capacity = @select(f32, in_sea, blurred * expNeg(L, ld(L, self.d, i) * inv_sea_depth), blurred);

                const depth = ld(L, self.d, i);
                const kd_land = if (P.settle_depth > 0) sp(L, P.deposit) / (sp(L, 1) + depth * sp(L, 1.0 / P.settle_depth)) else sp(L, P.deposit);
                const kd = @select(f32, in_sea, sp(L, P.sea_deposit), kd_land);
                const b = ld(L, self.b, i);
                const s0 = ld(L, self.s, i);
                const diff = capacity - s0;
                // e > 0: pick up material (never below sea level); e < 0: lay it down.
                const room = vmax(zero, b - level);
                const pick = vmin(vmin(sp(L, P.dissolve) * diff, sp(L, P.max_erode)), room);
                const e = @select(f32, diff > zero, pick, kd * diff);
                const s1 = s0 + e;
                st(L, self.bn, i, b - e);
                st(L, self.s1, i, s1);
                // Sediment per unit volume of the water that the fluxes move.
                st(L, self.phi, i, s1 / ld(L, self.phi, i));
                acc_e += e;
                acc_a += @abs(e);
            }
            pickup += @reduce(.Add, acc_e);
            exchange += @reduce(.Add, acc_a);
        }
        self.ledger.pickup += pickup;
        self.ledger.exchange += exchange;
        std.mem.swap([]f32, &self.b, &self.bn);
    }

    /// 5 + 6. Move suspended sediment with the water (donor cell: each pipe
    /// carries its source cell's concentration), then evaporate.
    fn transport(self: *Sim, comptime L: comptime_int) void {
        const V = Vec(L);
        const P = self.params;
        const p: usize = self.p;
        const zero = sp(L, 0);
        const dt = sp(L, P.dt);
        const keep = sp(L, 1.0 - @min(P.evaporation * P.dt, max_evaporation_step));
        var evaporated: f64 = 0;
        for (1..self.n + 1) |y| {
            const row = y * p;
            var acc: V = zero;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const phi = ld(L, self.phi, i);
                const out = phi * ld(L, self.fl, i) + phi * ld(L, self.fr, i) +
                    phi * ld(L, self.ft, i) + phi * ld(L, self.fb, i);
                const in = ld(L, self.phi, i - 1) * ld(L, self.fr, i - 1) +
                    ld(L, self.phi, i + 1) * ld(L, self.fl, i + 1) +
                    ld(L, self.phi, i - p) * ld(L, self.fb, i - p) +
                    ld(L, self.phi, i + p) * ld(L, self.ft, i + p);
                st(L, self.s, i, vmax(zero, ld(L, self.s1, i) + dt * (in - out)));

                const d = ld(L, self.d, i);
                const dn = d * keep;
                acc += d - dn;
                st(L, self.d, i, dn);
            }
            evaporated += @reduce(.Add, acc);
        }
        self.ledger.evaporation += evaporated;
    }

    /// 7. Thermal weathering: where neighbours differ by more than the talus
    /// height, move a fraction of the excess downhill. The per-edge transfer
    /// is an odd function of the height difference, so what one cell loses
    /// its neighbour gains.
    fn slump(self: *Sim, comptime L: comptime_int) void {
        const V = Vec(L);
        const p: usize = self.p;
        const t = sp(L, self.params.talus * self.cell);
        const k = sp(L, self.params.thermal);
        // Explicit diffusion: stable while thermal + creep per step stays
        // under 1/4 (each cell trades with four neighbours).
        const c_max = @max(0, max_diffusion_step - self.params.thermal);
        const c = sp(L, @min(self.params.creep * self.params.dt / (self.cell * self.cell), c_max));
        const zero = sp(L, 0);
        for (1..self.n + 1) |y| {
            const row = y * p;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const b = ld(L, self.b, i);
                const nbrs = [4]V{ ld(L, self.b, i - 1), ld(L, self.b, i + 1), ld(L, self.b, i - p), ld(L, self.b, i + p) };
                var moved: V = zero;
                inline for (nbrs) |nb| {
                    const dh = b - nb;
                    moved += k * (vmax(zero, dh - t) - vmax(zero, -dh - t)) + c * dh;
                }
                st(L, self.bn, i, b - moved);
            }
        }
        std.mem.swap([]f32, &self.b, &self.bn);
    }

    /// Flood-fill the sea from every edge cell below sea level.
    pub fn updateSea(self: *Sim) void {
        const n: usize = self.n;
        const p: usize = self.p;
        const sl = self.params.sea_level;
        for (1..n + 1) |y| @memset(self.sea[y * p + 1 .. y * p + 1 + n], 0);
        var tail: usize = 0;
        const Seed = struct {
            fn push(s: *Sim, i: usize, t: *usize, level: f32) void {
                if (s.sea[i] == 0 and s.b[i] < level) {
                    s.sea[i] = 1;
                    s.queue[t.*] = @intCast(i);
                    t.* += 1;
                }
            }
        };
        for (0..n) |k| {
            const x: u32 = @intCast(k);
            Seed.push(self, self.idx(x, 0), &tail, sl);
            Seed.push(self, self.idx(x, self.n - 1), &tail, sl);
            Seed.push(self, self.idx(0, x), &tail, sl);
            Seed.push(self, self.idx(self.n - 1, x), &tail, sl);
        }
        var head: usize = 0;
        while (head < tail) : (head += 1) {
            const i: usize = self.queue[head];
            // Ghost cells have sea = 1, so they are never entered.
            Seed.push(self, i - 1, &tail, sl);
            Seed.push(self, i + 1, &tail, sl);
            Seed.push(self, i - p, &tail, sl);
            Seed.push(self, i + p, &tail, sl);
        }
        self.sea_dirty = false;
        self.refreshGhosts(); // ghost water depends on the sea beside it
    }

    /// Pull every sea cell's water surface towards sea level (relax = 1
    /// holds it exactly), booking the water that takes as sea exchange.
    pub fn clampSea(self: *Sim, comptime L: comptime_int, relax: f32) void {
        const V = Vec(L);
        const zero = sp(L, 0);
        const level = sp(L, self.params.sea_level);
        const k = sp(L, relax);
        var total: f64 = 0;
        for (1..self.n + 1) |y| {
            const row = y * self.p;
            var acc: V = zero;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const d = ld(L, self.d, i);
                const b = ld(L, self.b, i);
                const target = vmax(zero, level - b);
                const is_sea = ld(L, self.sea, i) > sp(L, 0.5);
                const dn = @select(f32, is_sea, d + (target - d) * k, d);
                acc += dn - d;
                st(L, self.d, i, dn);
            }
            total += @reduce(.Add, acc);
        }
        self.ledger.sea_exchange += total;
    }

    // ------------------------------------------------------------------
    // Painting
    // ------------------------------------------------------------------

    /// Raise (strength > 0) or lower (strength < 0) the terrain around grid
    /// position (cx, cy) with a smooth falloff. Positions are in cells
    /// (0..n); anything outside the map is ignored. Returns the terrain
    /// volume actually added, in depth-sum units.
    pub fn brush(self: *Sim, cx: f32, cy: f32, radius: f32, strength: f32) f64 {
        if (!std.math.isFinite(cx) or !std.math.isFinite(cy) or
            !std.math.isFinite(radius) or !std.math.isFinite(strength)) return 0;
        const r = std.math.clamp(radius, 0.5, max_brush_radius);
        const k = std.math.clamp(strength, -max_brush_strength, max_brush_strength);
        const nf: f32 = @floatFromInt(self.n);
        const x0f = @max(@floor(cx - r), 0);
        const x1f = @min(@ceil(cx + r), nf - 1);
        const y0f = @max(@floor(cy - r), 0);
        const y1f = @min(@ceil(cy + r), nf - 1);
        if (x0f > x1f or y0f > y1f) return 0;
        const x0: u32 = @intFromFloat(x0f);
        const x1: u32 = @intFromFloat(x1f);
        const y0: u32 = @intFromFloat(y0f);
        const y1: u32 = @intFromFloat(y1f);
        const inv_r2 = 1.0 / (r * r);
        var added: f64 = 0;
        var shed_total: f64 = 0;
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const q = (dx * dx + dy * dy) * inv_r2;
                if (q >= 1) continue;
                const xf: f32 = @floatFromInt(x);
                const yf: f32 = @floatFromInt(y);
                const grain = self.brushGrain(xf, yf);
                const w = (1 - q) * (1 - q) * grain;
                const i = self.idx(x, y);
                const old = self.b[i];
                const nb = std.math.clamp(old + k * w, min_height, max_height);
                const applied = nb - old;
                self.b[i] = nb;
                self.base[i] += applied;
                added += applied;
                // Rising ground pushes up through standing water: the water
                // surface stays put, so the depth shrinks.
                if (applied > 0 and self.d[i] > 0) {
                    const shed = @min(self.d[i], applied);
                    self.d[i] -= shed;
                    shed_total -= shed;
                }
            }
        }
        self.ledger.brush_terrain += added;
        self.ledger.brush_water += shed_total;
        self.refreshGhosts();
        // The sea mask and the drainage survey catch up in settle() (once a
        // frame on the page) or at the next step, not after every dab.
        self.sea_dirty = true;
        self.survey_dirty = true;
        return added;
    }

    /// The brush texture at cell (x, y): 1 + t x (0.6 swell + ridges - 0.5),
    /// with t = brush_texture. The swell is broad value noise in [-1, 1];
    /// the ridges are finer ridged noise, (1 - |noise|)^2 in [0, 1]: sharp
    /// crests along the noise's zero lines with rounded hollows between, for
    /// the rain to gather in. So a dab lies between (1 - 1.1 t) and
    /// (1 + 1.1 t) of the smooth profile.
    pub fn brushGrain(self: *const Sim, x: f32, y: f32) f32 {
        const t = self.params.brush_texture;
        if (t == 0) return 1;
        const swell = terrain.valueNoise(self.seed +% 977, x * texture_freq, y * texture_freq);
        const r = 1.0 - @abs(terrain.valueNoise(self.seed +% 1543, x * ridge_freq, y * ridge_freq));
        return 1.0 + t * (0.6 * swell + r * r - 0.5);
    }

    // ------------------------------------------------------------------
    // Accounting
    // ------------------------------------------------------------------

    pub const Totals = struct { water: f64, terrain: f64, sediment: f64 };

    pub fn totals(self: *const Sim) Totals {
        var t = Totals{ .water = 0, .terrain = 0, .sediment = 0 };
        for (1..self.n + 1) |y| {
            const row = y * self.p;
            for (row + 1..row + 1 + self.n) |i| {
                t.water += self.d[i];
                t.terrain += self.b[i];
                t.sediment += self.s[i];
            }
        }
        return t;
    }

    /// River segments from the last survey: x0, y0, x1, y1 in grid cells,
    /// then upstream area over river_area.
    pub fn rivers(self: *const Sim) []const f32 {
        return self.segs[0 .. self.seg_count * hydro.seg_floats];
    }

    /// Lowest and highest interior terrain.
    pub fn heightRange(self: *const Sim) [2]f32 {
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        for (1..self.n + 1) |y| {
            const row = y * self.p;
            for (self.b[row + 1 .. row + 1 + self.n]) |h| {
                lo = @min(lo, h);
                hi = @max(hi, h);
            }
        }
        return .{ lo, hi };
    }
};
