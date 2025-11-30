#!/usr/bin/env bash
# Create GitHub Release Script
# This creates a proper GitHub release (not just a tag) to activate release badges

set -euo pipefail

VERSION="${1:-v0.6.0}"
TITLE="${2:-🚀 Blitz Gateway ${VERSION} - Production Ready}"

echo "=========================================="
echo "🚀 Creating GitHub Release: ${VERSION}"
echo "=========================================="

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo "❌ GitHub CLI (gh) not found. Install with: brew install gh"
    echo ""
    echo "Alternative: Create release via GitHub web UI:"
    echo "https://github.com/holynakamoto/blitz-gateway/releases/new"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo "❌ Not authenticated with GitHub. Running: gh auth login"
    gh auth login
fi

# Release notes
RELEASE_NOTES=$(cat <<EOF
## 🎉 Blitz Edge Gateway ${VERSION} - Production Ready!

Complete feature set with nuclear benchmarking capabilities.

### ✅ Core Features
- Rate limiting + DoS protection (eBPF + userspace hybrid)
- Graceful reload + zero-downtime config changes  
- OpenTelemetry metrics + Prometheus/Grafana dashboard
- HTTP/3 0-RTT + TLS session resumption
- JWT authentication/authorization middleware
- WASM plugin system

### 🏭 Production Deployment
- Docker Compose (dev/staging/prod)
- Kubernetes + Helm charts
- AWS CloudFormation templates
- Bare metal deployment guides

### 🧪 Benchmarking
- Comprehensive benchmarking suite
- Nuclear benchmarks (10M+ RPS target)
- Automated CI/CD performance testing

### 📦 Installation

\`\`\`bash
# Docker
docker pull ghcr.io/holynakamoto/blitz-gateway:${VERSION}

# Binary (download from assets)
# Coming soon
\`\`\`

### 📚 Documentation

- [Quick Start](https://github.com/holynakamoto/blitz-gateway#quick-start)
- [Production Deployment](https://github.com/holynakamoto/blitz-gateway/tree/main/docs/production)
- [Benchmarking Guide](https://github.com/holynakamoto/blitz-gateway/tree/main/docs/benchmark)

Ready to compete with the world's fastest proxies! ⚡
EOF
)

# Create release
echo "Creating release ${VERSION}..."
gh release create "${VERSION}" \
  --title "${TITLE}" \
  --notes "${RELEASE_NOTES}" \
  --target main

echo ""
echo "✅ Release created successfully!"
echo ""
echo "🔗 View release: https://github.com/holynakamoto/blitz-gateway/releases/tag/${VERSION}"
echo ""
echo "⏱️  Badges will update in 5-10 minutes"

