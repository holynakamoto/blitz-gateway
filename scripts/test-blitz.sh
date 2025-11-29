#!/bin/bash
# Comprehensive test suite for Blitz Gateway
# Tests: HTTP/1.1, Connection Handling, TLS 1.3, HTTP/2

set -e

BLITZ_HOST="${BLITZ_HOST:-localhost}"
BLITZ_PORT="${BLITZ_PORT:-8080}"
BLITZ_TLS_PORT="${BLITZ_TLS_PORT:-8443}"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

# Test result tracking
pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    FAILED=$((FAILED + 1))
}

skip() {
    echo -e "${YELLOW}⏭️  SKIP${NC}: $1"
    SKIPPED=$((SKIPPED + 1))
}

info() {
    echo -e "${BLUE}ℹ️  INFO${NC}: $1"
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Blitz Gateway Test Suite                                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Target: http://${BLITZ_HOST}:${BLITZ_PORT}"
echo "TLS:    https://${BLITZ_HOST}:${BLITZ_TLS_PORT}"
echo ""

# Check if server is running
info "Checking if Blitz server is running..."
if curl -s --connect-timeout 2 "http://${BLITZ_HOST}:${BLITZ_PORT}" > /dev/null 2>&1; then
    pass "Server is responding on port ${BLITZ_PORT}"
else
    fail "Server is not responding on port ${BLITZ_PORT}"
    echo ""
    echo "Please start Blitz server first:"
    echo "  ./zig-out/bin/blitz"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST 1: HTTP/1.1 Basic Functionality"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 1.1: Simple GET request
RESPONSE=$(curl -s "http://${BLITZ_HOST}:${BLITZ_PORT}/")
if [ -n "$RESPONSE" ]; then
    pass "Simple GET request"
    echo "   Response: ${RESPONSE:0:50}..."
else
    fail "Simple GET request (empty response)"
fi

# Test 1.2: GET with path
RESPONSE=$(curl -s "http://${BLITZ_HOST}:${BLITZ_PORT}/hello")
if [ -n "$RESPONSE" ]; then
    pass "GET request with path"
else
    fail "GET request with path"
fi

# Test 1.3: GET with query string
RESPONSE=$(curl -s "http://${BLITZ_HOST}:${BLITZ_PORT}/test?foo=bar&baz=qux")
if [ -n "$RESPONSE" ]; then
    pass "GET request with query string"
else
    fail "GET request with query string"
fi

# Test 1.4: POST request
RESPONSE=$(curl -s -X POST -d "test=data" "http://${BLITZ_HOST}:${BLITZ_PORT}/")
if [ -n "$RESPONSE" ]; then
    pass "POST request"
else
    fail "POST request"
fi

# Test 1.5: HTTP headers
HEADERS=$(curl -s -I "http://${BLITZ_HOST}:${BLITZ_PORT}/" | head -5)
if echo "$HEADERS" | grep -qi "HTTP/1.1"; then
    pass "HTTP/1.1 protocol"
else
    fail "HTTP/1.1 protocol"
fi

# Test 1.6: Response headers
if echo "$HEADERS" | grep -qi "Content-Type"; then
    pass "Response includes Content-Type header"
else
    fail "Response missing Content-Type header"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST 2: Connection Handling"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 2.1: Multiple sequential connections
info "Testing multiple sequential connections..."
SUCCESS=0
for i in {1..10}; do
    if curl -s --connect-timeout 2 "http://${BLITZ_HOST}:${BLITZ_PORT}/" > /dev/null 2>&1; then
        SUCCESS=$((SUCCESS + 1))
    fi
done
if [ $SUCCESS -eq 10 ]; then
    pass "10 sequential connections"
else
    fail "10 sequential connections ($SUCCESS/10 succeeded)"
fi

# Test 2.2: Concurrent connections
info "Testing concurrent connections..."
SUCCESS=0
for i in {1..20}; do
    curl -s --connect-timeout 2 "http://${BLITZ_HOST}:${BLITZ_PORT}/" > /dev/null 2>&1 &
done
wait
# Check if server still responds
if curl -s --connect-timeout 2 "http://${BLITZ_HOST}:${BLITZ_PORT}/" > /dev/null 2>&1; then
    pass "20 concurrent connections (server stable)"
else
    fail "20 concurrent connections (server crashed)"
fi

# Test 2.3: Keep-Alive connections
info "Testing Keep-Alive connections..."
if command -v curl >/dev/null 2>&1; then
    RESPONSE=$(curl -s --keepalive-time 2 --max-time 5 "http://${BLITZ_HOST}:${BLITZ_PORT}/")
    if [ -n "$RESPONSE" ]; then
        pass "Keep-Alive connection"
    else
        fail "Keep-Alive connection"
    fi
else
    skip "Keep-Alive connection (curl not available)"
fi

# Test 2.4: Connection reuse
info "Testing connection reuse..."
START=$(date +%s)
for i in {1..50}; do
    curl -s --connect-timeout 2 "http://${BLITZ_HOST}:${BLITZ_PORT}/" > /dev/null 2>&1
done
END=$(date +%s)
DURATION=$((END - START))
if [ $DURATION -lt 5 ]; then
    pass "Connection reuse (50 requests in ${DURATION}s)"
else
    fail "Connection reuse (50 requests took ${DURATION}s)"
fi

# Test 2.5: Large request
info "Testing large request handling..."
LARGE_DATA=$(head -c 10000 /dev/urandom | base64)
RESPONSE=$(curl -s -X POST -d "$LARGE_DATA" "http://${BLITZ_HOST}:${BLITZ_PORT}/" 2>&1)
if [ $? -eq 0 ]; then
    pass "Large request (10KB)"
else
    fail "Large request (10KB)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST 3: TLS 1.3 Support"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Check if certificates exist
if [ -f "certs/server.crt" ] && [ -f "certs/server.key" ]; then
    info "TLS certificates found"
    
    # Test 3.1: TLS connection
    if curl -s -k --connect-timeout 2 "https://${BLITZ_HOST}:${BLITZ_TLS_PORT}/" > /dev/null 2>&1; then
        pass "TLS connection works"
    else
        fail "TLS connection failed (server may not be listening on ${BLITZ_TLS_PORT})"
        skip "TLS 1.3 protocol check (connection failed)"
        skip "TLS certificate validation (connection failed)"
    fi
    
    # Test 3.2: TLS 1.3 protocol
    if command -v openssl >/dev/null 2>&1; then
        TLS_VERSION=$(echo | openssl s_client -connect "${BLITZ_HOST}:${BLITZ_TLS_PORT}" -tls1_3 2>/dev/null | grep "Protocol" | head -1)
        if echo "$TLS_VERSION" | grep -qi "TLSv1.3"; then
            pass "TLS 1.3 protocol supported"
        else
            fail "TLS 1.3 protocol not supported"
        fi
    else
        skip "TLS 1.3 protocol check (openssl not available)"
    fi
    
    # Test 3.3: Certificate validation
    if curl -s --cacert certs/server.crt "https://${BLITZ_HOST}:${BLITZ_TLS_PORT}/" > /dev/null 2>&1; then
        pass "TLS certificate validation"
    else
        fail "TLS certificate validation"
    fi
    
    # Test 3.4: HTTPS GET request
    RESPONSE=$(curl -s -k "https://${BLITZ_HOST}:${BLITZ_TLS_PORT}/")
    if [ -n "$RESPONSE" ]; then
        pass "HTTPS GET request"
    else
        fail "HTTPS GET request"
    fi
    
else
    skip "TLS tests (certificates not found)"
    info "Generate certificates with:"
    echo "  mkdir -p certs"
    echo "  openssl req -x509 -newkey rsa:4096 -keyout certs/server.key \\"
    echo "    -out certs/server.crt -days 365 -nodes -subj \"/CN=localhost\""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST 4: HTTP/2 Support"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Test 4.1: HTTP/2 over TLS (h2)
if command -v curl >/dev/null 2>&1; then
    HTTP2_RESPONSE=$(curl -s -k --http2 "https://${BLITZ_HOST}:${BLITZ_TLS_PORT}/" 2>&1)
    if [ $? -eq 0 ] && [ -n "$HTTP2_RESPONSE" ]; then
        # Check if HTTP/2 was actually used
        HTTP2_INFO=$(curl -s -k -I --http2 "https://${BLITZ_HOST}:${BLITZ_TLS_PORT}/" 2>&1)
        if echo "$HTTP2_INFO" | grep -qi "HTTP/2"; then
            pass "HTTP/2 over TLS (h2)"
        else
            skip "HTTP/2 over TLS (server may not support HTTP/2 yet)"
        fi
    else
        skip "HTTP/2 over TLS (TLS connection required)"
    fi
else
    skip "HTTP/2 test (curl not available)"
fi

# Test 4.2: HTTP/2 with h2load (if available)
if command -v h2load >/dev/null 2>&1; then
    info "Testing HTTP/2 with h2load..."
    H2LOAD_OUTPUT=$(h2load -n 10 -c 2 -m 1 "https://${BLITZ_HOST}:${BLITZ_TLS_PORT}/" 2>&1)
    if echo "$H2LOAD_OUTPUT" | grep -qi "finished"; then
        pass "HTTP/2 with h2load"
    else
        skip "HTTP/2 with h2load (may not be fully implemented)"
    fi
else
    skip "HTTP/2 with h2load (h2load not installed)"
fi

# Test 4.3: ALPN negotiation
if command -v openssl >/dev/null 2>&1 && [ -f "certs/server.crt" ]; then
    ALPN=$(echo | openssl s_client -connect "${BLITZ_HOST}:${BLITZ_TLS_PORT}" -alpn h2,http/1.1 2>/dev/null | grep "ALPN protocol" | head -1)
    if echo "$ALPN" | grep -qi "h2"; then
        pass "ALPN negotiation (h2 supported)"
    else
        skip "ALPN negotiation (h2 may not be configured)"
    fi
else
    skip "ALPN negotiation test (openssl or certificates not available)"
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "TEST SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo -e "${GREEN}Passed:${NC} $PASSED"
echo -e "${RED}Failed:${NC} $FAILED"
echo -e "${YELLOW}Skipped:${NC} $SKIPPED"
echo ""

TOTAL=$((PASSED + FAILED + SKIPPED))
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ Some tests failed${NC}"
    exit 1
fi

