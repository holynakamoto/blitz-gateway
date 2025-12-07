# QUIC/HTTP3 Session Validation & Benchmarking Suite

This suite provides comprehensive tools to validate and benchmark QUIC/HTTP3 session establishment and performance.

## 🎯 Overview

The suite includes validation and testing tools for:

1. **Basic Connectivity** - UDP socket communication
2. **QUIC Handshake** - Initial packet exchange and TLS handshake
3. **HTTP/3 Requests** - Full request/response cycles
4. **Session Capture** - Verify capture files are created
5. **Performance** - Latency and throughput benchmarking

## 🚀 Quick Start

### Zig Validator (Native, No Dependencies)

```bash
# Compile and run
cd /path/to/blitz-gateway
zig run tools/quic_validator.zig

# Test specific server
zig run tools/quic_validator.zig -- 192.168.1.100 4433

# Or compile to executable
zig build-exe tools/quic_validator.zig -o quic_validator
./quic_validator 127.0.0.1 8443
```

**What it tests:**
- ✓ UDP connectivity
- ✓ QUIC Initial packet acceptance
- ✓ Server response validation
- ✓ Capture directory creation

### Python Validator (Full Handshake)

```bash
# Install dependencies first
pip install aioquic

# Default (localhost:8443)
python3 tools/quic_validator.py

# Specific server
python3 tools/quic_validator.py 192.168.1.100 4433

# Verbose mode
python3 tools/quic_validator.py -v
```

### Python Benchmark

```bash
# Quick handshake benchmark (100 iterations)
python3 tools/quic_benchmark.py handshake

# Request benchmark (1000 requests, 10 concurrent)
python3 tools/quic_benchmark.py requests

# Full benchmark suite
python3 tools/quic_benchmark.py all -o results.json
```

## 📋 Prerequisites

### For Zig Validator
- Zig 0.11+ (already installed for your project)

### For Python Tools
```bash
pip install aioquic
```

## 🔍 Test Descriptions

### Test 1: UDP Connectivity
- **Purpose:** Verify basic UDP socket communication
- **Success criteria:** Able to send packets to server
- **Common failures:** 
  - Firewall blocking UDP
  - Server not listening
  - Network unreachable

### Test 2: QUIC Initial Packet
- **Purpose:** Verify server accepts and responds to QUIC Initial packets
- **Success criteria:** Receive valid QUIC response packet
- **Common failures:**
  - Initial secrets derivation mismatch
  - Packet encryption/decryption errors
  - Version negotiation issues

### Test 3: Session Capture
- **Purpose:** Verify capture files are created when connections are established
- **Success criteria:** `captures/` directory contains files
- **Requirements:** Server must be started with `--capture` flag

## 🐛 Troubleshooting

### Server Not Responding

```bash
# Check if server is running
ps aux | grep blitz

# Check if port is listening
netstat -ulpn | grep 8443
# or
ss -ulnp | grep 8443

# Check server logs
tail -f /tmp/blitz.log
```

### No Capture Files Created

1. Verify server started with `--capture` flag:
   ```bash
   ./zig-out/bin/blitz --mode quic --port 8443 \
     --cert certs/server.crt --key certs/server.key \
     --capture
   ```

2. Check server logs for `[CAPTURE]` messages

3. Verify connection reaches packet processing

### Handshake Timeout

- Check server logs for TLS errors
- Verify certificate is valid
- Check ALPN protocol negotiation ("h3")
- Review capture files for packet details

## 📊 Expected Output

### Successful Validation

```
╔═══════════════════════════════════════════════════════════╗
║  QUIC/HTTP3 Session Validation Suite                     ║
╠═══════════════════════════════════════════════════════════╣
║  Server: 127.0.0.1:8443                                   ║
╚═══════════════════════════════════════════════════════════╝

Test 1: UDP Connectivity
  ✓ PASS - UDP socket can send packets (no response expected) (25 ms)

Test 2: QUIC Initial Packet Exchange
  → Sending QUIC Initial packet (1200 bytes)
    DCID: a1b2c3d4e5f6g7h8
    SCID: 9i0j1k2l3m4n5o6p
  ← Received response (1200 bytes)
  ✓ PASS - Server responded with valid QUIC packet (45 ms)
        Received Initial packet (1200 bytes)

Test 3: Session Capture
  ✓ PASS - Capture files created successfully (5 ms)
        Found 4 capture file(s)

╔═══════════════════════════════════════════════════════════╗
║  Test Summary                                             ║
╠═══════════════════════════════════════════════════════════╣
║  Total Tests: 3                                           ║
║  Passed: 3                                                ║
║  Failed: 0                                                ║
╚═══════════════════════════════════════════════════════════╝

🎉 All tests passed! QUIC handshake is working.
```

## 🔧 Integration with CI/CD

### Basic CI Script

```bash
#!/bin/bash
# ci-validation.sh

# Start server
./zig-out/bin/blitz --mode quic --port 8443 \
  --cert certs/server.crt --key certs/server.key \
  --capture > /tmp/blitz.log 2>&1 &
SERVER_PID=$!

# Wait for startup
sleep 2

# Run validation
zig run tools/quic_validator.zig || exit 1

# Cleanup
kill $SERVER_PID
```

## 📝 Notes

- The Zig validator is lightweight and has no external dependencies
- Python validators provide more comprehensive testing but require aioquic
- Capture files are created in `captures/` directory when `--capture` flag is enabled
- Tests can be run against localhost or remote servers

## 📄 License

Part of the Blitz Gateway QUIC implementation.

