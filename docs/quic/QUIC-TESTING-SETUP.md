# QUIC End-to-End Testing Setup

## Overview

This document describes the setup for testing the QUIC implementation end-to-end before integrating with the main server.

## What's Been Implemented

### ✅ Standalone QUIC Server
- **File**: `src/quic_main.zig`
- **Build**: `zig build run-quic`
- **Binary**: `zig-out/bin/blitz-quic`
- **Port**: UDP 8443

### ✅ Transport Parameters
- **File**: `src/quic/transport_params.zig`
- **Status**: Encoding/decoding implemented
- **Tests**: `zig build test-transport-params`

### ✅ Test Script
- **File**: `scripts/docker/test-quic.sh`
- **Usage**: `./scripts/docker/test-quic.sh`

## Quick Start

### 1. Build QUIC Server

```bash
zig build
```

This creates `zig-out/bin/blitz-quic`

**Note**: QUIC server requires Linux (io_uring). On macOS/Windows, you can:
- Use Docker with Linux container
- Use a Linux VM
- Test unit tests only (transport parameters, frames, etc.)

### 2. Create TLS Certificates (if needed)

```bash
mkdir -p certs
openssl req -x509 -newkey rsa:4096 \
  -keyout certs/server.key \
  -out certs/server.crt \
  -days 365 -nodes \
  -subj "/CN=localhost"
```

### 3. Run QUIC Server

```bash
zig build run-quic
# Or directly:
./zig-out/bin/blitz-quic
```

### 4. Test with curl (when ready)

```bash
curl --http3-only -k https://localhost:8443/hello
```

## Current Status

### ✅ Completed
- Standalone QUIC server executable
- Transport parameters encoding/decoding
- UDP server loop with io_uring
- Buffer pool for zero-allocation
- Test script infrastructure

### 🚧 Next Steps (Priority Order)

1. **Transport Parameters Integration** (Today)
   - Add transport parameters to TLS handshake
   - Encode in ServerHello extension
   - Validate client parameters

2. **Header Protection** (Tomorrow)
   - Implement AES-128-ECB mask generation
   - Protect/unprotect packet headers
   - Required by RFC 9001

3. **End-to-End Testing** (Day 3)
   - Test with curl --http3-only
   - Debug handshake issues
   - Validate packet flow

4. **HTTP/3 Framing** (Day 4-5)
   - SETTINGS frame handling
   - HEADERS frame parsing
   - Response generation

## Testing Roadmap

### Phase 1: Basic Connectivity ✅
- ✅ Server starts without crashing
- ✅ Server binds to UDP port 8443
- 🚧 Server accepts UDP packets
- 🚧 Server sends responses

### Phase 2: Handshake Validation (Next)
- 🚧 ClientHello received and parsed
- 🚧 ServerHello sent with correct format
- 🚧 Transport parameters exchanged
- 🚧 TLS 1.3 handshake completes
- 🚧 1-RTT handshake successful

### Phase 3: HTTP/3 Request (After Handshake)
- 🚧 HTTP/3 SETTINGS frame received
- 🚧 HTTP/3 HEADERS frame parsed
- 🚧 Request routed to endpoint
- 🚧 Response generated
- 🚧 Client receives response

## Running Tests

### Unit Tests

```bash
# Transport parameters
zig build test-transport-params

# QUIC frames
zig build test-quic-frames

# Packet generation
zig build test-quic-packet-gen
```

### Integration Test Script

```bash
./scripts/test-quic.sh
```

This script:
1. Builds the QUIC server (if needed)
2. Creates certificates (if needed)
3. Starts the server
4. Tests UDP connectivity
5. Attempts curl test (may fail until handshake complete)
6. Cleans up

## Debugging

### Check if Server is Running

```bash
# Linux
ss -uln | grep 8443
# or
netstat -uln | grep 8443
```

### Monitor UDP Traffic

```bash
# tcpdump
sudo tcpdump -i lo -n udp port 8443

# Wireshark
sudo wireshark -i lo -f "udp port 8443"
```

### Server Logs

The server logs to stdout/stderr. Look for:
- "QUIC server listening on UDP port 8443"
- "Error handling QUIC packet: ..."
- TLS-related errors

## Known Issues

1. **Transport Parameters Not Integrated**
   - Currently implemented but not used in TLS handshake
   - Need to add to ServerHello extension

2. **Header Protection Missing**
   - Required by RFC 9001
   - Clients may reject unprotected packets

3. **TLS Integration Incomplete**
   - SSL_CTX needs QUIC-specific configuration
   - Transport parameters need to be passed to TLS

## Next Implementation Tasks

### Today: Transport Parameters Integration

1. Modify TLS handshake to include transport parameters
2. Encode parameters in ServerHello extension
3. Validate client parameters

### Tomorrow: Header Protection

1. Implement `src/quic/header_protection.zig`
2. Integrate with packet generation
3. Test with real clients

### Day 3: End-to-End Test

1. Fix any handshake issues
2. Get curl --http3-only working
3. Validate full handshake flow

## Success Criteria

By end of week, you should have:

```
✅ Standalone QUIC server working
✅ curl --http3-only successfully connects
✅ 1-RTT handshake completes
✅ Transport parameters implemented
✅ Header protection implemented
```

This puts you at **Phase 1 COMPLETE (100%)** and ready for Phase 2!

