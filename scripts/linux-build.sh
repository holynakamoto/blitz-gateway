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
ZIG_VERSION="0.15.0"  # Change this when you upgrade Zig

die() { echo "Error: $*" >&2; exit 1; }

command -v multipass >/dev/null || die "multipass not found → brew install --cask multipass"

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
fi

# ——— Install exact Zig version if missing or wrong ———
if ! multipass exec "$VM_NAME" -- zig version 2>/dev/null | grep -q "^${ZIG_VERSION}$"; then
    echo "Installing Zig ${ZIG_VERSION} in the VM..."
    multipass exec "$VM_NAME" -- sudo bash -c "
        set -euo pipefail
        URL='https://ziglang.org/download/${ZIG_VERSION}/zig-linux-x86_64-${ZIG_VERSION}.tar.xz'
        rm -rf /usr/local/zig-${ZIG_VERSION}
        echo 'Downloading Zig ${ZIG_VERSION}...'
        curl -L \"\$URL\" | tar -xJ -C /tmp
        mv \"/tmp/zig-linux-x86_64-${ZIG_VERSION}\" \"/usr/local/zig-${ZIG_VERSION}\"
        ln -sf \"/usr/local/zig-${ZIG_VERSION}/zig\" /usr/local/bin/zig
        echo 'Zig installed:'; zig version
    "
fi

# ——— Mount current project directory (100% reliable on 24.04+) ———
echo "Mounting project → ${VM_NAME}:${MOUNT_POINT}"
if ! multipass mount "$(pwd)" "${VM_NAME}:${MOUNT_POINT}" 2>/dev/null; then
    echo "Initial mount failed (expected on fresh 24.04) — fixing ownership..."
    multipass exec "$VM_NAME" -- sudo mkdir -p "${MOUNT_POINT}"
    multipass exec "$VM_NAME" -- sudo chown ubuntu:ubuntu "${MOUNT_POINT}"
    multipass mount "$(pwd)" "${VM_NAME}:${MOUNT_POINT}"
    echo "Mount fixed and applied"
else
    echo "Mount succeeded on first try"
fi

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
multipass exec "$VM_NAME" -- bash -c "cd '${MOUNT_POINT}' && zig $*"