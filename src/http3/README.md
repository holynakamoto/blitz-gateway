# HTTP/3 Implementation (RFC 9114)

## Status: Phase 2 - Framing & QPACK ✅

This module implements HTTP/3 on top of QUIC streams.

## Current Implementation

### ✅ Completed

- **Frame Types** (`frame.zig`)
  - DATA frame parsing and generation
  - HEADERS frame parsing and generation (with QPACK integration)
  - SETTINGS frame parsing and generation
  - GOAWAY frame parsing and generation
  - Variable-length integer encoding/decoding

- **QPACK Header Compression** (`qpack.zig`) - **MANDATORY for HTTP/3**
  - ✅ Complete static table (99 entries per RFC 9204 Appendix A)
  - ✅ Prefix integer encoding/decoding
  - ✅ String encoding (literal, Huffman TODO)
  - ✅ QpackEncoder for response headers
  - ✅ QpackDecoder for request headers
  - ✅ Static table indexed references
  - ✅ Literal with name reference
  - ✅ Literal with literal name
  - 🚧 Dynamic table (future)
  - 🚧 Encoder/decoder instruction streams (future)

## ⚠️ IMPORTANT: HPACK is FORBIDDEN in HTTP/3

RFC 9114 §4.2 is explicit:
> "HTTP/3 uses QPACK instead of HPACK for header compression. 
> The use of HPACK with HTTP/3 is not supported and will result 
> in interoperability failures."

Every major browser and HTTP/3 client will **reject** HPACK-encoded headers.
This implementation uses QPACK exclusively.

## Architecture

```
HTTP/3 Request/Response
        ↓
HTTP/3 Frame Parser (frame.zig)
        ↓
QPACK Header Compression (qpack.zig)  ← RFC 9204
        ↓
QUIC Streams (../quic/*)
        ↓
UDP + io_uring
```

## QPACK vs HPACK Differences

| Aspect | HPACK (HTTP/2) | QPACK (HTTP/3) |
|--------|---------------|----------------|
| Transport | TCP (reliable, ordered) | QUIC (unreliable, unordered) |
| Dynamic table updates | Same stream | Separate unidirectional streams |
| HOL blocking | Yes | No |
| Static table | 61 entries | 99 entries |
| References | Can reference future entries | Only acknowledged entries |

## Frame Types Supported

- ✅ DATA (0x00) - Payload delivery
- ✅ HEADERS (0x01) - Request/response headers (QPACK-encoded)
- ✅ SETTINGS (0x04) - Configuration
- ✅ GOAWAY (0x07) - Graceful shutdown
- 🚧 CANCEL_PUSH (0x03) - Server push cancellation
- 🚧 PUSH_PROMISE (0x05) - Server push
- 🚧 MAX_PUSH_ID (0x0d) - Push ID limits

## Usage Example

```zig
const frame = @import("http3/frame.zig");
const qpack = @import("http3/qpack.zig");

// Encoding response headers
var encoder = qpack.QpackEncoder.init(allocator);
defer encoder.deinit();

const headers = [_]qpack.HeaderField{
    .{ .name = ":status", .value = "200" },
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "server", .value = "blitz-gateway" },
};

// Generate HEADERS frame with QPACK encoding
var buf: [1024]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try frame.HeadersFrame.generateFromHeaders(fbs.writer(), &encoder, &headers);

// Decoding request headers
var decoder = qpack.QpackDecoder.init(allocator);
defer decoder.deinit();

const headers_frame = try frame.HeadersFrame.parse(data);
const decoded_headers = try headers_frame.decodeHeaders(&decoder);
defer allocator.free(decoded_headers);
```

## Next Steps

1. **Dynamic Table Support**
   - Insert with name reference
   - Insert with literal name
   - Duplicate instruction
   - Set dynamic table capacity

2. **Encoder/Decoder Streams**
   - Unidirectional stream handling
   - Table synchronization
   - Header Acknowledgment

3. **Huffman Coding**
   - Static Huffman table
   - Encode/decode strings

4. **Request/Response Handling**
   - Parse HTTP/3 requests
   - Generate HTTP/3 responses
   - Pseudo-header validation

## References

- RFC 9114: HTTP/3
- RFC 9204: QPACK: Field Compression for HTTP/3
- RFC 9218: Extensible Prioritization Scheme for HTTP
