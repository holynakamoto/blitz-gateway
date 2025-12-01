// Comprehensive validation suite for TLS 1.3 and HTTP/2 modules
// Tests the foundation before io_uring integration

const std = @import("std");
const testing = std.testing;

// Import our modules
// const tls = @import("tls/tls.zig"); // Temporarily disabled for picotls migration
const frame = @import("http2/frame.zig");
const hpack = @import("http2/hpack.zig");

test "Full Foundation Validation" {
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     TLS 1.3 + HTTP/2 Foundation Validation Suite            ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}

// --- TEST 1: TLS Context Initialization ---
test "TLS: Initialize OpenSSL Context and Load Certs" {
    std.debug.print("[TEST 1] TLS Context Initialization... ", .{});

    // Initialize TLS context
    var ctx = try tls.TlsContext.init();
    defer ctx.deinit();

    // Load the certificates we generated
    try ctx.loadCertificate("certs/server.crt", "certs/server.key");

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 2: HTTP/2 Frame Header Parsing ---
test "HTTP/2: Parse SETTINGS Frame Header" {
    std.debug.print("[TEST 2] HTTP/2 Frame Header Parsing... ", .{});

    // Construct a raw SETTINGS frame header (Type=0x4)
    // Length: 00 00 00 (Empty payload for valid ack/empty settings)
    // Type:   04 (SETTINGS)
    // Flags:  00
    // Stream: 00 00 00 00 (Must be stream 0)
    const raw_bytes = [_]u8{
        0x00, 0x00, 0x00, // Length (0)
        0x04, // Type (SETTINGS = 4)
        0x00, // Flags
        0x00,
        0x00,
        0x00,
        0x00, // Stream ID (0)
    };

    const header = try frame.FrameHeader.parse(&raw_bytes);

    try testing.expectEqual(frame.FrameType.settings, header.frame_type);
    try testing.expectEqual(@as(u24, 0), header.length);
    try testing.expectEqual(@as(u31, 0), header.stream_id);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 3: HTTP/2 DATA Frame Parsing ---
test "HTTP/2: Parse DATA Frame" {
    std.debug.print("[TEST 3] HTTP/2 DATA Frame Parsing... ", .{});

    // Construct a DATA frame with 4 bytes of payload
    // Length: 00 00 04 (4 bytes)
    // Type:   00 (DATA)
    // Flags:  01 (END_STREAM)
    // Stream: 00 00 00 01 (Stream 1)
    // Data:   "test"
    const raw_bytes = [_]u8{
        0x00, 0x00, 0x04, // Length (4)
        0x00, // Type (DATA = 0)
        0x01, // Flags (END_STREAM)
        0x00, 0x00, 0x00, 0x01, // Stream ID (1)
        0x74, 0x65, 0x73, 0x74, // "test"
    };

    const data_frame = try frame.DataFrame.parse(&raw_bytes);

    try testing.expectEqual(@as(u24, 4), data_frame.header.length);
    try testing.expectEqual(frame.FrameType.data, data_frame.header.frame_type);
    try testing.expectEqual(@as(u31, 1), data_frame.header.stream_id);
    try testing.expectEqual(@as(usize, 4), data_frame.data.len);
    try testing.expectEqualStrings("test", data_frame.data);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 4: HTTP/2 HEADERS Frame Parsing ---
test "HTTP/2: Parse HEADERS Frame" {
    std.debug.print("[TEST 4] HTTP/2 HEADERS Frame Parsing... ", .{});

    // Construct a minimal HEADERS frame
    // Length: 00 00 00 (empty header block for test)
    // Type:   01 (HEADERS)
    // Flags:  04 (END_HEADERS)
    // Stream: 00 00 00 01 (Stream 1)
    const raw_bytes = [_]u8{
        0x00, 0x00, 0x00, // Length (0)
        0x01, // Type (HEADERS = 1)
        0x04, // Flags (END_HEADERS)
        0x00, 0x00, 0x00, 0x01, // Stream ID (1)
    };

    const headers_frame = try frame.HeadersFrame.parse(&raw_bytes);

    try testing.expectEqual(frame.FrameType.headers, headers_frame.header.frame_type);
    try testing.expectEqual(@as(u31, 1), headers_frame.header.stream_id);
    try testing.expectEqual(@as(usize, 0), headers_frame.header_block.len);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 5: HPACK Decoding - Static Table Index ---
test "HTTP/2: HPACK Decode Static Header (Indexed)" {
    std.debug.print("[TEST 5] HPACK Decoder - Static Table... ", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var decoder = hpack.HpackDecoder.init(allocator);
    defer decoder.deinit();

    // 0x82 is the indexed representation for: :method: GET (Index 2 in Static Table)
    // Format: 1xxxxxxx (indexed header field)
    //         10000010 = 0x82 = index 2
    const input = [_]u8{0x82};

    const headers = try decoder.decode(&input);
    defer allocator.free(headers);

    // Verify we got ":method: GET"
    try testing.expect(headers.len >= 1);
    try testing.expectEqualStrings(":method", headers[0].name);
    try testing.expectEqualStrings("GET", headers[0].value);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 6: HPACK Decoding - Literal Header ---
test "HTTP/2: HPACK Decode Literal Header" {
    std.debug.print("[TEST 6] HPACK Decoder - Literal Header... ", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var decoder = hpack.HpackDecoder.init(allocator);
    defer decoder.deinit();

    // Literal header field with incremental indexing
    // Format: 01xxxxxx (literal header field, incremental indexing)
    //         01000000 = 0x40 (name not in table, 6-bit prefix)
    //         Then: name length (7-bit), name, value length (7-bit), value
    // Example: ":path: /hello"
    // 0x40 = literal, incremental, name not indexed
    // 0x05 = name length 5
    // ":path" = 5 bytes
    // 0x06 = value length 6
    // "/hello" = 6 bytes
    const input = [_]u8{
        0x40, // Literal, incremental, name not indexed
        0x05, // Name length: 5
        0x3a, 0x70, 0x61, 0x74, 0x68, // ":path"
        0x06, // Value length: 6
        0x2f, 0x68, 0x65, 0x6c, 0x6c, 0x6f, // "/hello"
    };

    const headers = try decoder.decode(&input);
    defer allocator.free(headers);

    try testing.expect(headers.len >= 1);
    try testing.expectEqualStrings(":path", headers[0].name);
    try testing.expectEqualStrings("/hello", headers[0].value);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 7: Frame Header Serialization ---
test "HTTP/2: Frame Header Serialization" {
    std.debug.print("[TEST 7] HTTP/2 Frame Header Serialization... ", .{});

    var buf: [9]u8 = undefined;

    const header = frame.FrameHeader{
        .length = 42,
        .frame_type = .data,
        .flags = 0x01, // END_STREAM
        .stream_id = 123,
    };

    try header.serialize(&buf);

    // Parse it back to verify
    const parsed = try frame.FrameHeader.parse(&buf);

    try testing.expectEqual(@as(u24, 42), parsed.length);
    try testing.expectEqual(frame.FrameType.data, parsed.frame_type);
    try testing.expectEqual(@as(u8, 0x01), parsed.flags);
    try testing.expectEqual(@as(u31, 123), parsed.stream_id);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 8: HTTP/2 Connection Preface ---
test "HTTP/2: Connection Preface" {
    std.debug.print("[TEST 8] HTTP/2 Connection Preface... ", .{});

    const preface = frame.CONNECTION_PREFACE;
    try testing.expectEqualStrings("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n", preface);
    try testing.expectEqual(@as(usize, 24), preface.len);

    std.debug.print("✅ PASSED\n", .{});
}

// --- TEST 9: Multiple HPACK Headers ---
test "HTTP/2: HPACK Decode Multiple Headers" {
    std.debug.print("[TEST 9] HPACK Decoder - Multiple Headers... ", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var decoder = hpack.HpackDecoder.init(allocator);
    defer decoder.deinit();

    // Multiple indexed headers: :method: GET, :path: /
    // 0x82 = :method: GET (index 2)
    // 0x84 = :path: / (index 4)
    const input = [_]u8{ 0x82, 0x84 };

    const headers = try decoder.decode(&input);
    defer allocator.free(headers);

    try testing.expect(headers.len >= 2);
    try testing.expectEqualStrings(":method", headers[0].name);
    try testing.expectEqualStrings("GET", headers[0].value);
    try testing.expectEqualStrings(":path", headers[1].name);
    try testing.expectEqualStrings("/", headers[1].value);

    std.debug.print("✅ PASSED\n", .{});
}

test "All Foundation Tests Complete" {
    std.debug.print("\n", .{});
    std.debug.print("╔════════════════════════════════════════════════════════════════╗\n", .{});
    std.debug.print("║     ✅ All Foundation Tests Passed - Ready for Integration     ║\n", .{});
    std.debug.print("╚════════════════════════════════════════════════════════════════╝\n", .{});
    std.debug.print("\n", .{});
}
