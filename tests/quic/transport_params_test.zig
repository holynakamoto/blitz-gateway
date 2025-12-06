// Unit tests for QUIC transport parameters

const std = @import("std");
const transport_params = @import("transport_params.zig");

test "transport parameters round-trip" {
    const params = transport_params.TransportParameters{
        .max_idle_timeout = 30_000,
        .max_udp_payload_size = 1500,
        .initial_max_data = 10_000_000,
        .initial_max_streams_bidi = 100,
    };

    var buf: [1024]u8 = undefined;
    const encoded_len = try params.encode(&buf);

    const decoded = try transport_params.TransportParameters.decode(buf[0..encoded_len]);

    try std.testing.expectEqual(params.max_idle_timeout, decoded.max_idle_timeout);
    try std.testing.expectEqual(params.max_udp_payload_size, decoded.max_udp_payload_size);
    try std.testing.expectEqual(params.initial_max_data, decoded.initial_max_data);
    try std.testing.expectEqual(params.initial_max_streams_bidi, decoded.initial_max_streams_bidi);
}

test "transport parameters default values" {
    const params = transport_params.TransportParameters{};

    try std.testing.expectEqual(@as(u64, 30_000), params.max_idle_timeout);
    try std.testing.expectEqual(@as(u64, 1500), params.max_udp_payload_size);
    try std.testing.expectEqual(@as(u64, 10_000_000), params.initial_max_data);
}
