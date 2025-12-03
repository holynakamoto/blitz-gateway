// UDP socket handling with io_uring for QUIC
// Phase 1: Basic UDP socket creation and io_uring integration

const std = @import("std");
const builtin = @import("builtin");

// Import io_uring C bindings from parent module for type compatibility
const io_uring_mod = @import("../core/io_uring.zig");
const c = io_uring_mod.c;

// Create UDP socket for QUIC
pub fn createUdpSocket(port: u16) !c_int {
    const sockfd = c.socket(c.AF_INET, c.SOCK_DGRAM | c.SOCK_NONBLOCK, 0);
    if (sockfd < 0) {
        return error.SocketCreationFailed;
    }

    // Enable SO_REUSEADDR
    const opt: c_int = 1;
    _ = c.setsockopt(sockfd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));

    // Bind to port
    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_addr.s_addr = c.INADDR_ANY;
    addr.sin_port = c.htons(port);

    // Use the C wrapper for bind to avoid glibc type issues
    if (io_uring_mod.blitz_bind(sockfd, &addr) < 0) {
        std.log.err("bind() failed on UDP port {d}", .{port});
        _ = c.close(sockfd);
        return error.BindFailed;
    }

    return sockfd;
}

// UDP connection info (for tracking client addresses)
pub const UdpConnection = struct {
    fd: c_int,
    client_addr: c.struct_sockaddr_in,
    client_addr_len: c.socklen_t,
    read_buffer: ?[]u8 = null,

    pub fn init(fd: c_int, client_addr: c.struct_sockaddr_in, client_addr_len: c.socklen_t) UdpConnection {
        return UdpConnection{
            .fd = fd,
            .client_addr = client_addr,
            .client_addr_len = client_addr_len,
        };
    }
};

// Helper to prepare recvfrom for io_uring
pub fn prepRecvFrom(
    sqe: *c.struct_io_uring_sqe,
    sockfd: c_int,
    buf: []u8,
    addr: *c.struct_sockaddr_in,
    addr_len: *c.socklen_t,
) void {
    // Prepare recvmsg to capture sender address
    // Ensure addr_len is initialized to the size of sockaddr_in
    addr_len.* = @sizeOf(c.struct_sockaddr_in);

    var msg: c.struct_msghdr = std.mem.zeroes(c.struct_msghdr);
    var iov: c.struct_iovec = .{
        .iov_base = buf.ptr,
        .iov_len = @intCast(buf.len),
    };
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_name = @ptrCast(addr);
    msg.msg_namelen = addr_len.*;

    c.io_uring_prep_recvmsg(sqe, sockfd, &msg, 0);
}

// Helper to prepare sendto for io_uring
pub fn prepSendTo(
    sqe: *c.struct_io_uring_sqe,
    sockfd: c_int,
    buf: []const u8,
    addr: *const c.struct_sockaddr_in,
    addr_len: c.socklen_t,
) void {
    c.io_uring_prep_sendto(
        sqe,
        sockfd,
        buf.ptr,
        @intCast(buf.len),
        0,
        @ptrCast(addr),
        addr_len,
    );
}
