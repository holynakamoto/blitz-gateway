# GitHub Badge Setup Guide

This guide explains how to set up all the badges shown in the README.md.

## ✅ Currently Working Badges

These badges should work immediately after pushing:

- **Stars/Forks**: Using shields.io (more reliable than badgen.net)
- **CI/Docker/Code Quality**: Workflow badges (will show status after workflows run)
- **License**: Should work automatically (Apache 2.0)
- **Issues**: Open/Closed issue counts
- **Zig Version**: Static badge (always works)

## 🔧 Badges That Need Setup

### 1. Release Badge (Shows "no releases found")

**Solution**: Create a GitHub release manually:

```bash
# Option 1: Using GitHub CLI (recommended)
gh release create v0.6.0 \
  --title "Blitz Gateway v0.6.0 - Production Ready" \
  --notes "🚀 Complete feature set with nuclear benchmarking capabilities

- Rate limiting + DoS protection (eBPF + userspace hybrid)
- Graceful reload + zero-downtime config changes  
- OpenTelemetry metrics + Prometheus/Grafana dashboard
- HTTP/3 0-RTT + TLS session resumption
- JWT authentication/authorization middleware
- WASM plugin system
- Production deployment guides (Docker/K8s/AWS/Helm)
- Comprehensive benchmarking suite (10M+ RPS target)

Ready to compete with the world's fastest proxies! ⚡"

# Option 2: Via GitHub Web UI
# 1. Go to https://github.com/holynakamoto/blitz-gateway/releases
# 2. Click "Draft a new release"
# 3. Select tag: v0.6.0
# 4. Add release title and description
# 5. Click "Publish release"
```

### 2. Codecov Badge (Shows "unknown")

**Solution**: Set up Codecov integration:

1. **Sign up for Codecov**:
   - Go to https://codecov.io
   - Sign in with GitHub
   - Add repository: `holynakamoto/blitz-gateway`

2. **Get Codecov Token** (if needed):
   - Copy the token from Codecov dashboard
   - Add to GitHub Secrets: `CODECOV_TOKEN`

3. **The badge will automatically update** after CI runs with coverage data

The CI workflow already includes Codecov upload in `.github/workflows/ci.yml`.

### 3. Docker Badges (Shows "repo not found")

**Solution**: Push Docker images to Docker Hub or GitHub Container Registry:

**Option A: Docker Hub**

1. Create Docker Hub account/repository
2. Update badges in README.md:
   ```markdown
   [![Docker Pulls](https://img.shields.io/docker/pulls/USERNAME/IMAGE)](https://hub.docker.com/r/USERNAME/IMAGE)
   ```

**Option B: GitHub Container Registry (ghcr.io) - Recommended**

The release workflow already pushes to `ghcr.io/holynakamoto/blitz-gateway`.

After the first release, add these badges:

```markdown
[![Docker Pulls](https://img.shields.io/github/downloads/holynakamoto/blitz-gateway/latest/total?label=ghcr%20pulls)](https://github.com/holynakamoto/blitz-gateway/pkgs/container/blitz-gateway)
```

### 4. Downloads Badge (Shows "no releases found")

**Solution**: After creating a GitHub release, this badge will automatically work.

## 🚀 Quick Fix Script

Run this to create a release and activate all badges:

```bash
# Make sure you have GitHub CLI installed
brew install gh

# Authenticate
gh auth login

# Create release
gh release create v0.6.0 \
  --title "🚀 Blitz Gateway v0.6.0 - Production Ready" \
  --notes-file <(cat <<EOF
## 🎉 Blitz Edge Gateway v0.6.0 - Production Ready!

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

Ready to compete with the world's fastest proxies! ⚡
EOF
)
```

## 📊 Badge Status Check

After setting up releases, verify badges work:

```bash
# Check if badges load
curl -I "https://img.shields.io/github/v/release/holynakamoto/blitz-gateway"
curl -I "https://github.com/holynakamoto/blitz-gateway/actions/workflows/ci.yml/badge.svg"
```

## 🎯 Badge Troubleshooting

**Badge shows "repo not found":**
- Check repository URL is correct: `holynakamoto/blitz-gateway`
- Verify repository is public (private repos have limited badge support)

**Workflow badge shows "failing":**
- Check GitHub Actions tab for workflow errors
- Ensure workflows are enabled in repository settings

**Release badge shows "no releases found":**
- Create a GitHub release (not just a tag)
- Wait 5-10 minutes for GitHub to update

**License badge shows "not identifiable":**
- License file is Apache 2.0 (correct)
- Badge should work, may need time to propagate

## 📝 Recommended Badge Order

For maximum impact, badges should appear in this order:

1. **Social proof** (Stars, Forks)
2. **Build status** (CI, Docker)
3. **Quality** (Code Quality, Codecov)
4. **Legal** (License)
5. **Activity** (Releases, Issues)
6. **Tech stack** (Zig version)
7. **Downloads** (Docker pulls, GitHub downloads)

This matches the current README.md layout.

