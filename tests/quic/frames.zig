// QUIC Frame parsing and generation (RFC 9000 Section 19)
// Focus: CRYPTO frames for handshake

const std = @import("std");
const packet = @import("packet.zig");

// Frame Types (RFC 9000 Section 19)
pub const FrameType = enum(u8) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06, // CRYPTO frame - critical for handshake
    new_token = 0x07,
    stream = 0x08,
    max_data = 0x10,
    max_stream_data = 0x11,
    max_streams_bidi = 0x12,
    max_streams_uni = 0x13,
    data_blocked = 0x14,
    stream_data_blocked = 0x15,
    streams_blocked_bidi = 0x16,
    streams_blocked_uni = 0x17,
    new_connection_id = 0x18,
    retire_connection_id = 0x19,
    path_challenge = 0x1a,
    path_response = 0x1b,
    connection_close = 0x1c,
    handshake_done = 0x1e,
    _,
};

// CRYPTO Frame (RFC 9000 Section 19.6)
// Used to carry TLS handshake messages
pub const CryptoFrame = struct {
    offset: u64, // Byte offset in crypto stream
    length: u64, // Length of crypto data
    data: []const u8, // Crypto data (TLS messages)

    pub fn parse(payload: []const u8) !CryptoFrame {
        var offset: usize = 0;

        // Frame type should already be consumed by caller
        // But we'll check if it's present
        if (payload.len == 0) {
            return error.IncompleteFrame;
        }

        // If first byte is frame type, skip it
        if (payload[0] == @intFromEnum(FrameType.crypto)) {
            offset += 1;
        }

        // Read offset (VarInt)
        const offset_result = try readVarInt(payload[offset..]);
        offset += offset_result.bytes_read;
        const frame_offset = offset_result.value;

        // Read length (VarInt)
        if (offset >= payload.len) {
            return error.IncompleteFrame;
        }
        const length_result = try readVarInt(payload[offset..]);
        offset += length_result.bytes_read;
        const frame_length = length_result.value;

        // Extract data
        if (offset + frame_length > payload.len) {
            return error.IncompleteFrame;
        }

        return CryptoFrame{
            .offset = frame_offset,
            .length = frame_length,
            .data = payload[offset .. offset + frame_length],
        };
    }

    // Parse from packet payload (assumes frame type already identified)
    pub fn parseFromPayload(payload: []const u8) !CryptoFrame {
        return parse(payload);
    }

    // Generate CRYPTO frame
    // Returns the number of bytes written to out_buf
    pub fn generate(
        frame_offset: u64,
        data: []const u8,
        out_buf: []u8,
    ) !usize {
        var offset: usize = 0;

        // Write frame type (0x06 = CRYPTO)
        if (offset >= out_buf.len) return error.BufferTooSmall;
        out_buf[offset] = @intFromEnum(FrameType.crypto);
        offset += 1;

        // Write offset (VarInt)
        const offset_bytes = try writeVarInt(out_buf[offset..], frame_offset);
        offset += offset_bytes;

        // Write length (VarInt)
        const length_bytes = try writeVarInt(out_buf[offset..], @intCast(data.len));
        offset += length_bytes;

        // Write data
        if (offset + data.len > out_buf.len) {
            return error.BufferTooSmall;
        }
        @memcpy(out_buf[offset .. offset + data.len], data);
        offset += data.len;

        return offset;
    }
};

// Variable-length integer encoding (RFC 9000 Section 16)
// Same as in packet.zig, but duplicated here for frame module independence
const VarIntResult = struct {
    value: u64,
    bytes_read: usize,
};

fn readVarInt(data: []const u8) !VarIntResult {
    if (data.len == 0) {
        return error.IncompleteVarInt;
    }

    const first_byte = data[0];
    const prefix = (first_byte & 0xC0) >> 6;

    return switch (prefix) {
        0 => VarIntResult{
            .value = @as(u64, first_byte & 0x3F),
            .bytes_read = 1,
        },
        1 => blk: {
            if (data.len < 2) return error.IncompleteVarInt;
            break :blk VarIntResult{
                .value = @as(u64, first_byte & 0x3F) << 8 | @as(u64, data[1]),
                .bytes_read = 2,
            };
        },
        2 => blk: {
            if (data.len < 4) return error.IncompleteVarInt;
            break :blk VarIntResult{
                .value = @as(u64, first_byte & 0x3F) << 24 |
                    @as(u64, data[1]) << 16 |
                    @as(u64, data[2]) << 8 |
                    @as(u64, data[3]),
                .bytes_read = 4,
            };
        },
        3 => blk: {
            if (data.len < 8) return error.IncompleteVarInt;
            break :blk VarIntResult{
                .value = @as(u64, first_byte & 0x3F) << 56 |
                    @as(u64, data[1]) << 48 |
                    @as(u64, data[2]) << 40 |
                    @as(u64, data[3]) << 32 |
                    @as(u64, data[4]) << 24 |
                    @as(u64, data[5]) << 16 |
                    @as(u64, data[6]) << 8 |
                    @as(u64, data[7]),
                .bytes_read = 8,
            };
        },
        else => return error.InvalidVarIntPrefix, // Should never happen (prefix is 2 bits)
    };
}

fn writeVarInt(buf: []u8, value: u64) !usize {
    if (value < (1 << 6)) {
        if (buf.len < 1) return error.BufferTooSmall;
        buf[0] = @truncate(value);
        return 1;
    } else if (value < (1 << 14)) {
        if (buf.len < 2) return error.BufferTooSmall;
        buf[0] = @truncate((value >> 8) | 0x40);
        buf[1] = @truncate(value);
        return 2;
    } else if (value < (1 << 30)) {
        if (buf.len < 4) return error.BufferTooSmall;
        buf[0] = @truncate((value >> 24) | 0x80);
        buf[1] = @truncate(value >> 16);
        buf[2] = @truncate(value >> 8);
        buf[3] = @truncate(value);
        return 4;
    } else {
        if (buf.len < 8) return error.BufferTooSmall;
        buf[0] = @truncate((value >> 56) | 0xC0);
        buf[1] = @truncate(value >> 48);
        buf[2] = @truncate(value >> 40);
        buf[3] = @truncate(value >> 32);
        buf[4] = @truncate(value >> 24);
        buf[5] = @truncate(value >> 16);
        buf[6] = @truncate(value >> 8);
        buf[7] = @truncate(value);
        return 8;
    }
}

// Extract CRYPTO frames from packet payload
// A packet payload may contain multiple frames
// Note: This function is now in handshake.zig for proper allocator management
// Keeping this for backward compatibility, but prefer handshake.extractCryptoFrames
pub fn extractCryptoFrames(payload: []const u8, allocator: std.mem.Allocator) !std.ArrayList(CryptoFrame) {
    // Zig 0.15.2: Use initCapacity for managed ArrayList
    var frames = std.ArrayList(CryptoFrame).initCapacity(allocator, 4) catch return error.OutOfMemory;
    errdefer frames.deinit();

    var offset: usize = 0;

    while (offset < payload.len) {
        // Check frame type
        if (payload[offset] == @intFromEnum(FrameType.crypto)) {
            // Parse CRYPTO frame
            const frame = try CryptoFrame.parseFromPayload(payload[offset..]);
            // Zig 0.15.2: append requires allocator
            try frames.append(allocator, frame);

            // Move offset past this frame
            // Frame type (1) + offset VarInt + length VarInt + data
            var frame_size: usize = 1; // Frame type
            const offset_result = try readVarInt(payload[offset + frame_size ..]);
            frame_size += offset_result.bytes_read;
            const length_result = try readVarInt(payload[offset + frame_size ..]);
            frame_size += length_result.bytes_read;
            frame_size += @intCast(length_result.value);

            offset += frame_size;
        } else {
            // Skip other frame types for now
            // TODO: Parse other frames or skip them properly
            offset += 1;
        }
    }

    return frames;
}
