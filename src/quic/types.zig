// quic/types.zig
const std = @import("std");

/// VarInt as defined in RFC 9000 §16 — up to 2^62-1
pub const VarInt = struct {
    value: u62,

    pub fn fromU64(val: u64) error{Overflow}!VarInt {
        if (val > (1 << 62) - 1) return error.Overflow;
        return VarInt{ .value = @intCast(val) };
    }

    pub fn eql(a: VarInt, b: VarInt) bool {
        return a.value == b.value;
    }
};

/// Packet Number — up to 62 bits, but we store as u64 for convenience
pub const PacketNumber = u64;

/// Stream ID — RFC 9000 §2.1
pub const StreamId = u62;

/// Error type for QUIC transport & crypto
pub const Error = error{
    InvalidPacket,
    InvalidVarInt,
    UnsupportedVersion,
    DecryptionFailed,
    ProtocolViolation,
    InternalError,
    BufferTooSmall,
    CryptoError,
};
