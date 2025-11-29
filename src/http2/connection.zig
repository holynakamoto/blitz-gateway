// HTTP/2 Connection management
// Handles streams, flow control, and multiplexing

const std = @import("std");
const frame = @import("frame.zig");
const hpack = @import("hpack.zig");

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
    
    pub const ConnectionSettings = struct {
        header_table_size: u32 = 4096,
        enable_push: bool = false,
        max_concurrent_streams: u32 = 100,
        initial_window_size: u32 = 65535,
        max_frame_size: u32 = 16384,
        max_header_list_size: u32 = 0xFFFFFFFF, // Unlimited
    };
    
    pub fn init(allocator: std.mem.Allocator) Http2Connection {
        return Http2Connection{
            .streams = std.HashMap(u31, *Stream, std.hash_map.AutoContext(u31), std.hash_map.default_max_load_percentage).init(allocator),
            .settings = ConnectionSettings{},
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *Http2Connection) void {
        var it = self.streams.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.streams.deinit();
    }
    
    pub fn createStream(self: *Http2Connection, stream_id: u31) !*Stream {
        if (self.streams.contains(stream_id)) {
            return error.StreamExists;
        }
        
        const stream = try self.allocator.create(Stream);
        stream.* = Stream.init(self.allocator, stream_id);
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
    
    pub fn handleFrame(self: *Http2Connection, data: []const u8) !void {
        const header = try frame.FrameHeader.parse(data);
        
        switch (header.frame_type) {
            .settings => {
                // Handle SETTINGS frame
                // TODO: Parse and apply settings
            },
            .headers => {
                const headers_frame = try frame.HeadersFrame.parse(data);
                const stream = try self.getOrCreateStream(headers_frame.header.stream_id);
                _ = stream; // TODO: Process headers
            },
            .data => {
                const data_frame = try frame.DataFrame.parse(data);
                const stream = self.getStream(data_frame.header.stream_id) orelse {
                    return error.StreamNotFound;
                };
                _ = stream; // TODO: Process data
            },
            .window_update => {
                // Handle window update
                // TODO: Parse and apply window update
            },
            .ping => {
                // Handle PING frame
                // TODO: Respond with PING ACK
            },
            .goaway => {
                // Handle GOAWAY frame
                // TODO: Close connection gracefully
            },
            else => {
                // Ignore other frame types for now
            },
        }
    }
    
    fn getOrCreateStream(self: *Http2Connection, stream_id: u31) !*Stream {
        if (self.getStream(stream_id)) |stream| {
            return stream;
        }
        return self.createStream(stream_id);
    }
};

