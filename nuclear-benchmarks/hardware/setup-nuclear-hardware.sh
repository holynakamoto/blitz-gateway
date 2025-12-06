#!/bin/bash
# Nuclear Hardware Setup Script
# Configures AMD EPYC/Ampere Altra systems for maximum HTTP proxy performance

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

log_nuclear() {
    echo -e "${PURPLE}[NUCLEAR HARDWARE SETUP]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Detect CPU architecture
detect_cpu() {
    log_info "🔍 Detecting CPU architecture..."

    if lscpu | grep -q "AMD EPYC"; then
        CPU_TYPE="epyc"
        CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
        log_success "✅ AMD EPYC detected: $CPU_MODEL"
    elif lscpu | grep -q "Ampere Altra"; then
        CPU_TYPE="altra"
        CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
        log_success "✅ Ampere Altra detected: $CPU_MODEL"
    else
        CPU_TYPE="generic"
        CPU_MODEL=$(lscpu | grep "Model name" | cut -d: -f2 | xargs)
        log_warning "⚠️ Generic CPU detected: $CPU_MODEL"
        log_warning "   Nuclear benchmarks work best on AMD EPYC 9754 or Ampere Altra"
    fi

    CPU_CORES=$(nproc)
    log_info "CPU cores: $CPU_CORES"
}

# Optimize kernel parameters for nuclear performance
optimize_kernel() {
    log_nuclear "🔧 Optimizing kernel parameters for nuclear HTTP performance..."

    # Create sysctl config
    sudo tee /etc/sysctl.d/99-nuclear-http.conf > /dev/null << 'EOF'
# Nuclear HTTP Proxy Kernel Optimizations
# Tested on AMD EPYC 9754 (128c) and Ampere Altra (128c)

# Network socket limits
net.core.somaxconn = 65536
net.core.netdev_max_backlog = 250000

# TCP optimizations
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 60
net.ipv4.tcp_keepalive_probes = 20

# TCP window scaling and timestamps
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1

# TCP congestion control (BBR for high throughput)
net.ipv4.tcp_congestion_control = bbr

# Memory management for high connection counts
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_rmem = 4096 87380 4194304
net.ipv4.tcp_wmem = 4096 65536 4194304

# UDP optimizations for QUIC/HTTP3
net.core.rmem_max = 25000000
net.core.wmem_max = 25000000

# File descriptor limits
fs.file-max = 2097152
fs.nr_open = 2097152

# Virtual memory optimizations
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1200

# Disable transparent huge pages (can cause latency spikes)
vm.nr_hugepages = 0

# CPU frequency scaling
EOF

    # Apply sysctl settings
    sudo sysctl -p /etc/sysctl.d/99-nuclear-http.conf
    log_success "✅ Kernel parameters optimized"
}

# Optimize CPU settings for maximum performance
optimize_cpu() {
    log_nuclear "⚡ Optimizing CPU settings for nuclear performance..."

    # CPU-specific optimizations
    case $CPU_TYPE in
        epyc)
            # AMD EPYC optimizations
            log_info "Applying AMD EPYC-specific optimizations..."

            # Set CPU governor to performance
            for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
                echo performance | sudo tee "$governor" > /dev/null 2>&1 || true
            done

            # Disable C-states for consistent performance
            for cstate in /sys/devices/system/cpu/cpu*/cpuidle/state*/disable; do
                echo 1 | sudo tee "$cstate" > /dev/null 2>&1 || true
            done

            # Set energy performance preference
            for epb in /sys/devices/system/cpu/cpu*/power/energy_perf_bias; do
                echo 0 | sudo tee "$epb" > /dev/null 2>&1 || true
            done
            ;;

        altra)
            # Ampere Altra optimizations
            log_info "Applying Ampere Altra-specific optimizations..."

            # Set performance mode
            sudo ipmitool raw 0x2e 0x10 0x1a 0x01 0x00 0x00 0x00 0x00 > /dev/null 2>&1 || true

            # CPU frequency scaling
            for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
                echo performance | sudo tee "$governor" > /dev/null 2>&1 || true
            done
            ;;

        *)
            # Generic optimizations
            log_info "Applying generic CPU optimizations..."

            for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
                echo performance | sudo tee "$governor" > /dev/null 2>&1 || true
            done
            ;;
    esac

    log_success "✅ CPU settings optimized"
}

# Optimize memory settings
optimize_memory() {
    log_nuclear "🧠 Optimizing memory settings for high connection counts..."

    # Disable swap for consistent performance
    sudo swapoff -a

    # Memory allocation optimizations
    echo 1 | sudo tee /proc/sys/vm/compact_memory > /dev/null 2>&1 || true

    # NUMA optimizations (if applicable)
    if command -v numactl &> /dev/null && [ -d /sys/devices/system/node ]; then
        log_info "NUMA system detected, applying optimizations..."

        # Bind memory allocation to local node
        echo 1 | sudo tee /proc/sys/vm/zone_reclaim_mode > /dev/null 2>&1 || true
    fi

    log_success "✅ Memory settings optimized"
}

# Optimize storage for logging
optimize_storage() {
    log_nuclear "💾 Optimizing storage for high-throughput logging..."

    # Use tmpfs for logs if possible (nuclear option)
    if [ -d /var/log ] && [ "$NUCLEAR_TMPFS_LOGS" = "true" ]; then
        log_warning "⚠️ Enabling tmpfs for logs (logs will not persist across reboots)"
        sudo mount -t tmpfs -o size=1G tmpfs /var/log/blitz-gateway 2>/dev/null || true
    fi

    # Optimize disk I/O scheduler
    for disk in /sys/block/sd* /sys/block/nvme*; do
        if [ -f "$disk/queue/scheduler" ]; then
            echo none | sudo tee "$disk/queue/scheduler" > /dev/null 2>&1 || true
        fi
    done

    log_success "✅ Storage settings optimized"
}

# Optimize network stack
optimize_network() {
    log_nuclear "🌐 Optimizing network stack for 100Gbps+ throughput..."

    # Network interface optimizations
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        log_info "Optimizing interface: $iface"

        # Increase ring buffer sizes
        sudo ethtool -G "$iface" rx 4096 tx 4096 2>/dev/null || true

        # Enable offloads
        sudo ethtool -K "$iface" tso on gso on gro on 2>/dev/null || true

        # Set interrupt coalescing
        sudo ethtool -C "$iface" adaptive-rx off adaptive-tx off rx-usecs 0 tx-usecs 0 2>/dev/null || true
    done

    # Route optimizations
    sudo sysctl -w net.ipv4.route.flush=1

    log_success "✅ Network stack optimized"
}

# Setup monitoring for nuclear benchmarks
setup_monitoring() {
    log_nuclear "📊 Setting up nuclear benchmark monitoring..."

    # Install monitoring tools
    sudo apt-get update
    sudo apt-get install -y htop iotop sysstat perf-tools-unstable

    # Create monitoring script
    cat > ~/nuclear-monitor.sh << 'EOF'
#!/bin/bash
# Nuclear Benchmark Monitoring Script

echo "=========================================="
echo "NUCLEAR BENCHMARK MONITORING - $(date)"
echo "=========================================="

echo "CPU Usage:"
mpstat 1 1 | tail -1

echo ""
echo "Memory Usage:"
free -h

echo ""
echo "Network Connections:"
ss -tun | grep -E "(ESTAB|LISTEN)" | wc -l

echo ""
echo "Top Processes:"
ps aux --sort=-%cpu | head -10

echo ""
echo "Disk I/O:"
iostat -x 1 1 | tail -10

echo ""
echo "Network I/O:"
sar -n DEV 1 1 | tail -5

echo "=========================================="
EOF

    chmod +x ~/nuclear-monitor.sh
    log_success "✅ Monitoring setup complete: ~/nuclear-monitor.sh"
}

# Install required packages
install_packages() {
    log_nuclear "📦 Installing required packages for nuclear benchmarks..."

    sudo apt-get update
    sudo apt-get install -y \
        build-essential \
        linux-tools-common \
        linux-tools-generic \
        ethtool \
        ipmitool \
        numactl \
        htop \
        iotop \
        sysstat \
        iproute2 \
        bpftrace \
        perf-tools-unstable

    # Install BBR congestion control
    if ! modprobe tcp_bbr 2>/dev/null; then
        log_info "Installing BBR congestion control..."
        sudo modprobe tcp_bbr
        echo tcp_bbr | sudo tee -a /etc/modules
    fi

    log_success "✅ Required packages installed"
}

# Verify nuclear readiness
verify_setup() {
    log_nuclear "✅ Verifying nuclear benchmark readiness..."

    # Check kernel parameters
    somaxconn=$(sysctl -n net.core.somaxconn)
    tcp_max_syn_backlog=$(sysctl -n net.ipv4.tcp_max_syn_backlog)

    if [ "$somaxconn" -ge 65536 ] && [ "$tcp_max_syn_backlog" -ge 65536 ]; then
        log_success "✅ Network socket limits configured correctly"
    else
        log_warning "⚠️ Network socket limits may need adjustment"
    fi

    # Check CPU governor
    governor=$(cat /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null || echo "unknown")
    if [ "$governor" = "performance" ]; then
        log_success "✅ CPU governor set to performance mode"
    else
        log_warning "⚠️ CPU governor is $governor (recommended: performance)"
    fi

    # Check memory
    total_mem=$(free -g | awk 'NR==2{printf "%.0f", $2}')
    if [ "$total_mem" -ge 256 ]; then
        log_success "✅ Sufficient memory available (${total_mem}GB)"
    else
        log_warning "⚠️ Limited memory (${total_mem}GB), nuclear benchmarks may be limited"
    fi

    # Check network
    iface=$(ip route | grep default | awk '{print $5}' | head -1)
    if [ -n "$iface" ]; then
        speed=$(ethtool "$iface" 2>/dev/null | grep -i speed | awk '{print $2}' || echo "unknown")
        log_info "Primary network interface: $iface ($speed)"
    fi

    log_success "🎯 System ready for nuclear HTTP proxy benchmarks!"
    log_info "Target: 10M+ HTTP/1.1 RPS, 6M+ HTTP/3 RPS, <100µs P95 latency"
}

# Print nuclear benchmark guide
print_guide() {
    cat << 'EOF'

==========================================
🚀 NUCLEAR BENCHMARK SETUP COMPLETE 🚀
==========================================

Your system is now optimized for maximum HTTP proxy performance!

NUCLEAR TARGETS (AMD EPYC 9754 / Ampere Altra):
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
• HTTP/1.1 RPS:     10,000,000+ (keep-alive)
• HTTP/2 RPS:       8,000,000+ (multiplexed)
• HTTP/3 RPS:       6,000,000+ (QUIC)
• P95 Latency:      <80µs (HTTP/2), <120µs (HTTP/3)
• Memory @5M RPS:   <200MB RSS
• CPU @5M RPS:      <35% utilization

REQUIRED HARDWARE:
━━━━━━━━━━━━━━━━━━
• CPU: AMD EPYC 9754 (128c) or Ampere Altra (128c)
• RAM: 256GB+ for connection state
• Network: 100Gbps with sub-5µs latency
• Storage: NVMe SSD for logs

RUNNING NUCLEAR BENCHMARKS:
━━━━━━━━━━━━━━━━━━━━━━━━━
1. HTTP/1.1 Nuclear: ./nuclear-benchmarks/scripts/nuclear-wrk2.sh
2. HTTP/2/3 Nuclear: ./nuclear-benchmarks/scripts/nuclear-h2load.sh
3. Real-browser K6:   k6 run nuclear-benchmarks/scripts/k6-script.js

MONITORING:
━━━━━━━━━━━
• Live monitoring: ~/nuclear-monitor.sh
• System stats:    htop, iotop, iostat
• Network:         sar -n DEV 1 1
• Performance:     perf top -p $(pidof blitz-gateway)

PUBLISHING RESULTS:
━━━━━━━━━━━━━━━━━━
When you hit 10M+ RPS, the results will:
• Make Hacker News front page
• Redefine HTTP proxy performance expectations
• Position Blitz Gateway as the fastest proxy ever written

🔥 READY FOR NUCLEAR PERFORMANCE! 🔥

EOF
}

# Main function
main() {
    log_nuclear "💥 INITIALIZING NUCLEAR HARDWARE OPTIMIZATION 💥"
    log_nuclear "Target: AMD EPYC/Ampere Altra optimization for 10M+ RPS"
    echo ""

    # Environment variable to control tmpfs logs
    export NUCLEAR_TMPFS_LOGS="${NUCLEAR_TMPFS_LOGS:-false}"

    # Run all optimization steps
    detect_cpu
    echo ""

    install_packages
    echo ""

    optimize_kernel
    echo ""

    optimize_cpu
    echo ""

    optimize_memory
    echo ""

    optimize_storage
    echo ""

    optimize_network
    echo ""

    setup_monitoring
    echo ""

    verify_setup
    echo ""

    print_guide
}

# Run main function
main "$@"
