// HTTP/2 Connection management
// Handles streams, flow control, and multiplexing

const std = @import("std");
pub const frame = @import("frame.zig");
const hpack = @import("hpack.zig");

// Default server SETTINGS (RFC 7540 compliant)
pub const DEFAULT_SERVER_SETTINGS = &[_]frame.SettingsFrame.Setting{
    .{ .id = frame.SettingsFrame.SETTINGS_HEADER_TABLE_SIZE, .value = 4096 },
    .{ .id = frame.SettingsFrame.SETTINGS_ENABLE_PUSH, .value = 0 },
    .{ .id = frame.SettingsFrame.SETTINGS_MAX_CONCURRENT_STREAMS, .value = 100 },
    .{ .id = frame.SettingsFrame.SETTINGS_INITIAL_WINDOW_SIZE, .value = 65535 },
    .{ .id = frame.SettingsFrame.SETTINGS_MAX_FRAME_SIZE, .value = 16384 },
};

pub const StreamState = enum {
    idle,
    reserved_local,
    reserved_remote,
    open,
    half_closed_local,
    half_closed_remote,
    closed,
};

pub const Stream = struct {
    id: u31,
    state: StreamState,
    window_size: i32 = 65535, // Initial window size
    decoder: hpack.HpackDecoder,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, stream_id: u31) Stream {
        return Stream{
            .id = stream_id,
            .state = .idle,
            .decoder = hpack.HpackDecoder.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Stream) void {
        self.decoder.deinit();
    }

    pub fn updateWindow(self: *Stream, increment: u32) void {
        self.window_size += @intCast(increment);
    }

    pub fn consumeWindow(self: *Stream, amount: u32) !void {
        if (@as(i32, @intCast(amount)) > self.window_size) {
            return error.WindowExceeded;
        }
        self.window_size -= @intCast(amount);
    }
};

pub const Http2Connection = struct {
    streams: std.HashMap(u31, *Stream, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage),
    connection_window: i32 = 65535,
    settings: ConnectionSettings,
    allocator: std.mem.Allocator,
    next_stream_id: u31 = 2, // Server-initiated streams are even (start at 2)
    encoder: hpack.HpackEncoder,
    settings_received: bool = false,

    pub const ConnectionSettings = struct {
        header_table_size: u32 = 4096,
        enable_push: bool = false,
        max_concurrent_streams: u32 = 100,
        initial_window_size: u32 = 65535,
        max_frame_size: u32 = 16384,
        max_header_list_size: u32 = 0xFFFFFFFF, // Unlimited
    };

    // Response action after processing a frame
    //
    // OWNERSHIP DOCUMENTATION:
    // ========================
    // This union may contain owned resources that MUST be freed by calling deinit().
    //
    // Owned resources:
    // - send_ping_ack: The []const u8 slice is owned and allocated via allocator.dupe()
    // - send_response.headers: The slice itself is owned (allocated via toOwnedSlice())
    // - send_response.headers[].value: Some header values are owned (e.g., "content-length" value
    //   is allocated via allocPrint), others are string literals. The deinit() method handles this.
    // - send_response.body: The []const u8 slice is owned and allocated via allocPrint()
    //
    /// ResponseAction represents actions that should be taken in response to HTTP/2 frames.
    ///
    /// # Memory Ownership
    ///
    /// Some variants contain allocated memory that must be freed by the caller:
    ///
    /// ## Variants with OWNED memory (must call deinit):
    ///
    /// - `send_ping_ack: []const u8`
    ///   - **Ownership**: The slice is allocated via `allocator.dupe()` in `handlePing()`.
    ///   - **Lifetime**: Owned by the ResponseAction until `deinit()` is called.
    ///   - **Freeing**: Call `action.deinit(allocator)` to free the ping data slice.
    ///   - **Example**: `defer action.deinit(allocator);`
    ///
    /// - `send_response: struct { ... }`
    ///   - **Ownership**: Contains multiple owned allocations:
    ///     - `body: []const u8` - Allocated via `allocPrint()` in `handleHeaders()`, owned by ResponseAction.
    ///     - `headers: []const hpack.HeaderField` - The slice itself is allocated via `toOwnedSlice()`, owned by ResponseAction.
    ///     - Some header values (e.g., "content-length") are allocated strings, owned by ResponseAction.
    ///   - **Lifetime**: All owned resources remain valid until `deinit()` is called.
    ///   - **Freeing**: Call `action.deinit(allocator)` to free:
    ///     1. The body slice
    ///     2. Each allocated header value (currently only "content-length")
    ///     3. The headers slice itself
    ///   - **Note**: Header names and most header values are string literals and don't need freeing.
    ///   - **Example**: `defer action.deinit(allocator);`
    ///
    /// ## Variants with NO owned memory (safe to ignore):
    ///
    /// - `none` - No data, no cleanup needed.
    /// - `send_settings: void` - No data, no cleanup needed.
    /// - `send_settings_ack: void` - No data, no cleanup needed.
    /// - `send_goaway: u31` - Only contains a stream ID (primitive value), no cleanup needed.
    /// - `close_connection: void` - No data, no cleanup needed.
    ///
    /// # Usage Pattern
    ///
    /// Always use `defer` to ensure cleanup, even for variants without owned memory:
    /// ```zig
    /// const action = try conn.handleFrame(data);
    /// defer action.deinit(allocator);
    /// // ... use action ...
    /// ```
    ///
    /// The `deinit()` function is safe to call multiple times and on variants without owned memory.
    pub const ResponseAction = union(enum) {
        none,
        send_settings: void, // Send initial server SETTINGS
        send_settings_ack: void,
        send_ping_ack: []const u8, // Opaque data (8 bytes) - OWNED, must be freed
        send_response: struct {
            stream_id: u31,
            status: u16,
            headers: []const hpack.HeaderField, // OWNED slice - must be freed along with allocated header values
            body: []const u8, // OWNED - must be freed
        },
        send_goaway: u31, // Last stream ID
        close_connection: void,

        /// Frees all owned resources in this ResponseAction.
        ///
        /// # Memory Management
        ///
        /// This function frees all memory owned by the ResponseAction:
        /// - `send_ping_ack`: Frees the ping data slice
        /// - `send_response`: Frees the body slice, allocated header values (e.g., "content-length"),
        ///   and the headers slice itself
        /// - Other variants: No-op (no owned memory)
        ///
        /// # Safety
        ///
        /// - Must be called exactly once for actions containing owned data to prevent leaks.
        /// - Safe to call multiple times (idempotent).
        /// - Safe to call on actions without owned data (no-op).
        /// - Use `defer action.deinit(allocator)` to ensure cleanup.
        ///
        /// See the ResponseAction union documentation for detailed memory ownership information.
        pub fn deinit(self: ResponseAction, allocator: std.mem.Allocator) void {
            switch (self) {
                .send_ping_ack => |ping_data| {
                    allocator.free(ping_data);
                },
                .send_response => |resp| {
                    // Free body
                    allocator.free(resp.body);

                    // Free headers slice and any allocated header values
                    for (resp.headers) |header| {
                        // Check if this header has an allocated value
                        // Currently, only "content-length" has an allocated value,
                        // but this pattern allows for future allocated header values
                        if (std.mem.eql(u8, header.name, "content-length")) {
                            allocator.free(header.value);
                        }
                        // Note: Other header values are string literals and don't need freeing
                        // Header names are always string literals in our current implementation
                    }

                    // Free the headers slice itself
                    allocator.free(resp.headers);
                },
                .none, .send_settings, .send_settings_ack, .send_goaway, .close_connection => {
                    // No owned resources to free
                },
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Http2Connection {
        return Http2Connection{
            .streams = std.HashMap(u31, *Stream, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage).init(allocator),
            .settings = ConnectionSettings{},
            .allocator = allocator,
            .encoder = hpack.HpackEncoder.init(allocator),
        };
    }

    pub fn deinit(self: *Http2Connection) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
        self.encoder.deinit();
    }

    pub fn createStream(self: *Http2Connection, stream_id: u31) !*Stream {
        if (self.streams.contains(stream_id)) {
            return error.StreamExists;
        }

        // Check concurrent stream limit
        if (self.streams.count() >= self.settings.max_concurrent_streams) {
            return error.TooManyStreams;
        }

        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id);
        stream.window_size = @intCast(self.settings.initial_window_size);
        try self.streams.put(stream_id, stream);

        return stream;
    }

    pub fn getStream(self: *Http2Connection, stream_id: u31) ?*Stream {
        return self.streams.get(stream_id);
    }

    pub fn removeStream(self: *Http2Connection, stream_id: u31) void {
        if (self.streams.fetchRemove(stream_id)) |entry| {
            entry.value.deinit();
            self.allocator.destroy(entry.value);
        }
    }

    pub fn handleFrame(self: *Http2Connection, data: []const u8) !ResponseAction {
        const header = try frame.FrameHeader.parse(data);

        switch (header.frame_type) {
            .settings => {
                return try self.handleSettings(data);
            },
            .headers => {
                return try self.handleHeaders(data);
            },
            .data => {
                return try self.handleData(data);
            },
            .window_update => {
                return try self.handleWindowUpdate(data);
            },
            .ping => {
                return try self.handlePing(data);
            },
            .goaway => {
                return ResponseAction{ .close_connection = {} };
            },
            .rst_stream => {
                // Client reset stream - just remove it
                if (header.stream_id != 0) {
                    self.removeStream(header.stream_id);
                }
                return ResponseAction.none;
            },
            else => {
                // Ignore other frame types
                return ResponseAction.none;
            },
        }
    }

    // Process all frames in the buffer, returning actions that require a response
    pub fn processAllFrames(self: *Http2Connection, data: []const u8) !struct { action: ResponseAction, needs_settings_ack: bool, bytes_consumed: usize } {
        var offset: usize = 0;
        var last_action: ResponseAction = ResponseAction.none;
        errdefer last_action.deinit(self.allocator); // Clean up on error
        var needs_settings_ack: bool = false;

        while (offset < data.len) {
            // Check if we have enough data for a frame header
            if (data.len - offset < frame.FrameHeader.SIZE) {
                break; // Incomplete frame, wait for more data
            }

            // Parse frame header to get frame length
            const header = try frame.FrameHeader.parse(data[offset..]);
            const frame_size = frame.FrameHeader.SIZE + header.length;

            // Check if we have the complete frame
            if (data.len - offset < frame_size) {
                break; // Incomplete frame, wait for more data
            }

            // Process this frame
            std.log.debug("Processing HTTP/2 frame: type={}, stream_id={}, length={}", .{ header.frame_type, header.stream_id, header.length });
            const action = try self.handleFrame(data[offset..][0..frame_size]);
            std.log.debug("Frame processed, action: {}", .{action});

            // Track actions that require a response
            // CRITICAL: If we need SETTINGS ACK, we MUST send it BEFORE any response
            switch (action) {
                .send_settings_ack => {
                    // We need to send SETTINGS ACK - mark it (will be sent first)
                    needs_settings_ack = true;
                },
                .send_response => {
                    // Response is highest priority - send this after ACK if needed
                    // Free previous action if it had owned resources
                    last_action.deinit(self.allocator);
                    last_action = action;
                },
                .send_ping_ack => {
                    // Keep track of PING ACK, but response takes priority
                    if (last_action != .send_response) {
                        // Free previous action if it had owned resources
                        last_action.deinit(self.allocator);
                        last_action = action;
                    } else {
                        // We're keeping send_response, so free this ping_ack action
                        action.deinit(self.allocator);
                    }
                },
                .send_settings => {
                    if (last_action == .none) {
                        last_action = action;
                    } else {
                        // We're keeping a different action, so free this settings action
                        // (though settings actions don't have owned resources, this is for safety)
                        action.deinit(self.allocator);
                    }
                },
                .send_goaway, .close_connection => {
                    // Free previous action if it had owned resources
                    last_action.deinit(self.allocator);
                    last_action = action;
                    offset += frame_size;
                    break; // Stop processing on GOAWAY or close
                },
                .none => {
                    // Continue processing - no owned resources to free
                },
            }

            offset += frame_size;
        }

        return .{ .action = last_action, .needs_settings_ack = needs_settings_ack, .bytes_consumed = offset };
    }

    fn handleSettings(self: *Http2Connection, data: []const u8) !ResponseAction {
        const flags = frame.FrameFlags.fromInt((try frame.FrameHeader.parse(data)).flags);

        // If ACK flag is set, this is a SETTINGS ACK from client - no response needed
        if (flags.ack) {
            return ResponseAction.none;
        }

        // Parse client settings
        const settings_frame = try frame.SettingsFrame.parse(data, self.allocator);
        defer self.allocator.free(settings_frame.settings);

        // Apply client settings
        for (settings_frame.settings) |setting| {
            switch (setting.id) {
                frame.SettingsFrame.SETTINGS_HEADER_TABLE_SIZE => {
                    self.settings.header_table_size = setting.value;
                    self.encoder.max_table_size = setting.value;
                },
                frame.SettingsFrame.SETTINGS_ENABLE_PUSH => {
                    self.settings.enable_push = (setting.value == 1);
                },
                frame.SettingsFrame.SETTINGS_MAX_CONCURRENT_STREAMS => {
                    self.settings.max_concurrent_streams = setting.value;
                },
                frame.SettingsFrame.SETTINGS_INITIAL_WINDOW_SIZE => {
                    self.settings.initial_window_size = setting.value;
                    // Update all existing streams
                    var it = self.streams.iterator();
                    while (it.next()) |entry| {
                        entry.value_ptr.*.window_size = @intCast(setting.value);
                    }
                },
                frame.SettingsFrame.SETTINGS_MAX_FRAME_SIZE => {
                    if (setting.value < 16384 or setting.value > 16777215) {
                        return error.InvalidMaxFrameSize;
                    }
                    self.settings.max_frame_size = setting.value;
                },
                frame.SettingsFrame.SETTINGS_MAX_HEADER_LIST_SIZE => {
                    self.settings.max_header_list_size = setting.value;
                },
                else => {
                    // Unknown setting - ignore per RFC 7540
                },
            }
        }

        self.settings_received = true;

        // Respond with SETTINGS ACK
        return ResponseAction{ .send_settings_ack = {} };
    }

    fn handleHeaders(self: *Http2Connection, data: []const u8) !ResponseAction {
        std.log.debug("Handling HEADERS frame", .{});
        const headers_frame = try frame.HeadersFrame.parse(data);
        const stream_id = headers_frame.header.stream_id;
        std.log.debug("HEADERS frame: stream_id={}, header_block_len={}", .{ stream_id, headers_frame.header_block.len });

        // Validate stream ID (must be odd for client-initiated streams)
        if (stream_id == 0 or stream_id % 2 == 0) {
            std.log.warn("Invalid stream ID: {} (must be odd for client-initiated)", .{stream_id});
            return error.InvalidStreamId;
        }

        // Get or create stream
        const stream = try self.getOrCreateStream(stream_id);
        stream.state = .open;

        // Decode HPACK headers
        std.log.debug("Decoding HPACK headers, {} bytes", .{headers_frame.header_block.len});
        const headers = try stream.decoder.decode(headers_frame.header_block);
        defer self.allocator.free(headers);
        std.log.debug("Decoded {} headers", .{headers.len});

        // Extract request information
        var method: []const u8 = "GET";
        var path: []const u8 = "/";
        var method_owned: ?[]u8 = null;
        var path_owned: ?[]u8 = null;
        const status: u16 = 200;

        errdefer {
            if (method_owned) |m| self.allocator.free(m);
            if (path_owned) |p| self.allocator.free(p);
        }

        for (headers) |header| {
            std.log.debug("Decoded header: name='{s}', value='{s}' (len={})", .{ header.name, header.value, header.value.len });
            if (std.mem.eql(u8, header.name, ":method")) {
                // Duplicate method string to ensure it remains valid after frame buffer is reused
                method_owned = try self.allocator.dupe(u8, header.value);
                method = method_owned.?;
            } else if (std.mem.eql(u8, header.name, ":path")) {
                // Duplicate path string to ensure it remains valid after frame buffer is reused
                path_owned = try self.allocator.dupe(u8, header.value);
                path = path_owned.?;
            }
        }

        // Clean path by stopping at first null byte (for both logging and response)
        const path_clean = std.mem.sliceTo(path, 0); // stops at first null
        std.log.info("Path: {s}", .{path_clean});

        // Generate response body (method and path are now owned and safe to use)
        const body = try std.fmt.allocPrint(self.allocator, "Hello, Blitz! (HTTP/2)\nMethod: {s}\nPath: {s}\n", .{ method, path_clean });

        // Free the duplicated strings now that they're copied into the body
        if (method_owned) |m| self.allocator.free(m);
        if (path_owned) |p| self.allocator.free(p);
        // Note: body ownership is transferred to ResponseAction - caller must call action.deinit(allocator) to free

        // Prepare response headers
        // Zig 0.15.2: Use initCapacity for ArrayList
        var response_headers = std.ArrayList(hpack.HeaderField).initCapacity(self.allocator, 8) catch return error.OutOfMemory;
        errdefer {
            for (response_headers.items) |h| {
                if (std.mem.eql(u8, h.name, "content-length")) {
                    self.allocator.free(h.value);
                }
            }
            // Zig 0.15.2: deinit requires allocator
            response_headers.deinit(self.allocator);
            self.allocator.free(body);
        }

        const content_length_str = try std.fmt.allocPrint(self.allocator, "{}", .{body.len});
        errdefer self.allocator.free(content_length_str);

        // Zig 0.15.2: append requires allocator
        try response_headers.append(hpack.HeaderField{ .name = ":status", .value = "200" });
        try response_headers.append(hpack.HeaderField{ .name = "content-type", .value = "text/plain" });
        try response_headers.append(hpack.HeaderField{ .name = "content-length", .value = content_length_str });
        try response_headers.append(hpack.HeaderField{ .name = "server", .value = "blitz-gateway" });

        return ResponseAction{
            .send_response = .{
                .stream_id = stream_id,
                .status = status,
                .headers = try response_headers.toOwnedSlice(),
                .body = body,
            },
        };
    }

    fn handleData(self: *Http2Connection, data: []const u8) !ResponseAction {
        const data_frame = try frame.DataFrame.parse(data);
        const stream = self.getStream(data_frame.header.stream_id) orelse {
            return error.StreamNotFound;
        };

        // Consume window
        try stream.consumeWindow(@intCast(data_frame.data.len));

        // If END_STREAM flag is set, mark stream as half-closed
        const flags = frame.FrameFlags.fromInt(data_frame.header.flags);
        if (flags.end_stream) {
            stream.state = .half_closed_remote;
        }

        // For now, we don't process request body - just return none
        return ResponseAction.none;
    }

    fn handleWindowUpdate(self: *Http2Connection, data: []const u8) !ResponseAction {
        const header = try frame.FrameHeader.parse(data);
        if (data.len < frame.FrameHeader.SIZE + 4) {
            return error.IncompleteFrame;
        }

        const increment = std.mem.readInt(u32, data[frame.FrameHeader.SIZE..][0..4], .big) & 0x7FFFFFFF;

        if (header.stream_id == 0) {
            // Connection-level window update
            self.connection_window += @intCast(increment);
        } else {
            // Stream-level window update
            const stream = self.getStream(header.stream_id) orelse {
                return error.StreamNotFound;
            };
            stream.updateWindow(increment);
        }

        return ResponseAction.none;
    }

    fn handlePing(self: *Http2Connection, data: []const u8) !ResponseAction {
        const header = try frame.FrameHeader.parse(data);
        const flags = frame.FrameFlags.fromInt(header.flags);

        // If ACK flag is set, this is a PING ACK from client - no response needed
        if (flags.ack) {
            return ResponseAction.none;
        }

        // Extract opaque data (8 bytes)
        if (data.len < frame.FrameHeader.SIZE + 8) {
            return error.IncompleteFrame;
        }

        const ping_data = data[frame.FrameHeader.SIZE..][0..8];
        const ping_data_copy = try self.allocator.dupe(u8, ping_data);

        // Respond with PING ACK
        return ResponseAction{ .send_ping_ack = ping_data_copy };
    }

    // Generate server SETTINGS frame
    pub fn getServerSettings(self: *Http2Connection) []const frame.SettingsFrame.Setting {
        _ = self;
        // Return default server settings from static storage
        return DEFAULT_SERVER_SETTINGS;
    }

    // Get initial server SETTINGS action (called when HTTP/2 connection is first established)
    pub fn getInitialSettingsAction(self: *Http2Connection) ResponseAction {
        _ = self;
        return ResponseAction{ .send_settings = {} };
    }

    // Generate HTTP/2 response frames
    pub fn generateResponse(self: *Http2Connection, stream_id: u31, _: u16, headers: []const hpack.HeaderField, body: []const u8, buf: []u8) !usize {
        var offset: usize = 0;

        // Encode response headers with HPACK
        const header_block_buf = buf[frame.FrameHeader.SIZE..];
        const header_block_len = try self.encoder.encode(headers, header_block_buf);

        // Write HEADERS frame
        // If there's no body, HEADERS must have both END_HEADERS (0x04) and END_STREAM (0x01) = 0x05
        // If there's a body, HEADERS only needs END_HEADERS (0x04), END_STREAM goes on DATA frame
        const headers_flags: u8 = if (body.len == 0) 0x05 else 0x04; // END_HEADERS | END_STREAM if no body, else just END_HEADERS
        const headers_frame = frame.FrameHeader{
            .length = @intCast(header_block_len),
            .frame_type = .headers,
            .flags = headers_flags,
            .stream_id = stream_id,
        };
        try headers_frame.serialize(buf[offset..]);
        offset += frame.FrameHeader.SIZE;
        offset += header_block_len;

        // Write DATA frame if body exists
        if (body.len > 0) {
            const data_frame = frame.FrameHeader{
                .length = @intCast(body.len),
                .frame_type = .data,
                .flags = 0x01, // END_STREAM flag
                .stream_id = stream_id,
            };
            try data_frame.serialize(buf[offset..]);
            offset += frame.FrameHeader.SIZE;

            if (offset + body.len > buf.len) {
                return error.BufferTooSmall;
            }
            @memcpy(buf[offset..][0..body.len], body);
            offset += body.len;
        }

        return offset;
    }

    fn getOrCreateStream(self: *Http2Connection, stream_id: u31) !*Stream {
        if (self.getStream(stream_id)) |stream| {
            return stream;
        }
        return self.createStream(stream_id);
    }
};
