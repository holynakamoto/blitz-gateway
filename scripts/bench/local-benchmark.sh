#!/bin/bash
# Quick local benchmark script for development
# Use this on your local machine before running full benchmarks on bare metal

set -e

BLITZ_PORT="${BLITZ_PORT:-8080}"
DURATION="${DURATION:-30}"

echo "=========================================="
echo "Blitz Local Benchmark (Development)"
echo "=========================================="
echo "Target: http://localhost:${BLITZ_PORT}"
echo "Duration: ${DURATION}s"
echo ""
echo "NOTE: This is for local development testing."
echo "For production benchmarks, use benches/reproduce.sh on bare metal."
echo ""

# Check if Blitz is running
if ! curl -s http://localhost:${BLITZ_PORT}/ > /dev/null; then
    echo "ERROR: Blitz is not running on port ${BLITZ_PORT}"
    echo ""
    echo "NOTE: Blitz requires Linux (io_uring is Linux-only)"
    echo ""
    echo "Options:"
    echo "  1. Use Docker: docker run --network host blitz:latest"
    echo "  2. Use Linux VM (Ubuntu 24.04+)"
    echo "  3. Test on bare metal Linux server"
    echo ""
    echo "See benches/DOCKER-TESTING.md for details"
    exit 1
fi

# Check prerequisites
if ! command -v wrk2 >/dev/null 2>&1; then
    echo "ERROR: wrk2 not found"
    echo "Install from: https://github.com/giltene/wrk2"
    echo "Or use: brew install wrk2 (macOS)"
    exit 1
fi

# Create benches directory if it doesn't exist
mkdir -p benches

echo "=========================================="
echo "Test 1: Latency Distribution (p99 focus)"
echo "=========================================="
echo "Running wrk latency test..."
echo ""

wrk -t 4 -c 1000 -d ${DURATION}s --latency \
  http://localhost:${BLITZ_PORT}/ | tee benches/local-latency.txt

echo ""
echo "=========================================="
echo "Test 2: Rate-Limited RPS Test"
echo "=========================================="
echo "Running wrk2 with 1M RPS target..."
echo ""

wrk2 -t 4 -c 10000 -d ${DURATION}s -R 1000000 \
  --latency --timeout 10s \
  http://localhost:${BLITZ_PORT}/ | tee benches/local-rps.txt

echo ""
echo "=========================================="
echo "Test 3: Simple Hey Test (if available)"
echo "=========================================="
if command -v hey >/dev/null 2>&1; then
    hey -n 100000 -c 100 -m GET http://localhost:${BLITZ_PORT}/ | tee benches/local-hey.txt
else
    echo "Skipped (hey not installed)"
    echo "Install with: go install github.com/rakyll/hey@latest"
fi

echo ""
echo "=========================================="
echo "Local Benchmark Complete!"
echo "=========================================="
echo "Results saved to benches/ directory"
echo ""
echo "Review:"
echo "  - benches/local-latency.txt (p99 latency)"
echo "  - benches/local-rps.txt (throughput)"
echo ""
echo "For production benchmarks on bare metal, see:"
echo "  - benches/reproduce.sh"
echo "  - benches/benchmark-machine-spec.md"
echo ""

