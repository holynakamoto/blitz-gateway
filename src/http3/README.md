# HTTP/3 Implementation (RFC 9114)

## Status: Phase 2 - Framing (In Progress)

This module implements HTTP/3 on top of QUIC streams.

## Current Implementation

### ✅ Completed

- **Frame Types** (`frame.zig`)
  - DATA frame parsing and generation
  - HEADERS frame parsing and generation
  - SETTINGS frame parsing and generation
  - GOAWAY frame parsing and generation
  - Variable-length integer encoding/decoding

## Architecture

HTTP/3 runs on top of QUIC streams:

```
QUIC Stream
    ↓
HTTP/3 Frame Parser (frame.zig)
    ↓
QPACK Header Decompression (TODO)
    ↓
Request Handler
```

## Frame Types Supported

- ✅ DATA (0x00) - Payload delivery
- ✅ HEADERS (0x01) - Request/response headers
- ✅ SETTINGS (0x04) - Configuration
- ✅ GOAWAY (0x07) - Graceful shutdown
- 🚧 CANCEL_PUSH (0x03) - Server push cancellation
- 🚧 PUSH_PROMISE (0x05) - Server push
- 🚧 MAX_PUSH_ID (0x0d) - Push ID limits

## Next Steps

1. **QPACK Implementation** (RFC 9204)
   - Static table
   - Dynamic table
   - Encoder/decoder streams
   - Header compression/decompression

2. **Request/Response Handling**
   - Parse HTTP/3 requests
   - Generate HTTP/3 responses
   - Pseudo-header handling

3. **Integration with Routing**
   - Connect HTTP/3 to existing routing engine
   - Load balancer integration

## References

- RFC 9114: HTTP/3
- RFC 9204: QPACK: Field Compression for HTTP/3
- RFC 9218: Extensible Prioritization Scheme for HTTP

