//! WebAssembly entry points. All memory is static: the simulation fields,
//! the flood-fill queue and the PNG buffer live in the module's linear
//! memory, and JavaScript reads the height and water fields in place.
//!
//! Every export validates its arguments and returns a negative code on bad
//! input instead of trapping.

const std = @import("std");
const sim_mod = @import("sim.zig");
const png = @import("png.zig");

const max_n = 512;
const max_cells = sim_mod.cellsFor(max_n);
const text_cap = 512;

var pool: [sim_mod.field_count * max_cells]f32 = undefined;
var queue: [max_n * max_n]u32 = undefined;
var png_buf: [png.encodedSize(max_n, text_cap)]u8 = undefined;
var text_buf: [text_cap]u8 = undefined;
var png_len: usize = 0;
var sim: sim_mod.Sim = undefined;
var ready = false;

pub const err_bad_size: i32 = -1;
pub const err_not_ready: i32 = -2;
pub const err_bad_arg: i32 = -3;

/// Start a new survey: an n x n grid (a multiple of 4, 8..512) with the
/// default terrain for `seed`.
export fn silt_init(n: u32, seed: u32) i32 {
    sim = sim_mod.Sim.init(&pool, &queue, n, seed) catch return err_bad_size;
    ready = true;
    return 0;
}

/// Run up to `count` steps (at most 1000 per call). Returns steps run.
export fn silt_step(count: u32) i32 {
    if (!ready) return err_not_ready;
    const k = @min(count, 1000);
    var i: u32 = 0;
    while (i < k) : (i += 1) sim.step();
    return @intCast(k);
}

/// Paint at grid position (x, y) in cells. Returns 0, or a negative code.
export fn silt_brush(x: f32, y: f32, radius: f32, strength: f32) i32 {
    if (!ready) return err_not_ready;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(radius) or !std.math.isFinite(strength) or radius <= 0) return err_bad_arg;
    _ = sim.brush(x, y, radius, strength);
    return 0;
}

export fn silt_size() u32 {
    return if (ready) sim.n else 0;
}
/// Row stride of every field (n + 2: one ghost cell each side).
export fn silt_stride() u32 {
    return if (ready) sim.p else 0;
}
/// Byte addresses of the fields (they move between steps: read them per frame).
export fn silt_height_ptr() usize {
    return if (ready) @intFromPtr(sim.b.ptr) else 0;
}
export fn silt_water_ptr() usize {
    return if (ready) @intFromPtr(sim.d.ptr) else 0;
}
export fn silt_base_ptr() usize {
    return if (ready) @intFromPtr(sim.base.ptr) else 0;
}
export fn silt_wet_ptr() usize {
    return if (ready) @intFromPtr(sim.wet.ptr) else 0;
}
export fn silt_sea_ptr() usize {
    return if (ready) @intFromPtr(sim.sea.ptr) else 0;
}
export fn silt_flow_ptr() usize {
    return if (ready) @intFromPtr(sim.flow.ptr) else 0;
}
export fn silt_sediment_ptr() usize {
    return if (ready) @intFromPtr(sim.s.ptr) else 0;
}
export fn silt_steps() f64 {
    return if (ready) @floatFromInt(sim.steps) else 0;
}
export fn silt_sea_level() f32 {
    return if (ready) sim.params.sea_level else 0;
}
/// World units per grid cell.
export fn silt_cell_size() f32 {
    return if (ready) sim.cell else 0;
}

/// Books and totals for tests and the page's readout:
/// 0 water, 1 terrain, 2 suspended sediment, 3 rain, 4 evaporation,
/// 5 sea exchange, 6 brush water, 7 brush terrain, 8 lowest, 9 highest.
export fn silt_stat(which: u32) f64 {
    if (!ready) return 0;
    const t = sim.totals();
    const l = sim.ledger;
    return switch (which) {
        0 => t.water,
        1 => t.terrain,
        2 => t.sediment,
        3 => l.rain,
        4 => l.evaporation,
        5 => l.sea_exchange,
        6 => l.brush_water,
        7 => l.brush_terrain,
        8 => sim.heightRange()[0],
        9 => sim.heightRange()[1],
        else => std.math.nan(f64),
    };
}

const ParamSpec = struct { field: []const u8, lo: f32, hi: f32 };
/// Tunable parameters, by index, with the range each accepts.
const param_specs = [_]ParamSpec{
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
    .{ .field = "river_flow", .lo = 0.001, .hi = 1000 },
    .{ .field = "friction_depth", .lo = 0.001, .hi = 100 },
    .{ .field = "creep", .lo = 0, .hi = 2 },
};

/// Set parameter `which` (see param_specs) to `value`. Returns 0, or a
/// negative code if the index is unknown or the value is out of range.
export fn silt_set_param(which: u32, value: f32) i32 {
    if (!ready) return err_not_ready;
    if (!std.math.isFinite(value)) return err_bad_arg;
    inline for (param_specs, 0..) |spec, k| {
        if (which == k) {
            if (value < spec.lo or value > spec.hi) return err_bad_arg;
            @field(sim.params, spec.field) = value;
            return 0;
        }
    }
    return err_bad_arg;
}

/// Scratch space for the PNG's description text (UTF-8, up to 512 bytes).
export fn silt_text_ptr() usize {
    return @intFromPtr(&text_buf);
}

/// Encode the terrain as a 16-bit greyscale PNG, black = `lo`, white = `hi`.
/// Returns the byte length (read it at silt_png_ptr), or a negative code.
export fn silt_encode_png(lo: f32, hi: f32, text_len: u32) i32 {
    if (!ready) return err_not_ready;
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi) or !(hi > lo) or text_len > text_cap) return err_bad_arg;
    png_len = png.encodeGray16(&png_buf, sim.n, sim.b, sim.p + 1, sim.p, lo, hi, text_buf[0..text_len]);
    return @intCast(png_len);
}

export fn silt_png_ptr() usize {
    return @intFromPtr(&png_buf);
}
