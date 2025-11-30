# Blitz Quick Start Guide

Get Blitz running in 60 seconds.

## Prerequisites

```bash
# Install Zig (0.12.0+)
# macOS: brew install zig
# Linux: https://ziglang.org/download/

# Install liburing
# Ubuntu/Debian:
sudo apt-get install liburing-dev

# Fedora/RHEL:
sudo dnf install liburing-devel
```

## Build & Run

```bash
# Build
zig build

# Run (starts on port 8080)
zig build run
```

## Test It

```bash
# In another terminal
curl http://localhost:8080/

# Expected output:
# Hello, Blitz!
```

## Benchmark

```bash
# Install wrk2
# macOS: brew install wrk2
# Linux: https://github.com/giltene/wrk2

# Run benchmark (adjust -R for your hardware)
wrk2 -t4 -c100 -d30s -R1000000 http://localhost:8080/
```

## Current Performance Targets

- **MVP Goal**: 3M+ RPS on single box
- **Final Goal**: 10M+ RPS, <50µs p99 latency

## Next Steps

1. ✅ io_uring echo server (done)
2. 🚧 HTTP/1.1 full parser
3. 🚧 TLS 1.3 support
4. 🚧 HTTP/2 support
5. 🚧 HTTP/3/QUIC support

## Troubleshooting

**"io_uring_queue_init failed"**
- Ensure you're on Linux 5.15+
- Check liburing is installed: `pkg-config --modversion liburing`

**"UnsupportedPlatform"**
- io_uring is Linux-only for now
- macOS/Windows support coming in v0.5

**Low RPS**
- Ensure you're running on bare metal or VM with proper CPU pinning
- Check CPU governor: `cpupower frequency-set -g performance`
- Increase file descriptor limits: `ulimit -n 100000`

## Architecture Notes

- **Event Loop**: io_uring (Linux), kqueue (macOS), IOCP (Windows) - planned
- **Memory**: Arena allocator (MVP), slab allocator (production)
- **Zero-copy**: Coming in v0.5
- **SIMD**: HTTP parser optimization planned

---

**Ready to hit 10M RPS? Let's go.** 🚀

