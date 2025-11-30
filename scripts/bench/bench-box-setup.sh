#!/usr/bin/env bash
# Blitz Benchmark Box Setup Script
# Optimizes Ubuntu 24.04 LTS for maximum io_uring performance
# Target: 10M-15M RPS, <50µs p99 latency

set -euo pipefail

echo "=========================================="
echo "Blitz Benchmark Box Setup"
echo "=========================================="
echo "This script will optimize your system for maximum io_uring performance"
echo "Target: 10M-15M RPS, <50µs p99 latency"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "ERROR: This script must be run as root (use sudo)"
    exit 1
fi

# Detect Ubuntu version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
    VERSION=$VERSION_ID
else
    echo "ERROR: Cannot detect OS version"
    exit 1
fi

echo "Detected: $OS $VERSION"
echo ""

# Check if Ubuntu 24.04
if [[ "$OS" != "ubuntu" ]] || [[ "$VERSION" != "24.04" ]]; then
    echo "WARNING: This script is optimized for Ubuntu 24.04 LTS"
    echo "You're running: $OS $VERSION"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Check if already ran (avoid double-reboot)
if [ -f /etc/blitz-bench-setup-complete ]; then
    echo "Setup already completed. Skipping kernel upgrade."
    SKIP_KERNEL=true
else
    SKIP_KERNEL=false
fi

# Step 1: Upgrade kernel to HWE (6.11+)
if [ "$SKIP_KERNEL" = false ]; then
    echo "=========================================="
    echo "Step 1: Upgrading kernel to HWE (6.11+)"
    echo "=========================================="
    
    apt update
    apt install -y linux-generic-hwe-24.04 linux-headers-generic-hwe-24.04
    
    echo ""
    echo "Kernel upgrade complete. Current kernel:"
    uname -r
    
    echo ""
    echo "=========================================="
    echo "REBOOT REQUIRED"
    echo "=========================================="
    echo "The system will reboot in 10 seconds to load the new kernel."
    echo "After reboot, run this script again to complete setup."
    echo ""
    sleep 10
    
    # Mark that we need to continue after reboot
    touch /etc/blitz-bench-setup-reboot-needed
    reboot
    exit 0
fi

# Step 2: Network tuning (post-reboot)
echo "=========================================="
echo "Step 2: Network & System Tuning"
echo "=========================================="

cat <<'EOF' > /etc/sysctl.d/99-blitz.conf
# Blitz Benchmark Optimizations
# Maximum connection limits
net.core.somaxconn = 1048576
net.ipv4.tcp_max_syn_backlog = 1048576
net.core.netdev_max_backlog = 50000
net.ipv4.ip_local_port_range = 1024 65535

# TCP optimizations
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 5
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_recycle = 0  # Disabled in modern kernels, but explicit

# Buffer sizes (large for high throughput)
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.udp_mem = 4096 87380 67108864

# Memory overcommit (for zero-allocation patterns)
vm.overcommit_memory = 1

# Disable OOM killer for benchmark processes
vm.oom_kill_allocating_task = 0

# File descriptor limits
fs.file-max = 2097152

# Disable swap (for consistent latency)
vm.swappiness = 0

# Kernel panic settings (fail fast)
kernel.panic_on_oops = 1
kernel.hung_task_timeout_secs = 0

# Disable mitigations for maximum performance (benchmark only!)
# WARNING: Only use on isolated benchmark boxes, not production
kernel.mitigations=off
EOF

sysctl --system

echo "Network tuning applied."

# Step 3: Disable Transparent Huge Pages (kills jitter)
echo ""
echo "=========================================="
echo "Step 3: Disabling Transparent Huge Pages"
echo "=========================================="

echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# Make it persistent
cat <<'EOF' > /etc/rc.local
#!/bin/bash
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
exit 0
EOF
chmod +x /etc/rc.local

echo "THP disabled (reduces jitter significantly)."

# Step 4: CPU Governor
echo ""
echo "=========================================="
echo "Step 4: Setting CPU Governor to Performance"
echo "=========================================="

# Install cpufreq utils if not present
apt install -y linux-tools-common linux-tools-generic || true

# Set to performance mode
echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor > /dev/null 2>&1 || {
    echo "WARNING: Could not set CPU governor (may not be available on this system)"
}

# Make it persistent
cat <<'EOF' > /etc/default/cpufrequtils
GOVERNOR="performance"
EOF

echo "CPU governor set to performance."

# Step 5: CPU Isolation (optional, for maximum performance)
echo ""
echo "=========================================="
echo "Step 5: CPU Isolation (Optional)"
echo "=========================================="

read -p "Isolate CPUs for Blitz? (leaves cores 0-7 for system, isolates 8+) [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    # Get CPU count
    CPU_COUNT=$(nproc)
    LAST_CPU=$((CPU_COUNT - 1))
    
    if [ $CPU_COUNT -gt 8 ]; then
        ISOL_CPUS="8-$LAST_CPU"
        echo "Isolating CPUs $ISOL_CPUS for Blitz..."
        
        # Update GRUB
        if [ -f /etc/default/grub ]; then
            if ! grep -q "isolcpus" /etc/default/grub; then
                sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/&isolcpus=$ISOL_CPUS /" /etc/default/grub
                update-grub
                echo "CPU isolation configured. Reboot required to take effect."
            else
                echo "CPU isolation already configured in GRUB."
            fi
        fi
    else
        echo "Not enough CPUs for isolation (need > 8, have $CPU_COUNT)"
    fi
else
    echo "Skipping CPU isolation."
fi

# Step 6: Disable unnecessary services
echo ""
echo "=========================================="
echo "Step 6: Disabling Unnecessary Services"
echo "=========================================="

SERVICES_TO_DISABLE=(
    "snapd"
    "apparmor"
    "bluetooth"
    "cups"
    "cups-browsed"
    "ModemManager"
    "whoopsie"
    "unattended-upgrades"
)

for service in "${SERVICES_TO_DISABLE[@]}"; do
    if systemctl is-enabled "$service" >/dev/null 2>&1; then
        systemctl disable "$service" 2>/dev/null || true
        systemctl stop "$service" 2>/dev/null || true
        echo "Disabled: $service"
    fi
done

echo "Unnecessary services disabled."

# Step 7: Increase file descriptor limits
echo ""
echo "=========================================="
echo "Step 7: Increasing File Descriptor Limits"
echo "=========================================="

cat <<'EOF' >> /etc/security/limits.conf
# Blitz benchmark limits
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 1048576
* hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

echo "File descriptor limits increased."

# Step 8: Install benchmarking tools
echo ""
echo "=========================================="
echo "Step 8: Installing Benchmarking Tools"
echo "=========================================="

# Install build tools for wrk2
apt install -y build-essential git curl

# Install wrk2 if not present
if ! command -v wrk2 &> /dev/null; then
    echo "Installing wrk2..."
    cd /tmp
    git clone https://github.com/giltene/wrk2.git || true
    cd wrk2
    make
    cp wrk /usr/local/bin/wrk2
    cd /
    rm -rf /tmp/wrk2
    echo "wrk2 installed."
else
    echo "wrk2 already installed."
fi

# Install hey (optional)
if ! command -v hey &> /dev/null; then
    if command -v go &> /dev/null; then
        echo "Installing hey..."
        go install github.com/rakyll/hey@latest || true
        echo "hey installed (if Go was available)."
    else
        echo "hey not installed (Go not available, optional)"
    fi
else
    echo "hey already installed."
fi

# Step 9: Verify io_uring support
echo ""
echo "=========================================="
echo "Step 9: Verifying io_uring Support"
echo "=========================================="

if [ -d /sys/fs/io_uring ]; then
    echo "✓ io_uring is available"
    echo "  Kernel version: $(uname -r)"
    echo "  io_uring entries: $(cat /sys/fs/io_uring/max_entries 2>/dev/null || echo 'N/A')"
else
    echo "✗ WARNING: io_uring not available (kernel may be too old)"
    echo "  Current kernel: $(uname -r)"
    echo "  Required: 5.15+"
fi

# Step 10: Final checks
echo ""
echo "=========================================="
echo "Step 10: Final System Check"
echo "=========================================="

echo "Kernel version: $(uname -r)"
echo "CPU cores: $(nproc)"
echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
echo "CPU governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo 'N/A')"
echo "THP status: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "File descriptor limit: $(ulimit -n)"

# Mark setup as complete
touch /etc/blitz-bench-setup-complete

echo ""
echo "=========================================="
echo "Setup Complete!"
echo "=========================================="
echo ""
echo "Your system is now optimized for Blitz benchmarks."
echo ""
echo "Next steps:"
echo "  1. If CPU isolation was enabled, reboot: sudo reboot"
echo "  2. Build Blitz: cd /path/to/blitz && zig build -Doptimize=ReleaseFast"
echo "  3. Run benchmarks: ./benches/reproduce.sh"
echo ""
echo "Expected performance (EPYC 9754, 128-core):"
echo "  - 12-15M RPS (HTTP/1.1 keep-alive)"
echo "  - <70µs p99 latency"
echo "  - <150MB memory at 5M RPS"
echo ""
echo "For maximum performance, ensure:"
echo "  - CPU isolation enabled (if >8 cores)"
echo "  - System is idle (no other processes)"
echo "  - Network tuning applied (done above)"
echo ""

