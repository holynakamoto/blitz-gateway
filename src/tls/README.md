# TLS 1.3 Implementation

This module provides TLS 1.3 support for Blitz using OpenSSL.

## Features

- TLS 1.3 only (no legacy protocols)
- ALPN support for HTTP/2 negotiation
- Non-blocking handshake for io_uring integration
- Zero-copy where possible

## Usage

```zig
const tls = @import("tls/tls.zig");

// Initialize TLS context
var tls_ctx = try tls.TlsContext.init();
defer tls_ctx.deinit();

// Load certificate and key
try tls_ctx.loadCertificate("cert.pem", "key.pem");

// Create TLS connection for a socket
var tls_conn = try tls_ctx.newConnection(fd);
defer tls_conn.deinit();

// Perform handshake (non-blocking)
while (tls_conn.state == .handshake) {
    const state = try tls_conn.doHandshake();
    if (state == .handshake) {
        // Need more I/O - submit to io_uring
        continue;
    }
}

// Read/write encrypted data
const bytes = try tls_conn.read(buffer);
try tls_conn.write(response);
```

## Requirements

- OpenSSL 1.1.1+ (TLS 1.3 support)
- libssl-dev package

## Integration with io_uring

The TLS handshake is non-blocking and integrates with io_uring:
1. Accept connection
2. Create TLS connection
3. Submit read to io_uring for handshake data
4. Process handshake in completion handler
5. If handshake incomplete, submit more I/O
6. Once connected, use TLS read/write for encrypted data

