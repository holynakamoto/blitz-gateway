// HTTP/2 Frame parsing and construction
// Optimized for zero-allocation and SIMD where possible

const std = @import("std");

pub const FrameType = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
};

pub const FrameFlags = packed struct(u8) {
    end_stream: bool = false,
    ack: bool = false,
    end_headers: bool = false,
    padded: bool = false,
    priority: bool = false,
    unused: u3 = 0,

    pub fn fromInt(flags: u8) FrameFlags {
        return @bitCast(flags);
    }

    pub fn toInt(self: FrameFlags) u8 {
        return @bitCast(self);
    }
};

pub const FrameHeader = packed struct {
    length: u24, // 24-bit length (max 16384)
    frame_type: FrameType,
    flags: u8,
    reserved: u1 = 0,
    stream_id: u31, // 31-bit stream ID

    pub const SIZE: usize = 9;

    pub fn parse(data: []const u8) !FrameHeader {
        if (data.len < SIZE) {
            return error.IncompleteFrame;
        }

        const length = std.mem.readInt(u24, data[0..3], .big);
        const frame_type = @as(FrameType, @enumFromInt(data[3]));
        const flags = data[4];
        const stream_id_raw = std.mem.readInt(u32, data[5..9], .big);
        const stream_id = @as(u31, @truncate(stream_id_raw & 0x7FFFFFFF));

        return FrameHeader{
            .length = length,
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };
    }

    pub fn serialize(self: FrameHeader, buf: []u8) !void {
        if (buf.len < SIZE) {
            return error.BufferTooSmall;
        }

        std.mem.writeInt(u24, buf[0..3], self.length, .big);
        buf[3] = @intFromEnum(self.frame_type);
        buf[4] = self.flags;
        const stream_id_u32: u32 = @intCast(self.stream_id);
        std.mem.writeInt(u32, buf[5..9], stream_id_u32, .big);
    }
};

pub const SettingsFrame = struct {
    header: FrameHeader,
    settings: []const Setting,

    pub const Setting = struct {
        id: u16,
        value: u32,
    };

    // SETTINGS frame IDs (RFC 7540 Section 6.5.2)
    pub const SETTINGS_HEADER_TABLE_SIZE: u16 = 0x1;
    pub const SETTINGS_ENABLE_PUSH: u16 = 0x2;
    pub const SETTINGS_MAX_CONCURRENT_STREAMS: u16 = 0x3;
    pub const SETTINGS_INITIAL_WINDOW_SIZE: u16 = 0x4;
    pub const SETTINGS_MAX_FRAME_SIZE: u16 = 0x5;
    pub const SETTINGS_MAX_HEADER_LIST_SIZE: u16 = 0x6;

    pub fn parse(data: []const u8, allocator: std.mem.Allocator) !SettingsFrame {
        const header = try FrameHeader.parse(data);
        if (header.frame_type != .settings) {
            return error.WrongFrameType;
        }

        if (header.length % 6 != 0) {
            return error.InvalidSettingsLength;
        }

        // Parse settings from payload
        var settings_list = std.ArrayList(SettingsFrame.Setting).initCapacity(allocator, 0);
        errdefer settings_list.deinit();

        var offset: usize = FrameHeader.SIZE;
        const num_settings = header.length / 6;

        for (0..num_settings) |_| {
            if (offset + 6 > data.len) {
                return error.IncompleteFrame;
            }

            const id = std.mem.readInt(u16, data[offset..][0..2], .big);
            const value = std.mem.readInt(u32, data[offset + 2 ..][0..4], .big);

            try settings_list.append(Setting{
                .id = id,
                .value = value,
            });

            offset += 6;
        }

        return SettingsFrame{
            .header = header,
            .settings = try settings_list.toOwnedSlice(allocator),
        };
    }

    // Serialize SETTINGS frame (for sending server settings)
    pub fn serialize(settings: []const Setting, buf: []u8, stream_id: u31, ack: bool) !usize {
        // SETTINGS ACK frames must have empty payload (RFC 7540 Section 6.5)
        const payload_size = if (ack) 0 else settings.len * 6;
        if (buf.len < FrameHeader.SIZE + payload_size) {
            return error.BufferTooSmall;
        }

        // Write frame header
        const header = FrameHeader{
            .length = @intCast(payload_size),
            .frame_type = .settings,
            .flags = if (ack) 0x01 else 0x00, // ACK flag
            .stream_id = stream_id,
        };
        try header.serialize(buf);

        // Write settings payload (only if not ACK)
        if (!ack) {
            var offset: usize = FrameHeader.SIZE;
            for (settings) |setting| {
                std.mem.writeInt(u16, buf[offset..][0..2], setting.id, .big);
                std.mem.writeInt(u32, buf[offset + 2 ..][0..4], setting.value, .big);
                offset += 6;
            }
        }

        return FrameHeader.SIZE + payload_size;
    }
};

pub const HeadersFrame = struct {
    header: FrameHeader,
    padding: ?u8 = null,
    priority: ?Priority = null,
    header_block: []const u8,

    pub const Priority = struct {
        exclusive: bool,
        stream_dependency: u31,
        weight: u8,
    };

    pub fn parse(data: []const u8) !HeadersFrame {
        const header = try FrameHeader.parse(data);
        if (header.frame_type != .headers) {
            return error.WrongFrameType;
        }

        var offset: usize = FrameHeader.SIZE;

        // Parse padding if present
        var padding: ?u8 = null;
        if (header.flags & 0x08 != 0) { // PADDED flag
            if (offset >= data.len) return error.IncompleteFrame;
            padding = data[offset];
            offset += 1;
        }

        // Parse priority if present
        var priority: ?Priority = null;
        if (header.flags & 0x20 != 0) { // PRIORITY flag
            if (offset + 5 > data.len) return error.IncompleteFrame;
            const dep_raw = std.mem.readInt(u32, data[offset..][0..4], .big);
            const exclusive = (dep_raw & 0x80000000) != 0;
            const stream_dependency = @as(u31, @truncate(dep_raw & 0x7FFFFFFF));
            const weight = data[offset + 4];
            priority = Priority{
                .exclusive = exclusive,
                .stream_dependency = stream_dependency,
                .weight = weight,
            };
            offset += 5;
        }

        // Calculate header block length
        const padding_len = if (padding) |p| p else 0;
        const header_block_len = header.length - (offset - FrameHeader.SIZE) - padding_len;

        if (offset + header_block_len > data.len) {
            return error.IncompleteFrame;
        }

        const header_block = data[offset..][0..header_block_len];

        return HeadersFrame{
            .header = header,
            .padding = padding,
            .priority = priority,
            .header_block = header_block,
        };
    }
};

pub const DataFrame = struct {
    header: FrameHeader,
    padding: ?u8 = null,
    data: []const u8,

    pub fn parse(data: []const u8) !DataFrame {
        const header = try FrameHeader.parse(data);
        if (header.frame_type != .data) {
            return error.WrongFrameType;
        }

        var offset: usize = FrameHeader.SIZE;

        // Parse padding if present
        var padding: ?u8 = null;
        if (header.flags & 0x08 != 0) { // PADDED flag
            if (offset >= data.len) return error.IncompleteFrame;
            padding = data[offset];
            offset += 1;
        }

        // Calculate data length
        const padding_len = if (padding) |p| p else 0;
        const data_len = header.length - (offset - FrameHeader.SIZE) - padding_len;

        if (offset + data_len > data.len) {
            return error.IncompleteFrame;
        }

        const frame_data = data[offset..][0..data_len];

        return DataFrame{
            .header = header,
            .padding = padding,
            .data = frame_data,
        };
    }
};

// HTTP/2 Connection Preface
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

// Helper functions for generating response frames

// Generate SETTINGS ACK frame
pub fn generateSettingsAck(buf: []u8) !usize {
    if (buf.len < FrameHeader.SIZE) {
        return error.BufferTooSmall;
    }

    const header = FrameHeader{
        .length = 0,
        .frame_type = .settings,
        .flags = 0x01, // ACK flag
        .stream_id = 0,
    };

    try header.serialize(buf);
    return FrameHeader.SIZE;
}

// Generate server SETTINGS frame (initial settings, not ACK)
pub fn generateServerSettings(settings: []const SettingsFrame.Setting, buf: []u8) !usize {
    return SettingsFrame.serialize(settings, buf, 0, false);
}

// Generate PING ACK frame
pub fn generatePingAck(opaque_data: []const u8, buf: []u8) !usize {
    if (opaque_data.len != 8) {
        return error.InvalidPingData;
    }
    if (buf.len < FrameHeader.SIZE + 8) {
        return error.BufferTooSmall;
    }

    const header = FrameHeader{
        .length = 8,
        .frame_type = .ping,
        .flags = 0x01, // ACK flag
        .stream_id = 0,
    };

    try header.serialize(buf);
    @memcpy(buf[FrameHeader.SIZE..][0..8], opaque_data);

    return FrameHeader.SIZE + 8;
}

// Generate GOAWAY frame
pub fn generateGoaway(last_stream_id: u31, error_code: u32, buf: []u8) !usize {
    if (buf.len < FrameHeader.SIZE + 8) {
        return error.BufferTooSmall;
    }

    const header = FrameHeader{
        .length = 8,
        .frame_type = .goaway,
        .flags = 0,
        .stream_id = 0,
    };

    try header.serialize(buf);

    // Write GOAWAY payload
    std.mem.writeInt(u32, buf[FrameHeader.SIZE..][0..4], @intCast(last_stream_id), .big);
    std.mem.writeInt(u32, buf[FrameHeader.SIZE + 4 ..][0..4], error_code, .big);

    return FrameHeader.SIZE + 8;
}

// Error codes (RFC 7540 Section 7)
pub const ErrorCode = enum(u32) {
    no_error = 0x0,
    protocol_error = 0x1,
    internal_error = 0x2,
    flow_control_error = 0x3,
    settings_timeout = 0x4,
    stream_closed = 0x5,
    frame_size_error = 0x6,
    refuse_stream = 0x7,
    cancel = 0x8,
    compression_error = 0x9,
    connect_error = 0xa,
    enhance_your_calm = 0xb,
    inadequate_security = 0xc,
    http_1_1_required = 0xd,
};
