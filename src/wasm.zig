//! WebAssembly entry points. All memory is static: the simulation fields,
//! the survey's queues, the river segments and the PNG buffer live in the
//! module's linear memory, and JavaScript reads the fields in place.
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
var upool: [sim_mod.u32sFor(max_n)]u32 = undefined;
var segs: [sim_mod.segFloatsFor(max_n)]f32 = undefined;
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
    sim = sim_mod.Sim.init(&pool, &upool, &segs, n, seed) catch return err_bad_size;
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
/// The sea and the drainage survey catch up at the next silt_settle or step.
export fn silt_brush(x: f32, y: f32, radius: f32, strength: f32) i32 {
    if (!ready) return err_not_ready;
    if (!std.math.isFinite(x) or !std.math.isFinite(y) or !std.math.isFinite(radius) or !std.math.isFinite(strength) or radius <= 0) return err_bad_arg;
    _ = sim.brush(x, y, radius, strength);
    return 0;
}

/// Bring the sea up to date after painting, and re-run the drainage survey
/// if painting changed the ground or 16 steps have passed. Returns 1 if the
/// survey ran, 0 if nothing was due. The page calls it once per frame.
export fn silt_settle() i32 {
    if (!ready) return err_not_ready;
    const due = sim.surveyDue();
    sim.settle();
    return @intFromBool(due);
}

/// Bumped each time the drainage survey runs.
export fn silt_survey_version() u32 {
    return if (ready) sim.survey_version else 0;
}
/// River segments: silt_river_count() records of 5 f32 at silt_rivers_ptr():
/// x0, y0, x1, y1 in grid cells, then upstream area over the river threshold.
export fn silt_rivers_ptr() usize {
    return @intFromPtr(&segs);
}
export fn silt_river_count() u32 {
    return if (ready) @intCast(sim.seg_count) else 0;
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
/// Signed distance to the coast in world units (land > 0, sea < 0).
export fn silt_dist_ptr() usize {
    return if (ready) @intFromPtr(sim.dist.ptr) else 0;
}
/// Upstream drainage area in world units squared (0 in the sea).
export fn silt_acc_ptr() usize {
    return if (ready) @intFromPtr(sim.acc.ptr) else 0;
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
/// 5 sea exchange, 6 brush water, 7 brush terrain, 8 lowest, 9 highest,
/// 10 water off the land edges, 11 sediment off the land edges,
/// 12 sediment picked up minus laid down, 13 picked up plus laid down.
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
        10 => l.edge_water,
        11 => l.edge_sediment,
        12 => l.pickup,
        13 => l.exchange,
        else => std.math.nan(f64),
    };
}

/// Set parameter `which` (see sim.param_specs) to `value`. Returns 0, or a
/// negative code if the index is unknown or the value is out of range.
export fn silt_set_param(which: u32, value: f32) i32 {
    if (!ready) return err_not_ready;
    return if (sim_mod.setParam(&sim.params, which, value)) 0 else err_bad_arg;
}

/// Scratch space for the PNG's description text: Latin-1 (ISO 8859-1), as
/// the PNG spec requires for tEXt, up to 512 bytes. NUL bytes are refused.
export fn silt_text_ptr() usize {
    return @intFromPtr(&text_buf);
}

/// Encode the terrain as a 16-bit greyscale PNG, black = `lo`, white = `hi`.
/// Returns the byte length (read it at silt_png_ptr), or a negative code.
export fn silt_encode_png(lo: f32, hi: f32, text_len: u32) i32 {
    if (!ready) return err_not_ready;
    if (!std.math.isFinite(lo) or !std.math.isFinite(hi) or !(hi > lo) or text_len > text_cap) return err_bad_arg;
    if (std.mem.indexOfScalar(u8, text_buf[0..text_len], 0) != null) return err_bad_arg;
    png_len = png.encodeGray16(&png_buf, sim.n, sim.b, sim.p + 1, sim.p, lo, hi, text_buf[0..text_len]);
    return @intCast(png_len);
}

export fn silt_png_ptr() usize {
    return @intFromPtr(&png_buf);
}
