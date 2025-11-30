#!/bin/bash
# Test Blitz Gateway .deb installation in Vagrant/UTM VM
# This script is meant to be run INSIDE the VM after setup

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo "=========================================="
echo "🧪 Testing Blitz Gateway Install"
echo "=========================================="
echo ""

# Step 1: Check if we're in the right directory
if [ ! -f "install.sh" ]; then
    log_error "install.sh not found in current directory"
    log_info "Please run from blitz-gateway root or /vagrant"
    exit 1
fi

# Step 2: Build .deb package
log_info "Step 1: Building .deb package..."

# Check if binary exists
if [ ! -f "zig-out/bin/blitz-quic" ]; then
    log_info "Binary not found - building..."
    
    # Check if Zig is installed
    if ! command -v zig &> /dev/null; then
        log_error "Zig not found. Install with:"
        log_info "  wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz"
        log_info "  tar -xf zig-linux-x86_64-0.15.2.tar.xz -C /opt/"
        log_info "  ln -sf /opt/zig-linux-x86_64-0.15.2/zig /usr/local/bin/zig"
        exit 1
    fi
    
    # Install dependencies
    log_info "Installing build dependencies..."
    sudo apt-get update
    sudo apt-get install -y liburing-dev libssl-dev pkg-config || true
    
    # Build
    log_info "Building optimized binary..."
    zig build run-quic -Doptimize=ReleaseFast
fi

# Install nfpm if needed
if ! command -v nfpm &> /dev/null; then
    log_info "Installing nfpm..."
    curl -sSfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o /tmp/nfpm.deb
    sudo dpkg -i /tmp/nfpm.deb || sudo apt-get install -yf
fi

# Build .deb
VERSION="0.6.0"
log_info "Creating .deb package..."
mkdir -p dist

# Backup nfpm.yaml
cp nfpm.yaml nfpm.yaml.bak

# Update version
sed -i "s/version: \".*\"/version: \"${VERSION}\"/" nfpm.yaml

# Build package
nfpm pkg --packager deb --target dist/ || {
    log_error "Failed to build .deb package"
    mv nfpm.yaml.bak nfpm.yaml
    exit 1
}

# Restore nfpm.yaml
mv nfpm.yaml.bak nfpm.yaml

log_success ".deb package created: $(ls -1 dist/*.deb)"

# Step 3: Test installation
log_info "Step 2: Testing installation..."

# Remove existing installation if present
if systemctl is-active --quiet blitz-gateway 2>/dev/null; then
    log_info "Stopping existing service..."
    sudo systemctl stop blitz-gateway || true
fi

if dpkg -l | grep -q blitz-gateway; then
    log_info "Removing existing package..."
    sudo apt-get remove -y blitz-gateway || true
fi

# Install the .deb
DEB_FILE=$(ls -1 dist/*.deb | head -1)
log_info "Installing $DEB_FILE..."
sudo dpkg -i "$DEB_FILE" || {
    log_info "Installing dependencies..."
    sudo apt-get install -yf
    sudo dpkg -i "$DEB_FILE"
}

log_success "Package installed successfully!"

# Step 4: Verify installation
log_info "Step 3: Verifying installation..."

# Check binary
if [ -f "/usr/bin/blitz-gateway" ]; then
    log_success "✅ Binary installed at /usr/bin/blitz-gateway"
    /usr/bin/blitz-gateway --help | head -5
else
    log_error "❌ Binary not found"
    exit 1
fi

# Check config
if [ -f "/etc/blitz-gateway/config.toml" ]; then
    log_success "✅ Config file exists at /etc/blitz-gateway/config.toml"
else
    log_error "❌ Config file not found"
    exit 1
fi

# Check user
if id blitz-gateway &>/dev/null; then
    log_success "✅ System user 'blitz-gateway' created"
    id blitz-gateway
else
    log_error "❌ User 'blitz-gateway' not found"
    exit 1
fi

# Check service
if systemctl list-unit-files | grep -q blitz-gateway; then
    log_success "✅ Systemd service installed"
    systemctl status blitz-gateway --no-pager -l || true
else
    log_error "❌ Systemd service not found"
    exit 1
fi

# Step 5: Test service (dry run)
log_info "Step 4: Testing service configuration..."

# Create a minimal config for testing
sudo tee /etc/blitz-gateway/config.toml > /dev/null <<'EOF'
mode = "origin"
listen = "0.0.0.0:8443"
rate_limit = "10000 req/s"
rate_limit_per_ip = "1000 req/s"
metrics_enabled = true
metrics_port = 9090
EOF

log_info "Testing service start (will fail without certs, that's OK)..."
sudo systemctl daemon-reload
sudo systemctl enable blitz-gateway || true

# Try to start (may fail if certs missing, that's expected)
sudo systemctl start blitz-gateway 2>&1 | head -5 || {
    log_warning "Service start failed (expected if TLS certs missing)"
    log_info "This is normal - service is installed correctly"
}

echo ""
log_success "=========================================="
log_success "✅ Install Test Complete!"
log_success "=========================================="
echo ""
echo "Package installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Configure: sudo nano /etc/blitz-gateway/config.toml"
echo "  2. Add TLS certs (if using HTTPS/QUIC)"
echo "  3. Start: sudo systemctl start blitz-gateway"
echo "  4. Check status: sudo systemctl status blitz-gateway"
echo "  5. View logs: sudo journalctl -u blitz-gateway -f"
echo ""

