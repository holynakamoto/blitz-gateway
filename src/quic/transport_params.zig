// QUIC Transport Parameters (RFC 9000 Section 18)
// Transport parameters are sent during the TLS handshake and define connection limits

const std = @import("std");
const packet = @import("packet.zig");

// Transport Parameter IDs (RFC 9000 Section 18.2)
pub const TransportParameterId = enum(u64) {
    original_destination_connection_id = 0x00,
    max_idle_timeout = 0x01,
    stateless_reset_token = 0x02,
    max_udp_payload_size = 0x03,
    initial_max_data = 0x04,
    initial_max_stream_data_bidi_local = 0x05,
    initial_max_stream_data_bidi_remote = 0x06,
    initial_max_stream_data_uni = 0x07,
    initial_max_streams_bidi = 0x08,
    initial_max_streams_uni = 0x09,
    ack_delay_exponent = 0x0a,
    max_ack_delay = 0x0b,
    disable_active_migration = 0x0c,
    preferred_address = 0x0d,
    active_connection_id_limit = 0x0e,
    initial_source_connection_id = 0x0f,
    retry_source_connection_id = 0x10,
    _,
};

// Transport Parameters structure
pub const TransportParameters = struct {
    max_idle_timeout: u64 = 30_000, // 30 seconds (milliseconds)
    max_udp_payload_size: u64 = 65536, // QUIC max packet size (64KB)
    initial_max_data: u64 = 10_000_000, // 10 MB
    initial_max_stream_data_bidi_local: u64 = 1_000_000, // 1 MB
    initial_max_stream_data_bidi_remote: u64 = 1_000_000, // 1 MB
    initial_max_stream_data_uni: u64 = 1_000_000, // 1 MB
    initial_max_streams_bidi: u64 = 100,
    initial_max_streams_uni: u64 = 100,
    ack_delay_exponent: u64 = 3,
    max_ack_delay: u64 = 25, // 25ms
    disable_active_migration: bool = true,
    active_connection_id_limit: u64 = 2,

    // Encode transport parameters as TLV (Type-Length-Value) format
    // Returns number of bytes written
    pub fn encode(self: TransportParameters, buf: []u8) !usize {
        var offset: usize = 0;

        // Encode each parameter as: VarInt ID, VarInt Length, Value
        const params = [_]struct { id: TransportParameterId, value: u64 }{
            .{ .id = .max_idle_timeout, .value = self.max_idle_timeout },
            .{ .id = .max_udp_payload_size, .value = self.max_udp_payload_size },
            .{ .id = .initial_max_data, .value = self.initial_max_data },
            .{ .id = .initial_max_stream_data_bidi_local, .value = self.initial_max_stream_data_bidi_local },
            .{ .id = .initial_max_stream_data_bidi_remote, .value = self.initial_max_stream_data_bidi_remote },
            .{ .id = .initial_max_stream_data_uni, .value = self.initial_max_stream_data_uni },
            .{ .id = .initial_max_streams_bidi, .value = self.initial_max_streams_bidi },
            .{ .id = .initial_max_streams_uni, .value = self.initial_max_streams_uni },
            .{ .id = .ack_delay_exponent, .value = self.ack_delay_exponent },
            .{ .id = .max_ack_delay, .value = self.max_ack_delay },
            .{ .id = .active_connection_id_limit, .value = self.active_connection_id_limit },
        };

        for (params) |param| {
            // Write parameter ID (VarInt)
            const id_bytes = try writeVarInt(buf[offset..], @intFromEnum(param.id));
            offset += id_bytes;

            // Write parameter length (VarInt) - 8 bytes for u64 value
            const len_bytes = try writeVarInt(buf[offset..], 8);
            offset += len_bytes;

            // Write parameter value (8 bytes, big-endian)
            if (offset + 8 > buf.len) {
                return error.BufferTooSmall;
            }
            std.mem.writeInt(u64, buf[offset..][0..8], param.value, .big);
            offset += 8;
        }

        // Encode disable_active_migration (boolean, 0 bytes value)
        const disable_id_bytes = try writeVarInt(buf[offset..], @intFromEnum(TransportParameterId.disable_active_migration));
        offset += disable_id_bytes;
        const disable_len_bytes = try writeVarInt(buf[offset..], 0);
        offset += disable_len_bytes;

        return offset;
    }

    // Decode transport parameters from TLV format
    pub fn decode(data: []const u8) !TransportParameters {
        var params = TransportParameters{};
        var offset: usize = 0;

        while (offset < data.len) {
            // Read parameter ID (VarInt)
            const id_result = try readVarInt(data[offset..]);
            offset += id_result.bytes_read;
            const param_id = @as(TransportParameterId, @enumFromInt(id_result.value));

            // Read parameter length (VarInt)
            const len_result = try readVarInt(data[offset..]);
            offset += len_result.bytes_read;
            const param_len = len_result.value;

            // Read parameter value
            if (offset + param_len > data.len) {
                return error.IncompleteTransportParameters;
            }

            const value: u64 = if (param_len == 0) 0 else if (param_len == 8)
                std.mem.readInt(u64, data[offset..][0..8], .big)
            else
                return error.InvalidParameterLength;

            offset += param_len;

            // Set parameter value
            switch (param_id) {
                .max_idle_timeout => params.max_idle_timeout = value,
                .max_udp_payload_size => params.max_udp_payload_size = value,
                .initial_max_data => params.initial_max_data = value,
                .initial_max_stream_data_bidi_local => params.initial_max_stream_data_bidi_local = value,
                .initial_max_stream_data_bidi_remote => params.initial_max_stream_data_bidi_remote = value,
                .initial_max_stream_data_uni => params.initial_max_stream_data_uni = value,
                .initial_max_streams_bidi => params.initial_max_streams_bidi = value,
                .initial_max_streams_uni => params.initial_max_streams_uni = value,
                .ack_delay_exponent => params.ack_delay_exponent = value,
                .max_ack_delay => params.max_ack_delay = value,
                .disable_active_migration => params.disable_active_migration = (value != 0),
                .active_connection_id_limit => params.active_connection_id_limit = value,
                else => {
                    // Unknown parameter - skip it
                },
            }
        }

        return params;
    }
};

// VarInt encoding/decoding helpers (same as in packet.zig)
fn readVarInt(data: []const u8) !struct { value: u64, bytes_read: usize } {
    if (data.len == 0) {
        return error.IncompleteVarInt;
    }

    const first_byte = data[0];
    const prefix = (first_byte & 0xC0) >> 6;

    return switch (prefix) {
        0 => .{ .value = @as(u64, first_byte & 0x3F), .bytes_read = 1 },
        1 => blk: {
            if (data.len < 2) return error.IncompleteVarInt;
            break :blk .{ .value = @as(u64, first_byte & 0x3F) << 8 | @as(u64, data[1]), .bytes_read = 2 };
        },
        2 => blk: {
            if (data.len < 4) return error.IncompleteVarInt;
            break :blk .{ .value = @as(u64, first_byte & 0x3F) << 24 | @as(u64, data[1]) << 16 | @as(u64, data[2]) << 8 | @as(u64, data[3]), .bytes_read = 4 };
        },
        3 => blk: {
            if (data.len < 8) return error.IncompleteVarInt;
            break :blk .{ .value = @as(u64, first_byte & 0x3F) << 56 | @as(u64, data[1]) << 48 | @as(u64, data[2]) << 40 | @as(u64, data[3]) << 32 | @as(u64, data[4]) << 24 | @as(u64, data[5]) << 16 | @as(u64, data[6]) << 8 | @as(u64, data[7]), .bytes_read = 8 };
        },
        else => return error.InvalidVarIntPrefix,
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
