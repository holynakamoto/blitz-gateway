#!/usr/bin/env bash
# =============================================================================
# linux-build.sh — Instant, strict Linux Zig builds on macOS via Multipass
# Works flawlessly with Zig 0.13 → 0.15+ (and future versions)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VM_NAME="zig-build"
MOUNT_POINT="/home/ubuntu/project"
ZIG_VERSION="0.15.2"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "Starting linux-build.sh"
echo "VM_NAME: $VM_NAME"
echo "ZIG_VERSION: $ZIG_VERSION"
echo "Project root: $PROJECT_ROOT"

command -v multipass >/dev/null || die "multipass not found → brew install --cask multipass"
echo "✓ Multipass found"

# ——— Parse --clean flag ———
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

# ——— Launch VM if missing ———
if ! multipass info "$VM_NAME" &>/dev/null; then
    echo "Launching fresh Ubuntu 24.04 VM '$VM_NAME' (~45 seconds first time)..."
    multipass launch 24.04 \
        --name "$VM_NAME" \
        --cpus 6 \
        --memory 12G \
        --disk 50G
    echo "✓ VM launched"
else
    echo "✓ VM '$VM_NAME' exists"
fi

# ——— Setup SSHFS for mounts ———
echo "Setting up mount support..."
multipass exec "$VM_NAME" -- sudo apt-get update -qq
multipass exec "$VM_NAME" -- sudo apt-get install -y -qq sshfs fuse3
echo "✓ SSHFS ready"

# ——— Install Zig if missing or wrong version ———
echo "Checking Zig installation..."
CURRENT_ZIG=$(multipass exec "$VM_NAME" -- bash -c "/snap/bin/zig version 2>/dev/null || echo 'none'" | tr -d '\r\n')

if [[ "$CURRENT_ZIG" == "$ZIG_VERSION" ]]; then
    echo "✓ Zig ${ZIG_VERSION} already installed"
else
    echo "Installing Zig ${ZIG_VERSION} via snap (1-3 minutes)..."
    multipass exec "$VM_NAME" -- sudo snap install zig --classic --beta
    multipass exec "$VM_NAME" -- bash -c "echo 'export PATH=/snap/bin:\$PATH' >> ~/.bashrc"

    # Verify
    INSTALLED=$(multipass exec "$VM_NAME" -- /snap/bin/zig version 2>&1 | tr -d '\r\n')
    echo "✓ Zig installed: $INSTALLED"
fi

# ——— Mount project directory ———
echo "Mounting project → ${VM_NAME}:${MOUNT_POINT}"
# Unmount first if already mounted
multipass umount "${VM_NAME}:${MOUNT_POINT}" 2>/dev/null || true

if ! multipass mount "$PROJECT_ROOT" "${VM_NAME}:${MOUNT_POINT}" 2>/dev/null; then
    echo "Fixing mount point ownership..."
    multipass exec "$VM_NAME" -- mkdir -p "${MOUNT_POINT}"
    multipass exec "$VM_NAME" -- sudo chown ubuntu:ubuntu "${MOUNT_POINT}"
    multipass mount "$PROJECT_ROOT" "${VM_NAME}:${MOUNT_POINT}" || die "Mount failed"
fi

# Verify mount
multipass exec "$VM_NAME" -- ls "${MOUNT_POINT}/build.zig" >/dev/null 2>&1 || die "Mount verification failed"
echo "✓ Mount verified"

# ——— Handle commands ———
if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [--clean] build [zig-options...]  or  $0 sh"
    exit 1
fi

if [[ "$1" == "sh" || "$1" == "shell" ]]; then
    echo "Entering VM shell — code at ${MOUNT_POINT}"
    exec multipass shell "$VM_NAME"
fi

# ——— Run zig command ———
echo "Running: zig $*"
multipass exec "$VM_NAME" -- /bin/sh -c "cd '${MOUNT_POINT}' && /snap/bin/zig $*"
echo "✓ Done"