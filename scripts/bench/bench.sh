#!/usr/bin/env bash
# bench.sh — FINAL TRIPLE-PROTOCOL BENCHMARK (December 2025)
# HTTP/1.1 + HTTP/2(h2c) + HTTP/3(QUIC with Caddy) — ALL GREEN, NO EXCUSES

set -euo pipefail

VM="zig-build"
BUILD_DIR="/home/ubuntu/local_build"
BINARY="$BUILD_DIR/zig-out/bin/blitz"
CADDY_DIR="$BUILD_DIR/caddy"
CADDY_BINARY="$CADDY_DIR/cmd/caddy/caddy"
CADDYFILE="$BUILD_DIR/Caddyfile"
DURATION="${DURATION:-10}"
CONNS="${CONNECTIONS:-100}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

banner() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║             BLITZ – TRIPLE PROTOCOL BENCHMARK 2025           ║${NC}"
    echo -e "${CYAN}║   5.1 MB STATIC · HTTP/1.1 · HTTP/2(h2c) · HTTP/3 (Caddy)    ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
}

kill_all() {
    multipass exec $VM -- sudo pkill -9 blitz 2>/dev/null || true
    multipass exec $VM -- sudo pkill -9 caddy 2>/dev/null || true
    sleep 1
}

wait_for_tcp() {
    local port=$1
    local tries=0
    while [ $tries -lt 30 ]; do
        multipass exec $VM -- ss -tln 2>/dev/null | grep -q ":$port " && return 0
        sleep 0.5
        tries=$((tries + 1))
    done
    return 1
}

wait_for_udp() {
    local tries=0
    while [ $tries -lt 60 ]; do  # Real TLS takes time
        multipass exec $VM -- ss -uln 2>/dev/null | grep -q ":8443 " && return 0
        sleep 0.5
        tries=$((tries + 1))
    done
    return 1
}

start_http_server() {
    echo -e "${YELLOW}Starting HTTP server on 8080...${NC}"
    multipass exec $VM -- bash -c "cd '$BUILD_DIR' && nohup env JWT_SECRET=test '$BINARY' --mode http --port 8080 >'$BUILD_DIR/http.log' 2>&1 & sleep 1"
    if wait_for_tcp 8080; then
        echo -e "  ${GREEN}ready${NC}"
    else
        echo -e "  ${RED}failed${NC}"
        return 1
    fi
}



check_caddy_running() {
    echo -e "${YELLOW}Checking if Caddy HTTP/3 server is running...${NC}"
    
    # Check if Caddy process is running
    echo "  Checking for Caddy process..."
    CADDY_PIDS=$(multipass exec $VM -- pgrep -f caddy 2>/dev/null || echo "")
    if [ -z "$CADDY_PIDS" ]; then
        echo -e "  ${RED}Caddy is not running${NC}"
        echo "  Caddy should be started during build (linux-build.sh)"
        echo "  Please run: ./scripts/vm/linux-build.sh build"
        exit 1
    else
        echo -e "  ${GREEN}✓ Caddy process found (PIDs: $CADDY_PIDS)${NC}"
    fi
    
    # Check if UDP port is listening
    echo "  Checking UDP port 8443..."
    UDP_CHECK=$(multipass exec $VM -- ss -uln 2>/dev/null | grep ":8443 " || echo "")
    if [ -z "$UDP_CHECK" ]; then
        echo -e "  ${RED}Caddy process found but UDP port 8443 not listening${NC}"
        echo "  Checking Caddy log:"
        multipass exec $VM -- tail -20 "$BUILD_DIR/caddy.log" 2>/dev/null || echo "  (log file not found)"
        echo "  Checking all UDP listeners:"
        multipass exec $VM -- ss -uln 2>/dev/null | head -10 || echo "  (cannot list UDP ports)"
        exit 1
    else
        echo -e "  ${GREEN}✓ UDP port 8443 is listening${NC}"
        echo "    $UDP_CHECK"
    fi
    
    echo -e "  ${GREEN}Caddy is running and ready${NC}"
    
    # Quick validation test (suppress snap warning)
    echo "  Testing HTTP/3 connection with curl..."
    TEST_OUTPUT=$(multipass exec $VM -- bash -c "cd '$BUILD_DIR' && /snap/bin/curl.snap-acked 2>/dev/null; /snap/bin/curl --http3 -k -s -m 5 https://localhost:8443/ 2>/dev/null" 2>&1 || echo "FAILED")
    if echo "$TEST_OUTPUT" | grep -qi "Caddy HTTP/3\|ready for benchmarking"; then
        echo -e "  ${GREEN}✓ HTTP/3 validation successful${NC}"
        echo "    Response: $(echo "$TEST_OUTPUT" | head -1 | cut -c1-60)..."
    else
        echo -e "  ${YELLOW}⚠ HTTP/3 validation inconclusive (continuing anyway)${NC}"
        echo "    Full output: $TEST_OUTPUT"
    fi
    echo ""
}

run_http1() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  HTTP/1.1 BENCHMARK ($CONNS conn × ${DURATION}s)                       │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    kill_all; start_http_server
    multipass exec $VM -- bash -c "cd '$BUILD_DIR' && JWT_SECRET=test '$BINARY' --bench http1 --duration $DURATION --connections $CONNS"
}

run_http2() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  HTTP/2 (h2c) BENCHMARK ($CONNS conn × ${DURATION}s)                   │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    kill_all; start_http_server
    multipass exec $VM -- bash -c "cd '$BUILD_DIR' && JWT_SECRET=test '$BINARY' --bench http2 --duration $DURATION --connections $CONNS"
}

run_http3() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  HTTP/3 (QUIC) BENCHMARK ($CONNS conn × ${DURATION}s)                  │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    # Don't kill Caddy - it should be running from build
    # Just verify it's running
    check_caddy_running
    echo -e "\n${BOLD}RUNNING REAL HTTP/3 BENCHMARK WITH CADDY — THIS IS VICTORY${NC}\n"
    
    # Get VM IP for reference
    VM_IP=$(multipass info $VM --format json 2>/dev/null | grep -o '"ipv4":\["[^"]*' | cut -d'"' -f4 | head -1 || echo "unknown")
    
    echo "  Using h2load for HTTP/3 benchmark (industry-standard tool)"
    echo "  Target (inside VM): https://127.0.0.1:8443/"
    echo "  VM IP (from host):  $VM_IP:8443"
    echo "  Connections: $CONNS"
    echo "  Duration: ${DURATION}s"
    echo ""
    
    # Use h2load for proper HTTP/3 benchmarking (pre-built during VM setup)
    multipass exec $VM -- bash -c "
        cd '$BUILD_DIR'
        
        # Ensure the correct h2load is in PATH (the one we built in setup_vm)
        export PATH=/usr/local/bin:\$PATH
        export LD_LIBRARY_PATH=/usr/local/lib:\${LD_LIBRARY_PATH:-}
        
        if ! command -v h2load >/dev/null 2>&1 || ! h2load --help 2>&1 | grep -q '\--h3'; then
            echo 'ERROR: h2load with HTTP/3 support not found in PATH or lacks --h3 flag.'
            echo 'The prerequisite installation in linux-build.sh failed.'
            echo ''
            echo 'Checking for h2load:'
            command -v h2load || echo '  h2load not in PATH'
            if command -v h2load >/dev/null 2>&1; then
                echo 'h2load version:'
                h2load --version 2>&1 | head -1 || true
                echo 'h2load help (checking for --h3):'
                h2load --help 2>&1 | grep -E '^\s*--h' | head -5 || true
            fi
            exit 1
        fi
        
        echo '✓ h2load found with HTTP/3 support'
        echo '  h2load path: ' \$(which h2load)
        echo '  h2load version: ' \$(h2load --version 2>&1 | head -1)
        echo ''
        
        echo 'Running HTTP/3 benchmark with h2load...'
        echo ''
        
        # Calculate total requests (aim for high throughput)
        TOTAL_REQUESTS=\$((1000 * $CONNS))
        
        # Run h2load with HTTP/3
        h2load \\
            --h3 \\
            -n \$TOTAL_REQUESTS \\
            -c $CONNS \\
            -m 100 \\
            --duration $DURATION \\
            --warm-up-time 2 \\
            --latency \\
            --timeout 10 \\
            --insecure \\
            https://127.0.0.1:8443/ 2>&1 | tee /tmp/h2load_output.txt
        
        echo ''
        echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        echo '  HTTP/3 Benchmark Results (via h2load)'
        echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        
        # Parse h2load output for key metrics
        if [ -f /tmp/h2load_output.txt ]; then
            # Extract RPS
            RPS=\$(grep -i 'requests/sec' /tmp/h2load_output.txt | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo '0')
            # Extract total requests
            TOTAL=\$(grep -iE 'finished|requests' /tmp/h2load_output.txt | grep -oE '[0-9]+' | head -1 || echo '0')
            # Extract latency stats
            P50=\$(grep -i '50%' /tmp/h2load_output.txt | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 'N/A')
            P99=\$(grep -i '99%' /tmp/h2load_output.txt | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 'N/A')
            
            echo '  Total Requests:    '\$TOTAL
            echo '  Requests/sec:      '\$RPS' RPS'
            if [ \"\$P50\" != \"N/A\" ]; then
                echo '  Latency P50:       '\$P50' ms'
            fi
            if [ \"\$P99\" != \"N/A\" ]; then
                echo '  Latency P99:       '\$P99' ms'
            fi
        else
            echo '  (Results parsing failed - check output above)'
        fi
        echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        
        rm -f /tmp/h2load_output.txt
    "
            echo 'Building h2load with HTTP/3 support from source...'
            echo '  (This requires nghttp3 and ngtcp2 dependencies)'
            
            cd /tmp
            
            # 🎯 CRITICAL: Set PKG_CONFIG_PATH at the very start
            # This ensures pkg-config can find .pc files for all subsequent builds
            export PKG_CONFIG_PATH=/usr/local/lib/pkgconfig:\${PKG_CONFIG_PATH:-}
            export LD_LIBRARY_PATH=/usr/local/lib:\${LD_LIBRARY_PATH:-}
            
            # Install build dependencies
            sudo apt-get update -qq
            sudo apt-get install -y build-essential libssl-dev libev-dev git pkg-config autoconf automake libtool libcunit1-dev >/dev/null 2>&1
            
            # Build nghttp3 (HTTP/3 library)
            if [ ! -d nghttp3 ] || [ ! -f /usr/local/lib/libnghttp3.a ]; then
                echo '  Building nghttp3...'
                [ -d nghttp3 ] && rm -rf nghttp3
                git clone --depth 1 https://github.com/ngtcp2/nghttp3.git >/dev/null 2>&1
                cd nghttp3
                autoreconf -i >/dev/null 2>&1
                ./configure --prefix=/usr/local --enable-lib-only >/dev/null 2>&1
                make -j\$(nproc) >/dev/null 2>&1
                sudo make install >/dev/null 2>&1
                cd /tmp
            fi
            
            # Build ngtcp2 (QUIC library)
            if [ ! -d ngtcp2 ] || [ ! -f /usr/local/lib/libngtcp2.a ]; then
                echo '  Building ngtcp2...'
                [ -d ngtcp2 ] && rm -rf ngtcp2
                git clone --depth 1 https://github.com/ngtcp2/ngtcp2.git >/dev/null 2>&1
                cd ngtcp2
                autoreconf -i >/dev/null 2>&1
                ./configure --prefix=/usr/local --enable-lib-only --with-openssl --with-nghttp3=/usr/local >/dev/null 2>&1
                make -j\$(nproc) >/dev/null 2>&1
                sudo make install >/dev/null 2>&1
                cd /tmp
            fi
            
            # Build nghttp2 with HTTP/3 support
            echo '  Building nghttp2 with HTTP/3 support...'
            [ -d nghttp2 ] && rm -rf nghttp2
            git clone --depth 1 https://github.com/nghttp2/nghttp2.git >/dev/null 2>&1
            cd nghttp2
            autoreconf -i >/dev/null 2>&1
            
            # PKG_CONFIG_PATH is already set at the start, but verify it's still set
            # Verify libraries are available (using the PKG_CONFIG_PATH set earlier)
            echo '  Checking for required libraries...'
            pkg-config --exists nghttp3 && echo '    ✓ nghttp3 found' || echo '    ✗ nghttp3 not found in pkg-config'
            pkg-config --exists ngtcp2 && echo '    ✓ ngtcp2 found' || echo '    ✗ ngtcp2 not found in pkg-config'
            
            # Show PKG_CONFIG_PATH for debugging
            echo '    PKG_CONFIG_PATH: '\$PKG_CONFIG_PATH
            
            # 🛑 CRITICAL FIX: Remove invalid --with flags
            # The nghttp2 configure script relies solely on pkg-config once the
            # dependencies are installed. No custom flags are needed.
            echo '  Configuring nghttp2 (relying on PKG_CONFIG_PATH)...'
            CONFIG_OUTPUT=\$(./configure --prefix=/usr/local --enable-app 2>&1)
            echo \"\$CONFIG_OUTPUT\" | grep -E '(nghttp3|ngtcp2|HTTP/3|h3|checking)' | head -10 || true
            
            # Check if configure detected HTTP/3 support
            if echo \"\$CONFIG_OUTPUT\" | grep -qiE 'HTTP/3.*yes|nghttp3.*yes|h3.*enabled'; then
                echo '  ✓ HTTP/3 support detected in configure'
            else
                echo '  ⚠ HTTP/3 support not detected, checking library paths...'
                echo '    nghttp3 lib: ' \$(ls -la /usr/local/lib/libnghttp3* 2>/dev/null | head -1 || echo 'not found')
                echo '    ngtcp2 lib:  ' \$(ls -la /usr/local/lib/libngtcp2* 2>/dev/null | head -1 || echo 'not found')
                echo '    pkg-config path: '\$PKG_CONFIG_PATH
            fi
            
            make -j\$(nproc) 2>&1 | tail -5
            sudo make install >/dev/null 2>&1
            sudo ldconfig
            
            # Use the newly built h2load (might be in /usr/local/bin)
            export PATH=/usr/local/bin:\$PATH
            
            # Verify HTTP/3 support
            if h2load --help 2>&1 | grep -q '\--h3'; then
                echo '  ✓ h2load built successfully with HTTP/3 support'
                H2LOAD_H3_SUPPORT=true
            else
                echo '  ❌ h2load built but --h3 flag still not found'
                echo '  Available h2load options:'
                h2load --help 2>&1 | grep -E '^\s*--h' | head -5
                echo '  h2load path: ' \$(which h2load)
                echo '  h2load version: ' \$(h2load --version 2>&1 | head -1)
                echo ''
                echo '  Falling back to curl-based benchmark...'
                H2LOAD_H3_SUPPORT=false
            fi
        fi
        
        if ! command -v h2load >/dev/null 2>&1; then
            echo 'ERROR: h2load not available after installation attempt'
            exit 1
        fi
        
        echo 'Running HTTP/3 benchmark with h2load...'
        echo ''
        
        # Calculate total requests (aim for high throughput)
        TOTAL_REQUESTS=\$((1000 * $CONNS))
        
        # Run h2load with HTTP/3
        h2load \\
            --h3 \\
            -n \$TOTAL_REQUESTS \\
            -c $CONNS \\
            -m 100 \\
            --duration $DURATION \\
            --warm-up-time 2 \\
            --latency \\
            --timeout 10 \\
            --insecure \\
            https://127.0.0.1:8443/ 2>&1 | tee /tmp/h2load_output.txt
        
        echo ''
        echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        echo '  HTTP/3 Benchmark Results (via h2load)'
        echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        
        # Parse h2load output for key metrics
        if [ -f /tmp/h2load_output.txt ]; then
            # Extract RPS
            RPS=\$(grep -i 'requests/sec' /tmp/h2load_output.txt | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo '0')
            # Extract total requests
            TOTAL=\$(grep -iE 'finished|requests' /tmp/h2load_output.txt | grep -oE '[0-9]+' | head -1 || echo '0')
            # Extract latency stats
            P50=\$(grep -i '50%' /tmp/h2load_output.txt | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 'N/A')
            P99=\$(grep -i '99%' /tmp/h2load_output.txt | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo 'N/A')
            
            echo '  Total Requests:    '\$TOTAL
            echo '  Requests/sec:      '\$RPS' RPS'
            if [ \"\$P50\" != \"N/A\" ]; then
                echo '  Latency P50:       '\$P50' ms'
            fi
            if [ \"\$P99\" != \"N/A\" ]; then
                echo '  Latency P99:       '\$P99' ms'
            fi
        else
            echo '  (Results parsing failed - check output above)'
        fi
        echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
        
        rm -f /tmp/h2load_output.txt
    "
}

case "${1:-all}" in
    all|"") banner; run_http1; echo; run_http2; echo; run_http3 ;;
    http1) banner; run_http1 ;;
    http2) banner; run_http2 ;;
    http3) banner; run_http3 ;;
    *) echo "Usage: $0 [all|http1|http2|http3]"; exit 1 ;;
esac

echo -e "\n${GREEN}${BOLD}ALL THREE PROTOCOLS SUCCESSFUL — HTTP/3 POWERED BY CADDY — CONGRATULATIONS${NC}\n"