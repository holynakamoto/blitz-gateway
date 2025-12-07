#!/usr/bin/env bash
# diagnose-quic.sh - Debug QUIC connection issues

set -euo pipefail

VM="zig-build"
BUILD_DIR="/home/ubuntu/local_build"

echo "🔍 QUIC Server Diagnostic"
echo "=========================="
echo ""

echo "1. Checking if server is running..."
if multipass exec $VM -- pgrep -f "blitz.*quic" >/dev/null; then
    echo "   ✓ Server process found"
    multipass exec $VM -- ps aux | grep blitz | grep -v grep
else
    echo "   ✗ Server process NOT running"
fi

echo ""
echo "2. Checking UDP socket..."
multipass exec $VM -- ss -ulnp 2>/dev/null | grep 8443 || echo "   ✗ Port 8443 not listening"

echo ""
echo "3. Checking server logs (last 30 lines)..."
echo "-------------------------------------------"
multipass exec $VM -- tail -30 $BUILD_DIR/quic.log 2>/dev/null || echo "   ✗ No log file found"
echo "-------------------------------------------"

echo ""
echo "4. Checking for error patterns..."
if multipass exec $VM -- grep -i "error\|fail\|panic" $BUILD_DIR/quic.log 2>/dev/null | tail -10; then
    echo ""
else
    echo "   No obvious errors found"
fi

echo ""
echo "5. Checking for certificate logs..."
if multipass exec $VM -- grep -E "\[CERT\]|\[SIGN\]|error 50" $BUILD_DIR/quic.log 2>/dev/null | tail -20; then
    echo ""
else
    echo "   No certificate logs found"
fi

echo ""
echo "6. Testing connection from within VM..."
if multipass exec $VM -- bash -c "echo 'test' | nc -u -w1 127.0.0.1 8443" 2>/dev/null; then
    echo "   ✓ UDP connection accepted"
else
    echo "   ? Connection test inconclusive (expected for QUIC)"
fi

echo ""
echo "7. Certificate files present?"
multipass exec $VM -- ls -lh $BUILD_DIR/cert.pem $BUILD_DIR/key.pem 2>/dev/null || echo "   ✗ Certificate files missing"

echo ""
echo "8. Checking certificate validity..."
if multipass exec $VM -- bash -c "[ -f $BUILD_DIR/cert.pem ] && openssl x509 -in $BUILD_DIR/cert.pem -text -noout 2>/dev/null | head -5"; then
    echo "   ✓ Certificate is valid"
else
    echo "   ✗ Certificate validation failed"
fi

echo ""
echo "9. Checking for TLS handshake attempts..."
if multipass exec $VM -- grep -E "handshake|ClientHello|ServerHello|TLS" $BUILD_DIR/quic.log 2>/dev/null | tail -10; then
    echo ""
else
    echo "   No TLS handshake logs found"
fi

echo ""
echo "10. Server startup command used..."
if multipass exec $VM -- grep -E "Starting|blitz.*quic" $BUILD_DIR/quic.log 2>/dev/null | head -5; then
    echo ""
else
    echo "   (Check if server started with --cert and --key flags)"
fi

echo ""
echo "=========================="
echo "Diagnostic complete"
echo ""
echo "Next steps:"
echo "  • If server not running: Check startup errors above"
echo "  • If error 50 found: Certificate signing issue (should be fixed)"
echo "  • If no [SIGN] logs: Client not connecting or handshake not starting"
echo "  • If [SIGN] logs present: Check for signature generation errors"

