# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Ubuntu 22.04 LTS ARM64 for Apple Silicon Macs
  # Using generic box that supports multiple providers
  config.vm.box = "generic/ubuntu2204"
  
  # Forward QUIC port (UDP)
  config.vm.network "forwarded_port", guest: 8443, host: 8443, protocol: "udp"
  
  # Forward HTTP/HTTPS for testing (TCP)
  config.vm.network "forwarded_port", guest: 8080, host: 8080
  config.vm.network "forwarded_port", guest: 8443, host: 8444, protocol: "tcp" # HTTPS on different port to avoid conflict
  
  # Sync project directory
  config.vm.synced_folder ".", "/home/vagrant/blitz-gateway"
  
  # Use UTM provider for ARM Macs (you have vagrant_utm plugin installed)
  config.vm.provider "utm" do |utm|
    utm.memory = 4096
    utm.cpus = 4
  end
  
  # Fallback: Parallels (if installed)
  # Install: brew install --cask parallels
  # Plugin: vagrant plugin install vagrant-parallels
  config.vm.provider "parallels" do |prl|
    prl.memory = 4096
    prl.cpus = 4
  end
  
  # Fallback: QEMU/libvirt (if using QEMU)
  config.vm.provider "libvirt" do |libvirt|
    libvirt.memory = 4096
    libvirt.cpus = 4
  end
  
  # Provision: Install dependencies
  config.vm.provision "shell", inline: <<-SHELL
    set -e
    
    echo "🔧 Installing build dependencies..."
    apt-get update
    apt-get install -y \
      curl \
      wget \
      git \
      build-essential \
      libssl-dev \
      liburing-dev \
      pkg-config \
      netcat-openbsd \
      net-tools
    
    echo "🦎 Installing Zig 0.15.2..."
    cd /tmp
    if [ ! -f zig-linux-x86_64-0.15.2.tar.xz ]; then
      wget -q https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
    fi
    tar -xf zig-linux-x86_64-0.15.2.tar.xz
    mkdir -p /usr/local/zig
    mv zig-linux-x86_64-0.15.2/* /usr/local/zig/
    ln -sf /usr/local/zig/zig /usr/local/bin/zig || true
    
    echo "📦 Setting up certificates directory..."
    mkdir -p /home/vagrant/blitz-gateway/certs
    
    echo "✅ Setup complete!"
    echo ""
    echo "Zig version:"
    zig version
    echo ""
    echo "Next steps:"
    echo "  1. vagrant ssh"
    echo "  2. cd /home/vagrant/blitz-gateway"
    echo "  3. zig build"
    echo "  4. sudo ./zig-out/bin/blitz-quic"
  SHELL
end
