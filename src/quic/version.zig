// Version Negotiation (RFC 9000 Section 6)

const std = @import("std");
const constants = @import("constants.zig");

/// Check if a version is supported
pub fn isSupportedVersion(version: u32) bool {
    return version == constants.VERSION_1;
}

/// Generate a Version Negotiation packet (RFC 9000 Section 6)
/// This is sent when the server doesn't support the client's version
pub fn generateVersionNegotiation(
    dest_conn_id: []const u8,
    src_conn_id: []const u8,
    buffer: []u8,
) !usize {
    // Version Negotiation packet structure:
    // - First byte: 0x80 (long header, but version = 0)
    // - Version: 0x00000000
    // - DCID length + DCID
    // - SCID length + SCID
    // - Supported versions list

    if (buffer.len < 1 + 4 + 1 + dest_conn_id.len + 1 + src_conn_id.len + 4) {
        return error.BufferTooSmall;
    }

    var pos: usize = 0;

    // First byte: long header bit set, version negotiation
    buffer[pos] = 0x80;
    pos += 1;

    // Version: 0x00000000
    std.mem.writeInt(u32, buffer[pos..pos+4], constants.VERSION_NEGOTIATION, .big);
    pos += 4;

    // DCID length + DCID
    buffer[pos] = @intCast(dest_conn_id.len);
    pos += 1;
    @memcpy(buffer[pos..pos+dest_conn_id.len], dest_conn_id);
    pos += dest_conn_id.len;

    // SCID length + SCID
    buffer[pos] = @intCast(src_conn_id.len);
    pos += 1;
    @memcpy(buffer[pos..pos+src_conn_id.len], src_conn_id);
    pos += src_conn_id.len;

    // Supported versions: just QUIC v1 for now
    std.mem.writeInt(u32, buffer[pos..pos+4], constants.VERSION_1, .big);
    pos += 4;

    return pos;
}

