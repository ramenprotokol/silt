//! Procedural default terrain: a mountain range in the north, a winding
//! valley that drains south, a coastal plain and a sea shelf along the south
//! edge. Everything is derived from integer hashes of a seed, so the same seed
//! gives the same terrain on every machine.

const std = @import("std");

/// 32-bit integer hash of (seed, x, y). Wrapping arithmetic only, so it is
/// identical on every target.
pub fn hash(seed: u32, x: i32, y: i32) u32 {
    var h: u32 = seed *% 0x9E3779B1;
    h ^= @as(u32, @bitCast(x)) *% 0x85EBCA77;
    h = (h << 13) | (h >> 19);
    h ^= @as(u32, @bitCast(y)) *% 0xC2B2AE3D;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    h *%= 0x297A2D39;
    h ^= h >> 15;
    return h;
}

/// Uniform in [0, 1).
pub fn unit(seed: u32, x: i32, y: i32) f32 {
    return @as(f32, @floatFromInt(hash(seed, x, y) >> 8)) * (1.0 / 16777216.0);
}

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

/// Value noise in [-1, 1] with quintic interpolation.
pub fn valueNoise(seed: u32, x: f32, y: f32) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const tx = fade(x - fx);
    const ty = fade(y - fy);
    const a = unit(seed, ix, iy);
    const b = unit(seed, ix + 1, iy);
    const c = unit(seed, ix, iy + 1);
    const d = unit(seed, ix + 1, iy + 1);
    const top = a + (b - a) * tx;
    const bot = c + (d - c) * tx;
    return (top + (bot - top) * ty) * 2.0 - 1.0;
}

/// Fractal sum of value noise, roughly in [-1, 1].
pub fn fbm(seed: u32, x: f32, y: f32, octaves: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 0.5;
    var freq: f32 = 1;
    var norm: f32 = 0;
    var o: u32 = 0;
    while (o < octaves) : (o += 1) {
        sum += amp * valueNoise(seed +% o *% 7919, x * freq, y * freq);
        norm += amp;
        amp *= 0.5;
        freq *= 2.03;
    }
    return sum / norm;
}

/// Ridged fractal noise in [0, 1]: sharp crests, rounded valleys.
pub fn ridged(seed: u32, x: f32, y: f32, octaves: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 0.5;
    var freq: f32 = 1;
    var norm: f32 = 0;
    var o: u32 = 0;
    while (o < octaves) : (o += 1) {
        const r = 1.0 - @abs(valueNoise(seed +% 101 +% o *% 7919, x * freq, y * freq));
        sum += amp * r * r;
        norm += amp;
        amp *= 0.5;
        freq *= 2.1;
    }
    return sum / norm;
}

/// Depth (world units) the sea floor drops to within a few cells of the coast.
const shoreface: f32 = 0.6;

fn smoothstep(e0: f32, e1: f32, x: f32) f32 {
    const t = std.math.clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Height (world units, sea level 0) at normalised map position (u, v),
/// with u running west to east and v running north to south, both in [0, 1].
pub fn height(seed: u32, u: f32, v: f32) f32 {
    const pi = std.math.pi;
    const phase = unit(seed, 17, 29) * 2.0 * pi;

    // Coastline: where the land meets the sea, a wavy line in the south.
    const coast = 0.66 + 0.05 * fbm(seed +% 1, u * 2.2, 0.5, 3) + 0.02 * @sin(u * 5.0 + phase);
    const t = coast - v; // > 0 on land: distance inland (in map units)

    if (t <= 0) {
        // A shallow shelf where rivers can build deltas, then a drop to
        // deeper water towards the south edge.
        const off = -t;
        // Continuous with the land at the shore (depth 0 at the coast), so the
        // coastline is a clean curve rather than a staircase of cells. A short
        // steep shoreface first: new land has to be built by a river's load,
        // not by a film of sheet-wash filling a knee-deep margin.
        const depth = shoreface * (1.0 - @exp(-off / 0.006)) + 1.0 * (1.0 - @exp(-off / 0.06)) + 8.5 * smoothstep(0.07, 0.3, off);
        return -depth + 0.35 * fbm(seed +% 2, u * 9.0, v * 9.0, 3) * smoothstep(0.0, 0.05, off);
    }

    // Coastal plain rising gently inland, then a mountain range in the north.
    const plain = 20.0 * t;
    const range_mask = smoothstep(0.12, 0.55, t);
    const crest = ridged(seed +% 3, u * 3.2, v * 3.2, 5);
    const mountains = range_mask * (20.0 + 24.0 * crest);

    // A winding main valley that drains the range to the coast.
    const valley_x = 0.5 + 0.13 * @sin(v * 5.5 + phase) + 0.05 * fbm(seed +% 4, v * 3.0, 1.7, 3);
    const valley_w = 0.07 + 0.05 * t;
    const dv = (u - valley_x) / valley_w;
    const valley = @exp(-dv * dv);

    // A smaller tributary valley in the west.
    const trib_x = 0.2 + 0.06 * @sin(v * 7.0 + phase * 1.7);
    const dt = (u - trib_x) / 0.06;
    const trib = @exp(-dt * dt) * smoothstep(0.1, 0.35, t);

    // The main valley continues across the plain as a shallow lowland.
    var h = plain * (1.0 - 0.45 * valley) + mountains * (1.0 - 0.72 * valley) * (1.0 - 0.45 * trib);
    // Fine texture, stronger in the hills, fading out at the shore so the
    // coast stays continuous with the sea floor.
    h += (0.8 + 3.0 * range_mask) * fbm(seed +% 5, u * 14.0, v * 14.0, 4) * smoothstep(0.0, 0.05, t);
    return h;
}

test "hash is deterministic and seed-sensitive" {
    try std.testing.expectEqual(hash(1, 2, 3), hash(1, 2, 3));
    try std.testing.expect(hash(1, 2, 3) != hash(2, 2, 3));
    try std.testing.expect(hash(1, 2, 3) != hash(1, 3, 2));
}

test "noise stays in range" {
    var y: f32 = 0;
    while (y < 8) : (y += 0.37) {
        var x: f32 = 0;
        while (x < 8) : (x += 0.41) {
            const n = valueNoise(7, x, y);
            try std.testing.expect(n >= -1.0 and n <= 1.0);
            const r = ridged(7, x, y, 4);
            try std.testing.expect(r >= 0.0 and r <= 1.0);
        }
    }
}

test "default terrain has land in the north and sea in the south" {
    try std.testing.expect(height(1, 0.5, 0.05) > 5.0);
    try std.testing.expect(height(1, 0.5, 0.98) < 0.0);
}
