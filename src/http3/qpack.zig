// QPACK: Header Compression for HTTP/3 (RFC 9204)
// This is MANDATORY for HTTP/3 - HPACK is explicitly forbidden
//
// Key differences from HPACK:
// - Uses separate unidirectional streams for encoder/decoder instructions
// - Explicit acknowledgments prevent head-of-line blocking
// - Dynamic table updates are decoupled from header blocks
// - References to not-yet-acknowledged entries are forbidden

const std = @import("std");

// QPACK Static Table (RFC 9204 Appendix A)
// 99 entries - different from HPACK's 61 entries
pub const StaticTable = struct {
    pub const Entry = struct {
        name: []const u8,
        value: []const u8,
    };

    // RFC 9204 Appendix A - Static Table
    pub const entries = [_]Entry{
        .{ .name = ":authority", .value = "" }, // 0
        .{ .name = ":path", .value = "/" }, // 1
        .{ .name = "age", .value = "0" }, // 2
        .{ .name = "content-disposition", .value = "" }, // 3
        .{ .name = "content-length", .value = "0" }, // 4
        .{ .name = "cookie", .value = "" }, // 5
        .{ .name = "date", .value = "" }, // 6
        .{ .name = "etag", .value = "" }, // 7
        .{ .name = "if-modified-since", .value = "" }, // 8
        .{ .name = "if-none-match", .value = "" }, // 9
        .{ .name = "last-modified", .value = "" }, // 10
        .{ .name = "link", .value = "" }, // 11
        .{ .name = "location", .value = "" }, // 12
        .{ .name = "referer", .value = "" }, // 13
        .{ .name = "set-cookie", .value = "" }, // 14
        .{ .name = ":method", .value = "CONNECT" }, // 15
        .{ .name = ":method", .value = "DELETE" }, // 16
        .{ .name = ":method", .value = "GET" }, // 17
        .{ .name = ":method", .value = "HEAD" }, // 18
        .{ .name = ":method", .value = "OPTIONS" }, // 19
        .{ .name = ":method", .value = "POST" }, // 20
        .{ .name = ":method", .value = "PUT" }, // 21
        .{ .name = ":scheme", .value = "http" }, // 22
        .{ .name = ":scheme", .value = "https" }, // 23
        .{ .name = ":status", .value = "103" }, // 24
        .{ .name = ":status", .value = "200" }, // 25
        .{ .name = ":status", .value = "304" }, // 26
        .{ .name = ":status", .value = "404" }, // 27
        .{ .name = ":status", .value = "503" }, // 28
        .{ .name = "accept", .value = "*/*" }, // 29
        .{ .name = "accept", .value = "application/dns-message" }, // 30
        .{ .name = "accept-encoding", .value = "gzip, deflate, br" }, // 31
        .{ .name = "accept-ranges", .value = "bytes" }, // 32
        .{ .name = "access-control-allow-headers", .value = "cache-control" }, // 33
        .{ .name = "access-control-allow-headers", .value = "content-type" }, // 34
        .{ .name = "access-control-allow-origin", .value = "*" }, // 35
        .{ .name = "cache-control", .value = "max-age=0" }, // 36
        .{ .name = "cache-control", .value = "max-age=2592000" }, // 37
        .{ .name = "cache-control", .value = "max-age=604800" }, // 38
        .{ .name = "cache-control", .value = "no-cache" }, // 39
        .{ .name = "cache-control", .value = "no-store" }, // 40
        .{ .name = "cache-control", .value = "public, max-age=31536000" }, // 41
        .{ .name = "content-encoding", .value = "br" }, // 42
        .{ .name = "content-encoding", .value = "gzip" }, // 43
        .{ .name = "content-type", .value = "application/dns-message" }, // 44
        .{ .name = "content-type", .value = "application/javascript" }, // 45
        .{ .name = "content-type", .value = "application/json" }, // 46
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" }, // 47
        .{ .name = "content-type", .value = "image/gif" }, // 48
        .{ .name = "content-type", .value = "image/jpeg" }, // 49
        .{ .name = "content-type", .value = "image/png" }, // 50
        .{ .name = "content-type", .value = "text/css" }, // 51
        .{ .name = "content-type", .value = "text/html; charset=utf-8" }, // 52
        .{ .name = "content-type", .value = "text/plain" }, // 53
        .{ .name = "content-type", .value = "text/plain;charset=utf-8" }, // 54
        .{ .name = "range", .value = "bytes=0-" }, // 55
        .{ .name = "strict-transport-security", .value = "max-age=31536000" }, // 56
        .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains" }, // 57
        .{ .name = "strict-transport-security", .value = "max-age=31536000; includesubdomains; preload" }, // 58
        .{ .name = "vary", .value = "accept-encoding" }, // 59
        .{ .name = "vary", .value = "origin" }, // 60
        .{ .name = "x-content-type-options", .value = "nosniff" }, // 61
        .{ .name = "x-xss-protection", .value = "1; mode=block" }, // 62
        .{ .name = ":status", .value = "100" }, // 63
        .{ .name = ":status", .value = "204" }, // 64
        .{ .name = ":status", .value = "206" }, // 65
        .{ .name = ":status", .value = "302" }, // 66
        .{ .name = ":status", .value = "400" }, // 67
        .{ .name = ":status", .value = "403" }, // 68
        .{ .name = ":status", .value = "421" }, // 69
        .{ .name = ":status", .value = "425" }, // 70
        .{ .name = ":status", .value = "500" }, // 71
        .{ .name = "accept-language", .value = "" }, // 72
        .{ .name = "access-control-allow-credentials", .value = "FALSE" }, // 73
        .{ .name = "access-control-allow-credentials", .value = "TRUE" }, // 74
        .{ .name = "access-control-allow-headers", .value = "*" }, // 75
        .{ .name = "access-control-allow-methods", .value = "get" }, // 76
        .{ .name = "access-control-allow-methods", .value = "get, post, options" }, // 77
        .{ .name = "access-control-allow-methods", .value = "options" }, // 78
        .{ .name = "access-control-expose-headers", .value = "content-length" }, // 79
        .{ .name = "access-control-request-headers", .value = "content-type" }, // 80
        .{ .name = "access-control-request-method", .value = "get" }, // 81
        .{ .name = "access-control-request-method", .value = "post" }, // 82
        .{ .name = "alt-svc", .value = "clear" }, // 83
        .{ .name = "authorization", .value = "" }, // 84
        .{ .name = "content-security-policy", .value = "script-src 'none'; object-src 'none'; base-uri 'none'" }, // 85
        .{ .name = "early-data", .value = "1" }, // 86
        .{ .name = "expect-ct", .value = "" }, // 87
        .{ .name = "forwarded", .value = "" }, // 88
        .{ .name = "if-range", .value = "" }, // 89
        .{ .name = "origin", .value = "" }, // 90
        .{ .name = "purpose", .value = "prefetch" }, // 91
        .{ .name = "server", .value = "" }, // 92
        .{ .name = "timing-allow-origin", .value = "*" }, // 93
        .{ .name = "upgrade-insecure-requests", .value = "1" }, // 94
        .{ .name = "user-agent", .value = "" }, // 95
        .{ .name = "x-forwarded-for", .value = "" }, // 96
        .{ .name = "x-frame-options", .value = "deny" }, // 97
        .{ .name = "x-frame-options", .value = "sameorigin" }, // 98
    };

    pub fn lookup(index: usize) ?Entry {
        if (index >= entries.len) return null;
        return entries[index];
    }

    pub fn findName(name: []const u8) ?usize {
        for (entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name)) {
                return i;
            }
        }
        return null;
    }

    pub fn findExact(name: []const u8, value: []const u8) ?usize {
        for (entries, 0..) |entry, i| {
            if (std.mem.eql(u8, entry.name, name) and std.mem.eql(u8, entry.value, value)) {
                return i;
            }
        }
        return null;
    }
};

// Header field representation
pub const HeaderField = struct {
    name: []const u8,
    value: []const u8,
    // For dynamic table: do we own this memory?
    owned: bool = false,
};

// QPACK Prefix Integer encoding (RFC 9204 Section 4.1.1)
// Similar to HPACK but with different prefix lengths
pub fn readPrefixInt(data: []const u8, prefix_bits: u3) !struct { value: u64, bytes_read: usize } {
    if (data.len == 0) return error.IncompleteData;

    const prefix_mask: u8 = (@as(u8, 1) << prefix_bits) - 1;
    var value: u64 = data[0] & prefix_mask;
    var offset: usize = 1;

    if (value < prefix_mask) {
        return .{ .value = value, .bytes_read = offset };
    }

    // Multi-byte encoding
    var shift: u6 = 0;
    while (offset < data.len) {
        const byte = data[offset];
        offset += 1;
        value += @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) {
            return .{ .value = value, .bytes_read = offset };
        }
        shift += 7;
        if (shift > 56) return error.IntegerOverflow;
    }

    return error.IncompleteData;
}

// Write prefix integer
pub fn writePrefixInt(writer: anytype, value: u64, prefix_bits: u3, prefix_byte: u8) !usize {
    const prefix_mask: u8 = (@as(u8, 1) << prefix_bits) - 1;
    var bytes_written: usize = 0;

    if (value < prefix_mask) {
        try writer.writeByte(prefix_byte | @as(u8, @intCast(value)));
        return 1;
    }

    try writer.writeByte(prefix_byte | prefix_mask);
    bytes_written = 1;

    var remaining = value - prefix_mask;
    while (remaining >= 128) {
        try writer.writeByte(@as(u8, @intCast(remaining & 0x7F)) | 0x80);
        bytes_written += 1;
        remaining >>= 7;
    }
    try writer.writeByte(@as(u8, @intCast(remaining)));
    bytes_written += 1;

    return bytes_written;
}

// Read Huffman-encoded string (simplified - no actual Huffman for now)
pub fn readString(data: []const u8, prefix_bits: u3) !struct { value: []const u8, bytes_read: usize } {
    if (data.len == 0) return error.IncompleteData;

    const huffman = (data[0] & 0x80) != 0;
    const len_result = try readPrefixInt(data, prefix_bits);

    const string_start = len_result.bytes_read;
    const string_len = len_result.value;

    if (data.len < string_start + string_len) {
        return error.IncompleteData;
    }

    // TODO: Implement Huffman decoding if huffman flag is set
    _ = huffman;

    return .{
        .value = data[string_start..][0..@intCast(string_len)],
        .bytes_read = string_start + @as(usize, @intCast(string_len)),
    };
}

// Write string (literal, no Huffman for now)
pub fn writeString(writer: anytype, value: []const u8, prefix_bits: u3) !usize {
    // No Huffman encoding (bit 7 = 0)
    const bytes_written = try writePrefixInt(writer, value.len, prefix_bits, 0x00);
    try writer.writeAll(value);
    return bytes_written + value.len;
}

// QPACK Encoder - encodes headers for HTTP/3 responses
pub const QpackEncoder = struct {
    allocator: std.mem.Allocator,
    // Dynamic table (entries we've added)
    dynamic_table: std.ArrayListUnmanaged(HeaderField),
    max_table_capacity: usize,
    current_table_size: usize,
    // For tracking acknowledged entries (prevents HOL blocking)
    insert_count: u64,
    // Encoder stream buffer (separate from header blocks)
    encoder_stream_buffer: std.ArrayListUnmanaged(u8),

    pub fn init(allocator: std.mem.Allocator) QpackEncoder {
        return QpackEncoder{
            .allocator = allocator,
            .dynamic_table = .{},
            .max_table_capacity = 4096, // Default from RFC
            .current_table_size = 0,
            .insert_count = 0,
            .encoder_stream_buffer = .{},
        };
    }

    pub fn deinit(self: *QpackEncoder) void {
        // Free owned entries
        for (self.dynamic_table.items) |field| {
            if (field.owned) {
                self.allocator.free(field.name);
                self.allocator.free(field.value);
            }
        }
        self.dynamic_table.deinit(self.allocator);
        self.encoder_stream_buffer.deinit(self.allocator);
    }

    // Encode a header block for HTTP/3
    // Returns encoded bytes (caller owns)
    pub fn encode(self: *QpackEncoder, headers: []const HeaderField) ![]u8 {
        var buffer = std.ArrayList(u8).initCapacity(self.allocator, 256) catch return error.OutOfMemory;
        errdefer buffer.deinit(self.allocator);

        // QPACK header block prefix (RFC 9204 Section 4.5.1)
        // Required Insert Count (QPACK uses 0 for static-only encoding)
        try buffer.append(0x00); // Required Insert Count = 0
        try buffer.append(0x00); // Delta Base = 0 (Sign bit = 0)

        for (headers) |field| {
            try self.encodeField(&buffer, field);
        }

        return buffer.toOwnedSlice(self.allocator);
    }

    fn encodeField(self: *QpackEncoder, buffer: *std.ArrayList(u8), field: HeaderField) !void {
        // Try static table first (most efficient)
        if (StaticTable.findExact(field.name, field.value)) |index| {
            // Indexed Field Line - Static (RFC 9204 Section 4.5.2)
            // Format: 1 T=1 index (6-bit prefix)
            // 0b11xxxxxx - static table indexed
            const prefix: u8 = 0xC0; // 11xxxxxx
            var temp_buf: [16]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&temp_buf);
            const writer = fbs.writer();
            _ = try writePrefixInt(writer, index, 6, prefix);
            try buffer.appendSlice(self.allocator, fbs.getWritten());
            return;
        }

        // Try name-only match in static table
        if (StaticTable.findName(field.name)) |name_index| {
            // Literal Field Line With Name Reference - Static (RFC 9204 Section 4.5.4)
            // Format: 01 N T=1 index (4-bit prefix) + value
            const prefix: u8 = 0x50; // 0101xxxx (N=0, T=1)
            var temp_buf: [256]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&temp_buf);
            const writer = fbs.writer();
            _ = try writePrefixInt(writer, name_index, 4, prefix);
            _ = try writeString(writer, field.value, 7);
            try buffer.appendSlice(self.allocator, fbs.getWritten());
            return;
        }

        // Literal Field Line With Literal Name (RFC 9204 Section 4.5.6)
        // Format: 001 N=0 name + value
        try buffer.append(0x20); // 001x xxxx (N=0, no Huffman)
        var temp_buf: [512]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&temp_buf);
        const writer = fbs.writer();
        _ = try writeString(writer, field.name, 3);
        _ = try writeString(writer, field.value, 7);
        try buffer.appendSlice(self.allocator, fbs.getWritten());
    }
};

// QPACK Decoder - decodes headers from HTTP/3 requests
pub const QpackDecoder = struct {
    allocator: std.mem.Allocator,
    // Dynamic table (entries added by encoder instructions)
    dynamic_table: std.ArrayListUnmanaged(HeaderField),
    max_table_capacity: usize,
    current_table_size: usize,
    // Known Received Count (for acknowledgment)
    known_received_count: u64,

    pub fn init(allocator: std.mem.Allocator) QpackDecoder {
        return QpackDecoder{
            .allocator = allocator,
            .dynamic_table = .{},
            .max_table_capacity = 4096,
            .current_table_size = 0,
            .known_received_count = 0,
        };
    }

    pub fn deinit(self: *QpackDecoder) void {
        // Free owned entries
        for (self.dynamic_table.items) |field| {
            if (field.owned) {
                self.allocator.free(field.name);
                self.allocator.free(field.value);
            }
        }
        self.dynamic_table.deinit(self.allocator);
    }

    // Decode a header block
    pub fn decode(self: *QpackDecoder, data: []const u8) ![]HeaderField {
        if (data.len < 2) return error.IncompleteData;

        var offset: usize = 0;

        // Read Required Insert Count (RFC 9204 Section 4.5.1)
        // Uses full byte encoding, not prefix integer
        // For static-only encoding, this is always 0
        const required_insert_count = data[offset];
        offset += 1;
        _ = required_insert_count; // For now, we only support static table

        // Read Delta Base (7-bit prefix)
        if (offset >= data.len) return error.IncompleteData;
        const base_result = try readPrefixInt(data[offset..], 7);
        offset += base_result.bytes_read;

        var headers = std.ArrayList(HeaderField).initCapacity(self.allocator, 16) catch return error.OutOfMemory;
        errdefer headers.deinit(self.allocator);

        // Decode field lines
        while (offset < data.len) {
            const field = try self.decodeFieldLine(data[offset..]);
            try headers.append(field.field);
            offset += field.bytes_read;
        }

        return headers.toOwnedSlice(self.allocator);
    }

    const FieldResult = struct {
        field: HeaderField,
        bytes_read: usize,
    };

    fn decodeFieldLine(self: *QpackDecoder, data: []const u8) !FieldResult {
        if (data.len == 0) return error.IncompleteData;

        const first_byte = data[0];

        // Indexed Field Line (RFC 9204 Section 4.5.2)
        if ((first_byte & 0x80) != 0) {
            // 1xxxxxxx - Indexed
            const is_static = (first_byte & 0x40) != 0;

            if (is_static) {
                // Static table reference
                const index_result = try readPrefixInt(data, 6);
                const entry = StaticTable.lookup(@intCast(index_result.value)) orelse
                    return error.InvalidIndex;
                return FieldResult{
                    .field = .{ .name = entry.name, .value = entry.value },
                    .bytes_read = index_result.bytes_read,
                };
            } else {
                // Dynamic table reference
                const index_result = try readPrefixInt(data, 6);
                const dyn_index = @as(usize, @intCast(index_result.value));
                if (dyn_index >= self.dynamic_table.items.len) {
                    return error.InvalidIndex;
                }
                const entry = self.dynamic_table.items[dyn_index];
                return FieldResult{
                    .field = .{ .name = entry.name, .value = entry.value },
                    .bytes_read = index_result.bytes_read,
                };
            }
        }

        // Literal Field Line With Name Reference (RFC 9204 Section 4.5.4)
        if ((first_byte & 0xC0) == 0x40) {
            // 01xxxxxx
            const is_static = (first_byte & 0x10) != 0;
            var offset: usize = 0;

            if (is_static) {
                const index_result = try readPrefixInt(data, 4);
                offset = index_result.bytes_read;
                const entry = StaticTable.lookup(@intCast(index_result.value)) orelse
                    return error.InvalidIndex;

                const value_result = try readString(data[offset..], 7);
                offset += value_result.bytes_read;

                // Duplicate name from static table, value from data
                const name_copy = try self.allocator.dupe(u8, entry.name);
                errdefer self.allocator.free(name_copy);
                const value_copy = try self.allocator.dupe(u8, value_result.value);

                return FieldResult{
                    .field = .{ .name = name_copy, .value = value_copy, .owned = true },
                    .bytes_read = offset,
                };
            } else {
                // Dynamic name reference - not yet supported
                return error.DynamicTableNotSupported;
            }
        }

        // Literal Field Line With Literal Name (RFC 9204 Section 4.5.6)
        if ((first_byte & 0xE0) == 0x20) {
            // 001xxxxx
            var offset: usize = 0;

            const name_result = try readString(data, 3);
            offset = name_result.bytes_read;

            const value_result = try readString(data[offset..], 7);
            offset += value_result.bytes_read;

            const name_copy = try self.allocator.dupe(u8, name_result.value);
            errdefer self.allocator.free(name_copy);
            const value_copy = try self.allocator.dupe(u8, value_result.value);

            return FieldResult{
                .field = .{ .name = name_copy, .value = value_copy, .owned = true },
                .bytes_read = offset,
            };
        }

        // Indexed Field Line With Post-Base Index (RFC 9204 Section 4.5.3)
        if ((first_byte & 0xF0) == 0x10) {
            // 0001xxxx - Post-base indexed
            return error.DynamicTableNotSupported;
        }

        return error.InvalidFieldLine;
    }
};

// Tests
test "static table lookup" {
    // :status 200 is at index 25
    const entry = StaticTable.lookup(25);
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings(":status", entry.?.name);
    try std.testing.expectEqualStrings("200", entry.?.value);
}

test "static table find exact" {
    const index = StaticTable.findExact(":method", "GET");
    try std.testing.expect(index != null);
    try std.testing.expectEqual(@as(usize, 17), index.?);
}

test "encode simple response" {
    var encoder = QpackEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const headers = [_]HeaderField{
        .{ .name = ":status", .value = "200" },
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "server", .value = "blitz" },
    };

    const encoded = try encoder.encode(&headers);
    defer std.testing.allocator.free(encoded);

    // Should have QPACK prefix (2 bytes) + encoded headers
    try std.testing.expect(encoded.len > 2);

    // First two bytes are Required Insert Count and Delta Base
    try std.testing.expectEqual(@as(u8, 0x00), encoded[0]);
    try std.testing.expectEqual(@as(u8, 0x00), encoded[1]);
}

test "decode simple request" {
    var decoder = QpackDecoder.init(std.testing.allocator);
    defer decoder.deinit();

    // Manually construct a simple QPACK header block:
    // - Required Insert Count: 0
    // - Delta Base: 0
    // - Indexed :method GET (static index 17)
    var encoded = [_]u8{
        0x00, // Required Insert Count = 0
        0x00, // Delta Base = 0
        0xC0 | 17, // Indexed static, index 17 (:method GET)
    };

    const headers = try decoder.decode(&encoded);
    defer std.testing.allocator.free(headers);

    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings(":method", headers[0].name);
    try std.testing.expectEqualStrings("GET", headers[0].value);
}

test "prefix integer encoding" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const writer = fbs.writer();

    // Small value (fits in prefix)
    _ = try writePrefixInt(writer, 10, 5, 0x00);
    try std.testing.expectEqual(@as(u8, 10), fbs.getWritten()[0]);

    // Reset
    fbs.reset();

    // Value requiring multi-byte
    _ = try writePrefixInt(writer, 1337, 5, 0x00);
    const written = fbs.getWritten();
    try std.testing.expect(written.len > 1);
}
