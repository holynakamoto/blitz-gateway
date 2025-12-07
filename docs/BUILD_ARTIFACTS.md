# Build Artifact Management Strategy Guide

## 🎯 TL;DR Recommendations

**For your situation (solo dev, custom build, 4.7MB binaries):**

1. ✅ **Keep local Multipass builds** - Fast, free, debuggable
2. ✅ **rsync artifacts to Mac** - Backup and version control
3. ✅ **Commit metadata only** - Not the binaries themselves
4. ✅ **Use GitHub Releases** - For distributing binaries
5. ⚠️ **Skip CI/CD for now** - Add later if team grows

---

## 📊 Strategy Comparison

### Option 1: Local Build + GitHub Releases (RECOMMENDED)

**Workflow:**
```bash
# On Mac:
./scripts/vm/linux-build.sh build -Doptimize=ReleaseFast

# Sync artifacts
./scripts/sync_artifacts_to_mac.sh

# Commit metadata
git add artifacts/checksums/ artifacts/metadata/
git commit -m "build: ARM64 v1.2.3 metadata"
git push

# Release binaries (when ready)
gh release create v1.2.3 \
  ./artifacts/aarch64-linux/blitz \
  ./artifacts/aarch64-linux/quic_handshake_server \
  --title "Release v1.2.3" \
  --notes "ARM64 static binaries - liburing 2.7, picotls"
```

**Pros:**
- ✅ Free (no CI/CD costs)
- ✅ Fast (local VM, cached deps)
- ✅ Binaries distributed via releases (not in git)
- ✅ Metadata versioned in git
- ✅ Easy to debug

**Cons:**
- ⚠️ Manual process (but quick)
- ⚠️ Only you can build

**Cost:** $0/month

---

### Option 2: Git LFS for Binaries

**Setup:**
```bash
# Install Git LFS
brew install git-lfs
git lfs install

# Track binaries
git lfs track "artifacts/aarch64-linux/*"
git add .gitattributes

# Commit (LFS handles large files)
git add artifacts/
git commit -m "build: ARM64 binaries via LFS"
git push
```

**Pros:**
- ✅ Binaries versioned with code
- ✅ Git handles them properly
- ✅ Can checkout specific binary versions

**Cons:**
- ⚠️ GitHub LFS free tier: 1GB storage, 1GB bandwidth/month
- ⚠️ Your binaries: 4.7MB × 2 = ~9.4MB per version
- ⚠️ After ~100 versions (940MB), you hit the limit
- 💰 Additional: $5/month per 50GB data pack

**Cost:** Free for <100 versions, then $5/month

---

### Option 3: Full CI/CD (GitHub Actions)

**When to use:** Multiple developers OR frequent releases

**Setup:** `.github/workflows/build-aarch64.yml`

```yaml
name: Build ARM64 Static Binaries

on:
  push:
    branches: [main]
    tags: ['v*']
  pull_request:

jobs:
  build-aarch64:
    runs-on: ubuntu-22.04
    
    steps:
      - uses: actions/checkout@v4
      
      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential cmake git
          
      - name: Install Zig
        run: |
          wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
          tar xf zig-linux-x86_64-0.15.2.tar.xz
          echo "$PWD/zig-linux-x86_64-0.15.2" >> $GITHUB_PATH
      
      - name: Build liburing
        run: |
          cd /tmp
          git clone --depth 1 --branch liburing-2.7 https://github.com/axboe/liburing.git
          cd liburing
          ./configure --prefix=/usr/local
          make -j$(nproc)
          sudo make install
      
      - name: Build picotls
        run: |
          cd deps/picotls
          mkdir build && cd build
          cmake .. -DCMAKE_BUILD_TYPE=Release \
            -DBUILD_SHARED_LIBS=OFF \
            -DPTLS_MINICRYPTO=ON \
            -DPTLS_OPENSSL=OFF
          make -j$(nproc)
          sudo cp libpicotls-core.a /usr/local/lib/libpicotls.a
          sudo cp libpicotls-minicrypto.a /usr/local/lib/
          sudo mkdir -p /usr/local/include/picotls
          sudo cp -r ../include/* /usr/local/include/
      
      - name: Build with Zig
        run: |
          zig build -Doptimize=ReleaseFast -Dtarget=aarch64-linux-musl
      
      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: aarch64-binaries
          path: |
            zig-out/bin/blitz
            zig-out/bin/quic_handshake_server
      
      - name: Create Release (on tag)
        if: startsWith(github.ref, 'refs/tags/')
        uses: softprops/action-gh-release@v1
        with:
          files: |
            zig-out/bin/blitz
            zig-out/bin/quic_handshake_server
```

**Pros:**
- ✅ Automated on every push
- ✅ Reproducible builds
- ✅ Multi-developer friendly
- ✅ Build matrix (test multiple configs)

**Cons:**
- ⚠️ ~10 minutes per build
- ⚠️ 2,000 free minutes/month = ~200 builds
- ⚠️ Complex setup to maintain
- ⚠️ Harder to debug build issues

**Cost:** 
- Free tier: ~200 builds/month
- If exceeded: $0.08 per build
- If building 5×/day: ~$12/month overage

---

### Option 4: Commit Binaries Directly (NOT RECOMMENDED)

**Why not:**
- ❌ 4.7MB × 2 binaries = 9.4MB per commit
- ❌ Git history grows forever
- ❌ Slows down clone/checkout
- ❌ GitHub warns about large files (>50MB total ok, but messy)

**Only if:**
- Binaries are <100KB each
- Very infrequent releases
- Need exact binary in git history

---

## 🏆 Recommendation for Solo Development

### Phase 1: Now (Solo Development)

**Use Option 1: Local Build + GitHub Releases**

```bash
# Your workflow:
1. Code changes on Mac
2. Run: ./scripts/vm/linux-build.sh build -Doptimize=ReleaseFast
3. Run: ./scripts/sync_artifacts_to_mac.sh
4. Commit code + metadata: git commit -am "feat: new feature"
5. When releasing: gh release create v1.2.3 artifacts/aarch64-linux/*
```

**Why:** Free, fast, simple, works great for 1 developer.

### Phase 2: Later (When Needed)

Add CI/CD **only when:**
- You have 2+ developers
- Building >5 times/day
- Need automated testing on ARM64
- Want to test PRs automatically

---

## 📁 Recommended Git Structure

```
blitz-gateway/
├── .github/
│   └── workflows/
│       └── build-aarch64.yml      # Add later
├── artifacts/
│   ├── .gitignore                 # Ignore binaries, keep metadata
│   ├── checksums/
│   │   └── sha256sums.txt        # ✅ Commit this
│   ├── metadata/
│   │   └── build_info.txt        # ✅ Commit this
│   └── aarch64-linux/
│       ├── blitz                  # ❌ Don't commit (use releases)
│       └── quic_handshake_server  # ❌ Don't commit (use releases)
├── scripts/
│   ├── linux-build.sh             # ✅ Build script
│   └── sync_artifacts_to_mac.sh   # ✅ Sync script
└── src/
    └── ...
```

---

## 🔄 Complete Workflow Example

### Development Cycle

```bash
# 1. Make code changes
vim src/main.zig

# 2. Build locally
./scripts/vm/linux-build.sh build -Doptimize=ReleaseFast

# 3. Sync artifacts to Mac
./scripts/sync_artifacts_to_mac.sh

# 4. Commit code + metadata
git add src/ artifacts/checksums/ artifacts/metadata/
git commit -m "feat: implement new QUIC feature"
git push
```

### Release Cycle

```bash
# 1. Tag release
git tag v1.2.3
git push --tags

# 2. Build release artifacts
./scripts/vm/linux-build.sh build -Doptimize=ReleaseFast
./scripts/sync_artifacts_to_mac.sh

# 3. Create GitHub release with binaries
gh release create v1.2.3 \
  artifacts/aarch64-linux/blitz \
  artifacts/aarch64-linux/quic_handshake_server \
  --title "Release v1.2.3" \
  --notes "
## Changes
- New QUIC feature
- Performance improvements

## Static Binaries (ARM64 Linux)
- blitz: QUIC gateway server
- quic_handshake_server: Test server

Built with:
- liburing 2.7 (io_uring support)
- picotls with minicrypto (TLS 1.3)
- musl libc (fully static)
"

# 4. Done! Users can download from:
#    https://github.com/you/repo/releases/v1.2.3
```

---

## 💡 Pro Tips

### Keep VM Alive for Fast Builds

```bash
# Your VM persists between builds (dependencies cached)
# Build takes: ~30s (vs 10min in CI)

# First build: 10 minutes (builds deps)
# Subsequent: 30 seconds (deps cached)
```

### Testing Without Rebuilding

```bash
# Copy artifacts to test machine
scp artifacts/aarch64-linux/blitz user@arm-server:/tmp/
ssh user@arm-server /tmp/blitz --version
```

---

## 📊 Cost Comparison Summary

| Strategy | Setup Time | Monthly Cost | Best For |
|----------|------------|--------------|----------|
| **Local + Releases** | 5 min | $0 | Solo dev, custom build |
| **Git LFS** | 10 min | $0-5 | Small team, versioned bins |
| **GitHub Actions** | 1 hour | $0-15 | Team, automated testing |
| **Commit Direct** | 0 min | $0 | ❌ Not recommended |

---

## 🎯 Final Summary

**Yes, rsync artifacts back to Mac**, but:
- ✅ Commit only metadata (checksums, build info)
- ✅ Use GitHub Releases for binaries
- ❌ Don't commit 4.7MB binaries to git
- ⏳ Add CI/CD later if needed

Your current setup is **optimal for your situation**. Don't over-engineer it!

