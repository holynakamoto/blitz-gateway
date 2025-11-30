#!/usr/bin/env bash
# Quick setup script for Ubuntu 24.04 VM
# Run this inside your Ubuntu VM after installation

set -e

echo "=========================================="
echo "Blitz VM Setup Script"
echo "=========================================="
echo "This will install all dependencies and prepare your VM for Blitz benchmarks"
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then 
    echo "ERROR: Don't run as root. Run as your user (will use sudo when needed)"
    exit 1
fi

# Update system
echo "Updating system..."
sudo apt update && sudo apt upgrade -y

# Install build tools
echo ""
echo "Installing build tools..."
sudo apt install -y \
    build-essential \
    git \
    curl \
    wget \
    liburing-dev \
    pkg-config

# Install Zig
echo ""
echo "Installing Zig 0.12.0..."
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    ZIG_ARCH="x86_64"
elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
    ZIG_ARCH="aarch64"
else
    echo "ERROR: Unsupported architecture: $ARCH"
    exit 1
fi

cd /tmp
wget -q https://ziglang.org/download/0.12.0/zig-linux-${ZIG_ARCH}-0.12.0.tar.xz
tar -xf zig-linux-${ZIG_ARCH}-0.12.0.tar.xz
sudo mv zig-linux-${ZIG_ARCH}-0.12.0 /opt/zig
rm zig-linux-${ZIG_ARCH}-0.12.0.tar.xz

# Add Zig to PATH
if ! grep -q "/opt/zig" ~/.bashrc; then
    echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc
fi
export PATH="/opt/zig:$PATH"

# Install wrk2
echo ""
echo "Installing wrk2..."
cd /tmp
git clone https://github.com/giltene/wrk2.git
cd wrk2
make
sudo cp wrk /usr/local/bin/wrk2
cd ~
rm -rf /tmp/wrk2

# Verify installations
echo ""
echo "=========================================="
echo "Verification"
echo "=========================================="
echo "Zig version:"
zig version

echo ""
echo "liburing version:"
pkg-config --modversion liburing || echo "liburing not found via pkg-config (but may be installed)"

echo ""
echo "wrk2 version:"
wrk2 --version || echo "wrk2 installed"

echo ""
echo "Kernel version:"
uname -r

echo ""
echo "CPU cores:"
nproc

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo "  1. Clone or transfer Blitz repo to this VM"
echo "  2. cd blitz-gateway"
echo "  3. zig build -Doptimize=ReleaseFast"
echo "  4. ./zig-out/bin/blitz"
echo "  5. In another terminal: ./benches/local-benchmark.sh"
echo ""
echo "For maximum performance (optional):"
echo "  sudo ./scripts/bench-box-setup.sh"
echo "  (This will reboot the VM once)"
echo ""

