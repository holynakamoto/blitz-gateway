# Badge Troubleshooting Guide

## Understanding Badge Statuses

### ✅ Working Badges (These should display correctly)

- **Stars/Forks**: Shows "0" initially - normal for new repos
- **Issues**: Shows "0 open" / "0 closed" - normal if no issues exist
- **Built with Zig**: Static badge - always works
- **Built with love**: Static badge - always works

### ⚠️ Badges That May Show Errors Initially

#### 1. Workflow Badges (CI, Docker, Code Quality) Showing "Failing"

**Why this happens:**
- Workflows haven't been triggered yet (need a push to main)
- Workflow file has errors
- GitHub Actions are disabled

**How to fix:**
1. **Trigger workflows**: Make a small commit and push
2. **Check Actions tab**: Go to https://github.com/holynakamoto/blitz-gateway/actions
3. **Enable Actions**: Settings → Actions → Allow all actions
4. **Check workflow files**: Ensure `.github/workflows/*.yml` files are valid

**Example to trigger:**
```bash
git commit --allow-empty -m "Trigger CI workflows" && git push
```

#### 2. License Badge Showing "Not Identifiable"

**Why this happens:**
- GitHub hasn't scanned the LICENSE file yet
- LICENSE file format isn't recognized

**Status:** ✅ **FIXED** - Now using explicit Apache 2.0 static badge

#### 3. Release Badge Showing "No Releases Found"

**Why this happens:**
- Only a git tag exists (v0.6.0), but no GitHub release

**How to fix:**
```bash
# Option 1: Use the script
./scripts/misc/create-release.sh v0.6.0

# Option 2: Manual via GitHub CLI
gh release create v0.6.0 \
  --title "🚀 Blitz Gateway v0.6.0 - Production Ready" \
  --notes "Release notes here"

# Option 3: Via GitHub Web UI
# Go to: https://github.com/holynakamoto/blitz-gateway/releases/new
```

#### 4. Badge Showing "404 Badge Not Found"

**Why this happens:**
- Broken badge URL
- Repository path incorrect
- Badge service is down

**Status:** ✅ **FIXED** - All badge URLs now correct

## Quick Status Check

Run this to verify badge URLs:

```bash
# Check if badges are accessible
curl -I "https://img.shields.io/github/stars/holynakamoto/blitz-gateway"
curl -I "https://github.com/holynakamoto/blitz-gateway/actions/workflows/ci.yml/badge.svg"
```

## Badge Status After Setup

### Immediate (after push)
- ✅ Stars/Forks will show actual counts
- ✅ Issues will show actual counts
- ✅ Static badges (Zig, License, etc.) work immediately

### After Workflows Run (5-15 minutes)
- ✅ CI badge will show "passing" or "failing" based on actual test results
- ✅ Docker badge will show build status
- ✅ Code Quality badge will show linting results

### After Creating Release
- ✅ Release badge will show version number
- ✅ Downloads badge will be available

## Common Issues

### Badges Not Updating
- **Wait 5-10 minutes**: GitHub caches badge data
- **Clear browser cache**: Hard refresh (Cmd+Shift+R / Ctrl+Shift+R)
- **Check badge URL**: Verify repository path is correct

### Workflow Badges Always Failing
1. Check Actions tab for error messages
2. Verify workflow files are valid YAML
3. Ensure required secrets/permissions are set
4. Check if workflows are enabled in repository settings

### Release Badge Not Showing
- Must create GitHub release (not just git tag)
- Wait 5-10 minutes for GitHub to update
- Verify release is public (not draft)

## Need Help?

- **Badge Setup Guide**: See `docs/BADGE-SETUP.md`
- **GitHub Actions Docs**: https://docs.github.com/en/actions
- **Shields.io Docs**: https://shields.io/

