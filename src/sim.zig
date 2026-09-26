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
//!
//! Every change of water and material is booked (rain, evaporation, sea
//! exchange, painting), so tests can check the accounting after each step.
//!
//! Layout: every field is an (n+2) x (n+2) array of f32. The outer ring is a
//! ghost ring. Ghost terrain copies the nearest edge cell (so slopes and
//! slumping see a flat continuation) and ghost water is a very tall wall (so
//! no water ever flows off the map). Interior rows are n cells wide, and n is
//! a multiple of the SIMD width, so the hot loops never need a scalar tail.
//!
//! No allocation happens after `init`: all buffers are handed in.

const std = @import("std");
const terrain = @import("terrain.zig");

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

/// Spatial frequency (per cell) of the brush texture.
const texture_freq: f32 = 0.09;

/// How often (in steps) the connected sea is re-flooded from the map edge.
pub const sea_every: u64 = 4;

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
    /// Deposition constant (Kd).
    deposit: f32 = 0.1,
    /// Evaporation constant (Ke), per unit time.
    evaporation: f32 = 0.012,
    /// Lower bound on the local tilt, so flat ground still carries sediment.
    min_tilt: f32 = 0.03,
    /// Capacity grows with speed x depth (the discharge per unit width, a
    /// stream-power measure) up to this depth; deeper, slower water (a lake,
    /// the sea) carries less.
    depth_ref: f32 = 0.5,
    /// Stream power below which nothing is picked up, so gentle sheet-wash
    /// on hillsides does not rill the whole map.
    threshold: f32 = 0.05,
    /// Most terrain one cell can lose in one step.
    max_erode: f32 = 0.08,
    /// Speed cap, a guard against the model's rare flux spikes.
    max_speed: f32 = 8.0,
    /// Steepest stable slope (rise over run) before material slumps.
    talus: f32 = 1.2,
    /// Fraction of the excess height moved per step by slumping.
    thermal: f32 = 0.08,
    /// Hillslope creep: linear diffusion of the terrain (soil creep in
    /// landscape-evolution models), in world units squared per unit time.
    /// It rounds off one-cell rills; channels, which keep cutting, survive.
    creep: f32 = 0.04,
    /// Sea level (world units).
    sea_level: f32 = 0.0,
    /// Fraction of the gap to sea level closed per step in sea cells (1 holds
    /// the surface exactly; less lets a river's momentum carry out to sea).
    sea_relax: f32 = 0.1,
    /// Smoothing of the displayed discharge (fraction of the new value).
    flow_smooth: f32 = 0.02,
    /// Painted ground is not perfectly smooth: each dab is modulated by up to
    /// this fraction with fixed value noise, so a painted mountain has
    /// hollows for the rain to find (a perfect dome sheds water evenly and
    /// never gullies).
    brush_texture: f32 = 0.35,
    /// Display: standing water deeper than this is drawn as water...
    lake_depth: f32 = 1.5,
    /// ...and so is any cell whose smoothed discharge exceeds this.
    river_flow: f32 = 1.5,
};

/// Per-step running totals, in "depth summed over cells" units (multiply by
/// the cell area for a volume). f64 so the books stay exact enough.
pub const Ledger = struct {
    rain: f64 = 0,
    evaporation: f64 = 0,
    sea_exchange: f64 = 0,
    brush_water: f64 = 0,
    brush_terrain: f64 = 0,
};

/// Number of f32 fields a simulation needs.
pub const field_count = 15;

pub fn cellsFor(n: u32) usize {
    const p: usize = n + 2;
    return p * p;
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
    sea_dirty: bool,

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
    /// Smoothed discharge per unit width (for drawing rivers).
    flow: []f32,
    /// Display field: the cell is drawn as water where wet > 1.
    wet: []f32,
    /// Sediment capacity before smoothing (scratch).
    cap: []f32,
    /// Flood-fill queue for the sea mask.
    queue: []u32,

    /// `pool` must hold `field_count * cellsFor(n)` floats and `queue`
    /// `n * n` entries. n must be a positive multiple of `lanes`, at most 512.
    pub fn init(pool: []f32, queue: []u32, n: u32, seed: u32) Error!Sim {
        if (n < 8 or n > 512 or n % lanes != 0) return error.BadSize;
        const cells = cellsFor(n);
        if (pool.len < field_count * cells or queue.len < @as(usize, n) * n) return error.BufferTooSmall;
        var fields: [field_count][]f32 = undefined;
        for (&fields, 0..) |*f, k| f.* = pool[k * cells .. (k + 1) * cells];
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
            .queue = queue[0 .. @as(usize, n) * n],
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

    /// Ghost terrain copies the nearest edge cell.
    pub fn refreshGhosts(self: *Sim) void {
        self.forEachGhost(struct {
            fn f(s: *Sim, g: usize, c: usize) void {
                s.b[g] = s.b[c];
            }
        }.f);
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
        const storm = 0.4 + 1.2 * self.nextRandom(); // passing showers, mean 1
        self.rain(L, storm);
        self.flux(L);
        self.water(L);
        self.erode(L);
        self.refreshGhosts(); // erode swapped in a buffer with stale ghosts
        self.transport(L);
        if (self.params.thermal > 0 or self.params.creep > 0) self.slump(L);
        self.refreshGhosts();
        self.steps += 1;
        if (self.sea_dirty or self.steps % sea_every == 0) self.updateSea();
        self.clampSea(L, self.params.sea_relax);
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
    fn erode(self: *Sim, comptime L: comptime_int) void {
        const P = self.params;
        const p: usize = self.p;
        const zero = sp(L, 0);
        for (1..self.n + 1) |y| {
            const row = y * p;
            var x: usize = 1;
            while (x <= self.n) : (x += L) {
                const i = row + x;
                const c = self.cap;
                const edges = ld(L, c, i - 1) + ld(L, c, i + 1) + ld(L, c, i - p) + ld(L, c, i + p);
                const corners = ld(L, c, i - p - 1) + ld(L, c, i - p + 1) + ld(L, c, i + p - 1) + ld(L, c, i + p + 1);
                const capacity = (ld(L, c, i) * sp(L, 4) + edges * sp(L, 2) + corners) * sp(L, 1.0 / 16.0);
                const s0 = ld(L, self.s, i);
                const diff = capacity - s0;
                // e > 0: pick up material; e < 0: lay it down.
                const e = @select(f32, diff > zero, vmin(sp(L, P.dissolve) * diff, sp(L, P.max_erode)), sp(L, P.deposit) * diff);
                const s1 = s0 + e;
                st(L, self.bn, i, ld(L, self.b, i) - e);
                st(L, self.s1, i, s1);
                // Sediment per unit volume of the water that the fluxes move.
                st(L, self.phi, i, s1 / ld(L, self.phi, i));
            }
        }
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
        const keep = sp(L, 1.0 - P.evaporation * P.dt);
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
        // Explicit diffusion: stable while the per-step coefficient is < 1/4.
        const c = sp(L, @min(self.params.creep * self.params.dt / (self.cell * self.cell), 0.2));
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
    }

    /// Pull every sea cell's water surface towards sea level (relax = 1
    /// holds it exactly), booking the water that takes as sea exchange. Also
    /// fills the display field `wet`.
    pub fn clampSea(self: *Sim, comptime L: comptime_int, relax: f32) void {
        const V = Vec(L);
        const zero = sp(L, 0);
        const level = sp(L, self.params.sea_level);
        const k = sp(L, relax);
        const inv_lake = sp(L, 1.0 / self.params.lake_depth);
        const inv_river = sp(L, 1.0 / self.params.river_flow);
        const p: usize = self.p;
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
                // Drawn as water where wet > 1: strong flow anywhere, or deep
                // standing water off the sea (the page draws the sea itself
                // from the sea mask and the sea-level contour).
                // Flow, lightly blurred (3x3 binomial) so drawn rivers don't
                // fray into the model's cell-scale flicker.
                const fp = self.flow;
                const edges = ld(L, fp, i - 1) + ld(L, fp, i + 1) + ld(L, fp, i - p) + ld(L, fp, i + p);
                const corners = ld(L, fp, i - p - 1) + ld(L, fp, i - p + 1) + ld(L, fp, i + p - 1) + ld(L, fp, i + p + 1);
                const blurred = (ld(L, fp, i) * sp(L, 4) + edges * sp(L, 2) + corners) * sp(L, 1.0 / 16.0);
                const flow = blurred * inv_river;
                st(L, self.wet, i, @select(f32, is_sea, flow, vmax(dn * inv_lake, flow)));
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
                const grain = 1.0 + self.params.brush_texture *
                    terrain.valueNoise(self.seed +% 977, xf * texture_freq, yf * texture_freq);
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
        self.updateSea();
        self.clampSea(lanes, 1);
        return added;
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
