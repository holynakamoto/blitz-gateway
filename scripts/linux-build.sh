#!/usr/bin/env bash
# =============================================================================
# linux-build.sh — Instant, strict Linux Zig builds on macOS via Multipass
# Works flawlessly with Zig 0.13 → 0.15+ (and future versions)
# =============================================================================
# Usage:
#   ./scripts/linux-build.sh build test
#   ./scripts/linux-build.sh build -Drelease-safe
#   ./scripts/linux-build.sh --clean build -Drelease-fast
#   ./scripts/linux-build.sh sh               # drop into VM shell
#   ./scripts/linux-build.sh shell
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VM_NAME="zig-build"
MOUNT_POINT="/home/ubuntu/project"
ZIG_VERSION="0.15.2"  # Target Zig version

die() {
    echo "ERROR: $*" >&2
    echo "Debug info:" >&2
    echo "- VM_NAME: $VM_NAME" >&2
    echo "- MOUNT_POINT: $MOUNT_POINT" >&2
    echo "- Current step failed" >&2
    exit 1
}

echo "Starting linux-build.sh with debugging enabled"
echo "VM_NAME: $VM_NAME"
echo "ZIG_VERSION: $ZIG_VERSION"
echo "Current directory: $(pwd)"

command -v multipass >/dev/null || die "multipass not found → brew install --cask multipass"
echo "✓ Multipass found"

# ——— Parse --clean flag safely ———
CLEAN_VM=false
if [[ "${1:-}" == "--clean" ]]; then
    CLEAN_VM=true
    shift
fi

# ——— Clean VM if requested ———
if $CLEAN_VM; then
    echo "Deleting VM '$VM_NAME'..."
    multipass stop "$VM_NAME" 2>/dev/null || true
    multipass delete --purge "$VM_NAME" 2>/dev/null || true
fi

# ——— Launch VM if missing (fast official 24.04 image) ———
if ! multipass info "$VM_NAME" &>/dev/null; then
    echo "Launching fresh Ubuntu 24.04 VM '$VM_NAME' (this takes ~45 seconds the first time)..."
    multipass launch 24.04 \
        --name "$VM_NAME" \
        --cpus 6 \
        --memory 12G \
        --disk 50G
    echo "VM launched successfully"
else
    echo "VM '$VM_NAME' already exists"
fi

# ——— Install multipass-sshfs snap for mounts (Ubuntu 24.04+ requirement) ———
echo "Installing multipass-sshfs snap for reliable mounts..."
multipass exec "$VM_NAME" -- sudo snap install multipass-sshfs --classic
echo "✓ multipass-sshfs installed"

# ——— Install exact Zig version if missing or wrong ———
echo "Checking Zig installation in VM (may take up to 60s on first snap run)..."
if ! timeout 90 multipass exec "$VM_NAME" -- bash -c "
    echo '  → Checking for Zig...'
    if command -v /snap/bin/zig >/dev/null; then
        echo '  → Found Zig, checking version...'
        /snap/bin/zig version 2>&1
    else
        echo '  → No Zig found'
        exit 1
    fi
" 2>&1 | grep -q "^${ZIG_VERSION}$"; then
    echo "Installing Zig ${ZIG_VERSION} in the VM via snap (with PATH fix)..."
    multipass exec "$VM_NAME" -- sudo bash -c "
        set -euo pipefail

        # Ensure snapd is ready
        if ! command -v snap &>/dev/null; then
            apt-get update -q
            apt-get install -y snapd
            systemctl enable --now snapd.socket || true
            export PATH=/snap/bin:\$PATH
        fi

        # Install specific version if available, otherwise latest
        if snap info zig | grep -q \"^${ZIG_VERSION} \" 2>/dev/null; then
            snap install zig --classic --channel=${ZIG_VERSION}/stable
        else
            echo \"Version ${ZIG_VERSION} not in snap store, installing latest...\"
            snap install zig --classic --beta
        fi

        # Critical: Force /snap/bin into PATH for non-interactive sessions
        echo 'export PATH=/snap/bin:\$PATH' >> /etc/environment
        echo 'export PATH=/snap/bin:\$PATH' >> /home/ubuntu/.bashrc

        echo 'Zig installed and PATH fixed'
        /snap/bin/zig version
    "
    echo "Zig installation completed"
else
    echo "Zig ${ZIG_VERSION} already installed"
fi

# ——— Mount current project directory (100% reliable on 24.04+) ———
echo "Mounting project → ${VM_NAME}:${MOUNT_POINT}"
if ! multipass mount "$(pwd)" "${VM_NAME}:${MOUNT_POINT}" 2>/dev/null; then
    echo "Initial mount failed (expected on fresh 24.04) — fixing ownership..."
    echo "Creating mount point directory..."
    multipass exec "$VM_NAME" -- /bin/mkdir -p "${MOUNT_POINT}" || {
        echo "ERROR: Failed to create mount point directory"
        exit 1
    }
    echo "Setting ownership..."
    multipass exec "$VM_NAME" -- /bin/chown ubuntu:ubuntu "${MOUNT_POINT}" || {
        echo "ERROR: Failed to set ownership"
        exit 1
    }
    echo "Retrying mount..."
    multipass mount "$(pwd)" "${VM_NAME}:${MOUNT_POINT}" || {
        echo "ERROR: Mount failed even after fixing ownership"
        exit 1
    }
    echo "Mount fixed and applied successfully"
else
    echo "Mount succeeded on first try"
fi

# Verify mount worked
echo "Verifying mount..."
if ! multipass exec "$VM_NAME" -- ls "${MOUNT_POINT}/build.zig" >/dev/null 2>&1; then
    echo "ERROR: Mount verification failed - build.zig not found in VM"
    exit 1
fi
echo "Mount verified successfully"

# ——— Usage / shortcuts ———
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [--clean] build [zig-options...]    or    $0 sh"
    exit 1
fi

if [[ "$1" == "sh" || "$1" == "shell" ]]; then
    echo "Entering VM shell — your code is at ${MOUNT_POINT}"
    exec multipass shell "$VM_NAME"
fi

# ——— Run the actual zig command inside Linux ———
echo "Running in Linux VM: zig $*"
echo "Working directory in VM: ${MOUNT_POINT}"
echo "Command to execute: export PATH=/snap/bin:\$PATH && cd '${MOUNT_POINT}' && zig $*"

# Test VM connectivity first
echo "Testing VM connectivity..."
if ! multipass exec "$VM_NAME" -- echo "VM is responsive"; then
    echo "ERROR: Cannot connect to VM"
    exit 1
fi

# Execute the zig command with error handling
echo "Executing zig command..."
if ! multipass exec "$VM_NAME" -- /bin/sh -c "PATH=/snap/bin:\$PATH && cd '${MOUNT_POINT}' && /snap/bin/zig $*"; then
    echo "ERROR: Zig command failed with exit code $?"
    echo "Debug info:"
    echo "- VM name: $VM_NAME"
    echo "- Mount point: $MOUNT_POINT"
    echo "- Command: zig $*"
    echo "- Current directory in VM:"
    multipass exec "$VM_NAME" -- /bin/sh -c "PATH=/snap/bin:\$PATH && /bin/pwd" || echo "Cannot get pwd"
    echo "- Directory contents:"
    multipass exec "$VM_NAME" -- /bin/sh -c "PATH=/snap/bin:\$PATH && /bin/ls -la '${MOUNT_POINT}'" || echo "Cannot list directory"
    exit 1
fi

echo "Command completed successfully"