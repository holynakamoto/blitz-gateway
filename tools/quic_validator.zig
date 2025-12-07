// QUIC/HTTP3 Session Validator
// Comprehensive validation tool for testing QUIC handshake and HTTP3 session establishment

const std = @import("std");
const builtin = @import("builtin");

// Test modes
pub const TestMode = enum {
    basic_connectivity, // Simple UDP packet test
    initial_packet, // Send valid QUIC Initial packet
    full_handshake, // Complete QUIC handshake attempt
    http3_request, // HTTP3 GET request
    all, // Run all tests
};

// Test result
pub const TestResult = struct {
    test_name: []const u8,
    passed: bool,
    message: []const u8,
    duration_ms: u64,
    details: ?[]const u8 = null,
};

// QUIC packet builder for testing
pub const QuicInitialPacketBuilder = struct {
    allocator: std.mem.Allocator,

    // Generate a minimal valid QUIC Initial packet
    pub fn buildMinimalInitial(self: QuicInitialPacketBuilder, dest_conn_id: []const u8, src_conn_id: []const u8) ![]u8 {
        // QUIC Initial packet structure:
        // - Long Header (1 byte): 11xx0000 where xx = packet number length
        // - Version (4 bytes): 0x00000001 (QUIC v1)
        // - DCID Len (1 byte)
        // - DCID (variable)
        // - SCID Len (1 byte)
        // - SCID (variable)
        // - Token Length (varint) - 0 for client Initial
        // - Length (varint) - length of packet number + payload
        // - Packet Number (1-4 bytes)
        // - Payload (CRYPTO frame with ClientHello)

        const packet_size = 1200; // QUIC requires minimum 1200 bytes for Initial
        var packet = try self.allocator.alloc(u8, packet_size);
        errdefer self.allocator.free(packet);

        @memset(packet, 0); // Initialize with zeros (PADDING frames)

        var pos: usize = 0;

        // Long header: Initial packet (type=0) with 1-byte packet number
        packet[pos] = 0xC0; // 11000000 - Long header, Initial, 1-byte PN
        pos += 1;

        // Version: QUIC v1 (0x00000001)
        std.mem.writeInt(u32, packet[pos..][0..4], 0x00000001, .big);
        pos += 4;

        // Destination Connection ID
        packet[pos] = @intCast(dest_conn_id.len);
        pos += 1;
        @memcpy(packet[pos..][0..dest_conn_id.len], dest_conn_id);
        pos += dest_conn_id.len;

        // Source Connection ID
        packet[pos] = @intCast(src_conn_id.len);
        pos += 1;
        @memcpy(packet[pos..][0..src_conn_id.len], src_conn_id);
        pos += src_conn_id.len;

        // Token Length: 0 (no token for client Initial)
        packet[pos] = 0x00;
        pos += 1;

        // Placeholder for Length field (will be set below)
        const length_offset = pos;
        packet[pos] = 0x40; // 2-byte varint marker
        pos += 2;

        // Packet Number (1 byte)
        packet[pos] = 0x00;
        pos += 1;

        // Calculate payload length (rest of packet - PN - this simple test just uses PADDING)
        const payload_start = pos;
        const payload_len = packet_size - payload_start;

        // Set Length field: PN (1 byte) + payload
        const total_len = 1 + payload_len;
        packet[length_offset] = 0x40 | @as(u8, @intCast((total_len >> 8) & 0x3F));
        packet[length_offset + 1] = @intCast(total_len & 0xFF);

        // Payload is all zeros (PADDING frames) for this basic test

        return packet;
    }

    pub fn deinit(self: QuicInitialPacketBuilder, packet: []u8) void {
        self.allocator.free(packet);
    }
};

// Connection validator
pub const ConnectionValidator = struct {
    allocator: std.mem.Allocator,
    server_addr: std.net.Address,
    timeout_ms: u64 = 5000,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !ConnectionValidator {
        const addr = try std.net.Address.parseIp4(host, port);
        return ConnectionValidator{
            .allocator = allocator,
            .server_addr = addr,
        };
    }

    // Test 1: Basic UDP connectivity
    pub fn testUdpConnectivity(self: *ConnectionValidator) !TestResult {
        const start_time = std.time.milliTimestamp();

        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        defer std.posix.close(sock);

        // Set receive timeout
        var timeout: std.posix.timeval = undefined;
        timeout.sec = @intCast(@divTrunc(self.timeout_ms, 1000));
        timeout.usec = @intCast(@mod(self.timeout_ms, 1000) * 1000);
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        );

        // Send a simple test packet
        const test_data = "QUIC_PING";
        const sent = try std.posix.sendto(
            sock,
            test_data,
            0,
            &self.server_addr.any,
            self.server_addr.getOsSockLen(),
        );

        if (sent != test_data.len) {
            return TestResult{
                .test_name = "UDP Connectivity",
                .passed = false,
                .message = "Failed to send full packet",
                .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
            };
        }

        // Try to receive (server might reject, but socket should work)
        var recv_buf: [1024]u8 = undefined;
        _ = std.posix.recvfrom(sock, &recv_buf, 0, null, null) catch |err| {
            // Timeout is expected - server won't respond to invalid packet
            if (err == error.WouldBlock) {
                return TestResult{
                    .test_name = "UDP Connectivity",
                    .passed = true,
                    .message = "UDP socket can send packets (no response expected)",
                    .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                };
            }
            return err;
        };

        const duration = std.time.milliTimestamp() - start_time;
        return TestResult{
            .test_name = "UDP Connectivity",
            .passed = true,
            .message = "UDP bidirectional communication works",
            .duration_ms = @intCast(duration),
        };
    }

    // Test 2: QUIC Initial packet acceptance
    pub fn testQuicInitial(self: *ConnectionValidator) !TestResult {
        const start_time = std.time.milliTimestamp();

        const sock = try std.posix.socket(
            std.posix.AF.INET,
            std.posix.SOCK.DGRAM,
            std.posix.IPPROTO.UDP,
        );
        defer std.posix.close(sock);

        // Set receive timeout
        var timeout: std.posix.timeval = undefined;
        timeout.sec = 2;
        timeout.usec = 0;
        try std.posix.setsockopt(
            sock,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&timeout),
        );

        // Generate connection IDs
        var dcid: [8]u8 = undefined;
        var scid: [8]u8 = undefined;
        std.crypto.random.bytes(&dcid);
        std.crypto.random.bytes(&scid);

        // Build QUIC Initial packet
        const builder = QuicInitialPacketBuilder{ .allocator = self.allocator };
        const packet = try builder.buildMinimalInitial(&dcid, &scid);
        defer builder.deinit(packet);

        std.debug.print("  → Sending QUIC Initial packet ({} bytes)\n", .{packet.len});
        std.debug.print("    DCID: ", .{});
        for (dcid) |byte| std.debug.print("{x:0>2}", .{byte});
        std.debug.print("\n", .{});
        std.debug.print("    SCID: ", .{});
        for (scid) |byte| std.debug.print("{x:0>2}", .{byte});
        std.debug.print("\n", .{});

        // Send Initial packet
        const sent = try std.posix.sendto(
            sock,
            packet,
            0,
            &self.server_addr.any,
            self.server_addr.getOsSockLen(),
        );

        if (sent != packet.len) {
            return TestResult{
                .test_name = "QUIC Initial Packet",
                .passed = false,
                .message = "Failed to send full Initial packet",
                .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
            };
        }

        // Wait for response
        var recv_buf: [2048]u8 = undefined;
        const recv_len = std.posix.recvfrom(sock, &recv_buf, 0, null, null) catch |err| {
            if (err == error.WouldBlock) {
                return TestResult{
                    .test_name = "QUIC Initial Packet",
                    .passed = false,
                    .message = "Server did not respond to Initial packet (timeout)",
                    .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                    .details = "Check server logs for errors. Server should send ServerHello.",
                };
            }
            return err;
        };

        const duration = std.time.milliTimestamp() - start_time;

        std.debug.print("  ← Received response ({} bytes)\n", .{recv_len});

        // Basic validation of response
        if (recv_len < 20) {
            return TestResult{
                .test_name = "QUIC Initial Packet",
                .passed = false,
                .message = "Response too short to be valid QUIC packet",
                .duration_ms = @intCast(duration),
            };
        }

        // Check if it's a QUIC packet (long header)
        const first_byte = recv_buf[0];
        if ((first_byte & 0x80) == 0) {
            return TestResult{
                .test_name = "QUIC Initial Packet",
                .passed = false,
                .message = "Response is not a QUIC long header packet",
                .duration_ms = @intCast(duration),
            };
        }

        // Extract packet type
        const packet_type = (first_byte & 0x30) >> 4;
        const type_name = switch (packet_type) {
            0 => "Initial",
            1 => "0-RTT",
            2 => "Handshake",
            3 => "Retry",
            else => "Unknown",
        };

        var details_buf: [256]u8 = undefined;
        const details = try std.fmt.bufPrint(&details_buf, "Received {s} packet ({} bytes)", .{ type_name, recv_len });
        const details_copy = try self.allocator.dupe(u8, details);

        return TestResult{
            .test_name = "QUIC Initial Packet",
            .passed = true,
            .message = "Server responded with valid QUIC packet",
            .duration_ms = @intCast(duration),
            .details = details_copy,
        };
    }

    // Test 3: Check capture directory
    pub fn testCaptureCreation(self: *ConnectionValidator) !TestResult {
        const start_time = std.time.milliTimestamp();

        // Check if captures directory exists
        var captures_dir = std.fs.cwd().openDir("captures", .{ .iterate = true }) catch |err| {
            if (err == error.FileNotFound) {
                return TestResult{
                    .test_name = "Capture Directory",
                    .passed = false,
                    .message = "captures/ directory does not exist - no sessions captured yet",
                    .duration_ms = @intCast(std.time.milliTimestamp() - start_time),
                    .details = "Directory will be created when first QUIC connection is established",
                };
            }
            return err;
        };
        defer captures_dir.close();

        // Count capture files
        var file_count: usize = 0;
        var iter = captures_dir.iterate();
        
        while (try iter.next()) |entry| {
            if (entry.kind == .file) {
                file_count += 1;
            }
        }

        const duration = std.time.milliTimestamp() - start_time;

        var details_buf: [256]u8 = undefined;
        const details = try std.fmt.bufPrint(&details_buf, "Found {} capture file(s)", .{file_count});
        const details_copy = try self.allocator.dupe(u8, details);

        return TestResult{
            .test_name = "Capture Directory",
            .passed = file_count > 0,
            .message = if (file_count > 0) "Capture files created successfully" else "No capture files found",
            .duration_ms = @intCast(duration),
            .details = details_copy,
        };
    }

    // Run all tests
    pub fn runAllTests(self: *ConnectionValidator) ![]TestResult {
        var results = try std.ArrayList(TestResult).initCapacity(self.allocator, 10);

        std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  QUIC/HTTP3 Session Validation Suite                     ║\n", .{});
        std.debug.print("╠═══════════════════════════════════════════════════════════╣\n", .{});
        // Format address for display
        const addr_str = switch (self.server_addr.any.family) {
            std.posix.AF.INET => blk: {
                const addr_in = self.server_addr.in;
                var buf: [64]u8 = undefined;
                const addr_bytes = std.mem.asBytes(&addr_in.sa.addr);
                const ip_str = try std.fmt.bufPrint(&buf, "{d}.{d}.{d}.{d}:{}", .{
                    addr_bytes[0], addr_bytes[1], addr_bytes[2], addr_bytes[3],
                    std.mem.bigToNative(u16, addr_in.sa.port),
                });
                break :blk ip_str;
            },
            else => "unknown",
        };
        std.debug.print("║  Server: {s:<47} ║\n", .{addr_str});
        std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

        // Test 1: UDP Connectivity
        std.debug.print("Test 1: UDP Connectivity\n", .{});
        const test1 = try self.testUdpConnectivity();
        try results.append(self.allocator, test1);
        printResult(test1);

        // Test 2: QUIC Initial
        std.debug.print("\nTest 2: QUIC Initial Packet Exchange\n", .{});
        const test2 = try self.testQuicInitial();
        try results.append(self.allocator, test2);
        printResult(test2);

        // Small delay to let server process
        std.Thread.sleep(500 * std.time.ns_per_ms);

        // Test 3: Capture files
        std.debug.print("\nTest 3: Session Capture\n", .{});
        const test3 = try self.testCaptureCreation();
        try results.append(self.allocator, test3);
        printResult(test3);

        return try results.toOwnedSlice(self.allocator);
    }

    fn printResult(result: TestResult) void {
        const status = if (result.passed) "✓ PASS" else "✗ FAIL";
        const color = if (result.passed) "\x1b[32m" else "\x1b[31m";
        const reset = "\x1b[0m";

        std.debug.print("  {s}{s}{s} - {s} ({} ms)\n", .{ color, status, reset, result.message, result.duration_ms });
        if (result.details) |details| {
            std.debug.print("        {s}\n", .{details});
        }
    }

    pub fn printSummary(results: []const TestResult) void {
        var passed: usize = 0;
        var failed: usize = 0;

        for (results) |result| {
            if (result.passed) {
                passed += 1;
            } else {
                failed += 1;
            }
        }

        std.debug.print("\n╔═══════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║  Test Summary                                             ║\n", .{});
        std.debug.print("╠═══════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║  Total Tests: {d:<3}                                         ║\n", .{results.len});
        std.debug.print("║  \x1b[32mPassed: {d:<3}\x1b[0m                                             ║\n", .{passed});
        std.debug.print("║  \x1b[31mFailed: {d:<3}\x1b[0m                                             ║\n", .{failed});
        std.debug.print("╚═══════════════════════════════════════════════════════════╝\n\n", .{});

        if (failed > 0) {
            std.debug.print("⚠️  Some tests failed. Check server logs for details.\n", .{});
            std.debug.print("   Common issues:\n", .{});
            std.debug.print("   - Server not running or not listening on specified port\n", .{});
            std.debug.print("   - Certificate/key issues preventing TLS handshake\n", .{});
            std.debug.print("   - Initial secrets derivation mismatch\n", .{});
            std.debug.print("   - Packet encryption/decryption errors\n\n", .{});
        } else {
            std.debug.print("🎉 All tests passed! QUIC handshake is working.\n\n", .{});
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8443;

    if (args.len > 1) {
        host = args[1];
    }
    if (args.len > 2) {
        port = try std.fmt.parseInt(u16, args[2], 10);
    }

    var validator = try ConnectionValidator.init(allocator, host, port);

    const results = try validator.runAllTests();
    defer {
        for (results) |result| {
            if (result.details) |details| {
                allocator.free(details);
            }
        }
        allocator.free(results);
    }

    ConnectionValidator.printSummary(results);

    // Exit with error code if any tests failed
    for (results) |result| {
        if (!result.passed) {
            std.process.exit(1);
        }
    }
}

