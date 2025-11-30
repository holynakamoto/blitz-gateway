#!/usr/bin/env bash
# Automated UTM VM creation - waits for ISO if needed

set -e

VM_NAME="blitz-benchmark"
ISO_PATH="$HOME/Downloads/ubuntu-24.04-live-server-arm64.iso"
VM_MEMORY=4096
VM_CPUS=4
VM_DISK_SIZE=40

echo "=========================================="
echo "Blitz UTM VM Auto-Setup"
echo "=========================================="
echo ""

# Check if UTM is installed
if ! command -v utmctl &> /dev/null && [ ! -d "/Applications/UTM.app" ]; then
    echo "❌ UTM not found. Installing..."
    brew install --cask utm
    echo "✅ UTM installed. Please restart this script."
    exit 1
fi

# Wait for ISO if downloading
if [ ! -f "$ISO_PATH" ] || [ $(stat -f%z "$ISO_PATH" 2>/dev/null || echo 0) -lt 1000000000 ]; then
    echo "📥 Waiting for Ubuntu ISO..."
    echo "   Expected location: $ISO_PATH"
    echo ""
    
    # Check if download is in progress
    if [ -f "${ISO_PATH}.tmp" ] || pgrep -f "ubuntu-24.04.*iso" > /dev/null; then
        echo "⏳ ISO download in progress, waiting..."
        while [ ! -f "$ISO_PATH" ] || [ $(stat -f%z "$ISO_PATH" 2>/dev/null || echo 0) -lt 1000000000 ]; do
            SIZE=$(stat -f%z "$ISO_PATH" 2>/dev/null || echo 0)
            if [ "$SIZE" -gt 0 ]; then
                SIZE_MB=$((SIZE / 1024 / 1024))
                echo "   Downloaded: ${SIZE_MB} MB..."
            fi
            sleep 5
        done
        echo "✅ ISO download complete!"
    else
        echo "❌ ISO not found and no download detected"
        echo ""
        echo "Please download Ubuntu 24.04 Server (ARM64):"
        echo "  https://ubuntu.com/download/server/arm"
        echo ""
        echo "Or run this to download:"
        echo "  cd ~/Downloads && curl -L -o ubuntu-24.04-live-server-arm64.iso https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-arm64.iso"
        exit 1
    fi
fi

echo "✅ ISO found: $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
echo ""

# Check if VM already exists
EXISTING_VM=$(utmctl list 2>/dev/null | grep "$VM_NAME" | awk '{print $NF}' || true)
if [ -n "$EXISTING_VM" ]; then
    echo "⚠️  VM '$VM_NAME' already exists!"
    echo "Starting existing VM..."
    utmctl start "$VM_NAME" 2>/dev/null || true
    exit 0
fi

# Create VM using AppleScript
echo "🔧 Creating UTM VM..."

osascript << EOF
tell application "UTM"
    activate
    delay 1
    
    -- Create new VM
    set newVM to make new virtual machine with properties {name:"${VM_NAME}", backend:"QEMU"}
    
    -- Configure system
    tell newVM
        set architecture to "aarch64"
        set memory to ${VM_MEMORY}
        set cpuCount to ${VM_CPUS}
    end tell
    
    -- Add ISO drive
    tell newVM
        make new drive with properties {interface:"cd", image path:"${ISO_PATH}", removable:true, read only:true}
    end tell
    
    -- Add disk drive
    tell newVM
        make new drive with properties {interface:"virtio", image path:"", size:${VM_DISK_SIZE} * 1024 * 1024 * 1024}
    end tell
    
    -- Configure network (shared mode)
    tell newVM
        set network mode to "shared"
    end tell
    
    -- Save VM
    save newVM
end tell
EOF

if [ $? -ne 0 ]; then
    echo "❌ Failed to create VM via AppleScript"
    exit 1
fi

echo "✅ VM created successfully!"
sleep 2

# Start VM
if utmctl list 2>/dev/null | grep -q "$VM_NAME"; then
    echo "Starting VM..."
    utmctl start "$VM_NAME" 2>/dev/null || true
    echo ""
    echo "✅ VM created and started!"
else
    echo "⚠️  VM created but not yet registered"
    echo "   Start manually: utmctl start \"$VM_NAME\""
fi

echo ""
echo "=========================================="
echo "VM Setup Complete!"
echo "=========================================="
echo ""
echo "VM Name: $VM_NAME"
echo ""
echo "Commands:"
echo "  • Start:  utmctl start \"$VM_NAME\""
echo "  • Stop:   utmctl stop \"$VM_NAME\""
echo "  • Status: utmctl status \"$VM_NAME\""
echo "  • IP:     utmctl ip-address \"$VM_NAME\""
echo ""

