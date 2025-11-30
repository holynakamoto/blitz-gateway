// QUIC Packet parsing and generation (RFC 9000)
// Phase 1: Basic packet structures and parsing

const std = @import("std");

// QUIC Version (RFC 9000)
pub const QUIC_VERSION_1: u32 = 0x00000001;

// Packet Type Masks (RFC 9000 Section 17.2)
// These are the values after extracting bits 6-7 and shifting right by 4
pub const PACKET_TYPE_MASK: u8 = 0x30;
pub const PACKET_TYPE_INITIAL: u8 = 0x00 >> 4; // 0
pub const PACKET_TYPE_0RTT: u8 = 0x10 >> 4; // 1
pub const PACKET_TYPE_HANDSHAKE: u8 = 0x20 >> 4; // 2
pub const PACKET_TYPE_RETRY: u8 = 0x30 >> 4; // 3

// Long Header Packet (RFC 9000 Section 17.2.1)
pub const LongHeaderPacket = struct {
    packet_type: u8, // Bits 6-7 of first byte
    version: u32,
    dest_conn_id: []const u8,
    src_conn_id: []const u8,
    payload: []const u8,
    
    pub fn parse(data: []const u8) !LongHeaderPacket {
        if (data.len < 7) {
            return error.IncompletePacket;
        }
        
        const first_byte = data[0];
        const packet_type = (first_byte & PACKET_TYPE_MASK) >> 4;
        
        // Version is next 4 bytes (network byte order)
        const version = std.mem.readInt(u32, data[1..][0..4], .big);
        
        // Connection ID lengths (RFC 9000: DCID length, then SCID length, both at start)
        const dest_conn_id_len = data[5];
        const src_conn_id_len = data[6];
        
        var offset: usize = 7;
        
        if (offset + dest_conn_id_len > data.len) {
            return error.IncompletePacket;
        }
        const dest_conn_id = data[offset..offset + dest_conn_id_len];
        offset += dest_conn_id_len;
        
        if (offset + src_conn_id_len > data.len) {
            return error.IncompletePacket;
        }
        const src_conn_id = data[offset..offset + src_conn_id_len];
        offset += src_conn_id_len;
        
        // Token length (for INITIAL packets)
        var token_len: usize = 0;
        if (packet_type == PACKET_TYPE_INITIAL) {
            if (offset + 2 > data.len) {
                return error.IncompletePacket;
            }
            token_len = std.mem.readInt(u16, data[offset..][0..2], .big);
            offset += 2;
            
            // Only check token space if token_len > 0
            if (token_len > 0) {
                if (offset + token_len > data.len) {
                    return error.IncompletePacket;
                }
                offset += token_len; // Skip token
            }
        }
        
        // Length field (2 bytes) - must have at least 2 bytes remaining
        if (offset + 2 > data.len) {
            return error.IncompletePacket;
        }
        const payload_len = std.mem.readInt(u16, data[offset..][0..2], .big);
        offset += 2;
        
        // Create payload slice
        // Handle empty payload (payload_len == 0) and non-empty payload
        const payload: []const u8 = if (payload_len == 0) 
            if (offset < data.len) data[offset..offset] else data[data.len..] // Empty slice
        else blk: {
            // Check if we have enough space for non-empty payload
            if (offset + payload_len > data.len) {
                return error.IncompletePacket;
            }
            break :blk data[offset..offset + payload_len];
        };
        
        return LongHeaderPacket{
            .packet_type = packet_type,
            .version = version,
            .dest_conn_id = dest_conn_id,
            .src_conn_id = src_conn_id,
            .payload = payload,
        };
    }
};

// Short Header Packet (RFC 9000 Section 17.3)
pub const ShortHeaderPacket = struct {
    dest_conn_id: []const u8,
    packet_number: u64,
    payload: []const u8,
    
    pub fn parse(data: []const u8, conn_id_len: usize) !ShortHeaderPacket {
        if (data.len < 1 + conn_id_len) {
            return error.IncompletePacket;
        }
        
        const dest_conn_id = data[1..1 + conn_id_len];
        var offset: usize = 1 + conn_id_len;
        
        // Packet number is variable length (1-4 bytes)
        // First byte after conn_id has packet number length in bits 0-1
        if (offset >= data.len) {
            return error.IncompletePacket;
        }
        const pn_byte = data[offset];
        const pn_len = ((pn_byte & 0x03) + 1);
        offset += 1;
        
        if (offset + pn_len > data.len) {
            return error.IncompletePacket;
        }
        
        var packet_number: u64 = 0;
        for (0..pn_len) |i| {
            packet_number |= @as(u64, data[offset + i]) << (@as(u6, @intCast(i)) * 8);
        }
        offset += pn_len;
        
        const payload = data[offset..];
        
        return ShortHeaderPacket{
            .dest_conn_id = dest_conn_id,
            .packet_number = packet_number,
            .payload = payload,
        };
    }
};

// Determine if packet is long or short header
pub fn isLongHeader(first_byte: u8) bool {
    return (first_byte & 0x80) != 0;
}

// Parse QUIC packet (auto-detect long/short header)
pub const Packet = union(enum) {
    long: LongHeaderPacket,
    short: ShortHeaderPacket,
    
    pub fn parse(data: []const u8, conn_id_len: usize) !Packet {
        if (data.len == 0) {
            return error.IncompletePacket;
        }
        
        if (isLongHeader(data[0])) {
            const long = try LongHeaderPacket.parse(data);
            return Packet{ .long = long };
        } else {
            const short = try ShortHeaderPacket.parse(data, conn_id_len);
            return Packet{ .short = short };
        }
    }
};

// QUIC Frame Types (RFC 9000 Section 19)
pub const FrameType = enum(u8) {
    padding = 0x00,
    ping = 0x01,
    ack = 0x02,
    ack_ecn = 0x03,
    reset_stream = 0x04,
    stop_sending = 0x05,
    crypto = 0x06,
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
pub const CryptoFrame = struct {
    offset: u64,
    length: u64,
    data: []const u8,
    
    pub fn parse(data: []const u8) !CryptoFrame {
        var offset: usize = 0;
        
        // Frame type (1 byte) - should be 0x06
        if (data.len < 1) {
            return error.IncompleteFrame;
        }
        if (data[0] != @intFromEnum(FrameType.crypto)) {
            return error.InvalidFrameType;
        }
        offset += 1;
        
        // Offset (variable length)
        const offset_len = try readVarInt(data[offset..]);
        offset += offset_len.bytes_read;
        const frame_offset = offset_len.value;
        
        // Length (variable length)
        const length_len = try readVarInt(data[offset..]);
        offset += length_len.bytes_read;
        const frame_length = length_len.value;
        
        if (offset + frame_length > data.len) {
            return error.IncompleteFrame;
        }
        
        return CryptoFrame{
            .offset = frame_offset,
            .length = frame_length,
            .data = data[offset..offset + frame_length],
        };
    }
};

// Variable-length integer encoding (RFC 9000 Section 16)
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
    };
}

// Packet Generation Functions

// Generate INITIAL packet with CRYPTO frame payload
// Returns the number of bytes written to out_buf
pub fn generateInitialPacket(
    dest_conn_id: []const u8,  // Client's connection ID (destination from server perspective)
    src_conn_id: []const u8,   // Server's connection ID (source from server perspective)
    payload: []const u8,        // CRYPTO frame(s) to include
    out_buf: []u8,
) !usize {
    var offset: usize = 0;
    
    // Check buffer size (rough estimate: header + payload)
    const min_size = 1 + 4 + 1 + dest_conn_id.len + 1 + src_conn_id.len + 2 + 2 + payload.len;
    if (out_buf.len < min_size) {
        return error.BufferTooSmall;
    }
    
    // First byte: Long header (0x80) + INITIAL (0x00) = 0x80
    out_buf[offset] = 0x80; // Long header bit + INITIAL type
    offset += 1;
    
    // Version (4 bytes, network byte order)
    std.mem.writeInt(u32, out_buf[offset..][0..4], QUIC_VERSION_1, .big);
    offset += 4;
    
    // Connection ID lengths (both at bytes 5 and 6, before the actual IDs)
    if (dest_conn_id.len > 255) {
        return error.InvalidConnIdLength;
    }
    if (src_conn_id.len > 255) {
        return error.InvalidConnIdLength;
    }
    if (offset + 2 > out_buf.len) {
        return error.BufferTooSmall;
    }
    out_buf[offset] = @truncate(dest_conn_id.len);
    out_buf[offset + 1] = @truncate(src_conn_id.len);
    offset += 2;
    
    // Destination Connection ID
    if (offset + dest_conn_id.len > out_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(out_buf[offset..offset + dest_conn_id.len], dest_conn_id);
    offset += dest_conn_id.len;
    
    // Source Connection ID
    if (offset + src_conn_id.len > out_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(out_buf[offset..offset + src_conn_id.len], src_conn_id);
    offset += src_conn_id.len;
    
    // Token length (2 bytes, big-endian) - 0 for server response
    if (offset + 2 > out_buf.len) {
        return error.BufferTooSmall;
    }
    std.mem.writeInt(u16, out_buf[offset..][0..2], 0, .big);
    offset += 2;
    
    // Payload length (2 bytes, big-endian)
    if (offset + 2 > out_buf.len) {
        return error.BufferTooSmall;
    }
    if (payload.len > 65535) {
        return error.PayloadTooLarge;
    }
    std.mem.writeInt(u16, out_buf[offset..][0..2], @truncate(payload.len), .big);
    offset += 2;
    
    // Payload (CRYPTO frame(s))
    if (offset + payload.len > out_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(out_buf[offset..offset + payload.len], payload);
    offset += payload.len;
    
    return offset;
}

// Generate HANDSHAKE packet with CRYPTO frame payload
// Returns the number of bytes written to out_buf
pub fn generateHandshakePacket(
    dest_conn_id: []const u8,  // Client's connection ID
    src_conn_id: []const u8,   // Server's connection ID
    payload: []const u8,       // CRYPTO frame(s) to include
    out_buf: []u8,
) !usize {
    var offset: usize = 0;
    
    // Check buffer size
    const min_size = 1 + 4 + 1 + dest_conn_id.len + 1 + src_conn_id.len + 2 + payload.len;
    if (out_buf.len < min_size) {
        return error.BufferTooSmall;
    }
    
    // First byte: Long header (0x80) + HANDSHAKE (0x20) = 0xA0
    out_buf[offset] = 0xA0; // Long header bit + HANDSHAKE type
    offset += 1;
    
    // Version (4 bytes, network byte order)
    std.mem.writeInt(u32, out_buf[offset..][0..4], QUIC_VERSION_1, .big);
    offset += 4;
    
    // Connection ID lengths (both at bytes 5 and 6, before the actual IDs)
    if (dest_conn_id.len > 255) {
        return error.InvalidConnIdLength;
    }
    if (src_conn_id.len > 255) {
        return error.InvalidConnIdLength;
    }
    if (offset + 2 > out_buf.len) {
        return error.BufferTooSmall;
    }
    out_buf[offset] = @truncate(dest_conn_id.len);
    out_buf[offset + 1] = @truncate(src_conn_id.len);
    offset += 2;
    
    // Destination Connection ID
    if (offset + dest_conn_id.len > out_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(out_buf[offset..offset + dest_conn_id.len], dest_conn_id);
    offset += dest_conn_id.len;
    
    // Source Connection ID
    if (offset + src_conn_id.len > out_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(out_buf[offset..offset + src_conn_id.len], src_conn_id);
    offset += src_conn_id.len;
    
    // No token field for HANDSHAKE packets
    
    // Payload length (2 bytes, big-endian)
    if (offset + 2 > out_buf.len) {
        return error.BufferTooSmall;
    }
    if (payload.len > 65535) {
        return error.PayloadTooLarge;
    }
    std.mem.writeInt(u16, out_buf[offset..][0..2], @truncate(payload.len), .big);
    offset += 2;
    
    // Payload (CRYPTO frame(s))
    if (offset + payload.len > out_buf.len) {
        return error.BufferTooSmall;
    }
    @memcpy(out_buf[offset..offset + payload.len], payload);
    offset += payload.len;
    
    return offset;
}

// Write variable-length integer
pub fn writeVarInt(writer: anytype, value: u64) !usize {
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

