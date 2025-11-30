#!/bin/bash
# Build .deb package locally for testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

cd "$PROJECT_ROOT"

VERSION="${1:-0.6.0}"

echo "=========================================="
echo "Building Blitz Gateway .deb package"
echo "Version: ${VERSION}"
echo "=========================================="

# Check if nfpm is installed
if ! command -v nfpm &> /dev/null; then
    echo "Installing nfpm..."
    curl -sSfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o /tmp/nfpm.deb
    sudo dpkg -i /tmp/nfpm.deb || sudo apt-get install -yf
fi

# Build binary if not exists
if [ ! -f "zig-out/bin/blitz-quic" ]; then
    echo "Building binary..."
    zig build run-quic -Doptimize=ReleaseFast
fi

# Update version in nfpm.yaml
sed -i.bak "s/version: \".*\"/version: \"${VERSION}\"/" packaging/nfpm.yaml

# Create dist directory
mkdir -p dist

# Build .deb package
echo "Building .deb package..."
nfpm pkg --packager deb --target dist/ --config packaging/nfpm.yaml

# Restore nfpm.yaml
mv packaging/nfpm.yaml.bak packaging/nfpm.yaml

echo ""
echo "✅ Package built successfully!"
echo "📦 Location: dist/blitz-gateway_${VERSION}_amd64.deb"
echo ""
echo "Install with:"
echo "  sudo dpkg -i dist/blitz-gateway_${VERSION}_amd64.deb"

