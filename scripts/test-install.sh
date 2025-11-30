#!/bin/bash
# Test Blitz Gateway Install Script in Vagrant/UTM VM
# Builds .deb package and tests installation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

cd "$PROJECT_ROOT"

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

VERSION="${1:-0.6.0}"
VM_TYPE="${2:-vagrant}"

echo "=========================================="
echo "🧪 Testing Blitz Gateway Install System"
echo "=========================================="
echo "Version: ${VERSION}"
echo "VM Type: ${VM_TYPE}"
echo ""

# Step 1: Build .deb package locally
log_info "Step 1: Building .deb package..."

if ! command -v nfpm &> /dev/null; then
    log_info "Installing nfpm..."
    curl -sSfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o /tmp/nfpm.deb
    sudo dpkg -i /tmp/nfpm.deb || sudo apt-get install -yf
fi

# Build binary if needed (skip on macOS since we can't build Linux binary)
if [ ! -f "zig-out/bin/blitz-quic" ]; then
    log_warning "Binary not found - will build in VM"
    BUILD_IN_VM=true
else
    BUILD_IN_VM=false
fi

# Create dist directory
mkdir -p dist

if [ "$BUILD_IN_VM" = "false" ]; then
    # Update version in nfpm.yaml
    sed -i.bak "s/version: \".*\"/version: \"${VERSION}\"/" nfpm.yaml
    
    # Build .deb package
    log_info "Building .deb package with nfpm..."
    nfpm pkg --packager deb --target dist/ || {
        log_error "Failed to build .deb package locally"
        log_info "This is expected on macOS - will build in VM instead"
        BUILD_IN_VM=true
    }
    
    # Restore nfpm.yaml
    mv nfpm.yaml.bak nfpm.yaml 2>/dev/null || true
fi

# Step 2: Start/Connect to VM
log_info "Step 2: Setting up VM..."

if [ "$VM_TYPE" = "vagrant" ]; then
    # Check if Vagrant is installed
    if ! command -v vagrant &> /dev/null; then
        log_error "Vagrant not found. Install with: brew install vagrant"
        exit 1
    fi
    
    # Check if VM is running
    if ! vagrant status | grep -q "running"; then
        log_info "Starting Vagrant VM..."
        vagrant up
    else
        log_info "Vagrant VM is already running"
    fi
    
    # Copy files to VM
    log_info "Copying install files to VM..."
    vagrant ssh -c "mkdir -p /tmp/blitz-install-test"
    vagrant scp install.sh default:/tmp/blitz-install-test/
    if [ -f "dist/"*.deb ]; then
        vagrant scp dist/*.deb default:/tmp/blitz-install-test/
    fi
    
    VM_CMD="vagrant ssh -c"
    VM_USER="vagrant"
    
elif [ "$VM_TYPE" = "utm" ]; then
    log_info "UTM VM mode - manual setup required"
    log_info "Please ensure UTM VM is running and accessible via SSH"
    read -p "Enter VM SSH connection (e.g., user@192.168.x.x or use 'vagrant ssh' if using Vagrant with UTM): " VM_SSH
    
    VM_CMD="ssh $VM_SSH"
    VM_USER=$(echo "$VM_SSH" | cut -d'@' -f1)
    
    # Copy files
    log_info "Copying install files to UTM VM..."
    ssh "$VM_SSH" "mkdir -p /tmp/blitz-install-test"
    scp install.sh "$VM_SSH:/tmp/blitz-install-test/"
    if [ -f "dist/"*.deb ]; then
        scp dist/*.deb "$VM_SSH:/tmp/blitz-install-test/"
    fi
else
    log_error "Unknown VM type: $VM_TYPE (use 'vagrant' or 'utm')"
    exit 1
fi

# Step 3: Build in VM if needed
if [ "$BUILD_IN_VM" = "true" ]; then
    log_info "Step 3: Building binary and package in VM..."
    
    $VM_CMD "cd /vagrant && \
        sudo apt-get update && \
        sudo apt-get install -y liburing-dev libssl-dev pkg-config && \
        zig build run-quic -Doptimize=ReleaseFast && \
        mkdir -p dist && \
        curl -sSfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o /tmp/nfpm.deb && \
        sudo dpkg -i /tmp/nfpm.deb && \
        sed -i \"s/version: \\\".*\\\"/version: \\\"${VERSION}\\\"/\" nfpm.yaml && \
        nfpm pkg --packager deb --target dist/ && \
        cp dist/*.deb /tmp/blitz-install-test/" || {
        log_error "Failed to build in VM"
        exit 1
    }
fi

# Step 4: Test installation
log_info "Step 4: Testing installation..."

$VM_CMD "cd /tmp/blitz-install-test && \
    echo 'Testing install script...' && \
    sudo bash -x install.sh 2>&1 | tee install.log" || {
    log_error "Installation failed"
    $VM_CMD "cat /tmp/blitz-install-test/install.log"
    exit 1
}

# Step 5: Verify installation
log_info "Step 5: Verifying installation..."

$VM_CMD "echo 'Checking binary...' && \
    /usr/bin/blitz-gateway --help && \
    echo '✅ Binary works' && \
    echo '' && \
    echo 'Checking service...' && \
    systemctl status blitz-gateway --no-pager || true && \
    echo '' && \
    echo 'Checking config...' && \
    ls -la /etc/blitz-gateway/config.toml && \
    echo '✅ Config exists' && \
    echo '' && \
    echo 'Checking user...' && \
    id blitz-gateway && \
    echo '✅ User exists'" || {
    log_error "Verification failed"
    exit 1
}

log_success "Installation test completed successfully!"
echo ""
echo "Next steps:"
echo "  1. Configure: sudo nano /etc/blitz-gateway/config.toml"
echo "  2. Start: sudo systemctl start blitz-gateway"
echo "  3. Check logs: sudo journalctl -u blitz-gateway -f"

