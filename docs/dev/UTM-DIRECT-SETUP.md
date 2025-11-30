# UTM Direct Setup (Recommended for Apple Silicon)

Since Vagrant UTM boxes aren't widely available, let's use UTM directly - it's actually simpler!

## 🚀 Quick Setup (15 minutes)

### Step 1: Install UTM (if needed)

```bash
brew install --cask utm
```

Or download from: https://mac.getutm.app/

### Step 2: Download Ubuntu 22.04 Server ISO

```bash
cd ~/Downloads
curl -L -o ubuntu-22.04-server-amd64.iso \
  https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso
```

### Step 3: Create VM in UTM

1. Open **UTM** app
2. Click **"+"** → **"Virtualize"** → **"Linux"**
3. **Boot Image**: Select the downloaded ISO file
4. **Hardware**:
   - **CPU Cores**: 4-8
   - **Memory**: 8-16 GB
   - **Storage**: 50 GB
   - **Network**: Shared Network (NAT)
5. Click **"Save"** → **"Start"**

### Step 4: Install Ubuntu

1. Follow the installer
2. **Important**: Choose **"Minimal installation"**
3. Set up user account (remember username/password!)
4. Enable SSH server when prompted
5. Reboot when done

### Step 5: Get VM IP Address

```bash
# In VM terminal (after login):
ip addr show | grep "inet " | grep -v 127.0.0.1

# Or check in UTM: VM → Network → IP Address
```

### Step 6: Copy Project to VM

```bash
# From your Mac terminal:
VM_IP="<VM_IP_ADDRESS>"  # Replace with actual IP
VM_USER="<VM_USERNAME>"  # Replace with your username

# Copy the entire project
scp -r ~/blitz-gateway ${VM_USER}@${VM_IP}:~/

# Or just the install test script
scp -r ~/blitz-gateway/packaging ${VM_USER}@${VM_IP}:~/blitz-gateway/
scp -r ~/blitz-gateway/scripts ${VM_USER}@${VM_IP}:~/blitz-gateway/
scp ~/blitz-gateway/install.sh ${VM_USER}@${VM_IP}:~/blitz-gateway/
scp -r ~/blitz-gateway/packaging ${VM_USER}@${VM_IP}:~/blitz-gateway/
scp ~/blitz-gateway/build.zig ${VM_USER}@${VM_IP}:~/blitz-gateway/
```

### Step 7: SSH and Test

```bash
# SSH into VM
ssh ${VM_USER}@${VM_IP}

# Test install script
cd ~/blitz-gateway
./scripts/vm/test-install-in-vm.sh
```

## ✅ What Gets Tested

- ✅ Builds optimized binary
- ✅ Creates .deb package
- ✅ Installs package
- ✅ Verifies binary, config, user, service
- ✅ Shows next steps

## 📋 Alternative: Use Shared Folder

If you want the repo synced automatically:

1. **In UTM VM settings**:
   - Add Shared Directory pointing to your project folder
   - Mount point: `/mnt/shared`

2. **In VM**:
   ```bash
   # Copy from shared folder
   cp -r /mnt/shared/blitz-gateway ~/
   cd ~/blitz-gateway
   ./scripts/vm/test-install-in-vm.sh
   ```

## 🎯 Quick Commands

```bash
# Find VM IP
vm_ip=$(vmctl ip-address "VM_NAME" 2>/dev/null || echo "Check UTM GUI")

# Copy project
scp -r ~/blitz-gateway user@${vm_ip}:~/

# SSH in
ssh user@${vm_ip}
```

## 🐛 Troubleshooting

### Can't Find VM IP

Check in UTM app: Select VM → Network tab → IP Address

### SSH Connection Refused

1. Ensure SSH server is installed in VM:
   ```bash
   sudo apt install openssh-server
   sudo systemctl start ssh
   ```

2. Check firewall:
   ```bash
   sudo ufw allow ssh
   ```

### Permission Denied

Make sure you're using the correct username and password you set during Ubuntu installation.

## 📖 Next Steps

Once install test passes:

1. **Configure**: `sudo nano /etc/blitz-gateway/config.toml`
2. **Start**: `sudo systemctl start blitz-gateway`
3. **Test**: `curl http://localhost:8443` (if configured)
4. **Benchmark**: Run benchmark scripts

