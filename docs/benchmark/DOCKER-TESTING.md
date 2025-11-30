# Testing Blitz on macOS/Windows with Docker

Blitz uses io_uring which is **Linux-only**. Use Docker to test on macOS/Windows before deploying to bare metal.

## Quick Start (Automated)

**One-command setup and benchmark:**

```bash
./scripts/bench/docker-bench.sh
```

This will:
1. Build the Docker image (Ubuntu 24.04 LTS Minimal)
2. Start container with proper privileges
3. Apply system tuning
4. Start Blitz server
5. Show you how to run benchmarks

## Manual Docker Setup

### Step 1: Build Image

```bash
docker build -t blitz:latest .
```

### Step 2: Run Container

```bash
# Stop existing container if any
docker stop blitz 2>/dev/null || true
docker rm blitz 2>/dev/null || true

# Run with privileged mode (required for system tuning)
docker run -d \
  --name blitz \
  --privileged \
  --network host \
  -v /sys:/sys:rw \
  --ulimit nofile=1048576:1048576 \
  blitz:latest \
  tail -f /dev/null
```

### Step 3: Apply System Tuning

```bash
docker exec blitz bash -c "
  sysctl -w net.core.somaxconn=1048576
  sysctl -w net.ipv4.tcp_max_syn_backlog=1048576
  sysctl -w net.core.netdev_max_backlog=50000
  echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
  echo performance | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
  ulimit -n 1048576
"
```

### Step 4: Start Blitz

```bash
docker exec -d blitz bash -c "cd /app && ./zig-out/bin/blitz"
```

### Step 5: Run Benchmarks

**Option A: From host** (if wrk2 installed on macOS/Windows):
```bash
./scripts/bench/local-benchmark.sh
```

**Option B: Inside container**:
```bash
docker exec blitz bash -c "cd /app && ./scripts/bench/local-benchmark.sh"
```

**Option C: Manual wrk2 test**:
```bash
docker exec blitz wrk2 -t 4 -c 1000 -d 30s -R 1000000 --latency http://localhost:8080/hello
```

## Docker Compose (Alternative)

```bash
# Start container
docker-compose up -d

# Apply tuning and start Blitz
docker exec blitz bash -c "cd /app && ./scripts/bench/bench-box-setup.sh" || true
docker exec -d blitz bash -c "cd /app && ./zig-out/bin/blitz"

# Run benchmarks
docker exec blitz bash -c "cd /app && ./scripts/bench/local-benchmark.sh"
```

## Expected Performance in Docker

**Note**: Docker adds overhead, so expect lower performance than bare metal:

- **Local machine (Docker)**: 1-3M RPS (depending on host hardware)
- **Bare metal (same hardware)**: 3-5M RPS
- **Bare metal (EPYC 9754)**: 12-15M RPS

Docker is great for:
- ✅ Testing the setup scripts
- ✅ Verifying code works
- ✅ Development iteration
- ✅ Learning the benchmark process

For production benchmarks, use bare metal Linux.

## Troubleshooting

**"io_uring not available"**
- Docker may not expose io_uring properly
- Try: `docker exec blitz ls /sys/fs/io_uring`
- If missing, you may need a newer Docker version or Linux host

**"Permission denied" for system tuning**
- Ensure `--privileged` flag is used
- Or use `--cap-add SYS_ADMIN --cap-add SYS_NICE`

**Low performance**
- Docker adds virtualization overhead
- Use `--network host` to reduce network overhead
- Consider bare metal for real benchmarks

**Container won't start**
- Check Docker logs: `docker logs blitz`
- Ensure Docker has enough resources allocated

## View Logs

```bash
# Blitz server logs
docker exec blitz cat /tmp/blitz.log

# Container logs
docker logs blitz

# Real-time logs
docker exec blitz tail -f /tmp/blitz.log
```

## Cleanup

```bash
# Stop container
docker stop blitz

# Remove container
docker rm blitz

# Remove image (optional)
docker rmi blitz:latest
```

## Next Steps

After testing in Docker:
1. Deploy Ubuntu 24.04 LTS Minimal on bare metal
2. Run `./scripts/bench/bench-box-setup.sh` on bare metal
3. Run `./scripts/bench/reproduce.sh` for production benchmarks
4. Compare results (Docker vs bare metal)

