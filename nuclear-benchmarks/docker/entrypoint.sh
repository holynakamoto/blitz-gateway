#!/bin/bash
# Nuclear Benchmark Docker Entrypoint

set -euo pipefail

echo "=========================================="
echo "🚀 NUCLEAR BENCHMARK ENVIRONMENT"
echo "=========================================="
echo "Container: $(hostname)"
echo "Date: $(date)"
echo "=========================================="

# Setup environment
export PATH="/usr/local/bin:$PATH"
export DEBIAN_FRONTEND=noninteractive

# Install any missing dependencies at runtime
if ! command -v wrk2 &> /dev/null; then
    echo "📦 Installing WRK2..."
    apt-get update && apt-get install -y build-essential libssl-dev git
    cd /tmp
    git clone https://github.com/giltene/wrk2.git
    cd wrk2
    make
    cp wrk /usr/local/bin/wrk2
    ln -sf /usr/local/bin/wrk2 /usr/local/bin/wrk
fi

if ! command -v h2load &> /dev/null; then
    echo "📦 Installing nghttp2..."
    apt-get install -y libssl-dev libev-dev libevent-dev libxml2-dev pkg-config
    cd /tmp
    git clone https://github.com/nghttp2/nghttp2.git
    cd nghttp2
    autoreconf -i
    ./configure --enable-app
    make -j$(nproc)
    make install
    ldconfig
fi

# Nuclear kernel optimizations (if running privileged)
if [ "$(id -u)" = "0" ]; then
    echo "🔧 Applying nuclear kernel optimizations..."

    # Network optimizations
    sysctl -w net.core.somaxconn=65536 2>/dev/null || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=65536 2>/dev/null || true
    sysctl -w net.ipv4.tcp_tw_reuse=1 2>/dev/null || true
    sysctl -w net.ipv4.tcp_fin_timeout=10 2>/dev/null || true

    # Memory optimizations
    sysctl -w vm.swappiness=10 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true

    # CPU optimizations
    for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
        echo performance > "$governor" 2>/dev/null || true
    done
fi

# Setup results directory
RESULTS_DIR="/nuclear-benchmarks/results/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "📁 Results will be saved to: $RESULTS_DIR"
echo ""

# Check if Blitz Gateway is available
echo "🔍 Checking Blitz Gateway connectivity..."

if [ -n "${BLITZ_HOST:-}" ]; then
    BLITZ_URL="${BLITZ_HOST}"
else
    BLITZ_URL="blitz-gateway"
fi

# Test HTTP endpoint
if curl -f -s --max-time 10 "http://${BLITZ_URL}:8080/health" > /dev/null 2>&1; then
    echo "✅ Blitz Gateway HTTP endpoint reachable"
else
    echo "⚠️  Blitz Gateway HTTP endpoint not reachable (this is OK if testing other proxies)"
fi

# Test HTTPS endpoint
if curl -f -s -k --max-time 10 "https://${BLITZ_URL}:8443/health" > /dev/null 2>&1; then
    echo "✅ Blitz Gateway HTTPS endpoint reachable"
else
    echo "⚠️  Blitz Gateway HTTPS endpoint not reachable (this is OK if testing other proxies)"
fi

echo ""

# Run the requested command or default to nuclear suite
if [ $# -eq 0 ]; then
    echo "🎯 Running complete nuclear benchmark suite..."
    exec /nuclear-benchmarks/run-nuclear-suite.sh
else
    echo "🎯 Running: $@"
    exec "$@"
fi
