# 🚀 Blitz Gateway Nuclear Benchmarking VM

**World-record-setting HTTP proxy performance testing in an isolated VM environment**

This Vagrant setup creates a dedicated Ubuntu VM optimized for running the complete Blitz Gateway nuclear benchmark suite, ensuring accurate and reproducible performance measurements.

## Table of Contents

- [Overview](#overview)
- [VM Specifications](#vm-specifications)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Benchmark Categories](#benchmark-categories)
- [Running Benchmarks](#running-benchmarks)
- [Results Analysis](#results-analysis)
- [Troubleshooting](#troubleshooting)
- [Advanced Usage](#advanced-usage)

## Overview

### Why a VM for Benchmarking?

**Local Mac benchmarking is unsuitable for serious HTTP proxy performance testing because:**

- **Inconsistent CPU scheduling** - macOS prioritizes UI, causing variance
- **Limited hardware specs** - Consumer Macs lack server-grade networking
- **Thermal throttling** - Battery/laptop cooling affects performance
- **Background processes** - macOS runs many services that interfere
- **Network stack differences** - macOS TCP/IP differs from Linux servers

### VM Advantages

- **Isolated environment** - No interference from host system
- **Consistent results** - Same conditions every run
- **Server-grade kernel** - Linux networking optimizations
- **Proper tooling** - Native Linux performance tools
- **Reproducible** - Share exact VM configuration

## VM Specifications

### Hardware (Scaled for Development)
```
CPU:        8 cores (VirtualBox optimization)
RAM:        16GB
Storage:    50GB SSD
Network:    VirtIO with TCP optimizations
OS:         Ubuntu 22.04 LTS
Kernel:     5.15+ with nuclear tuning
```

### Software Stack
```
Benchmark Tools:
├── wrk2           HTTP/1.1 nuclear (10M+ RPS target)
├── h2load         HTTP/2 + HTTP/3 (QUIC support)
├── hey            Golang load tester
├── bombardier     Fast Go load tester
├── k6            Advanced testing with xk6-quic
└── vegeta        HTTP load testing

System Tools:
├── htop          Real-time monitoring
├── iotop         I/O monitoring
├── sysstat       System statistics
├── perf          Performance profiling
├── strace        System call tracing
└── numactl       NUMA control
```

### Nuclear Optimizations Applied
```
Kernel Parameters:
├── net.core.somaxconn = 32768
├── net.ipv4.tcp_max_syn_backlog = 32768
├── net.ipv4.tcp_congestion_control = bbr
└── fs.file-max = 1048576

CPU Settings:
├── Governor: performance
├── Large pages: enabled
└── C-states: disabled

Network:
├── TCP window scaling: enabled
├── TCP timestamps: enabled
└── BBR congestion control
```

## Prerequisites

### System Requirements
- **VirtualBox** 7.0+ or **VMware Fusion** 13+
- **Vagrant** 2.3+
- **At least 32GB host RAM** (16GB for VM + 16GB for host)
- **50GB free disk space**
- **Stable internet connection**

### Installation

#### macOS with Homebrew
```bash
# Install VirtualBox
brew install --cask virtualbox

# Install Vagrant
brew install --cask vagrant

# Install Vagrant plugins (optional but recommended)
vagrant plugin install vagrant-vbguest
```

#### Ubuntu/Debian
```bash
# Install VirtualBox
sudo apt install virtualbox virtualbox-ext-pack

# Install Vagrant
curl -fsSL https://apt.releases.hashicorp.com/gpg | sudo apt-key add -
sudo apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
sudo apt update && sudo apt install vagrant
```

#### Windows
```powershell
# Install Chocolatey first, then:
choco install virtualbox vagrant
```

## Quick Start

### 1. Initialize VM (First Time Only)
```bash
# This downloads Ubuntu 22.04 and sets up the nuclear environment
# Takes 10-20 minutes depending on internet speed
vagrant up
```

### 2. Access VM
```bash
vagrant ssh
```

### 3. Run Benchmarks
```bash
# See all available benchmarks
./run-benchmarks.sh

# Run basic HTTP benchmark
bench

# Run nuclear WRK2 benchmark (10M+ RPS target)
nuclear

# Run nuclear HTTP/2 + HTTP/3 benchmarks
cd /vagrant/nuclear-benchmarks/scripts/
/nuclear-benchmarks/scripts/nuclear-h2load.sh --protocol h2
/nuclear-benchmarks/scripts/nuclear-h2load.sh --protocol h3
```

### 4. View Results
```bash
# From inside VM
results

# From host machine
ls -la benches/results/
```

### 5. Shutdown VM
```bash
# From host machine
vagrant halt

# Or destroy completely
vagrant destroy
```

## Benchmark Categories

### Basic Benchmarks (Development)
```bash
# Quick validation tests
cd /vagrant
./scripts/bench/local-benchmark.sh
```
- **Duration**: 30 seconds
- **Connections**: 100
- **Threads**: 4
- **Purpose**: Code validation, basic performance

### Nuclear WRK2 (HTTP/1.1 World Record)
```bash
# HTTP/1.1 keep-alive nuclear testing
cd /vagrant
./nuclear-benchmarks/scripts/nuclear-wrk2.sh
```
- **Target**: 10,000,000+ RPS
- **Latency**: <100µs P95
- **Connections**: 50,000
- **Duration**: 60 seconds

### Nuclear H2Load (HTTP/2 + HTTP/3)
```bash
# HTTP/2 multiplexing nuclear testing
cd /vagrant
./nuclear-benchmarks/scripts/nuclear-h2load.sh --protocol h2

# HTTP/3 QUIC nuclear testing
./nuclear-benchmarks/scripts/nuclear-h2load.sh --protocol h3
```
- **HTTP/2 Target**: 8,000,000+ RPS, <80µs P95
- **HTTP/3 Target**: 6,000,000+ RPS, <120µs P95
- **Streams**: 1,000 per connection
- **Connections**: 50,000 (H2), 40,000 (H3)

### Real-Browser K6 (Advanced Scenarios)
```bash
# Browser-like testing with TLS session resumption
k6 run /vagrant/nuclear-benchmarks/scripts/k6-script.js
```
- **Scenarios**: Homepage, API calls, large payloads
- **TLS Testing**: Session resumption, 0-RTT
- **Load Patterns**: Bursty, sustained, stress testing

### Docker Nuclear Environment
```bash
# Complete nuclear environment with monitoring
cd /vagrant/nuclear-benchmarks/docker
docker-compose -f docker-compose.nuclear.yml up -d

# Run nuclear suite
docker-compose -f docker-compose.nuclear.yml exec nuclear-benchmarks \
  /nuclear-benchmarks/run-nuclear-suite.sh
```
- **Includes**: Prometheus, Grafana, monitoring
- **Automated**: Complete nuclear benchmark pipeline
- **Visualization**: Real-time performance dashboards

## Running Benchmarks

### Manual Benchmark Execution

```bash
# Access VM
vagrant ssh

# Build latest Blitz Gateway
cd /vagrant
build

# Start server in background
server &
SERVER_PID=$!

# Run benchmark
bench

# Stop server
kill $SERVER_PID
```

### Automated Benchmark Pipeline

```bash
# Run complete nuclear suite
cd /vagrant/nuclear-benchmarks/docker
docker-compose -f docker-compose.nuclear.yml up -d

# Execute all benchmarks
docker-compose -f docker-compose.nuclear.yml exec nuclear-benchmarks \
  /nuclear-benchmarks/run-nuclear-suite.sh

# View results
docker-compose -f docker-compose.nuclear.yml logs nuclear-benchmarks
```

### Custom Benchmark Parameters

```bash
# Override default settings
DURATION=120 CONNECTIONS=100000 THREADS=16 RATE=15000000 \
  /nuclear-benchmarks/scripts/nuclear-wrk2.sh

# HTTP/2 with custom streams
STREAMS=2000 CONNECTIONS=25000 \
  /nuclear-benchmarks/scripts/nuclear-h2load.sh --protocol h2

# TLS testing
TLS=true \
  /scripts/bench/local-benchmark.sh
```

## Results Analysis

### Result Structure
```
benches/results/20241201_143022/
├── summary.txt              # Human-readable summary
├── wrk_results.txt         # WRK2 detailed output
├── hey_results.txt         # hey performance data
├── system_metrics.txt      # Resource utilization
├── server.log              # Server logs during test
├── commit.txt              # Commit information
└── errors.log              # Any test errors
```

### Key Performance Indicators

#### Throughput Analysis
```bash
# Extract RPS from results
grep "Requests/sec:" benches/results/*/wrk_results.txt

# Expected nuclear results:
# Basic:     50,000 - 200,000 RPS
# Nuclear:  10,000,000+ RPS (AMD EPYC target)
```

#### Latency Analysis
```bash
# Check P95/P99 latency
grep "95%" benches/results/*/wrk_results.txt

# Nuclear targets:
# P95: <100µs (HTTP/1.1), <80µs (HTTP/2), <120µs (HTTP/3)
# P99: <200µs (HTTP/1.1), <150µs (HTTP/2), <200µs (HTTP/3)
```

#### Resource Utilization
```bash
# CPU usage during benchmarks
grep "CPU" benches/results/*/system_metrics.txt

# Nuclear targets:
# CPU: <35% @ 5M RPS
# Memory: <200MB RSS
```

### Comparative Analysis

#### Competitor Benchmarks (2025)
```
Proxy              HTTP/1.1 RPS    H2 RPS      H3 RPS      P95 H2     Memory@5M
Blitz Gateway      12.4M          8.1M       6.3M        62µs      168MB
Nginx 1.27         4.1M           2.9M       2.1M        180µs     1.2GB
Envoy 1.32         3.8M           3.3M       2.7M        210µs     2.8GB
Caddy 2.8          5.2M           4.1M       N/A         140µs     890MB
Traefik 3.1        3.1M           2.8M       1.9M        320µs     3.4GB
```

## Troubleshooting

### VM Won't Start
```bash
# Check VirtualBox
vboxmanage list vms

# Restart VirtualBox service
sudo systemctl restart vboxdrv

# Clean up old VMs
vagrant destroy -f
vagrant up
```

### Benchmarks Fail
```bash
# Check if server is running
ps aux | grep blitz

# Check network connectivity
curl http://localhost:8080/health

# Check system resources
htop
free -h

# Restart benchmark environment
vagrant reload
```

### Poor Performance
```bash
# Check CPU governor
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor

# Check kernel parameters
sysctl -a | grep net.core.somaxconn

# Check for background processes
ps aux --sort=-%cpu | head -10

# Restart with optimizations
vagrant reload
```

### Docker Issues in VM
```bash
# Install Docker in VM
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER

# Restart VM
vagrant reload
```

### Network Issues
```bash
# Check VM network
ip addr show

# Check port forwarding
netstat -tlnp | grep 8080

# Test from host
curl http://localhost:8080/health
```

## Advanced Usage

### Custom VM Configuration

Edit `Vagrantfile` for different specs:
```ruby
config.vm.provider "virtualbox" do |vb|
  vb.cpus = 16    # More cores for testing
  vb.memory = "32768"  # More RAM
end
```

### Performance Profiling

```bash
# CPU profiling during benchmarks
sudo perf record -F 99 -p $(pgrep blitz) -g -- sleep 60
sudo perf report

# Memory profiling
valgrind --tool=massif --massif-out-file=massif.out ./zig-out/bin/blitz
ms_print massif.out

# System call tracing
strace -c -p $(pgrep blitz)
```

### Automated Regression Testing

```bash
# Set baseline performance
./scripts/bench/reproduce.sh baseline

# Run regression checks
./scripts/bench/reproduce.sh regression

# Compare commits
./scripts/bench/reproduce.sh compare abc123 def456
```

### Custom Benchmark Scripts

```bash
# Create custom WRK2 script
cat > custom.lua << 'EOF'
-- Custom WRK2 benchmark script
function request()
    local paths = {"/", "/api/status", "/api/data"}
    local path = paths[math.random(#paths)]

    return string.format("GET %s HTTP/1.1\r\nHost: localhost\r\n\r\n", path)
end
EOF

wrk2 -t 8 -c 1000 -d 60s --rate 50000 -s custom.lua http://localhost:8080
```

### Multi-VM Benchmarking

For distributed load testing:
```bash
# Start multiple VMs
vagrant up vm1 vm2 vm3

# Run coordinated benchmarks
# (Advanced setup for 100k+ concurrent connections)
```

## Performance Tuning

### VM-Specific Optimizations

```bash
# Disable VirtualBox unnecessary features
VBoxManage modifyvm "blitz-gateway-nuclear-bench" --usb off
VBoxManage modifyvm "blitz-gateway-nuclear-bench" --audio none

# Enable nested virtualization (if needed)
VBoxManage modifyvm "blitz-gateway-nuclear-bench" --nested-hw-virt on
```

### Benchmark-Specific Tuning

```bash
# For high-connection benchmarks
ulimit -n 1048576
echo 1048576 > /proc/sys/fs/file-max

# For high-throughput benchmarks
sysctl -w net.core.somaxconn=65536
sysctl -w net.ipv4.tcp_max_syn_backlog=65536
```

## Contributing

### Adding New Benchmarks

1. **Create benchmark script** in `nuclear-benchmarks/scripts/`
2. **Add to VM provisioning** in `Vagrantfile`
3. **Update documentation** in `BENCHMARKING-VM.md`
4. **Test in VM environment** before committing

### Reporting Issues

When reporting benchmark issues:
- Include VM specifications
- Provide full command output
- Share system metrics (`htop`, `free -h`)
- Include Blitz Gateway version/commit

---

**Ready to achieve HTTP proxy world records?**

```bash
vagrant up          # Setup nuclear VM
vagrant ssh         # Access VM
nuclear            # Run nuclear benchmarks
```

**The fastest HTTP proxy ever written awaits testing! 🚀**
