# Testing Blitz Gateway Install Script

## Quick Test in Vagrant VM

### Option 1: Vagrant (Recommended)

```bash
# Start VM (uses Ubuntu 22.04)
vagrant up

# SSH into VM
vagrant ssh

# Test the install
cd /vagrant
./scripts/vm/test-install-in-vm.sh
```

This will:
1. Build the optimized binary
2. Create a .deb package
3. Install it using the package system
4. Verify all components are working

### Option 2: UTM VM

If you have a UTM VM running Ubuntu 22.04 or 24.04:

```bash
# From your Mac, copy the repo to the VM
scp -r ~/blitz-gateway user@vm-ip:/home/user/

# SSH into VM
ssh user@vm-ip

# Run test script
cd ~/blitz-gateway
./scripts/vm/test-install-in-vm.sh
```

### Option 3: Test the Real Install Script

To test the actual install script (downloads from GitHub Releases):

```bash
# In VM, create a test release version
cd /vagrant
VERSION="0.6.0"

# Build and create .deb
./packaging/build-deb.sh "$VERSION"

# Copy .deb to a location where install.sh can find it
# (for testing, you can modify install.sh to use local file)

# Or test with local file modification:
# Temporarily modify install.sh to use local .deb file
```

## Manual Test Steps

### 1. Build the Package

```bash
cd /vagrant
./packaging/build-deb.sh 0.6.0
```

### 2. Install the Package

```bash
# Install dependencies if needed
sudo apt-get install -y liburing2 libssl3

# Install the .deb
sudo dpkg -i dist/blitz-gateway_0.6.0_amd64.deb
```

### 3. Verify Installation

```bash
# Check binary
/usr/bin/blitz-gateway --help

# Check config
ls -la /etc/blitz-gateway/config.toml

# Check user
id blitz-gateway

# Check service
systemctl status blitz-gateway
```

### 4. Configure and Start

```bash
# Edit configuration
sudo nano /etc/blitz-gateway/config.toml

# Start service
sudo systemctl start blitz-gateway

# Check status
sudo systemctl status blitz-gateway

# View logs
sudo journalctl -u blitz-gateway -f
```

## Testing the Install Script End-to-End

To test the actual `install.sh` script that users would run:

### 1. Create a Test GitHub Release

```bash
# Tag a test version
git tag v0.6.0-test
git push origin v0.6.0-test

# GitHub Actions will build and publish .deb to releases
```

### 2. Test Install Script

```bash
# In VM
curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash
```

### 3. Or Test with Local Modifications

For local testing, you can modify `install.sh` to use a local .deb file:

```bash
# Modify install.sh to point to local file instead of GitHub Releases
# Then test:
sudo bash install.sh
```

## Expected Results

After successful installation, you should see:

- ✅ Binary at `/usr/bin/blitz-gateway`
- ✅ Config at `/etc/blitz-gateway/config.toml`
- ✅ System user `blitz-gateway` created
- ✅ Systemd service installed and enabled
- ✅ Directories created:
  - `/var/lib/blitz-gateway`
  - `/var/log/blitz-gateway`
- ✅ Service can start (may need TLS certs for full functionality)

## Troubleshooting

### Binary Not Found

```bash
# Check if binary was built
ls -la zig-out/bin/blitz-quic

# Rebuild if needed
zig build run-quic -Doptimize=ReleaseFast
```

### Package Build Fails

```bash
# Install nfpm
curl -sSfL https://github.com/goreleaser/nfpm/releases/latest/download/nfpm_amd64.deb -o /tmp/nfpm.deb
sudo dpkg -i /tmp/nfpm.deb
```

### Service Won't Start

```bash
# Check logs
sudo journalctl -u blitz-gateway -n 50

# Check config syntax
sudo blitz-gateway --help

# Verify TLS certs (if using HTTPS/QUIC)
ls -la /etc/blitz-gateway/*.crt /etc/blitz-gateway/*.key
```

## Next Steps

Once install is verified:

1. **Push a real release tag** (e.g., `v0.6.0`)
2. **GitHub Actions will auto-build** and publish .deb
3. **Users can install** with one command:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash
   ```

