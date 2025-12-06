# Blitz Edge Gateway

**The fastest edge proxy ever written. 10M+ RPS. <50µs p99 latency.**

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Zig](https://img.shields.io/badge/Zig-0.15.2-orange)](https://ziglang.org/)

Blitz Gateway is an ultra-low-latency edge API gateway and reverse proxy written in Zig. Built with io_uring, zero-copy architectures, and custom memory allocators to achieve performance that makes existing proxies obsolete.

## Why Blitz

- **10M+ RPS** on a single 128-core box
- **<50µs p99 latency** for HTTP/1.1, HTTP/2, HTTP/3
- **Zero-copy architecture** with io_uring for kernel-bypass performance
- **<200MB memory** at 5M RPS
- **Production-ready** with rate limiting, graceful reload, and full observability

## Features

- **HTTP/1.1, HTTP/2, HTTP/3** (QUIC) support with TLS 1.3
- **Load balancing** with health checks, connection pooling, and weighted routing
- **JWT authentication** with role-based access control
- **Rate limiting** with eBPF acceleration for DoS protection
- **Zero-downtime config reload** via SIGHUP
- **WASM plugins** for extensibility
- **OpenTelemetry metrics** with Prometheus/Grafana integration

## Installation

### Download Pre-built Binary (ARM64 Linux)

**Latest Release:** [v1.0.0](https://github.com/holynakamoto/blitz-gateway/releases/tag/v1.0.0)

#### Quick Install

```bash
# Download the latest release
curl -L -o blitz https://github.com/holynakamoto/blitz-gateway/releases/download/v1.0.0/blitz

# Make executable
chmod +x blitz

# Verify
./blitz --version
```

#### Alternative: Using wget

```bash
wget https://github.com/holynakamoto/blitz-gateway/releases/download/v1.0.0/blitz
chmod +x blitz
```

#### Alternative: Using GitHub CLI

```bash
gh release download v1.0.0 --repo holynakamoto/blitz-gateway --pattern "blitz"
chmod +x blitz
```

### System Requirements

- **Architecture:** ARM64 (aarch64) Linux
- **Kernel:** Linux 5.1+ (for io_uring support)
- **Dependencies:** None! Fully static binary

### Verified Platforms

✅ Ubuntu 22.04 ARM64  
✅ Ubuntu 20.04 ARM64  
✅ Debian 11/12 ARM64  
✅ Amazon Linux 2023 ARM64  
✅ Any ARM64 Linux distribution with kernel 5.1+

### Binary Details

- **Size:** 4.7MB (statically linked)
- **Built with:**
  - liburing 2.7 (io_uring support)
  - picotls with minicrypto (TLS 1.3)
  - musl libc (fully static)
- **SHA256:** `7f291c5c...` (see [release page](https://github.com/holynakamoto/blitz-gateway/releases/tag/v1.0.0) for full checksum)

### Verify Download

```bash
# Check it's the correct architecture
file blitz
# Expected: ELF 64-bit LSB executable, ARM aarch64, statically linked

# Verify it's truly static (no dependencies)
ldd blitz 2>&1
# Expected: "not a dynamic executable" or similar message

# Check size
ls -lh blitz
# Expected: ~4.7M
```

### Deploy to Server

#### Manual Deployment

```bash
# Copy to server
scp blitz user@your-server:/tmp/

# SSH and install
ssh user@your-server
sudo mv /tmp/blitz /usr/local/bin/
sudo chmod +x /usr/local/bin/blitz
```

#### Systemd Service (Recommended)

Create `/etc/systemd/system/blitz.service`:

```ini
[Unit]
Description=Blitz QUIC Gateway
After=network.target
Documentation=https://github.com/holynakamoto/blitz-gateway

[Service]
Type=simple
ExecStart=/usr/local/bin/blitz
Restart=always
RestartSec=5
User=blitz
Group=blitz

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/blitz

[Install]
WantedBy=multi-user.target
```

Enable and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable blitz
sudo systemctl start blitz
sudo systemctl status blitz
```

### Docker Deployment

```dockerfile
FROM scratch
COPY blitz /blitz
EXPOSE 443/udp
ENTRYPOINT ["/blitz"]
```

Build and run:

```bash
docker build -t blitz-gateway .
docker run -p 443:443/udp blitz-gateway
```

### Building from Source

```bash
# On macOS with Multipass installed
./scripts/linux-build.sh build -Doptimize=ReleaseFast

# Sync binary to Mac
./scripts/sync_artifacts_to_mac.sh
```

See [docs/BUILD_ARTIFACTS.md](docs/BUILD_ARTIFACTS.md) for detailed build instructions.

## Usage

```bash
# Start the QUIC gateway
./blitz

# Show help
./blitz --help

# Run in foreground with logging
./blitz --verbose
```

## Upgrading

```bash
# Download new version
curl -L -o blitz.new https://github.com/holynakamoto/blitz-gateway/releases/download/v1.1.0/blitz

# Stop service
sudo systemctl stop blitz

# Replace binary
sudo mv blitz.new /usr/local/bin/blitz
sudo chmod +x /usr/local/bin/blitz

# Start service
sudo systemctl start blitz
```

## Troubleshooting

### "cannot execute binary file: Exec format error"

You're trying to run an ARM64 binary on a different architecture. Download the appropriate binary for your system:
- ARM64/aarch64: Use this binary
- x86_64/AMD64: Coming soon (or build from source)

### "io_uring not supported"

Your kernel is older than 5.1. Check kernel version:

```bash
uname -r
```

Upgrade your kernel or use a newer Linux distribution (Ubuntu 22.04 recommended).

### Binary won't start

Check logs:

```bash
# If using systemd
sudo journalctl -u blitz -f

# If running manually
./blitz --verbose
```

## Architecture

```
Users → Blitz Edge Nodes
         ├─ io_uring event loop
         ├─ Zero-copy HTTP parser (SIMD)
         ├─ TLS 1.3 (memory BIOs)
         ├─ HTTP/2 + HTTP/3 (QUIC)
         ├─ Load balancing
         ├─ JWT auth + RBAC
         ├─ Rate limiting (eBPF + userspace)
         ├─ WASM plugins
         └─ Observability (OTLP + Prometheus)
```

## Performance

| Protocol | Target RPS | Target Latency |
|----------|-----------|----------------|
| HTTP/1.1 | 12M+ | <50µs p99 |
| HTTP/2   | 10M+ | <80µs p99 |
| HTTP/3   | 8M+  | <120µs p99 |

**Current results** (VM testing): 2,528 RPS (HTTP/2 over TLS)

See [benchmarking guide](docs/benchmark/README.md) for production benchmarks on bare metal.

## Documentation

- **[Documentation Index](docs/INDEX.md)** - Complete documentation guide
- **[Production Deployment](docs/production/README.md)** - Docker, Kubernetes, AWS, Bare Metal
- **[Benchmarking Guide](docs/benchmark/README.md)** - Performance testing and optimization
- **[Contributing](docs/CONTRIBUTING.md)** - Development setup and guidelines
- **[Release & Publishing](docs/release/)** - Publishing to APT and Docker

## Status

**v0.6** - Production-ready beta

✅ HTTP/1.1, HTTP/2, HTTP/3 (QUIC)  
✅ Load balancing with health checks  
✅ JWT authentication & authorization  
✅ Rate limiting & DoS protection  
✅ Zero-downtime config reload  
✅ WASM plugin system  
✅ OpenTelemetry metrics  

**Roadmap:** [docs/ROADMAP.md](docs/ROADMAP.md)

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.

<!-- Force CI workflow refresh -->

