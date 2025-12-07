# QUIC Validation - VM Integration Guide

This guide shows how to use the validation tools with your Multipass VM setup.

## 🎯 Your Setup

```
Host Machine (macOS)
    │
    ├─► Multipass VM "zig-build"
    │    └─► /home/ubuntu/local_build/
    │         ├─► server binary (QUIC server)
    │         ├─► tools/quic_validator.zig (existing)
    │         └─► validation-tools/ (this toolkit)
    │
    └─► Network: localhost:8443 (forwarded to VM)
```

## 📦 Installation

### Step 1: Copy Tools to VM

```bash
# From your host machine, copy the validation tools to VM
multipass transfer validation-tools/ zig-build:/home/ubuntu/local_build/

# Or mount this directory
multipass mount $(pwd) zig-build:/mnt/validation-tools
```

### Step 2: Install Python Dependencies (in VM)

```bash
# SSH into VM
multipass shell zig-build

# Install aioquic
pip3 install aioquic

# Or if pip3 not available
sudo apt update
sudo apt install python3-pip
pip3 install aioquic
```

### Step 3: Make Scripts Executable

```bash
cd /home/ubuntu/local_build/validation-tools
chmod +x *.sh *.py
```

## 🚀 Running Tests

### Option 1: From Host Machine (Testing VM Server)

If your VM server is accessible from host:

```bash
# Test from host (assumes port forwarding)
python3 quic_validator.py localhost 8443

# Or run quickstart
./quickstart.sh localhost 8443
```

### Option 2: Inside VM (Recommended)

```bash
# SSH into VM
multipass shell zig-build

# Navigate to build directory
cd /home/ubuntu/local_build

# Start server with capture enabled
./server --capture &

# Run validation from tools directory
cd validation-tools
./quickstart.sh

# Or run specific validators
zig run quic_validator.zig
python3 quic_validator.py
```

### Option 3: Combined VM + Host Testing

```bash
# Terminal 1 (VM): Start server
multipass shell zig-build
cd /home/ubuntu/local_build
./server --capture

# Terminal 2 (Host): Run tests
cd validation-tools
python3 quic_validator.py localhost 8443
```

## 🔧 VM-Specific Commands

### Start Server in VM

```bash
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && ./server --capture"
```

### Run Zig Validator in VM

```bash
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && zig run tools/quic_validator.zig"
```

### Run Python Validator in VM

```bash
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_validator.py"
```

### Check Captures in VM

```bash
multipass exec zig-build -- bash -c "ls -la /home/ubuntu/local_build/captures/"
```

### View Server Logs in VM

```bash
multipass exec zig-build -- bash -c "tail -f /home/ubuntu/local_build/server.log"
```

## 📊 Complete VM Testing Workflow

```bash
#!/bin/bash
# save as: vm-test.sh

set -e

echo "=== Starting QUIC Server in VM ==="
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && ./server --capture &"

echo "=== Waiting for server to start ==="
sleep 2

echo "=== Running Zig Validator ==="
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && zig run tools/quic_validator.zig"

echo "=== Running Python Validator ==="
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_validator.py"

echo "=== Checking Captures ==="
multipass exec zig-build -- bash -c "ls -la /home/ubuntu/local_build/captures/"

echo "=== Running Benchmark ==="
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_benchmark.py all"

echo "=== Stopping Server ==="
multipass exec zig-build -- bash -c "pkill -f './server'"

echo "=== Tests Complete ==="
```

## 🐛 VM-Specific Troubleshooting

### Issue: Can't Connect to Server from Host

**Solution 1: Port Forwarding**

```bash
# Stop VM
multipass stop zig-build

# Add port forwarding
multipass start zig-build --mount type=port,host=8443,guest=8443

# Or use SSH tunnel
ssh -L 8443:localhost:8443 ubuntu@$(multipass info zig-build | grep IPv4 | awk '{print $2}')
```

**Solution 2: Test from Within VM**

```bash
# Always works - test from inside VM
multipass shell zig-build
cd /home/ubuntu/local_build/validation-tools
./quickstart.sh localhost 8443
```

### Issue: aioquic Not Found in VM

```bash
# Install in VM
multipass shell zig-build
pip3 install --user aioquic

# Or system-wide
sudo pip3 install aioquic

# Verify installation
python3 -c "import aioquic; print('OK')"
```

### Issue: Zig Validator Fails

```bash
# Check Zig version in VM
multipass exec zig-build -- zig version

# Verify file exists
multipass exec zig-build -- ls -la /home/ubuntu/local_build/tools/quic_validator.zig

# Run with verbose output
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && zig run tools/quic_validator.zig -- localhost 8443"
```

### Issue: Capture Directory Not Found

```bash
# Check server started with --capture flag
multipass exec zig-build -- bash -c "ps aux | grep server"

# Check if directory exists
multipass exec zig-build -- bash -c "ls -la /home/ubuntu/local_build/captures/"

# Create manually if needed
multipass exec zig-build -- bash -c "mkdir -p /home/ubuntu/local_build/captures"
```

## 📁 VM File Structure

```
/home/ubuntu/local_build/
├── server                          # Your QUIC server binary
├── cert.pem                        # TLS certificate
├── key.pem                         # TLS private key
├── server.log                      # Server logs
│
├── tools/                          # Your existing tools
│   └── quic_validator.zig          # Existing Zig validator
│
├── validation-tools/               # This toolkit
│   ├── README.md                   # Main documentation
│   ├── quickstart.sh               # Automated testing
│   ├── quic_validator.zig          # Enhanced Zig validator
│   ├── quic_validator.py           # Python validator
│   ├── quic_benchmark.py           # Benchmark tool
│   ├── QUICK_REFERENCE.md          # Quick commands
│   ├── VALIDATION_GUIDE.md         # Complete guide
│   └── VM_INTEGRATION.md           # This file
│
└── captures/                       # Generated by server
    ├── connection_*.pcap
    ├── connection_*.json
    ├── connection_*.txt
    └── connection_*.keys
```

## 🎯 Recommended Workflow

### Daily Development

1. **Start server in VM:**
   ```bash
   multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && ./server --capture &"
   ```

2. **Quick validation:**
   ```bash
   multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && zig run tools/quic_validator.zig"
   ```

3. **Check captures:**
   ```bash
   multipass exec zig-build -- ls -la /home/ubuntu/local_build/captures/
   ```

### Before Committing Changes

1. **Full validation suite:**
   ```bash
   multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && ./quickstart.sh"
   ```

2. **Run benchmarks:**
   ```bash
   multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_benchmark.py all -o results.json"
   ```

3. **Compare with baseline:**
   ```bash
   # Copy results to host for comparison
   multipass transfer zig-build:/home/ubuntu/local_build/validation-tools/results.json .
   ```

### Performance Testing

1. **Establish baseline:**
   ```bash
   multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_benchmark.py all -o baseline.json"
   multipass transfer zig-build:/home/ubuntu/local_build/validation-tools/baseline.json .
   ```

2. **After optimizations:**
   ```bash
   multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_benchmark.py all -o current.json"
   multipass transfer zig-build:/home/ubuntu/local_build/validation-tools/current.json .
   ```

3. **Compare:**
   ```bash
   # On host
   diff baseline.json current.json
   ```

## 🔄 Syncing Between Host and VM

### Push to VM

```bash
# Copy entire toolkit
multipass transfer validation-tools/ zig-build:/home/ubuntu/local_build/

# Copy specific file
multipass transfer quic_benchmark.py zig-build:/home/ubuntu/local_build/validation-tools/
```

### Pull from VM

```bash
# Get capture files
multipass transfer zig-build:/home/ubuntu/local_build/captures/ ./captures-$(date +%Y%m%d)/

# Get benchmark results
multipass transfer zig-build:/home/ubuntu/local_build/validation-tools/results.json ./results-$(date +%Y%m%d).json
```

## 📝 Quick Reference

### Essential Commands

```bash
# Start server
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && ./server --capture &"

# Run validation
multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && ./quickstart.sh"

# Check status
multipass exec zig-build -- bash -c "ps aux | grep server"

# View logs
multipass exec zig-build -- bash -c "tail -20 /home/ubuntu/local_build/server.log"

# Stop server
multipass exec zig-build -- bash -c "pkill -f './server'"

# Clean captures
multipass exec zig-build -- bash -c "rm -rf /home/ubuntu/local_build/captures/*"
```

### Monitoring

```bash
# Watch server logs
multipass exec zig-build -- bash -c "tail -f /home/ubuntu/local_build/server.log | grep -E '(QUIC|CAPTURE|ERROR)'"

# Watch captures being created
multipass exec zig-build -- bash -c "watch -n 1 'ls -lt /home/ubuntu/local_build/captures/ | head -10'"

# Monitor server CPU/memory
multipass exec zig-build -- bash -c "top -b -n 1 | grep server"
```

## ✅ Validation Checklist

Before starting benchmark tests:

- [ ] VM is running: `multipass list`
- [ ] Server binary exists: `multipass exec zig-build -- ls /home/ubuntu/local_build/server`
- [ ] Certificates exist: `multipass exec zig-build -- ls /home/ubuntu/local_build/{cert,key}.pem`
- [ ] Validation tools installed: `multipass exec zig-build -- ls /home/ubuntu/local_build/validation-tools/`
- [ ] Python dependencies installed: `multipass exec zig-build -- python3 -c "import aioquic"`
- [ ] Server starts successfully: `multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && ./server --capture"`
- [ ] Zig validator passes: `multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build && zig run tools/quic_validator.zig"`
- [ ] Python validator passes: `multipass exec zig-build -- bash -c "cd /home/ubuntu/local_build/validation-tools && python3 quic_validator.py"`
- [ ] Capture files created: `multipass exec zig-build -- ls /home/ubuntu/local_build/captures/`

## 🎓 Next Steps

1. **Copy this toolkit to your VM**
2. **Run the quickstart script**
3. **Verify all tests pass**
4. **Run your first benchmark**
5. **Review the generated captures**

Your QUIC/HTTP3 server will be fully validated and ready for production benchmarking! 🚀

