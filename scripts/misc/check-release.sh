#!/bin/bash
# Check Blitz Gateway Release Status

set -euo pipefail

VERSION="${1:-latest}"
REPO="holynakamoto/blitz-gateway"

echo "=========================================="
echo "🔍 Checking Release Status"
echo "=========================================="
echo ""

if [ "$VERSION" = "latest" ]; then
    echo "📦 Checking latest release..."
    RESPONSE=$(curl -s "https://api.github.com/repos/${REPO}/releases/latest")
    
    if echo "$RESPONSE" | grep -q '"message"'; then
        echo "❌ No releases found"
        echo ""
        echo "Check workflow status:"
        echo "  https://github.com/${REPO}/actions"
    else
        TAG=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null || echo "unknown")
        PUBLISHED=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('published_at', 'Not published'))" 2>/dev/null || echo "unknown")
        ASSETS=$(echo "$RESPONSE" | python3 -c "import sys, json; assets = json.load(sys.stdin).get('assets', []); print(f'{len(assets)} asset(s)')" 2>/dev/null || echo "unknown")
        
        echo "✅ Latest release: $TAG"
        echo "   Published: $PUBLISHED"
        echo "   Assets: $ASSETS"
        echo ""
        echo "🔗 View release: https://github.com/${REPO}/releases/tag/${TAG}"
    fi
else
    TAG="v${VERSION#v}"
    echo "📦 Checking release: $TAG"
    RESPONSE=$(curl -s "https://api.github.com/repos/${REPO}/releases/tags/${TAG}")
    
    if echo "$RESPONSE" | grep -q '"message"'; then
        echo "❌ Release $TAG not found"
    else
        PUBLISHED=$(echo "$RESPONSE" | python3 -c "import sys, json; print(json.load(sys.stdin).get('published_at', 'Not published'))" 2>/dev/null || echo "unknown")
        ASSETS=$(echo "$RESPONSE" | python3 -c "import sys, json; assets = json.load(sys.stdin).get('assets', []); print(f'{len(assets)} asset(s)')" 2>/dev/null || echo "unknown")
        
        echo "✅ Release $TAG exists"
        echo "   Published: $PUBLISHED"
        echo "   Assets: $ASSETS"
        echo ""
        echo "🔗 View release: https://github.com/${REPO}/releases/tag/${TAG}"
    fi
fi

echo ""
echo "=========================================="
echo "🔄 Checking Workflow Status"
echo "=========================================="
echo ""

WORKFLOW_RUNS=$(curl -s "https://api.github.com/repos/${REPO}/actions/workflows/release-deb.yml/runs?per_page=1")
STATUS=$(echo "$WORKFLOW_RUNS" | python3 -c "import sys, json; run = json.load(sys.stdin)['workflow_runs'][0]; print(f\"Status: {run['status']}\nConclusion: {run.get('conclusion', 'pending')}\nURL: {run['html_url']}\")" 2>/dev/null || echo "Could not fetch workflow status")

echo "$STATUS"
echo ""
echo "🔗 View all workflows: https://github.com/${REPO}/actions"

