#!/bin/bash
# Helper script to create UTM VM (manual steps with verification)

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     UTM VM Creation Helper                                     ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

DOWNLOAD_DIR="$HOME/Downloads"
VM_NAME="Blitz-Dev-x86_64"

echo "Step 1: Checking for Ubuntu image..."
QCOW2_FILE=$(find "$DOWNLOAD_DIR" -name "*.qcow2" -o -name "*ubuntu*.qcow2" 2>/dev/null | head -1)
ISO_FILE=$(find "$DOWNLOAD_DIR" -name "*ubuntu*.iso" 2>/dev/null | head -1)

if [ -n "$QCOW2_FILE" ]; then
    echo "✅ Found qcow2 image: $QCOW2_FILE"
    IMAGE_FILE="$QCOW2_FILE"
    IMAGE_TYPE="qcow2"
elif [ -n "$ISO_FILE" ]; then
    echo "✅ Found ISO image: $ISO_FILE"
    IMAGE_FILE="$ISO_FILE"
    IMAGE_TYPE="iso"
else
    echo "❌ No Ubuntu image found in Downloads"
    echo ""
    echo "Please download:"
    echo "  - qcow2: https://github.com/kdrag0n/macvm/releases"
    echo "  - ISO: https://ubuntu.com/download/server"
    exit 1
fi

echo ""
echo "Step 2: Opening UTM..."
open -a UTM 2>/dev/null || {
    echo "❌ Could not open UTM"
    echo "Please install UTM from: https://mac.getutm.app"
    exit 1
}

sleep 2

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     MANUAL STEPS IN UTM                                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Follow these steps in the UTM window:"
echo ""
echo "1. Click the '+' button (top left)"
echo "2. Select 'Virtualize' → 'Linux'"
echo "3. Boot Image:"
echo "   - Click 'Browse'"
echo "   - Navigate to: $IMAGE_FILE"
echo "   - Select the file"
echo ""
echo "4. Hardware Settings:"
echo "   - CPU Cores: 6-8"
echo "   - Memory: 8-12 GB"
echo "   - Storage: 40 GB"
echo "   - Network: Shared Network (NAT)"
echo ""
echo "5. Click 'Save'"
echo "   - Name: $VM_NAME"
echo ""
echo "6. Click 'Start' to boot the VM"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -p "Press Enter when VM is created and started..."

echo ""
echo "Step 3: First Boot Instructions"
echo ""
echo "When the VM boots:"
echo "  - Username: ubuntu"
echo "  - Password: ubuntu"
echo "  - You'll be prompted to change the password"
echo ""
echo "Once logged in, you can:"
echo "  1. Copy the setup script into the VM"
echo "  2. Or clone Blitz directly:"
echo "     git clone https://github.com/holynakamoto/blitz-gateway.git"
echo ""
read -p "Press Enter when VM is booted and ready..."

echo ""
echo "✅ VM Setup Complete!"
echo ""
echo "Next: Run the setup script inside the VM:"
echo "  cd ~/blitz-gateway"
echo "  chmod +x scripts/setup-utm-x86-vm.sh"
echo "  ./scripts/setup-utm-x86-vm.sh"
