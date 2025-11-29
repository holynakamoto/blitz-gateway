# VM Status Check

Run this command to check if VM is ready:

```bash
# Check if image is downloaded
ls -lh ~/Downloads/*.qcow2 ~/Downloads/*ubuntu*.iso 2>/dev/null

# Check if UTM is running
ps aux | grep -i utm | grep -v grep

# Once VM is running, you can SSH into it (if network configured)
# Or use UTM's built-in terminal
```

## Quick Setup Commands (Inside VM)

Once VM is booted and you're logged in:

```bash
# 1. Update system
sudo apt update

# 2. Install dependencies
sudo apt install -y curl git build-essential clang lld libssl-dev pkg-config liburing-dev openssl

# 3. Install Zig
cd /tmp
curl -L https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz -o zig.tar.xz
tar -xf zig.tar.xz
sudo mv zig-linux-x86_64-0.12.0 /usr/local/zig
sudo ln -sf /usr/local/zig/zig /usr/local/bin/zig

# 4. Clone Blitz
cd ~
git clone https://github.com/holynakamoto/blitz-gateway.git blitz
cd blitz

# 5. Generate certs
mkdir -p certs
openssl req -x509 -newkey rsa:4096 \
    -keyout certs/server.key \
    -out certs/server.crt \
    -days 365 -nodes \
    -subj "/CN=localhost"

# 6. Build
zig build -Doptimize=ReleaseFast

# 7. Run
./zig-out/bin/blitz
```

