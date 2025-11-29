#!/bin/bash
# Download Ubuntu 24.04 x86_64 image for UTM

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Downloading Ubuntu 24.04 x86_64 for UTM                    ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

DOWNLOAD_DIR="$HOME/Downloads"
cd "$DOWNLOAD_DIR"

echo "Option 1: Ready-made qcow2 image (Recommended - Fastest)"
echo "  URL: https://github.com/kdrag0n/macvm/releases"
echo "  File: Ubuntu 24.04 Desktop – x86_64.qcow2"
echo ""
echo "Option 2: Official Ubuntu Server ISO"
echo "  URL: https://ubuntu.com/download/server"
echo "  File: ubuntu-24.04-server-amd64.iso"
echo ""

read -p "Download ready-made qcow2? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Opening GitHub releases page..."
    open "https://github.com/kdrag0n/macvm/releases"
    echo ""
    echo "📥 Please download 'Ubuntu 24.04 Desktop – x86_64.qcow2'"
    echo "   Save it to: $DOWNLOAD_DIR"
    echo ""
    echo "Once downloaded, run this script again to verify."
    exit 0
fi

echo "Checking for downloaded files..."
if ls "$DOWNLOAD_DIR"/*.qcow2 2>/dev/null | grep -q .; then
    echo "✅ Found qcow2 file(s):"
    ls -lh "$DOWNLOAD_DIR"/*.qcow2
    echo ""
    echo "Ready to create VM in UTM!"
elif ls "$DOWNLOAD_DIR"/*ubuntu*.iso 2>/dev/null | grep -q .; then
    echo "✅ Found Ubuntu ISO file(s):"
    ls -lh "$DOWNLOAD_DIR"/*ubuntu*.iso
    echo ""
    echo "Ready to create VM in UTM!"
else
    echo "❌ No Ubuntu image found in Downloads"
    echo ""
    echo "Please download one of:"
    echo "  1. qcow2: https://github.com/kdrag0n/macvm/releases"
    echo "  2. ISO: https://ubuntu.com/download/server"
fi

