# Setting Up Linux VM on macOS for Blitz Benchmarks

## Quick Start (Choose One)

### Option 1: UTM (Recommended - Free, Easy, Native Apple Silicon Support)

**Best for**: M1/M2/M3 Macs, easiest setup

1. **Install UTM**:
   ```bash
   brew install --cask utm
   ```
   Or download from: https://mac.getutm.app/

2. **Download Ubuntu 24.04 LTS Server ISO**:
   ```bash
   cd ~/Downloads
   wget https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso
   ```
   Or for Apple Silicon: `ubuntu-24.04-live-server-arm64.iso`

3. **Create VM in UTM**:
   - Open UTM
   - Click "+" → "Virtualize"
   - Choose "Linux"
   - Select your downloaded ISO
   - Allocate resources:
     - **CPU**: 4-8 cores (use half your Mac's cores)
     - **RAM**: 8-16 GB (use 1/4 to 1/2 of your Mac's RAM)
     - **Disk**: 40 GB (enough for Ubuntu + Blitz + benchmarks)
   - Enable "Hardware OpenGL" for better performance
   - Click "Save" and start VM

4. **Install Ubuntu**:
   - Follow installer (use defaults, set up user account)
   - **Important**: Choose "Minimal installation" when prompted
   - Reboot when done

### Option 2: Parallels Desktop (If You Have It)

**Best for**: Best performance, but costs money

1. **Create New VM**:
   - File → New
   - Choose "Install Windows, Linux, or another OS"
   - Select Ubuntu 24.04 ISO
   - Allocate: 4-8 cores, 8-16 GB RAM, 40 GB disk
   - Start installation

2. **Install Ubuntu** (same as UTM)

### Option 3: VirtualBox (Free, Cross-Platform)

**Best for**: Intel Macs, or if UTM doesn't work

1. **Install VirtualBox**:
   ```bash
   brew install --cask virtualbox
   ```

2. **Download Ubuntu ISO** (same as UTM)

3. **Create VM**:
   - New → Name: "Blitz Benchmark"
   - Type: Linux, Version: Ubuntu (64-bit)
   - Memory: 8192 MB (8 GB)
   - Create virtual disk: 40 GB, VDI, Dynamically allocated
   - Settings → System → Processor: 4-8 CPUs
   - Settings → Storage → Add Ubuntu ISO
   - Start VM

4. **Install Ubuntu** (same as UTM)

## Post-Installation Setup

Once Ubuntu is installed and you've logged in:

### 1. Update System

```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Install Dependencies

```bash
# Install Zig
wget https://ziglang.org/download/0.12.0/zig-linux-$(uname -m)-0.12.0.tar.xz
tar -xf zig-linux-*-0.12.0.tar.xz
sudo mv zig-linux-*-0.12.0 /opt/zig
echo 'export PATH="/opt/zig:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Install liburing
sudo apt install -y liburing-dev build-essential git curl

# Verify
zig version
pkg-config --modversion liburing
```

### 3. Clone and Build Blitz

```bash
# If you have the repo locally, you can SCP it over, or clone from GitHub
git clone https://github.com/blitz-gateway/blitz.git
cd blitz

# Build
zig build -Doptimize=ReleaseFast

# Test
./zig-out/bin/blitz
```

### 4. Run System Optimization (Optional but Recommended)

```bash
# Apply system tuning for better performance
sudo ./scripts/bench/bench-box-setup.sh
# Note: This will reboot the VM once for kernel upgrade
```

### 5. Run Benchmarks

```bash
# Install wrk2
cd /tmp
git clone https://github.com/giltene/wrk2.git
cd wrk2
make
sudo cp wrk /usr/local/bin/wrk2

# Run benchmarks
cd ~/blitz
./scripts/bench/local-benchmark.sh
```

## Transferring Files from Mac to VM

### Option 1: SCP (Command Line)

```bash
# From your Mac terminal
scp -r /Users/nickmoore/blitz-gateway user@vm-ip:/home/user/
```

### Option 2: Shared Folder (UTM/Parallels)

**UTM**:
- VM Settings → Sharing → Enable "Directory Sharing"
- Select a folder on your Mac
- In VM: `sudo mount -t 9p -o trans=virtio,version=9p2000.L share /mnt`

**Parallels**:
- VM → Configure → Options → Sharing
- Enable "Share Mac" folders
- Access via `/media/psf/` in VM

### Option 3: Git (Easiest)

```bash
# In VM
git clone https://github.com/your-username/blitz-gateway.git
# Or if private, use SSH keys
```

## VM Performance Tips

1. **Allocate enough resources**:
   - Minimum: 4 cores, 8 GB RAM
   - Recommended: 8 cores, 16 GB RAM (if your Mac has it)

2. **Enable hardware acceleration**:
   - UTM: Enable "Hardware OpenGL"
   - VirtualBox: Settings → Display → Enable 3D Acceleration

3. **Disable unnecessary services**:
   ```bash
   sudo systemctl disable snapd apparmor
   ```

4. **Use bridged networking** (for better network performance):
   - UTM: Settings → Network → Mode: "Bridged"
   - This gives VM direct network access

## Expected Performance in VM

**Note**: VMs have overhead, so expect lower numbers than bare metal:

- **4-core VM**: 500K - 1.5M RPS
- **8-core VM**: 1M - 3M RPS
- **16-core VM**: 2M - 5M RPS

This is still great for:
- ✅ Testing the code works
- ✅ Verifying benchmarks run
- ✅ Development iteration
- ✅ Learning the process

For production benchmarks (12M+ RPS), you'll need bare metal, but the VM is perfect for now!

## Troubleshooting

**VM is slow**:
- Increase allocated RAM/CPU
- Disable unnecessary macOS apps
- Close other VMs

**Can't connect to VM**:
- Check VM IP: `ip addr` in VM
- Use bridged networking mode
- Check macOS firewall

**Build fails**:
- Ensure liburing is installed: `sudo apt install liburing-dev`
- Check Zig version: `zig version` (should be 0.12.0+)
- Verify kernel: `uname -r` (should be 5.15+)

**Low benchmark numbers**:
- This is normal in VMs (overhead)
- Focus on verifying it works, not absolute numbers
- Real benchmarks need bare metal

## Next Steps

1. ✅ Set up VM
2. ✅ Install dependencies
3. ✅ Build Blitz
4. ✅ Run benchmarks
5. ✅ Verify everything works
6. 🎯 When ready for production numbers, get bare metal server

---

**Ready to start?** Pick UTM (easiest) and follow the steps above!

