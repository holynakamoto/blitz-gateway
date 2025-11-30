#!/usr/bin/env bash
# Mac-side script to help set up Linux VM for Blitz
# This runs on your Mac, not in the VM

set -e

echo "=========================================="
echo "Blitz VM Setup Helper (macOS)"
echo "=========================================="
echo "This will help you set up a Linux VM to run Blitz benchmarks"
echo ""

# Check if UTM is installed
if ! command -v utm &> /dev/null && [ ! -d "/Applications/UTM.app" ]; then
    echo "UTM is not installed."
    read -p "Install UTM now? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Installing UTM..."
        brew install --cask utm
        echo "UTM installed! Open it from Applications."
    else
        echo "You can install UTM manually:"
        echo "  brew install --cask utm"
        echo "  Or download from: https://mac.getutm.app/"
    fi
else
    echo "✓ UTM is installed"
fi

# Check architecture
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ISO_NAME="ubuntu-24.04-live-server-arm64.iso"
    ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-arm64.iso"
    echo "Detected: Apple Silicon (ARM)"
else
    ISO_NAME="ubuntu-24.04-live-server-amd64.iso"
    ISO_URL="https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso"
    echo "Detected: Intel Mac"
fi

# Check if ISO exists
ISO_PATH="$HOME/Downloads/$ISO_NAME"
if [ -f "$ISO_PATH" ]; then
    echo "✓ Ubuntu ISO found: $ISO_PATH"
else
    echo ""
    echo "Ubuntu ISO not found. Download it?"
    read -p "Download Ubuntu 24.04 Server ISO? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Downloading Ubuntu 24.04 Server ISO..."
        echo "This may take a few minutes..."
        cd ~/Downloads
        curl -L -o "$ISO_NAME" "$ISO_URL"
        echo "✓ Download complete: $ISO_PATH"
    else
        echo "You can download it manually:"
        echo "  $ISO_URL"
    fi
fi

echo ""
echo "=========================================="
echo "Next Steps"
echo "=========================================="
echo ""
echo "1. Open UTM (Applications → UTM)"
echo "2. Click '+' → 'Virtualize' → 'Linux'"
echo "3. Select: $ISO_PATH"
echo "4. Configure VM:"
echo "   - CPU: 4-8 cores"
echo "   - RAM: 8-16 GB"
echo "   - Disk: 40 GB"
echo "5. Start VM and install Ubuntu (choose 'Minimal installation')"
echo ""
echo "After Ubuntu is installed, in the VM run:"
echo "  curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/vm-setup.sh | bash"
echo ""
echo "Or see benches/VM-QUICK-START.md for detailed instructions"
echo ""

