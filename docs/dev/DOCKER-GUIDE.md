# Docker Guide for Blitz Gateway QUIC Testing

## Quick Start

```bash
# Start QUIC server
./scripts/docker/docker-quic.sh run

# Test from macOS
curl --http3-only -k https://localhost:8443/hello

# View logs
./scripts/docker/docker-quic.sh logs

# Stop server
./scripts/docker/docker-quic.sh stop
```

## Why Docker?

Docker is the **recommended approach** for QUIC development and testing:

✅ **Faster iteration** - 2-5 second startup vs 30-60s for Vagrant  
✅ **Better networking** - Native UDP forwarding, simpler port mapping  
✅ **Lower overhead** - ~100-200MB RAM vs 1-2GB for full VM  
✅ **CI/CD ready** - Easy GitHub Actions integration  
✅ **Multi-service** - docker-compose for load balancer testing  
✅ **Production path** - Same Dockerfile for deployment  

## Architecture

```
┌─────────────────────────────────────────┐
│  macOS Host                             │
│                                         │
│  ┌──────────────────────────────────┐  │
│  │  Docker Desktop (Linux VM)       │  │
│  │                                   │  │
│  │  ┌────────────────────────────┐  │  │
│  │  │  blitz-quic container       │  │  │
│  │  │  - QUIC server (UDP 8443)   │  │  │
│  │  │  - io_uring enabled         │  │  │
│  │  └────────────────────────────┘  │  │
│  │                                   │  │
│  │  Port forwarding:                  │  │
│  │  - 8443:8443/udp (QUIC)          │  │
│  │  - 8080:8080 (HTTP)               │  │
│  │  - 8444:8443 (HTTPS)              │  │
│  └──────────────────────────────────┘  │
│                                         │
│  curl --http3-only https://localhost:8443 │
└─────────────────────────────────────────┘
```

## Files

- **`Dockerfile`** - Container image definition
- **`infra/compose/`** - Environment-specific Docker Compose files
- **`infra/up.sh`** - Smart wrapper script for environment management
- **`Makefile`** - Convenience shortcuts for common tasks
- **`.dockerignore`** - Exclude unnecessary files from build

## Development Workflow

### Option 1: Rebuild on Each Change (Recommended)

```bash
# Edit code
vim src/quic/handshake.zig

# Rebuild and restart
./scripts/docker/docker-quic.sh rebuild

# Test
curl --http3-only -k https://localhost:8443/hello
```

### Option 2: Volume Mount (Faster Iteration)

Edit `infra/compose/dev.yml`:

```yaml
volumes:
  - ./certs:/app/certs:ro
  - ./src:/app/src:ro  # Add this
```

Then rebuild inside container:

```bash
docker-compose exec blitz-quic zig build
docker-compose restart blitz-quic
```

## Testing

### Basic Connectivity

```bash
# Start server
./scripts/docker/docker-quic.sh run

# Test UDP port
nc -zu localhost 8443

# Test HTTP/3
curl --http3-only -k https://localhost:8443/hello

# Test with verbose output
curl --http3-only -k -v https://localhost:8443/hello
```

### Load Balancer Testing

```bash
# Start with backend
docker-compose --profile with-backend up -d

# Test load balancing
for i in {1..10}; do
  curl --http3-only -k https://localhost:8443/api
done
```

### Performance Testing

```bash
# Inside container
docker-compose exec blitz-quic /bin/bash
cd /app
zig build -Doptimize=ReleaseFast
./zig-out/bin/blitz-quic

# From host (using wrk or similar)
wrk -t4 -c100 -d30s --http3 https://localhost:8443/
```

## Troubleshooting

### Library Linking Issues

If you see errors like:
```
error: unable to find dynamic system library 'crypto'
```

**Solution:** The `build.zig` includes multiple library paths. If it still fails:

```bash
# Check libraries in container
docker-compose exec blitz-quic find /usr/lib* -name "libcrypto.so*"

# Rebuild with verbose output
docker-compose build --progress=plain
```

### io_uring Not Available

If you see:
```
error: io_uring not available
```

**Solution:** The `privileged: true` setting is configured in `infra/compose/common.yml`. Docker Desktop on macOS uses a Linux VM, so io_uring should work.

### Port Already in Use

```bash
# Find process using port
lsof -i :8443

# Kill process
kill -9 <PID>

# Or use different port in infra/compose/dev.yml
ports:
  - "8444:8443/udp"
```

### Container Won't Start

```bash
# Check logs
docker-compose logs blitz-quic

# Check container status
docker ps -a | grep blitz-quic

# Remove and rebuild
docker-compose down
docker-compose build --no-cache
docker-compose up -d
```

## CI/CD Integration

### GitHub Actions

```yaml
name: QUIC Tests

on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Build Docker image
        run: docker-compose build
      
      - name: Start QUIC server
        run: docker-compose up -d blitz-quic
      
      - name: Wait for server
        run: sleep 5
      
      - name: Test QUIC
        run: |
          curl --http3-only -k https://localhost:8443/hello
```

## Performance Expectations

| Environment | Expected RPS | Latency | Use Case |
|-------------|-------------|---------|----------|
| Docker (macOS) | 100K-500K | <1ms | Development testing |
| Docker (Linux) | 500K-2M | <500µs | Integration testing |
| Bare metal | 8M-10M | <120µs | Production benchmarks |

**Docker is sufficient for correctness testing.** Use bare metal for final performance validation.

## Comparison: Docker vs Vagrant

| Aspect | Docker | Vagrant |
|--------|--------|---------|
| Startup time | 2-5s | 30-60s |
| RAM usage | ~200MB | ~2GB |
| UDP networking | ✅ Native | ⚠️ NAT config |
| CI/CD | ✅ Easy | ⚠️ Complex |
| io_uring | ✅ Works | ✅ Works |
| Multi-service | ✅ docker-compose | ⚠️ Multi-VM |

**Recommendation:** Use Docker for 90% of testing, Vagrant only for deep kernel debugging.

## Next Steps

1. ✅ **Docker setup complete** - You're ready to test!
2. 🔄 **Transport parameters** - Continue implementation
3. 🔄 **Header protection** - Next handshake step
4. 🔄 **End-to-end testing** - Validate full handshake

## Resources

- [Docker Documentation](https://docs.docker.com/)
- [docker-compose Reference](https://docs.docker.com/compose/compose-file/)
- [QUIC Testing Guide](./QUIC-TESTING-SETUP.md)

