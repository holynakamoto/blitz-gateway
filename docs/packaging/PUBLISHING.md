# Publishing Blitz Gateway to APT and Docker

Complete guide for publishing releases to both APT repositories and Docker registries.

## Overview

Blitz Gateway is published to:
- **APT Repository**: PackageCloud (free for OSS) + GitHub Releases
- **Docker Registry**: GitHub Container Registry (`ghcr.io/holynakamoto/blitz-gateway`)

## Prerequisites

### GitHub Secrets Required

Set these in: Repository → Settings → Secrets and variables → Actions

1. **`PACKAGECLOUD_TOKEN`** (Optional - for APT repo)
   - Get from: https://packagecloud.io/api#api_tokens
   - Required only if using PackageCloud (recommended)

### GitHub Packages Permissions

Ensure GitHub Actions has write access:
- Repository → Settings → Actions → General
- Under "Workflow permissions", enable "Read and write permissions"

## Publishing a Release

### Step 1: Create Git Tag

```bash
# Set version
VERSION="0.6.0"

# Create and push tag
git tag -a "v${VERSION}" -m "Release v${VERSION}"
git push origin "v${VERSION}"
```

### Step 2: GitHub Actions Automatically

When you push a tag starting with `v*.*.*`, GitHub Actions automatically:

1. **Builds .deb package**
   - Builds optimized binary
   - Creates .deb using nfpm
   - Uploads to GitHub Releases

2. **Publishes to APT** (if configured)
   - Uploads to PackageCloud
   - Available via `apt install blitz-gateway`

3. **Builds Docker images**
   - Production image: `ghcr.io/holynakamoto/blitz-gateway:latest`
   - Development image: `ghcr.io/holynakamoto/blitz-gateway:latest-dev`
   - Minimal image: `ghcr.io/holynakamoto/blitz-gateway:latest-minimal`
   - Version tags: `ghcr.io/holynakamoto/blitz-gateway:v0.6.0`

4. **Creates GitHub Release**
   - Includes .deb package
   - Release notes with changelog

## APT Repository Setup

### Option 1: PackageCloud (Recommended)

1. **Create PackageCloud Account**
   - Sign up: https://packagecloud.io/signup
   - Free for open source projects

2. **Create Repository**
   - Dashboard → New Repository
   - Name: `blitz-gateway`
   - Visibility: Public

3. **Get API Token**
   - Settings → API Tokens
   - Create new token
   - Copy token

4. **Add to GitHub Secrets**
   ```bash
   # Add as secret: PACKAGECLOUD_TOKEN
   ```

5. **Update Install Script** (if needed)
   The install script downloads from GitHub Releases by default.
   To use PackageCloud, update `install.sh` to add the repo.

### Option 2: GitHub Releases Only

If not using PackageCloud, users can install from GitHub Releases:

```bash
# Manual download and install
wget https://github.com/holynakamoto/blitz-gateway/releases/download/v0.6.0/blitz-gateway_0.6.0_amd64.deb
sudo dpkg -i blitz-gateway_0.6.0_amd64.deb
```

## Docker Publishing

### Images Published

On each release tag, these images are published:

| Image | Tag Pattern | Description |
|-------|-------------|-------------|
| Production | `:latest`, `:v0.6.0` | Optimized production server |
| Development | `:latest-dev`, `:v0.6.0-dev` | Development tools included |
| Minimal | `:latest-minimal`, `:v0.6.0-minimal` | Ultra-minimal scratch image |

### Pull and Run

```bash
# Pull latest
docker pull ghcr.io/holynakamoto/blitz-gateway:latest

# Run
docker run -d \
  --name blitz-gateway \
  -p 8443:8443/udp \
  ghcr.io/holynakamoto/blitz-gateway:latest
```

### Make Images Public

By default, GitHub Container Registry images are private. To make them public:

1. Go to: https://github.com/holynakamoto/blitz-gateway/pkgs/container/blitz-gateway
2. Click "Package settings"
3. Under "Danger Zone", click "Change visibility"
4. Select "Public"

## Manual Publishing

### Build and Publish .deb Locally

```bash
# Build package
./packaging/build-deb.sh 0.6.0

# Upload to PackageCloud manually
package_cloud push holynakamoto/blitz-gateway/ubuntu/jammy dist/*.deb

# Or upload to GitHub Releases manually via web UI
```

### Build and Publish Docker Locally

```bash
# Login to GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Build and push
docker buildx build --platform linux/amd64,linux/arm64 \
  --target prod \
  -t ghcr.io/holynakamoto/blitz-gateway:latest \
  -t ghcr.io/holynakamoto/blitz-gateway:v0.6.0 \
  --push .
```

## Verification

### Check APT Package

```bash
# If using PackageCloud
curl https://packagecloud.io/holynakamoto/blitz-gateway/ubuntu/dists/

# Check GitHub Release
curl https://api.github.com/repos/holynakamoto/blitz-gateway/releases/latest
```

### Check Docker Images

```bash
# List available tags
curl https://ghcr.io/v2/holynakamoto/blitz-gateway/tags/list

# Pull and verify
docker pull ghcr.io/holynakamoto/blitz-gateway:latest
docker inspect ghcr.io/holynakamoto/blitz-gateway:latest
```

## Troubleshooting

### APT Publishing Fails

- **Check token**: Ensure `PACKAGECLOUD_TOKEN` is set correctly
- **Check repo**: Verify repository exists on PackageCloud
- **Check permissions**: Token needs write access

### Docker Publishing Fails

- **Check permissions**: GitHub Actions needs `packages: write` permission
- **Check visibility**: Images may be private by default
- **Check workflow**: View Actions tab for error details

### Images Not Public

- Manually change visibility in GitHub Package settings
- Or add workflow step to set visibility (requires additional API calls)

## Next Steps

After first release:

1. **Test installation**: `curl -fsSL ... | sudo bash`
2. **Test Docker**: `docker pull ghcr.io/holynakamoto/blitz-gateway:latest`
3. **Update documentation**: Link to installation methods
4. **Announce release**: Update README, create announcement

