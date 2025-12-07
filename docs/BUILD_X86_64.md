# Building x86_64 Binaries

## The Challenge

The pre-built static libraries (`liburing-ffi.a`, `libpicotls.a`) in the Multipass ARM64 VM are compiled for ARM64 architecture. To build for x86_64 (needed for AMD EPYC, Intel Xeon, etc.), you need an x86_64 build environment.

## Solution 1: GitHub Actions (Recommended)

The easiest approach - automatic builds on every tag push.

### Setup

1. The workflow is already configured at `.github/workflows/build-release.yml`

2. To trigger a build:
   ```bash
   git tag v1.0.2
   git push origin v1.0.2
   ```

3. The workflow will:
   - Build for x86_64 on `ubuntu-22.04` runner
   - Build for ARM64 using cross-compilation
   - Create a GitHub Release with both binaries

### Manual Trigger

Go to Actions → "Build Release Binaries" → "Run workflow"

## Solution 2: Docker

Build locally using Docker's x86_64 emulation:

```bash
# Create Dockerfile
cat > Dockerfile.x86_64 << 'EOF'
FROM --platform=linux/amd64 ubuntu:22.04

RUN apt-get update && apt-get install -y \
    build-essential cmake git wget xz-utils

# Install Zig
RUN wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz \
    && tar xf zig-linux-x86_64-0.14.0.tar.xz \
    && mv zig-linux-x86_64-0.14.0 /opt/zig

ENV PATH="/opt/zig:$PATH"

WORKDIR /build
COPY . .

# Build dependencies
RUN cd deps/liburing && ./configure && make -j$(nproc) && make install
RUN cd deps/liburing/src && gcc -c -fPIC -O2 liburing.c -o liburing-ffi.o \
    && ar rcs liburing-ffi.a liburing-ffi.o && cp liburing-ffi.a /usr/local/lib/

RUN cd deps/picotls && git submodule update --init --recursive \
    && mkdir build && cd build \
    && cmake .. -DBUILD_SHARED_LIBS=OFF -DPTLS_MINICRYPTO=ON -DPTLS_OPENSSL=OFF \
    && make -j$(nproc) picotls-core picotls-minicrypto \
    && cp libpicotls-core.a /usr/local/lib/libpicotls.a \
    && cp libpicotls-minicrypto.a /usr/local/lib/ \
    && cp -r ../include/picotls /usr/local/include/ \
    && cp ../include/picotls.h /usr/local/include/

# Build Blitz
RUN zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl

CMD ["cp", "zig-out/bin/blitz", "/output/blitz-linux-x86_64"]
EOF

# Build
docker build --platform linux/amd64 -t blitz-x86_64 -f Dockerfile.x86_64 .

# Extract binary
mkdir -p release
docker run --platform linux/amd64 -v $(pwd)/release:/output blitz-x86_64
```

## Solution 3: Cloud VM

Use a cloud provider with x86_64 VMs:

### AWS EC2
```bash
# Launch Ubuntu 22.04 x86_64 instance
aws ec2 run-instances --image-id ami-0c55b159cbfafe1f0 --instance-type c5.2xlarge
```

### GCP Compute Engine
```bash
gcloud compute instances create blitz-builder \
  --machine-type=n2-standard-8 \
  --image-family=ubuntu-2204-lts
```

### DigitalOcean
```bash
doctl compute droplet create blitz-builder \
  --image ubuntu-22-04-x64 \
  --size s-4vcpu-8gb
```

Then SSH in and run the build script.

## Verification

After building, verify the binary:

```bash
# Check architecture
file blitz-linux-x86_64
# Expected: ELF 64-bit LSB executable, x86-64, statically linked

# Check it's truly static
ldd blitz-linux-x86_64
# Expected: "not a dynamic executable"

# Run on x86_64 machine
./blitz-linux-x86_64 --version
```

## Current Binaries

| Version | Architecture | Status |
|---------|--------------|--------|
| v1.0.1 | ARM64 | ✅ Available |
| v1.0.1 | x86_64 | ⏳ Pending (use GitHub Actions) |

## Quick Reference

```bash
# Trigger CI build
git tag v1.0.2
git push origin v1.0.2

# Download from release
curl -L -o blitz https://github.com/holynakamoto/blitz-gateway/releases/latest/download/blitz-linux-x86_64
chmod +x blitz
```

