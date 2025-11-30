# Blitz Gateway Benchmark Suite

Comprehensive performance benchmarking and regression testing for Blitz Gateway.

## Table of Contents

- [Overview](#overview)
- [Quick Start](#quick-start)
- [Benchmark Scenarios](#benchmark-scenarios)
- [Performance Metrics](#performance-metrics)
- [Regression Testing](#regression-testing)
- [Configuration](#configuration)
- [Running Benchmarks](#running-benchmarks)
- [Analyzing Results](#analyzing-results)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)

## Overview

The Blitz Gateway benchmark suite provides comprehensive performance testing capabilities including:

- **Load Testing**: HTTP/QUIC request throughput and latency measurement
- **Regression Detection**: Automatic performance regression identification
- **Multi-Scenario Testing**: Various request patterns and workloads
- **System Monitoring**: CPU, memory, and network resource tracking
- **Statistical Analysis**: Confidence intervals and trend analysis
- **CI/CD Integration**: Automated benchmarking in CI pipelines

### Architecture

```
Benchmark Suite Architecture
├── Scripts (scripts/bench/)
│   ├── local-benchmark.sh    # Local benchmark runner
│   └── reproduce.sh          # Cross-commit comparison
├── Configuration (benches/config.toml)
│   ├── Scenarios             # Test case definitions
│   ├── Tools                 # Benchmark tool configs
│   └── Thresholds            # Performance limits
├── Results (benches/results/)
│   ├── Raw data              # Tool outputs
│   ├── Summaries             # Processed results
│   └── Comparisons           # Regression analysis
└── CI/CD (.github/workflows/)
    └── benchmark.yml         # Automated benchmarking
```

## Quick Start

### Prerequisites

```bash
# Install benchmark tools (choose one or more)
sudo apt-get install wrk hey bombardier
# OR
go install github.com/tsenart/vegeta@latest

# Install system monitoring tools
sudo apt-get install htop sysstat

# Ensure Zig is installed
zig version  # Should be 0.15.2+
```

### Run Basic Benchmark

```bash
# Clone and setup
git clone https://github.com/blitz-gateway/blitz-gateway
cd blitz-gateway

# Run basic benchmark (30 seconds, 100 connections)
./scripts/bench/local-benchmark.sh

# Results saved to: benches/results/YYYYMMDD_HHMMSS/
```

### Compare Performance

```bash
# Set baseline performance
./scripts/bench/reproduce.sh baseline

# Run regression check
./scripts/bench/reproduce.sh regression

# Compare specific commits
./scripts/bench/reproduce.sh compare abc123 def456
```

## Benchmark Scenarios

### HTTP Scenarios

| Scenario | Description | Load Pattern | Use Case |
|----------|-------------|--------------|----------|
| **Homepage** | Basic GET requests | 80% of traffic | Static content serving |
| **API Status** | JSON API calls | 15% of traffic | Health checks, monitoring |
| **API Data** | POST with JSON payload | 5% of traffic | Data ingestion, forms |

### Load Profiles

| Profile | Duration | Connections | Purpose |
|---------|----------|-------------|---------|
| **Basic** | 30s | 50 | Quick validation |
| **Standard** | 60s | 100 | Development testing |
| **Stress** | 120s | 500 | Peak load testing |
| **Endurance** | 30min | 200 | Long-term stability |

### Protocol Testing

```toml
# HTTP/1.1, HTTP/2, QUIC support
[server]
protocol = "http"  # http, https, quic
tls_enabled = true
quic_enabled = true
```

## Performance Metrics

### Primary Metrics

| Metric | Description | Target | Unit |
|--------|-------------|--------|------|
| **Requests/sec** | Throughput | 10,000+ | req/s |
| **P50 Latency** | Median response time | <10ms | ms |
| **P95 Latency** | 95th percentile | <50ms | ms |
| **P99 Latency** | 99th percentile | <100ms | ms |
| **Error Rate** | Failed requests | <1% | % |

### System Metrics

| Resource | Metric | Threshold | Unit |
|----------|--------|-----------|------|
| **CPU** | User + System | <80% | % |
| **Memory** | RSS usage | <85% | % |
| **Network** | Bandwidth | <80% | % |
| **Disk I/O** | Read/Write | <70% | % |

### Tool-Specific Outputs

#### WRK Results
```
Running 30s test @ http://127.0.0.1:8080/
  2 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     5.23ms    3.44ms  45.67ms   85.24%
    Req/Sec     9.52k   845.23   10.12k    72.34%
  285694 requests in 30.01s, 45.67MB read
Requests/sec:   9523.45
Transfer/sec:      1.52MB
```

#### hey Results
```
Summary:
  Total:        30.0000 secs
  Slowest:      0.0457 secs
  Fastest:      0.0012 secs
  Average:      0.0052 secs
  Requests/sec: 9523.4567

  Total data:   45.67 MB
  Size/request: 167 bytes

Response time histogram:
  0.001 [1]     |
  0.005 [8923]  |■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■■
  0.010 [567]   |■■■■
  0.020 [234]   |■■
  0.050 [23]    |

Latency distribution:
  10% in 0.0023 secs
  25% in 0.0034 secs
  50% in 0.0052 secs
  75% in 0.0078 secs
  90% in 0.0123 secs
  95% in 0.0189 secs
  99% in 0.0345 secs
```

## Regression Testing

### Setting Baselines

```bash
# Set current performance as baseline
./scripts/bench/reproduce.sh baseline

# Baseline stored in: benches/baseline.json
```

### Regression Detection

```bash
# Check for regressions against baseline
./scripts/bench/reproduce.sh regression

# Output example:
PERFORMANCE REGRESSION DETECTED: 15.3% degradation in requests/sec
Current: 8234 req/sec
Baseline: 9523 req/sec
```

### Threshold Configuration

```toml
[regression]
enabled = true
max_degradation_percentage = 10.0  # Alert if >10% slower
min_improvement_percentage = 5.0   # Note if >5% faster

[thresholds]
p95_response_time = 50  # Alert if >50ms
max_error_rate_percentage = 1.0  # Alert if >1% errors
```

## Configuration

### Benchmark Configuration

```toml
# benches/config.toml
[benchmark]
name = "production-benchmarks"
description = "Production performance validation"

[load_test]
connections = 1000
duration_seconds = 300
rate_limit = 50000  # 50k req/sec limit

[thresholds]
p99_response_time = 100  # 100ms target
min_requests_per_second = 50000
max_error_rate_percentage = 0.1
```

### Environment Variables

```bash
# Override configuration
export DURATION=60
export CONNECTIONS=500
export THREADS=8
export HOST=127.0.0.1
export PORT=8080
export TLS=true
export QUIC=false
```

## Running Benchmarks

### Local Development

```bash
# Basic benchmark
./scripts/bench/local-benchmark.sh

# Custom configuration
DURATION=60 CONNECTIONS=200 ./scripts/bench/local-benchmark.sh

# TLS testing
TLS=true ./scripts/bench/local-benchmark.sh

# QUIC testing
QUIC=true ./scripts/bench/local-benchmark.sh
```

### CI/CD Integration

```yaml
# .github/workflows/benchmark.yml
name: Benchmark
on:
  push:
    branches: [main]
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
      - name: Install tools
        run: sudo apt-get install -y wrk
      - name: Run benchmarks
        run: ./scripts/bench/local-benchmark.sh
      - name: Regression check
        run: ./scripts/bench/reproduce.sh regression
```

### Docker-Based Benchmarking

```bash
# Run benchmarks in Docker
docker run --rm \
  -v $(pwd):/workspace \
  -w /workspace \
  --network host \
  blitz-gateway:latest \
  ./scripts/bench/local-benchmark.sh
```

## Analyzing Results

### Result Structure

```
benches/results/20241201_143022/
├── summary.txt              # Human-readable summary
├── system_metrics.txt       # System resource usage
├── wrk_results.txt         # WRK raw output
├── hey_results.txt         # hey raw output
├── server.log              # Server logs
├── commit.txt              # Commit information
└── errors.log              # Any errors encountered
```

### Key Performance Indicators

```bash
# Extract key metrics from results
grep "Requests/sec" benches/results/*/wrk_results.txt
grep "95%" benches/results/*/hey_results.txt
grep "error" benches/results/*/errors.log
```

### Comparative Analysis

```bash
# Compare two benchmark runs
./scripts/bench/reproduce.sh compare commit1 commit2

# Output:
Benchmark Comparison
=======================================
Commit 1: abc123 Optimize connection pooling
Commit 2: def456 Add request caching

WRK Results:
  Commit 1: 9523 req/sec
  Commit 2: 11234 req/sec
  Difference: +1711
  Status: IMPROVEMENT

hey Results:
  Commit 1: 9456 req/sec
  Commit 2: 11189 req/sec
  Difference: +1733
  Status: IMPROVEMENT
```

### Statistical Analysis

The benchmark suite provides:

- **Confidence Intervals**: Statistical significance testing
- **Outlier Detection**: Remove anomalous results
- **Trend Analysis**: Performance over time
- **Regression Alerts**: Automatic notifications

## CI/CD Integration

### GitHub Actions Integration

```yaml
name: Performance Regression
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

      - name: Run benchmark
        run: ./scripts/bench/local-benchmark.sh

      - name: Check regression
        run: ./scripts/bench/reproduce.sh regression

      - name: Comment on PR
        if: failure()
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: '⚠️ **Performance Regression Detected**\n\n' +
                    'This PR introduces a performance regression. ' +
                    'Please review the benchmark results and optimize if necessary.'
            })
```

### Automated Reporting

```yaml
- name: Generate report
  run: |
    # Generate HTML report
    ./scripts/bench/generate-report.sh

- name: Upload results
  uses: actions/upload-artifact@v4
  with:
    name: benchmark-results
    path: benches/results/
```

## Troubleshooting

### Common Issues

#### Benchmark Tools Not Found

```bash
# Install WRK
sudo apt-get install wrk

# Install hey
wget https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x hey_linux_amd64
sudo mv hey_linux_amd64 /usr/local/bin/hey

# Install bombardier
go install -ldflags="-s -w" github.com/codesenberg/bombardier@latest
```

#### Server Won't Start

```bash
# Check port availability
netstat -tlnp | grep :8080

# Check server logs
tail -f benches/results/*/server.log

# Manual server test
zig build -Doptimize=ReleaseFast
./zig-out/bin/blitz --help
```

#### Inconsistent Results

```bash
# Run multiple iterations
for i in {1..5}; do
  echo "Iteration $i:"
  ./scripts/bench/local-benchmark.sh
  sleep 10
done

# Check system load
uptime
htop
```

#### Memory Issues

```bash
# Monitor memory usage
watch -n 1 'ps aux --sort=-%mem | head -5'

# Check for memory leaks
valgrind --tool=massif ./zig-out/bin/blitz --help

# Adjust benchmark settings
CONNECTIONS=50 THREADS=2 ./scripts/bench/local-benchmark.sh
```

### Performance Tuning

#### System Optimization

```bash
# Kernel parameters
sudo sysctl -w net.core.somaxconn=65536
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=65536
sudo sysctl -w fs.file-max=2097152

# CPU governor
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Disable swap (for consistent results)
sudo swapoff -a
```

#### Application Tuning

```bash
# Environment variables for performance
export QUIC_MAX_CONNECTIONS=10000
export HTTP_MAX_CONCURRENT=1000
export WORKER_THREADS=8
export GOMEMLIMIT=1GiB
```

### Getting Help

1. **Documentation**: Check this guide and inline help
2. **GitHub Issues**: Report bugs and performance issues
3. **Community**: Join discussions for optimization tips
4. **Professional Support**: Contact team for enterprise assistance

---

**Benchmarking Blitz Gateway** ensures consistent high performance across releases. The suite provides automated regression detection, comprehensive metrics collection, and CI/CD integration for continuous performance validation.
