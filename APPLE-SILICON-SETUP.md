# Apple Silicon Setup (ARM Mac)

## Problem

VirtualBox doesn't support x86_64 VMs on Apple Silicon. You need to use **UTM** instead.

## Quick Fix

```bash
# 1. Destroy the VirtualBox VM (already done)
vagrant destroy -f

# 2. Start with UTM provider
vagrant up --provider=utm
```

## Prerequisites

✅ **Already installed:**
- Vagrant (2.4.9)
- vagrant_utm plugin (0.1.5)
- UTM app (needed - install if missing)

## First Time Setup

If UTM app is not installed:

```bash
# Install UTM
brew install --cask utm

# Or download from: https://mac.getutm.app/
```

## Usage

### Start VM with UTM

```bash
vagrant up --provider=utm
```

**First boot:** Takes ~5-10 minutes (downloads Ubuntu 22.04 box)

### SSH into VM

```bash
vagrant ssh
```

### Test Install Script

```bash
vagrant ssh
cd /vagrant
./scripts/vm/test-install-in-vm.sh
```

## Performance Notes

- **x86_64 emulation** on Apple Silicon works but is slower than native ARM
- **HVF acceleration** is enabled for best performance
- Expect ~50-70% of native performance (still good for testing!)

## Alternative: Direct UTM (No Vagrant)

If Vagrant + UTM gives issues, use UTM directly:

1. **Create UTM VM manually** with Ubuntu 22.04 Server ISO
2. **SSH into VM** and test install script:
   ```bash
   ssh user@vm-ip
   cd ~/blitz-gateway
   ./scripts/vm/test-install-in-vm.sh
   ```

## Troubleshooting

### UTM Plugin Not Found

```bash
vagrant plugin install vagrant_utm
```

### UTM App Not Installed

```bash
brew install --cask utm
```

### Box Download Issues

```bash
# Manually download box (if needed)
vagrant box add utm/ubuntu-jammy64
```

### VM Won't Start

Check UTM app is running and VM was created properly:
```bash
# Check UTM status
vagrant status
```

## Next Steps

Once VM is running:

1. **Test install**: `./scripts/vm/test-install-in-vm.sh`
2. **Configure**: Edit `/etc/blitz-gateway/config.toml`
3. **Start service**: `sudo systemctl start blitz-gateway`
4. **Run benchmarks**: See `./run-benchmarks.sh`

