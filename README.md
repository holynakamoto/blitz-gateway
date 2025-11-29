# Blitz Edge Gateway

**Ultra-Low-Latency Edge API Gateway & Reverse Proxy written in Zig**

> Building the fastest edge proxy ever written. Target: 10M+ RPS, <50µs p99 latency.

[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.12.0-orange.svg)](https://ziglang.org/)

## 🎯 Vision

Build the first edge proxy that achieves **sub-50 µs p99 latency** at **millions of RPS** on commodity hardware, making every existing C/C++/Rust proxy obsolete.

## 🚀 Success Metrics

| Metric                              | Target (bare metal, single box)         |
|-------------------------------------|------------------------------------------|
| HTTP/1.1 keep-alive RPS             | ≥ 10,000,000 RPS                        |
| TLS 1.3 + HTTP/2 p99 latency        | ≤ 80 µs                                 |
| HTTP/3 (QUIC) p99 latency           | ≤ 120 µs                                |
| Memory usage at 5M RPS              | ≤ 200 MB                                |
| CPU usage at 5M RPS (128-core)      | ≤ 35%                                   |
| Cold start time (binary → ready)    | ≤ 15 ms                                 |
| Config hot-reload time              | ≤ 5 ms                                  |

## 🏗️ Architecture

```
Users → Global Anycast → Blitz Edge Nodes (bare metal or VMs)
                          ├─ io_uring / kqueue / IOCP event loop
                          ├─ Zero-copy HTTP parser (SIMD state machine)
                          ├─ TLS 1.3 (zero-copy, kernel TLS ready)
                          ├─ QUIC/HTTP3 (pure Zig implementation)
                          ├─ Routing → Radix tree + eBPF map
                          ├─ Backend pool → Connection reuse, health checks
                          ├─ WASM runtime → wasmtime-zig fork, < 2 ms load
                          └─ Metrics → OTLP + Prometheus
```

## 📦 Current Status: MVP v0.1 (Private Alpha)

- ✅ HTTP/1.1 echo server with io_uring
- ✅ Basic connection handling
- 🚧 TLS 1.3 support (in progress)
- 🚧 HTTP/2 support (planned)
- 🚧 HTTP/3/QUIC support (planned)
- 🚧 Routing and load balancing (planned)
- 🚧 WASM plugin system (planned)

## 🛠️ Building

### Prerequisites

- Zig 0.12.0 or later
- **Linux 5.15+** (for io_uring support) - **Required**
- **Ubuntu 24.04 LTS Minimal** (recommended for benchmarks)
- liburing development headers

**Note**: Blitz requires Linux. For macOS/Windows testing, use Docker or a Linux VM (see `benches/DOCKER-TESTING.md`).

### Quick Setup (Ubuntu 24.04)

**One-command system optimization:**

```bash
curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/bench-box-setup.sh | sudo bash
```

This optimizes your system for maximum io_uring performance. See `scripts/README.md` for details.

### Install liburing

**Ubuntu/Debian:**
```bash
sudo apt-get install liburing-dev
```

**Fedora/RHEL:**
```bash
sudo dnf install liburing-devel
```

**macOS (for development, limited support):**
```bash
brew install liburing
```

### Build

```bash
zig build
```

### Run

```bash
zig build run
```

The server will start on port 8080 by default.

### Benchmark

```bash
# Install wrk2 if needed
# On macOS: brew install wrk2
# On Linux: https://github.com/giltene/wrk2

wrk2 -t4 -c100 -d30s -R1000000 http://localhost:8080/
```

## 🧪 Testing

```bash
zig build test
```

## 📊 Benchmarking

### Quick Start: Linux VM (Recommended for Testing)

**Don't have bare metal?** Set up a free Linux VM on your Mac:

```bash
# 1. Install UTM (free VM software)
brew install --cask utm

# 2. Follow: benches/VM-QUICK-START.md
#    (5-minute setup guide)
```

See `benches/VM-SETUP.md` for detailed VM setup instructions.

### Quick Local Benchmark (Linux Only)

For development testing on your local Linux machine:

```bash
# Start Blitz
zig build run

# In another terminal, run local benchmark
./benches/local-benchmark.sh
```

### Production Benchmarks

For production-grade benchmarks on bare metal:

1. **Set up hardware** (see `benches/benchmark-machine-spec.md`)
2. **Run full benchmark suite**:
   ```bash
   ./benches/reproduce.sh
   ```

### Benchmark Results

See `benches/COMPARISON.md` for comparison against Nginx, Envoy, Traefik, and others.

**Expected Results** (AMD EPYC 9754, 128-core):
- **12M+ RPS** (HTTP/1.1 keep-alive)
- **< 70 µs p99 latency**
- **< 150 MB memory** at 5M RPS

### Benchmark Endpoints

- `/hello` - Optimized endpoint for benchmarking (fastest path)
- `/` or `/health` - Standard health check
- `/echo/*` - Echo endpoint (returns request path)

For maximum RPS, use `/hello` endpoint:
```bash
wrk2 -t 128 -c 200000 -d 60s -R 12000000 --latency http://localhost:8080/hello
```

## 📊 Roadmap

| Quarter       | Milestone                                      | Key Deliverables                                                                 |
|---------------|------------------------------------------------|----------------------------------------------------------------------------------|
| Q4 2025       | MVP v0.1 (private alpha)                       | HTTP/1.1 + TLS 1.3, io_uring, 5M RPS, basic routing, health checks               |
| Q1 2026       | v0.5 (public beta)                             | HTTP/2, rate limiting, JWT auth, OpenTelemetry, hot reload, Docker image         |
| Q2 2026       | v1.0 GA (open source)                          | HTTP/3 (pure Zig QUIC), WASM plugins, enterprise WAF module  |
| Q3 2026       | v2.0 (enterprise + cloud launch)               | Managed global platform launch, marketplace, SLA 99.999%, SOC2                 |
| Q4 2026       | Exit event                                     | Acquisition term sheet (target $100M+)                                           |

## 🤝 Contributing

We're building the fastest infrastructure software ever written. If you want to help us hit 10M RPS and <50µs latency, check out [CONTRIBUTING.md](CONTRIBUTING.md).

## 📄 License

Apache 2.0 - See [LICENSE](LICENSE) for details.

## 🔗 Links

- **Website**: [blitzgateway.com](https://blitzgateway.com) (coming soon)
- **Twitter**: [@blitzgateway](https://twitter.com/blitzgateway) (coming soon)
- **Discord**: (coming soon)

## 💬 Community

Join us in building the future of edge computing. Every microsecond matters.

**LFG. 🚀**

