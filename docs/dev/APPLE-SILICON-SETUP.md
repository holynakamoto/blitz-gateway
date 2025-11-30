# Apple Silicon Setup (ARM Mac)

## Problem

VirtualBox doesn't support x86_64 VMs on Apple Silicon. Also, standard Vagrant boxes don't have UTM provider support.

## ✅ Recommended Solution: UTM Direct

Use UTM directly (no Vagrant needed) - it's actually simpler and more reliable!

**See: [UTM-DIRECT-SETUP.md](UTM-DIRECT-SETUP.md)** for step-by-step guide.

Quick workflow:
1. Create VM in UTM GUI
2. Install Ubuntu 22.04
3. Copy project to VM
4. Test install script

## Alternative: Vagrant with UTM (if boxes available)

If you want to use Vagrant, you'll need to find or create a UTM-compatible box.

**Prerequisites:**
- Vagrant (2.4.9) ✅
- vagrant_utm plugin (0.1.5) ✅
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

