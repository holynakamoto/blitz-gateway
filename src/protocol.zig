// Shared protocol enum for HTTP/1.1 and HTTP/2
// Used by both Connection and TLS connection types

const std = @import("std");

/// Protocol version negotiated for a connection
pub const Protocol = enum(u8) {
    http1_1 = 0,
    http2 = 1,

    pub fn format(
        self: Protocol,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        const name = switch (self) {
            .http1_1 => "HTTP/1.1",
            .http2 => "HTTP/2",
        };
        try writer.writeAll(name);
    }
};
