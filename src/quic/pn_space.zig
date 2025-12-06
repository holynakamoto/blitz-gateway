// Packet Number Space (RFC 9000 Section 12.3)
// Manages packet numbers for Initial, Handshake, and Application spaces

const std = @import("std");
const types = @import("types.zig");

pub const PacketNumberSpace = struct {
    space_type: types.PacketNumberSpace,
    next_packet_number: u64, // Next packet number to send
    largest_received: u64,    // Largest packet number received
    largest_acked: u64,       // Largest packet number acknowledged

    pub fn init(space_type: types.PacketNumberSpace) PacketNumberSpace {
        return PacketNumberSpace{
            .space_type = space_type,
            .next_packet_number = 0,
            .largest_received = 0,
            .largest_acked = 0,
        };
    }

    /// Get next packet number to send
    pub fn getNext(self: *PacketNumberSpace) u64 {
        const pn = self.next_packet_number;
        self.next_packet_number += 1;
        return pn;
    }

    /// Record a received packet number
    pub fn recordReceived(self: *PacketNumberSpace, pn: u64) void {
        if (pn > self.largest_received) {
            self.largest_received = pn;
        }
    }

    /// Record an acknowledged packet number
    pub fn recordAcked(self: *PacketNumberSpace, pn: u64) void {
        if (pn > self.largest_acked) {
            self.largest_acked = pn;
        }
    }
};

