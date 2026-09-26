//! The drainage survey: which way the water runs, where the rivers are, and
//! how far each cell is from the coast. It is for drawing only; the physics
//! in sim.zig never reads it. The kernel runs it every `survey_every` steps
//! and after painting.
//!
//!  1. Fill pits with the Priority-Flood of Barnes, Lehman & Mulla (2014),
//!     "Priority-Flood: An optimal depression-filling and watershed-labeling
//!     algorithm for digital elevation models", Computers & Geosciences 62,
//!     117-127. The outlets are the sea's shore and the open land edges of
//!     the map. The priority queue is a bucket queue over heights quantised
//!     to 1/`q_per_unit` of a unit, so the fill runs in linear time; within a
//!     bucket cells leave in the order they arrived, so a flat drains towards
//!     the outlet that reached it first.
//!  2. Give every land cell one receiver (D8): the neighbour with the
//!     steepest drop on the filled surface, counting only neighbours in a
//!     strictly lower bucket; on flats and in filled pits, the cell the flood
//!     reached it from. Every receiver left the queue before its donor, so the
//!     receivers form a tree rooted at the outlets and the queue order is a
//!     topological order.
//!  3. Accumulate upstream area down that tree (reverse queue order).
//!  4. Lakes: standing water in a filled pit deeper than `lake_depth`.
//!  5. River segments, from each river cell's node to its receiver's node.
//!     A river cell drains more than `river_area`; small streams are drawn
//!     only where the simulated water really runs (discharge above
//!     `river_flow` to start a stream, half that to keep it going), so a
//!     stream can fade out on a fan instead of ruling a straight line down a
//!     plain it only trickles across. Rivers draining `big_river` times the
//!     threshold are always drawn, so every trunk reaches the sea. Nodes are
//!     cell centres pulled a quarter of the way towards the receiver and the
//!     main tributary, which rounds off the D8 staircase while keeping every
//!     segment joined to the next.
//!  6. Signed distance to the coastline (positive on land, world units), by
//!     two-pass "dead reckoning" (Grevera 2004, "The dead reckoning signed
//!     distance transform", CVIU 95), seeded with the sea-level crossing of
//!     the terrain so the offsets follow the smooth coast the page draws.

const std = @import("std");
const sim_mod = @import("sim.zig");
const Sim = sim_mod.Sim;

/// Height quantisation of the bucket queue: 1/128 unit (about 16 cm at the
/// page's 20 m per unit).
pub const q_per_unit: f32 = 128;
const key_floor: f32 = sim_mod.min_height - 8;
const key_ceiling: f32 = sim_mod.max_height + 8;
pub const bucket_count: usize = @intFromFloat((key_ceiling - key_floor) * q_per_unit + 1);

/// Receiver markers (anything else is a cell index).
pub const unseen: u32 = 0xFFFF_FFFF;
pub const sea_cell: u32 = 0xFFFF_FFFE;
pub const ghost_cell: u32 = 0xFFFF_FFFD;
/// Distances beyond this many world units from the coast are not measured;
/// they read as +/- `far_units`.
pub const band_units: f32 = 64;
pub const far_units: f32 = 1.0e4;
/// Rivers draining this many times `river_area` are always drawn.
pub const big_river: f32 = 30;
/// Floats per river segment: x0, y0, x1, y1 (grid cells), upstream area / river_area.
pub const seg_floats = 5;

// Compare-and-select rather than @min/@max, which follow C's fmin/fmax
// (NaN-ignoring) and cost a call on wasm (see sim.zig's vmin/vmax).
inline fn smax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

inline fn key(h: f32) u32 {
    const c = if (h < key_floor) key_floor else if (h > key_ceiling) key_ceiling else h;
    const k: u32 = @intFromFloat((c - key_floor) * q_per_unit);
    return if (k < bucket_count) k else bucket_count - 1;
}

const Queue = struct {
    heads: []u32,
    tails: []u32,
    next: []u32,

    fn push(q: *Queue, i: u32, k: u32) void {
        q.next[i] = unseen;
        if (q.heads[k] == unseen) q.heads[k] = i else q.next[q.tails[k]] = i;
        q.tails[k] = i;
    }
};

/// A land cell's receiver is another land cell (not the sea or off the map).
inline fn onLand(s: *const Sim, r: u32) bool {
    return r < sea_mod_limit and s.recv[r] < sea_mod_limit;
}
const sea_mod_limit: u32 = ghost_cell;

/// Offsets of the 8 neighbours and their distances (in cells).
fn neighbours(p: usize) [8]isize {
    const pi: isize = @intCast(p);
    return .{ -1, 1, -pi, pi, -pi - 1, -pi + 1, pi - 1, pi + 1 };
}
const nbr_dist = [8]f32{ 1, 1, 1, 1, std.math.sqrt2, std.math.sqrt2, std.math.sqrt2, std.math.sqrt2 };

inline fn at(i: usize, o: isize) usize {
    return @intCast(@as(isize, @intCast(i)) + o);
}

pub fn survey(s: *Sim) void {
    fill(s);
    receivers(s);
    accumulate(s);
    lakes(s);
    rivers(s);
    coastDistance(s);
    s.survey_version +%= 1;
    s.survey_dirty = false;
    s.survey_age = 0;
}

/// 1. Priority-Flood. Leaves the pop order of the land cells in s.order[0..s.land].
fn fill(s: *Sim) void {
    const n: usize = s.n;
    const p: usize = s.p;
    const sl = s.params.sea_level;
    const nb = neighbours(p);
    var q = Queue{ .heads = s.heads, .tails = s.tails, .next = s.next };
    @memset(q.heads, unseen);
    // s.sx holds each cell's bucket (as f32, exact) for receivers().
    const sea_key: f32 = @floatFromInt(key(sl));
    // Ghost ring: never entered. Sea: an outlet at sea level. Land: unseen.
    @memset(s.recv, ghost_cell);
    for (1..n + 1) |y| {
        for (y * p + 1..y * p + 1 + n) |i| {
            s.filled[i] = s.b[i];
            s.recv[i] = if (s.sea[i] > 0.5) sea_cell else unseen;
            s.sx[i] = sea_key;
        }
    }
    // Seeds: sea cells on the shore, and land cells on the map's edge.
    for (1..n + 1) |y| {
        for (y * p + 1..y * p + 1 + n) |i| {
            if (s.recv[i] == sea_cell) {
                inline for (nb) |o| {
                    if (s.recv[at(i, o)] == unseen) {
                        s.filled[i] = sl;
                        q.push(@intCast(i), key(sl));
                        break;
                    }
                }
            } else {
                const x = i - y * p;
                if (x == 1 or x == n or y == 1 or y == n) {
                    // Parent: the ghost cell straight off the map (an edge outlet).
                    const off: usize = if (y == 1) i - p else if (y == n) i + p else if (x == 1) i - 1 else i + 1;
                    const ki = key(s.b[i]);
                    s.recv[i] = @intCast(off);
                    s.sx[i] = @floatFromInt(ki);
                    q.push(@intCast(i), ki);
                }
            }
        }
    }
    var land: usize = 0;
    var k: usize = 0;
    while (k < bucket_count) : (k += 1) {
        while (q.heads[k] != unseen) {
            const c: usize = q.heads[k];
            q.heads[k] = q.next[c];
            const fc = s.filled[c];
            if (s.recv[c] != sea_cell) {
                s.order[land] = @intCast(c);
                land += 1;
            }
            inline for (nb) |o| {
                const j = at(c, o);
                if (s.recv[j] == unseen) {
                const f = smax(s.b[j], fc);
                const kj = key(f);
                s.filled[j] = f;
                s.recv[j] = @intCast(c);
                s.sx[j] = @floatFromInt(kj);
                q.push(@intCast(j), kj);
                }
            }
        }
    }
    s.land = land;
}

/// 2. Steepest descent on the filled surface, to neighbours in a lower
/// bucket (which all left the queue earlier); otherwise keep the flood parent.
/// Row by row for cache locality: the order does not matter here.
fn receivers(s: *Sim) void {
    const p: usize = s.p;
    const n: usize = s.n;
    const sl = s.params.sea_level;
    const nb = neighbours(p);
    for (1..n + 1) |y| {
        for (1..n + 1) |x| {
            const c = y * p + x;
            if (s.recv[c] >= ghost_cell) continue; // sea
            const fc = s.filled[c];
            const kc = s.sx[c];
            var best: u32 = s.recv[c];
            var best_slope: f32 = 0;
            inline for (nb, nbr_dist) |o, dist| {
                const j = at(c, o);
                const rj = s.recv[j];
                if (rj != ghost_cell and s.sx[j] < kc) {
                    const fj = if (rj == sea_cell) sl else s.filled[j];
                    const slope = (fc - fj) * (1.0 / dist);
                    if (slope > best_slope) {
                        best_slope = slope;
                        best = @intCast(j);
                    }
                }
            }
            // Off the map: the ground beyond an open edge continues the slope.
            if (x == 1 or x == n or y == 1 or y == n) {
                const edges = [4]struct { on: bool, off: usize, back: usize }{
                    .{ .on = x == 1, .off = c - 1, .back = c + 1 },
                    .{ .on = x == n, .off = c + 1, .back = c - 1 },
                    .{ .on = y == 1, .off = c - p, .back = c + p },
                    .{ .on = y == n, .off = c + p, .back = c - p },
                };
                for (edges) |e| {
                    if (!e.on) continue;
                    const beyond = 2 * s.b[c] - s.b[e.back];
                    if (@as(f32, @floatFromInt(key(beyond))) >= kc) continue;
                    const slope = fc - beyond;
                    if (slope > best_slope) {
                        best_slope = slope;
                        best = @intCast(e.off);
                    }
                }
            }
            s.recv[c] = best;
        }
    }
}

/// 3. Upstream area in world units squared, including the cell itself.
fn accumulate(s: *Sim) void {
    @memset(s.acc, 0);
    const area = s.cell * s.cell;
    for (s.order[0..s.land]) |c| s.acc[c] = area;
    var k = s.land;
    while (k > 0) {
        k -= 1;
        const c = s.order[k];
        const r = s.recv[c];
        if (onLand(s, r)) s.acc[r] += s.acc[c];
    }
}

/// 4. The display field `wet`: > 1 where a filled pit holds standing water
/// deeper than lake_depth (a lake). Rivers are drawn as lines, not from here.
fn lakes(s: *Sim) void {
    const inv = 1.0 / s.params.lake_depth;
    @memset(s.wet, 0);
    for (s.order[0..s.land]) |c| {
        const pit = s.filled[c] - s.b[c];
        s.wet[c] = @min(s.d[c], pit) * inv;
    }
}

fn centre(s: *const Sim, i: usize) [2]f32 {
    const x: f32 = @floatFromInt(@as(isize, @intCast(i % s.p)) - 1);
    const y: f32 = @floatFromInt(@as(isize, @intCast(i / s.p)) - 1);
    return .{ x + 0.5, y + 0.5 };
}

/// 5. River segments. Scratch: s.sy holds 1 where a drawn river flows in.
fn rivers(s: *Sim) void {
    const a0 = s.params.river_area;
    const q_start = s.params.river_flow;
    const q_keep = 0.5 * q_start;
    const p: usize = s.p;
    // Main tributary of each channel cell: the donor with the most area.
    @memset(s.next, unseen); // reused: next[r] = main donor of r
    for (s.order[0..s.land]) |c| {
        if (s.acc[c] < a0) continue;
        const r = s.recv[c];
        if (!onLand(s, r)) continue;
        if (s.next[r] == unseen or s.acc[c] > s.acc[s.next[r]]) s.next[r] = c;
    }
    // Which river cells are drawn, upstream first (reverse queue order), so
    // whether a drawn stream flows into a cell is known when we reach it.
    @memset(s.sy, 0);
    const cap = s.segs.len / seg_floats;
    var count: usize = 0;
    var k = s.land;
    while (k > 0) {
        k -= 1;
        const c: usize = s.order[k];
        if (s.acc[c] < a0 or s.wet[c] > 1) continue;
        if (s.acc[c] < big_river * a0) {
            const f = s.flow;
            const q = (4 * f[c] + 2 * (f[c - 1] + f[c + 1] + f[c - p] + f[c + p]) +
                f[c - p - 1] + f[c - p + 1] + f[c + p - 1] + f[c + p + 1]) * (1.0 / 16.0);
            const fed = s.sy[c] > 0;
            if (!(q >= q_start or (fed and q >= q_keep))) continue;
        }
        const r = s.recv[c];
        if (onLand(s, r)) s.sy[r] = 1;
        if (count == cap) continue;
        const a = node(s, c);
        const b = if (onLand(s, r)) node(s, r) else centre(s, r);
        const o = count * seg_floats;
        s.segs[o..][0..seg_floats].* = .{ a[0], a[1], b[0], b[1], s.acc[c] / a0 };
        count += 1;
    }
    s.seg_count = count;
}

fn node(s: *const Sim, c: usize) [2]f32 {
    const pc = centre(s, c);
    const pr = centre(s, s.recv[c]);
    const d = s.next[c];
    const pd = if (d != unseen) centre(s, d) else pc;
    return .{ 0.5 * pc[0] + 0.25 * (pr[0] + pd[0]), 0.5 * pc[1] + 0.25 * (pr[1] + pd[1]) };
}

/// 6. Signed distance to the coastline, in world units (land > 0, sea < 0).
/// Uses s.sx/s.sy as the nearest coast point of each cell (in cells).
fn coastDistance(s: *Sim) void {
    const n: usize = s.n;
    const p: usize = s.p;
    const far = std.math.inf(f32);
    const sl = s.params.sea_level;
    @memset(s.sx, far);
    @memset(s.sy, far);
    var y_lo: usize = n + 1;
    var y_hi: usize = 0;
    // Seed the cells on either side of the coast with the point where the
    // terrain crosses sea level (linearised), at most a cell away.
    for (1..n + 1) |y| {
        const cy = @as(f32, @floatFromInt(y)) - 0.5;
        for (1..n + 1) |x| {
            const i = y * p + x;
            const here = s.sea[i] > 0.5;
            var mx: f32 = 0;
            var my: f32 = 0;
            var m: f32 = 0;
            if (x > 1 and (s.sea[i - 1] > 0.5) != here) {
                mx -= 1;
                m += 1;
            }
            if (x < n and (s.sea[i + 1] > 0.5) != here) {
                mx += 1;
                m += 1;
            }
            if (y > 1 and (s.sea[i - p] > 0.5) != here) {
                my -= 1;
                m += 1;
            }
            if (y < n and (s.sea[i + p] > 0.5) != here) {
                my += 1;
                m += 1;
            }
            if (m == 0) continue;
            y_lo = @min(y_lo, y);
            y_hi = @max(y_hi, y);
            const cx = @as(f32, @floatFromInt(x)) - 0.5;
            const gx = 0.5 * (s.b[i + 1] - s.b[i - 1]);
            const gy = 0.5 * (s.b[i + p] - s.b[i - p]);
            const g2 = gx * gx + gy * gy;
            var ox: f32 = 0.5 * mx / m;
            var oy: f32 = 0.5 * my / m;
            if (g2 > 1e-8) {
                const t = (s.b[i] - sl) / g2;
                const lx = -t * gx;
                const ly = -t * gy;
                // Trust the linear estimate only if it points across the coast.
                if (lx * mx + ly * my > 0 and lx * lx + ly * ly <= 1) {
                    ox = lx;
                    oy = ly;
                }
            }
            s.sx[i] = cx + ox;
            s.sy[i] = cy + oy;
        }
    }
    const Pass = struct {
        inline fn relax(sim: *Sim, i: usize, j: usize, cx: f32, cy: f32) void {
            const jx = sim.sx[j];
            if (jx == far) return;
            const jy = sim.sy[j];
            const ix = sim.sx[i];
            const iy = sim.sy[i];
            if (ix == far or (jx - cx) * (jx - cx) + (jy - cy) * (jy - cy) < (ix - cx) * (ix - cx) + (iy - cy) * (iy - cy)) {
                sim.sx[i] = jx;
                sim.sy[i] = jy;
            }
        }
    };
    // Only a band around the coast is ever drawn from, so the sweeps stop
    // `band` world units beyond the last coast cell.
    const band: usize = @intFromFloat(@ceil(band_units / s.cell));
    if (y_hi == 0) y_lo = 1; // no coast: nothing to sweep (every cell reads as far)
    const r0: usize = if (y_lo > band) y_lo - band else 1;
    const r1: usize = if (y_hi == 0) 0 else @min(n, y_hi + band);
    for (r0..r1 + 1) |y| {
        const cy = @as(f32, @floatFromInt(y)) - 0.5;
        for (1..n + 1) |x| {
            const i = y * p + x;
            const cx = @as(f32, @floatFromInt(x)) - 0.5;
            Pass.relax(s, i, i - 1, cx, cy);
            Pass.relax(s, i, i - p - 1, cx, cy);
            Pass.relax(s, i, i - p, cx, cy);
            Pass.relax(s, i, i - p + 1, cx, cy);
        }
    }
    var y: usize = r1;
    while (y >= r0 and y >= 1) : (y -= 1) {
        const cy = @as(f32, @floatFromInt(y)) - 0.5;
        var x: usize = n;
        while (x >= 1) : (x -= 1) {
            const i = y * p + x;
            const cx = @as(f32, @floatFromInt(x)) - 0.5;
            Pass.relax(s, i, i + 1, cx, cy);
            Pass.relax(s, i, i + p + 1, cx, cy);
            Pass.relax(s, i, i + p, cx, cy);
            Pass.relax(s, i, i + p - 1, cx, cy);
        }
    }
    // Signed distance in world units; cells beyond the band read as "far".
    const big: f32 = far_units;
    for (1..n + 1) |yy| {
        const cy = @as(f32, @floatFromInt(yy)) - 0.5;
        const swept = yy >= r0 and yy <= r1;
        for (1..n + 1) |x| {
            const i = yy * p + x;
            var d = big;
            if (swept and s.sx[i] != far) {
                const cx = @as(f32, @floatFromInt(x)) - 0.5;
                d = @sqrt((s.sx[i] - cx) * (s.sx[i] - cx) + (s.sy[i] - cy) * (s.sy[i] - cy)) * s.cell;
            }
            s.dist[i] = if (s.sea[i] > 0.5) -d else d;
        }
    }
}

