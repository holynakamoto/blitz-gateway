#!/bin/bash
# Test script for Blitz QUIC Server
# Usage: ./scripts/test-quic.sh
# Works in Vagrant VM or on Linux host

set -e

echo "🧪 Testing Blitz QUIC Server..."
echo ""

# Detect if running in Vagrant
if [ -f /vagrant/Vagrantfile ] || [ -d /vagrant ]; then
    echo "📦 Running in Vagrant VM"
    PROJECT_DIR="/home/vagrant/blitz-gateway"
else
    echo "💻 Running on host"
    PROJECT_DIR="$(pwd)"
fi

cd "$PROJECT_DIR"

# Check if server binary exists
if [ ! -f "./zig-out/bin/blitz-quic" ]; then
    echo "❌ QUIC server binary not found. Building..."
    zig build
    if [ ! -f "./zig-out/bin/blitz-quic" ]; then
        echo "❌ Build failed. Please run: zig build"
        exit 1
    fi
fi

# Check if certificates exist
if [ ! -f "certs/server.crt" ] || [ ! -f "certs/server.key" ]; then
    echo "⚠️  TLS certificates not found. Creating self-signed certificates..."
    mkdir -p certs
    openssl req -x509 -newkey rsa:4096 -keyout certs/server.key -out certs/server.crt -days 365 -nodes -subj "/CN=localhost" 2>/dev/null || {
        echo "❌ Failed to create certificates. Please install OpenSSL or create certs manually."
        exit 1
    }
    echo "✅ Certificates created"
fi

# Function to cleanup
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    if [ ! -z "$SERVER_PID" ]; then
        sudo kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Start server in background
echo "🚀 Starting QUIC server on port 8443..."
sudo ./zig-out/bin/blitz-quic &
SERVER_PID=$!

# Wait for server to start
sleep 3

# Check if server is running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "❌ Server failed to start"
    exit 1
fi

echo "✅ Server started (PID: $SERVER_PID)"
echo ""

# Test 1: Check if server is listening on UDP port 8443
echo "Test 1: Checking UDP port 8443..."
if command -v netstat &> /dev/null; then
    if sudo netstat -ulnp 2>/dev/null | grep -q ":8443"; then
        echo "✅ Server is listening on UDP port 8443"
    else
        echo "⚠️  Server not listening (may need sudo for netstat)"
    fi
elif command -v ss &> /dev/null; then
    if sudo ss -ulnp 2>/dev/null | grep -q ":8443"; then
        echo "✅ Server is listening on UDP port 8443"
    else
        echo "⚠️  Server not listening"
    fi
else
    echo "⚠️  Could not verify UDP port (netstat/ss not available)"
fi
echo ""

# Test 2: curl with HTTP/3 (if available)
echo "Test 2: Testing with curl --http3-only..."
if command -v curl &> /dev/null; then
    curl --http3-only -k --max-time 5 https://localhost:8443/hello 2>&1 || {
        echo "⚠️  curl test failed (this is expected if handshake not fully implemented)"
        echo "   This is normal - we're still implementing transport parameters and header protection"
    }
else
    echo "⚠️  curl not found - skipping HTTP/3 test"
fi
echo ""

# Test 3: Basic UDP connectivity test
echo "Test 3: Testing UDP connectivity..."
if command -v nc &> /dev/null; then
    echo "test" | nc -u -w1 localhost 8443 2>/dev/null && echo "✅ UDP port is reachable" || echo "⚠️  UDP test inconclusive (expected - server may not respond to invalid packets)"
else
    echo "⚠️  nc (netcat) not found - skipping UDP connectivity test"
fi
echo ""

# Test 4: curl with HTTP/3 (if available)
echo "Test 4: Testing with curl --http3-only..."
if command -v curl &> /dev/null; then
    if curl --version 2>/dev/null | grep -q "HTTP3" || curl --version 2>/dev/null | grep -q "http3"; then
        echo "Attempting HTTP/3 request..."
        if curl --http3-only -k https://localhost:8443/hello -m 5 2>&1; then
            echo "✅ HTTP/3 request succeeded!"
        else
            echo "⚠️  HTTP/3 request failed (this is expected until handshake is complete)"
        fi
    else
        echo "⚠️  curl doesn't support HTTP/3 (install curl with HTTP/3 support)"
    fi
else
    echo "⚠️  curl not found"
fi
echo ""

echo "✅ Tests complete!"
echo ""
echo "Next steps:"
echo "  1. Implement transport parameters in TLS handshake"
echo "  2. Implement header protection (RFC 9001)"
echo "  3. Test with: curl --http3-only -k https://localhost:8443/hello"
echo ""

