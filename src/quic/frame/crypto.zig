// CRYPTO Frame (RFC 9000 Section 19.6)
// Carries cryptographic handshake messages

const std = @import("std");
const constants = @import("../constants.zig");
const varint = @import("../varint.zig");
const types = @import("../types.zig");

pub const CryptoFrame = struct {
    offset: u64,
    length: u64,
    data: []const u8,

    /// Parse a CRYPTO frame from a byte slice
    pub fn parse(data: []const u8) !CryptoFrame {
        if (data.len < 1) {
            return error.InsufficientData;
        }

        const frame_type = data[0];
        if (frame_type != constants.FRAME_TYPE_CRYPTO) {
            return error.InvalidFrameType;
        }

        var pos: usize = 1;

        // Offset (varint)
        const offset_result = try varint.decode(data[pos..]);
        const offset = offset_result.value;
        pos += offset_result.bytes_read;

        // Length (varint)
        if (pos >= data.len) {
            return error.InsufficientData;
        }
        const length_result = try varint.decode(data[pos..]);
        const length = length_result.value;
        pos += length_result.bytes_read;

        // Data
        if (pos + length > data.len) {
            return error.InsufficientData;
        }
        const frame_data = data[pos..pos+@as(usize, length)];

        return CryptoFrame{
            .offset = offset,
            .length = length,
            .data = frame_data,
        };
    }

    /// Write a CRYPTO frame to a writer
    pub fn write(self: *const CryptoFrame, writer: anytype) !usize {
        var written: usize = 0;

        // Frame type
        try writer.writeByte(constants.FRAME_TYPE_CRYPTO);
        written += 1;

        // Offset (varint)
        const offset_varint = types.VarInt{ .value = @intCast(self.offset) };
        var offset_buf: [8]u8 = undefined;
        const offset_len = varint.encode(offset_varint, &offset_buf);
        try writer.writeAll(offset_buf[0..offset_len]);
        written += offset_len;

        // Length (varint)
        const length_varint = types.VarInt{ .value = @intCast(self.length) };
        var length_buf: [8]u8 = undefined;
        const length_len = varint.encode(length_varint, &length_buf);
        try writer.writeAll(length_buf[0..length_len]);
        written += length_len;

        // Data
        try writer.writeAll(self.data);
        written += self.data.len;

        return written;
    }

    /// Create a CRYPTO frame
    pub fn create(offset: u64, data: []const u8) CryptoFrame {
        return CryptoFrame{
            .offset = offset,
            .length = @intCast(data.len),
            .data = data,
        };
    }
};

// Test helpers
test "crypto frame parse/write" {
    const test_data = "Hello, QUIC!";
    const frame = CryptoFrame.create(0, test_data);

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const written = try frame.write(stream.writer());

    const parsed = try CryptoFrame.parse(buf[0..written]);
    try std.testing.expectEqual(@as(u64, 0), parsed.offset);
    try std.testing.expectEqual(@as(u64, test_data.len), parsed.length);
    try std.testing.expectEqualStrings(test_data, parsed.data);
}

