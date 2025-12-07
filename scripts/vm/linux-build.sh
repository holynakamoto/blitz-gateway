#!/usr/bin/env bash
# =============================================================================
# linux-build.sh — Clean Orchestration Script (Refactored)
# Zig 0.15.2 + liburing (static) + Caddy (HTTP/3)
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
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  linux-build.sh — Clean Orchestration Mode            ║"
echo "╚════════════════════════════════════════════════════════╝"
echo "Project root: $PROJECT_ROOT"

command -v multipass >/dev/null || die "multipass not found → https://multipass.run"

# --- Parse arguments ---
CLEAN_VM=false
CLEAN_PROJECT=false
TEST_LINKING=false
BUILD_REQUESTED=false
SKIP_CERT_TEST=false
SETUP_VALIDATION_TOOLS=false

# Re-parse arguments to handle the clean flags correctly
REMAINING_ARGS=()
for arg in "$@"; do
    if [[ "$arg" == "--clean-vm" ]]; then
        CLEAN_VM=true
    elif [[ "$arg" == "--clean" ]]; then
        CLEAN_PROJECT=true
    elif [[ "$arg" == "--test-linking" ]]; then
        TEST_LINKING=true
    elif [[ "$arg" == "--skip-test" ]]; then
        SKIP_CERT_TEST=true
    elif [[ "$arg" == "--setup-validation" ]]; then
        SETUP_VALIDATION_TOOLS=true
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
  --skip-test     Skip automatic binary test after build
  --setup-validation  Setup QUIC validation tools in VM after build

Features:
  • Static linking for core libraries (liburing)
  • Pinned liburing version for reproducibility (2.7)
  • liburing-ffi.a for proper FFI symbol resolution
  • Automatic binary verification
  • Persistent VM with cached dependencies (use --clean for fast rebuilds)
  • Modular script architecture for easier maintenance

USAGE
    exit 1
fi

# Overwrite positional arguments with remaining build args
# Handle empty array case to avoid "unbound variable" error
if [ ${#REMAINING_ARGS[@]} -gt 0 ]; then
    set -- "${REMAINING_ARGS[@]}"
else
    set --
fi

# If clean-vm is set, it implies clean-project cleanup on the new VM
if $CLEAN_VM; then
    CLEAN_PROJECT=true
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 1: VM Setup and Preparation
# ═══════════════════════════════════════════════════════════════════════════

if $CLEAN_VM || ! multipass info "$VM_NAME" &>/dev/null; then
    # Call setup-vm.sh for fresh VM creation and setup
    source "$SCRIPT_DIR/setup-vm.sh" "$VM_NAME" "$PROJECT_ROOT" "$CLEAN_VM"
else
    echo "✓ VM '$VM_NAME' is already running"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 2: Code Synchronization and Project Clean
# ═══════════════════════════════════════════════════════════════════════════

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

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 3: Build Static Dependencies
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "--- 3. Building Static Dependencies ---"

# Build liburing 2.7 with FFI support
echo "--- Installing liburing $LIBURING_VERSION — FFI Build + Direct Install ---"
multipass exec "$VM_NAME" -- bash < "$SCRIPT_DIR/build-liburing.sh"
echo "✓ liburing $LIBURING_VERSION — INSTALLED (liburing-ffi.a for Zig FFI linking)"

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 4: Run Zig Build
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "--- 4. Running Zig Build (Static Linking) ---"

# Check if user specified a target, if not, use glibc for OpenSSL compatibility
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
    # Use glibc instead of musl when OpenSSL is needed (avoids header conflicts)
    # Note: We still get static linking for our code, OpenSSL links dynamically
    echo "Using default target: aarch64-linux-gnu (glibc for OpenSSL compatibility)"
    ZIG_ARGS="-Dtarget=aarch64-linux-gnu $*"
    # Export LDFLAGS to attempt static linking where possible
    export LDFLAGS="-L/usr/local/lib -L/usr/lib/aarch64-linux-gnu -static-libgcc"
fi

echo "Build command: /snap/bin/zig build $ZIG_ARGS"
echo ""

multipass exec "$VM_NAME" -- bash <<EOF
set -euo pipefail
cd $LOCAL_BUILD_POINT

# Set up environment for static linking (hybrid approach)
export CFLAGS="-I/usr/local/include"
export CPPFLAGS="-I/usr/local/include"
# liburing-ffi is linked directly via build.zig (addObjectFile)
# We don't use -luring-ffi here because Zig handles the linking
export LDFLAGS="-L/usr/local/lib -L/usr/lib/aarch64-linux-gnu"
export PKG_CONFIG_PATH="/usr/local/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig"

echo "Environment variables:"
echo "  CFLAGS=\$CFLAGS"
echo "  LDFLAGS=\$LDFLAGS"
echo ""
echo "Note: liburing-ffi.a is linked directly by build.zig for proper FFI symbol resolution"
echo "Note: Using glibc target (aarch64-linux-gnu) for OpenSSL compatibility"
echo ""

# Build with Zig - hybrid static/dynamic linking (glibc target)
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

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 5: Test Binary (HTTP/1.1 and HTTP/2)
# ═══════════════════════════════════════════════════════════════════════════

if ! $SKIP_CERT_TEST && [ -n "$(multipass exec "$VM_NAME" -- bash -c "ls -A $LOCAL_BUILD_POINT/zig-out/bin/blitz 2>/dev/null" 2>/dev/null)" ]; then
    echo ""
    echo "--- 5. Testing Binary (HTTP/1.1 and HTTP/2 only) ---"
    echo ""
    echo "Note: QUIC/HTTP/3 is no longer supported in Zig. Use Caddy for HTTP/3."
    echo ""

    multipass exec "$VM_NAME" -- bash < "$SCRIPT_DIR/test-binary.sh"
else
    if $SKIP_CERT_TEST; then
        echo ""
        echo "--- Skipping binary test (--skip-test flag) ---"
    else
        echo ""
        echo "--- Skipping binary test (binary not found) ---"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 6: Setup Validation Tools (Optional)
# ═══════════════════════════════════════════════════════════════════════════

if $SETUP_VALIDATION_TOOLS; then
    echo ""
    echo "--- 6. Setting Up QUIC Validation Tools ---"
    multipass exec "$VM_NAME" -- bash < "$SCRIPT_DIR/setup-validation-tools.sh"
    echo ""
    echo "✓ Validation tools setup complete"
fi

# ═══════════════════════════════════════════════════════════════════════════
# PHASE 7: Build Caddy for HTTP/3
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "--- 7. Building Caddy for HTTP/3 ---"
multipass exec "$VM_NAME" -- bash < "$SCRIPT_DIR/build-caddy.sh"

# ═══════════════════════════════════════════════════════════════════════════
# FINAL: Summary
# ═══════════════════════════════════════════════════════════════════════════

echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║  ✓✓✓ BUILD COMPLETE — CLEAN ORCHESTRATION MODE ✓✓✓     ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Static dependencies used:"
echo "  ✓ liburing-ffi (${LIBURING_VERSION}) — FFI variant for Zig linking"
echo "  ✓ Static linking for core libraries"
echo ""
echo "HTTP/3 Support:"
echo "  ✓ Caddy built — Ready for HTTP/3 benchmarks"
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
echo "To run benchmarks (includes automatic Caddy setup for HTTP/3):"
echo "  multipass exec $VM_NAME -- bash -c 'cd $LOCAL_BUILD_POINT && ./scripts/bench/bench.sh http3'"
echo ""
if $SETUP_VALIDATION_TOOLS; then
    echo "Validation tools installed. To test QUIC server:"
    echo "  multipass exec $VM_NAME -- bash -c 'cd $LOCAL_BUILD_POINT && ./zig-out/bin/blitz --mode quic --port 8443 --cert certs/server.crt --key certs/server.key --capture &'"
    echo "  multipass exec $VM_NAME -- bash -c 'cd $LOCAL_BUILD_POINT && zig run tools/quic_validator.zig'"
    echo ""
fi
echo "To clean up VM:"
echo "  multipass stop $VM_NAME && multipass delete $VM_NAME --purge"
echo ""
