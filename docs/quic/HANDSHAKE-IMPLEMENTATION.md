# QUIC Handshake Implementation Guide

## Overview

This document describes the QUIC 1-RTT handshake implementation for Blitz Gateway, integrating TLS 1.3 with QUIC transport (RFC 9000 + RFC 9001).

## Architecture

```
UDP Packet (io_uring)
    ↓
QUIC Packet Parser
    ↓
Connection Lookup/Creation
    ↓
Handshake Manager
    ├─ CRYPTO Frame Extraction
    ├─ TLS 1.3 Integration (memory BIOs)
    └─ QUIC Transport Parameters
    ↓
Handshake Complete → Application Data
```

## Key Components

### 1. Handshake Manager (`handshake.zig`)

Manages the QUIC handshake state machine:
- **States**: idle → client_hello_sent → server_hello_sent → handshake_complete → connected
- **Crypto Streams**: Tracks Initial and Handshake crypto streams separately
- **TLS Integration**: Feeds CRYPTO frames to TLS 1.3, extracts TLS output

### 2. Server Connection (`server.zig`)

Manages QUIC server connections:
- **Connection Lookup**: Uses connection ID to find/create connections
- **Packet Processing**: Routes packets to handshake or application data handlers
- **State Management**: Tracks connection lifecycle

## Handshake Flow (1-RTT)

### Client → Server (INITIAL Packet)

1. Client sends INITIAL packet containing:
   - ClientHello in CRYPTO frame (Initial crypto stream)
   - Connection IDs
   - Version negotiation

2. Server processes:
   ```zig
   handshake.processInitialPacket(crypto_frame_data, ssl)
   ```
   - Extracts CRYPTO frame data
   - Feeds to TLS 1.3 (memory BIO)
   - Triggers TLS handshake

### Server → Client (INITIAL Packet)

3. Server generates ServerHello:
   ```zig
   crypto_data = handshake.generateServerHello()
   ```
   - TLS generates ServerHello
   - Wrapped in CRYPTO frame
   - Sent in INITIAL packet

### Client → Server (HANDSHAKE Packet)

4. Client sends HANDSHAKE packet:
   - Additional TLS handshake messages in CRYPTO frame
   - Handshake crypto stream

5. Server processes:
   ```zig
   handshake.processHandshakePacket(crypto_frame_data)
   ```

### Server → Client (HANDSHAKE Packet)

6. Server completes handshake:
   - Sends Finished message
   - Handshake complete

## TLS 1.3 Integration

### Key Differences from TCP/TLS

1. **CRYPTO Frames**: TLS messages sent in QUIC CRYPTO frames, not directly
2. **Stream Separation**: Initial and Handshake crypto streams are separate
3. **Transport Parameters**: QUIC-specific parameters exchanged during handshake
4. **Key Derivation**: Uses QUIC-specific key derivation (RFC 9001)

### Memory BIOs

QUIC uses memory BIOs (same as HTTP/2 implementation):
- `read_bio`: Feed encrypted data from QUIC packets
- `write_bio`: Extract encrypted data for QUIC packets
- No socket BIO (QUIC uses UDP, not TCP)

## Implementation Status

### ✅ Completed

- Handshake state machine structure
- Crypto stream tracking
- Basic packet processing flow
- TLS integration framework
- **CRYPTO Frame Parsing** ✅ **COMPLETE**
  - Extract CRYPTO frames from packet payload
  - Handle VarInt encoding/decoding
  - Parse offset and length fields
  - Unit tests passing (6/6 tests)
- **CRYPTO Frame Generation** ✅ **COMPLETE**
  - Generate CRYPTO frames from TLS output
  - Proper VarInt encoding
  - Frame wrapping for packet payload

### ✅ Completed

- **Packet Generation** ✅ **COMPLETE**
  - Generate INITIAL packets with CRYPTO frames
  - Generate HANDSHAKE packets with CRYPTO frames
  - Proper RFC 9000 packet structure
  - Round-trip tests passing (4/4)

### 🚧 In Progress

- QUIC transport parameters
- Error handling and retry logic

### 📋 TODO

1. ✅ **CRYPTO Frame Parsing** - COMPLETE
   - ✅ Extract CRYPTO frames from packet payload
   - ✅ Handle multiple frames per packet
   - ✅ Track frame offsets

2. ✅ **Packet Generation** - **COMPLETE**
   - ✅ Build INITIAL packets with CRYPTO frames
   - ✅ Build HANDSHAKE packets
   - 🚧 Header protection (RFC 9001) - next
   - ✅ Integration with CRYPTO frame generator

3. **Transport Parameters**
   - Encode/decode transport parameters
   - Validate client parameters
   - Send server parameters

4. **Key Derivation**
   - QUIC-specific key derivation
   - Initial secrets
   - Handshake secrets
   - Application secrets

5. **Error Handling**
   - Invalid packet handling
   - Handshake timeout
   - Retry logic

## Next Steps

1. Implement CRYPTO frame parsing
2. Implement packet generation
3. Add transport parameters
4. Integrate with UDP server loop
5. Test with real QUIC clients (curl, Chrome)

## References

- RFC 9000: QUIC Transport Protocol
- RFC 9001: Using TLS to Secure QUIC
- RFC 9114: HTTP/3

