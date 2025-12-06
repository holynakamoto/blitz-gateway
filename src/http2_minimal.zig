//! Minimal HTTP/2 cleartext (h2c) support for benchmarking
//! Implements just enough of HTTP/2 to make h2load work
//!
//! RFC 7540: https://tools.ietf.org/html/rfc7540
//! Section 3.2: Starting HTTP/2 for "http" URIs

const std = @import("std");

const HTTP2_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

pub const Http2Error = error{
    InvalidPreface,
    IncompleteFrame,
    UnsupportedFeature,
    ConnectionError,
    EndOfStream,
};

/// Handle HTTP/2 upgrade from HTTP/1.1
/// Per RFC 7540 Section 3.2:
/// 1. Server sends 101 Switching Protocols
/// 2. Server MUST send connection preface (SETTINGS)
/// 3. Server responds to stream 1 (the upgrade request)
/// 4. Server processes subsequent frames
pub fn handleHttp2Upgrade(stream: std.net.Stream) !void {
    std.log.info("HTTP/2 upgrade requested", .{});

    // Step 1: Send 101 Switching Protocols
    const upgrade_response =
        "HTTP/1.1 101 Switching Protocols\r\n" ++
        "Connection: Upgrade\r\n" ++
        "Upgrade: h2c\r\n" ++
        "\r\n";

    _ = try stream.write(upgrade_response);
    std.log.info("Sent 101 Switching Protocols", .{});

    // Step 2: Send server connection preface (SETTINGS frame)
    try sendSettingsFrame(stream);

    // Step 3: Read client connection preface
    var preface_buf: [24]u8 = undefined;
    var total_preface: usize = 0;
    while (total_preface < 24) {
        const n = stream.read(preface_buf[total_preface..]) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            std.log.err("Failed to read HTTP/2 preface: {}", .{err});
            return err;
        };
        if (n == 0) {
            std.log.err("Connection closed before preface", .{});
            return;
        }
        total_preface += n;
    }

    if (!std.mem.eql(u8, preface_buf[0..24], HTTP2_PREFACE)) {
        std.log.err("Invalid HTTP/2 preface", .{});
        return Http2Error.InvalidPreface;
    }
    std.log.info("Received valid HTTP/2 preface", .{});

    // Step 4: Respond to the original upgrade request as stream 1
    // Per RFC 7540, the upgrade request becomes the first request on stream 1
    std.log.debug("Responding to upgrade request on stream 1", .{});
    try sendResponse(stream, 1);

    // Step 5: Process HTTP/2 frames for additional requests
    processHttp2Frames(stream) catch |err| {
        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
            std.log.debug("HTTP/2 connection closed by peer", .{});
            return;
        }
        if (err == error.WouldBlock) {
            std.log.debug("Connection idle", .{});
            return;
        }
        return err;
    };
}

fn sendSettingsFrame(stream: std.net.Stream) !void {
    const settings = [_]u8{
        0x00, 0x00, 0x0c, // Length: 12 (2 settings x 6 bytes)
        0x04, // Type: SETTINGS (4)
        0x00, // Flags: none
        0x00, 0x00, 0x00, 0x00, // Stream ID: 0
        // MAX_CONCURRENT_STREAMS = 100
        0x00, 0x03, 0x00, 0x00, 0x00, 0x64,
        // INITIAL_WINDOW_SIZE = 65535
        0x00, 0x04, 0x00, 0x00, 0xff, 0xff,
    };

    _ = try stream.write(&settings);
    std.log.debug("Sent SETTINGS frame", .{});
}

fn processHttp2FramesWithBuffer(stream: std.net.Stream, initial_buffer: []const u8) !void {
    var pending: [256]u8 = undefined;
    var pending_len: usize = 0;
    
    // Copy any initial buffered data
    if (initial_buffer.len > 0) {
        @memcpy(pending[0..initial_buffer.len], initial_buffer);
        pending_len = initial_buffer.len;
    }
    
    var frames_processed: u32 = 0;
    var idle_count: u32 = 0;
    const max_idle: u32 = 50;

    while (true) {
        // Ensure we have at least 9 bytes for frame header
        while (pending_len < 9) {
            const n = stream.read(pending[pending_len..]) catch |err| {
                if (err == error.WouldBlock) {
                    idle_count += 1;
                    if (idle_count > max_idle and frames_processed > 0) {
                        return;
                    }
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    return;
                }
                return err;
            };
            if (n == 0) return;
            pending_len += n;
            idle_count = 0;
        }

        // Parse frame header from pending buffer
        const length: u24 = (@as(u24, pending[0]) << 16) |
            (@as(u24, pending[1]) << 8) |
            @as(u24, pending[2]);
        const frame_type = pending[3];
        const flags = pending[4];
        const stream_id: u31 = (@as(u31, pending[5] & 0x7F) << 24) |
            (@as(u31, pending[6]) << 16) |
            (@as(u31, pending[7]) << 8) |
            @as(u31, pending[8]);

        std.log.debug("Frame: type={}, len={}, stream={}, flags=0x{x}", .{ frame_type, length, stream_id, flags });

        // Shift pending buffer by 9 (header consumed)
        const remaining = pending_len - 9;
        if (remaining > 0) {
            var tmp: [256]u8 = undefined;
            @memcpy(tmp[0..remaining], pending[9..pending_len]);
            @memcpy(pending[0..remaining], tmp[0..remaining]);
        }
        pending_len = remaining;

        // Read payload
        var payload_buf: [16384]u8 = undefined;
        var payload: []u8 = &[_]u8{};
        if (length > 0) {
            if (length > payload_buf.len) {
                return Http2Error.UnsupportedFeature;
            }
            
            // First use any pending data
            var payload_read: usize = 0;
            if (pending_len > 0) {
                const from_pending = @min(pending_len, length);
                @memcpy(payload_buf[0..from_pending], pending[0..from_pending]);
                payload_read = from_pending;
                // Shift pending
                const new_remaining = pending_len - from_pending;
                if (new_remaining > 0) {
                    var tmp2: [256]u8 = undefined;
                    @memcpy(tmp2[0..new_remaining], pending[from_pending..pending_len]);
                    @memcpy(pending[0..new_remaining], tmp2[0..new_remaining]);
                }
                pending_len = new_remaining;
            }
            
            // Read rest from stream
            while (payload_read < length) {
                const n = stream.read(payload_buf[payload_read..length]) catch |err| {
                    if (err == error.WouldBlock) {
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                        continue;
                    }
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) return;
                    return err;
                };
                if (n == 0) return Http2Error.IncompleteFrame;
                payload_read += n;
            }
            payload = payload_buf[0..length];
        }

        frames_processed += 1;

        switch (frame_type) {
            0x00 => {}, // DATA
            0x01 => try handleHeadersFrame(stream, stream_id), // HEADERS
            0x04 => try handleSettingsFrameResponse(stream, flags), // SETTINGS
            0x06 => try handlePingFrame(stream, payload), // PING
            0x07 => return, // GOAWAY
            0x08 => {}, // WINDOW_UPDATE
            0x03 => {}, // RST_STREAM
            else => {},
        }
    }
}

fn processHttp2Frames(stream: std.net.Stream) !void {
    var frames_processed: u32 = 0;
    var idle_count: u32 = 0;
    const max_idle: u32 = 50;

    while (true) {
        var header: [9]u8 = undefined;
        var header_read: usize = 0;

        while (header_read < 9) {
            const n = stream.read(header[header_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    idle_count += 1;
                    if (idle_count > max_idle and frames_processed > 0) {
                        return;
                    }
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
                    return;
                }
                return err;
            };

            if (n == 0) return;
            header_read += n;
            idle_count = 0;
        }

        const length: u24 = (@as(u24, header[0]) << 16) |
            (@as(u24, header[1]) << 8) |
            @as(u24, header[2]);
        const frame_type = header[3];
        const flags = header[4];
        const stream_id: u31 = (@as(u31, header[5] & 0x7F) << 24) |
            (@as(u31, header[6]) << 16) |
            (@as(u31, header[7]) << 8) |
            @as(u31, header[8]);

        std.log.debug("Frame: type={}, len={}, stream={}, flags=0x{x}", .{ frame_type, length, stream_id, flags });

        // Read payload
        var payload_buf: [16384]u8 = undefined;
        var payload: []u8 = &[_]u8{};
        if (length > 0) {
            if (length > payload_buf.len) {
                return Http2Error.UnsupportedFeature;
            }
            var total_read: usize = 0;
            while (total_read < length) {
                const n = stream.read(payload_buf[total_read..length]) catch |err| {
                    if (err == error.WouldBlock) {
                        std.Thread.sleep(1 * std.time.ns_per_ms);
                        continue;
                    }
                    if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) return;
                    return err;
                };
                if (n == 0) return Http2Error.IncompleteFrame;
                total_read += n;
            }
            payload = payload_buf[0..length];
        }

        frames_processed += 1;

        switch (frame_type) {
            0x00 => {}, // DATA - ignore for benchmark
            0x01 => try handleHeadersFrame(stream, stream_id), // HEADERS
            0x04 => try handleSettingsFrameResponse(stream, flags), // SETTINGS
            0x06 => try handlePingFrame(stream, payload), // PING
            0x07 => return, // GOAWAY
            0x08 => {}, // WINDOW_UPDATE - ignore
            0x03 => {}, // RST_STREAM - ignore
            else => {},
        }
    }
}

fn handleHeadersFrame(stream: std.net.Stream, stream_id: u31) !void {
    std.log.debug("HEADERS on stream {}", .{stream_id});
    try sendResponse(stream, stream_id);
}

fn handleSettingsFrameResponse(stream: std.net.Stream, flags: u8) !void {
    if (flags & 0x01 == 0) {
        const ack = [_]u8{
            0x00, 0x00, 0x00,
            0x04, 0x01,
            0x00, 0x00, 0x00, 0x00,
        };
        _ = try stream.write(&ack);
        std.log.debug("Sent SETTINGS ACK", .{});
    }
}

fn handlePingFrame(stream: std.net.Stream, payload: []const u8) !void {
    var pong: [17]u8 = undefined;
    pong[0] = 0x00;
    pong[1] = 0x00;
    pong[2] = 0x08;
    pong[3] = 0x06;
    pong[4] = 0x01;
    pong[5] = 0x00;
    pong[6] = 0x00;
    pong[7] = 0x00;
    pong[8] = 0x00;
    if (payload.len >= 8) {
        @memcpy(pong[9..17], payload[0..8]);
    } else {
        @memset(pong[9..17], 0);
    }
    _ = try stream.write(&pong);
}

fn sendResponse(stream: std.net.Stream, stream_id: u31) !void {
    // HEADERS frame with :status 200 (HPACK indexed)
    const headers = [_]u8{ 0x88 }; // :status 200
    try sendFrame(stream, 0x01, 0x04, stream_id, &headers); // HEADERS + END_HEADERS

    // DATA frame with body + END_STREAM
    const body = "{\"status\":\"ok\",\"protocol\":\"h2c\"}\n";
    try sendFrame(stream, 0x00, 0x01, stream_id, body);

    std.log.debug("Sent response on stream {}", .{stream_id});
}

fn sendFrame(stream: std.net.Stream, frame_type: u8, flags: u8, stream_id: u31, payload: []const u8) !void {
    const len: u24 = @intCast(payload.len);
    var header: [9]u8 = undefined;
    header[0] = @intCast((len >> 16) & 0xFF);
    header[1] = @intCast((len >> 8) & 0xFF);
    header[2] = @intCast(len & 0xFF);
    header[3] = frame_type;
    header[4] = flags;
    header[5] = @intCast((stream_id >> 24) & 0x7F);
    header[6] = @intCast((stream_id >> 16) & 0xFF);
    header[7] = @intCast((stream_id >> 8) & 0xFF);
    header[8] = @intCast(stream_id & 0xFF);

    _ = try stream.write(&header);
    if (payload.len > 0) {
        _ = try stream.write(payload);
    }
}

/// Handle direct HTTP/2 connection (prior knowledge, no upgrade)
/// Used by tools like h2load that send the preface directly
pub fn handleDirectHttp2(stream: std.net.Stream, initial_data: []const u8) !void {
    std.log.info("Direct HTTP/2 connection (prior knowledge)", .{});

    // Verify we have at least the start of the preface
    if (initial_data.len < 3 or !std.mem.startsWith(u8, initial_data, "PRI")) {
        std.log.err("Invalid HTTP/2 preface start", .{});
        return Http2Error.InvalidPreface;
    }

    // Buffer to hold preface + any extra data
    var buffer: [256]u8 = undefined;
    var buf_len: usize = 0;

    // Copy initial data
    const copy_len = @min(initial_data.len, buffer.len);
    @memcpy(buffer[0..copy_len], initial_data[0..copy_len]);
    buf_len = copy_len;

    // Read more if we don't have full preface
    while (buf_len < 24) {
        const n = stream.read(buffer[buf_len..]) catch |err| {
            if (err == error.WouldBlock) {
                std.Thread.sleep(1 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return;
        buf_len += n;
    }

    // Verify preface
    if (!std.mem.eql(u8, buffer[0..24], HTTP2_PREFACE)) {
        std.log.err("Invalid HTTP/2 preface", .{});
        return Http2Error.InvalidPreface;
    }
    std.log.info("Received valid HTTP/2 preface", .{});

    // Send server SETTINGS
    try sendSettingsFrame(stream);

    // Process any buffered data after preface as frames
    // Then continue reading from stream
    const extra_data = buffer[24..buf_len];
    processHttp2FramesWithBuffer(stream, extra_data) catch |err| {
        if (err == error.ConnectionResetByPeer or err == error.BrokenPipe) {
            std.log.debug("HTTP/2 connection closed by peer", .{});
            return;
        }
        if (err == error.WouldBlock) {
            std.log.debug("Connection idle", .{});
            return;
        }
        return err;
    };
}
