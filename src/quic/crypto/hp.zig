// quic/crypto/hp.zig
// Header Protection — RFC 9001 §5.4
// Works with both AES-128-GCM and ChaCha20-Poly1305

const std = @import("std");

pub const HeaderProtection = struct {
    /// Remove header protection from packet in-place
    /// `sample` must be 16 bytes starting at pn_offset + 4
    pub fn remove(packet: []u8, pn_offset: usize, hp_key: [16]u8) void {
        const sample = packet[pn_offset + 4 ..][0..16];
        const mask = computeMask(hp_key, sample);

        // Unmask first byte
        packet[0] ^= mask[0] & if ((packet[0] & 0x80) != 0) @as(u8, 0x1f) else 0x0f;

        // Unmask packet number
        const pn_len = (packet[0] & 0x03) + 1;
        for (packet[pn_offset..][0..pn_len], 0..) |*b, i| {
            b.* ^= mask[1 + i];
        }
    }

    /// Apply header protection (for sending)
    pub fn apply(packet: []u8, pn_offset: usize, hp_key: [16]u8) void {
        const sample = packet[pn_offset + 4 ..][0..16];
        const mask = computeMask(hp_key, sample);

        // Mask first byte
        packet[0] ^= mask[0] & if ((packet[0] & 0x80) != 0) @as(u8, 0x1f) else 0x0f;

        // Mask packet number
        const pn_len = (packet[0] & 0x03) + 1;
        for (packet[pn_offset..][0..pn_len], 0..) |*b, i| {
            b.* ^= mask[1 + i];
        }
    }

    fn computeMask(hp_key: [16]u8, sample: []const u8) [16]u8 {
        // AES-128 block cipher in ECB mode (yes, really — RFC says so)
        var block: [16]u8 = undefined;
        var out: [16]u8 = undefined;
        @memcpy(&block, sample);

        std.crypto.core.aes.Aes128.encrypt(&out, &block, hp_key);

        return out;
    }
};
