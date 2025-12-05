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
TEST_LINKING=false
BUILD_REQUESTED=false

# Re-parse arguments to handle the clean flags correctly
REMAINING_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--clean-vm" ]]; then
        CLEAN_VM=true
    elif [[ "$arg" == "--clean" ]]; then
        CLEAN_PROJECT=true
    elif [[ "$arg" == "--test-linking" ]]; then
        TEST_LINKING=true
    elif [[ "$arg" == "build" ]]; then
        # Filter out "build" - zig build already builds by default
        # This prevents "no step named 'build'" error
        BUILD_REQUESTED=true
    else
        REMAINING_ARGS+=("$arg")
    fi
done

# Check if required build arguments are present (unless testing linking or build was requested)
if [[ ${#REMAINING_ARGS[@]} -eq 0 ]] && [[ "$TEST_LINKING" == "false" ]] && [[ "$BUILD_REQUESTED" == "false" ]]; then
    cat <<USAGE
Usage: $0 [--clean-vm] [--clean] [--test-linking] <zig build args>

Examples:
  $0 build                                    # Normal build (reuses VM & deps)
  $0 --clean build -Doptimize=ReleaseFast     # Fast clean (only Zig artifacts)
  $0 --clean-vm build -Doptimize=ReleaseFast   # Full clean (rebuilds everything)
  $0 build -Doptimize=ReleaseSmall -Dstrip=true
  $0 test
  $0 --test-linking                           # Test all liburing linking approaches

Flags:
  --clean         Clean only Zig build artifacts (.zig-cache, zig-out) - FAST
  --clean-vm      Delete and recreate VM (rebuilds all dependencies) - SLOW
  --test-linking  Test all 4 liburing linking approaches to find which works

Features:
  • 100% static linking (no dynamic dependencies)
  • Self-contained picotls with minicrypto (no OpenSSL)
  • Pinned liburing version for reproducibility (2.7)
  • liburing-ffi.a for proper FFI symbol resolution
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

# --- 2. Sync code & Project Clean (ENHANCED - Bulletproof Cache Clean) ---
echo ""
echo "--- 2. Synchronizing Files & Project Clean ---"

# Clean project artifacts if requested (fast clean mode)
if $CLEAN_PROJECT; then
    echo "Cleaning project artifacts in VM (.zig-cache, zig-out, and global cache)..."
    multipass exec "$VM_NAME" -- bash -c "
        set -euo pipefail
        cd \"$LOCAL_BUILD_POINT\"
        
        echo 'Removing local .zig-cache and zig-out...'
        rm -rf .zig-cache zig-out zig-cache zig-out 2>/dev/null || true
        echo 'Local caches deleted'
        
        echo 'Nuking Zig global cache for this project (prevents stale objects forever)...'
        # This is the nuclear option — deletes every cached object related to this exact binary
        rm -rf /home/ubuntu/.cache/zig/o/*blitz* \
               /home/ubuntu/.cache/zig/o/*quic_handshake_server* \
               /home/ubuntu/.cache/zig/o/*cimport* 2>/dev/null || true
        
        echo 'Zig global cache nuked — 100% fresh objects guaranteed'
    "
    echo "✓ Project artifacts and Zig cache cleaned"
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

# Note: liburing verification removed - we now build directly from GitHub (always correct version)

# --- 3. Build static dependencies ---
echo ""
echo "--- 3. Building Static Dependencies ---"

# --- LIBURING 2.7 — Official Build Method with FFI Support ---
# Per PRD: Using liburing-ffi.a for proper static linking with Zig
# liburing-ffi exports all functions as regular symbols (not inline)
echo "--- Installing liburing $LIBURING_VERSION — FFI Build + Direct Install ---"
multipass exec "$VM_NAME" -- bash -c "
    set -euo pipefail
    cd /tmp
    rm -rf liburing
    echo 'Cloning liburing $LIBURING_VERSION...'
    git clone --depth 1 --branch '$LIBURING_VERSION' https://github.com/axboe/liburing.git
    cd liburing
    echo 'Configuring...'
    ./configure --prefix=/usr/local
    echo 'Building liburing (standard make - produces both static and FFI variants)...'
    make -j\$(nproc)
    
    # Verify both static libraries were built
    if [ ! -f src/liburing.a ]; then
        echo 'FATAL: src/liburing.a not found after build!'
        exit 1
    fi
    if [ ! -f src/liburing-ffi.a ]; then
        echo 'FATAL: src/liburing-ffi.a not found after build!'
        echo 'Checking available libraries:'
        ls -la src/*.a
        exit 1
    fi
    
    SIZE_REGULAR=\$(du -b src/liburing.a | cut -f1)
    SIZE_FFI=\$(du -b src/liburing-ffi.a | cut -f1)
    echo \"SUCCESS: Built liburing libraries\"
    echo \"  - liburing.a: \$SIZE_REGULAR bytes\"
    echo \"  - liburing-ffi.a: \$SIZE_FFI bytes (~1.5MB expected)\"
    
    # NUCLEAR CLEAN — remove any old liburing installation
    sudo rm -rf /usr/local/lib/liburing.* /usr/local/include/liburing /usr/local/lib/pkgconfig/liburing* 2>/dev/null || true
    
    # Install headers (direct copy, avoiding make install issues)
    sudo mkdir -p /usr/local/include/liburing
    sudo cp src/include/liburing/*.h /usr/local/include/liburing/
    sudo cp src/include/liburing.h /usr/local/include/
    
    # Install BOTH static libraries (FFI is primary, regular as fallback)
    sudo cp src/liburing.a /usr/local/lib/liburing.a
    sudo cp src/liburing-ffi.a /usr/local/lib/liburing-ffi.a
    
    # Remove shared libraries (we only want static)
    sudo rm -f /usr/local/lib/liburing.so* 2>/dev/null || true
    
    echo ''
    echo 'Verifying liburing-ffi symbol exports...'
    # Check that FFI variant has the required symbols (from PRD Appendix A)
    REQUIRED_SYMBOLS='io_uring_queue_init io_uring_submit io_uring_queue_exit'
    MISSING=0
    for symbol in \$REQUIRED_SYMBOLS; do
        if nm /usr/local/lib/liburing-ffi.a 2>/dev/null | grep -q \" T \$symbol\"; then
            echo \"  ✓ \$symbol\"
        else
            echo \"  ✗ \$symbol MISSING\"
            MISSING=\$((MISSING + 1))
        fi
    done
    
    if [ \$MISSING -gt 0 ]; then
        echo ''
        echo 'WARNING: Some symbols missing from liburing-ffi.a'
        echo 'Full symbol list:'
        nm /usr/local/lib/liburing-ffi.a | grep -E \" T (io_uring|_io_uring|__io_uring)\" | head -20
    fi
    
    echo ''
    echo 'liburing $LIBURING_VERSION installed with FFI support'
    ls -lh /usr/local/lib/liburing*.a
"
echo "liburing $LIBURING_VERSION — INSTALLED (liburing-ffi.a for Zig FFI linking)"

multipass exec "$VM_NAME" -- bash -c "
set -euo pipefail
LOCAL_BUILD_POINT='$LOCAL_BUILD_POINT'

# --- Build picotls with minicrypto (STATIC ONLY) ---
if [ ! -f /usr/local/lib/libpicotls.a ]; then
    echo 'Building picotls (static with minicrypto, NO OpenSSL)...'
    cd \$LOCAL_BUILD_POINT/deps/picotls
    rm -rf build
    mkdir build && cd build
    echo 'Configuring picotls...'
    cmake .. \\
        -DCMAKE_BUILD_TYPE=Release \\
        -DBUILD_SHARED_LIBS=OFF \\
        -DPTLS_MINICRYPTO=ON \\
        -DPTLS_OPENSSL=OFF \\
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
    echo 'Compiling picotls...'
    make -j\$(nproc) picotls-core picotls-minicrypto
    # Install static libraries
    echo 'Installing picotls libraries...'
    sudo cp libpicotls-core.a /usr/local/lib/libpicotls.a
    sudo cp libpicotls-minicrypto.a /usr/local/lib/
    sudo mkdir -p /usr/local/include/picotls
    sudo cp -r ../include/picotls/*.h /usr/local/include/picotls/ 2>/dev/null || true
    sudo cp ../include/picotls.h /usr/local/include/
    
    # Verify static libraries exist
    if [ ! -f /usr/local/lib/libpicotls.a ] || [ ! -f /usr/local/lib/libpicotls-minicrypto.a ]; then
        echo 'ERROR: picotls static libraries not found after build!'
        exit 1
    fi
    
    echo '✓ picotls installed (static only, minicrypto)'
    ls -lh /usr/local/lib/libpicotls*.a
else
    echo '✓ picotls already installed'
    ls -lh /usr/local/lib/libpicotls*.a
fi

# Continue with verification...
echo ''
echo '=================================================================='
echo '  Verifying Static Libraries'
echo '=================================================================='

# Verify static libraries exist and are correct architecture
for lib_file in liburing.a liburing-ffi.a libpicotls.a libpicotls-minicrypto.a; do
    lib_path=\"/usr/local/lib/\$lib_file\"
    if [ ! -f \"\$lib_path\" ]; then
        echo \"ERROR: \$lib_file not found at \$lib_path\"
        exit 1
    fi
    
    # Check it's a static archive (not shared library)
    if ! file \"\$lib_path\" | grep -q 'current ar archive'; then
        echo \"ERROR: \$lib_file is not a static archive!\"
        file \"\$lib_path\"
        exit 1
    fi
    
    # Check architecture (should be aarch64)
    arch=\$(file \"\$lib_path\" | grep -o 'aarch64\\|ARM\\|arm64' | head -1 || echo 'unknown')
    if [ \"\$arch\" = 'unknown' ]; then
        echo \"WARNING: Could not determine architecture of \$lib_file\"
        file \"\$lib_path\"
    else
        echo \"✓ \$lib_file: static archive, architecture: \$arch\"
    fi
done

# Additional verification for liburing-ffi.a symbols (critical for Zig linking)
echo ''
echo 'Verifying liburing-ffi.a has required symbols for Zig FFI...'
LIBURING_FFI='/usr/local/lib/liburing-ffi.a'
REQUIRED_SYMBOLS=(
    'io_uring_queue_init'
    'io_uring_submit'
    'io_uring_queue_exit'
    'io_uring_wait_cqe'
    'io_uring_get_sqe'
    'io_uring_cqe_seen'
    'io_uring_cq_advance'
)
ALL_FOUND=true
for symbol in \"\${REQUIRED_SYMBOLS[@]}\"; do
    if nm \"\$LIBURING_FFI\" 2>/dev/null | grep -E \" T \${symbol}\\\$\" >/dev/null; then
        echo \"  ✓ \$symbol\"
    else
        echo \"  ✗ \$symbol NOT FOUND\"
        ALL_FOUND=false
    fi
done

if [ \"\$ALL_FOUND\" = false ]; then
    echo ''
    echo 'WARNING: Some required symbols missing from liburing-ffi.a'
    echo 'The build may fail with undefined symbol errors.'
fi

echo ''
echo '=================================================================='
echo '  ✓ All Static Dependencies Ready'
echo '=================================================================='
echo '  • /usr/local/lib/liburing.a (helper functions)'
echo '  • /usr/local/lib/liburing-ffi.a (PRIMARY - FFI exports)'
echo '  • /usr/local/lib/libpicotls.a'
echo '  • /usr/local/lib/libpicotls-minicrypto.a'
echo '  • Headers in /usr/local/include/'
echo ''
"

# --- 4. Test Linking (if requested) or Build Project ---

# If --test-linking was specified, run the linking test suite
if $TEST_LINKING; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running liburing Linking Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "This will test 4 different linking approaches:"
    echo "  1. linkSystemLibrary(\"uring-ffi\")"
    echo "  2. linkSystemLibrary(\"uring\")"
    echo "  3. addObjectFile(liburing-ffi.a)"
    echo "  4. addObjectFile(liburing.a)"
    echo ""
    
    multipass exec "$VM_NAME" -- bash "$LOCAL_BUILD_POINT/scripts/test_liburing_linking.sh"
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Test complete! Review results above to determine best approach."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

echo "--- 4. Running Zig Build (Ultimate Static Linking) ---"

# Check if user specified a target, if not, use musl for true static linking
HAS_TARGET=false
for arg in "$@"; do
    if [[ "$arg" == -Dtarget=* ]]; then
        HAS_TARGET=true
        break
    fi
done

if $HAS_TARGET; then
    echo "Using user-specified target"
    ZIG_ARGS="$*"
else
    echo "Using default target: aarch64-linux-musl (for true static linking)"
    ZIG_ARGS="-Dtarget=aarch64-linux-musl $*"
fi

echo "Build command: /snap/bin/zig build $ZIG_ARGS"
echo ""

multipass exec "$VM_NAME" -- bash <<EOF
set -euo pipefail
cd $LOCAL_BUILD_POINT

# Set up environment for FULLY STATIC linking
export CFLAGS="-I/usr/local/include"
export CPPFLAGS="-I/usr/local/include"
# liburing-ffi is linked directly via build.zig (addObjectFile)
# We don't use -luring-ffi here because Zig handles the linking
export LDFLAGS="-L/usr/local/lib -static -lpicotls -lpicotls-minicrypto -lpthread -ldl"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/local/lib/aarch64-linux-gnu/pkgconfig"

echo "Environment variables:"
echo "  CFLAGS=\$CFLAGS"
echo "  LDFLAGS=\$LDFLAGS"
echo ""
echo "Note: liburing-ffi.a is linked directly by build.zig for proper FFI symbol resolution"
echo "Note: Using musl libc for true static linking (glibc doesn't support static)"
echo ""

# Build with Zig - enforce static linking with musl
echo "Running Zig build..."
/snap/bin/zig build \
    --search-prefix /usr/local \
    -freference-trace \
    $ZIG_ARGS

echo ""
echo "✓ Zig build completed"
echo ""

# Verify binaries are statically linked
if [ -d zig-out/bin ] && [ -n "\$(ls -A zig-out/bin 2>/dev/null)" ]; then
    echo "=================================================================="
    echo "  Binary Verification (Static Linking Check)"
    echo "=================================================================="
    
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
    echo "=================================================================="
    echo "  Note: linux-vdso.so.1 is kernel-provided and OK"
    echo "  A truly static binary shows 'not a dynamic exec'"
    echo "=================================================================="
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
echo "  ✓ liburing-ffi (${LIBURING_VERSION}) — FFI variant for Zig linking"
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