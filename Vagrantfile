# Vagrant Configuration for Blitz Gateway Nuclear Benchmarking
# Sets up a dedicated Ubuntu VM optimized for HTTP proxy performance testing

Vagrant.configure("2") do |config|
  # Use Ubuntu 22.04 LTS for nuclear benchmarks
  config.vm.box = "ubuntu/jammy64"
  config.vm.box_version = "20230624.0.0"

  # VM Hardware Configuration (scaled for development/testing)
  # In production: AMD EPYC 9754 (128c), 256GB RAM, 100Gbps networking
  
  # VirtualBox provider (if using VirtualBox)
  config.vm.provider "virtualbox" do |vb|
    # CPU and Memory (scaled down for VM but optimized)
    vb.cpus = 8    # 8 cores for development benchmarking
    vb.memory = "16384"  # 16GB RAM

    # Network optimization for high throughput
    vb.customize ["modifyvm", :id, "--nictype1", "virtio"]
    vb.customize ["modifyvm", :id, "--cableconnected1", "on"]

    # CPU optimizations
    vb.customize ["modifyvm", :id, "--cpu-profile", "host"]
    vb.customize ["modifyvm", :id, "--cpuexecutioncap", "100"]
    vb.customize ["modifyvm", :id, "--largepages", "on"]

    # Disable unnecessary features for performance
    vb.customize ["modifyvm", :id, "--usb", "off"]
    vb.customize ["modifyvm", :id, "--audio", "none"]
    vb.customize ["modifyvm", :id, "--clipboard", "disabled"]

    # VM name
    vb.name = "blitz-gateway-nuclear-bench"
  end

  # UTM provider (for macOS - install: vagrant plugin install vagrant_utm)
  config.vm.provider "utm" do |utm|
    utm.memory = 16384  # 16GB RAM
    utm.cpus = 8        # 8 cores
    utm.arch = "x86_64" # x86_64 architecture
    utm.machine_type = "pc"  # PC machine type
    utm.accel = "tcg"   # TCG acceleration (or "hvf" for Apple Silicon)
  end

  # Network configuration
  config.vm.network "private_network", type: "dhcp"

  # Port forwarding for benchmarking (using non-standard host ports to avoid conflicts)
  config.vm.network "forwarded_port", guest: 8080, host: 18080, protocol: "tcp"  # HTTP -> 18080
  config.vm.network "forwarded_port", guest: 8443, host: 18443, protocol: "tcp"  # HTTPS -> 18443
  config.vm.network "forwarded_port", guest: 8443, host: 18443, protocol: "udp"  # QUIC -> 18443
  config.vm.network "forwarded_port", guest: 9090, host: 19090, protocol: "tcp"  # Metrics -> 19090
  config.vm.network "forwarded_port", guest: 3000, host: 13000, protocol: "tcp"  # Grafana -> 13000

  # Shared folder for code and results (works with both VirtualBox and UTM)
  config.vm.synced_folder ".", "/vagrant"

  # VM provisioning script
  config.vm.provision "shell", inline: <<-SHELL
    #!/bin/bash
    set -euo pipefail

    echo "=========================================="
    echo "🚀 BLITZ GATEWAY NUCLEAR BENCHMARK VM"
    echo "=========================================="
    echo "Setting up Ubuntu 22.04 for HTTP proxy nuclear benchmarks"
    echo ""

    # Update system
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y

    # Install essential tools
    apt-get install -y \
        build-essential \
        cmake \
        ninja-build \
        pkg-config \
        git \
        curl \
        wget \
        unzip \
        software-properties-common \
        htop \
        iotop \
        sysstat \
        procps \
        lsof \
        strace \
        perf-tools-unstable \
        linux-tools-generic \
        numactl \
        taskset \
        jq \
        bc \
        time \
        vim \
        tmux \
        screen

    # Install Zig (required for Blitz Gateway)
    echo "📦 Installing Zig 0.15.2..."
    wget -q https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
    tar -xf zig-linux-x86_64-0.15.2.tar.xz -C /opt/
    ln -sf /opt/zig-linux-x86_64-0.15.2/zig /usr/local/bin/zig
    rm zig-linux-x86_64-0.15.2.tar.xz

    # Install nuclear benchmark tools
    echo "🔧 Installing nuclear benchmark tools..."

    # WRK2 - HTTP/1.1 nuclear benchmarking
    echo "Installing WRK2..."
    cd /tmp
    git clone https://github.com/giltene/wrk2.git
    cd wrk2
    make
    cp wrk /usr/local/bin/wrk2
    ln -sf /usr/local/bin/wrk2 /usr/local/bin/wrk

    # nghttp2 (h2load) - HTTP/2 + HTTP/3 benchmarking
    echo "Installing nghttp2..."
    apt-get install -y libssl-dev libev-dev libevent-dev libxml2-dev
    cd /tmp
    git clone https://github.com/nghttp2/nghttp2.git
    cd nghttp2
    git checkout v1.59.0
    autoreconf -i
    ./configure --enable-app --disable-hpack-tools --disable-examples
    make -j$(nproc)
    make install
    ldconfig

    # hey - Golang load tester
    echo "Installing hey..."
    wget -O /usr/local/bin/hey https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
    chmod +x /usr/local/bin/hey

    # bombardier - Alternative load tester
    echo "Installing bombardier..."
    wget -O /tmp/bombardier.tar.gz https://github.com/codesenberg/bombardier/releases/download/v1.2.5/bombardier-linux-amd64.tar.gz
    tar -xzf /tmp/bombardier.tar.gz -C /tmp
    cp /tmp/bombardier-linux-amd64/bombardier /usr/local/bin/
    chmod +x /usr/local/bin/bombardier

    # vegeta - Advanced load testing
    echo "Installing vegeta..."
    wget -O /usr/local/bin/vegeta https://github.com/tsenart/vegeta/releases/download/v12.8.4/vegeta_12.8.4_linux_amd64.tar.gz
    tar -xzf /usr/local/bin/vegeta -C /usr/local/bin/
    chmod +x /usr/local/bin/vegeta

    # k6 with xk6-quic for HTTP/3
    echo "Installing k6 with QUIC support..."
    wget https://github.com/grafana/k6/releases/download/v0.51.0/k6-v0.51.0-linux-amd64.tar.gz
    tar -xzf k6-v0.51.0-linux-amd64.tar.gz
    cp k6-v0.51.0-linux-amd64/k6 /usr/local/bin/k6

    # Install Go for additional tools
    echo "Installing Go..."
    wget -q https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
    tar -C /usr/local -xzf go1.21.5.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    echo 'export PATH=$PATH:/usr/local/go/bin' >> /home/vagrant/.bashrc

    # Nuclear kernel optimizations
    echo "🔧 Applying nuclear kernel optimizations..."

    cat > /etc/sysctl.d/99-nuclear-bench.conf << 'EOF'
# Nuclear HTTP Proxy Kernel Optimizations
# For benchmarking environment (scaled down from production)

# Network socket limits
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 100000

# TCP optimizations
net.ipv4.tcp_max_syn_backlog = 32768
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

# TCP congestion control
net.ipv4.tcp_congestion_control = bbr

# Memory management
net.ipv4.tcp_mem = 393216 524288 786432
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152

# UDP optimizations for QUIC
net.core.rmem_max = 12500000
net.core.wmem_max = 12500000

# File descriptor limits
fs.file-max = 1048576
fs.nr_open = 1048576

# Virtual memory optimizations
vm.swappiness = 10
vm.dirty_ratio = 20
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 1200

# Disable transparent huge pages
vm.nr_hugepages = 0
EOF

    # Apply sysctl settings
    sysctl -p /etc/sysctl.d/99-nuclear-bench.conf

    # CPU governor setup
    cat > /etc/systemd/system/cpu-governor.service << 'EOF'
[Unit]
Description=Set CPU governor to performance
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for governor in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do echo performance > "$governor" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    systemctl enable cpu-governor
    systemctl start cpu-governor

    # Increase file descriptor limits
    cat > /etc/security/limits.d/benchmark.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
* soft nproc 32768
* hard nproc 32768
vagrant soft nofile 1048576
vagrant hard nofile 1048576
EOF

    # Setup Blitz Gateway project
    echo "🚀 Setting up Blitz Gateway project..."
    cd /vagrant

    # Install nfpm for package building
    echo "Installing nfpm for .deb package building..."
    curl -sSfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o /tmp/nfpm.deb
    dpkg -i /tmp/nfpm.deb 2>/dev/null || apt-get install -yf
    rm -f /tmp/nfpm.deb

    # Create results directory
    mkdir -p nuclear-benchmarks/results

    # Setup convenience scripts
    cat > /home/vagrant/run-benchmarks.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "🚀 BLITZ GATEWAY BENCHMARK SUITE"
echo "=========================================="
echo "Available benchmark commands:"
echo ""
echo "1. Basic HTTP benchmark:"
echo "   cd /vagrant && ./scripts/bench/local-benchmark.sh"
echo ""
echo "2. Nuclear WRK2 benchmark:"
echo "   cd /vagrant && ./nuclear-benchmarks/scripts/nuclear-wrk2.sh"
echo ""
echo "3. Nuclear HTTP/2 + HTTP/3 benchmark:"
echo "   cd /vagrant && ./nuclear-benchmarks/scripts/nuclear-h2load.sh"
echo ""
echo "4. Nuclear Docker environment:"
echo "   cd /vagrant/nuclear-benchmarks/docker"
echo "   docker-compose -f docker-compose.nuclear.yml up -d"
echo ""
    echo "5. Build and test server:"
    echo "   cd /vagrant && zig build -Doptimize=ReleaseFast"
    echo "   ./zig-out/bin/blitz"
    echo ""
    echo "6. Test install script:"
    echo "   cd /vagrant && ./scripts/vm/test-install-in-vm.sh"
    echo ""
    echo "=========================================="
EOF

    chmod +x /home/vagrant/run-benchmarks.sh

    # Setup aliases
    cat >> /home/vagrant/.bashrc << 'EOF'

# Blitz Gateway Benchmark Aliases
alias bench='cd /vagrant && ./scripts/bench/local-benchmark.sh'
alias nuclear='cd /vagrant && ./nuclear-benchmarks/scripts/nuclear-wrk2.sh'
alias build='cd /vagrant && zig build -Doptimize=ReleaseFast'
alias server='./zig-out/bin/blitz'
alias monitor='htop'
alias results='ls -la /vagrant/benches/results/ | tail -10'

# Nuclear environment info
echo "=========================================="
echo "🚀 BLITZ GATEWAY NUCLEAR BENCHMARK VM"
echo "=========================================="
echo "VM Specs: $(nproc) cores, $(free -h | awk 'NR==2{print $2}') RAM"
echo "Kernel: $(uname -r)"
echo ""
echo "Quick commands:"
echo "  ./run-benchmarks.sh  # Show all benchmark options"
echo "  bench               # Run basic benchmarks"
echo "  nuclear             # Run nuclear WRK2 benchmarks"
echo "  build              # Build optimized server"
echo "  server             # Start Blitz Gateway"
echo "  monitor            # System monitoring"
echo "  results            # View benchmark results"
echo "=========================================="
EOF

    # Create welcome message
    cat > /etc/motd << 'EOF'

==========================================
🚀 BLITZ GATEWAY NUCLEAR BENCHMARK VM
==========================================

This VM is optimized for HTTP proxy performance testing.

VM Configuration:
- CPU: 8 cores (VirtualBox optimization)
- RAM: 16GB
- Network: VirtIO with optimizations
- Storage: 50GB SSD
- Kernel: Ubuntu 22.04 with nuclear tuning

Available Tools:
- wrk2: HTTP/1.1 nuclear benchmarking
- h2load: HTTP/2 + HTTP/3 benchmarking
- hey: Golang load tester
- bombardier: Fast Go load tester
- k6: Advanced load testing with QUIC
- vegeta: HTTP load testing

Quick Start:
1. cd /vagrant (project directory)
2. ./run-benchmarks.sh (see options)
3. bench (run basic benchmarks)
4. nuclear (run nuclear benchmarks)

Results saved to: /vagrant/benches/results/

==========================================

EOF

    echo ""
    echo "🎯 VM setup complete!"
    echo "Run: vagrant ssh"
    echo "Then: ./run-benchmarks.sh"
    echo ""

  SHELL
end