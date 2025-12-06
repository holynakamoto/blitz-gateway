// QUIC Client Implementation
// High-level client interface

const std = @import("std");
const connection = @import("connection.zig");
const types = @import("types.zig");

pub const Client = struct {
    allocator: std.mem.Allocator,
    conn: ?*connection.Connection,

    pub fn init(allocator: std.mem.Allocator) Client {
        return Client{
            .allocator = allocator,
            .conn = null,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.conn) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
    }
};

