# Blitz Gateway Packaging

Professional one-command install system for Ubuntu 22.04 / 24.04.

## Package Structure

```
packaging/
├── systemd/
│   └── blitz-gateway.service    # Systemd service unit
├── config/
│   └── blitz-gateway.toml       # Default configuration
├── scripts/
│   ├── preinstall.sh            # Pre-installation setup
│   ├── postinstall.sh           # Post-installation configuration
│   ├── preremove.sh             # Pre-removal cleanup
│   └── postremove.sh            # Post-removal cleanup
└── build-deb.sh                 # Local build script
```

## Building Locally

```bash
# Build optimized binary first
zig build run-quic -Doptimize=ReleaseFast

# Build .deb package
./packaging/build-deb.sh 0.6.0

# Install locally
sudo dpkg -i dist/blitz-gateway_0.6.0_amd64.deb
```

## Installation

### For Users

**One-command install:**
```bash
curl -fsSL https://raw.githubusercontent.com/holynakamoto/blitz-gateway/main/install.sh | sudo bash
```

**After installation:**
```bash
# Edit configuration
sudo nano /etc/blitz-gateway/config.toml

# Start service
sudo systemctl start blitz-gateway

# Enable auto-start on boot
sudo systemctl enable blitz-gateway

# Check status
sudo systemctl status blitz-gateway

# View logs
sudo journalctl -u blitz-gateway -f
```

## Automated Releases

When you push a git tag (e.g., `v0.6.0`), GitHub Actions automatically:
1. Builds the optimized binary
2. Creates a `.deb` package using `nfpm`
3. Publishes to GitHub Releases
4. (Optional) Publishes to PackageCloud

## Package Details

- **Binary**: `/usr/bin/blitz-gateway`
- **Configuration**: `/etc/blitz-gateway/config.toml`
- **Data**: `/var/lib/blitz-gateway`
- **Logs**: `/var/log/blitz-gateway`
- **User**: `blitz-gateway` (system user)
- **Service**: `systemctl start blitz-gateway`

## Dependencies

- `liburing2` (>= 2.0) - io_uring support
- `libssl3` (>= 3.0) - TLS/SSL support
- `libc6` (>= 2.35) - Standard C library

## System Requirements

- Ubuntu 22.04 LTS or 24.04 LTS
- Linux kernel 5.15+ (for io_uring)
- x86_64 architecture

