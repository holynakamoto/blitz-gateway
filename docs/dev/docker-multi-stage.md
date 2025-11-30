# Docker Multi-Stage Build System

This document describes the consolidated Docker build system for Blitz QUIC/HTTP3 server.

## Overview

The project uses a single multi-stage `Dockerfile` with multiple build targets to support different deployment scenarios. This eliminates duplication and simplifies maintenance.

## Build Targets

### `prod` (Default)
**Production-ready QUIC server**
- Minimal runtime dependencies
- Optimized binary
- Self-contained with certificates
- Health checks enabled

**Use for:** Production deployments, CI/CD pipelines

```bash
docker build -t blitz-gateway:latest .
# or explicitly
docker build --target prod -t blitz-gateway:latest .
```

### `dev`
**Development and testing server**
- Additional debugging tools
- Network utilities (netcat, curl, etc.)
- Development certificates
- Multiple port exposure
- Source code mounting support

**Use for:** Local development, integration testing, debugging

```bash
docker build --target dev -t blitz-gateway:dev .
```

### `minimal`
**Ultra-minimal scratch-based image**
- No shell or package manager
- Direct binary execution
- Smallest possible image size
- Limited debugging capabilities

**Use for:** Production with minimal attack surface

```bash
docker build --target minimal -t blitz-gateway:minimal .
```

## Build Arguments

| Argument | Default | Description |
|----------|---------|-------------|
| `UBUNTU_VERSION` | `22.04` | Ubuntu base image version |
| `ZIG_VERSION` | `0.15.2` | Zig compiler version |
| `BUILD_TYPE` | `Release` | CMake build type for PicoTLS |

## Usage Examples

### Local Development
```bash
# Build development image
docker build --target dev -t blitz-dev .

# Run with source mounting
docker run -it --rm \
  -p 8443:8443/udp \
  -v $(pwd):/app \
  blitz-dev
```

### Production Deployment
```bash
# Build optimized production image
docker build --target prod -t blitz-prod .

# Run in production
docker run -d \
  --name blitz-server \
  -p 8443:8443/udp \
  --restart unless-stopped \
  blitz-prod
```

### Multi-Platform Builds
```bash
# Build for multiple architectures
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --target prod \
  -t blitz-gateway:latest \
  --push .
```

## Docker Compose Integration

### Production Service
```yaml
services:
  blitz-quic:
    build:
      context: .
      target: prod
    ports:
      - "8443:8443/udp"
```

### Development Service
```yaml
services:
  blitz-quic-dev:
    build:
      context: .
      target: dev
    profiles: [dev]
    ports:
      - "8443:8443/udp"
      - "8080:8080/tcp"
```

## Build Stages

### 1. `base-builder`
- Ubuntu base image
- Common build dependencies
- Zig compiler installation

### 2. `picotls-builder`
- PicoTLS compilation from source
- OpenSSL integration
- Static library generation

### 3. `app-builder`
- Zig application compilation
- Certificate generation
- Final binary linking

### 4. `runtime-base`
- Minimal runtime environment
- Required shared libraries
- Certificate authorities

## Health Checks

### Production Target
- QUIC UDP port connectivity check
- 30-second intervals, 10-second timeout
- 3 retries with 5-second start period

### Development Target
- QUIC UDP port check
- TCP port checks for HTTP/HTTPS
- Same timing as production

## Security Considerations

### Production Image
- Minimal attack surface
- No shell or debugging tools
- Read-only certificate mounting
- Non-root user execution (when applicable)

### Development Image
- Additional tools for debugging
- Source code access for development
- More permissive for testing

## CI/CD Integration

### GitHub Actions
- `docker.yml`: Tests all build targets
- `release.yml`: Publishes all variants
- `benchmark.yml`: Uses dev target for testing

### Build Commands
```bash
# CI production build
docker build --target prod .

# CI development test
docker build --target dev .

# Release builds
docker build --target prod -t prod .
docker build --target dev -t dev .
docker build --target minimal -t minimal .
```

## Troubleshooting

### Build Failures
- **PicoTLS submodule**: Ensure `git submodule update --init --recursive`
- **Architecture issues**: Use `--platform` flag for cross-compilation
- **Certificate errors**: Check certs directory and permissions

### Runtime Issues
- **Port conflicts**: Change host port mapping
- **Permission denied**: Ensure proper user permissions
- **Library not found**: Check `LD_LIBRARY_PATH` environment

## Migration from Old Dockerfiles

### Before (Multiple files)
```bash
# Dockerfile (prod)
# Dockerfile.quic (dev)
docker build -f Dockerfile .
docker build -f Dockerfile.quic .
```

### After (Single file, multiple targets)
```bash
# Production
docker build --target prod .

# Development
docker build --target dev .

# Minimal
docker build --target minimal .
```

## Future Enhancements

- **Distroless base**: Replace Ubuntu with Google's distroless
- **SBOM generation**: Software Bill of Materials
- **Vulnerability scanning**: Integrated security scanning
- **Multi-arch CI**: Automated cross-platform testing
