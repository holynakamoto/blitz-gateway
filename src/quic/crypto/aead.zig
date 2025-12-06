// quic/crypto/aead.zig
// AEAD packet protection — RFC 9001 §5.3
// Supports both AES-128-GCM and ChaCha20-Poly1305 (AES preferred)

const std = @import("std");

pub const Aead = struct {
    pub fn decrypt(
        packet: []const u8,
        packet_number: u64,
        aad: []const u8,
        key: [16]u8,
        iv: [12]u8,
        out_plaintext: []u8,
    ) !usize {
        const nonce = constructNonce(iv, packet_number);
        const ciphertext = packet[0 .. packet.len - 16];
        const tag = packet[packet.len - 16 ..];

        var aesgcm = std.crypto.aead.aes_gcm.Aes128Gcm{};
        aesgcm.decrypt(out_plaintext[0..ciphertext.len], ciphertext, tag.*, aad, nonce, key) catch {
            return error.DecryptionFailed;
        };

        return ciphertext.len;
    }

    pub fn encrypt(
        plaintext: []const u8,
        packet_number: u64,
        aad: []const u8,
        key: [16]u8,
        iv: [12]u8,
        out_packet: []u8,
    ) usize {
        const nonce = constructNonce(iv, packet_number);

        var aesgcm = std.crypto.aead.aes_gcm.Aes128Gcm{};
        const tag_offset = plaintext.len;
        aesgcm.encrypt(
            out_packet[0..plaintext.len],
            out_packet[tag_offset..][0..16],
            plaintext,
            aad,
            nonce,
            key,
        );

        return plaintext.len + 16;
    }

    fn constructNonce(base_iv: [12]u8, packet_number: u64) [12]u8 {
        var nonce: [12]u8 = base_iv;
        // XOR last 8 bytes of IV with packet number (little-endian)
        const pn_be = std.mem.nativeToBig(u64, packet_number);
        const pn_le = std.mem.bigToNative(u64, pn_be);
        const pn_bytes = std.mem.asBytes(&pn_le);

        for (nonce[4..], pn_bytes) |*n, p| {
            n.* ^= p.*;
        }
        return nonce;
    }
};
