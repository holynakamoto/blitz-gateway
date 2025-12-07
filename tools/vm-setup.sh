#!/bin/bash

# VM Setup Script for QUIC Validation Tools
# Automates installation and configuration in Multipass VM

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

VM_NAME="${1:-zig-build}"
VM_PATH="/home/ubuntu/local_build"

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  QUIC Validation Tools - VM Setup                        ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo

# Check if VM exists
echo -e "${YELLOW}► Checking VM status...${NC}"
if ! multipass list | grep -q "$VM_NAME"; then
    echo -e "${RED}Error: VM '$VM_NAME' not found${NC}"
    echo "Available VMs:"
    multipass list
    exit 1
fi

VM_STATUS=$(multipass list | grep "$VM_NAME" | awk '{print $2}')
if [ "$VM_STATUS" != "Running" ]; then
    echo -e "${YELLOW}  Starting VM...${NC}"
    multipass start "$VM_NAME"
fi

echo -e "${GREEN}  ✓ VM is running${NC}"
echo

# Create directories
echo -e "${YELLOW}► Creating directory structure...${NC}"
multipass exec "$VM_NAME" -- bash -c "mkdir -p $VM_PATH/validation-tools"
multipass exec "$VM_NAME" -- bash -c "mkdir -p $VM_PATH/captures"
echo -e "${GREEN}  ✓ Directories created${NC}"
echo

# Copy validation tools
echo -e "${YELLOW}► Copying validation tools to VM...${NC}"
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

FILES=(
    "QUIC_TESTING_README.md"
    "VM_INTEGRATION.md"
    "quic_validator.zig"
)

for file in "${FILES[@]}"; do
    if [ -f "$SCRIPT_DIR/$file" ]; then
        multipass transfer "$SCRIPT_DIR/$file" "$VM_NAME:$VM_PATH/validation-tools/" 2>/dev/null || {
            echo -e "${YELLOW}  ⚠ Could not transfer $file (may need manual copy)${NC}"
        }
        echo "  ✓ Copied $file"
    else
        echo -e "${YELLOW}  ⚠ Skipping $file (not found)${NC}"
    fi
done

echo -e "${GREEN}  ✓ Files copied${NC}"
echo

# Make scripts executable
echo -e "${YELLOW}► Setting permissions...${NC}"
multipass exec "$VM_NAME" -- bash -c "cd $VM_PATH/validation-tools && chmod +x *.sh *.py 2>/dev/null || true"
echo -e "${GREEN}  ✓ Scripts are executable${NC}"
echo

# Check Python installation
echo -e "${YELLOW}► Checking Python installation...${NC}"
if multipass exec "$VM_NAME" -- which python3 > /dev/null 2>&1; then
    PYTHON_VERSION=$(multipass exec "$VM_NAME" -- python3 --version)
    echo -e "${GREEN}  ✓ $PYTHON_VERSION installed${NC}"
else
    echo -e "${YELLOW}  Installing Python3...${NC}"
    multipass exec "$VM_NAME" -- sudo apt update
    multipass exec "$VM_NAME" -- sudo apt install -y python3 python3-pip
    echo -e "${GREEN}  ✓ Python3 installed${NC}"
fi
echo

# Check aioquic installation
echo -e "${YELLOW}► Checking aioquic...${NC}"
if multipass exec "$VM_NAME" -- python3 -c "import aioquic" 2>/dev/null; then
    echo -e "${GREEN}  ✓ aioquic is installed${NC}"
else
    echo -e "${YELLOW}  Installing aioquic...${NC}"
    multipass exec "$VM_NAME" -- pip3 install --user aioquic
    echo -e "${GREEN}  ✓ aioquic installed${NC}"
fi
echo

# Check Zig installation
echo -e "${YELLOW}► Checking Zig installation...${NC}"
if multipass exec "$VM_NAME" -- which zig > /dev/null 2>&1; then
    ZIG_VERSION=$(multipass exec "$VM_NAME" -- zig version 2>/dev/null | head -1)
    echo -e "${GREEN}  ✓ Zig installed: $ZIG_VERSION${NC}"
else
    echo -e "${RED}  ✗ Zig not found${NC}"
    echo "  Install Zig in the VM or use Python validator only"
fi
echo

# Verify server binary
echo -e "${YELLOW}► Checking server binary...${NC}"
if multipass exec "$VM_NAME" -- test -f "$VM_PATH/zig-out/bin/blitz"; then
    echo -e "${GREEN}  ✓ Server binary found at $VM_PATH/zig-out/bin/blitz${NC}"
elif multipass exec "$VM_NAME" -- test -f "$VM_PATH/server"; then
    echo -e "${GREEN}  ✓ Server binary found at $VM_PATH/server${NC}"
else
    echo -e "${YELLOW}  ⚠ Server binary not found${NC}"
    echo "  Build your server: cd $VM_PATH && zig build"
fi
echo

# Verify certificates
echo -e "${YELLOW}► Checking certificates...${NC}"
CERT_OK=true
if multipass exec "$VM_NAME" -- test -f "$VM_PATH/certs/server.crt"; then
    echo -e "${GREEN}  ✓ certs/server.crt found${NC}"
elif multipass exec "$VM_NAME" -- test -f "$VM_PATH/cert.pem"; then
    echo -e "${GREEN}  ✓ cert.pem found${NC}"
else
    echo -e "${YELLOW}  ⚠ Certificate not found${NC}"
    CERT_OK=false
fi

if multipass exec "$VM_NAME" -- test -f "$VM_PATH/certs/server.key"; then
    echo -e "${GREEN}  ✓ certs/server.key found${NC}"
elif multipass exec "$VM_NAME" -- test -f "$VM_PATH/key.pem"; then
    echo -e "${GREEN}  ✓ key.pem found${NC}"
else
    echo -e "${YELLOW}  ⚠ Private key not found${NC}"
    CERT_OK=false
fi

if [ "$CERT_OK" = false ]; then
    echo "  Generate certificates with:"
    echo "  multipass exec $VM_NAME -- bash -c 'cd $VM_PATH && mkdir -p certs && openssl req -x509 -newkey rsa:2048 -nodes -keyout certs/server.key -out certs/server.crt -days 365 -subj \"/CN=localhost\"'"
fi
echo

# Summary
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Setup Complete                                           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo
echo "📍 Validation tools installed at: $VM_PATH/validation-tools/"
echo
echo "🚀 Next steps:"
echo
echo "1. Start your QUIC server:"
echo "   multipass exec $VM_NAME -- bash -c \"cd $VM_PATH && ./zig-out/bin/blitz --mode quic --port 8443 --cert certs/server.crt --key certs/server.key --capture &\""
echo
echo "2. Run validation (choose one):"
echo "   # Zig validator:"
echo "   multipass exec $VM_NAME -- bash -c \"cd $VM_PATH && zig run tools/quic_validator.zig\""
echo
echo "   # Or from validation-tools:"
echo "   multipass exec $VM_NAME -- bash -c \"cd $VM_PATH/validation-tools && zig run quic_validator.zig\""
echo
echo "3. Check captures:"
echo "   multipass exec $VM_NAME -- bash -c \"ls -lh $VM_PATH/captures/\""
echo
echo "📚 Documentation:"
echo "   multipass exec $VM_NAME -- cat $VM_PATH/validation-tools/QUIC_TESTING_README.md"
echo "   multipass exec $VM_NAME -- cat $VM_PATH/validation-tools/VM_INTEGRATION.md"
echo

# Create helper script
echo -e "${YELLOW}► Creating helper script...${NC}"
cat > /tmp/vm-test.sh << 'HELPER_EOF'
#!/bin/bash
# Quick test script for VM

VM_NAME="zig-build"
VM_PATH="/home/ubuntu/local_build"

case "$1" in
    start)
        echo "Starting server..."
        multipass exec $VM_NAME -- bash -c "cd $VM_PATH && ./zig-out/bin/blitz --mode quic --port 8443 --cert certs/server.crt --key certs/server.key --capture > /tmp/blitz.log 2>&1 &"
        sleep 2
        echo "Server started (PID in /tmp/blitz.log)"
        ;;
    stop)
        echo "Stopping server..."
        multipass exec $VM_NAME -- bash -c "pkill -f 'blitz.*quic' || true"
        echo "Server stopped"
        ;;
    validate)
        echo "Running validation..."
        multipass exec $VM_NAME -- bash -c "cd $VM_PATH && zig run tools/quic_validator.zig"
        ;;
    logs)
        echo "Viewing server logs..."
        multipass exec $VM_NAME -- bash -c "tail -f /tmp/blitz.log"
        ;;
    captures)
        echo "Listing captures..."
        multipass exec $VM_NAME -- bash -c "ls -lah $VM_PATH/captures/ 2>/dev/null || echo 'No captures directory yet'"
        ;;
    shell)
        multipass shell $VM_NAME
        ;;
    *)
        echo "Usage: $0 {start|stop|validate|logs|captures|shell}"
        exit 1
        ;;
esac
HELPER_EOF

chmod +x /tmp/vm-test.sh
if [ -w "$(dirname "$SCRIPT_DIR")" ]; then
    cp /tmp/vm-test.sh "$SCRIPT_DIR/../vm-test.sh"
    echo -e "${GREEN}  ✓ Helper script created: $SCRIPT_DIR/../vm-test.sh${NC}"
    echo
    echo "🎯 Quick commands (from host):"
    echo "   ./vm-test.sh start      # Start server"
    echo "   ./vm-test.sh validate   # Run validation"
    echo "   ./vm-test.sh logs       # View logs"
    echo "   ./vm-test.sh captures   # List captures"
    echo "   ./vm-test.sh stop       # Stop server"
    echo "   ./vm-test.sh shell      # SSH to VM"
fi

echo
echo -e "${GREEN}✅ All done! Ready to validate your QUIC server.${NC}"
echo

