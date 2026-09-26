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
    queue: []u32,
    sim: Sim,

    fn init(n: u32, seed: u32) !Harness {
        const pool = try testing.allocator.alloc(f32, sim_mod.field_count * sim_mod.cellsFor(n));
        errdefer testing.allocator.free(pool);
        const queue = try testing.allocator.alloc(u32, @as(usize, n) * n);
        errdefer testing.allocator.free(queue);
        return .{ .pool = pool, .queue = queue, .sim = try Sim.init(pool, queue, n, seed) };
    }

    fn deinit(self: *Harness) void {
        testing.allocator.free(self.pool);
        testing.allocator.free(self.queue);
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
}

const Books = struct {
    water0: f64,
    mass0: f64,

    fn open(s: *const Sim) Books {
        const t = s.totals();
        return .{ .water0 = t.water - ledgerWater(s), .mass0 = t.terrain + t.sediment - s.ledger.brush_terrain };
    }

    fn ledgerWater(s: *const Sim) f64 {
        const l = s.ledger;
        return l.rain - l.evaporation + l.sea_exchange + l.brush_water;
    }

    /// Water: what is on the map equals what started there plus rain, minus
    /// evaporation, plus sea exchange and painting. Material: terrain plus
    /// suspended sediment changes only by painting.
    fn check(self: Books, s: *const Sim) !void {
        const t = s.totals();
        const l = s.ledger;
        const water_expected = self.water0 + ledgerWater(s);
        const water_scale = @abs(self.water0) + l.rain + l.evaporation + @abs(l.sea_exchange) + @abs(l.brush_water) + 1;
        const mass_expected = self.mass0 + l.brush_terrain;
        var mass_scale: f64 = 1 + @abs(l.brush_terrain);
        for (1..s.n + 1) |y| {
            const row = y * s.p;
            for (row + 1..row + 1 + s.n) |i| mass_scale += @abs(s.b[i]) + s.s[i];
        }
        // f32 fields, summed in f64: allow a few parts per million.
        try testing.expectApproxEqAbs(water_expected, t.water, 2e-6 * water_scale);
        try testing.expectApproxEqAbs(mass_expected, t.terrain + t.sediment, 2e-6 * mass_scale);
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
        if (k % 100 == 0) try books.check(s);
    }
    try expectSane(s);
    // The run did real work on both sides of the books.
    try testing.expect(s.ledger.rain > 0);
    try testing.expect(s.ledger.evaporation > 0);
    try testing.expect(s.ledger.sea_exchange != 0);
}

test "conservation: sediment is only exchanged with the terrain" {
    var h = try Harness.init(32, 3);
    defer h.deinit();
    const s = &h.sim;
    const before = s.totals();
    var k: u32 = 0;
    while (k < 150) : (k += 1) s.step();
    const after = s.totals();
    // Material moved (the river cut and laid down), but none was created.
    try testing.expect(after.sediment > 0);
    try testing.expectApproxEqAbs(before.terrain + before.sediment, after.terrain + after.sediment, 1e-5 * @abs(before.terrain) + 1e-3);
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

test "boundary: no water leaves through the map edge" {
    var h = try Harness.init(32, 5);
    defer h.deinit();
    const s = &h.sim;
    // A plane tilted down towards the west edge, all above sea level: no sea.
    setPlane(s, 2, 0.4, 0.05);
    try testing.expectEqual(@as(f32, 0), s.sea[s.idx(0, 0)]);
    const books = Books.open(s);
    for (0..300) |_| {
        s.step();
        // Pipes pointing off the map never carry anything.
        for (0..s.n) |k| {
            const kk: u32 = @intCast(k);
            try testing.expectEqual(@as(f32, 0), s.fl[s.idx(0, kk)]);
            try testing.expectEqual(@as(f32, 0), s.fr[s.idx(s.n - 1, kk)]);
            try testing.expectEqual(@as(f32, 0), s.ft[s.idx(kk, 0)]);
            try testing.expectEqual(@as(f32, 0), s.fb[s.idx(kk, s.n - 1)]);
        }
    }
    try books.check(s);
    // With no sea, only rain and evaporation touched the water.
    try testing.expectEqual(@as(f64, 0), s.ledger.sea_exchange);
    // The water ran west and pooled against the edge.
    var west: f64 = 0;
    var east: f64 = 0;
    for (0..s.n) |y| {
        west += s.d[s.idx(0, @intCast(y))];
        east += s.d[s.idx(s.n - 1, @intCast(y))];
    }
    try testing.expect(west > 4 * east);
    try expectSane(s);
}

test "boundary: ghost ring stays a wall and mirrors the edge terrain" {
    var h = try Harness.init(24, 11);
    defer h.deinit();
    const s = &h.sim;
    for (0..60) |_| s.step();
    _ = s.brush(0, 0, 6, 3); // paint right into the corner
    const p = s.p;
    for (0..p) |x| {
        try testing.expectEqual(sim_mod.wall, s.d[x]);
        try testing.expectEqual(sim_mod.wall, s.d[(p - 1) * p + x]);
        try testing.expectEqual(@as(f32, 0), s.fl[x] + s.fr[x] + s.ft[x] + s.fb[x]);
    }
    for (1..p - 1) |y| {
        try testing.expectEqual(s.b[y * p + 1], s.b[y * p]);
        try testing.expectEqual(s.b[y * p + p - 2], s.b[y * p + p - 1]);
    }
    for (1..p - 1) |x| {
        try testing.expectEqual(s.b[p + x], s.b[x]);
        try testing.expectEqual(s.b[(p - 2) * p + x], s.b[(p - 1) * p + x]);
    }
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
    try testing.expect(s.b[s.idx(16, 16)] < 0);
    try testing.expect(s.sea[s.idx(16, 16)] < 0.5);
    try testing.expectEqual(@as(f32, 0), s.d[s.idx(16, 16)]);
    // Cut a channel from it to the edge and the sea floods in.
    var x: f32 = 16;
    while (x < 34) : (x += 1) _ = s.brush(x, 16, 2, -4);
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
            // Within +-35% of the smooth profile, and never negative.
            const smooth = (1 - q) * (1 - q);
            try testing.expect(dh >= smooth * 0.64 and dh <= smooth * 1.36);
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
    var queue: [64]u32 = undefined;
    try testing.expectError(error.BadSize, Sim.init(&pool, &queue, 6, 0));
    try testing.expectError(error.BadSize, Sim.init(&pool, &queue, 10, 0));
    try testing.expectError(error.BadSize, Sim.init(&pool, &queue, 1024, 0));
    try testing.expectError(error.BufferTooSmall, Sim.init(&pool, &queue, 16, 0));
}
