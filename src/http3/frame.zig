// HTTP/3 Frame parsing and generation (RFC 9114)
// Phase 2: HTTP/3 framing on top of QUIC streams
//
// IMPORTANT: HTTP/3 uses QPACK for header compression, NOT HPACK!
// RFC 9114 §4.2: "The use of HPACK with HTTP/3 is not supported"

const std = @import("std");
pub const qpack = @import("qpack.zig");

// HTTP/3 Frame Types (RFC 9114 Section 7.2)
pub const FrameType = enum(u64) {
    data = 0x00,
    headers = 0x01,
    cancel_push = 0x03,
    settings = 0x04,
    push_promise = 0x05,
    goaway = 0x07,
    max_push_id = 0x0d,
    duplicate_push = 0x0e,
    _,
};

// DATA Frame (RFC 9114 Section 7.2.1)
pub const DataFrame = struct {
    data: []const u8,

    pub fn parse(data: []const u8) !DataFrame {
        // DATA frame format: Type (varint) + Payload
        var offset: usize = 0;

        // Read frame type (should be 0x00)
        const type_result = try readVarInt(data[offset..]);
        offset += type_result.bytes_read;

        if (type_result.value != @intFromEnum(FrameType.data)) {
            return error.InvalidFrameType;
        }

        // Remaining data is payload
        const payload = data[offset..];

        return DataFrame{
            .data = payload,
        };
    }

    pub fn generate(writer: anytype, data: []const u8) !void {
        // Write frame type (0x00 = DATA)
        _ = try writeVarInt(writer, @intFromEnum(FrameType.data));
        // Write payload
        try writer.writeAll(data);
    }
};

// HEADERS Frame (RFC 9114 Section 7.2.2)
pub const HeadersFrame = struct {
    header_block: []const u8, // QPACK-encoded header block

    pub fn parse(data: []const u8) !HeadersFrame {
        var offset: usize = 0;

        // Read frame type (should be 0x01)
        const type_result = try readVarInt(data[offset..]);
        offset += type_result.bytes_read;

        if (type_result.value != @intFromEnum(FrameType.headers)) {
            return error.InvalidFrameType;
        }

        // Remaining data is QPACK-encoded header block
        const header_block = data[offset..];

        return HeadersFrame{
            .header_block = header_block,
        };
    }

    pub fn generate(writer: anytype, header_block: []const u8) !void {
        // Write frame type (0x01 = HEADERS)
        _ = try writeVarInt(writer, @intFromEnum(FrameType.headers));
        // Write QPACK-encoded header block
        try writer.writeAll(header_block);
    }

    // Generate HEADERS frame from header fields using QPACK encoding
    // This is the correct way to send headers in HTTP/3
    pub fn generateFromHeaders(writer: anytype, encoder: *qpack.QpackEncoder, headers: []const qpack.HeaderField) !void {
        // Encode headers with QPACK
        const encoded = try encoder.encode(headers);
        defer encoder.allocator.free(encoded);

        // Write frame type (0x01 = HEADERS)
        _ = try writeVarInt(writer, @intFromEnum(FrameType.headers));
        // Write QPACK-encoded header block
        try writer.writeAll(encoded);
    }

    // Decode HEADERS frame content into header fields using QPACK
    pub fn decodeHeaders(self: HeadersFrame, decoder: *qpack.QpackDecoder) ![]qpack.HeaderField {
        return decoder.decode(self.header_block);
    }
};

// SETTINGS Frame (RFC 9114 Section 7.2.4)
pub const SettingsFrame = struct {
    settings: std.ArrayList(Setting),
    allocator: std.mem.Allocator,

    pub const Setting = struct {
        identifier: u64,
        value: u64,
    };

    pub fn init(allocator: std.mem.Allocator) SettingsFrame {
        return SettingsFrame{
            // Zig 0.15.2: Use initCapacity
            .settings = std.ArrayList(Setting).initCapacity(allocator, 8) catch @panic("Failed to init settings"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SettingsFrame) void {
        // Zig 0.15.2: deinit requires allocator
        self.settings.deinit(self.allocator);
    }

    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !SettingsFrame {
        var frame = SettingsFrame.init(allocator);
        var offset: usize = 0;

        // Read frame type (should be 0x04)
        const type_result = try readVarInt(data[offset..]);
        offset += type_result.bytes_read;

        if (type_result.value != @intFromEnum(FrameType.settings)) {
            return error.InvalidFrameType;
        }

        // Parse settings (varint pairs)
        while (offset < data.len) {
            const id_result = try readVarInt(data[offset..]);
            offset += id_result.bytes_read;

            if (offset >= data.len) break;

            const value_result = try readVarInt(data[offset..]);
            offset += value_result.bytes_read;

            // Zig 0.15.2: append requires allocator
            try frame.settings.append(Setting{
                .identifier = id_result.value,
                .value = value_result.value,
            });
        }

        return frame;
    }

    pub fn generate(writer: anytype, settings: []const Setting) !void {
        // Write frame type (0x04 = SETTINGS)
        _ = try writeVarInt(writer, @intFromEnum(FrameType.settings));
        // Write settings (varint pairs)
        for (settings) |setting| {
            _ = try writeVarInt(writer, setting.identifier);
            _ = try writeVarInt(writer, setting.value);
        }
    }
};

// GOAWAY Frame (RFC 9114 Section 7.2.6)
pub const GoawayFrame = struct {
    stream_id: u64,

    pub fn parse(data: []const u8) !GoawayFrame {
        var offset: usize = 0;

        // Read frame type (should be 0x07)
        const type_result = try readVarInt(data[offset..]);
        offset += type_result.bytes_read;

        if (type_result.value != @intFromEnum(FrameType.goaway)) {
            return error.InvalidFrameType;
        }

        // Read stream ID
        const stream_id_result = try readVarInt(data[offset..]);

        return GoawayFrame{
            .stream_id = stream_id_result.value,
        };
    }

    pub fn generate(writer: anytype, stream_id: u64) !void {
        // Write frame type (0x07 = GOAWAY)
        _ = try writeVarInt(writer, @intFromEnum(FrameType.goaway));
        // Write stream ID
        _ = try writeVarInt(writer, stream_id);
    }
};

// Variable-length integer encoding (same as QUIC)
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
        else => return error.InvalidVarInt,
    };
}

fn writeVarInt(writer: anytype, value: u64) !usize {
    if (value < (1 << 6)) {
        try writer.writeByte(@truncate(value));
        return 1;
    } else if (value < (1 << 14)) {
        try writer.writeByte(@truncate((value >> 8) | 0x40));
        try writer.writeByte(@truncate(value));
        return 2;
    } else if (value < (1 << 30)) {
        try writer.writeByte(@truncate((value >> 24) | 0x80));
        try writer.writeByte(@truncate(value >> 16));
        try writer.writeByte(@truncate(value >> 8));
        try writer.writeByte(@truncate(value));
        return 4;
    } else {
        try writer.writeByte(@truncate((value >> 56) | 0xC0));
        try writer.writeByte(@truncate(value >> 48));
        try writer.writeByte(@truncate(value >> 40));
        try writer.writeByte(@truncate(value >> 32));
        try writer.writeByte(@truncate(value >> 24));
        try writer.writeByte(@truncate(value >> 16));
        try writer.writeByte(@truncate(value >> 8));
        try writer.writeByte(@truncate(value));
        return 8;
    }
}
