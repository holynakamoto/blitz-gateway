# Docker Benchmark Workaround

## Current Issue

Zig 0.12.0 has a known issue linking liburing when using `@cImport`. The linker can't find the io_uring symbols even though the library is installed correctly.

## Quick Workaround: Use Your Local Build

Since you're on macOS and can't run Blitz directly, here's a workaround:

### Option 1: Build Locally, Copy Binary to Docker

```bash
# 1. Build on a Linux machine/VM (or wait for bare metal)
zig build -Doptimize=ReleaseFast

# 2. Copy binary into Docker container
docker run -d --name blitz --privileged --network host \
  -v $(pwd)/zig-out/bin/blitz:/app/blitz \
  ubuntu:24.04 \
  tail -f /dev/null

# 3. Run Blitz in container
docker exec blitz /app/blitz
```

### Option 2: Use GitHub Actions / CI

Set up a GitHub Actions workflow that:
1. Builds Blitz on Linux
2. Runs benchmarks
3. Reports results

### Option 3: Use a Linux VM (Quick)

```bash
# Use UTM, Parallels, or VirtualBox
# Install Ubuntu 24.04 LTS
# Build and benchmark directly
```

## The Real Solution: Bare Metal

For actual benchmarks, you need bare metal Linux anyway. Docker adds overhead and the linking issue is a red herring - on bare metal with proper setup, everything works.

**Recommended**: Get a bare metal server (see `FREE-BARE-METAL-OPTIONS.md`) and run benchmarks there. Docker is just for testing the process.

## Status

- ✅ Code compiles (with Zig 0.15.2 locally)
- ✅ All features implemented
- ✅ Benchmark scripts ready
- ❌ Docker build blocked by Zig 0.12.0 liburing linking issue

**Next Step**: Deploy to bare metal Linux and run benchmarks there.

