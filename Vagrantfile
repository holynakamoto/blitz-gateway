# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Detect host architecture
  host_arch = `uname -m`.strip
  
  if host_arch == "arm64"
    # ============================================
    # Apple Silicon Configuration (UTM)
    # ============================================
    
    # Use UTM box (Debian-based, but we'll work with it)
    # Note: UTM boxes are limited - using bookworm which works
    config.vm.box = "utm/bookworm"
    config.vm.hostname = "zig-blitz-dev"
    
    # UTM provider configuration
    config.vm.provider "utm" do |utm|
      utm.memory = 4096
      utm.cpus = 4
    end
    
    # Network configuration
    config.vm.network "forwarded_port", guest: 3000, host: 3000
    config.vm.network "private_network", ip: "192.168.56.10"
    
  else
    # ============================================
    # Intel Mac/x86_64 Configuration (VirtualBox)
    # ============================================
    
    config.vm.box = "ubuntu/jammy64"
    config.vm.hostname = "zig-blitz-dev"
    
    config.vm.provider "virtualbox" do |vb|
      vb.name = "blitz-benchmark"
      vb.memory = "4096"
      vb.cpus = 4
      
      # Enable better performance
      vb.customize ["modifyvm", :id, "--natdnshostresolver1", "on"]
      vb.customize ["modifyvm", :id, "--natdnsproxy1", "on"]
    end
    
    # Network configuration
    config.vm.network "forwarded_port", guest: 3000, host: 3000
    config.vm.network "private_network", type: "dhcp"
  end
  
  # Synced folder - works for both providers
  config.vm.synced_folder ".", "/vagrant"
  
  # ============================================
  # System Provisioning
  # ============================================
  
  config.vm.provision "shell", inline: <<-SHELL
    set -e  # Exit on error
    
    echo "================================================"
    echo "🚀 Starting Blitz Development Environment Setup"
    echo "================================================"
    
    # Update system packages
    echo "📦 Updating system packages..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get upgrade -y -qq
    
    # Install build dependencies
    echo "🔧 Installing build dependencies..."
    apt-get install -y -qq \
      build-essential \
      git \
      curl \
      wget \
      ca-certificates \
      xz-utils \
      liburing-dev \
      pkg-config \
      htop \
      vim \
      net-tools
    
    # Detect architecture for Zig
    ARCH=$(uname -m)
    case "$ARCH" in
      x86_64)
        ZIG_ARCH="x86_64"
        ;;
      aarch64|arm64)
        ZIG_ARCH="aarch64"
        ;;
      *)
        echo "❌ Unsupported architecture: $ARCH"
        exit 1
        ;;
    esac
    
    echo "🎯 Detected architecture: $ARCH (Zig: $ZIG_ARCH)"
    
    # Install Zig 0.13.0
    ZIG_VERSION="0.13.0"
    ZIG_DIR="/usr/local/zig"
    
    echo "⚡ Installing Zig ${ZIG_VERSION} for ${ZIG_ARCH}..."
    
    cd /tmp
    
    # Download Zig with verbose output
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
    echo "📥 Downloading from: $ZIG_URL"
    
    if ! wget -q --show-progress "$ZIG_URL" -O zig.tar.xz; then
      echo "❌ Failed to download Zig. Trying alternate method..."
      curl -L "$ZIG_URL" -o zig.tar.xz || {
        echo "❌ Download failed completely"
        exit 1
      }
    fi
    
    # Verify download
    if [ ! -f zig.tar.xz ]; then
      echo "❌ Zig archive not found after download"
      exit 1
    fi
    
    echo "📦 Extracting Zig..."
    tar -xf zig.tar.xz || {
      echo "❌ Failed to extract Zig archive"
      exit 1
    }
    
    # Remove old installation if exists
    rm -rf "$ZIG_DIR"
    
    # Move Zig to /usr/local
    mv "zig-linux-${ZIG_ARCH}-${ZIG_VERSION}" "$ZIG_DIR"
    
    # Create symlink
    ln -sf "${ZIG_DIR}/zig" /usr/local/bin/zig
    
    # Cleanup
    rm -f zig.tar.xz
    
    # Verify Zig installation
    if ! /usr/local/bin/zig version; then
      echo "❌ Zig installation verification failed"
      exit 1
    fi
    
    echo "✅ Zig installed successfully: $(/usr/local/bin/zig version)"
    
    # Install wrk2 for benchmarking
    echo "📊 Installing wrk2..."
    cd /tmp
    
    if [ -d wrk2 ]; then
      rm -rf wrk2
    fi
    
    git clone --quiet https://github.com/giltene/wrk2.git
    cd wrk2
    make -j$(nproc) > /dev/null 2>&1
    cp wrk /usr/local/bin/wrk2
    cd /tmp
    rm -rf wrk2
    
    echo "✅ wrk2 installed successfully"
    
    # System tuning for high-performance networking
    echo "⚙️  Applying system tuning..."
    
    # Network tuning
    sysctl -w net.core.somaxconn=65535 2>/dev/null || true
    sysctl -w net.ipv4.tcp_max_syn_backlog=65535 2>/dev/null || true
    sysctl -w net.core.netdev_max_backlog=65535 2>/dev/null || true
    sysctl -w net.ipv4.ip_local_port_range="1024 65535" 2>/dev/null || true
    
    # File descriptor limits
    cat >> /etc/security/limits.conf <<EOF
* soft nofile 65535
* hard nofile 65535
vagrant soft nofile 65535
vagrant hard nofile 65535
EOF
    
    # Make tuning persistent
    cat >> /etc/sysctl.conf <<EOF

# Blitz performance tuning
net.core.somaxconn=65535
net.ipv4.tcp_max_syn_backlog=65535
net.core.netdev_max_backlog=65535
net.ipv4.ip_local_port_range=1024 65535
EOF
    
    echo "✅ System tuning applied"
    
    # Setup environment for vagrant user
    echo "🎨 Configuring user environment..."
    
    cat >> /home/vagrant/.bashrc <<'BASHRC_EOF'

# Zig environment
export PATH="/usr/local/zig:$PATH"

# Helpful aliases
alias zbuild='zig build'
alias zrun='zig build run'
alias ztest='zig build test'
alias zclean='rm -rf zig-cache zig-out'
alias zrelease='zig build -Doptimize=ReleaseFast'

# Project aliases
alias cdp='cd /vagrant'
alias bench='wrk2 -t4 -c100 -d30s -R2000'

BASHRC_EOF
    
    chown vagrant:vagrant /home/vagrant/.bashrc
    
    # Create a test script
    cat > /home/vagrant/test-zig.sh <<'TEST_EOF'
#!/bin/bash
echo "Testing Zig installation..."
echo "Zig version: $(zig version)"
echo "Zig location: $(which zig)"
echo ""
echo "Creating test program..."
cat > /tmp/test.zig <<'ZIG_EOF'
const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("✅ Zig is working correctly!\n", .{});
}
ZIG_EOF

echo "Compiling test program..."
zig build-exe /tmp/test.zig -femit-bin=/tmp/test

echo "Running test program..."
/tmp/test

echo ""
echo "✅ Zig installation is working!"
rm -f /tmp/test.zig /tmp/test
TEST_EOF
    
    chmod +x /home/vagrant/test-zig.sh
    chown vagrant:vagrant /home/vagrant/test-zig.sh
    
    echo ""
    echo "================================================"
    echo "✨ Setup Complete!"
    echo "================================================"
    echo ""
    echo "System Information:"
    echo "  • OS: $(lsb_release -d | cut -f2)"
    echo "  • Architecture: $ARCH"
    echo "  • Zig: $(/usr/local/bin/zig version)"
    echo "  • liburing: $(pkg-config --modversion liburing 2>/dev/null || echo 'installed')"
    echo "  • wrk2: $(wrk2 --version 2>&1 | head -n1 || echo 'installed')"
    echo ""
    echo "Network:"
    if [ -n "$(ip addr show | grep '192.168.56.10')" ]; then
      echo "  • Private IP: 192.168.56.10"
    fi
    echo "  • Port forwarding: 3000 (guest) → 3000 (host)"
    echo ""
    echo "Next Steps:"
    echo "  1. vagrant ssh"
    echo "  2. cd /vagrant"
    echo "  3. ./test-zig.sh    # Test Zig installation"
    echo "  4. zig build -Doptimize=ReleaseFast"
    echo "  5. ./zig-out/bin/blitz"
    echo ""
    echo "Aliases available:"
    echo "  • zbuild, zrun, ztest, zclean, zrelease"
    echo "  • cdp (cd to project), bench (run benchmark)"
    echo ""
  SHELL
  
  # User-level provisioning (runs as vagrant user)
  config.vm.provision "shell", privileged: false, inline: <<-SHELL
    echo "👤 Setting up user environment..."
    
    # Test Zig installation
    if zig version > /dev/null 2>&1; then
      echo "✅ Zig is accessible in user environment"
    else
      echo "⚠️  Zig not in PATH yet - will be available after re-login"
    fi
  SHELL
  
  # Post-up message
  config.vm.post_up_message = <<-MESSAGE
  
  ╔══════════════════════════════════════════════════════════╗
  ║                                                          ║
  ║   🚀 Blitz Development Environment Ready!               ║
  ║                                                          ║
  ║   Run: vagrant ssh                                      ║
  ║   Then: cd /vagrant && ./test-zig.sh                   ║
  ║                                                          ║
  ╚══════════════════════════════════════════════════════════╝
  
  MESSAGE
end