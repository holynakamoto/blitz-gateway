# Quick Test: Blitz Gateway Install in Vagrant/UTM

## 🚀 Fastest Way to Test (Vagrant)

Your Vagrantfile is already configured for Ubuntu 22.04, which matches the install script!

```bash
# Start VM
vagrant up

# SSH in
vagrant ssh

# Run install test (builds .deb and installs)
cd /vagrant
./scripts/vm/test-install-in-vm.sh
```

Done! This will:
- ✅ Build the binary
- ✅ Create .deb package  
- ✅ Install it
- ✅ Verify everything works

## 📝 What Gets Tested

- Binary installation (`/usr/bin/blitz-gateway`)
- Config file (`/etc/blitz-gateway/config.toml`)
- System user creation (`blitz-gateway`)
- Systemd service setup
- All directories and permissions

## 🔧 Using UTM Instead

If you prefer UTM directly (not via Vagrant):

1. **Create UTM VM** with Ubuntu 22.04:
   - Download ISO: `ubuntu-22.04-server-amd64.iso`
   - Create VM in UTM with 4-8 CPUs, 8-16GB RAM

2. **Copy repo to VM**:
   ```bash
   # From Mac
   scp -r ~/blitz-gateway user@vm-ip:/home/user/
   ```

3. **SSH and test**:
   ```bash
   ssh user@vm-ip
   cd ~/blitz-gateway
   ./scripts/vm/test-install-in-vm.sh
   ```

## ✅ Expected Output

You should see:
```
✅ Binary installed at /usr/bin/blitz-gateway
✅ Config file exists at /etc/blitz-gateway/config.toml
✅ System user 'blitz-gateway' created
✅ Systemd service installed
✅ Install Test Complete!
```

## 🎯 Next Steps After Test

Once verified:
1. **Configure**: `sudo nano /etc/blitz-gateway/config.toml`
2. **Start**: `sudo systemctl start blitz-gateway`
3. **Check**: `sudo systemctl status blitz-gateway`

For full details, see: `docs/packaging/TEST-INSTALL.md`

