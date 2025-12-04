#!/usr/bin/env bash
# Setup Vagrant with VirtualBox on Apple Silicon

set -e

echo "=========================================="
echo "Vagrant + VirtualBox on Apple Silicon"
echo "=========================================="
echo ""

# Check VirtualBox
if ! command -v VBoxManage &> /dev/null; then
    echo "❌ VirtualBox not found"
    echo "Installing VirtualBox..."
    brew install --cask virtualbox
fi

VBOX_VERSION=$(VBoxManage --version)
echo "✅ VirtualBox installed: $VBOX_VERSION"

# Check ARM64 support
if VBoxManage list systemproperties | grep -q "ARMv8"; then
    echo "✅ ARM64 support detected!"
else
    echo "⚠️  ARM64 support may be limited"
fi

echo ""
echo "VirtualBox 7.0+ supports ARM64, but ARM64 boxes are limited."
echo ""
echo "Options:"
echo "1. Use Ubuntu 22.04 (jammy) - may need to find ARM64 box"
echo "2. Create custom box from Ubuntu ISO"
echo "3. Use UTM directly (easier)"
echo ""
echo "To try with existing box:"
echo "  vagrant box add ubuntu/jammy64 --provider virtualbox"
echo "  vagrant up --provider=virtualbox"
echo ""

