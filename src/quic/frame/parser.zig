// Frame Parser (RFC 9000 Section 19)
// Zero-copy frame parsing from packet payloads

const std = @import("std");
const constants = @import("../constants.zig");
const types = @import("../types.zig");
const varint = @import("../varint.zig");
const Frame = @import("types.zig").Frame;
const CryptoFrame = @import("crypto.zig").CryptoFrame;

/// Parse frames from a decrypted packet payload
/// Returns a list of frames found in the payload
pub fn parseFrames(allocator: std.mem.Allocator, payload: []const u8) !std.ArrayList(Frame) {
    var frames = std.ArrayList(Frame).init(allocator);
    errdefer frames.deinit();

    var pos: usize = 0;
    while (pos < payload.len) {
        const frame = try parseFrame(payload[pos..]);
        try frames.append(frame.frame);
        pos += frame.bytes_consumed;
    }

    return frames;
}

const ParseResult = struct {
    frame: Frame,
    bytes_consumed: usize,
};

/// Parse a single frame from the start of a byte slice
fn parseFrame(data: []const u8) !ParseResult {
    if (data.len < 1) {
        return error.InsufficientData;
    }

    const frame_type = data[0];

    return switch (frame_type) {
        constants.FRAME_TYPE_PADDING => {
            // PADDING frame: just 0x00 bytes, consume all padding
            var consumed: usize = 1;
            while (consumed < data.len and data[consumed] == constants.FRAME_TYPE_PADDING) {
                consumed += 1;
            }
            return ParseResult{
                .frame = Frame{ .padding = {} },
                .bytes_consumed = consumed,
            };
        },
        constants.FRAME_TYPE_PING => ParseResult{
            .frame = Frame{ .ping = {} },
            .bytes_consumed = 1,
        },
        constants.FRAME_TYPE_CRYPTO => {
            const crypto_frame = try CryptoFrame.parse(data);
            // Calculate bytes consumed: frame type (1) + offset varint + length varint + data
            var temp_buf: [8]u8 = undefined;
            const offset_varint = types.VarInt{ .value = @intCast(crypto_frame.offset) };
            const offset_len = varint.encode(offset_varint, &temp_buf);
            const length_varint = types.VarInt{ .value = @intCast(crypto_frame.length) };
            const length_len = varint.encode(length_varint, &temp_buf);
            
            return ParseResult{
                .frame = Frame{ .crypto = Frame.CryptoFrame{
                    .offset = crypto_frame.offset,
                    .length = crypto_frame.length,
                    .data = crypto_frame.data,
                } },
                .bytes_consumed = 1 + // frame type
                    offset_len +
                    length_len +
                    crypto_frame.data.len,
            };
        },
        else => {
            // For now, return unsupported frame type
            // TODO: Implement all frame types
            return error.UnsupportedFrameType;
        },
    };
}

