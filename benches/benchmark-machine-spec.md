# Benchmark Machine Specifications

## Recommended Hardware (2025)

### Tier 1: Maximum Performance (Target: 12M+ RPS)

| Component | Specification | Cost | Where to Get |
|-----------|--------------|------|--------------|
| CPU | AMD EPYC 9754 (128-core Bergamo) or EPYC 9575F (96-core Turin) | $5-7k | Newegg, Supermicro |
| RAM | 128-256 GB DDR5-5600 | $800-1.5k | Any vendor |
| NIC | Dual 100 Gbps Mellanox/NVIDIA ConnectX-7 or Broadcom | $1-2k | eBay, specialized vendors |
| OS | Ubuntu 24.04 LTS, kernel 6.11+ | Free | ubuntu.com |

**Total Cost**: ~$7-10k (one-time)

### Tier 2: Cloud/Bare Metal Rental (Recommended for Day-1)

| Provider | Instance Type | Specs | Cost | Link |
|----------|--------------|-------|------|-----|
| Equinix Metal | m3.large.x86 | 128-core EPYC, 256GB RAM | ~$2.50/hr | equinix.com |
| Packet.com | c3.large.arm | Ampere Altra 80-core | ~$1.50/hr | packet.com |
| Lattice.work | Custom | Various EPYC configs | ~$800/mo | lattice.work |
| Clouvider | Bare Metal | EPYC 7003 series | ~$600-1000/mo | clouvider.com |

**Recommendation**: Start with Equinix Metal m3.large.x86 for 2-4 hours ($5-10) to get initial benchmarks, then decide on longer-term rental.

### Tier 3: Development/Testing (Local Machine)

For initial development and testing:
- Any modern CPU with 8+ cores
- 16GB+ RAM
- Linux 5.15+ (for io_uring)
- Localhost testing only

**Expected**: 1-3M RPS on good laptop, 3-5M RPS on desktop

## System Configuration

### Required Kernel Version
- Linux 5.15+ (io_uring support)
- Linux 6.11+ (recommended, latest io_uring optimizations)

### Automated Setup (Recommended)

**One-command setup** (Ubuntu 24.04 LTS):

```bash
curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/bench-box-setup.sh | sudo bash
```

This script will:
- Upgrade kernel to HWE (6.11+)
- Apply all network and system tuning
- Disable THP (reduces jitter)
- Set CPU governor to performance
- Install benchmarking tools (wrk2, hey)
- Configure CPU isolation (optional)

**Or if you have the repo:**

```bash
sudo ./scripts/bench-box-setup.sh
```

### Manual Network Tuning (if needed)

If you prefer manual setup:

```bash
# High connection limits
echo 'net.core.somaxconn = 1048576' >> /etc/sysctl.conf
echo 'net.ipv4.tcp_max_syn_backlog = 1048576' >> /etc/sysctl.conf
echo 'net.core.netdev_max_backlog = 50000' >> /etc/sysctl.conf
echo 'net.ipv4.ip_local_port_range = 1024 65535' >> /etc/sysctl.conf
sysctl -p

# CPU governor
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Disable THP (reduces jitter - important!)
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

### CPU Isolation (for maximum performance)

```bash
# Isolate cores 0-95 for Blitz, leave 96-127 for system/client
taskset -c 0-95 ./zig-out/bin/blitz
```

## Benchmark Client Requirements

The client machine should be:
- Same data center (same rack preferred)
- 100 Gbps NIC (or at least 10 Gbps)
- Similar CPU (doesn't need to be as powerful)
- Running wrk2 or hey

**Note**: For localhost testing, the same machine can be both server and client, but results will be lower due to context switching.

## Expected Results by Hardware Tier

| Hardware Tier | Expected RPS | p99 Latency | Notes |
|--------------|--------------|-------------|-------|
| EPYC 9754 (128-core) | 12-15M | 60-80 µs | Production target |
| EPYC 4584PX (48-core) | 6-8M | 80-100 µs | Good alternative |
| Cloud instance (80-core) | 4-6M | 100-150 µs | Rental option |
| Desktop (16-core) | 3-5M | 150-200 µs | Development |
| Laptop (8-core) | 1-3M | 200-300 µs | Local testing |

## Verification Checklist

Before running benchmarks:

- [ ] Kernel version 5.15+ (`uname -r`)
- [ ] io_uring support (`ls /sys/fs/io_uring`)
- [ ] liburing installed (`pkg-config --modversion liburing`)
- [ ] System tuning applied (see above)
- [ ] CPU governor set to performance
- [ ] File descriptor limits increased (`ulimit -n 100000`)
- [ ] Network tuning applied
- [ ] Client machine ready (same DC, 10G+ NIC)

## Troubleshooting

**Low RPS (< 1M)**
- Check CPU governor: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
- Check for CPU throttling: `dmesg | grep -i thermal`
- Verify io_uring: `dmesg | grep -i uring`
- Check network: `ethtool -S <interface> | grep -i error`

**High latency (> 200 µs)**
- Ensure CPU isolation
- Check for context switching: `vmstat 1`
- Verify no other processes using CPU: `top` or `htop`
- Check network latency: `ping <server_ip>`

**Connection errors**
- Increase file descriptor limits
- Check network tuning (somaxconn, backlog)
- Verify firewall rules
- Check for port conflicts

