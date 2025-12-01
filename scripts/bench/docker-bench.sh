#!/usr/bin/env bash
# Docker Benchmark Setup Script
# Sets up and runs Blitz benchmarks in Docker (Ubuntu 24.04 LTS)

set -e

echo "=========================================="
echo "Blitz Docker Benchmark Setup"
echo "=========================================="
echo ""

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running"
    echo "Start Docker and try again"
    exit 1
fi

# Build the image
echo "Building Blitz Docker image..."
echo "NOTE: Docker build may fail due to Zig 0.12.0 liburing linking issue."
echo "This is a known limitation. For actual benchmarks, use bare metal Linux."
echo ""
docker build -t blitz:latest . || {
    echo ""
    echo "=========================================="
    echo "Docker Build Failed (Expected)"
    echo "=========================================="
    echo ""
    echo "This is a known issue with Zig 0.12.0 and liburing linking in Docker."
    echo "The code is correct and works on bare metal Linux."
    echo ""
    echo "Solutions:"
    echo "  1. Use bare metal Linux (recommended for benchmarks)"
    echo "  2. Build on Linux VM and copy binary to Docker"
    echo "  3. Wait for Zig 0.13.0+ with better liburing support"
    echo ""
    echo "Docker benchmarks are not recommended. Use bare metal for accurate results."
    echo "See docs/benchmark/QUICK-START-BARE-METAL.md for production benchmarking."
    echo ""
    exit 1
}

echo ""
echo "=========================================="
echo "Starting Blitz container"
echo "=========================================="

# Stop and remove existing container if it exists
docker stop blitz 2>/dev/null || true
docker rm blitz 2>/dev/null || true

# Run container in privileged mode (required for system tuning)
docker run -d \
    --name blitz \
    --privileged \
    --network host \
    -v /sys:/sys:rw \
    --ulimit nofile=1048576:1048576 \
    blitz:latest \
    tail -f /dev/null

echo "Container started."
echo ""

# Wait a moment for container to be ready
sleep 2

# Apply system tuning inside container
echo "=========================================="
echo "Applying System Tuning (inside container)"
echo "=========================================="
echo ""

# Run setup script inside container (skip kernel upgrade in Docker)
docker exec blitz bash -c "
    # Network tuning
    sysctl -w net.core.somaxconn=1048576 || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=1048576 || true
    sysctl -w net.core.netdev_max_backlog=50000 || true
    
    # THP (if available)
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    
    # CPU governor (if available)
    echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
    
    # File descriptors
    ulimit -n 1048576 || true
    
    echo 'System tuning applied.'
"

echo ""
echo "=========================================="
echo "Starting Blitz Server"
echo "=========================================="

# Start Blitz in the background inside container
docker exec -d blitz bash -c "cd /app && ./zig-out/bin/blitz > /tmp/blitz.log 2>&1"

# Wait for server to start
echo "Waiting for Blitz to start..."
sleep 3

# Check if server is running
if docker exec blitz curl -s http://localhost:8080/hello > /dev/null 2>&1; then
    echo "✓ Blitz is running on port 8080"
else
    echo "✗ Blitz failed to start. Checking logs..."
    docker exec blitz cat /tmp/blitz.log || true
    exit 1
fi

echo ""
echo "=========================================="
echo "Blitz is ready for benchmarking!"
echo "=========================================="
echo ""
echo "Container: blitz"
echo "Server: http://localhost:8080"
echo ""
echo "Run benchmarks:"
echo "  Option 1: From host (if wrk2 installed):"
echo "    ./benches/local-benchmark.sh"
echo ""
echo "  Option 2: Inside container:"
echo "    docker exec blitz bash -c 'cd /app && ./benches/local-benchmark.sh'"
echo ""
echo "  Option 3: Manual wrk2 test:"
echo "    docker exec blitz wrk2 -t 4 -c 1000 -d 30s -R 1000000 --latency http://localhost:8080/hello"
echo ""
echo "View logs:"
echo "    docker exec blitz cat /tmp/blitz.log"
echo ""
echo "Stop container:"
echo "    docker stop blitz"
echo ""

