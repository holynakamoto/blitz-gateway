#!/bin/bash
# Setup script for x86_64 Linux VM in UTM for Blitz development
# This script helps set up the VM environment once it's created

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Blitz x86_64 Linux VM Setup (UTM)                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}This script should be run INSIDE the x86_64 Linux VM${NC}"
echo ""
echo "Prerequisites:"
echo "  1. UTM VM with Ubuntu 24.04 x86_64 (Desktop or Server)"
echo "  2. VM should have 6-8 CPU cores, 8-12 GB RAM"
echo "  3. Network: Shared Network (NAT) or Bridged"
echo ""
read -p "Press Enter to continue or Ctrl+C to cancel..."

echo ""
echo "Step 1: Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
    curl \
    git \
    build-essential \
    clang \
    lld \
    libssl-dev \
    pkg-config \
    liburing-dev \
    openssl \
    ca-certificates \
    2>&1 | grep -E "(Reading|Unpacking|Setting up)" | tail -5

echo ""
echo "Step 2: Installing Zig..."
ZIG_VERSION="0.12.0"
ZIG_ARCH="x86_64"
if ! command -v zig &> /dev/null; then
    cd /tmp
    curl -L "https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz" -o zig.tar.xz
    tar -xf zig.tar.xz
    sudo mv zig-linux-${ZIG_ARCH}-${ZIG_VERSION} /usr/local/zig
    sudo ln -sf /usr/local/zig/zig /usr/local/bin/zig
    echo "✅ Zig ${ZIG_VERSION} installed"
else
    echo "✅ Zig already installed: $(zig version)"
fi

echo ""
echo "Step 3: Cloning Blitz repository..."
if [ ! -d "$HOME/blitz" ]; then
    cd "$HOME"
    git clone https://github.com/holynakamoto/blitz-gateway.git blitz || {
        echo "⚠️  Remote clone failed, using local copy if available..."
        if [ -d "/vagrant" ]; then
            cp -r /vagrant "$HOME/blitz"
        fi
    }
    echo "✅ Blitz repository ready"
else
    echo "✅ Blitz repository already exists"
fi

echo ""
echo "Step 4: Generating TLS certificates..."
cd "$HOME/blitz"
mkdir -p certs
if [ ! -f certs/server.crt ] || [ ! -f certs/server.key ]; then
    openssl req -x509 -newkey rsa:4096 \
        -keyout certs/server.key \
        -out certs/server.crt \
        -days 365 -nodes \
        -subj "/C=US/ST=State/L=City/O=Blitz/CN=localhost" \
        2>/dev/null
    echo "✅ TLS certificates generated"
else
    echo "✅ TLS certificates already exist"
fi

echo ""
echo "Step 5: Building Blitz with TLS/HTTP/2 support..."
cd "$HOME/blitz"
zig build -Doptimize=ReleaseFast 2>&1 | tail -10

if [ -f zig-out/bin/blitz ]; then
    echo ""
    echo -e "${GREEN}✅✅✅ Build successful!${NC}"
    ls -lh zig-out/bin/blitz
    echo ""
    echo "Step 6: Testing the server..."
    echo ""
    echo "Starting Blitz server..."
    pkill -9 blitz 2>/dev/null || true
    sleep 1
    
    ./zig-out/bin/blitz > /tmp/blitz.log 2>&1 &
    BLITZ_PID=$!
    sleep 3
    
    if ps -p $BLITZ_PID > /dev/null; then
        echo "✅ Server started (PID: $BLITZ_PID)"
        echo ""
        echo "Testing HTTP/1.1..."
        curl -s http://localhost:8080/hello && echo "" || echo "❌ HTTP/1.1 test failed"
        
        echo ""
        echo "Testing TLS 1.3 + HTTP/2..."
        curl --insecure --http2 -s https://localhost:8443/hello -v 2>&1 | grep -E "(HTTP|TLS|ALPN)" || echo "⚠️  TLS test (may need TLS enabled in code)"
        
        echo ""
        echo "Server logs:"
        tail -10 /tmp/blitz.log
    else
        echo "❌ Server failed to start"
        cat /tmp/blitz.log
    fi
else
    echo "❌ Build failed - check errors above"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Setup Complete!                                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Enable TLS in src/io_uring.zig (uncomment TLS code)"
echo "  2. Test with: curl --insecure --http2 https://localhost:8443/hello"
echo "  3. Benchmark with: wrk2 -t4 -c100 -d30s -R100000 --latency https://localhost:8443/hello"
echo ""

