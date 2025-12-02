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
            // Zig 0.15.2: Use initCapacity for ArrayList
            .dynamic_table = std.ArrayList(HeaderField).initCapacity(allocator, 64) catch @panic("Failed to init HPACK dynamic table"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackDecoder) void {
        // Free all owned header field strings in the dynamic table
        for (self.dynamic_table.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        // Zig 0.15.2: deinit requires allocator
        self.dynamic_table.deinit(self.allocator);
    }

    // Decode header block
    pub fn decode(self: *HpackDecoder, data: []const u8) ![]HeaderField {
        // Zig 0.15.2: Use initCapacity
        var headers = std.ArrayList(HeaderField).initCapacity(self.allocator, 16) catch return error.OutOfMemory;
        errdefer headers.deinit(self.allocator);

        var offset: usize = 0;
        while (offset < data.len) {
            const header = try self.decodeHeaderField(data[offset..]);
            // Zig 0.15.2: append requires allocator
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
        // Pattern: 0000xxxx where xxxx is the name index
        // At this point, we know bits 7-4 are all 0 (otherwise we would have matched above)
        // So any byte with upper 4 bits = 0 is "never indexed"
        if ((first_byte & 0xF0) == 0) {
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
        // Value length byte: bit 7 = Huffman flag, bits 6-0 = length
        const value_len_byte = data[offset];
        const is_huffman = (value_len_byte & 0x80) != 0;
        const value_len_result = try self.decodeInteger(data[offset..], 7);
        offset += value_len_result.bytes_consumed;
        if (offset + value_len_result.value > data.len) {
            return error.IncompleteHeader;
        }

        var value: []const u8 = undefined;
        if (is_huffman) {
            // Decode Huffman-encoded value (RFC 7541 Appendix B)
            const huffman_data = data[offset..][0..value_len_result.value];
            const decoded_value = try self.decodeHuffman(huffman_data);
            value = decoded_value;
            offset += value_len_result.value;
        } else {
            value = data[offset..][0..value_len_result.value];
            offset += value_len_result.value;
        }

        const field = HeaderField{ .name = name, .value = value };

        // Add to dynamic table if needed
        // Note: addToDynamicTable creates owned copies, so the original field.value
        // (if Huffman-decoded) is still owned by the caller and returned in DecodeResult
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
            const old_field = self.dynamic_table.pop();
            // Free the old field's memory
            self.allocator.free(old_field.name);
            self.allocator.free(old_field.value);
        }

        // Create owned copies to ensure consistent memory ownership
        // This handles both Huffman-decoded values and borrowed slices from static table
        const name_copy = try self.allocator.dupe(u8, field.name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, field.value);
        errdefer self.allocator.free(value_copy);

        try self.dynamic_table.append(.{
            .name = name_copy,
            .value = value_copy,
        });
    }

    fn getTableSize(self: *HpackDecoder) usize {
        var size: usize = 0;
        for (self.dynamic_table.items) |field| {
            size += field.name.len + field.value.len + 32;
        }
        return size;
    }

    // Decode Huffman-encoded string (RFC 7541 Appendix B)
    // Simplified implementation - for now, returns raw bytes if decoding fails
    // Full implementation would require the complete Huffman table from RFC 7541
    fn decodeHuffman(self: *HpackDecoder, data: []const u8) ![]const u8 {
        // For now, return a copy of the raw bytes
        // TODO: Implement full Huffman decoding with RFC 7541 Appendix B table
        // This is a placeholder that prevents crashes but doesn't decode correctly
        const decoded = try self.allocator.dupe(u8, data);
        return decoded;
    }
};

// HPACK Encoder for response headers
pub const HpackEncoder = struct {
    dynamic_table: std.ArrayList(HeaderField),
    max_table_size: u32 = 4096,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) HpackEncoder {
        return HpackEncoder{
            // Zig 0.15.2: Use initCapacity
            .dynamic_table = std.ArrayList(HeaderField).initCapacity(allocator, 64) catch @panic("Failed to init HPACK encoder table"),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *HpackEncoder) void {
        // Free all owned header field strings in the dynamic table
        for (self.dynamic_table.items) |field| {
            self.allocator.free(field.name);
            self.allocator.free(field.value);
        }
        // Zig 0.15.2: deinit requires allocator
        self.dynamic_table.deinit(self.allocator);
    }

    // Encode a single header field
    pub fn encodeField(self: *HpackEncoder, field: HeaderField, buf: []u8) !usize {
        // Fast path: :status: 200 is static table index 8 (most common response)
        if (std.mem.eql(u8, field.name, ":status") and std.mem.eql(u8, field.value, "200")) {
            return self.encodeIndexed(8, buf);
        }

        // Try to find in static table first
        if (self.findInStaticTable(field)) |index| {
            return self.encodeIndexed(index, buf);
        }

        // Try to find in dynamic table
        if (self.findInDynamicTable(field)) |index| {
            const static_count = STATIC_TABLE.len;
            return self.encodeIndexed(@intCast(static_count + index), buf);
        }

        // Encode as literal with incremental indexing
        return self.encodeLiteral(field, buf, true);
    }

    // Encode multiple header fields
    pub fn encode(self: *HpackEncoder, headers: []const HeaderField, buf: []u8) !usize {
        var offset: usize = 0;
        for (headers) |field| {
            const encoded_len = try self.encodeField(field, buf[offset..]);
            offset += encoded_len;
        }
        return offset;
    }

    fn findInStaticTable(_: *HpackEncoder, field: HeaderField) ?u32 {
        for (STATIC_TABLE, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, field.name) and std.mem.eql(u8, entry.value, field.value)) {
                return @intCast(i);
            }
        }
        return null;
    }

    fn findInDynamicTable(self: *HpackEncoder, field: HeaderField) ?usize {
        for (self.dynamic_table.items, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, field.name) and std.mem.eql(u8, entry.value, field.value)) {
                return self.dynamic_table.items.len - 1 - i;
            }
        }
        return null;
    }

    fn encodeIndexed(_: *HpackEncoder, index: u32, buf: []u8) !usize {
        if (buf.len < 1) return error.BufferTooSmall;

        if (index < 127) {
            buf[0] = 0x80 | @as(u8, @intCast(index));
            return 1;
        }

        // Multi-byte index encoding
        buf[0] = 0x80 | 0x7F;
        var offset: usize = 1;
        var remaining = index - 127;

        while (remaining > 0) {
            if (offset >= buf.len) return error.BufferTooSmall;
            const byte = @as(u8, @intCast(remaining & 0x7F));
            remaining >>= 7;
            buf[offset] = if (remaining > 0) 0x80 | byte else byte;
            offset += 1;
        }

        return offset;
    }

    fn encodeLiteral(self: *HpackEncoder, field: HeaderField, buf: []u8, add_to_table: bool) !usize {
        var offset: usize = 0;

        // Try to find name in static table
        var name_index: ?u32 = null;
        for (STATIC_TABLE, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, field.name)) {
                name_index = @intCast(i);
                break;
            }
        }

        if (name_index) |idx| {
            // Name indexed - encode index into the prefix byte
            // For literal with incremental indexing: prefix is 0x40 (bit 6), index in bits 5-0 (6 bits)
            // For literal without indexing: prefix is 0x00, index in bits 3-0 (4 bits)
            const prefix_bits: u3 = if (add_to_table) 6 else 4;
            const prefix_mask: u8 = if (add_to_table) 0x40 else 0x00;
            const mask = (@as(u32, 1) << prefix_bits) - 1;
            const idx_val: u32 = @intCast(idx);

            if (idx_val < mask) {
                // Index fits in prefix bits - combine prefix with index
                buf[offset] = prefix_mask | @as(u8, @intCast(idx_val));
                offset += 1;
            } else {
                // Multi-byte encoding - set prefix with max value (all 1s in prefix bits), then encode remainder
                buf[offset] = prefix_mask | @as(u8, @intCast(mask));
                offset += 1;
                var remaining = idx_val - mask;
                while (remaining > 0) {
                    if (offset >= buf.len) return error.BufferTooSmall;
                    const byte = @as(u8, @intCast(remaining & 0x7F));
                    remaining >>= 7;
                    buf[offset] = if (remaining > 0) 0x80 | byte else byte;
                    offset += 1;
                }
            }
        } else {
            // Name literal
            if (add_to_table) {
                buf[offset] = 0x40; // Literal with incremental indexing
            } else {
                buf[offset] = 0x00; // Literal without indexing
            }
            offset += 1;
            offset += try self.encodeInteger(buf[offset..], @intCast(field.name.len), 7);
            if (offset + field.name.len > buf.len) return error.BufferTooSmall;
            @memcpy(buf[offset..][0..field.name.len], field.name);
            offset += field.name.len;
        }

        // Encode value
        offset += try self.encodeInteger(buf[offset..], @intCast(field.value.len), 7);
        if (offset + field.value.len > buf.len) return error.BufferTooSmall;
        @memcpy(buf[offset..][0..field.value.len], field.value);
        offset += field.value.len;

        // Add to dynamic table if needed
        if (add_to_table) {
            try self.addToDynamicTable(field);
        }

        return offset;
    }

    fn encodeInteger(_: *HpackEncoder, buf: []u8, value: u32, prefix_bits: u3) !usize {
        if (buf.len == 0) return error.BufferTooSmall;

        const mask = (@as(u32, 1) << prefix_bits) - 1;
        if (value < mask) {
            buf[0] = @as(u8, @intCast(value));
            return 1;
        }

        // Multi-byte encoding
        buf[0] = @as(u8, @intCast(mask));
        var offset: usize = 1;
        var remaining = value - mask;

        while (remaining > 0) {
            if (offset >= buf.len) return error.BufferTooSmall;
            const byte = @as(u8, @intCast(remaining & 0x7F));
            remaining >>= 7;
            buf[offset] = if (remaining > 0) 0x80 | byte else byte;
            offset += 1;
        }

        return offset;
    }

    fn addToDynamicTable(self: *HpackEncoder, field: HeaderField) !void {
        const entry_size = field.name.len + field.value.len + 32;
        if (entry_size > self.max_table_size) {
            return; // Entry too large
        }

        // Evict entries if needed
        while (self.getTableSize() + entry_size > self.max_table_size) {
            if (self.dynamic_table.items.len == 0) break;
            const old_field = self.dynamic_table.pop();
            // Free the old field's memory
            self.allocator.free(old_field.name);
            self.allocator.free(old_field.value);
        }

        // Create owned copies to prevent dangling pointers
        // The original field contains borrowed slices that may be freed by the caller
        const name_copy = try self.allocator.dupe(u8, field.name);
        errdefer self.allocator.free(name_copy);
        const value_copy = try self.allocator.dupe(u8, field.value);
        errdefer self.allocator.free(value_copy);

        try self.dynamic_table.append(.{
            .name = name_copy,
            .value = value_copy,
        });
    }

    fn getTableSize(self: *HpackEncoder) usize {
        var size: usize = 0;
        for (self.dynamic_table.items) |field| {
            size += field.name.len + field.value.len + 32;
        }
        return size;
    }
};
