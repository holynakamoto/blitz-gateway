// QUIC Connection management (RFC 9000)
// Handles connection state, streams, and flow control

const std = @import("std");
const packet = @import("packet.zig");

// Connection ID length (RFC 9000)
pub const CONN_ID_LEN: usize = 8; // Default 8 bytes

// Connection State (RFC 9000 Section 10)
pub const ConnectionState = enum {
    idle,
    handshake,
    active,
    draining,
    closed,
};

// QUIC Connection
pub const QuicConnection = struct {
    state: ConnectionState,
    version: u32,
    local_conn_id: []u8, // Our connection ID
    remote_conn_id: []u8, // Peer's connection ID
    packet_number: u64 = 0,
    allocator: std.mem.Allocator,
    
    // Flow control
    max_data: u64 = 10_000_000, // Initial max data (10 MB)
    max_stream_data_bidi_local: u64 = 1_000_000,
    max_stream_data_bidi_remote: u64 = 1_000_000,
    max_stream_data_uni: u64 = 1_000_000,
    max_streams_bidi: u64 = 100,
    max_streams_uni: u64 = 100,
    
    // Stream management
    streams: std.HashMap(u64, *Stream, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage),
    next_stream_id_bidi: u64 = 0, // Server-initiated bidirectional streams (even numbers)
    next_stream_id_uni: u64 = 2, // Server-initiated unidirectional streams (even numbers, start at 2)
    
    pub fn init(allocator: std.mem.Allocator, local_conn_id: []u8, remote_conn_id: []u8) QuicConnection {
        return QuicConnection{
            .state = .idle,
            .version = packet.QUIC_VERSION_1,
            .local_conn_id = local_conn_id,
            .remote_conn_id = remote_conn_id,
            .allocator = allocator,
            .streams = std.HashMap(u64, *Stream, std.hash_map.AutoContext(u64), std.hash_map.default_max_load_percentage).init(allocator),
        };
    }
    
    pub fn deinit(self: *QuicConnection) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
    }
    
    pub fn getOrCreateStream(self: *QuicConnection, stream_id: u64) !*Stream {
        if (self.streams.get(stream_id)) |existing| {
            return existing;
        }
        
        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id);
        try self.streams.put(stream_id, stream);
        return stream;
    }
    
    pub fn nextPacketNumber(self: *QuicConnection) u64 {
        const pn = self.packet_number;
        self.packet_number += 1;
        return pn;
    }
};

// Stream State (RFC 9000 Section 3)
pub const StreamState = enum {
    idle,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

// QUIC Stream
pub const Stream = struct {
    id: u64,
    state: StreamState,
    offset: u64 = 0,
    max_stream_data: u64 = 1_000_000, // Initial max stream data
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator, stream_id: u64) Stream {
        return Stream{
            .id = stream_id,
            .state = .idle,
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Stream) void {
        _ = self;
    }
    
    pub fn isBidirectional(self: *const Stream) bool {
        return (self.id & 0x01) == 0;
    }
    
    pub fn isUnidirectional(self: *const Stream) bool {
        return (self.id & 0x01) == 1;
    }
    
    pub fn isClientInitiated(self: *const Stream) bool {
        return (self.id & 0x02) == 0;
    }
    
    pub fn isServerInitiated(self: *const Stream) bool {
        return (self.id & 0x02) == 1;
    }
};

