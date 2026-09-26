//! Minimal PNG writer for the heightmap export: 16-bit greyscale, one tEXt
//! chunk, and zlib "stored" (uncompressed) deflate blocks. No compression
//! keeps the encoder tiny and exact; a 512 x 512 export is about 513 KiB.

const std = @import("std");

const crc_table: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var t: [256]u32 = undefined;
    for (0..256) |n| {
        var c: u32 = @intCast(n);
        for (0..8) |_| c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        t[n] = c;
    }
    break :blk t;
};

pub fn crc32(bytes: []const u8) u32 {
    return crcUpdate(0xFFFFFFFF, bytes) ^ 0xFFFFFFFF;
}

fn crcUpdate(start: u32, bytes: []const u8) u32 {
    var c = start;
    for (bytes) |x| c = crc_table[(c ^ x) & 0xFF] ^ (c >> 8);
    return c;
}

const max_stored = 65535;

/// Bytes needed for an n x n image with `text_len` bytes of description.
pub fn encodedSize(n: usize, text_len: usize) usize {
    const raw = n * (1 + 2 * n);
    const blocks = (raw + max_stored - 1) / max_stored;
    const idat = 2 + raw + 5 * blocks + 4;
    const text = if (text_len > 0) 12 + "Description".len + 1 + text_len else 0;
    return 8 + (12 + 13) + text + (12 + idat) + 12;
}

const Out = struct {
    buf: []u8,
    pos: usize = 0,

    fn byte(self: *Out, x: u8) void {
        self.buf[self.pos] = x;
        self.pos += 1;
    }
    fn bytes(self: *Out, xs: []const u8) void {
        @memcpy(self.buf[self.pos..][0..xs.len], xs);
        self.pos += xs.len;
    }
    fn u32be(self: *Out, x: u32) void {
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], x, .big);
        self.pos += 4;
    }
    /// Writes the chunk length and type; returns where the CRC starts.
    fn beginChunk(self: *Out, len: u32, kind: *const [4]u8) usize {
        self.u32be(len);
        const at = self.pos;
        self.bytes(kind);
        return at;
    }
    fn endChunk(self: *Out, crc_from: usize) void {
        self.u32be(crc32(self.buf[crc_from..self.pos]));
    }
};

/// Streams raw bytes into stored deflate blocks and keeps the Adler-32.
const Stored = struct {
    out: *Out,
    remaining: usize,
    in_block: usize = 0,
    a: u32 = 1,
    b: u32 = 0,

    fn put(self: *Stored, x: u8) void {
        if (self.in_block == 0) {
            const len: u16 = @intCast(@min(self.remaining, max_stored));
            self.out.byte(if (self.remaining <= max_stored) 1 else 0); // BFINAL, BTYPE=00
            self.out.byte(@truncate(len));
            self.out.byte(@truncate(len >> 8));
            self.out.byte(@truncate(~len));
            self.out.byte(@truncate(~len >> 8));
            self.in_block = len;
        }
        self.out.byte(x);
        self.in_block -= 1;
        self.remaining -= 1;
        self.a = (self.a + x) % 65521;
        self.b = (self.b + self.a) % 65521;
    }
};

/// Encodes an n x n greyscale image, 16 bits per sample. `src` is read at
/// `first + y * stride + x`; `lo` maps to 0 and `hi` to 65535. `text` goes
/// into a tEXt "Description" chunk, which the PNG spec defines as Latin-1
/// (ISO 8859-1) with no NUL bytes; the caller encodes it that way. Returns
/// the number of bytes written to `out` (which must hold `encodedSize`).
pub fn encodeGray16(out_buf: []u8, n: u32, src: []const f32, first: usize, stride: usize, lo: f32, hi: f32, text: []const u8) usize {
    var o = Out{ .buf = out_buf };
    o.bytes(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });

    var c = o.beginChunk(13, "IHDR");
    o.u32be(n);
    o.u32be(n);
    o.bytes(&.{ 16, 0, 0, 0, 0 }); // bit depth 16, greyscale, deflate, filter 0, no interlace
    o.endChunk(c);

    if (text.len > 0) {
        c = o.beginChunk(@intCast("Description".len + 1 + text.len), "tEXt");
        o.bytes("Description");
        o.byte(0);
        o.bytes(text);
        o.endChunk(c);
    }

    const nn: usize = n;
    const raw = nn * (1 + 2 * nn);
    const blocks = (raw + max_stored - 1) / max_stored;
    c = o.beginChunk(@intCast(2 + raw + 5 * blocks + 4), "IDAT");
    o.byte(0x78); // zlib: deflate, 32K window
    o.byte(0x01); // no preset dictionary, fastest; (0x7801 % 31 == 0)
    var z = Stored{ .out = &o, .remaining = raw };
    const span = hi - lo;
    const scale: f32 = if (span > 0) 65535.0 / span else 0;
    for (0..nn) |y| {
        z.put(0); // filter: none
        const row = first + y * stride;
        for (src[row .. row + nn]) |h| {
            const q = std.math.clamp((h - lo) * scale, 0, 65535);
            const v: u16 = @intFromFloat(@round(q));
            z.put(@truncate(v >> 8));
            z.put(@truncate(v));
        }
    }
    o.u32be((z.b << 16) | z.a);
    o.endChunk(c);

    c = o.beginChunk(0, "IEND");
    o.endChunk(c);
    return o.pos;
}

test "crc32 matches the standard check value" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
}

test "encodes a valid 16-bit greyscale PNG" {
    const n = 4;
    var src: [36]f32 = undefined;
    for (&src, 0..) |*v, i| v.* = @floatFromInt(i);
    var buf: [encodedSize(n, 5)]u8 = undefined;
    // interior of a 6 x 6 padded grid starts at index 7
    const len = encodeGray16(&buf, n, &src, 7, 6, 7, 28, "hello");
    try std.testing.expectEqual(buf.len, len);
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, buf[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", buf[12..16]);
    try std.testing.expectEqual(@as(u8, 16), buf[24]); // bit depth
    try std.testing.expectEqual(@as(u8, 0), buf[25]); // greyscale
    // Every chunk's CRC checks out and the chunks tile the file exactly.
    var pos: usize = 8;
    var kinds: usize = 0;
    while (pos < len) {
        const clen = std.mem.readInt(u32, buf[pos..][0..4], .big);
        const body = buf[pos + 4 .. pos + 8 + clen];
        try std.testing.expectEqual(crc32(body), std.mem.readInt(u32, buf[pos + 8 + clen ..][0..4], .big));
        pos += 12 + clen;
        kinds += 1;
    }
    try std.testing.expectEqual(len, pos);
    try std.testing.expectEqual(@as(usize, 4), kinds); // IHDR tEXt IDAT IEND
    // First pixel (src[7] = lo) is 0, last (src[28] = hi) is 65535.
    const idat = std.mem.indexOf(u8, &buf, "IDAT").? + 4;
    const raw0 = idat + 2 + 5; // zlib header + stored block header
    try std.testing.expectEqual(@as(u8, 0), buf[raw0]); // filter byte
    try std.testing.expectEqual(@as(u8, 0), buf[raw0 + 1]);
    try std.testing.expectEqual(@as(u8, 0), buf[raw0 + 2]);
    const last = raw0 + 4 * 9 - 2;
    try std.testing.expectEqual(@as(u8, 0xFF), buf[last]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[last + 1]);
}

test "large images split into several stored blocks" {
    const n = 200; // 200 * 401 bytes of raw data > 65535
    try std.testing.expect(n * (1 + 2 * n) > max_stored);
    const src = try std.testing.allocator.alloc(f32, n * n);
    defer std.testing.allocator.free(src);
    @memset(src, 1);
    const buf = try std.testing.allocator.alloc(u8, encodedSize(n, 0));
    defer std.testing.allocator.free(buf);
    const len = encodeGray16(buf, n, src, 0, n, 0, 2, "");
    try std.testing.expectEqual(buf.len, len);
}
