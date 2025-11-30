#!/bin/bash
# Quick test script for Vagrant VM
# Usage: ./scripts/vagrant-test.sh

set -e

echo "🚀 Vagrant QUIC Test"
echo ""

# Check if Vagrant is installed
if ! command -v vagrant &> /dev/null; then
    echo "❌ Vagrant not found. Install with: brew install vagrant"
    exit 1
fi

# Check if VM is running
if ! vagrant status | grep -q "running"; then
    echo "📦 Starting Vagrant VM..."
    vagrant up
fi

echo "🧪 Running tests in VM..."
echo ""

# Run test script in VM
vagrant ssh -c "cd /home/vagrant/blitz-gateway && ./scripts/test-quic.sh"

echo ""
echo "✅ Vagrant test complete!"
echo ""
echo "To SSH into VM: vagrant ssh"
echo "To stop VM: vagrant suspend"

