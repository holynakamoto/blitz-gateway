#!/bin/bash

# sync_artifacts_to_mac.sh - Pull build artifacts from VM to Mac and prepare for git

set -euo pipefail

echo "╔════════════════════════════════════════════════════════╗"
echo "║  Sync Build Artifacts from VM to Mac                  ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

VM_NAME="zig-build"
LOCAL_ARTIFACTS_DIR="./artifacts/aarch64-linux"

# 1. Create artifacts directory structure
echo "Creating artifacts directory..."
mkdir -p "$LOCAL_ARTIFACTS_DIR"
mkdir -p "./artifacts/checksums"
mkdir -p "./artifacts/metadata"

# 2. Transfer binaries from VM
echo ""
echo "Transferring binaries from VM..."
multipass transfer "$VM_NAME:/home/ubuntu/local_build/zig-out/bin/blitz" \
    "$LOCAL_ARTIFACTS_DIR/blitz"

multipass transfer "$VM_NAME:/home/ubuntu/local_build/zig-out/bin/quic_handshake_server" \
    "$LOCAL_ARTIFACTS_DIR/quic_handshake_server"

echo "✓ Binaries transferred"

# 3. Generate checksums
echo ""
echo "Generating checksums..."
shasum -a 256 "$LOCAL_ARTIFACTS_DIR"/* > "./artifacts/checksums/sha256sums.txt"
echo "✓ Checksums generated"

# 4. Get build metadata from VM
echo ""
echo "Collecting build metadata..."
multipass exec "$VM_NAME" -- bash <<'EOF' > "./artifacts/metadata/build_info.txt"
echo "Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
echo "Build Host: $(hostname)"
echo "Kernel: $(uname -r)"
echo "Zig Version: $(/snap/bin/zig version)"
echo ""
echo "Static Libraries:"
ls -lh /usr/local/lib/liburing*.a /usr/local/lib/libpicotls*.a
echo ""
echo "liburing version:"
cat /tmp/liburing/version 2>/dev/null || echo "liburing-2.7"
EOF

echo "✓ Metadata collected"

# 5. Verify binaries
echo ""
echo "Verifying binaries on Mac..."
for binary in "$LOCAL_ARTIFACTS_DIR"/*; do
    if [ -f "$binary" ] && [ -x "$binary" ]; then
        SIZE=$(du -h "$binary" | cut -f1)
        echo "  $(basename "$binary"): $SIZE"
        file "$binary"
    fi
done

# 6. Create .gitignore if not exists (optional - see options below)
if [ ! -f artifacts/.gitignore ]; then
    cat > artifacts/.gitignore <<'GITIGNORE'
# Ignore binaries by default (they're large)
# Remove these lines if you want to commit binaries to git
*.so
*.dylib
aarch64-linux/blitz
aarch64-linux/quic_handshake_server

# Keep metadata
!checksums/
!metadata/
GITIGNORE
    echo "✓ Created artifacts/.gitignore"
fi

# 7. Show summary
echo ""
echo "╔════════════════════════════════════════════════════════╗"
echo "║  Artifact Sync Complete                                ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Artifacts location: $LOCAL_ARTIFACTS_DIR"
ls -lh "$LOCAL_ARTIFACTS_DIR"
echo ""
echo "Checksums: ./artifacts/checksums/sha256sums.txt"
echo "Metadata: ./artifacts/metadata/build_info.txt"
echo ""

# 8. Git options
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Git Options:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "OPTION A - Commit only metadata (RECOMMENDED):"
echo "  git add artifacts/checksums/ artifacts/metadata/"
echo "  git commit -m 'build: update ARM64 build metadata'"
echo ""
echo "OPTION B - Commit binaries to git (NOT recommended for >1MB files):"
echo "  git add artifacts/"
echo "  git commit -m 'build: add ARM64 static binaries'"
echo ""
echo "OPTION C - Use Git LFS for binaries:"
echo "  git lfs track 'artifacts/aarch64-linux/*'"
echo "  git add .gitattributes artifacts/"
echo "  git commit -m 'build: add ARM64 binaries with LFS'"
echo ""
echo "OPTION D - Store in GitHub Releases (BEST for binaries):"
echo "  gh release create v1.0.0 \\"
echo "    ./artifacts/aarch64-linux/blitz \\"
echo "    ./artifacts/aarch64-linux/quic_handshake_server \\"
echo "    --title 'v1.0.0' \\"
echo "    --notes 'ARM64 static binaries'"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

