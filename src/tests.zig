//! Kernel tests: `zig build test`.

const std = @import("std");
const sim_mod = @import("sim.zig");
const Sim = sim_mod.Sim;
const testing = std.testing;

test {
    _ = @import("terrain.zig");
    _ = @import("png.zig");
}

/// A simulation with heap buffers (the wasm build uses static ones).
const Harness = struct {
    pool: []f32,
    upool: []u32,
    segs: []f32,
    sim: Sim,

    fn init(n: u32, seed: u32) !Harness {
        const pool = try testing.allocator.alloc(f32, sim_mod.field_count * sim_mod.cellsFor(n));
        errdefer testing.allocator.free(pool);
        const upool = try testing.allocator.alloc(u32, sim_mod.u32sFor(n));
        errdefer testing.allocator.free(upool);
        const segs = try testing.allocator.alloc(f32, sim_mod.segFloatsFor(n));
        errdefer testing.allocator.free(segs);
        return .{ .pool = pool, .upool = upool, .segs = segs, .sim = try Sim.init(pool, upool, segs, n, seed) };
    }

    fn deinit(self: *Harness) void {
        testing.allocator.free(self.pool);
        testing.allocator.free(self.upool);
        testing.allocator.free(self.segs);
    }
};

/// Replace the terrain with a plane h = h0 + sx*x + sy*y (cells), and reset
/// water, sediment and the books.
fn setPlane(s: *Sim, h0: f32, sx: f32, sy: f32) void {
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        s.b[i] = h0 + sx * @as(f32, @floatFromInt(x)) + sy * @as(f32, @floatFromInt(y));
        s.d[i] = 0;
        s.s[i] = 0;
        s.fl[i] = 0;
        s.fr[i] = 0;
        s.ft[i] = 0;
        s.fb[i] = 0;
    };
    s.refreshGhosts();
    @memcpy(s.base, s.b);
    s.updateSea();
    s.clampSea(sim_mod.lanes, 1);
    s.ledger = .{};
    s.survey_dirty = true;
}

const Books = struct {
    water0: f64,
    mass0: f64,
    sed0: f64,

    fn open(s: *const Sim) Books {
        const t = s.totals();
        return .{
            .water0 = t.water - ledgerWater(s),
            .mass0 = t.terrain + t.sediment - s.ledger.brush_terrain + s.ledger.edge_sediment,
            .sed0 = t.sediment - s.ledger.pickup + s.ledger.edge_sediment,
        };
    }

    fn ledgerWater(s: *const Sim) f64 {
        const l = s.ledger;
        return l.rain - l.evaporation + l.sea_exchange + l.brush_water - l.edge_water;
    }

    /// Water: what is on the map equals what started there plus rain, minus
    /// evaporation, plus sea exchange and painting, minus what ran off the
    /// open edges. Material: terrain plus suspended sediment changes only by
    /// painting and by sediment carried off the edges.
    fn check(self: Books, s: *const Sim) !void {
        const t = s.totals();
        const l = s.ledger;
        const water_expected = self.water0 + ledgerWater(s);
        const water_scale = @abs(self.water0) + l.rain + l.evaporation + @abs(l.sea_exchange) + @abs(l.brush_water) + l.edge_water + 1;
        const mass_expected = self.mass0 + l.brush_terrain - l.edge_sediment;
        var mass_scale: f64 = 1 + @abs(l.brush_terrain);
        for (1..s.n + 1) |y| {
            const row = y * s.p;
            for (row + 1..row + 1 + s.n) |i| mass_scale += @abs(s.b[i]) + s.s[i];
        }
        // f32 fields, summed in f64: allow a few parts per million.
        try testing.expectApproxEqAbs(water_expected, t.water, 2e-6 * water_scale);
        try testing.expectApproxEqAbs(mass_expected, t.terrain + t.sediment, 2e-6 * mass_scale);
        try self.checkSediment(s);
    }

    /// The suspended load is judged against its own traffic, not against the
    /// whole terrain: it must equal what it started with plus what was picked
    /// up minus what was laid down (booked as `pickup`) minus what left over
    /// the edges, to a millionth of all the material that moved between bed
    /// and water (`exchange`). A leak of 0.1% of the load per step fails this.
    fn checkSediment(self: Books, s: *const Sim) !void {
        const l = s.ledger;
        const expected = self.sed0 + l.pickup - l.edge_sediment;
        try testing.expectApproxEqAbs(expected, s.totals().sediment, 1e-6 * l.exchange + 1e-9);
    }
};

fn expectSane(s: *const Sim) !void {
    for (1..s.n + 1) |y| {
        const row = y * s.p;
        for (row + 1..row + 1 + s.n) |i| {
            try testing.expect(std.math.isFinite(s.b[i]));
            try testing.expect(std.math.isFinite(s.d[i]) and s.d[i] >= 0);
            try testing.expect(std.math.isFinite(s.s[i]) and s.s[i] >= 0);
        }
    }
}

test "conservation: water and sediment books balance after every step" {
    var h = try Harness.init(48, 7);
    defer h.deinit();
    const s = &h.sim;
    const books = Books.open(s);
    try books.check(s);
    var k: u32 = 0;
    while (k < 400) : (k += 1) {
        s.step();
        try books.check(s);
        // Paint now and then, including under water and at the sea.
        if (k == 100) _ = s.brush(24, 20, 6, 3);
        if (k == 200) _ = s.brush(24, 40, 8, -2);
        if (k == 300) _ = s.brush(10, 46, 5, 4);
        if (k % 50 == 0) s.settle();
        if (k % 100 == 0) try books.check(s);
    }
    try expectSane(s);
    // The run did real work on every side of the books.
    try testing.expect(s.ledger.rain > 0);
    try testing.expect(s.ledger.evaporation > 0);
    try testing.expect(s.ledger.sea_exchange != 0);
    try testing.expect(s.ledger.edge_water > 0);
    try testing.expect(s.ledger.exchange > 0);
    try testing.expect(s.ledger.pickup != 0);
}

test "conservation: the suspended load matches the pickup ledger every step" {
    var h = try Harness.init(64, 3);
    defer h.deinit();
    const s = &h.sim;
    const books = Books.open(s);
    for (0..300) |_| {
        s.step();
        try books.checkSediment(s);
    }
    // Material really moved, and some of it is still in the water.
    try testing.expect(s.totals().sediment > 0);
    try testing.expect(s.ledger.exchange > s.totals().sediment);
}

test "determinism: a fixed seed gives bit-identical runs" {
    var a = try Harness.init(40, 1234);
    defer a.deinit();
    var b = try Harness.init(40, 1234);
    defer b.deinit();
    for (0..120) |_| {
        a.sim.step();
        b.sim.step();
    }
    try testing.expectEqualSlices(f32, a.sim.b, b.sim.b);
    try testing.expectEqualSlices(f32, a.sim.d, b.sim.d);
    try testing.expectEqualSlices(f32, a.sim.s, b.sim.s);
    try testing.expectEqual(a.sim.ledger.rain, b.sim.ledger.rain);

    var c = try Harness.init(40, 1235);
    defer c.deinit();
    try testing.expect(!std.mem.eql(f32, a.sim.base, c.sim.base));
}

test "determinism: SIMD kernels match the scalar kernels bit for bit" {
    var v = try Harness.init(32, 99);
    defer v.deinit();
    var x = try Harness.init(32, 99);
    defer x.deinit();
    for (0..80) |_| {
        v.sim.stepLanes(4);
        x.sim.stepLanes(1);
    }
    try testing.expectEqualSlices(f32, v.sim.b, x.sim.b);
    try testing.expectEqualSlices(f32, v.sim.d, x.sim.d);
    try testing.expectEqualSlices(f32, v.sim.s, x.sim.s);
}

test "boundary: water leaves through open land edges only where the ground falls away" {
    var h = try Harness.init(32, 5);
    defer h.deinit();
    const s = &h.sim;
    // A plane rising to the east and (gently) to the south, all above sea
    // level: no sea. The ground falls away off the west and north edges.
    setPlane(s, 2, 0.4, 0.05);
    try testing.expectEqual(@as(f32, 0), s.sea[s.idx(0, 0)]);
    const books = Books.open(s);
    for (0..300) |_| {
        s.step();
        // Off the east and south edges the ground rises: nothing leaves there.
        for (0..s.n) |k| {
            const kk: u32 = @intCast(k);
            try testing.expectEqual(@as(f32, 0), s.fr[s.idx(s.n - 1, kk)]);
            try testing.expectEqual(@as(f32, 0), s.fb[s.idx(kk, s.n - 1)]);
        }
        try books.check(s);
    }
    // With no sea, only rain, evaporation and the edges touched the water,
    // and the west edge carried most of it away.
    try testing.expectEqual(@as(f64, 0), s.ledger.sea_exchange);
    try testing.expect(s.ledger.edge_water > 0.2 * s.ledger.rain);
    var west: f64 = 0;
    var north: f64 = 0;
    for (0..s.n) |k| {
        west += s.fl[s.idx(0, @intCast(k))];
        north += s.ft[s.idx(@intCast(k), 0)];
    }
    try testing.expect(west > north and north > 0);
    // Nothing ponds against the open edge.
    for (0..s.n) |y| try testing.expect(s.d[s.idx(0, @intCast(y))] < 0.05);
    try expectSane(s);
}

test "boundary: sea edges stay closed" {
    var h = try Harness.init(32, 5);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, -3, 0, 0); // all sea
    for (0..50) |_| s.step();
    for (0..s.n) |k| {
        const kk: u32 = @intCast(k);
        try testing.expectEqual(@as(f32, 0), s.fl[s.idx(0, kk)]);
        try testing.expectEqual(@as(f32, 0), s.fr[s.idx(s.n - 1, kk)]);
        try testing.expectEqual(@as(f32, 0), s.ft[s.idx(kk, 0)]);
        try testing.expectEqual(@as(f32, 0), s.fb[s.idx(kk, s.n - 1)]);
    }
    try testing.expectEqual(@as(f64, 0), s.ledger.edge_water);
}

test "boundary: ghost ring mirrors the edge terrain; its water is a wall by the sea, the edge slope by land" {
    var h = try Harness.init(24, 11);
    defer h.deinit();
    const s = &h.sim;
    for (0..60) |_| s.step();
    _ = s.brush(0, 0, 6, 3); // paint right into the corner
    s.settle();
    const p = s.p;
    const n = s.n;
    for (1..p - 1) |y| {
        try testing.expectEqual(s.b[y * p + 1], s.b[y * p]);
        try testing.expectEqual(s.b[y * p + p - 2], s.b[y * p + p - 1]);
    }
    for (1..p - 1) |x| {
        try testing.expectEqual(s.b[p + x], s.b[x]);
        try testing.expectEqual(s.b[(p - 2) * p + x], s.b[(p - 1) * p + x]);
    }
    // Ghost fluxes never move.
    for (0..p) |x| try testing.expectEqual(@as(f32, 0), s.fl[x] + s.fr[x] + s.ft[x] + s.fb[x]);
    // West column: a wall beside sea cells, the edge slope beside land.
    var seen_sea = false;
    var seen_land = false;
    for (1..n + 1) |y| {
        const g = y * p;
        if (s.sea[g + 1] > 0.5) {
            seen_sea = true;
            try testing.expectEqual(sim_mod.wall, s.d[g]);
        } else {
            seen_land = true;
            try testing.expectEqual(s.b[g + 1] - s.b[g + 2], s.d[g]);
        }
    }
    try testing.expect(seen_sea and seen_land); // the default map has both on its west edge
}

test "boundary: the connected sea is held at sea level" {
    var h = try Harness.init(48, 21);
    defer h.deinit();
    const s = &h.sim;
    for (0..100) |_| s.step();
    // Soft hold (the default): river inflow may lift the surface a little
    // while it spreads out to sea.
    var sea_cells: usize = 0;
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        if (s.sea[i] > 0.5 and s.b[i] < s.params.sea_level) {
            sea_cells += 1;
            try testing.expectApproxEqAbs(s.params.sea_level, s.b[i] + s.d[i], 0.25);
        }
    };
    // The default terrain has a sea along the south edge, and none in the north.
    try testing.expect(sea_cells > s.n * 4);
    try testing.expect(s.sea[s.idx(s.n / 2, s.n - 1)] > 0.5);
    try testing.expect(s.sea[s.idx(s.n / 2, 0)] < 0.5);
    // Hard hold: every sea cell sits exactly at sea level after a step.
    s.params.sea_relax = 1;
    s.step();
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        if (s.sea[i] > 0.5 and s.b[i] < s.params.sea_level)
            try testing.expectApproxEqAbs(s.params.sea_level, s.b[i] + s.d[i], 1e-4);
    };
}

test "boundary: an inland hollow below sea level is a lake, not sea" {
    var h = try Harness.init(32, 1);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, 3, 0, 0);
    _ = s.brush(16, 16, 5, -4); // a pit down to -1, far from the edge
    s.settle();
    try testing.expect(s.b[s.idx(16, 16)] < 0);
    try testing.expect(s.sea[s.idx(16, 16)] < 0.5);
    try testing.expectEqual(@as(f32, 0), s.d[s.idx(16, 16)]);
    // Cut a channel from it to the edge and the sea floods in.
    var x: f32 = 16;
    while (x < 34) : (x += 1) _ = s.brush(x, 16, 2, -4);
    s.settle();
    try testing.expect(s.sea[s.idx(16, 16)] > 0.5);
    try testing.expect(s.d[s.idx(16, 16)] > 0);
}

test "brush: raises a smooth, symmetric mound inside the radius only" {
    var h = try Harness.init(32, 1);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, 5, 0, 0);
    s.params.brush_texture = 0; // exact shape; texture has its own test
    const added = s.brush(16, 16, 5, 1);
    var sum: f64 = 0;
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        const dh = s.b[i] - 5;
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - 16;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - 16;
        if (dx * dx + dy * dy >= 25) {
            try testing.expectEqual(@as(f32, 0), dh);
        } else {
            try testing.expect(dh > 0 and dh <= 1);
        }
        // Mirror symmetry about the brush centre (cell 15.5 | 16.5 boundary).
        const mx: u32 = @intCast(31 - x);
        try testing.expectEqual(s.b[i], s.b[s.idx(mx, @intCast(y))]);
        sum += dh;
    };
    try testing.expectApproxEqAbs(added, sum, 1e-4);
    try testing.expectApproxEqAbs(added, s.ledger.brush_terrain, 1e-9);
    // The surveyed base moves with the paint, so painting is not "deposit".
    for (s.b, s.base) |b, base| try testing.expectEqual(b, base);
}

test "brush: texture roughens a dab but stays inside the radius" {
    var h = try Harness.init(32, 1);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, 5, 0, 0);
    const added = s.brush(16, 16, 8, 1);
    try testing.expect(added > 0);
    var lo: f32 = 10;
    var hi: f32 = 0;
    for (0..s.n) |y| for (0..s.n) |x| {
        const dh = s.b[s.idx(@intCast(x), @intCast(y))] - 5;
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - 16;
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - 16;
        const q = (dx * dx + dy * dy) / 64;
        if (q >= 1) {
            try testing.expectEqual(@as(f32, 0), dh);
        } else {
            // Within (1 -/+ 1.1 t) of the smooth profile, and never negative.
            const smooth = (1 - q) * (1 - q);
            const t = s.params.brush_texture;
            try testing.expect(dh >= smooth * (1 - 1.1 * t) - 1e-6 and dh <= smooth * (1 + 1.1 * t) + 1e-6);
            if (q < 0.5) {
                lo = @min(lo, dh / smooth);
                hi = @max(hi, dh / smooth);
            }
        }
    };
    try testing.expect(hi - lo > 0.1); // it really is textured
    // Same seed and stroke, same texture.
    var h2 = try Harness.init(32, 1);
    defer h2.deinit();
    setPlane(&h2.sim, 5, 0, 0);
    _ = h2.sim.brush(16, 16, 8, 1);
    try testing.expectEqualSlices(f32, s.b, h2.sim.b);
}

test "brush: lowering undoes raising, and strength and height are clamped" {
    var h = try Harness.init(32, 1);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, 5, 0, 0);
    _ = s.brush(10, 12, 4, 0.75);
    _ = s.brush(10, 12, 4, -0.75);
    for (0..s.n) |y| for (0..s.n) |x| {
        try testing.expectApproxEqAbs(@as(f32, 5), s.b[s.idx(@intCast(x), @intCast(y))], 1e-5);
    };
    // Strength is capped per stamp, and terrain never passes the ceiling.
    _ = s.brush(16, 16, 3, 1000);
    try testing.expect(s.b[s.idx(16, 16)] <= 5 + sim_mod.max_brush_strength);
    for (0..100) |_| _ = s.brush(16, 16, 3, 4);
    try testing.expectEqual(sim_mod.max_height, s.b[s.idx(16, 16)]);
}

test "brush: bad input and off-map strokes change nothing" {
    var h = try Harness.init(16, 1);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, 3, 0, 0);
    const snapshot = try testing.allocator.dupe(f32, s.b);
    defer testing.allocator.free(snapshot);
    try testing.expectEqual(@as(f64, 0), s.brush(std.math.nan(f32), 4, 3, 1));
    try testing.expectEqual(@as(f64, 0), s.brush(4, 4, std.math.inf(f32), 1));
    try testing.expectEqual(@as(f64, 0), s.brush(-100, -100, 5, 1));
    try testing.expectEqual(@as(f64, 0), s.brush(500, 8, 5, 1));
    try testing.expectEqualSlices(f32, snapshot, s.b);
    // A stroke half off the map paints only the on-map half.
    try testing.expect(s.brush(-1, 8, 4, 1) > 0);
}

test "brush: raising ground through standing water sheds that water" {
    var h = try Harness.init(32, 1);
    defer h.deinit();
    const s = &h.sim;
    setPlane(s, -3, 0, 0); // everything is sea, 3 deep
    const books = Books.open(s);
    try testing.expectApproxEqAbs(@as(f32, 3), s.d[s.idx(16, 16)], 1e-6);
    _ = s.brush(16, 16, 6, 4); // pokes an island 1 above the sea
    s.settle();
    try testing.expect(s.b[s.idx(15, 15)] > 0);
    try testing.expectEqual(@as(f32, 0), s.d[s.idx(15, 15)]);
    try testing.expect(s.sea[s.idx(15, 15)] < 0.5);
    try books.check(s);
}

test "erosion cuts the hills and builds land at the coast" {
    var h = try Harness.init(64, 4);
    defer h.deinit();
    const s = &h.sim;
    for (0..600) |_| s.step();
    try expectSane(s);
    var cut: f64 = 0;
    var laid: f64 = 0;
    var laid_near_sea: f64 = 0;
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        const dh = s.b[i] - s.base[i];
        if (dh < 0) cut -= dh else laid += dh;
        if (dh > 0 and s.base[i] < 2) laid_near_sea += dh;
    };
    try testing.expect(cut > 1);
    try testing.expect(laid > 0.5);
    try testing.expect(laid_near_sea > 0);
}

test "init rejects bad sizes and short buffers" {
    var pool: [sim_mod.field_count * 100]f32 = undefined;
    var upool: [64]u32 = undefined;
    var segs: [64]f32 = undefined;
    try testing.expectError(error.BadSize, Sim.init(&pool, &upool, &segs, 6, 0));
    try testing.expectError(error.BadSize, Sim.init(&pool, &upool, &segs, 10, 0));
    try testing.expectError(error.BadSize, Sim.init(&pool, &upool, &segs, 1024, 0));
    try testing.expectError(error.BufferTooSmall, Sim.init(&pool, &upool, &segs, 16, 0));
}

// ---------------------------------------------------------------------------
// Drainage survey (hydro.zig)

const hydro = @import("hydro.zig");

/// Follow a land cell's receivers to the sea or off the map. Fails on a
/// cycle (more hops than cells) or a chain that climbs the filled surface.
fn drainsOut(s: *const Sim, start: usize) !void {
    var c = start;
    var hops: usize = 0;
    while (true) : (hops += 1) {
        try testing.expect(hops <= s.land);
        const r = s.recv[c];
        try testing.expect(r < hydro.ghost_cell);
        const rr = s.recv[r];
        if (rr == hydro.sea_cell or rr == hydro.ghost_cell) return; // reached the sea or left the map
        try testing.expect(s.filled[r] <= s.filled[c]);
        c = r;
    }
}

test "survey: every land cell drains to the sea or off the map, down the filled surface" {
    var h = try Harness.init(96, 2);
    defer h.deinit();
    const s = &h.sim;
    for (0..200) |_| s.step();
    _ = s.brush(40, 30, 8, -3); // dig a closed pit: the fill must route through it
    s.settle();
    var land: usize = 0;
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        if (s.sea[i] > 0.5) {
            try testing.expectEqual(hydro.sea_cell, s.recv[i]);
            continue;
        }
        land += 1;
        try testing.expect(s.filled[i] >= s.b[i]);
        try drainsOut(s, i);
    };
    try testing.expectEqual(land, s.land);
}

test "survey: upstream area is conserved: the outlets drain the whole land" {
    var h = try Harness.init(64, 9);
    defer h.deinit();
    const s = &h.sim;
    for (0..100) |_| s.step();
    s.settle();
    var at_outlets: f64 = 0;
    for (s.order[0..s.land]) |c| {
        const r = s.recv[c];
        const rr = s.recv[r];
        if (rr == hydro.sea_cell or rr == hydro.ghost_cell) at_outlets += s.acc[c];
        // A cell drains at least itself, and at least as much as any donor.
        try testing.expect(s.acc[c] >= s.cell * s.cell);
        if (rr != hydro.sea_cell and rr != hydro.ghost_cell) try testing.expect(s.acc[r] > s.acc[c]);
    }
    const all: f64 = @as(f64, @floatFromInt(s.land)) * s.cell * s.cell;
    try testing.expectApproxEqRel(all, at_outlets, 1e-6);
}

test "survey: a valley's river runs down its axis, and a filled pit holding water is a lake" {
    var h = try Harness.init(64, 1);
    defer h.deinit();
    const s = &h.sim;
    // A V-shaped valley draining north (off the map), no sea.
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        const dx = @abs(@as(f32, @floatFromInt(x)) - 31.5);
        s.b[i] = 2 + 0.3 * dx + 0.05 * @as(f32, @floatFromInt(y));
    };
    s.refreshGhosts();
    @memcpy(s.base, s.b);
    s.updateSea();
    s.params.river_flow = 0; // draw every river cell: this checks routing, not the flow gate
    s.params.river_area = 200;
    hydro.survey(s);
    // Cells on the valley floor drain nearly the whole map; the axis carries a river.
    const mouth = s.idx(31, 0);
    try testing.expect(s.acc[mouth] + s.acc[s.idx(32, 0)] > 0.6 * @as(f32, @floatFromInt(s.n * s.n)) * s.cell * s.cell);
    var on_axis: usize = 0;
    const segs = s.rivers();
    var k: usize = 0;
    while (k < segs.len) : (k += hydro.seg_floats) {
        if (@abs(segs[k] - 32) < 2 and @abs(segs[k + 2] - 32) < 2) on_axis += 1;
    }
    try testing.expect(on_axis > s.n / 2);
    // Dig a pit on the floor and fill it with water: a lake, and the river
    // is not drawn across it.
    const before = try testing.allocator.dupe(f32, s.b);
    defer testing.allocator.free(before);
    _ = s.brush(32, 30, 5, -2);
    for (0..s.n) |y| for (0..s.n) |x| {
        const i = s.idx(@intCast(x), @intCast(y));
        if (s.b[i] < before[i] - 0.5) s.d[i] = 3;
    };
    s.settle();
    try testing.expect(s.wet[s.idx(31, 30)] > 1);
    const rs = s.rivers();
    k = 0;
    while (k < rs.len) : (k += hydro.seg_floats) {
        const cx: u32 = @intFromFloat(@floor(rs[k]));
        const cy: u32 = @intFromFloat(@floor(rs[k + 1]));
        try testing.expect(s.wet[s.idx(cx, cy)] <= 1 or rs[k + 4] >= hydro.big_river);
    }
}

test "survey: river segments join end to end, down to the sea" {
    var h = try Harness.init(96, 4);
    defer h.deinit();
    const s = &h.sim;
    for (0..600) |_| s.step();
    s.settle();
    const segs = s.rivers();
    try testing.expect(segs.len > 0);
    // Every segment ends where another begins, or in the sea, off the map,
    // or in a lake. Starts are indexed by position.
    var k: usize = 0;
    var joined: usize = 0;
    var ends: usize = 0;
    while (k < segs.len) : (k += hydro.seg_floats) {
        ends += 1;
        const ex = segs[k + 2];
        const ey = segs[k + 3];
        var j: usize = 0;
        var found = false;
        while (j < segs.len) : (j += hydro.seg_floats) {
            if (segs[j] == ex and segs[j + 1] == ey) {
                found = true;
                break;
            }
        }
        if (found) {
            joined += 1;
            continue;
        }
        // Not joined: it must end in the sea, off the map, in a lake, or at
        // a stream the flow gate stopped drawing (whose cell is then a river
        // cell with too little water).
        const cx: i32 = @intFromFloat(@floor(ex));
        const cy: i32 = @intFromFloat(@floor(ey));
        if (cx < 0 or cy < 0 or cx >= s.n or cy >= s.n) continue;
        const i = s.idx(@intCast(cx), @intCast(cy));
        try testing.expect(s.sea[i] > 0.5 or s.wet[i] > 1 or s.acc[i] < hydro.big_river * s.params.river_area);
    }
    try testing.expect(joined * 2 > ends);
}

test "survey: signed distance to a straight coast is the perpendicular distance" {
    var h = try Harness.init(64, 1);
    defer h.deinit();
    const s = &h.sim;
    // Land in the north sloping down to sea in the south. Height is 0 at row
    // index 40.5, i.e. at y = 41 in grid coordinates (cell centres sit at
    // index + 0.5): that line is the coast.
    setPlane(s, 0.2 * 40.5, 0, -0.2);
    s.settle();
    // Measured within a band of hydro.band_units (8 cells here) of the coast.
    for ([_]u32{ 10, 30, 50 }) |x| {
        for ([_]u32{ 33, 36, 39, 40, 41, 45, 47 }) |y| {
            const expected = (41.0 - (@as(f32, @floatFromInt(y)) + 0.5)) * s.cell;
            try testing.expectApproxEqAbs(expected, s.dist[s.idx(x, y)], 0.05 * s.cell);
        }
        // Beyond the band: "far", with the right sign.
        try testing.expectEqual(hydro.far_units, s.dist[s.idx(x, 5)]);
        try testing.expectEqual(-hydro.far_units, s.dist[s.idx(x, 60)]);
    }
}

// ---------------------------------------------------------------------------
// Fuzz: any parameters the kernel accepts, and any painting, keep the fields
// finite and bounded, with no blow-up (deterministic: a fixed PRNG seed).
// Earlier builds failed this: evaporation x dt could pass 1 (negative water,
// then NaN), and thermal + creep could pass the explicit stability limit.

test "fuzz: any accepted parameters keep the fields finite and bounded" {
    var prng = std.Random.DefaultPrng.init(0x5117);
    const rnd = prng.random();
    var h = try Harness.init(32, 3);
    defer h.deinit();
    for (0..60) |round| {
        const s = &h.sim;
        s.* = try Sim.init(h.pool, h.upool, h.segs, 32, @intCast(round + 1));
        // Every parameter: its low end, its high end, or anything between.
        for (sim_mod.param_specs, 0..) |spec, k| {
            const pick = rnd.uintLessThan(u8, 4);
            const v = switch (pick) {
                0 => spec.lo,
                1 => spec.hi,
                else => spec.lo + (spec.hi - spec.lo) * rnd.float(f32) * rnd.float(f32),
            };
            try testing.expect(sim_mod.setParam(&s.params, @intCast(k), v));
        }
        // Out-of-range and non-finite values are refused.
        try testing.expect(!sim_mod.setParam(&s.params, 0, -1));
        try testing.expect(!sim_mod.setParam(&s.params, 1, std.math.nan(f32)));
        try testing.expect(!sim_mod.setParam(&s.params, sim_mod.param_specs.len, 1));
        for (0..120) |step| {
            s.step();
            if (step % 40 == 0) {
                _ = s.brush(rnd.float(f32) * 40 - 4, rnd.float(f32) * 40 - 4, rnd.float(f32) * 80, rnd.float(f32) * 20 - 10);
                s.settle();
            }
        }
        s.settle();
        for (1..s.n + 1) |y| {
            const row = y * s.p;
            for (row + 1..row + 1 + s.n) |i| {
                // No blow-up. (Heights can pass the paint ceiling: with, say,
                // no deposition on land and instant deposition at sea, a whole
                // catchment's load piles up at one mouth. That is conserved
                // material, not an instability.)
                try testing.expect(std.math.isFinite(s.b[i]) and @abs(s.b[i]) < 1000);
                try testing.expect(s.b[i] >= sim_mod.min_height - 1e-3); // nothing digs below the paint floor
                try testing.expect(std.math.isFinite(s.d[i]) and s.d[i] >= 0 and s.d[i] < 1e4);
                try testing.expect(std.math.isFinite(s.s[i]) and s.s[i] >= 0);
                try testing.expect(std.math.isFinite(s.dist[i]) and std.math.isFinite(s.acc[i]));
            }
        }
        for (s.rivers()) |v| try testing.expect(std.math.isFinite(v));
    }
}
