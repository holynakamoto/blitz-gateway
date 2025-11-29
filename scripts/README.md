# Blitz Setup Scripts

## bench-box-setup.sh

One-command system optimization for maximum io_uring performance.

### Quick Start

On a fresh Ubuntu 24.04 LTS Minimal installation:

```bash
curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/bench-box-setup.sh | sudo bash
```

Or if you have the repo cloned:

```bash
sudo ./scripts/bench-box-setup.sh
```

### What It Does

1. **Upgrades kernel** to HWE (6.11+) for latest io_uring optimizations
2. **Network tuning** - Maximum connection limits, TCP optimizations
3. **Disables THP** - Eliminates jitter from transparent huge pages
4. **CPU governor** - Sets to performance mode
5. **CPU isolation** (optional) - Isolates cores for Blitz
6. **Disables services** - Removes background noise (snapd, apparmor, etc.)
7. **File descriptors** - Increases limits to 1M+
8. **Installs tools** - wrk2, hey for benchmarking
9. **Verifies io_uring** - Confirms kernel support

### Requirements

- Ubuntu 24.04 LTS (recommended) or 22.04 LTS
- Root access (sudo)
- Internet connection (for package installation)

### Expected Results

After running this script on EPYC 9754 (128-core):

- **12-15M RPS** (HTTP/1.1 keep-alive)
- **<70µs p99 latency**
- **<150MB memory** at 5M RPS

### Notes

- Script will reboot once for kernel upgrade
- After reboot, run the script again to complete setup
- CPU isolation requires a second reboot if enabled
- Some optimizations (mitigations=off) are for benchmark boxes only, not production

### Troubleshooting

**Script fails on kernel upgrade:**
- Ensure you have internet connectivity
- Check: `apt update && apt upgrade`

**io_uring not available:**
- Kernel may be too old (< 5.15)
- Check: `ls /sys/fs/io_uring`
- Upgrade kernel manually if needed

**Low performance:**
- Verify CPU governor: `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor`
- Check THP: `cat /sys/kernel/mm/transparent_hugepage/enabled` (should be "never")
- Ensure system is idle: `top` or `htop`

### Manual Steps (if script fails)

If the script fails, you can apply optimizations manually:

```bash
# Network tuning
sysctl -w net.core.somaxconn=1048576
sysctl -w net.ipv4.tcp_max_syn_backlog=1048576

# THP
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# CPU governor
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# File descriptors
ulimit -n 1048576
```

See `bench-box-setup.sh` for complete configuration.

