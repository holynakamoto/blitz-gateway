# Quick Start: Blitz on x86_64 Linux VM (UTM)

## 🚀 10-Minute Setup

### 1. Download Ubuntu 24.04 x86_64 Image

**Option A: Ready-made (Fastest)**
```bash
# Download from GitHub releases
open https://github.com/kdrag0n/macvm/releases

# Look for: "Ubuntu 24.04 Desktop – x86_64.qcow2"
# Save to: ~/Downloads/
```

**Option B: Official ISO**
```bash
# Download from Ubuntu
open https://ubuntu.com/download/server

# Get: Ubuntu 24.04 LTS Server (x86_64)
```

### 2. Create VM in UTM

1. Open **UTM** app
2. Click **"+"** button
3. Select **"Virtualize"** → **"Linux"**
4. **Boot Image**: Browse and select the `.qcow2` or `.iso` file
5. **Hardware Settings**:
   - **CPU Cores**: 6-8
   - **Memory**: 8-12 GB  
   - **Storage**: 40 GB
   - **Network**: Shared Network (NAT)
6. Click **"Save"** → **"Start"**

### 3. First Boot

- **Username**: `ubuntu`
- **Password**: `ubuntu` (change on first login)

### 4. Setup Blitz (Inside VM)

**Copy the setup script into the VM:**

**Option A: Shared Folder (if configured)**
```bash
# In VM terminal:
cd ~
cp /path/to/shared/blitz-gateway/scripts/vm/setup-utm-x86-vm.sh .
chmod +x setup-utm-x86-vm.sh
./setup-utm-x86-vm.sh
```

**Option B: Manual Copy (via scp from Mac)**
```bash
# From Mac terminal:
cd ~/blitz-gateway
scp scripts/vm/setup-utm-x86-vm.sh ubuntu@<VM_IP>:~/

# Then in VM:
chmod +x setup-utm-x86-vm.sh
./setup-utm-x86-vm.sh
```

**Option C: Manual Setup (if script fails)**
```bash
# Inside VM:
sudo apt update
sudo apt install -y curl git build-essential clang lld libssl-dev pkg-config liburing-dev openssl

# Install Zig
cd /tmp
curl -L https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz -o zig.tar.xz
tar -xf zig.tar.xz
sudo mv zig-linux-x86_64-0.12.0 /usr/local/zig
sudo ln -sf /usr/local/zig/zig /usr/local/bin/zig

# Clone Blitz
cd ~
git clone https://github.com/holynakamoto/blitz-gateway.git blitz
cd blitz

# Generate certs
mkdir -p certs
openssl req -x509 -newkey rsa:4096 \
    -keyout certs/server.key \
    -out certs/server.crt \
    -days 365 -nodes \
    -subj "/CN=localhost"

# Build
zig build -Doptimize=ReleaseFast

# Run
./zig-out/bin/blitz
```

### 5. Test

**From inside VM:**
```bash
# HTTP/1.1
curl http://localhost:8080/hello

# TLS 1.3 + HTTP/2 (once enabled)
curl --insecure --http2 https://localhost:8443/hello -v
```

**From macOS host:**
```bash
# Find VM IP (in VM: ip addr show | grep "inet ")
# Then from Mac:
curl --insecure --http2 https://<VM_IP>:8443/hello -v
```

## ✅ Expected Results

- ✅ Build completes without errors
- ✅ Server starts on port 8080 (HTTP/1.1)
- ✅ TLS certificates generated
- ✅ Ready for TLS/HTTP/2 testing

## 🎯 Next Steps

1. Enable TLS in `src/io_uring.zig` (uncomment TLS code)
2. Test TLS 1.3 handshake
3. Test HTTP/2 negotiation
4. Run benchmarks

## 📊 Performance Targets (x86_64 VM)

- **HTTP/1.1**: 400K-800K RPS
- **TLS 1.3 + HTTP/2**: 200K-500K RPS  
- **p99 Latency**: <80 µs

Perfect for development! 🚀

