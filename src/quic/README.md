# QUIC Implementation (RFC 9000)

## Status: Phase 1 - Foundation (In Progress)

This module implements the QUIC transport protocol for Blitz Gateway.

## Current Implementation

### ✅ Completed

- **Packet Structures** (`packet.zig`)
  - Long header packet parsing (INITIAL, HANDSHAKE, 0-RTT, RETRY)
  - Short header packet parsing
  - Variable-length integer encoding/decoding
  - CRYPTO frame parsing
  - Frame type definitions

- **Connection Management** (`connection.zig`)
  - Connection state machine
  - Stream management (bidirectional and unidirectional)
  - Flow control parameters
  - Connection ID handling

- **UDP Socket Handling** (`udp.zig`)
  - UDP socket creation and binding
  - io_uring integration helpers (prepRecvFrom, prepSendTo)
  - Connection tracking structure

## Architecture

```
UDP Socket (io_uring)
    ↓
QUIC Packet Parser (packet.zig)
    ↓
Connection Demultiplexer (connection.zig)
    ↓
Stream Demultiplexer
    ↓
HTTP/3 Frame Handler (http3/frame.zig)
```

## Next Steps

1. **QUIC Handshake Implementation**
   - 1-RTT handshake with TLS 1.3
   - Connection establishment
   - Version negotiation

2. **Packet Encryption/Decryption**
   - Header protection (RFC 9001)
   - Packet protection with AEAD
   - Key derivation

3. **Loss Detection & Congestion Control**
   - ACK frame generation
   - Packet loss detection
   - Cubic/BBR congestion control

4. **Stream Multiplexing**
   - STREAM frame handling
   - Flow control per stream
   - Stream state management

## References

- RFC 9000: QUIC Transport Protocol
- RFC 9001: Using TLS to Secure QUIC
- RFC 9114: HTTP/3

