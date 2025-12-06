// quic/packet.zig
// Initial packet parsing — only what we need for handshake (expand later)

const std = @import("std");
const constants = @import("constants.zig");
const varint = @import("varint.zig");
const types = @import("types.zig");

pub const LongHeader = struct {
    packet_type: u8,
    version: u32,
    dcid: []const u8,
    scid: []const u8,
    token: []const u8,
    packet_number_len: usize, // 1–4
    packet_number: types.PacketNumber,
    payload_len: usize,
    payload_offset: usize,
};

/// Parse only the unprotected parts of a long-header packet (before HP removal)
pub fn parseUnprotectedLong(data: []const u8) !LongHeader {
    if (data.len < 7) return error.InvalidPacket;
    if ((data[0] & 0x80) == 0) return error.InvalidPacket; // must be long header

    const packet_type = (data[0] >> 4) & 0x3;
    const version = std.mem.readInt(u32, data[1..5], .big);

    var pos: usize = 5;

    const dcid_len = data[pos];
    pos += 1;
    if (dcid_len > 20 or pos + dcid_len > data.len) return error.InvalidPacket;
    const dcid = data[pos .. pos + dcid_len];
    pos += dcid_len;

    const scid_len = data[pos];
    pos += 1;
    if (scid_len > 20 or pos + scid_len > data.len) return error.InvalidPacket;
    const scid = data[pos .. pos + scid_len];
    pos += scid_len;

    // Token length (varint)
    const token_res = try varint.decode(data[pos..]);
    pos += token_res.bytes_read;
    const token_len = token_res.value.value;
    if (pos + token_len > data.len) return error.InvalidPacket;
    const token = data[pos .. pos + token_len];
    pos += token_len;

    return LongHeader{
        .packet_type = packet_type,
        .version = version,
        .dcid = dcid,
        .scid = scid,
        .token = token,
        .packet_number_len = 0, // filled later
        .packet_number = 0,
        .payload_len = 0,
        .payload_offset = pos,
    };
}
