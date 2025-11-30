# Release Checklist

Complete checklist for publishing Blitz Gateway to APT and Docker.

## Pre-Release

- [ ] All tests passing (`zig build test`)
- [ ] Version updated in `nfpm.yaml`
- [ ] CHANGELOG.md updated (if exists)
- [ ] Documentation reviewed

## GitHub Secrets Setup

- [ ] `PACKAGECLOUD_TOKEN` added (optional - for APT repo)
  - Get from: https://packagecloud.io/api#api_tokens
  - Add at: Repository → Settings → Secrets → Actions

## Package Permissions

- [ ] GitHub Actions has write permissions
  - Repository → Settings → Actions → General
  - Enable "Read and write permissions"

## Publishing Release

### Option 1: Automated Script

```bash
./PUBLISH-RELEASE.sh 0.6.0
```

This will:
- Update version in files
- Create and push git tag
- Trigger GitHub Actions workflows

### Option 2: Manual

```bash
# Set version
VERSION="0.6.0"
TAG="v${VERSION}"

# Update version in nfpm.yaml
sed -i "s/version: \".*\"/version: \"${VERSION}\"/" nfpm.yaml
git add nfpm.yaml
git commit -m "Bump version to ${VERSION}"

# Create and push tag
git tag -a "$TAG" -m "Release ${TAG}"
git push origin main
git push origin "$TAG"
```

## Post-Release Verification

### APT Package

- [ ] Check GitHub Release created
  - https://github.com/holynakamoto/blitz-gateway/releases
  - Should contain `.deb` file

- [ ] Check PackageCloud (if configured)
  - https://packagecloud.io/holynakamoto/blitz-gateway
  - Package should appear in repository

- [ ] Test installation
  ```bash
  curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash
  ```

### Docker Images

- [ ] Check GHCR packages
  - https://github.com/holynakamoto/blitz-gateway/pkgs/container/blitz-gateway
  - Should see: `latest`, `v0.6.0`, `v0.6.0-dev`, `v0.6.0-minimal`

- [ ] Make images public
  - Package settings → Change visibility → Public

- [ ] Test Docker pull
  ```bash
  docker pull ghcr.io/holynakamoto/blitz-gateway:latest
  docker run --rm ghcr.io/holynakamoto/blitz-gateway:latest --help
  ```

## Documentation Updates

- [ ] README.md installation instructions verified
- [ ] Release notes completed
- [ ] Announcement prepared (if needed)

## Monitoring

- [ ] Check GitHub Actions workflows completed
  - https://github.com/holynakamoto/blitz-gateway/actions
  - Both "Release" and "Build and Release .deb Package" should succeed

## Troubleshooting

### Workflows Failed

Check Actions tab for errors:
- Build failures → Check Zig/build dependencies
- Docker push failures → Check GHCR permissions
- PackageCloud failures → Check token is valid

### Images Not Public

Manually set visibility:
1. Go to package page
2. Package settings → Change visibility
3. Select "Public"

### Package Not Found

- Check tag format: must be `v*.*.*` (e.g., `v0.6.0`)
- Check workflow triggered: View Actions tab
- Check package name: `blitz-gateway`

