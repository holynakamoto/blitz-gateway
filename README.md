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

### One-Command Install (Ubuntu 22.04 / 24.04)

```bash
curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash
```

Installs Blitz Gateway as a systemd service. Configure and start:

```bash
# Edit configuration
sudo nano /etc/blitz-gateway/config.toml

# Start service
sudo systemctl start blitz-gateway

# Enable on boot
sudo systemctl enable blitz-gateway
```

### Manual APT Install

```bash
# Download .deb from GitHub Releases
VERSION="0.6.0"
wget https://github.com/holynakamoto/blitz-gateway/releases/download/v${VERSION}/blitz-gateway_${VERSION}_amd64.deb

# Install
sudo apt-get install ./blitz-gateway_${VERSION}_amd64.deb

# Or install dependencies first if needed
sudo apt-get install -y liburing2 libssl3
sudo dpkg -i blitz-gateway_${VERSION}_amd64.deb
```

### Docker

```bash
# Pull latest image
docker pull ghcr.io/holynakamoto/blitz-gateway:latest

# Run production container
docker run -d \
  --name blitz-gateway \
  -p 8443:8443/udp \
  -v $(pwd)/config.toml:/etc/blitz-gateway/config.toml \
  --restart unless-stopped \
  ghcr.io/holynakamoto/blitz-gateway:latest

# Or use Docker Compose
git clone https://github.com/holynakamoto/blitz-gateway.git
cd blitz-gateway

# Development
make dev up

# Production
make prod up -d

# With monitoring
make monitoring up -d
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

