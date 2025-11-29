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
const MAX_CONNECTIONS: usize = 100000; // Pre-allocated connection slots
const BUFFER_POOL_SIZE: usize = 200000; // Pre-allocated buffers

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
};

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

    // Pre-allocate connection table (fixed-size array, no hash map overhead)
    // We'll use fd as index (with bounds checking)
    const connections = try backing_allocator.alloc(Connection, MAX_CONNECTIONS);
    defer backing_allocator.free(connections);
    @memset(connections, Connection{ .fd = -1, .in_use = false });

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

                // Store connection info (using fd as index with bounds check)
                if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                    var conn = &connections[@intCast(client_fd)];
                    conn.* = Connection{
                        .fd = client_fd,
                        .read_buffer = read_buf,
                        .in_use = true,
                    };
                    
                    // Initialize TLS connection if TLS is enabled
                    if (tls_ctx) |*ctx| {
                        if (ctx.newConnection(client_fd)) |tls_conn| {
                            conn.tls_conn = tls_conn;
                            conn.is_tls = true;
                        } else |err| {
                            std.log.warn("Failed to create TLS connection: {} (continuing without TLS)", .{err});
                            // Continue without TLS for this connection
                            conn.is_tls = false;
                        }
                    }
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
                    // Connection closed - release buffers
                    if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                        const conn = &connections[@intCast(client_fd)];
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
                            http2_conn.deinit();
                            backing_allocator.destroy(http2_conn);
                        }
                        conn.* = Connection{ .fd = -1, .in_use = false };
                    }
                    _ = c.close(client_fd);
                    continue;
                }

                // Get connection
                const conn = if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS)
                    &connections[@intCast(client_fd)]
                else {
                    _ = c.close(client_fd);
                    continue;
                };

                const read_buf = conn.read_buffer orelse {
                    _ = c.close(client_fd);
                    continue;
                };

                // Handle TLS handshake if in progress
                if (conn.is_tls) {
                    if (conn.tls_conn) |*tls_conn| {
                        if (tls_conn.state == .handshake) {
                            // Perform TLS handshake
                            _ = tls_conn.doHandshake() catch |err| {
                                std.log.warn("TLS handshake failed: {}", .{err});
                                buffer_pool.releaseRead(read_buf);
                                _ = c.close(client_fd);
                                continue;
                            };
                            
                            // Check handshake state after doHandshake
                            if (tls_conn.state == .handshake) {
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
                                continue;
                            }
                        }
                        
                        // Check if TLS is now connected (after handshake or if already connected)
                        if (tls_conn.state == .connected) {
                                // Handshake complete - decrypt data
                                const decrypted_len = tls_conn.read(read_buf) catch |err| {
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
                                    
                                    // Handle HTTP/2 frames
                                    conn.http2_conn.?.handleFrame(read_buf[0..decrypted_len]) catch |err| {
                                        std.log.warn("HTTP/2 frame handling failed: {}", .{err});
                                        buffer_pool.releaseRead(read_buf);
                                        _ = c.close(client_fd);
                                        continue;
                                    };
                                    
                                    // For now, send a simple HTTP/2 response
                                    // TODO: Implement proper HTTP/2 response generation
                                    buffer_pool.releaseRead(read_buf);
                                    continue;
                                }
                                
                                // HTTP/1.1 over TLS - process decrypted data
                                // Fall through to HTTP/1.1 handler below
                            } else {
                                // TLS error
                                std.log.warn("TLS error state: {}", .{tls_conn.state});
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
                
                // Plain HTTP/1.1 (no TLS) or HTTP/1.1 over TLS (after decryption)
                total_requests += 1;
                requests_this_second += 1;

                // Parse HTTP request (zero-allocation - all slices point into read_buf)
                const request_data = read_buf[0..bytes_read];
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

                    if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                        connections[@intCast(client_fd)].write_buffer = write_buf;
                    }

                    const sqe_opt2 = blitz_io_uring_get_sqe(&ring);
                    if (sqe_opt2 == null) continue;
                    sqe = sqe_opt2.?;
                    c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response.len)), 0);
                    setSqeData(sqe, encodeUserData(client_fd, .write));
                _ = c.io_uring_submit(&ring);
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
                if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                    connections[@intCast(client_fd)].write_buffer = write_buf;
                }

                // Submit write
                const sqe_opt6 = blitz_io_uring_get_sqe(&ring);
                if (sqe_opt6 == null) {
                    buffer_pool.releaseWrite(write_buf);
                    _ = c.close(client_fd);
                    continue;
                }
                sqe = sqe_opt6.?;
                
                // For TLS connections, encrypt the response before writing
                // Note: OpenSSL's SSL_write handles encryption, but we need to call it
                // before submitting to io_uring. For now, we'll write plain data and
                // handle encryption in a future optimization.
                if (conn.is_tls) {
                    if (conn.tls_conn) |*tls_conn| {
                        // Encrypt response using TLS write
                        const encrypted_len = tls_conn.write(write_buf[0..response_len]) catch |err| {
                            std.log.warn("TLS write failed: {}", .{err});
                            buffer_pool.releaseWrite(write_buf);
                            _ = c.close(client_fd);
                            continue;
                        };
                        // Write encrypted data (OpenSSL handles encryption internally)
                        c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(encrypted_len)), 0);
                    } else {
                        // TLS connection not available, use plain write
                        c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response_len)), 0);
                    }
                } else {
                    // Plain HTTP/1.1 write
                    c.io_uring_prep_write(sqe, client_fd, write_buf.ptr, @as(c_uint, @intCast(response_len)), 0);
                }
                
                setSqeData(sqe, encodeUserData(client_fd, .write));
                _ = c.io_uring_submit(&ring);
            },
            .write => {
                // After write completes, release write buffer and prepare next read for keep-alive
                const client_fd = decoded.fd;

                // Release write buffer back to pool
                if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                    const conn = &connections[@intCast(client_fd)];
                    if (conn.write_buffer) |buf| {
                        buffer_pool.releaseWrite(buf);
                        conn.write_buffer = null;
                    }
                }

                // Reuse existing read buffer for next read
                var read_buf: ?[]u8 = null;
                if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                    read_buf = connections[@intCast(client_fd)].read_buffer;
                }

                if (read_buf == null) {
                    // No read buffer - get new one from pool
                    read_buf = buffer_pool.acquireRead();
                    if (read_buf) |buf| {
                        if (client_fd >= 0 and @as(usize, @intCast(client_fd)) < MAX_CONNECTIONS) {
                            connections[@intCast(client_fd)].read_buffer = buf;
                        }
                    }
                }

                if (read_buf) |buf| {
                    const sqe_opt2 = blitz_io_uring_get_sqe(&ring);
                    if (sqe_opt2 == null) {
                        buffer_pool.releaseRead(buf);
                        _ = c.close(client_fd);
                        continue;
                    }
                    const read_sqe = sqe_opt2.?;
                    c.io_uring_prep_read(read_sqe, client_fd, buf.ptr, @as(c_uint, @intCast(BUFFER_SIZE)), 0);
                    setSqeData(read_sqe, encodeUserData(client_fd, .read));
                    _ = c.io_uring_submit(&ring);
                } else {
                    // No buffers available - close connection
                    _ = c.close(client_fd);
                }
            },
        }

        // Print stats every second
        const now = std.time.nanoTimestamp();
        if (now - last_stats_time >= std.time.ns_per_s) {
            const rps = requests_this_second;
            std.log.info("Connections: {}, Total Requests: {}, RPS: {}", .{ connection_count, total_requests, rps });
            requests_this_second = 0;
            last_stats_time = now;
        }
    }
}
