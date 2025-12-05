// QUIC UDP Server with io_uring event loop
// Integrates QUIC server with io_uring for high-performance UDP packet handling

const std = @import("std");
const builtin = @import("builtin");

// Import io_uring C bindings from parent module for type compatibility
const io_uring_mod = @import("../core/io_uring.zig");
const c = io_uring_mod.c;

const server_mod = @import("server.zig");
const packet = @import("packet.zig");
const udp = @import("udp.zig");
const crypto = @import("crypto.zig");

// Buffer pool for UDP packets
const UDP_BUFFER_SIZE = 65536; // QUIC max packet size (64KB)
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

    // ═══════════════════════════════════════════════════════════════════════════
    // QUIC PACKET DECRYPTION FLOW (from working quic_handshake_server.zig)
    // Must decrypt BEFORE parsing! QUIC uses encryption-at-rest.
    // ═══════════════════════════════════════════════════════════════════════════

    if (data.len < 18) {
        std.log.debug("Packet too short: {} bytes", .{data.len});
        return;
    }

    const first_byte = data[0];

    // Check if long header (bit 7 = 1)
    if ((first_byte & 0x80) == 0) {
        std.log.debug("Short header packet (1-RTT) - not handled yet", .{});
        return;
    }

    // Check packet type (bits 4-5): 0 = Initial
    const packet_type = (first_byte & 0x30) >> 4;
    if (packet_type != 0) {
        std.log.debug("Non-Initial packet type {} - not handled yet", .{packet_type});
        return;
    }

    // Extract DCID (unprotected part of header)
    const orig_dcid_len = data[5];
    if (6 + orig_dcid_len > data.len) {
        std.log.debug("Invalid DCID length", .{});
        return;
    }
    const dcid = data[6 .. 6 + orig_dcid_len];

    // Extract SCID
    const scid_offset = 6 + orig_dcid_len;
    if (scid_offset >= data.len) return;
    const orig_scid_len = data[scid_offset];
    const scid = data[scid_offset + 1 .. scid_offset + 1 + orig_scid_len];

    std.log.info("[QUIC] Initial packet: DCID={} bytes, SCID={} bytes", .{ orig_dcid_len, orig_scid_len });

    // Derive Initial secrets from DCID
    const secrets = crypto.deriveInitialSecrets(dcid) catch |err| {
        std.log.err("[CRYPTO] Failed to derive secrets: {any}", .{err});
        return;
    };

    // Make a mutable copy for header protection removal
    var packet_copy: [65536]u8 = undefined;
    @memcpy(packet_copy[0..data.len], data);

    // Find packet number offset
    const pn_offset = crypto.findPacketNumberOffset(packet_copy[0..data.len]) catch |err| {
        std.log.err("[CRYPTO] Failed to find PN offset: {any}", .{err});
        return;
    };

    // Remove header protection
    const pn = crypto.removeHeaderProtection(packet_copy[0..data.len], &secrets.client_hp, pn_offset) catch |err| {
        std.log.err("[CRYPTO] Failed to remove header protection: {any}", .{err});
        return;
    };

    std.log.info("[CRYPTO] Packet number: {} - header protection removed", .{pn});

    // ═══════════════════════════════════════════════════════════════════════════
    // NOW RE-PARSE THE PACKET STRUCTURE (length field was also protected!)
    // ═══════════════════════════════════════════════════════════════════════════

    std.log.info("[CRYPTO] Starting packet re-parsing after header protection");
    var pos: usize = 0;

    // First byte (now unprotected)
    const header_type = packet_copy[pos];
    pos += 1;

    // Version (4 bytes)
    pos += 4;

    // DCID len + DCID
    const dcid_len = packet_copy[pos];
    pos += 1 + dcid_len;

    // SCID len + SCID
    const scid_len = packet_copy[pos];
    pos += 1 + scid_len;

    // Debug: show the next few bytes to understand the varint
    std.log.info("[CRYPTO] pos={}, next 8 bytes: {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2} {x:0>2}", .{
        pos,
        if (pos < packet_copy.len) packet_copy[pos] else 0,
        if (pos+1 < packet_copy.len) packet_copy[pos+1] else 0,
        if (pos+2 < packet_copy.len) packet_copy[pos+2] else 0,
        if (pos+3 < packet_copy.len) packet_copy[pos+3] else 0,
        if (pos+4 < packet_copy.len) packet_copy[pos+4] else 0,
        if (pos+5 < packet_copy.len) packet_copy[pos+5] else 0,
        if (pos+6 < packet_copy.len) packet_copy[pos+6] else 0,
        if (pos+7 < packet_copy.len) packet_copy[pos+7] else 0,
    });

    var payload_len: usize = 0;
    const bytes_read = std.leb.readILEB128(usize, packet_copy[pos..], &payload_len) catch |err| {
        std.log.err("[CRYPTO] Failed to read payload length varint: {any}", .{err});
        return;
    };
    pos += bytes_read;

    std.log.info("[CRYPTO] Read payload_len={} in {} bytes", .{payload_len, bytes_read});

    // Packet number length (bottom 2 bits of first byte)
    const pn_len = 1 + @as(usize, header_type & 0x03);

    // Read packet number
    const packet_number = switch (pn_len) {
        1 => packet_copy[pos],
        2 => std.mem.readInt(u16, packet_copy[pos..pos+2], .little),
        3 => std.mem.readInt(u32, packet_copy[pos..pos+3], .little) & 0x00FFFFFF,
        4 => std.mem.readInt(u32, packet_copy[pos..pos+4], .little),
        else => unreachable,
    };
    pos += pn_len;

    // Encrypted payload starts here
    if (pos + payload_len > data.len) {
        std.log.err("[CRYPTO] Invalid payload bounds: pos={} + payload_len={} > data.len={}", .{pos, payload_len, data.len});
        return;
    }

    const encrypted_payload = packet_copy[pos .. pos + payload_len];
    const header_aad = packet_copy[0..pos];

    // Decrypt payload
    var plaintext: [65536]u8 = undefined;
    const decrypted_len = crypto.decryptPayload(
        encrypted_payload,
        &secrets.client_key,
        &secrets.client_iv,
        packet_number,
        header_aad,
        &plaintext,
    ) catch |err| {
        std.log.err("[CRYPTO] Decryption failed: {any}", .{err});
        return;
    };

    std.log.info("[CRYPTO] Decrypted {} bytes", .{decrypted_len});

    // Get or create connection using SCID as remote connection ID
    const conn = try quic_server.getOrCreateConnection(scid, client_ip);

    // Process decrypted payload (contains CRYPTO frames with ClientHello)
    try conn.processDecryptedPayload(plaintext[0..decrypted_len], quic_server.ssl_ctx);

    // Check if we need to send a response (handshake in progress)
    if (conn.state == .handshaking) {
        // Generate response packet
        var response_buf: [65536]u8 = undefined;
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
