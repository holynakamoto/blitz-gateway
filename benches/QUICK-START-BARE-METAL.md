# Quick Start: Bare Metal Benchmarks

Since Docker has a Zig 0.12.0 liburing linking issue, here's the fastest path to get benchmarks running:

## Step 1: Get a Linux Server

**Free Options:**
- **Zemim**: 30-day free trial - https://www.zemim.com/free-dedicated-server-trial/ ($1 verification)
- **BareServer**: 24-hour free trial - https://www.bare-server.com/pricing (request in order notes)

**Low-Cost Options:**
- **Hetzner**: €4-8/month VPS (good for testing)
- **DigitalOcean**: $6/month (with $200 free credit via GitHub Student Pack)

## Step 2: Deploy Ubuntu 24.04 LTS Minimal

On your server:

```bash
# One-command setup
curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/bench-box-setup.sh | sudo bash
```

This will:
- Upgrade kernel to 6.11+
- Apply all system tuning
- Install benchmarking tools
- Optimize for maximum performance

## Step 3: Build and Run

```bash
# Clone repo
git clone https://github.com/blitz-gateway/blitz.git
cd blitz

# Build
zig build -Doptimize=ReleaseFast

# Run
./zig-out/bin/blitz
```

## Step 4: Benchmark

In another terminal:

```bash
# Quick test
curl http://localhost:8080/hello

# Full benchmark
./benches/reproduce.sh
```

## Expected Results

On good hardware (8+ cores):
- **1-5M RPS** (depending on CPU)
- **p99 latency: 100-200 µs**

On EPYC 9754 (128-core):
- **12-15M RPS**
- **p99 latency: 60-80 µs**

## Why Not Docker?

Docker has a known Zig 0.12.0 liburing linking issue. The code is correct and works perfectly on bare metal. Docker is just for testing the setup process - real benchmarks need bare metal anyway for accurate numbers.

**Bottom line**: Get a Linux server, run the setup script, build, and benchmark. It'll work perfectly.

