// HTTP/2 Frame parsing and construction
// Optimized for zero-allocation and SIMD where possible

const std = @import("std");

pub const FrameType = enum(u8) {
    data = 0,
    headers = 1,
    priority = 2,
    rst_stream = 3,
    settings = 4,
    push_promise = 5,
    ping = 6,
    goaway = 7,
    window_update = 8,
    continuation = 9,
};

pub const FrameFlags = packed struct(u8) {
    end_stream: bool = false,
    ack: bool = false,
    end_headers: bool = false,
    padded: bool = false,
    priority: bool = false,
    unused: u3 = 0,
    
    pub fn fromInt(flags: u8) FrameFlags {
        return @bitCast(flags);
    }
    
    pub fn toInt(self: FrameFlags) u8 {
        return @bitCast(self);
    }
};

pub const FrameHeader = packed struct {
    length: u24, // 24-bit length (max 16384)
    frame_type: FrameType,
    flags: u8,
    reserved: u1 = 0,
    stream_id: u31, // 31-bit stream ID
    
    pub const SIZE: usize = 9;
    
    pub fn parse(data: []const u8) !FrameHeader {
        if (data.len < SIZE) {
            return error.IncompleteFrame;
        }
        
        const length = std.mem.readInt(u24, data[0..3], .big);
        const frame_type = @as(FrameType, @enumFromInt(data[3]));
        const flags = data[4];
        const stream_id_raw = std.mem.readInt(u32, data[5..9], .big);
        const stream_id = @as(u31, @truncate(stream_id_raw & 0x7FFFFFFF));
        
        return FrameHeader{
            .length = length,
            .frame_type = frame_type,
            .flags = flags,
            .stream_id = stream_id,
        };
    }
    
    pub fn serialize(self: FrameHeader, buf: []u8) !void {
        if (buf.len < SIZE) {
            return error.BufferTooSmall;
        }
        
        std.mem.writeInt(u24, buf[0..3], self.length, .big);
        buf[3] = @intFromEnum(self.frame_type);
        buf[4] = self.flags;
        const stream_id_u32: u32 = @intCast(self.stream_id);
        std.mem.writeInt(u32, buf[5..9], stream_id_u32, .big);
    }
};

pub const SettingsFrame = struct {
    header: FrameHeader,
    settings: []const Setting,
    
    pub const Setting = struct {
        id: u16,
        value: u32,
    };
    
    pub fn parse(data: []const u8) !SettingsFrame {
        const header = try FrameHeader.parse(data);
        if (header.frame_type != .settings) {
            return error.WrongFrameType;
        }
        
        if (header.length % 6 != 0) {
            return error.InvalidSettingsLength;
        }
        
        // For now, return empty settings array
        // In production, we'd parse the settings from data[FrameHeader.SIZE..]
        const empty_settings: []const Setting = &[_]Setting{};
        
        return SettingsFrame{
            .header = header,
            .settings = empty_settings,
        };
    }
};

pub const HeadersFrame = struct {
    header: FrameHeader,
    padding: ?u8 = null,
    priority: ?Priority = null,
    header_block: []const u8,
    
    pub const Priority = struct {
        exclusive: bool,
        stream_dependency: u31,
        weight: u8,
    };
    
    pub fn parse(data: []const u8) !HeadersFrame {
        const header = try FrameHeader.parse(data);
        if (header.frame_type != .headers) {
            return error.WrongFrameType;
        }
        
        var offset: usize = FrameHeader.SIZE;
        
        // Parse padding if present
        var padding: ?u8 = null;
        if (header.flags & 0x08 != 0) { // PADDED flag
            if (offset >= data.len) return error.IncompleteFrame;
            padding = data[offset];
            offset += 1;
        }
        
        // Parse priority if present
        var priority: ?Priority = null;
        if (header.flags & 0x20 != 0) { // PRIORITY flag
            if (offset + 5 > data.len) return error.IncompleteFrame;
            const dep_raw = std.mem.readInt(u32, data[offset..][0..4], .big);
            const exclusive = (dep_raw & 0x80000000) != 0;
            const stream_dependency = @as(u31, @truncate(dep_raw & 0x7FFFFFFF));
            const weight = data[offset + 4];
            priority = Priority{
                .exclusive = exclusive,
                .stream_dependency = stream_dependency,
                .weight = weight,
            };
            offset += 5;
        }
        
        // Calculate header block length
        const padding_len = if (padding) |p| p else 0;
        const header_block_len = header.length - (offset - FrameHeader.SIZE) - padding_len;
        
        if (offset + header_block_len > data.len) {
            return error.IncompleteFrame;
        }
        
        const header_block = data[offset..][0..header_block_len];
        
        return HeadersFrame{
            .header = header,
            .padding = padding,
            .priority = priority,
            .header_block = header_block,
        };
    }
};

pub const DataFrame = struct {
    header: FrameHeader,
    padding: ?u8 = null,
    data: []const u8,
    
    pub fn parse(data: []const u8) !DataFrame {
        const header = try FrameHeader.parse(data);
        if (header.frame_type != .data) {
            return error.WrongFrameType;
        }
        
        var offset: usize = FrameHeader.SIZE;
        
        // Parse padding if present
        var padding: ?u8 = null;
        if (header.flags & 0x08 != 0) { // PADDED flag
            if (offset >= data.len) return error.IncompleteFrame;
            padding = data[offset];
            offset += 1;
        }
        
        // Calculate data length
        const padding_len = if (padding) |p| p else 0;
        const data_len = header.length - (offset - FrameHeader.SIZE) - padding_len;
        
        if (offset + data_len > data.len) {
            return error.IncompleteFrame;
        }
        
        const frame_data = data[offset..][0..data_len];
        
        return DataFrame{
            .header = header,
            .padding = padding,
            .data = frame_data,
        };
    }
};

// HTTP/2 Connection Preface
pub const CONNECTION_PREFACE = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";

