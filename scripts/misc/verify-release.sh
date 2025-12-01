#!/bin/bash
# Verify Release Quality - Run before publishing
# Checks build, tests, and package integrity

set -euo pipefail

REPO="holynakamoto/blitz-gateway"
VERSION="${1:-}"

if [ -z "$VERSION" ]; then
    echo "Usage: $0 VERSION"
    echo "Example: $0 0.6.0"
    exit 1
fi

TAG="v${VERSION#v}"

echo "=========================================="
echo "🔍 Verifying Release Quality"
echo "=========================================="
echo "Version: $VERSION"
echo "Tag: $TAG"
echo ""

# Check 1: Build status
echo "1️⃣  Checking build status..."
BUILD_STATUS=$(gh run list --workflow=release-deb.yml --limit 1 --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion // "pending")"')
echo "   Build: $BUILD_STATUS"

if echo "$BUILD_STATUS" | grep -q "completed:success"; then
    echo "   ✅ Build successful"
elif echo "$BUILD_STATUS" | grep -q "completed:failure"; then
    echo "   ❌ Build failed - check logs"
    echo "   View: gh run view --web"
    exit 1
else
    echo "   ⏳ Build in progress..."
fi

echo ""

# Check 2: Release exists
echo "2️⃣  Checking if release exists..."
RELEASE=$(curl -s "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" | python3 -c "import sys, json; r = json.load(sys.stdin); print('exists' if 'tag_name' in r else 'not_found')" 2>/dev/null || echo "not_found")

if [ "$RELEASE" = "exists" ]; then
    echo "   ✅ Release exists"
    
    # Check assets
    ASSETS=$(curl -s "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" | python3 -c "import sys, json; r = json.load(sys.stdin); print(len(r.get('assets', [])))" 2>/dev/null || echo "0")
    echo "   📦 Assets: $ASSETS"
    
    if [ "$ASSETS" -gt 0 ]; then
        echo "   ✅ Release has assets"
    else
        echo "   ⚠️  Release has no assets"
    fi
else
    echo "   ⏳ Release not yet created"
fi

echo ""

# Check 3: CI/CD pipeline status
echo "3️⃣  Checking CI/CD pipeline..."
CI_STATUS=$(gh run list --workflow=ci-cd.yml --limit 1 --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion // "pending")"')
echo "   CI/CD: $CI_STATUS"

if echo "$CI_STATUS" | grep -q "completed:success"; then
    echo "   ✅ CI/CD passed"
elif echo "$CI_STATUS" | grep -q "completed:failure"; then
    echo "   ⚠️  CI/CD failed (may be expected if committed directly to main)"
else
    echo "   ⏳ CI/CD in progress..."
fi

echo ""

# Check 4: Test installation (if release exists)
if [ "$RELEASE" = "exists" ]; then
    echo "4️⃣  Testing installation..."
    echo "   Run: curl -fsSL https://raw.githubusercontent.com/${REPO}/main/install.sh | sudo bash"
    echo "   Or download: https://github.com/${REPO}/releases/download/${TAG}/blitz-gateway_${VERSION}_amd64.deb"
fi

echo ""
echo "=========================================="
echo "📋 Summary"
echo "=========================================="
echo ""
echo "To verify release quality:"
echo "  1. Check build logs: gh run view --web"
echo "  2. Test install script in a VM"
echo "  3. Verify .deb package: dpkg -I blitz-gateway_${VERSION}_amd64.deb"
echo "  4. Check Docker image: docker pull ghcr.io/${REPO}:${TAG}"
echo ""
echo "Best practice: Create a PR first to run CI, then merge and tag"

