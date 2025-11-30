# Vagrant Guide for QUIC Testing

## Overview

This guide explains how to use Vagrant to test the QUIC implementation on Linux while developing on macOS.

## Why Vagrant?

- **Develop on macOS** with your preferred tools
- **Test on Linux** with io_uring support
- **Auto-sync code** via shared folders
- **Reproducible** environment for testing

## Prerequisites

### Install Vagrant

**macOS:**
```bash
brew install vagrant virtualbox
```

**Or download:**
- [Vagrant](https://www.vagrantup.com/downloads)
- [VirtualBox](https://www.virtualbox.org/wiki/Downloads)

### Verify Installation

```bash
vagrant --version
vboxmanage --version
```

## Quick Start

### 1. Start Vagrant VM

```bash
# In blitz-gateway directory
vagrant up
```

**First time**: ~5 minutes (downloads Ubuntu, installs dependencies)
**Subsequent**: ~30 seconds

### 2. SSH into VM

```bash
vagrant ssh
```

### 3. Navigate to Project

```bash
cd /home/vagrant/blitz-gateway
```

### 4. Build and Test

```bash
# Build QUIC server
zig build

# Run tests
zig build test-transport-params
zig build test-quic-frames
zig build test-quic-packet-gen

# Run QUIC server
sudo ./zig-out/bin/blitz-quic
```

### 5. Test from macOS

In another terminal (on your Mac):

```bash
# Test UDP connectivity
nc -u localhost 8443

# Test HTTP/3 (when ready)
curl --http3-only -k https://localhost:8443/hello
```

## Development Workflow

### Option 1: Edit on macOS, Test in VM

**On macOS:**
```bash
# Edit code in your editor
vim src/quic/handshake.zig

# Run unit tests (fast, no VM needed)
zig build test
```

**In VM:**
```bash
vagrant ssh
cd /home/vagrant/blitz-gateway

# Code automatically synced!
zig build
sudo ./zig-out/bin/blitz-quic
```

### Option 2: Auto-rebuild in VM

**In VM terminal (leave open):**
```bash
vagrant ssh
cd /home/vagrant/blitz-gateway

# Watch for changes and rebuild
while true; do
  inotifywait -e modify -r src/ 2>/dev/null && \
  zig build && \
  echo "✅ Rebuilt at $(date)"
done
```

**On macOS:**
- Edit code
- Save file
- VM auto-rebuilds
- Test immediately

## Port Forwarding

The Vagrantfile forwards:
- **UDP 8443** (QUIC) → `localhost:8443` on macOS
- **TCP 8080** (HTTP) → `localhost:8080` on macOS
- **TCP 8444** (HTTPS) → `localhost:8444` on macOS (to avoid conflict)

Test from macOS:
```bash
curl --http3-only -k https://localhost:8443/hello
```

## Common Commands

### VM Management

```bash
# Start VM
vagrant up

# SSH into VM
vagrant ssh

# Suspend VM (saves state, fast resume)
vagrant suspend

# Resume VM
vagrant resume

# Restart VM
vagrant reload

# Destroy VM (clean slate)
vagrant destroy

# Check VM status
vagrant status
```

### Running Commands in VM

```bash
# Run command without SSH
vagrant ssh -c "cd blitz-gateway && zig build test"

# Run test script
vagrant ssh -c "cd blitz-gateway && ./scripts/docker/test-quic.sh"
```

## Testing Workflow

### 1. Unit Tests (macOS)

```bash
# Fast iteration on macOS
zig build test-transport-params
zig build test-quic-frames
zig build test-quic-packet-gen
```

### 2. Integration Tests (VM)

```bash
vagrant ssh
cd /home/vagrant/blitz-gateway

# Run test script
./scripts/docker/test-quic.sh
```

### 3. Manual Testing

**In VM:**
```bash
# Start server
sudo ./zig-out/bin/blitz-quic
```

**On macOS:**
```bash
# Test with curl
curl --http3-only -k https://localhost:8443/hello
```

## Troubleshooting

### VM Won't Start

```bash
# Check VirtualBox is running
ps aux | grep VirtualBox

# Check Vagrant status
vagrant status

# Destroy and recreate
vagrant destroy
vagrant up
```

### Port Already in Use

```bash
# Check what's using port 8443
lsof -i :8443

# Kill process or change port in Vagrantfile
```

### Code Not Syncing

```bash
# Check shared folder
vagrant ssh
ls -la /home/vagrant/blitz-gateway

# Reload VM
vagrant reload
```

### Build Fails in VM

```bash
# Check Zig is installed
vagrant ssh -c "zig version"

# Re-provision
vagrant provision
```

## Performance Testing

### Release Build

```bash
vagrant ssh
cd /home/vagrant/blitz-gateway

# Build optimized
zig build -Doptimize=ReleaseFast

# Run server
sudo ./zig-out/bin/blitz-quic
```

### Benchmark from macOS

```bash
# Install wrk2
brew install wrk2

# Benchmark QUIC (when HTTP/3 is ready)
wrk2 -t4 -c100 -d30s -R100000 https://localhost:8443/hello
```

## File Structure

```
blitz-gateway/
├── Vagrantfile              # VM configuration
├── .vagrant/                # Vagrant metadata (gitignore)
├── src/                     # Source code (synced)
├── scripts/
│   └── test-quic.sh         # Test script (works in VM)
└── certs/                   # TLS certificates (synced)
```

## Next Steps

1. **Start VM**: `vagrant up`
2. **SSH in**: `vagrant ssh`
3. **Build**: `cd /home/vagrant/blitz-gateway && zig build`
4. **Test**: `./scripts/docker/test-quic.sh`
5. **Develop**: Edit on macOS, test in VM

## Tips

- **Keep VM suspended** when not testing (fast resume)
- **Use shared folders** for code (auto-sync)
- **Run unit tests on macOS** (faster iteration)
- **Run integration tests in VM** (Linux required)
- **Use `vagrant reload`** if networking issues

## Resources

- [Vagrant Documentation](https://www.vagrantup.com/docs)
- [VirtualBox Documentation](https://www.virtualbox.org/manual/)
- [Zig Documentation](https://ziglang.org/documentation/)

