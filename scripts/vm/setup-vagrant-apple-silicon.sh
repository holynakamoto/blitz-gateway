#!/usr/bin/env bash
# Setup Vagrant for Apple Silicon (M1/M2/M3)

set -e

echo "=========================================="
echo "Vagrant Setup for Apple Silicon"
echo "=========================================="
echo ""

# Check if Parallels is installed
if command -v prlctl &> /dev/null; then
    echo "✅ Parallels detected!"
    echo ""
    echo "Installing Vagrant Parallels plugin..."
    vagrant plugin install vagrant-parallels
    echo ""
    echo "✅ Setup complete! Use: vagrant up --provider=parallels"
    exit 0
fi

# Use QEMU (free alternative)
echo "Parallels not found. Setting up QEMU provider (free)..."
echo ""

# Install QEMU
if ! command -v qemu-system-aarch64 &> /dev/null; then
    echo "Installing QEMU..."
    brew install qemu
fi

# Install Vagrant QEMU plugin
echo "Installing Vagrant QEMU plugin..."
vagrant plugin install vagrant-qemu

echo ""
echo "✅ Setup complete!"
echo ""
echo "Usage:"
echo "  vagrant up --provider=qemu"
echo ""
echo "Note: QEMU is slower than Parallels but free and works great!"

