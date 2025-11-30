# Docker Build Troubleshooting

## Issue: Library Linking Failures

The Docker build is failing because Zig can't find the system libraries (`liburing`, `libssl`, `libcrypto`) even though they're installed.

## Root Cause

Ubuntu 22.04 stores libraries in architecture-specific directories:
- `/usr/lib/x86_64-linux-gnu/` (for x86_64)
- `/usr/lib/aarch64-linux-gnu/` (for ARM64)

Zig's default library search doesn't include these paths.

## Solutions

### Option 1: Use Vagrant Instead (Recommended)

Since you have UTM and the vagrant_utm plugin, use Vagrant:

```bash
vagrant up --provider=utm
vagrant ssh
cd /home/vagrant/blitz-gateway
zig build
```

This avoids Docker library path issues entirely.

### Option 2: Fix Docker Build

The build.zig has been updated to add the library path, but there may still be issues. To fix:

1. **Verify libraries exist:**
```bash
docker run --rm -it blitz-quic:latest bash
find /usr/lib* -name "libcrypto.so*"
```

2. **Use pkg-config:**
Update build.zig to use pkg-config for library discovery.

3. **Manual symlinks:**
Create proper symlinks in the Dockerfile.

### Option 3: Skip Docker for Now

Focus on:
1. **Vagrant testing** (works with UTM)
2. **Transport parameters integration** (can be done on macOS)
3. **Header protection** (can be done on macOS)

Then test end-to-end in Vagrant when ready.

## Current Status

- ✅ Vagrantfile ready (UTM provider)
- ⚠️ Docker build needs library path fixes
- ✅ All unit tests passing on macOS
- ✅ Code compiles on macOS

## Recommendation

**Use Vagrant for Linux testing** - it's simpler and avoids Docker library path issues.

```bash
vagrant up --provider=utm
```

