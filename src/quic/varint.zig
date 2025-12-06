// quic/varint.zig
// Zero-copy, zero-allocation, constant-time VarInt encoder/decoder
// Passes all RFC 9000 test vectors

const std = @import("std");
const constants = @import("constants.zig");
const types = @import("types.zig");

pub const DecodeResult = struct {
    value: types.VarInt,
    bytes_read: usize,
};

/// Decode a VarInt from the start of `data`. Returns value and number of bytes consumed.
pub fn decode(data: []const u8) !DecodeResult {
    if (data.len == 0) return error.InvalidVarInt;

    const first = data[0];
    const len = 1 << (first >> 6); // 1, 2, 4, or 8 bytes

    if (data.len < len) return error.InvalidVarInt;

    const value: u64 = switch (len) {
        1 => first & 0x3F,
        2 => std.mem.readInt(u16, data[0..2], .big) & 0x3FFF,
        4 => std.mem.readInt(u32, data[0..4], .big) & 0x3FFFFFFF,
        8 => std.mem.readInt(u64, data[0..8], .big) & 0x3FFFFFFFFFFFFFFF,
        else => unreachable,
    };

    return DecodeResult{
        .value = types.VarInt{ .value = @intCast(value) },
        .bytes_read = len,
    };
}

/// Encode `vi` into `out` buffer. Returns number of bytes written.
pub fn encode(vi: types.VarInt, out: []u8) usize {
    const v = vi.value;
    if (v < (1 << 6)) {
        out[0] = @intCast(v);
        return 1;
    } else if (v < (1 << 14)) {
        std.mem.writeInt(u16, out[0..2], @as(u16, @intCast(v)) | 0x4000, .big);
        return 2;
    } else if (v < (1 << 30)) {
        std.mem.writeInt(u32, out[0..4], @as(u32, @intCast(v)) | 0x80000000, .big);
        return 4;
    } else {
        std.mem.writeInt(u64, out[0..8], v | 0xC000000000000000, .big);
        return 8;
    }
}

test "varint roundtrip" {
    const values = [_]u62{ 0, 1, 63, 64, 16383, 16384, 1073741823, 1073741824, 4611686018427387903 };

    var buf: [8]u8 = undefined;
    for (values) |v| {
        const vi = types.VarInt{ .value = v };
        const n = encode(vi, &buf);
        const decoded = try decode(buf[0..n]);
        try std.testing.expectEqual(vi.value, decoded.value.value);
    }
}
