# VM Quick Start (5 Minutes)

## Step 1: Install UTM (2 minutes)

```bash
brew install --cask utm
```

Or download: https://mac.getutm.app/

## Step 2: Download Ubuntu 24.04 Server ISO

```bash
cd ~/Downloads
# For Intel Macs:
wget https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso

# For Apple Silicon (M1/M2/M3):
wget https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-arm64.iso
```

## Step 3: Create VM in UTM

1. Open UTM
2. Click **"+"** → **"Virtualize"**
3. Choose **"Linux"**
4. Select your downloaded ISO
5. **Resources** (adjust based on your Mac):
   - **CPU**: 4-8 cores
   - **RAM**: 8-16 GB
   - **Disk**: 40 GB
6. Click **"Save"** and **"Play"**

## Step 4: Install Ubuntu

1. Follow installer (use defaults)
2. **Important**: Choose **"Minimal installation"**
3. Set up user account
4. Reboot when done

## Step 5: Setup Blitz (Copy-paste this)

Once logged into Ubuntu VM:

```bash
# One-command setup (installs everything)
curl -sL https://raw.githubusercontent.com/blitz-gateway/blitz/main/scripts/vm/vm-setup.sh | bash

# Or if you have the repo locally, transfer it first:
# From Mac: scp -r ~/blitz-gateway user@vm-ip:/home/user/
```

## Step 6: Build and Run

```bash
# If you cloned/transferred the repo:
cd blitz-gateway
zig build -Doptimize=ReleaseFast
./zig-out/bin/blitz
```

## Step 7: Benchmark

In another terminal (or SSH session):

```bash
cd blitz-gateway
./scripts/bench/local-benchmark.sh
```

## That's It!

You should see:
- Blitz running on port 8080
- Benchmark results showing RPS and latency
- Everything working! 🎉

**Note**: VM performance will be lower than bare metal (expect 500K-3M RPS depending on your Mac's specs), but it's perfect for testing and development.

---

**Troubleshooting?** See `docs/benchmark/VM-SETUP.md` for detailed guide.

