# Using Vagrant with UTM on macOS

## Quick Setup

### 1. Install UTM and Vagrant UTM Plugin

```bash
# Install UTM (if not already installed)
brew install --cask utm

# Install Vagrant UTM plugin
vagrant plugin install vagrant_utm
```

### 2. Use UTM Provider

```bash
# Start VM with UTM provider
vagrant up --provider=utm

# Or set default provider
export VAGRANT_DEFAULT_PROVIDER=utm
vagrant up
```

## UTM vs VirtualBox

**VirtualBox** (default):
- Works on macOS, Linux, Windows
- More mature, stable
- Slower on macOS (especially Apple Silicon)

**UTM** (recommended for macOS):
- Native macOS integration
- Better performance on Apple Silicon
- Free and open source
- Requires `vagrant_utm` plugin

## Current Vagrantfile Configuration

The Vagrantfile supports both providers:

```ruby
# VirtualBox (default)
config.vm.provider "virtualbox" do |vb|
  vb.cpus = 8
  vb.memory = "16384"
  # ...
end

# UTM (for macOS)
config.vm.provider "utm" do |utm|
  utm.memory = 16384
  utm.cpus = 8
  utm.arch = "x86_64"
  # ...
end
```

## Using UTM

### Option 1: Specify Provider

```bash
vagrant up --provider=utm
vagrant ssh
```

### Option 2: Set Default

```bash
export VAGRANT_DEFAULT_PROVIDER=utm
vagrant up
```

### Option 3: Direct UTM (No Vagrant)

If you prefer not to use Vagrant with UTM:

1. Create UTM VM manually with Ubuntu 22.04
2. Use the test script directly:
   ```bash
   ssh user@vm-ip
   cd ~/blitz-gateway
   ./scripts/vm/test-install-in-vm.sh
   ```

## Troubleshooting

### Plugin Not Found

```bash
vagrant plugin install vagrant_utm
```

### UTM Not Installed

```bash
brew install --cask utm
# Or download from: https://mac.getutm.app/
```

### Provider Conflicts

```bash
# Destroy existing VirtualBox VM
vagrant destroy

# Use UTM instead
vagrant up --provider=utm
```

## Testing Install Script

Once VM is running (with either provider):

```bash
vagrant ssh
cd /vagrant
./scripts/vm/test-install-in-vm.sh
```

Both providers use the same Ubuntu 22.04 box, so the install script works identically.

