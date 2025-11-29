const std = @import("std");
const builtin = @import("builtin");
const allocator = @import("allocator.zig");
const http = @import("http/parser.zig");

// Use liburing for io_uring support
// Define AT_FDCWD if not already defined (needed for liburing.h on some systems)
const AT_FDCWD: c_int = -100;
const c = @cImport({
    @cDefine("AT_FDCWD", "-100");
    @cInclude("liburing.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
});

// C wrapper functions to avoid Zig 0.12.0 union type issues and inline function linking
extern fn blitz_bind(sockfd: c_int, addr: [*c]const c.struct_sockaddr_in) c_int;
extern fn blitz_io_uring_cqe_seen(ring: *c.struct_io_uring, cqe: ?*c.struct_io_uring_cqe) void;
extern fn blitz_io_uring_wait_cqe(ring: *c.struct_io_uring, cqe_ptr: *?*c.struct_io_uring_cqe) c_int;
extern fn blitz_io_uring_get_sqe(ring: *c.struct_io_uring) ?*c.struct_io_uring_sqe;

const SQ_RING_SIZE: u32 = 4096;
const BUFFER_SIZE: usize = 4096;
const BUFFER_POOL_SIZE: usize = 200000; // Pre-allocated buffers
// Note: MAX_CONNECTIONS removed - using HashMap for dynamic connection storage

// TLS constants
const TLS_RECORD_TYPE_HANDSHAKE: u8 = 0x16; // TLS handshake record type

// Pre-allocated HTTP response (no allocation needed) - kept for fallback
const HTTP_RESPONSE = http.CommonResponses.OK;

// Import TLS and HTTP/2 modules
const tls = @import("tls/tls.zig");
const http2 = @import("http2/connection.zig");

// Connection state
const Connection = struct {
    fd: c_int,
    read_buffer: ?[]u8 = null,
    write_buffer: ?[]u8 = null,
    in_use: bool = false,
    // TLS support
    tls_conn: ?tls.TlsConnection = null,
    is_tls: bool = false,
    // HTTP/2 support
    http2_conn: ?*http2.Http2Connection = null,
    protocol: tls.Protocol = .http1_1,
    // Connection tracking for limits/timeouts
    created_at: i64 = 0,
    last_active: i64 = 0,
    request_count: u32 = 0,
    
    // Connection limits
    const MAX_REQUESTS_PER_CONN: u32 = 1000;
    const IDLE_TIMEOUT_NS: i64 = 30 * std.time.ns_per_s; // 30 seconds
    const MAX_CONNECTION_AGE_NS: i64 = 300 * std.time.ns_per_s; // 5 minutes
};

// Helper function for explicit connection cleanup
fn closeConnection(
    fd: c_int,
    connections: *std.AutoHashMap(c_int, Connection),
    buffer_pool: *allocator.BufferPool,
    backing_allocator: std.mem.Allocator,
    reason: []const u8,
) void {
    if (connections.getPtr(fd)) |conn| {
        // Release buffers
        if (conn.read_buffer) |buf| {
            buffer_pool.releaseRead(buf);
            conn.read_buffer = null;
        }
        if (conn.write_buffer) |buf| {
            buffer_pool.releaseWrite(buf);
            conn.write_buffer = null;
        }
        
        // Clean up TLS connection if present
        if (conn.tls_conn) |*tls_conn| {
            tls_conn.deinit();
            conn.tls_conn = null;
        }
        
        // Clean up HTTP/2 connection if present
        if (conn.http2_conn) |http2_conn| {
            backing_allocator.destroy(http2_conn);
            conn.http2_conn = null;
        }
        
        // Explicitly reset all fields
        conn.fd = -1;
        conn.in_use = false;
        conn.is_tls = false;
        conn.protocol = .http1_1;
        conn.created_at = 0;
        conn.last_active = 0;
        conn.request_count = 0;
        
        // Remove from HashMap
        _ = connections.remove(fd);
    }
    
    // Close socket
    _ = c.close(fd);
    std.log.debug("Closed connection {}: {s}", .{ fd, reason });
}

// Connection state stored in user_data
// We encode: fd in lower 32 bits, operation type in upper bits
const OpType = enum(u32) {
    accept = 0,
    read = 1,
    write = 2,
    // tls_handshake = 3, // TLS handshake in progress (disabled for now)
};

fn encodeUserData(fd: c_int, op: OpType) u64 {
    const op_val: u64 = @intCast(@intFromEnum(op));
    const fd_val: u64 = @intCast(@as(u32, @bitCast(@as(c_int, fd))));
    return (op_val << 32) | fd_val;
}

fn decodeUserData(user_data: u64) struct { fd: c_int, op: OpType } {
    const fd = @as(c_int, @bitCast(@as(u32, @truncate(user_data))));
    const op = @as(OpType, @enumFromInt(@as(u32, @truncate(user_data >> 32))));
    return .{ .fd = fd, .op = op };
}

// Zig 0.12.0 compatibility: io_uring_sqe_set_data expects ?*anyopaque
fn setSqeData(sqe: *c.struct_io_uring_sqe, user_data: u64) void {
    c.io_uring_sqe_set_data(sqe, @as(?*anyopaque, @ptrFromInt(user_data)));
}

var ring: c.struct_io_uring = undefined;

pub fn init() !void {
    if (builtin.os.tag != .linux) {
        return error.UnsupportedPlatform;
    }

    const ret = c.io_uring_queue_init(SQ_RING_SIZE, &ring, 0);
    if (ret < 0) {
        std.log.err("io_uring_queue_init failed: {}", .{ret});
        return error.IoUringInitFailed;
    }

    std.log.info("io_uring initialized with {} SQ entries", .{SQ_RING_SIZE});
}

pub fn deinit() void {
    if (builtin.os.tag == .linux) {
        c.io_uring_queue_exit(&ring);
    }
}

fn createServerSocket(port: u16) !c_int {
    const sockfd = c.socket(c.AF_INET, c.SOCK_STREAM | c.SOCK_NONBLOCK, 0);
    if (sockfd < 0) {
        return error.SocketCreationFailed;
    }

    const opt: c_int = 1;
    _ = c.setsockopt(sockfd, c.SOL_SOCKET, c.SO_REUSEADDR, &opt, @sizeOf(c_int));

    var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
    addr.sin_family = c.AF_INET;
    addr.sin_addr.s_addr = c.INADDR_ANY;
    addr.sin_port = c.htons(port);

    // Use C wrapper to avoid Zig 0.12.0 union type issues
    const bind_result = blitz_bind(sockfd, &addr);
    if (bind_result < 0) {
        std.log.err("bind() failed on port {}", .{port});
        _ = c.close(sockfd);
        return error.BindFailed;
    }

    if (c.listen(sockfd, 1024) < 0) {
        _ = c.close(sockfd);
        return error.ListenFailed;
    }

    return sockfd;
}

pub fn runEchoServer(port: u16) !void {
    const server_fd = try createServerSocket(port);
    defer _ = c.close(server_fd);

    std.log.info("Echo server listening on port {}", .{port});
    std.log.info("Target: 3M+ RPS", .{});

    // Initialize allocators at startup - zero allocations after this
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const backing_allocator = gpa.allocator();
    
    // Initialize TLS context (optional - only if certs exist)
    var tls_ctx: ?tls.TlsContext = null;
    const cert_path = "certs/server.crt";
    const key_path = "certs/server.key";
    
    // Try to load TLS certificates (non-fatal if they don't exist)
    tls_ctx = blk: {
        break :blk tls.TlsContext.init() catch |err| {
            std.log.warn("TLS initialization failed: {} (continuing without TLS)", .{err});
            break :blk null;
        };
    };
    
    if (tls_ctx) |*ctx| {
        if (ctx.loadCertificate(cert_path, key_path)) {
            std.log.info("TLS 1.3 enabled with HTTP/2 support", .{});
        } else |err| {
            std.log.warn("Failed to load TLS certificates: {} (continuing without TLS)", .{err});
            ctx.deinit();
            tls_ctx = null;
        }
    }
    
    defer {
        if (tls_ctx) |*ctx| {
            ctx.deinit();
        }
    }

    // Pre-allocate buffer pool (all buffers allocated at startup)
    var buffer_pool = try allocator.BufferPool.init(backing_allocator, BUFFER_SIZE, BUFFER_POOL_SIZE);
    defer buffer_pool.deinit();

    // Use HashMap for connection storage (handles any fd value safely)
    var connections = std.AutoHashMap(c_int, Connection).init(backing_allocator);
    defer connections.deinit();

    // Submit initial accept
    const sqe_opt = blitz_io_uring_get_sqe(&ring);
    if (sqe_opt == null) {
        return error.GetSqeFailed;
    }
    var sqe = sqe_opt.?;

    c.io_uring_prep_accept(sqe, server_fd, null, null, 0);
    setSqeData(sqe, encodeUserData(server_fd, .accept));
    _ = c.io_uring_submit(&ring);

    var connection_count: u64 = 0;
    var total_requests: u64 = 0;
    var requests_this_second: u64 = 0;
    var last_stats_time = std.time.nanoTimestamp();

    // Main event loop - this is where the magic happens
    while (true) {
        var cqe: ?*c.struct_io_uring_cqe = null;
        _ = blitz_io_uring_wait_cqe(&ring, &cqe);

        if (cqe == null) {
            continue;
        }

        const res = cqe.?.res;
        const user_data = cqe.?.user_data;
        const decoded = decodeUserData(user_data);

        blitz_io_uring_cqe_seen(&ring, cqe);

        if (res < 0) {
            if (decoded.op == .read or decoded.op == .write) {
                _ = c.close(decoded.fd);
            }
            continue;
        }

        switch (decoded.op) {
            .accept => {
                const client_fd: c_int = res;
                connection_count += 1;

                // Get read buffer from pool (zero allocation)
                const read_buf = buffer_pool.acquireRead() orelse {
                    // Pool exhausted - close connection and continue
                    _ = c.close(client_fd);
                    // Re-submit accept
                    const sqe_opt2 = blitz_io_uring_get_sqe(&ring);
                    if (sqe_opt2 == null) continue;
                    sqe = sqe_opt2.?;
                        c.io_uring_prep_accept(sqe, server_fd, null, null, 0);
                    setSqeData(sqe, encodeUserData(server_fd, .accept));
                        _ = c.io_uring_submit(&ring);
                    continue;
                };

                // Store connection info in HashMap
                const now: i64 = @intCast(std.time.nanoTimestamp());
                try connections.put(client_fd, Connection{
                    .fd = client_fd,
                    .read_buffer = read_buf,
                    .in_use = true,
                    .created_at = now,
                    .last_active = now,
                    .request_count = 0,
                });
                // Don't initialize TLS here - we'll detect it from first bytes

                // Make socket non-blocking (required for OpenSSL)
                // Note: Socket is already non-blocking from SOCK_NONBLOCK flag, but ensure it's set
                const flags = c.fcntl(client_fd, c.F_GETFL, @as(c_int, 0));
                if (flags >= 0) {
                    _ = c.fcntl(client_fd, c.F_SETFL, @as(c_int, flags | c.O_NONBLOCK));
                }

                // Submit read for new connection
                const sqe_opt4 = blitz_io_uring_get_sqe(&ring);
                if (sqe_opt4 == null) {
                    buffer_pool.releaseRead(read_buf);
                    _ = c.close(client_fd);
                } else {
                    const read_sqe = sqe_opt4.?;
                    c.io_uring_prep_read(read_sqe, client_fd, read_buf.ptr, @as(c_uint, @intCast(BUFFER_SIZE)), 0);
                    setSqeData(read_sqe, encodeUserData(client_fd, .read));
                    _ = c.io_uring_submit(&ring);
                }

                // Re-submit accept for next connection
                const sqe_opt3 = blitz_io_uring_get_sqe(&ring);
                if (sqe_opt3 != null) {
                    sqe = sqe_opt3.?;
                    c.io_uring_prep_accept(sqe, server_fd, null, null, 0);
                    setSqeData(sqe, encodeUserData(server_fd, .accept));
                    _ = c.io_uring_submit(&ring);
                }
            },
            .read => {
                const bytes_read: usize = @intCast(res);
                const client_fd = decoded.fd;

                if (bytes_read == 0) {
                    // Connection closed - explicit cleanup
                    closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "client closed");
                    continue;
                }

                // Get connection from HashMap
                const conn_opt = connections.getPtr(client_fd);
                if (conn_opt == null) {
                    // Connection not found - close it
                    _ = c.close(client_fd);
                    continue;
                }
                var conn = conn_opt.?;

                const read_buf = conn.read_buffer orelse {
                    _ = c.close(client_fd);
                    continue;
                };

                // Track effective data length (decrypted_len for TLS, bytes_read for plaintext)
                var effective_bytes: usize = bytes_read;

                // Auto-detect TLS: Check if first byte is TLS_RECORD_TYPE_HANDSHAKE (TLS handshake record)
                // This MUST happen before we try to parse HTTP or handle existing TLS
                // CRITICAL ISSUE: We've already read the ClientHello into read_buf, but OpenSSL
                // with socket BIO expects to read directly from the socket. The data is no longer
                // in the socket buffer, so OpenSSL can't access it. This requires memory BIOs
                // for proper io_uring integration.
                // TODO: Refactor to use memory BIOs to feed read_buf data to OpenSSL
                if (tls_ctx != null and !conn.is_tls and bytes_read > 0) {
                    if (read_buf[0] == TLS_RECORD_TYPE_HANDSHAKE) {
                        // Looks like TLS ClientHello - initialize TLS connection
                        // NOTE: This will currently fail because socket BIO can't access already-read data
                        // The proper fix is memory BIOs (see TODO above)
                        if (tls_ctx) |*ctx| {
                            if (ctx.newConnection(client_fd)) |tls_conn| {
                                conn.tls_conn = tls_conn;
                                conn.is_tls = true;
                                std.log.debug("TLS connection detected, starting handshake", .{});
                                
                                // Feed the ClientHello data we already read to OpenSSL via memory BIO
                                var tls_conn_mut = conn.tls_conn.?;
                                tls_conn_mut.feedData(read_buf[0..bytes_read]) catch |err| {
                                    std.log.warn("Failed to feed TLS data: {}", .{err});
                                    buffer_pool.releaseRead(read_buf);
                                    _ = c.close(client_fd);
                                    continue;
                                };
                                
                                // Start TLS handshake (now OpenSSL can access the data via memory BIO)
                                _ = tls_conn_mut.doHandshake() catch |err| {
                                    std.log.warn("TLS handshake failed: {}", .{err});
                                    buffer_pool.releaseRead(read_buf);
                                    _ = c.close(client_fd);
                                    continue;
                                };
                                
                                // Check if handshake needs more data or produced encrypted output
                                if (tls_conn_mut.state == .handshake) {
                                    // Check if there's encrypted output to send (ServerHello, etc.)
                                    if (tls_conn_mut.hasEncryptedOutput()) {
                                        // Get encrypted output and write it via io_uring
                                        const write_buf_tls = buffer_pool.acquireWrite() orelse {
                                            buffer_pool.releaseRead(read_buf);
                                            _ = c.close(client_fd);
                                            continue;
                                        };
                                        const encrypted_len = tls_conn_mut.getEncryptedOutput(write_buf_tls) catch |err| {
                                            std.log.warn("Failed to get TLS encrypted output: {}", .{err});
                                            buffer_pool.releaseWrite(write_buf_tls);
                                            buffer_pool.releaseRead(read_buf);
                                            _ = c.close(client_fd);
                                            continue;
                                        };
                                        
                                        if (connections.getPtr(client_fd)) |conn_ptr| {
                                            conn_ptr.write_buffer = write_buf_tls;
                                        }
                                        
                                        const sqe_opt_tls_write = blitz_io_uring_get_sqe(&ring);
                                        if (sqe_opt_tls_write == null) {
                                            buffer_pool.releaseRead(read_buf);
                                            continue;
                                        }
                                        sqe = sqe_opt_tls_write.?;
                                        c.io_uring_prep_write(sqe, client_fd, write_buf_tls.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                                        setSqeData(sqe, encodeUserData(client_fd, .write));
                                        _ = c.io_uring_submit(&ring);
                                    }
                                    
                                    // If still handshaking, need more data from client
                                    const sqe_opt_tls = blitz_io_uring_get_sqe(&ring);
                                    if (sqe_opt_tls == null) {
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    }
                                    sqe = sqe_opt_tls.?;
                                    c.io_uring_prep_read(sqe, client_fd, read_buf.ptr, @as(c_uint, @intCast(BUFFER_SIZE)), 0);
                                    setSqeData(sqe, encodeUserData(client_fd, .read));
                                    _ = c.io_uring_submit(&ring);
                                    buffer_pool.releaseRead(read_buf);
                                    continue;
                                }
                                
                                // Handshake complete - send any remaining encrypted output
                                if (tls_conn_mut.hasEncryptedOutput()) {
                                    const write_buf_tls = buffer_pool.acquireWrite() orelse {
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    const encrypted_len = tls_conn_mut.getEncryptedOutput(write_buf_tls) catch |err| {
                                        std.log.warn("Failed to get TLS encrypted output: {}", .{err});
                                        buffer_pool.releaseWrite(write_buf_tls);
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    if (connections.getPtr(client_fd)) |conn_ptr| {
                                        conn_ptr.write_buffer = write_buf_tls;
                                    }
                                    
                                    const sqe_opt_tls_write2 = blitz_io_uring_get_sqe(&ring);
                                    if (sqe_opt_tls_write2 == null) {
                                        buffer_pool.releaseRead(read_buf);
                                        continue;
                                    }
                                    sqe = sqe_opt_tls_write2.?;
                                    c.io_uring_prep_write(sqe, client_fd, write_buf_tls.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                                    setSqeData(sqe, encodeUserData(client_fd, .write));
                                    _ = c.io_uring_submit(&ring);
                                }
                                
                                // Handshake complete - wait for encrypted application data
                                // Don't try to read immediately - wait for next io_uring read event
                                // The client will send encrypted HTTP request in next packet
                                buffer_pool.releaseRead(read_buf);
                                continue;
                            } else |err| {
                                std.log.warn("Failed to create TLS connection: {} (treating as plaintext)", .{err});
                                // Fall through to plaintext HTTP/1.1
                            }
                        }
                    }
                    // If not TLS (first byte != TLS_RECORD_TYPE_HANDSHAKE), fall through to plaintext HTTP/1.1
                }

                // Handle TLS handshake if in progress (continuation after initial detection)
                if (conn.is_tls) {
                    if (conn.tls_conn) |*tls_conn| {
                        if (tls_conn.state == .handshake) {
                            // Feed new data to TLS connection
                            tls_conn.feedData(read_buf[0..bytes_read]) catch |err| {
                                std.log.warn("Failed to feed TLS data: {}", .{err});
                                buffer_pool.releaseRead(read_buf);
                                _ = c.close(client_fd);
                                continue;
                            };
                            
                            // Continue TLS handshake
                            _ = tls_conn.doHandshake() catch |err| {
                                std.log.warn("TLS handshake failed: {}", .{err});
                                buffer_pool.releaseRead(read_buf);
                                _ = c.close(client_fd);
                                continue;
                            };
                            
                            // Check handshake state after doHandshake
                            if (tls_conn.state == .handshake) {
                                // Check for encrypted output to send
                                if (tls_conn.hasEncryptedOutput()) {
                                    const write_buf_tls = buffer_pool.acquireWrite() orelse {
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    const encrypted_len = tls_conn.getEncryptedOutput(write_buf_tls) catch |err| {
                                        std.log.warn("Failed to get TLS encrypted output: {}", .{err});
                                        buffer_pool.releaseWrite(write_buf_tls);
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    if (connections.getPtr(client_fd)) |conn_ptr| {
                                        conn_ptr.write_buffer = write_buf_tls;
                                    }
                                    
                                    const sqe_opt_tls_write = blitz_io_uring_get_sqe(&ring);
                                    if (sqe_opt_tls_write == null) {
                                        buffer_pool.releaseRead(read_buf);
                                        continue;
                                    }
                                    sqe = sqe_opt_tls_write.?;
                                    c.io_uring_prep_write(sqe, client_fd, write_buf_tls.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                                    setSqeData(sqe, encodeUserData(client_fd, .write));
                                    _ = c.io_uring_submit(&ring);
                                }
                                
                                // Need more data - submit another read
                                const sqe_opt5 = blitz_io_uring_get_sqe(&ring);
                                if (sqe_opt5 == null) {
                                    buffer_pool.releaseRead(read_buf);
                                    _ = c.close(client_fd);
                                    continue;
                                }
                                sqe = sqe_opt5.?;
                                c.io_uring_prep_read(sqe, client_fd, read_buf.ptr, @as(c_uint, @intCast(BUFFER_SIZE)), 0);
                                setSqeData(sqe, encodeUserData(client_fd, .read));
                                _ = c.io_uring_submit(&ring);
                                buffer_pool.releaseRead(read_buf);
                                continue;
                            }
                            
                            // Handshake complete - send any remaining encrypted output (final Finished message)
                            if (tls_conn.hasEncryptedOutput()) {
                                const write_buf_tls = buffer_pool.acquireWrite() orelse {
                                    buffer_pool.releaseRead(read_buf);
                                    closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "no write buffer");
                                    continue;
                                };
                                const encrypted_len = tls_conn.getEncryptedOutput(write_buf_tls) catch |err| {
                                    std.log.warn("Failed to get TLS encrypted output: {}", .{err});
                                    buffer_pool.releaseWrite(write_buf_tls);
                                    buffer_pool.releaseRead(read_buf);
                                    closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "getEncryptedOutput failed");
                                    continue;
                                };
                                
                                if (connections.getPtr(client_fd)) |conn_ptr| {
                                    conn_ptr.write_buffer = write_buf_tls;
                                }
                                
                                const sqe_opt_tls_write2 = blitz_io_uring_get_sqe(&ring);
                                if (sqe_opt_tls_write2 == null) {
                                    buffer_pool.releaseRead(read_buf);
                                    continue;
                                }
                                sqe = sqe_opt_tls_write2.?;
                                c.io_uring_prep_write(sqe, client_fd, write_buf_tls.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                                setSqeData(sqe, encodeUserData(client_fd, .write));
                                _ = c.io_uring_submit(&ring);
                            }
                            
                            // Handshake complete - WAIT for next read event (encrypted HTTP request)
                            // Don't try to decrypt yet - client will send encrypted HTTP GET in next packet
                            // Note: read_bio should be empty after handshake (all handshake data consumed by SSL_accept)
                            buffer_pool.releaseRead(read_buf);
                            continue;
                        }
                        
                        // Check if TLS is now connected (after handshake or if already connected)
                        if (tls_conn.state == .connected) {
                                // This is encrypted application data (HTTP request)
                                // Feed encrypted data from io_uring to OpenSSL read_bio
                                tls_conn.feedData(read_buf[0..bytes_read]) catch |err| {
                                    std.log.warn("Failed to feed TLS application data: {}", .{err});
                                    buffer_pool.releaseRead(read_buf);
                                    closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "TLS feedData failed");
                                    continue;
                                };
                                
                                // Decrypt data: SSL_read reads from read_bio, decrypts, writes to buffer
                                // Note: We use a separate buffer for decrypted data to avoid overwriting
                                // The encrypted data in read_buf is already fed to read_bio
                                const tls_decrypted_len = tls_conn.read(read_buf) catch |err| {
                                    if (err == error.WantRead) {
                                        // Need more data
                                        const sqe_opt6 = blitz_io_uring_get_sqe(&ring);
                                        if (sqe_opt6 == null) {
                                            buffer_pool.releaseRead(read_buf);
                                            _ = c.close(client_fd);
                                            continue;
                                        }
                                        sqe = sqe_opt6.?;
                                        c.io_uring_prep_read(sqe, client_fd, read_buf.ptr, @as(c_uint, @intCast(BUFFER_SIZE)), 0);
                                        setSqeData(sqe, encodeUserData(client_fd, .read));
                                        _ = c.io_uring_submit(&ring);
                                        continue;
                                    } else {
                                        std.log.warn("TLS read failed: {}", .{err});
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    }
                                };
                                
                                // Update protocol based on ALPN
                                conn.protocol = tls_conn.protocol;
                                
                                // Initialize HTTP/2 connection if negotiated
                                if (tls_conn.protocol == .http2) {
                                    if (conn.http2_conn == null) {
                                        const http2_conn = http2.Http2Connection.init(backing_allocator);
                                        conn.http2_conn = backing_allocator.create(http2.Http2Connection) catch {
                                            std.log.warn("Failed to allocate HTTP/2 connection", .{});
                                            buffer_pool.releaseRead(read_buf);
                                            _ = c.close(client_fd);
                                            continue;
                                        };
                                        conn.http2_conn.?.* = http2_conn;
                                    }
                                    
                                    // Handle HTTP/2 frames using decrypted data
                                    conn.http2_conn.?.handleFrame(read_buf[0..tls_decrypted_len]) catch |err| {
                                        std.log.warn("HTTP/2 frame handling failed: {}", .{err});
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    // TODO: Implement proper HTTP/2 response generation
                                    // For now, send GOAWAY frame before closing
                                    std.log.warn("HTTP/2 response not yet implemented, sending GOAWAY", .{});
                                    
                                    // Send GOAWAY frame (RFC 7540 Section 6.8)
                                    // Frame: 9 bytes header + 8 bytes payload
                                    const goaway_buf = buffer_pool.acquireWrite() orelse {
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    // GOAWAY frame header (9 bytes)
                                    // Length: 8 (payload size)
                                    goaway_buf[0] = 0;
                                    goaway_buf[1] = 0;
                                    goaway_buf[2] = 8; // Length: 8 bytes
                                    goaway_buf[3] = 7; // Frame type: GOAWAY
                                    goaway_buf[4] = 0; // Flags: none
                                    goaway_buf[5] = 0; // Reserved + Stream ID (0 for GOAWAY)
                                    goaway_buf[6] = 0;
                                    goaway_buf[7] = 0;
                                    goaway_buf[8] = 0;
                                    
                                    // GOAWAY payload (8 bytes)
                                    // Last-Stream-ID: 0 (no streams processed)
                                    goaway_buf[9] = 0;
                                    goaway_buf[10] = 0;
                                    goaway_buf[11] = 0;
                                    goaway_buf[12] = 0;
                                    // Error Code: ENHANCE_YOUR_CALM (0x0B) - server is closing
                                    goaway_buf[13] = 0;
                                    goaway_buf[14] = 0;
                                    goaway_buf[15] = 0;
                                    goaway_buf[16] = 0x0B; // ENHANCE_YOUR_CALM
                                    
                                    // Encrypt and send GOAWAY frame
                                    _ = tls_conn.write(goaway_buf[0..17]) catch |err| {
                                        std.log.warn("Failed to send GOAWAY frame: {}", .{err});
                                        buffer_pool.releaseWrite(goaway_buf);
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    const encrypted_goaway_len = tls_conn.getEncryptedOutput(goaway_buf) catch |err| {
                                        std.log.warn("Failed to get encrypted GOAWAY: {}", .{err});
                                        buffer_pool.releaseWrite(goaway_buf);
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    if (connections.getPtr(client_fd)) |conn_ptr| {
                                        conn_ptr.write_buffer = goaway_buf;
                                    }
                                    
                                    const sqe_opt_goaway = blitz_io_uring_get_sqe(&ring);
                                    if (sqe_opt_goaway != null) {
                                        sqe = sqe_opt_goaway.?;
                                        c.io_uring_prep_write(sqe, client_fd, goaway_buf.ptr, @as(c_uint, @intCast(encrypted_goaway_len)), 0);
                                        setSqeData(sqe, encodeUserData(client_fd, .write));
                                        _ = c.io_uring_submit(&ring);
                                    }
                                    
                                    buffer_pool.releaseRead(read_buf);
                                    // Connection will be closed after GOAWAY is sent (in write handler)
                                    continue;
                                }
                                
                                // HTTP/1.1 over TLS - use decrypted data for parsing
                                // OpenSSL SSL_read decrypts in-place, so read_buf contains decrypted data
                                // Update effective_bytes to use decrypted length
                                effective_bytes = tls_decrypted_len;
                                
                                // Update connection tracking
                                const now: i64 = @intCast(std.time.nanoTimestamp());
                                conn.last_active = now;
                                conn.request_count += 1;
                                
                                // Check connection limits
                                if (conn.request_count > Connection.MAX_REQUESTS_PER_CONN) {
                                    std.log.warn("Connection {} exceeded max requests ({}), closing", .{ client_fd, Connection.MAX_REQUESTS_PER_CONN });
                                    buffer_pool.releaseRead(read_buf);
                                    _ = c.close(client_fd);
                                    _ = connections.remove(client_fd);
                                    continue;
                                }
                                
                                total_requests += 1;
                                requests_this_second += 1;
                                // Fall through to shared HTTP/1.1 handler below
                            } else if (tls_conn.state == .tls_error or tls_conn.state == .closed) {
                                // TLS error or closed state
                                std.log.warn("TLS error/closed state: {}", .{tls_conn.state});
                                buffer_pool.releaseRead(read_buf);
                                _ = c.close(client_fd);
                                continue;
                            } else {
                                // Unknown TLS state
                                std.log.warn("TLS unknown state: {}", .{tls_conn.state});
                                buffer_pool.releaseRead(read_buf);
                                _ = c.close(client_fd);
                                continue;
                            }
                    } else {
                        // TLS connection not available
                        std.log.warn("TLS expected but connection not available", .{});
                        buffer_pool.releaseRead(read_buf);
                        _ = c.close(client_fd);
                        continue;
                    }
                }

                // Plain HTTP/1.1 (no TLS) - increment counters and update tracking
                if (!conn.is_tls) {
                    const now: i64 = @intCast(std.time.nanoTimestamp());
                    conn.last_active = now;
                    conn.request_count += 1;
                    
                    // Check connection limits
                    if (conn.request_count > Connection.MAX_REQUESTS_PER_CONN) {
                        std.log.warn("Connection {} exceeded max requests ({}), closing", .{ client_fd, Connection.MAX_REQUESTS_PER_CONN });
                        buffer_pool.releaseRead(read_buf);
                        _ = c.close(client_fd);
                        _ = connections.remove(client_fd);
                        continue;
                    }
                    
                    total_requests += 1;
                    requests_this_second += 1;
                }
                // Note: TLS connections already incremented counters above

                // Parse HTTP request (zero-allocation - all slices point into read_buf)
                // For TLS: use effective_bytes (set to decrypted_len above), for plaintext: use bytes_read
                const request_data = read_buf[0..effective_bytes];
                const parsed_request = http.parseRequest(request_data) catch {
                    // Invalid request - send 400 Bad Request
                    const write_buf = buffer_pool.acquireWrite() orelse {
                        _ = c.close(client_fd);
                        continue;
                    };

                    const response = http.CommonResponses.BAD_REQUEST;
                    if (write_buf.len >= response.len) {
                        @memcpy(write_buf[0..response.len], response);
                    } else {
                        buffer_pool.releaseWrite(write_buf);
                        _ = c.close(client_fd);
                        continue;
                    }

                    if (connections.getPtr(client_fd)) |conn_ptr| {
                        conn_ptr.write_buffer = write_buf;
                    }

                    const sqe_opt2 = blitz_io_uring_get_sqe(&ring);
                    if (sqe_opt2 == null) {
                        buffer_pool.releaseRead(read_buf);
                        continue;
                    }
                    sqe = sqe_opt2.?;
                    // For TLS, encrypt before writing
                    if (conn.is_tls) {
                        if (conn.tls_conn) |*tls_conn| {
                            // CRITICAL: Release read buffer before encrypting/writing
                            buffer_pool.releaseRead(read_buf);
                            conn.read_buffer = null;
                            
                            _ = tls_conn.write(write_buf[0..response.len]) catch |err| {
                                std.log.warn("TLS write failed: {}", .{err});
                                buffer_pool.releaseWrite(write_buf);
                                closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "TLS write failed");
                                continue;
                            };
                            const encrypted_len = tls_conn.getEncryptedOutput(write_buf) catch |err| {
                                std.log.warn("Failed to get TLS encrypted output: {}", .{err});
                                buffer_pool.releaseWrite(write_buf);
                                closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "getEncryptedOutput failed");
                                continue;
                            };
                            c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                        } else {
                            c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response.len)), 0);
                        }
                    } else {
                        c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response.len)), 0);
                    }
                    setSqeData(sqe, encodeUserData(client_fd, .write));
                    _ = c.io_uring_submit(&ring);
                    buffer_pool.releaseRead(read_buf);
                    continue;
                };

                // Generate response based on parsed request
                const write_buf = buffer_pool.acquireWrite() orelse {
                    _ = c.close(client_fd);
                    continue;
                };

                var response: []const u8 = http.CommonResponses.NOT_FOUND;
                var response_len: usize = http.CommonResponses.NOT_FOUND.len;

                // Route based on path
                // /hello is optimized for benchmarking (fastest path)
                if (std.mem.eql(u8, parsed_request.path, "/hello")) {
                    response = http.CommonResponses.HELLO;
                    response_len = http.CommonResponses.HELLO.len;
                } else if (std.mem.eql(u8, parsed_request.path, "/") or std.mem.eql(u8, parsed_request.path, "/health")) {
                    // Root or health check endpoint
                    response = http.CommonResponses.OK;
                    response_len = http.CommonResponses.OK.len;
                } else if (std.mem.startsWith(u8, parsed_request.path, "/echo")) {
                    // Echo endpoint - return the path as plain text
                    // Format: "HTTP/1.1 200 OK\r\nContent-Length: X\r\nConnection: keep-alive\r\n\r\n{path}"
                    const echo_body = parsed_request.path;
                    
                    // Manually construct response for echo (simpler and faster)
                    var pos: usize = 0;
                    const status_line = "HTTP/1.1 200 OK\r\n";
                    @memcpy(write_buf[pos..][0..status_line.len], status_line);
                    pos += status_line.len;
                    
                    const content_type_header = "Content-Type: text/plain\r\n";
                    @memcpy(write_buf[pos..][0..content_type_header.len], content_type_header);
                    pos += content_type_header.len;
                    
                    const content_length_header = std.fmt.bufPrint(write_buf[pos..], "Content-Length: {}\r\n", .{echo_body.len}) catch {
                        buffer_pool.releaseWrite(write_buf);
                        _ = c.close(client_fd);
                        continue;
                    };
                    pos += content_length_header.len;
                    
                    const connection_header = "Connection: keep-alive\r\n\r\n";
                    @memcpy(write_buf[pos..][0..connection_header.len], connection_header);
                    pos += connection_header.len;
                    
                    @memcpy(write_buf[pos..][0..echo_body.len], echo_body);
                    pos += echo_body.len;
                    
                    response = write_buf[0..pos];
                    response_len = pos;
                } else {
                    // Not found
                    response = http.CommonResponses.NOT_FOUND;
                    response_len = http.CommonResponses.NOT_FOUND.len;
                }

                // Copy response to write buffer
                if (write_buf.len >= response_len) {
                    @memcpy(write_buf[0..response_len], response);
                } else {
                    buffer_pool.releaseWrite(write_buf);
                    _ = c.close(client_fd);
                    continue;
                }

                // Store write buffer in connection
                if (connections.getPtr(client_fd)) |conn_ptr| {
                    conn_ptr.write_buffer = write_buf;
                }

                // Submit write
                const sqe_opt6 = blitz_io_uring_get_sqe(&ring);
                if (sqe_opt6 == null) {
                    buffer_pool.releaseWrite(write_buf);
                    _ = c.close(client_fd);
                    continue;
                }
                sqe = sqe_opt6.?;
                
                // For TLS connections, encrypt the response using memory BIOs
                if (conn.is_tls) {
                    if (conn.tls_conn) |*tls_conn| {
                        // CRITICAL: Release read buffer before encrypting/writing
                        // Don't reuse the buffer that contained encrypted request data
                        // This prevents BIO state issues and "bad record mac" errors
                        buffer_pool.releaseRead(read_buf);
                        conn.read_buffer = null;
                        
                        // Encrypt response (puts encrypted data in write_bio)
                        _ = tls_conn.write(write_buf[0..response_len]) catch |err| {
                            std.log.warn("TLS write failed: {}", .{err});
                            buffer_pool.releaseWrite(write_buf);
                            closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "TLS write failed");
                            continue;
                        };
                        
                        // Get encrypted output from write_bio
                        // Note: Encrypted data might be larger than plaintext, but write_buf should be large enough (BUFFER_SIZE)
                        const encrypted_len = tls_conn.getEncryptedOutput(write_buf) catch |err| {
                            std.log.warn("Failed to get TLS encrypted output: {}", .{err});
                            buffer_pool.releaseWrite(write_buf);
                            closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "getEncryptedOutput failed");
                            continue;
                        };
                        
                        if (encrypted_len == 0) {
                            std.log.warn("TLS encryption produced no output", .{});
                            buffer_pool.releaseWrite(write_buf);
                            closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "no encrypted output");
                            continue;
                        }
                        
                        // Write encrypted data via io_uring
                        c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                    } else {
                        // TLS connection not available, use plain write
                        c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response_len)), 0);
                    }
                } else {
                    // Plain HTTP/1.1 write - can reuse read buffer for keep-alive
                    c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response_len)), 0);
                }
                
                setSqeData(sqe, encodeUserData(client_fd, .write));
                _ = c.io_uring_submit(&ring);
            },
            .write => {
                // After write completes, release write buffer and prepare next read for keep-alive
                const client_fd = decoded.fd;

                // Get connection - check if it still exists
                const conn_opt = connections.getPtr(client_fd);
                if (conn_opt == null) {
                    // Connection already closed - just close the fd
                    _ = c.close(client_fd);
                    continue;
                }
                const conn = conn_opt.?;

                // Release write buffer back to pool
                if (conn.write_buffer) |buf| {
                    buffer_pool.releaseWrite(buf);
                    conn.write_buffer = null;
                }

                // For TLS connections, ensure read buffer is fresh (should already be null from read handler)
                // For plain HTTP/1.1, we can reuse the read buffer
                if (conn.is_tls) {
                    // TLS: Always use a fresh read buffer for each request
                    // The previous read buffer was already released in the read handler
                    if (conn.read_buffer) |old_buf| {
                        // Shouldn't happen, but clean up just in case
                        buffer_pool.releaseRead(old_buf);
                        conn.read_buffer = null;
                    }
                }

                // Get fresh read buffer for next request
                const fresh_read_buf = buffer_pool.acquireRead();
                if (fresh_read_buf) |buf| {
                    conn.read_buffer = buf; // Store fresh buffer
                    
                    const sqe_opt2 = blitz_io_uring_get_sqe(&ring);
                    if (sqe_opt2 == null) {
                        buffer_pool.releaseRead(buf);
                        closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "no SQE for keep-alive read");
                        continue;
                    }
                    const read_sqe = sqe_opt2.?;
                    c.io_uring_prep_read(read_sqe, client_fd, buf.ptr, @as(c_uint, @intCast(BUFFER_SIZE)), 0);
                    setSqeData(read_sqe, encodeUserData(client_fd, .read));
                    _ = c.io_uring_submit(&ring);
                } else {
                    // No buffers available - close connection
                    closeConnection(client_fd, &connections, &buffer_pool, backing_allocator, "no read buffer available");
                }
            },
        }

        // Print stats and cleanup idle connections every second
        const now: i64 = @intCast(std.time.nanoTimestamp());
        if (now - last_stats_time >= std.time.ns_per_s) {
            const rps = requests_this_second;
            std.log.info("Connections: {}, Total Requests: {}, RPS: {}", .{ connection_count, total_requests, rps });
            requests_this_second = 0;
            last_stats_time = now;
            
            // Cleanup idle and expired connections
            var it = connections.iterator();
            while (it.next()) |entry| {
                const conn = entry.value_ptr;
                const idle_time = now - conn.last_active;
                const age = now - conn.created_at;
                
                // Close idle connections
                if (idle_time > Connection.IDLE_TIMEOUT_NS) {
                    std.log.debug("Closing idle connection {} (idle: {}s)", .{ entry.key_ptr.*, @divTrunc(idle_time, std.time.ns_per_s) });
                    if (conn.read_buffer) |buf| {
                        buffer_pool.releaseRead(buf);
                    }
                    if (conn.write_buffer) |buf| {
                        buffer_pool.releaseWrite(buf);
                    }
                    if (conn.tls_conn) |*tls_conn| {
                        tls_conn.deinit();
                    }
                    if (conn.http2_conn) |http2_conn| {
                        backing_allocator.destroy(http2_conn);
                    }
                    _ = c.close(entry.key_ptr.*);
                    _ = connections.remove(entry.key_ptr.*);
                    connection_count = if (connection_count > 0) connection_count - 1 else 0;
                }
                // Close expired connections (max age)
                else if (age > Connection.MAX_CONNECTION_AGE_NS) {
                    std.log.debug("Closing expired connection {} (age: {}s)", .{ entry.key_ptr.*, @divTrunc(age, std.time.ns_per_s) });
                    if (conn.read_buffer) |buf| {
                        buffer_pool.releaseRead(buf);
                    }
                    if (conn.write_buffer) |buf| {
                        buffer_pool.releaseWrite(buf);
                    }
                    if (conn.tls_conn) |*tls_conn| {
                        tls_conn.deinit();
                    }
                    if (conn.http2_conn) |http2_conn| {
                        backing_allocator.destroy(http2_conn);
                    }
                    _ = c.close(entry.key_ptr.*);
                    _ = connections.remove(entry.key_ptr.*);
                    connection_count = if (connection_count > 0) connection_count - 1 else 0;
                }
            }
        }
    }
}
