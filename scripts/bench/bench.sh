#!/usr/bin/env bash
# bench.sh — FINAL TRIPLE-PROTOCOL BENCHMARK (December 2025)
# Tests HTTP/1.1 · HTTP/2(h2c) · HTTP/3(raw QUIC) independently

set -euo pipefail

VM="zig-build"
BUILD_DIR="/home/ubuntu/local_build"
BINARY="$BUILD_DIR/zig-out/bin/blitz"
DURATION="${DURATION:-10}"
CONNS="${CONNECTIONS:-100}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

banner() {
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗"
    echo "║             BLITZ – TRIPLE PROTOCOL BENCHMARK 2025           ║"
    echo "║      5.1 MB STATIC · HTTP/1.1 · HTTP/2(h2c) · HTTP/3 RAW      ║"
    echo -e "╚══════════════════════════════════════════════════════════════╝${NC}"
}

kill_all() { 
    multipass exec $VM -- sudo pkill -9 blitz 2>/dev/null || true
    sleep 1
}

wait_for_server() {
    local port=$1
    local max_wait=10
    local count=0
    while [ $count -lt $max_wait ]; do
        if multipass exec $VM -- ss -tln 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

wait_for_udp() {
    local port=$1
    local max_wait=10
    local count=0
    while [ $count -lt $max_wait ]; do
        if multipass exec $VM -- ss -uln 2>/dev/null | grep -q ":$port "; then
            return 0
        fi
        sleep 1
        count=$((count + 1))
    done
    return 1
}

start_http_server() {
    echo -e "${YELLOW}Starting HTTP server on 8080...${NC}"
    # Use nohup with proper detachment
    multipass exec $VM -- bash -c "cd $BUILD_DIR && nohup env JWT_SECRET=test $BINARY --mode http --port 8080 >http.log 2>&1 &
sleep 1
disown -a"
    sleep 2
    
    echo -n "  Waiting for server..."
    if wait_for_server 8080; then
        echo -e " ${GREEN}ready${NC}"
    else
        echo -e " ${RED}failed to start${NC}"
        multipass exec $VM -- cat $BUILD_DIR/http.log 2>/dev/null | tail -5 || true
        return 1
    fi
}

start_quic_server() {
    echo -e "${YELLOW}Starting QUIC server on 8443...${NC}"
    multipass exec $VM -- bash -c "cd $BUILD_DIR && nohup $BINARY --mode quic --port 8443 >quic.log 2>&1 &
sleep 1
disown -a"
    sleep 2
    
    echo -n "  Waiting for server..."
    if wait_for_udp 8443; then
        echo -e " ${GREEN}ready${NC}"
    else
        echo -e " ${RED}failed to start${NC}"
        multipass exec $VM -- cat $BUILD_DIR/quic.log 2>/dev/null | tail -5 || true
        return 1
    fi
}

smoke() {
    IP=$(multipass info $VM | grep IPv4 | awk '{print $2}')
    echo -e "\n${BOLD}Connectivity check (host → $IP):${NC}"
    
    # Check HTTP
    if curl -s --connect-timeout 3 http://$IP:8080/ >/dev/null 2>&1; then
        echo -e "${GREEN}   ✓ HTTP/1.1 + h2c OK${NC}"
    else
        echo -e "${RED}   ✗ HTTP failed${NC}"
    fi
    
    # Check QUIC
    if multipass exec $VM -- ss -uln 2>/dev/null | grep -q ":8443 "; then
        echo -e "${GREEN}   ✓ QUIC UDP 8443 listening${NC}"
    else
        echo -e "${RED}   ✗ QUIC not listening${NC}"
    fi
}

run_http1() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  HTTP/1.1 BENCHMARK ($CONNS conn × ${DURATION}s)                       │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    kill_all
    start_http_server || return 1
    echo ""
    multipass exec $VM -- bash -c "cd $BUILD_DIR && JWT_SECRET=test $BINARY --bench http1 --duration $DURATION --connections $CONNS"
}

run_http2() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  HTTP/2 (h2c) BENCHMARK ($CONNS conn × ${DURATION}s)                   │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    kill_all
    start_http_server || return 1
    echo ""
    multipass exec $VM -- bash -c "cd $BUILD_DIR && JWT_SECRET=test $BINARY --bench http2 --duration $DURATION --connections $CONNS"
}

run_http3() {
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  HTTP/3 (QUIC) BENCHMARK ($CONNS conn × ${DURATION}s)                  │${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────┘${NC}"
    kill_all
    start_quic_server || return 1
    echo ""
    multipass exec $VM -- bash -c "cd $BUILD_DIR && $BINARY --bench http3 --duration $DURATION --connections $CONNS --port 8443"
}

run_all() {
    banner
    echo -e "${BOLD}Running all three protocols independently...${NC}"
    echo ""
    
    run_http1
    kill_all
    echo ""
    
    run_http2
    kill_all
    echo ""
    
    run_http3
    
    smoke
    kill_all
    
    echo ""
    echo -e "${GREEN}✓ All benchmarks complete${NC}"
}

case "${1:-all}" in
    all|"") run_all ;;
    http1)  banner; run_http1; smoke; kill_all ;;
    http2)  banner; run_http2; smoke; kill_all ;;
    http3)  banner; run_http3; smoke; kill_all ;;
    smoke)  banner; kill_all; start_http_server; start_quic_server; smoke; kill_all ;;
    kill)   kill_all; echo "All killed" ;;
    *)      echo "Usage: $0 [all|http1|http2|http3|smoke|kill]"; exit 1 ;;
esac
