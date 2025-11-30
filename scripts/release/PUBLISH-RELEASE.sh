#!/bin/bash
# Publish Blitz Gateway Release
# Builds, packages, and publishes to APT and Docker

set -euo pipefail

VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: ./scripts/release/PUBLISH-RELEASE.sh VERSION"
    echo "Example: ./scripts/release/PUBLISH-RELEASE.sh 0.6.0"
    exit 1
fi

# Remove 'v' prefix if present
VERSION=${VERSION#v}
TAG="v${VERSION}"

echo "=========================================="
echo "🚀 Publishing Blitz Gateway v${VERSION}"
echo "=========================================="
echo ""

# Step 1: Verify we're on clean branch
if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Working directory is not clean. Commit or stash changes first."
    exit 1
fi

# Step 2: Check if tag already exists
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "⚠️  Tag $TAG already exists. Delete it first if you want to recreate:"
    echo "   git tag -d $TAG"
    echo "   git push origin :refs/tags/$TAG"
    exit 1
fi

# Step 3: Update version in files
echo "📝 Updating version to ${VERSION}..."
sed -i.bak "s/version: \".*\"/version: \"${VERSION}\"/" packaging/nfpm.yaml
sed -i.bak "s/\"0\\.6\\.0\"/\"${VERSION}\"/g" README.md || true
rm -f packaging/nfpm.yaml.bak README.md.bak

# Step 4: Commit version updates
git add packaging/nfpm.yaml README.md
git commit -m "Bump version to ${VERSION}" || echo "No changes to commit"

# Step 5: Create and push tag
echo ""
echo "🏷️  Creating tag ${TAG}..."
git tag -a "$TAG" -m "Release ${TAG}"

echo ""
echo "📤 Pushing to GitHub..."
git push origin main
git push origin "$TAG"

echo ""
echo "✅ Release tag pushed!"
echo ""
echo "GitHub Actions will now:"
echo "  ✓ Build .deb package"
echo "  ✓ Publish to GitHub Releases"
echo "  ✓ Publish to PackageCloud (if token configured)"
echo "  ✓ Build and push Docker images to GHCR"
echo ""
echo "Monitor progress at:"
echo "  https://github.com/holynakamoto/blitz-gateway/actions"
echo ""
echo "After workflows complete:"
echo "  1. Make Docker images public:"
echo "     https://github.com/holynakamoto/blitz-gateway/pkgs/container/blitz-gateway"
echo "  2. Test installation:"
echo "     curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash"
echo "  3. Test Docker:"
echo "     docker pull ghcr.io/holynakamoto/blitz-gateway:latest"

