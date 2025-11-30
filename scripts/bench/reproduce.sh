#!/bin/bash
# Blitz Benchmark Reproduction Script
# Run this on a bare-metal server with proper hardware (see benchmark-machine-spec.md)

set -e

BLITZ_IP="${BLITZ_IP:-localhost}"
BLITZ_PORT="${BLITZ_PORT:-8080}"
DURATION="${DURATION:-60}"
RATE="${RATE:-10000000}"  # 10M RPS default

echo "=========================================="
echo "Blitz Benchmark Suite"
echo "=========================================="
echo "Target: http://${BLITZ_IP}:${BLITZ_PORT}"
echo "Duration: ${DURATION}s"
echo "Rate: ${RATE} RPS"
echo ""

# Check prerequisites
command -v wrk2 >/dev/null 2>&1 || { echo "ERROR: wrk2 not found. Install from https://github.com/giltene/wrk2"; exit 1; }
command -v hey >/dev/null 2>&1 || { echo "WARNING: hey not found. Install with: go install github.com/rakyll/hey@latest"; }

# System tuning (requires root)
if [ "$EUID" -eq 0 ]; then
    echo "Applying basic system tuning..."
    sysctl -w net.core.somaxconn=1048576 >/dev/null 2>&1 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=1048576 >/dev/null 2>&1 || true
    sysctl -w net.core.netdev_max_backlog=50000 >/dev/null 2>&1 || true
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor >/dev/null 2>&1 || true
    echo never > /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
    echo "Basic system tuning applied."
    echo ""
    echo "NOTE: For maximum performance, run the full setup script:"
    echo "  sudo ./scripts/bench-box-setup.sh"
    echo "  (or: curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/bench-box-setup.sh | sudo bash)"
else
    echo "WARNING: Not running as root. System tuning skipped."
    echo "For best results, run with sudo or run: sudo ./scripts/bench-box-setup.sh"
fi

echo ""
echo "=========================================="
echo "Test 1: HTTP/1.1 Keep-Alive (High RPS)"
echo "=========================================="
echo "Running wrk2 with ${RATE} RPS target..."
echo ""

wrk2 -t 128 -c 200000 -d ${DURATION}s -R ${RATE} \
  --latency --timeout 10s \
  http://${BLITZ_IP}:${BLITZ_PORT}/ | tee benches/http1-wrk2.txt

echo ""
echo "=========================================="
echo "Test 2: Latency Distribution (p99 focus)"
echo "=========================================="
echo "Running wrk2 latency test..."
echo ""

wrk -t 128 -c 10000 -d 30s --latency \
  http://${BLITZ_IP}:${BLITZ_PORT}/ | tee benches/latency-wrk.txt

echo ""
echo "=========================================="
echo "Test 3: Simple Hey Test (pretty output)"
echo "=========================================="
if command -v hey >/dev/null 2>&1; then
    hey -n 1000000 -c 1000 -m GET http://${BLITZ_IP}:${BLITZ_PORT}/ | tee benches/hey-simple.txt
else
    echo "Skipped (hey not installed)"
fi

echo ""
echo "=========================================="
echo "Benchmark Complete!"
echo "=========================================="
echo "Results saved to benches/ directory"
echo ""
echo "Next steps:"
echo "1. Review benches/http1-wrk2.txt for RPS and latency"
echo "2. Review benches/latency-wrk.txt for p99/p99.9/p99.99"
echo "3. Compare against benchmarks/COMPARISON.md"
echo ""

