const std = @import("std");
const builtin = @import("builtin");

const io_uring = @import("io_uring.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    _ = gpa.allocator(); // Reserved for future use

    std.log.info("Blitz Edge Gateway v0.1.0", .{});
    std.log.info("Target: 10M+ RPS, <50µs p99 latency", .{});

    // Initialize io_uring on Linux, fallback to epoll/kqueue on other platforms
    if (builtin.os.tag == .linux) {
        try io_uring.init();
        defer io_uring.deinit();
        
        std.log.info("io_uring initialized", .{});
        std.log.info("Starting echo server on port 8080...", .{});
        
        try io_uring.runEchoServer(8080);
    } else {
        std.log.err("io_uring is only supported on Linux. Current OS: {}", .{builtin.os.tag});
        return error.UnsupportedPlatform;
    }
}

