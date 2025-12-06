# Blitz Gateway Benchmark Suite

Production-grade performance benchmarking for Blitz Gateway on bare metal.

## Quick Start

For production benchmarks, see **[Bare Metal Quick Start](QUICK-START-BARE-METAL.md)**.

For hardware requirements, see **[Hardware Specifications](benchmark-machine-spec.md)**.

## Overview

The Blitz Gateway benchmark suite is designed for **bare metal production benchmarking** to achieve maximum performance:

- **Target**: 10M+ RPS on 128-core hardware
- **Latency**: <50µs p99 for HTTP/1.1, <80µs for HTTP/2, <120µs for HTTP/3
- **Memory**: <200MB RSS at 5M RPS
- **CPU**: <35% utilization at 5M RPS

### Why Bare Metal?

Blitz Gateway uses `io_uring` for kernel-bypass performance, which requires:
- Linux kernel 5.15+ (6.11+ recommended)
- Direct hardware access
- System-level tuning
- No virtualization overhead

**Docker/VM benchmarks are not representative** of production performance. Use bare metal for accurate results.

## Prerequisites

### Hardware

- **Recommended**: AMD EPYC 9754 (128-core) or similar high-core-count CPU
- **Minimum**: 8+ cores, 16GB+ RAM
- **Network**: 10Gbps+ NIC (100Gbps for maximum performance)
- **OS**: Ubuntu 24.04 LTS with kernel 6.11+

See **[Hardware Specifications](benchmark-machine-spec.md)** for detailed requirements.

### System Setup

**One-command setup** (Ubuntu 24.04 LTS):

```bash
curl -sL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/scripts/bench/bench-box-setup.sh | sudo bash
```

This will:
- Upgrade kernel to 6.11+
- Apply network and system tuning
- Disable THP (reduces jitter)
- Set CPU governor to performance
- Install benchmarking tools (wrk2, hey)
- Configure CPU isolation (optional)

### Benchmark Tools

Install required tools:

```bash
# Install wrk2 (rate-limited RPS testing)
git clone https://github.com/giltene/wrk2
cd wrk2 && make
sudo cp wrk /usr/local/bin/wrk2

# Install hey
wget https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x hey_linux_amd64
sudo mv hey_linux_amd64 /usr/local/bin/hey

# Install system monitoring
sudo apt-get install htop sysstat
```

## Running Benchmarks

### 1. Build Blitz Gateway

```bash
git clone https://github.com/holynakamoto/blitz-gateway.git
cd blitz-gateway
zig build -Doptimize=ReleaseFast
```

### 2. Start Server

```bash
./zig-out/bin/blitz-quic
```

### 3. Run Benchmark

In another terminal (or from a separate client machine):

```bash
# Quick test
curl http://localhost:8080/hello

# Full production benchmark
./scripts/bench/reproduce.sh
```

### 4. Production Benchmark (Maximum RPS)

For maximum RPS testing on EPYC 9754 (128-core):

```bash
# HTTP/1.1 keep-alive (target: 12M+ RPS)
wrk2 -t 128 -c 200000 -d 60s -R 12000000 --latency http://$SERVER_IP/hello

# HTTP/2 over TLS (target: 10M+ RPS)
h2load -n 10000000 -c 1000 -m 100 https://$SERVER_IP/hello

# HTTP/3/QUIC (target: 8M+ RPS)
# Use quic-interop-runner or custom QUIC client
```

## Expected Results

### On EPYC 9754 (128-core)

| Protocol | RPS | p99 Latency | Memory |
|----------|-----|-------------|--------|
| HTTP/1.1 | 12-15M | 60-80 µs | <150MB |
| HTTP/2 | 10-12M | 80-100 µs | <180MB |
| HTTP/3 | 8-10M | 100-120 µs | <200MB |

### On Development Hardware (8-16 cores)

| Protocol | RPS | p99 Latency | Memory |
|----------|-----|-------------|--------|
| HTTP/1.1 | 1-5M | 150-300 µs | <200MB |
| HTTP/2 | 1-4M | 200-400 µs | <250MB |
| HTTP/3 | 1-3M | 250-500 µs | <300MB |

## Performance Metrics

### Primary Metrics

| Metric | Target | Unit |
|--------|--------|------|
| **Requests/sec** | 10,000,000+ | req/s |
| **P50 Latency** | <10 | µs |
| **P95 Latency** | <50 | µs |
| **P99 Latency** | <80 | µs |
| **Error Rate** | <0.1% | % |

### System Metrics

| Resource | Metric | Threshold | Unit |
|----------|--------|-----------|------|
| **CPU** | Utilization | <35% | % |
| **Memory** | RSS | <200MB | MB |
| **Network** | Bandwidth | <80% | % |

## Regression Testing

### Set Baseline

```bash
# Set current performance as baseline
./scripts/bench/reproduce.sh baseline

# Baseline stored in: benches/baseline.json
```

### Check for Regressions

```bash
# Check for regressions against baseline
./scripts/bench/reproduce.sh regression

# Output example:
PERFORMANCE REGRESSION DETECTED: 15.3% degradation in requests/sec
Current: 8234 req/sec
Baseline: 9523 req/sec
```

### Compare Commits

```bash
# Compare specific commits
./scripts/bench/reproduce.sh compare abc123 def456
```

## Benchmark Endpoints

Use these endpoints for benchmarking:

- **`/hello`** - Optimized for maximum RPS (fastest path, minimal parsing)
- **`/`** or **`/health`** - Standard health check
- **`/echo/*`** - Echo endpoint (returns request path)

**For maximum RPS, always use `/hello`:**

```bash
wrk2 -t 128 -c 200000 -d 60s -R 12000000 --latency http://$IP/hello
```

## Troubleshooting

### Low RPS (< 1M)

- Check CPU governor: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` (should be "performance")
- Check for CPU throttling: `dmesg | grep -i thermal`
- Verify io_uring: `ls /sys/fs/io_uring`
- Check network: `ethtool -S <interface> | grep -i error`
- Ensure system is idle: `top` or `htop`

### High Latency (> 200 µs)

- Ensure CPU isolation: `taskset -c 0-95 ./zig-out/bin/blitz-quic`
- Check for context switching: `vmstat 1`
- Verify no other processes using CPU: `top` or `htop`
- Check network latency: `ping <server_ip>`
- Disable THP: `echo never > /sys/kernel/mm/transparent_hugepage/enabled`

### Connection Errors

- Increase file descriptor limits: `ulimit -n 1000000`
- Check network tuning: `sysctl net.core.somaxconn` (should be 1048576)
- Verify firewall rules: `iptables -L`
- Check for port conflicts: `netstat -tlnp | grep :8080`

### System Tuning

```bash
# Kernel parameters
sudo sysctl -w net.core.somaxconn=1048576
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=1048576
sudo sysctl -w net.core.netdev_max_backlog=50000
sudo sysctl -w fs.file-max=2097152

# CPU governor
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Disable THP (reduces jitter)
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag
```

## CI/CD Integration

The benchmark suite can be integrated into CI/CD pipelines for regression detection:

```yaml
# .github/workflows/benchmark.yml
name: Benchmark
on:
  pull_request:
    branches: [main]

jobs:
  benchmark:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - name: Setup Zig
        uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.15.2
      - name: Build
        run: zig build -Doptimize=ReleaseFast
      - name: Run benchmark
        run: ./scripts/bench/local-benchmark.sh
      - name: Check regression
        run: ./scripts/bench/reproduce.sh regression
```

**Note**: CI benchmarks are limited by GitHub Actions runners. For production numbers, use bare metal.

## Documentation

- **[Bare Metal Quick Start](QUICK-START-BARE-METAL.md)** - Step-by-step setup guide
- **[Hardware Specifications](benchmark-machine-spec.md)** - Recommended hardware and system configuration

---

**Benchmarking Blitz Gateway** on bare metal ensures accurate production performance measurements. The suite provides automated regression detection, comprehensive metrics collection, and CI/CD integration for continuous performance validation.
