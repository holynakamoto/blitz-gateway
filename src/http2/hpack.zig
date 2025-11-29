// HPACK header compression for HTTP/2
// Implements RFC 7541

const std = @import("std");

pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,
};

// Static table (RFC 7541 Appendix B)
const STATIC_TABLE = [_]HeaderField{
    .{ .name = "", .value = "" }, // Index 0 (unused)
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

pub const HpackDecoder = struct {
    dynamic_table: std.ArrayList(HeaderField),
    max_table_size: u32 = 4096,
    allocator: std.mem.Allocator,
    
    pub fn init(allocator: std.mem.Allocator) HpackDecoder {
        return HpackDecoder{
            .dynamic_table = std.ArrayList(HeaderField).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *HpackDecoder) void {
        self.dynamic_table.deinit();
    }
    
    // Decode header block
    pub fn decode(self: *HpackDecoder, data: []const u8) ![]HeaderField {
        var headers = std.ArrayList(HeaderField).init(self.allocator);
        errdefer headers.deinit();
        
        var offset: usize = 0;
        while (offset < data.len) {
            const header = try self.decodeHeaderField(data[offset..]);
            try headers.append(header.field);
            offset += header.bytes_consumed;
        }
        
        return headers.toOwnedSlice();
    }
    
    const DecodeResult = struct {
        field: HeaderField,
        bytes_consumed: usize,
    };
    
    fn decodeHeaderField(self: *HpackDecoder, data: []const u8) !DecodeResult {
        if (data.len == 0) {
            return error.IncompleteHeader;
        }
        
        const first_byte = data[0];
        
        // Indexed header field (starts with 1)
        if (first_byte & 0x80 != 0) {
            const index_result = try self.decodeInteger(data, 7);
            const field = try self.getHeaderField(index_result.value);
            return DecodeResult{
                .field = field,
                .bytes_consumed = index_result.bytes_consumed,
            };
        }
        
        // Literal header field (incremental indexing)
        if (first_byte & 0x40 != 0) {
            return self.decodeLiteralHeader(data, 6, true);
        }
        
        // Dynamic table size update
        if (first_byte & 0x20 != 0) {
            const size = try self.decodeInteger(data, 5);
            self.max_table_size = size.value;
            // TODO: Evict entries if needed
            return DecodeResult{
                .field = HeaderField{ .name = "", .value = "" },
                .bytes_consumed = size.bytes_consumed,
            };
        }
        
        // Literal header field (no indexing)
        if (first_byte & 0x10 != 0) {
            return self.decodeLiteralHeader(data, 4, false);
        }
        
        // Literal header field (never indexed)
        if (first_byte & 0x0F == 0) {
            return self.decodeLiteralHeader(data, 4, false);
        }
        
        return error.InvalidHeaderEncoding;
    }
    
    fn decodeLiteralHeader(self: *HpackDecoder, data: []const u8, prefix_bits: u3, add_to_table: bool) !DecodeResult {
        var offset: usize = 0;
        
        // Decode name index or literal
        var name: []const u8 = undefined;
        if (data[0] & ((@as(u8, 1) << prefix_bits) - 1) != 0) {
            // Name is indexed
            const name_index = try self.decodeInteger(data, prefix_bits);
            const name_field = try self.getHeaderField(name_index.value);
            name = name_field.name;
            offset = name_index.bytes_consumed;
        } else {
            // Name is literal
            offset = 1;
            const name_len = try self.decodeInteger(data[offset..], 7);
            offset += name_len.bytes_consumed;
            if (offset + name_len.value > data.len) {
                return error.IncompleteHeader;
            }
            name = data[offset..][0..name_len.value];
            offset += name_len.value;
        }
        
        // Decode value
        const value_len = try self.decodeInteger(data[offset..], 7);
        offset += value_len.bytes_consumed;
        if (offset + value_len.value > data.len) {
            return error.IncompleteHeader;
        }
        const value = data[offset..][0..value_len.value];
        offset += value_len.value;
        
        const field = HeaderField{ .name = name, .value = value };
        
        // Add to dynamic table if needed
        if (add_to_table) {
            try self.addToDynamicTable(field);
        }
        
        return DecodeResult{
            .field = field,
            .bytes_consumed = offset,
        };
    }
    
    const IntegerResult = struct {
        value: u32,
        bytes_consumed: usize,
    };
    
    fn decodeInteger(self: *HpackDecoder, data: []const u8, prefix_bits: u3) !IntegerResult {
        _ = self; // Unused but needed for method signature
        if (data.len == 0) {
            return error.IncompleteInteger;
        }
        
        const mask = (@as(u8, 1) << prefix_bits) - 1;
        var value: u32 = @intCast(data[0] & mask);
        var offset: usize = 1;
        
        if (value < mask) {
            return IntegerResult{ .value = value, .bytes_consumed = offset };
        }
        
        // Multi-byte integer
        var shift: u5 = 0;
        while (offset < data.len) {
            if (offset >= 5) {
                return error.IntegerTooLarge;
            }
            const byte = data[offset];
            const byte_val = @as(u32, @intCast(byte & 0x7F));
            value += byte_val << @as(u5, @intCast(shift));
            offset += 1;
            if (byte & 0x80 == 0) {
                break;
            }
            shift += 7;
        }
        
        return IntegerResult{ .value = value, .bytes_consumed = offset };
    }
    
    fn getHeaderField(self: *HpackDecoder, index: u32) !HeaderField {
        if (index == 0) {
            return error.InvalidIndex;
        }
        
        if (index <= STATIC_TABLE.len - 1) {
            return STATIC_TABLE[@intCast(index)];
        }
        
        const dynamic_index = index - @as(u32, @intCast(STATIC_TABLE.len));
        if (dynamic_index >= self.dynamic_table.items.len) {
            return error.InvalidIndex;
        }
        
        const reverse_index = self.dynamic_table.items.len - 1 - dynamic_index;
        return self.dynamic_table.items[reverse_index];
    }
    
    fn addToDynamicTable(self: *HpackDecoder, field: HeaderField) !void {
        const entry_size = field.name.len + field.value.len + 32;
        if (entry_size > self.max_table_size) {
            return; // Entry too large
        }
        
        // Evict entries if needed
        while (self.getTableSize() + entry_size > self.max_table_size) {
            if (self.dynamic_table.items.len == 0) break;
            _ = self.dynamic_table.pop();
        }
        
        try self.dynamic_table.append(field);
    }
    
    fn getTableSize(self: *HpackDecoder) usize {
        var size: usize = 0;
        for (self.dynamic_table.items) |field| {
            size += field.name.len + field.value.len + 32;
        }
        return size;
    }
};

