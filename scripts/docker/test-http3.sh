#!/usr/bin/env bash
# HTTP/3 Test Script
# Tests QUIC server with HTTP/3 curl
set -euo pipefail

echo "🧪 Testing HTTP/3 against localhost:8443 ..."
echo ""

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not running"
    exit 1
fi

# Check if QUIC server is running (check container name)
if ! docker ps --format '{{.Names}}' | grep -q "blitz-quic-server"; then
    echo "❌ QUIC server is not running"
    echo "   Start it with: ./scripts/docker-quic.sh run"
    exit 1
fi
echo "✅ QUIC server container is running"

echo "📡 Sending HTTP/3 request..."
echo ""

# Test with verbose output
if docker run --rm --network host curlimages/curl \
     --http3-only \
     --insecure \
     --verbose \
     --max-time 5 \
     https://localhost:8443/hello 2>&1; then
    echo ""
    echo "✅ HTTP/3 SUCCESS!"
else
    echo ""
    echo "⚠️  HTTP/3 request failed (expected until QUIC handshake is implemented)"
    echo ""
    echo "📋 Quick check - can we reach UDP port?"
    echo "test" | nc -u -w1 localhost 8443 && echo "   ✅ UDP connectivity works"
    echo ""
    echo "📋 Server logs:"
    docker logs blitz-quic-server 2>&1 | tail -5
    exit 1
fi

