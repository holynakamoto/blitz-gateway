#!/usr/bin/env bash
# Automated UTM VM creation for Blitz benchmarks using AppleScript
# This script creates and configures a UTM VM from the terminal

set -e

VM_NAME="blitz-benchmark"
ISO_PATH="$HOME/Downloads/ubuntu-24.04-live-server-arm64.iso"
VM_MEMORY=4096  # 4 GB
VM_CPUS=4
VM_DISK_SIZE=40  # GB

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

# Check if VM already exists
EXISTING_VM=$(utmctl list 2>/dev/null | grep "$VM_NAME" | awk '{print $NF}' || true)
if [ -n "$EXISTING_VM" ]; then
    echo "⚠️  VM '$VM_NAME' already exists!"
    read -p "Delete and recreate? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Deleting existing VM..."
        utmctl delete "$VM_NAME" 2>/dev/null || true
        sleep 2
    else
        echo "Keeping existing VM. Use 'utmctl start \"$VM_NAME\"' to start it."
        exit 0
    fi
fi

# Check ISO - download if missing or prompt
if [ ! -f "$ISO_PATH" ] || [ $(stat -f%z "$ISO_PATH" 2>/dev/null || echo 0) -lt 1000000000 ]; then
    echo "📥 Ubuntu ISO not found or incomplete"
    echo ""
    read -p "Download ISO automatically? (Y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        echo "Downloading Ubuntu 24.04 Server ISO (ARM64)..."
        echo "This will take 5-10 minutes (~2GB), please wait..."
        echo ""
        cd ~/Downloads
        rm -f ubuntu-24.04-live-server-arm64.iso.tmp
        
        # Try multiple download methods
        if command -v wget &> /dev/null; then
            wget --progress=bar:force -O ubuntu-24.04-live-server-arm64.iso.tmp \
                "https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-arm64.iso" && \
                mv ubuntu-24.04-live-server-arm64.iso.tmp ubuntu-24.04-live-server-arm64.iso
        else
            curl -L --fail --progress-bar \
                -o ubuntu-24.04-live-server-arm64.iso.tmp \
                "https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-arm64.iso" && \
                mv ubuntu-24.04-live-server-arm64.iso.tmp ubuntu-24.04-live-server-arm64.iso
        fi
        
        if [ ! -f "$ISO_PATH" ] || [ $(stat -f%z "$ISO_PATH" 2>/dev/null || echo 0) -lt 1000000000 ]; then
            echo ""
            echo "❌ Download failed or incomplete"
            echo ""
            echo "Please download manually from:"
            echo "  https://ubuntu.com/download/server/arm"
            echo ""
            echo "Or: https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-arm64.iso"
            echo ""
            echo "Save to: $ISO_PATH"
            echo ""
            read -p "Press Enter once downloaded, or Ctrl+C to cancel..."
        else
            echo ""
            echo "✅ ISO downloaded successfully!"
        fi
    else
        echo ""
        echo "Please download Ubuntu 24.04 Server (ARM64) from:"
        echo "  https://ubuntu.com/download/server/arm"
        echo ""
        echo "Save to: $ISO_PATH"
        echo ""
        read -p "Press Enter once the ISO is downloaded, or Ctrl+C to cancel..."
    fi
    
    # Final check
    if [ ! -f "$ISO_PATH" ] || [ $(stat -f%z "$ISO_PATH" 2>/dev/null || echo 0) -lt 1000000000 ]; then
        echo "❌ ISO still not found or too small"
        exit 1
    fi
fi

echo "✅ ISO found: $ISO_PATH ($(du -h "$ISO_PATH" | cut -f1))"
echo ""

# Create VM using AppleScript
echo "🔧 Creating UTM VM using AppleScript..."

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
    echo ""
    echo "Alternative: Create VM manually in UTM:"
    echo "  1. Open UTM"
    echo "  2. Click '+' → Virtualize → Linux"
    echo "  3. Select ISO: $ISO_PATH"
    echo "  4. Set: ${VM_MEMORY} MB RAM, ${VM_CPUS} CPUs, ${VM_DISK_SIZE} GB disk"
    exit 1
fi

echo "✅ VM created successfully!"
echo ""

# Wait a moment for UTM to register
sleep 2

# Check if VM is registered
if utmctl list 2>/dev/null | grep -q "$VM_NAME"; then
    echo "✅ VM registered with UTM"
    echo ""
    echo "Starting VM..."
    utmctl start "$VM_NAME" 2>/dev/null || {
        echo "⚠️  VM registered but couldn't auto-start"
        echo "   Start manually: utmctl start \"$VM_NAME\""
    }
else
    echo "⚠️  VM created but not yet visible in utmctl"
    echo "   Try: utmctl list"
    echo "   Or start manually from UTM GUI"
fi

echo ""
echo "=========================================="
echo "VM Setup Complete!"
echo "=========================================="
echo ""
echo "VM Name: $VM_NAME"
echo ""
echo "Useful commands:"
echo "  • Start VM:    utmctl start \"$VM_NAME\""
echo "  • Stop VM:     utmctl stop \"$VM_NAME\""
echo "  • Status:      utmctl status \"$VM_NAME\""
echo "  • List VMs:    utmctl list"
echo "  • Get IP:      utmctl ip-address \"$VM_NAME\""
echo ""
echo "After Ubuntu is installed:"
echo "  1. Log into the VM"
echo "  2. Run: curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/vm-setup.sh | bash"
echo "  3. Transfer Blitz: scp -r ~/blitz-gateway blitz@VM-IP:/home/blitz/"
echo ""
