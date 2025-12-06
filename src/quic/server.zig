// QUIC Server Implementation
// High-level server interface with connection management

const std = @import("std");
const connection = @import("connection.zig");
const types = @import("types.zig");
const connection_id = @import("connection_id.zig");
const net = std.net;

pub const Server = struct {
    allocator: std.mem.Allocator,
    connections: std.HashMap([]const u8, *connection.Connection, ConnectionIdContext, 80),
    local_conn_id: types.ConnectionId, // Server's connection ID

    const ConnectionIdContext = struct {
        pub fn hash(self: @This(), key: []const u8) u64 {
            _ = self;
            return std.hash.Fnv1a.hash(key);
        }
        pub fn eql(self: @This(), a: []const u8, b: []const u8) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn init(allocator: std.mem.Allocator) !Server {
        // Generate server's connection ID
        const local_conn_id = connection_id.generateDefaultConnectionId();

        return Server{
            .allocator = allocator,
            .connections = std.HashMap([]const u8, *connection.Connection, ConnectionIdContext, 80).init(allocator),
            .local_conn_id = local_conn_id,
        };
    }

    pub fn deinit(self: *Server) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
            // Free the connection ID key
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.deinit();
    }

    /// Get or create a connection for a connection ID
    pub fn getOrCreateConnection(
        self: *Server,
        dcid: []const u8,
        peer_address: net.Address,
    ) !*connection.Connection {
        // Look up by DCID (client's connection ID)
        if (self.connections.get(dcid)) |conn| {
            return conn;
        }

        // New connection - create it
        const remote_conn_id = types.ConnectionId.init(dcid);
        const conn = try self.allocator.create(connection.Connection);
        errdefer self.allocator.destroy(conn);

        conn.* = try connection.Connection.initServer(
            self.allocator,
            self.local_conn_id,
            remote_conn_id,
            peer_address,
        );

        // Store connection ID copy for hash map key
        const dcid_copy = try self.allocator.dupe(u8, dcid);
        errdefer self.allocator.free(dcid_copy);

        try self.connections.put(dcid_copy, conn);

        return conn;
    }

    /// Remove a connection
    pub fn removeConnection(self: *Server, dcid: []const u8) void {
        if (self.connections.fetchRemove(dcid)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
            self.allocator.free(entry.key);
        }
    }
};
