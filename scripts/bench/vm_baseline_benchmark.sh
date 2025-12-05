#!/bin/bash

# vm_baseline_benchmark.sh - Complete baseline benchmarks for all protocols
# Run on 6-core ARM64 VM to establish baseline before EPYC deployment
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
RESULTS_DIR="/tmp/blitz_baseline_results"
BLITZ_BIN="/tmp/blitz"
JWT_SECRET="baseline-benchmark-secret-$(date +%s)"

# Test parameters (scaled for 6-core VM)
HTTP1_THREADS=6
HTTP1_CONNECTIONS=500
HTTP1_DURATION=30
HTTP1_TARGET_RPS=100000

HTTP2_THREADS=6
HTTP2_CONNECTIONS=500
HTTP2_DURATION=30
HTTP2_REQUESTS=500000

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Blitz Gateway - VM Baseline Benchmark Suite          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "Kernel: $(uname -r)"
echo "CPU Cores: $(nproc)"
echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
echo "Architecture: $(uname -m)"
echo ""

# Create results directory
mkdir -p "$RESULTS_DIR"
cd "$RESULTS_DIR"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"
    killall blitz 2>/dev/null || true
    sleep 2
}
trap cleanup EXIT

# Function to wait for server
wait_for_server() {
    local port=$1
    local protocol=$2
    local max_wait=10
    local count=0
    
    echo -n "Waiting for server on port $port ($protocol)..."
    while [ $count -lt $max_wait ]; do
        if [ "$protocol" = "UDP" ]; then
            if ss -ulnp | grep -q ":$port"; then
                echo -e " ${GREEN}✓${NC}"
                return 0
            fi
        else
            if ss -tlnp | grep -q ":$port"; then
                echo -e " ${GREEN}✓${NC}"
                return 0
            fi
        fi
        sleep 1
        count=$((count + 1))
        echo -n "."
    done
    echo -e " ${RED}✗ TIMEOUT${NC}"
    return 1
}

# Function to check if tools are installed
check_tools() {
    echo -e "${BLUE}Checking required tools...${NC}"
    
    local missing_tools=()
    
    if ! command -v wrk &> /dev/null; then
        missing_tools+=("wrk")
    fi
    
    if ! command -v h2load &> /dev/null; then
        missing_tools+=("h2load (nghttp2-client)")
    fi
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        echo -e "${RED}Missing tools:${NC} ${missing_tools[*]}"
        echo ""
        echo "Install with:"
        echo "  sudo apt install wrk nghttp2-client"
        exit 1
    fi
    
    echo -e "${GREEN}All tools available ✓${NC}"
    echo ""
}

# Check binary exists
if [ ! -f "$BLITZ_BIN" ]; then
    echo -e "${RED}Error: Blitz binary not found at $BLITZ_BIN${NC}"
    echo "Please ensure blitz is at /tmp/blitz"
    exit 1
fi

check_tools

#############################################################################
# TEST 1: HTTP/1.1 (Echo Mode)
#############################################################################

echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  TEST 1: HTTP/1.1 Baseline (Echo Mode)${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}\n"

cleanup
sleep 2

echo "Starting blitz in echo mode..."
JWT_SECRET="$JWT_SECRET" "$BLITZ_BIN" --mode echo > http1_server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

if ! wait_for_server 8080 TCP; then
    echo -e "${RED}Failed to start HTTP/1.1 server${NC}"
    echo "Server log:"
    cat http1_server.log
    exit 1
fi

echo ""
echo -e "${YELLOW}Test Configuration:${NC}"
echo "  Threads: $HTTP1_THREADS"
echo "  Connections: $HTTP1_CONNECTIONS"
echo "  Duration: ${HTTP1_DURATION}s"
echo "  Target RPS: $HTTP1_TARGET_RPS"
echo ""

# Simple connectivity test
echo "Testing connectivity..."
if curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/ | grep -q "200"; then
    echo -e "${GREEN}Connectivity test passed ✓${NC}"
else
    echo -e "${RED}Connectivity test failed ✗${NC}"
fi
echo ""

# Run benchmark
echo "Running HTTP/1.1 benchmark..."
echo ""

wrk -t${HTTP1_THREADS} -c${HTTP1_CONNECTIONS} -d${HTTP1_DURATION}s \
    --latency \
    http://127.0.0.1:8080/ \
    2>&1 | tee http1_baseline_results.txt

echo ""
echo -e "${GREEN}HTTP/1.1 test complete${NC}"

# Extract key metrics
HTTP1_RPS=$(grep "Requests/sec:" http1_baseline_results.txt | awk '{print $2}')
HTTP1_LATENCY_AVG=$(grep "Latency" http1_baseline_results.txt | head -1 | awk '{print $2}')
HTTP1_LATENCY_P99=$(grep "99%" http1_baseline_results.txt | awk '{print $2}')

echo ""
echo -e "${YELLOW}HTTP/1.1 Summary:${NC}"
echo "  RPS: $HTTP1_RPS"
echo "  Avg Latency: $HTTP1_LATENCY_AVG"
echo "  P99 Latency: $HTTP1_LATENCY_P99"

#############################################################################
# TEST 2: HTTP/2
#############################################################################

echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  TEST 2: HTTP/2 Baseline${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}\n"

cleanup
sleep 2

echo "Starting blitz in HTTP mode for HTTP/2 testing..."
JWT_SECRET="$JWT_SECRET" "$BLITZ_BIN" --mode http > http2_server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

if ! wait_for_server 8080 TCP; then
    echo -e "${RED}Failed to start HTTP/2 server${NC}"
    echo "Server log:"
    cat http2_server.log
    exit 1
fi

echo ""
echo -e "${YELLOW}Test Configuration:${NC}"
echo "  Threads: $HTTP2_THREADS"
echo "  Connections: $HTTP2_CONNECTIONS"
echo "  Duration: ${HTTP2_DURATION}s"
echo "  Total Requests: $HTTP2_REQUESTS"
echo ""

# Test /health endpoint
echo "Testing /health endpoint..."
if curl -s http://127.0.0.1:8080/health | grep -q "healthy"; then
    echo -e "${GREEN}Health check passed ✓${NC}"
else
    echo -e "${RED}Health check failed ✗${NC}"
fi
echo ""

# Run HTTP/2 benchmark
echo "Running HTTP/2 benchmark..."
echo ""

h2load -n ${HTTP2_REQUESTS} \
    -c ${HTTP2_CONNECTIONS} \
    -t ${HTTP2_THREADS} \
    -D ${HTTP2_DURATION}s \
    http://127.0.0.1:8080/health \
    2>&1 | tee http2_baseline_results.txt

echo ""
echo -e "${GREEN}HTTP/2 test complete${NC}"

# Extract key metrics
HTTP2_RPS=$(grep "requests/sec" http2_baseline_results.txt | head -1 | awk '{print $1}')
HTTP2_LATENCY_AVG=$(grep "time for request:" http2_baseline_results.txt | awk '{print $4}')
HTTP2_LATENCY_P99=$(grep "99%" http2_baseline_results.txt | tail -1 | awk '{print $2}')

echo ""
echo -e "${YELLOW}HTTP/2 Summary:${NC}"
echo "  RPS: $HTTP2_RPS"
echo "  Avg Latency: $HTTP2_LATENCY_AVG"
echo "  P99 Latency: $HTTP2_LATENCY_P99"

#############################################################################
# TEST 3: HTTP/3 (QUIC)
#############################################################################

echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  TEST 3: HTTP/3 (QUIC) Baseline${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}\n"

cleanup
sleep 2

echo "Starting blitz in QUIC mode (default)..."
"$BLITZ_BIN" > http3_server.log 2>&1 &
SERVER_PID=$!
echo "Server PID: $SERVER_PID"

if ! wait_for_server 8443 UDP; then
    echo -e "${RED}Failed to start QUIC server${NC}"
    echo "Server log:"
    cat http3_server.log
    exit 1
fi

echo ""
echo -e "${YELLOW}HTTP/3 Testing Status:${NC}"
echo ""

# Check if h2load supports HTTP/3
if h2load --help 2>&1 | grep -q "\-\-h3"; then
    echo -e "${GREEN}h2load supports HTTP/3 ✓${NC}"
    echo ""
    echo "Running HTTP/3 benchmark..."
    echo ""
    
    h2load -n ${HTTP2_REQUESTS} \
        -c ${HTTP2_CONNECTIONS} \
        -t ${HTTP2_THREADS} \
        -D ${HTTP2_DURATION}s \
        --h3 \
        https://127.0.0.1:8443/ \
        2>&1 | tee http3_baseline_results.txt
    
    echo ""
    echo -e "${GREEN}HTTP/3 test complete${NC}"
    
    HTTP3_RPS=$(grep "requests/sec" http3_baseline_results.txt | head -1 | awk '{print $1}')
    HTTP3_LATENCY_AVG=$(grep "time for request:" http3_baseline_results.txt | awk '{print $4}')
    HTTP3_LATENCY_P99=$(grep "99%" http3_baseline_results.txt | tail -1 | awk '{print $2}')
    
    echo ""
    echo -e "${YELLOW}HTTP/3 Summary:${NC}"
    echo "  RPS: $HTTP3_RPS"
    echo "  Avg Latency: $HTTP3_LATENCY_AVG"
    echo "  P99 Latency: $HTTP3_LATENCY_P99"
else
    echo -e "${YELLOW}h2load does not support HTTP/3 (--h3 flag)${NC}"
    echo "Ubuntu 22.04's nghttp2 is too old for HTTP/3 testing"
    echo ""
    echo -e "${BLUE}HTTP/3 Verification:${NC}"
    echo "  Server Status: Running ✓"
    echo "  UDP Port 8443: Listening ✓"
    echo "  Benchmark Tool: Not Available ✗"
    echo ""
    echo "Note: HTTP/3 will be properly benchmarked on EPYC with newer tools"
    
    # At least verify the server is stable
    echo ""
    echo "Running 30-second stability test..."
    sleep 30
    if ps -p $SERVER_PID > /dev/null; then
        echo -e "${GREEN}Server stable after 30 seconds ✓${NC}"
    else
        echo -e "${RED}Server crashed during stability test ✗${NC}"
    fi
fi

#############################################################################
# FINAL SUMMARY
#############################################################################

cleanup

echo -e "\n${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  VM Baseline Benchmark Results Summary                 ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}\n"

echo "Test Date: $(date)"
echo "Platform: $(uname -m) - $(nproc) cores - $(free -h | grep Mem | awk '{print $2}') RAM"
echo "Results Directory: $RESULTS_DIR"
echo ""

echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo -e "${YELLOW}  Protocol Performance Summary${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""

# Create summary table
{
    echo "| Protocol | RPS | Avg Latency | P99 Latency | Status |"
    echo "|----------|-----|-------------|-------------|--------|"
    
    if [ -n "${HTTP1_RPS:-}" ]; then
        echo "| HTTP/1.1 | $HTTP1_RPS | $HTTP1_LATENCY_AVG | $HTTP1_LATENCY_P99 | ✓ |"
    else
        echo "| HTTP/1.1 | - | - | - | ✗ |"
    fi
    
    if [ -n "${HTTP2_RPS:-}" ]; then
        echo "| HTTP/2   | $HTTP2_RPS | $HTTP2_LATENCY_AVG | $HTTP2_LATENCY_P99 | ✓ |"
    else
        echo "| HTTP/2   | - | - | - | ✗ |"
    fi
    
    if [ -n "${HTTP3_RPS:-}" ]; then
        echo "| HTTP/3   | $HTTP3_RPS | $HTTP3_LATENCY_AVG | $HTTP3_LATENCY_P99 | ✓ |"
    else
        echo "| HTTP/3   | Verified Running | - | - | ⚠ No Tool |"
    fi
} | column -t -s '|'

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════${NC}"
echo ""

# Save summary to file
cat > baseline_summary.txt << EOF
Blitz Gateway - VM Baseline Benchmark Results
==============================================
Date: $(date)
Platform: $(uname -m)
CPU Cores: $(nproc)
Memory: $(free -h | grep Mem | awk '{print $2}')
Kernel: $(uname -r)

Results:
--------
HTTP/1.1: ${HTTP1_RPS:-N/A} RPS, ${HTTP1_LATENCY_P99:-N/A} p99 latency
HTTP/2:   ${HTTP2_RPS:-N/A} RPS, ${HTTP2_LATENCY_P99:-N/A} p99 latency
HTTP/3:   ${HTTP3_RPS:-Not Tested} RPS (tool unavailable)

Files:
------
- http1_baseline_results.txt  : Full HTTP/1.1 results
- http2_baseline_results.txt  : Full HTTP/2 results
- http3_baseline_results.txt  : Full HTTP/3 results (if available)
- http1_server.log            : HTTP/1.1 server log
- http2_server.log            : HTTP/2 server log
- http3_server.log            : HTTP/3 server log
- baseline_summary.txt        : This summary

Next Steps:
-----------
1. Review detailed results in $RESULTS_DIR
2. Fix any failed tests
3. Rebuild for x86_64 architecture
4. Deploy to EPYC 9754
5. Run full EPYC benchmarks

Target Performance (EPYC 9754):
--------------------------------
HTTP/1.1: 12M+ RPS, <50µs p99
HTTP/2:   10M+ RPS, <80µs p99
HTTP/3:   8M+ RPS,  <120µs p99
EOF

echo -e "${GREEN}Summary saved to: baseline_summary.txt${NC}"
echo ""
echo -e "${BLUE}All baseline benchmarks complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Review results: cat $RESULTS_DIR/baseline_summary.txt"
echo "  2. Check detailed logs: ls -lh $RESULTS_DIR/"
echo "  3. Fix any failures before EPYC deployment"
echo ""

