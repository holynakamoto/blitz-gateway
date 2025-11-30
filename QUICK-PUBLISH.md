# Quick Start: Publish to APT and Docker

## One-Command Release

```bash
./PUBLISH-RELEASE.sh 0.6.0
```

That's it! This will:
1. ✅ Build .deb package
2. ✅ Publish to GitHub Releases
3. ✅ Publish to PackageCloud (if configured)
4. ✅ Build and push Docker images to GHCR

## Prerequisites (One-Time Setup)

### 1. PackageCloud Token (Optional - for APT repo)

```bash
# 1. Sign up at https://packagecloud.io (free for OSS)
# 2. Create repository: "holynakamoto/blitz-gateway"
# 3. Get API token from Settings → API Tokens
# 4. Add to GitHub Secrets:
#    Repository → Settings → Secrets → Actions → New secret
#    Name: PACKAGECLOUD_TOKEN
#    Value: <your-token>
```

### 2. GitHub Permissions

Already configured! GitHub Actions has write permissions automatically.

## What Gets Published

### APT Package
- **Location**: GitHub Releases + PackageCloud (if configured)
- **Install**: `curl -fsSL ... | sudo bash`
- **File**: `blitz-gateway_0.6.0_amd64.deb`

### Docker Images
- **Registry**: `ghcr.io/holynakamoto/blitz-gateway`
- **Tags**: 
  - `:latest` (production)
  - `:v0.6.0` (versioned)
  - `:v0.6.0-dev` (development)
  - `:v0.6.0-minimal` (minimal)

## After Publishing

### Make Docker Images Public

Docker images are private by default. Make them public:

1. Go to: https://github.com/holynakamoto/blitz-gateway/pkgs/container/blitz-gateway
2. Click "Package settings"
3. Under "Danger Zone" → "Change visibility"
4. Select "Public"

### Test Installation

```bash
# APT
curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash

# Docker
docker pull ghcr.io/holynakamoto/blitz-gateway:latest
docker run --rm ghcr.io/holynakamoto/blitz-gateway:latest --help
```

## Full Documentation

- **Detailed Guide**: `docs/packaging/PUBLISHING.md`
- **Checklist**: `RELEASE-CHECKLIST.md`
- **Packaging Docs**: `packaging/README.md`

