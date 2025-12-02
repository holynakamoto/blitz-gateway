// QUIC UDP Server with io_uring event loop
// Integrates QUIC server with io_uring for high-performance UDP packet handling

const std = @import("std");
const builtin = @import("builtin");

// Import io_uring C bindings from parent module for type compatibility
const io_uring_mod = @import("../io_uring.zig");
const c = io_uring_mod.c;

const server_mod = @import("server.zig");
const packet = @import("packet.zig");
const udp = @import("udp.zig");
// const tls = @import("../tls/tls.zig"); // Temporarily disabled for picotls migration

// Buffer pool for UDP packets
const UDP_BUFFER_SIZE = 1500; // Standard MTU
const UDP_BUFFER_POOL_SIZE = 1024;

const UdpBuffer = struct {
    data: [UDP_BUFFER_SIZE]u8,
    in_use: bool = false,
    client_addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in),
    client_addr_len: c.socklen_t = @sizeOf(c.struct_sockaddr_in),
};

pub const UdpBufferPool = struct {
    buffers: []UdpBuffer,
    free_list: std.ArrayList(usize),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !UdpBufferPool {
        const buffers = try allocator.alloc(UdpBuffer, UDP_BUFFER_POOL_SIZE);
        errdefer allocator.free(buffers);

        var free_list = std.ArrayList(usize).initCapacity(allocator, UDP_BUFFER_POOL_SIZE) catch @panic("Failed to init buffer pool free list");
        errdefer free_list.deinit();

        // Initialize all buffers as free
        for (0..UDP_BUFFER_POOL_SIZE) |i| {
            free_list.appendAssumeCapacity(i);
        }

        return UdpBufferPool{
            .buffers = buffers,
            .free_list = free_list,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *UdpBufferPool) void {
        self.allocator.free(self.buffers);
        self.free_list.deinit();
    }

    pub fn acquire(self: *UdpBufferPool) ?*UdpBuffer {
        const idx = self.free_list.pop() orelse return null;
        self.buffers[idx].in_use = true;
        return &self.buffers[idx];
    }

    pub fn release(self: *UdpBufferPool, buf: *UdpBuffer) void {
        const idx = @intFromPtr(buf) - @intFromPtr(self.buffers.ptr);
        const buffer_idx = idx / @sizeOf(UdpBuffer);
        if (buffer_idx < self.buffers.len) {
            self.buffers[buffer_idx].in_use = false;
            self.free_list.append(self.allocator, buffer_idx) catch {};
        }
    }
};

// User data encoding for io_uring
const UserData = struct {
    fd: c_int,
    op: Operation,
    buffer_idx: usize = 0,

    pub const Operation = enum {
        recvfrom,
        sendto,
    };
};

fn encodeUserData(fd: c_int, op: UserData.Operation, buffer_idx: usize) u64 {
    const fd_part: u64 = @intCast(fd & 0xFFFF);
    const op_part: u64 = @as(u64, @intCast(@intFromEnum(op))) << 16;
    const buf_part: u64 = @as(u64, @intCast(buffer_idx)) << 24;
    return fd_part | op_part | buf_part;
}

fn decodeUserData(user_data: u64) UserData {
    return UserData{
        .fd = @intCast(user_data & 0xFFFF),
        .op = @enumFromInt((user_data >> 16) & 0xFF),
        .buffer_idx = @intCast((user_data >> 24) & 0xFFFFFFFF),
    };
}

// Helper to get SQE (from io_uring.zig pattern)
fn getSqe(ring: *c.struct_io_uring) ?*c.struct_io_uring_sqe {
    return c.io_uring_get_sqe(ring);
}

fn setSqeData(sqe: *c.struct_io_uring_sqe, user_data: u64) void {
    c.io_uring_sqe_set_data(sqe, @as(?*anyopaque, @ptrFromInt(user_data)));
}

// Run QUIC UDP server with io_uring event loop
pub fn runQuicServer(ring: *c.struct_io_uring, port: u16) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize QUIC server
    var quic_server = try server_mod.QuicServer.init(allocator, port);
    defer quic_server.deinit();

    // TLS context initialization disabled for PicoTLS migration
    // TODO: Re-enable TLS context when PicoTLS integration is complete
    quic_server.ssl_ctx = null;

    // Initialize buffer pool
    var buffer_pool = try UdpBufferPool.init(allocator);
    defer buffer_pool.deinit();

    std.log.info("QUIC server listening on UDP port {d}", .{port});

    // Submit initial recvfrom operations (multiple for better throughput)
    const initial_recvs = 32;
    for (0..initial_recvs) |_| {
        const buf = buffer_pool.acquire() orelse break;

        const sqe_opt = getSqe(ring);
        if (sqe_opt == null) {
            buffer_pool.release(buf);
            break;
        }
        const sqe = sqe_opt.?;

        const buffer_idx = @intFromPtr(buf) - @intFromPtr(buffer_pool.buffers.ptr);
        const idx = buffer_idx / @sizeOf(UdpBuffer);

        udp.prepRecvFrom(sqe, quic_server.udp_fd, &buf.data, &buf.client_addr, &buf.client_addr_len);
        setSqeData(sqe, encodeUserData(quic_server.udp_fd, .recvfrom, idx));
    }
    _ = c.io_uring_submit(ring);

    // Main event loop
    while (true) {
        var cqe: ?*c.struct_io_uring_cqe = null;
        _ = c.io_uring_wait_cqe(ring, &cqe);

        if (cqe == null) {
            continue;
        }

        const res = cqe.?.res;
        const user_data = cqe.?.user_data;
        const decoded = decodeUserData(user_data);

        c.io_uring_cqe_seen(ring, cqe);

        if (res < 0) {
            // Error handling
            if (decoded.op == .recvfrom) {
                // Release buffer and resubmit recvfrom
                if (decoded.buffer_idx < buffer_pool.buffers.len) {
                    buffer_pool.release(&buffer_pool.buffers[decoded.buffer_idx]);
                }

                // Resubmit recvfrom
                const buf = buffer_pool.acquire() orelse continue;

                const sqe_opt = getSqe(ring);
                if (sqe_opt == null) {
                    buffer_pool.release(buf);
                    continue;
                }
                const sqe = sqe_opt.?;

                const buffer_idx = @intFromPtr(buf) - @intFromPtr(buffer_pool.buffers.ptr);
                const idx = buffer_idx / @sizeOf(UdpBuffer);

                udp.prepRecvFrom(sqe, quic_server.udp_fd, &buf.data, &buf.client_addr, &buf.client_addr_len);
                setSqeData(sqe, encodeUserData(quic_server.udp_fd, .recvfrom, idx));
                _ = c.io_uring_submit(ring);
            } else if (decoded.op == .sendto) {
                // Release buffer for failed sendto operation (do not resubmit)
                if (decoded.buffer_idx < buffer_pool.buffers.len) {
                    buffer_pool.release(&buffer_pool.buffers[decoded.buffer_idx]);
                }
            }
            continue;
        }

        switch (decoded.op) {
            .recvfrom => {
                const buf = &buffer_pool.buffers[decoded.buffer_idx];
                const packet_data = buf.data[0..@intCast(res)];

                // Process QUIC packet (client_addr is already filled by recvfrom)
                handleQuicPacket(
                    &quic_server,
                    packet_data,
                    &buf.client_addr,
                    &buf.client_addr_len,
                    ring,
                    &buffer_pool,
                ) catch |err| {
                    std.log.debug("Error handling QUIC packet: {any}", .{err});
                };

                // Resubmit recvfrom for next packet
                const next_buf = buffer_pool.acquire() orelse {
                    // Pool exhausted - reuse this buffer
                    // Use the buffer's own client_addr fields (heap-allocated, not stack)
                    const sqe_opt = getSqe(ring);
                    if (sqe_opt == null) {
                        buffer_pool.release(buf);
                        continue;
                    }
                    const sqe = sqe_opt.?;

                    udp.prepRecvFrom(sqe, quic_server.udp_fd, &buf.data, &buf.client_addr, &buf.client_addr_len);
                    setSqeData(sqe, encodeUserData(quic_server.udp_fd, .recvfrom, decoded.buffer_idx));
                    _ = c.io_uring_submit(ring);
                    continue;
                };

                const sqe_opt = getSqe(ring);
                if (sqe_opt == null) {
                    buffer_pool.release(next_buf);
                    buffer_pool.release(buf);
                    continue;
                }
                const sqe = sqe_opt.?;

                const buffer_idx = @intFromPtr(next_buf) - @intFromPtr(buffer_pool.buffers.ptr);
                const idx = buffer_idx / @sizeOf(UdpBuffer);

                // Use the buffer's own client_addr fields (heap-allocated, not stack)
                udp.prepRecvFrom(sqe, quic_server.udp_fd, &next_buf.data, &next_buf.client_addr, &next_buf.client_addr_len);
                setSqeData(sqe, encodeUserData(quic_server.udp_fd, .recvfrom, idx));
                _ = c.io_uring_submit(ring);

                // Release the buffer we just used
                buffer_pool.release(buf);
            },
            .sendto => {
                // Send completed - release buffer
                if (decoded.buffer_idx < buffer_pool.buffers.len) {
                    buffer_pool.release(&buffer_pool.buffers[decoded.buffer_idx]);
                }
            },
        }
    }
}

fn handleQuicPacket(
    quic_server: *server_mod.QuicServer,
    data: []const u8,
    client_addr: *c.struct_sockaddr_in,
    client_addr_len: *c.socklen_t,
    ring: *c.struct_io_uring,
    buffer_pool: *UdpBufferPool,
) !void {
    // Convert C sockaddr to Zig address
    const client_ip = std.net.Ip4Address.init(
        @as([4]u8, @bitCast(client_addr.sin_addr.s_addr)),
        @intCast(c.ntohs(client_addr.sin_port)),
    );

    // Parse packet to get connection ID for lookup
    const parsed = packet.Packet.parse(data, 8) catch |err| {
        std.log.debug("Failed to parse QUIC packet: {any}", .{err});
        return;
    };

    const remote_conn_id = switch (parsed) {
        .long => |p| p.src_conn_id,
        .short => |p| p.dest_conn_id,
    };

    // Get or create connection
    const conn = try quic_server.getOrCreateConnection(remote_conn_id, client_ip);

    // Process packet
    try conn.processPacket(data, quic_server.ssl_ctx);

    // Check if we need to send a response (handshake in progress)
    if (conn.state == .handshaking) {
        // Generate response packet
        var response_buf: [2048]u8 = undefined;
        const response_len = try conn.generateResponsePacket(.initial, &response_buf);

        // Get buffer for sending
        const send_buf = buffer_pool.acquire() orelse {
            std.log.warn("Buffer pool exhausted, dropping response", .{});
            return;
        };

        // Copy response to buffer
        if (response_len <= send_buf.data.len) {
            @memcpy(send_buf.data[0..response_len], response_buf[0..response_len]);

            // Submit sendto
            const sqe_opt = getSqe(ring);
            if (sqe_opt) |sqe| {
                const buffer_idx = @intFromPtr(send_buf) - @intFromPtr(buffer_pool.buffers.ptr);
                const idx = buffer_idx / @sizeOf(UdpBuffer);

                udp.prepSendTo(sqe, quic_server.udp_fd, send_buf.data[0..response_len], client_addr, client_addr_len.*);
                setSqeData(sqe, encodeUserData(quic_server.udp_fd, .sendto, idx));
                _ = c.io_uring_submit(ring);
            } else {
                buffer_pool.release(send_buf);
            }
        } else {
            buffer_pool.release(send_buf);
        }
    }
}
