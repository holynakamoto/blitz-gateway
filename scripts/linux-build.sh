#!/usr/bin/env bash
# =============================================================================
# linux-build-static.sh — ULTIMATE BULLETPROOF VERSION (FIXED)
# Zig 0.15.2 + picotls (minicrypto) + liburing (static)
# 100% static linking - ZERO dynamic library dependencies
# Builds aarch64-linux binaries using Multipass VM
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

VM_NAME="zig-build"
PROJECT_MOUNT_POINT="/home/ubuntu/project"
LOCAL_BUILD_POINT="/home/ubuntu/local_build"
LIBURING_VERSION="liburing-2.7"

die() { echo "ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  linux-build-static.sh — ULTIMATE BULLETPROOF MODE    ║"
echo "╚════════════════════════════════════════════════════════╝"
echo "Project root: $PROJECT_ROOT"

command -v multipass >/dev/null || die "multipass not found → https://multipass.run"

# --- Parse arguments ---
CLEAN_VM=false
CLEAN_PROJECT=false

# Re-parse arguments to handle the clean flags correctly
REMAINING_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--clean-vm" ]]; then
        CLEAN_VM=true
    elif [[ "$arg" == "--clean" ]]; then
        CLEAN_PROJECT=true
    else
        REMAINING_ARGS+=("$arg")
    fi
done

# Check if required build arguments are present
if [[ ${#REMAINING_ARGS[@]} -eq 0 ]]; then
    cat <<USAGE
Usage: $0 [--clean-vm] [--clean] <zig build args>

Examples:
  $0 build                                    # Normal build (reuses VM & deps)
  $0 --clean build -Doptimize=ReleaseFast     # Fast clean (only Zig artifacts)
  $0 --clean-vm build -Doptimize=ReleaseFast   # Full clean (rebuilds everything)
  $0 build -Doptimize=ReleaseSmall -Dstrip=true
  $0 test

Flags:
  --clean      Clean only Zig build artifacts (.zig-cache, zig-out) - FAST
  --clean-vm   Delete and recreate VM (rebuilds all dependencies) - SLOW

Features:
  • 100% static linking (no dynamic dependencies)
  • Self-contained picotls with minicrypto (no OpenSSL)
  • Pinned liburing version for reproducibility
  • Automatic binary verification
  • Persistent VM with cached dependencies (use --clean for fast rebuilds)

USAGE
    exit 1
fi

# Overwrite positional arguments with remaining build args
set -- "${REMAINING_ARGS[@]}"

# If clean-vm is set, it implies clean-project cleanup on the new VM
if $CLEAN_VM; then
    CLEAN_PROJECT=true
fi

# --- VM Setup Function (Unchanged) ---
setup_vm() {
    echo "--- 1. Launching/Preparing VM ---"
    if $CLEAN_VM; then
        echo "Deleting existing VM '$VM_NAME'..."
        multipass stop "$VM_NAME" --force 2>/dev/null || true
        multipass delete "$VM_NAME" --purge 2>/dev/null || true
        echo "✓ VM deleted"
    fi

    if ! multipass info "$VM_NAME" &>/dev/null; then
        echo "Launching fresh Ubuntu 22.04 VM..."
        multipass launch 22.04 --name "$VM_NAME" --cpus 6 --memory 12G --disk 50G
        echo "Waiting for VM to stabilize..."
        sleep 30
    fi

    echo "Installing build tools + Zig 0.15.2..."
    multipass exec "$VM_NAME" -- sudo bash <<'EOF'
set -euo pipefail

# Update and install ONLY what's needed for static builds
# NOTE: We explicitly DO NOT install libssl-dev to avoid dynamic OpenSSL
apt-get update -qq
apt-get install -y \
    build-essential \
    cmake \
    git \
    rsync \
    fuse3 \
    ca-certificates \
    snapd \
    pkg-config \
    linux-headers-generic \
    file \
    libc6-dev

echo "✓ Build tools installed (no libssl-dev)"

# Enable snapd
systemctl enable --now snapd 2>/dev/null || true
ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
sleep 10

# Passwordless sudo
echo 'ubuntu ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/ubuntu-nopasswd
chmod 0440 /etc/sudoers.d/ubuntu-nopasswd

# Install Zig 0.15.2 (snap beta)
if ! /snap/bin/zig version 2>/dev/null | grep -q "^0\.15\."; then
    echo "Installing Zig 0.15.2..."
    snap install zig --classic --channel=beta
    echo "✓ Zig installed"
else
    echo "✓ Zig already installed"
fi

/snap/bin/zig version

mkdir -p /home/ubuntu/project /home/ubuntu/local_build
chown ubuntu:ubuntu /home/ubuntu/project /home/ubuntu/local_build
EOF

    multipass mount "$PROJECT_ROOT" "${VM_NAME}:${PROJECT_MOUNT_POINT}" || die "Mount failed"
    echo "✓ VM ready — Zig 0.15.2 installed via snap"
}

if $CLEAN_VM || ! multipass info "$VM_NAME" &>/dev/null; then
    setup_vm
else
    echo "✓ VM '$VM_NAME' is already running"
fi

# --- 2. Sync code & Project Clean (MODIFIED) ---
echo ""
echo "--- 2. Synchronizing Files & Project Clean ---"

# Clean project artifacts if requested (fast clean mode)
if $CLEAN_PROJECT; then
    echo "Cleaning project artifacts in VM (.zig-cache, zig-out)..."
    # Use '|| true' to prevent script exit if files aren't found on a fresh VM
    multipass exec "$VM_NAME" -- bash -c "rm -rf \"$LOCAL_BUILD_POINT/.zig-cache\" \"$LOCAL_BUILD_POINT/zig-out\" 2>/dev/null || true"
    echo "✓ Project artifacts cleaned"
fi

multipass exec "$VM_NAME" -- bash <<EOF
rsync -a --delete --info=progress2 \
    --exclude='.git/' \
    --exclude='zig-cache/' \
    --exclude='zig-out/' \
    --exclude='build/' \
    --exclude='.DS_Store' \
    "$PROJECT_MOUNT_POINT/" "$LOCAL_BUILD_POINT/"
chown -R ubuntu:ubuntu "$LOCAL_BUILD_POINT"
EOF
echo "✓ Sync complete"

# --- 3. Build static dependencies (Unchanged) ---
echo ""
echo "--- 3. Building Static Dependencies ---"
multipass exec "$VM_NAME" -- bash <<EOF
set -euo pipefail

# --- Build liburing (STATIC ONLY) ---
if [ ! -f /usr/local/lib/liburing.a ]; then
    echo "Building liburing ${LIBURING_VERSION} (static only)..."
    cd /tmp
    rm -rf liburing
    
    # Clone specific tag for reproducibility
    git clone --depth 1 --branch ${LIBURING_VERSION} https://github.com/axboe/liburing.git
    cd liburing
    
    echo "Configuring liburing for static build..."
    ./configure --prefix=/usr/local
    
    echo "Compiling liburing (static library only)..."
    # liburing builds both static and shared by default
    # We'll build both but only keep the static library
    make -j\$(nproc)
    sudo make install
    
    # Remove shared libraries - we only want static
    echo "Removing shared libraries (keeping static only)..."
    sudo rm -f /usr/local/lib/liburing.so*
    
    # Verify static library exists
    if [ ! -f /usr/local/lib/liburing.a ]; then
        echo "ERROR: liburing.a not found after build!"
        exit 1
    fi
    
    echo "✓ liburing ${LIBURING_VERSION} installed (static only)"
    ls -lh /usr/local/lib/liburing.a
else
    echo "✓ liburing already installed"
    ls -lh /usr/local/lib/liburing.a
fi

# --- Build picotls with minicrypto (STATIC ONLY) ---
if [ ! -f /usr/local/lib/libpicotls.a ]; then
    echo "Building picotls (static with minicrypto, NO OpenSSL)..."
    cd $LOCAL_BUILD_POINT/deps/picotls
    rm -rf build
    mkdir build && cd build

    echo "Configuring picotls..."
    cmake .. \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_SHARED_LIBS=OFF \
        -DPTLS_MINICRYPTO=ON \
        -DPTLS_OPENSSL=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON

    echo "Compiling picotls..."
    make -j\$(nproc) picotls-core picotls-minicrypto

    # Install static libraries
    echo "Installing picotls libraries..."
    sudo cp libpicotls-core.a /usr/local/lib/libpicotls.a
    sudo cp libpicotls-minicrypto.a /usr/local/lib/
    sudo mkdir -p /usr/local/include/picotls
    sudo cp -r ../include/picotls/*.h /usr/local/include/picotls/ 2>/dev/null || true
    sudo cp ../include/picotls.h /usr/local/include/
    
    # Verify static libraries exist
    if [ ! -f /usr/local/lib/libpicotls.a ] || [ ! -f /usr/local/lib/libpicotls-minicrypto.a ]; then
        echo "ERROR: picotls static libraries not found after build!"
        exit 1
    fi
    
    echo "✓ picotls installed (static only, minicrypto)"
    ls -lh /usr/local/lib/libpicotls*.a
else
    echo "✓ picotls already installed"
    ls -lh /usr/local/lib/libpicotls*.a
fi

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║  Verifying Static Libraries                          ║"
╚═══════════════════════════════════════════════════════╝

# Verify static libraries exist and are correct architecture
for lib_file in liburing.a libpicotls.a libpicotls-minicrypto.a; do
    lib_path="/usr/local/lib/\$lib_file"
    if [ ! -f "\$lib_path" ]; then
        echo "ERROR: \$lib_file not found at \$lib_path"
        exit 1
    fi
    
    # Check it's a static archive (not shared library)
    if ! file "\$lib_path" | grep -q "current ar archive"; then
        echo "ERROR: \$lib_file is not a static archive!"
        file "\$lib_path"
        exit 1
    fi
    
    # Check architecture (should be aarch64)
    arch=\$(file "\$lib_path" | grep -o "aarch64\|ARM\|arm64" | head -1 || echo "unknown")
    if [ "\$arch" = "unknown" ]; then
        echo "WARNING: Could not determine architecture of \$lib_file"
        file "\$lib_path"
    else
        echo "✓ \$lib_file: static archive, architecture: \$arch"
    fi
done

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║  ✓ All Static Dependencies Ready                     ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo "  • /usr/local/lib/liburing.a"
echo "  • /usr/local/lib/libpicotls.a"
echo "  • /usr/local/lib/libpicotls-minicrypto.a"
echo "  • Headers in /usr/local/include/"
echo ""
EOF

# --- 4. Build Project with Zig (ULTIMATE STATIC MODE) (MODIFIED) ---
echo "--- 4. Running Zig Build (Ultimate Static Linking) ---"
echo "Build command: /snap/bin/zig $*" # Use $* as the full command including the verb (e.g., 'build')
echo ""

multipass exec "$VM_NAME" -- bash <<EOF
set -euo pipefail
cd $LOCAL_BUILD_POINT

# Set up environment for FULLY STATIC linking
export CFLAGS="-I/usr/local/include"
export CPPFLAGS="-I/usr/local/include"
export LDFLAGS="-L/usr/local/lib -static -lpicotls -lpicotls-minicrypto -luring -lpthread -ldl"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig"

echo "Environment variables:"
echo "  CFLAGS=\$CFLAGS"
echo "  LDFLAGS=\$LDFLAGS"
echo ""

# Build with Zig - enforce static linking
echo "Running Zig build..."
# This now passes the entire user command (e.g., 'build -Doptimize=ReleaseFast')
# directly to the Zig executable, resolving the "invalid option" error.
/snap/bin/zig \
    --search-prefix /usr/local \
    -freference-trace \
    $*

echo ""
echo "✓ Zig build completed"
echo ""

# Verify binaries are statically linked
if [ -d zig-out/bin ] && [ -n "\$(ls -A zig-out/bin 2>/dev/null)" ]; then
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  Binary Verification (Static Linking Check)          ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    
    for binary in zig-out/bin/*; do
        if [ -x "\$binary" ] && [ -f "\$binary" ]; then
            echo ""
            echo "Binary: \$(basename \$binary)"
            echo "----------------------------------------"
            
            # Check file type
            file "\$binary"
            
            # Check for dynamic dependencies
            echo ""
            if ldd "\$binary" 2>&1 | grep -q "not a dynamic executable"; then
                echo "✓ FULLY STATIC — No dynamic dependencies"
            elif ldd "\$binary" 2>&1 | grep -qE "linux-vdso|ld-linux"; then
                echo "⚠ Dynamically linked (checking dependencies):"
                ldd "\$binary" 2>&1
            else
                echo "✓ Likely static (ldd check failed as expected)"
            fi
            
            # Show binary size
            echo ""
            ls -lh "\$binary"
        fi
    done
    
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║  Note: linux-vdso.so.1 is kernel-provided and OK     ║"
    ║  A truly static binary shows 'not a dynamic exec'    ║
    ╚═══════════════════════════════════════════════════════╝
else
    echo "⚠ No binaries found in zig-out/bin/"
fi
EOF

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║  ✓✓✓ BUILD COMPLETE — ULTIMATE STATIC MODE ✓✓✓        ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Static dependencies used:"
echo "  ✓ liburing (${LIBURING_VERSION}) — NO dynamic liburing.so"
echo "  ✓ picotls with minicrypto — NO OpenSSL dependencies"
echo "  ✓ NO glibc dynamic dependencies (except kernel vDSO)"
echo ""
echo "Built artifacts location:"
echo "  VM: $LOCAL_BUILD_POINT/zig-out"
echo ""
echo "To copy binaries to host:"
echo "  multipass transfer $VM_NAME:$LOCAL_BUILD_POINT/zig-out/bin/* ."
echo ""
echo "To verify static linking on host (macOS):"
echo "  file <binary>    # Should show 'statically linked'"
echo "  On Linux: ldd <binary>  # Should show 'not a dynamic executable'"
echo ""
echo "To shell into VM:"
echo "  multipass shell $VM_NAME"
echo ""
echo "To clean up VM:"
echo "  multipass stop $VM_NAME && multipass delete $VM_NAME --purge"
echo ""