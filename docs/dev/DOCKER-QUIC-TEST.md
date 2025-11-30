# Docker Alternative for QUIC Testing on ARM Mac

Since VirtualBox doesn't support x86 VMs on ARM Macs, Docker is a simpler alternative.

## Quick Start

### 1. Create Dockerfile

```dockerfile
FROM ubuntu:22.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    libssl-dev \
    liburing-dev \
    pkg-config \
    netcat-openbsd \
    net-tools \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.15.2
RUN cd /tmp && \
    wget -q https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz && \
    tar -xf zig-linux-x86_64-0.15.2.tar.xz && \
    mv zig-linux-x86_64-0.15.2 /usr/local/zig && \
    ln -s /usr/local/zig/zig /usr/local/bin/zig

WORKDIR /app

# Copy source code
COPY . .

# Build
RUN zig build

# Expose ports
EXPOSE 8080 8443/udp 8443

CMD ["./zig-out/bin/blitz-quic"]
```

### 2. Build and Run

```bash
# Build image
docker build -t blitz-quic .

# Run container
docker run -it --rm \
  -p 8080:8080 \
  -p 8443:8443/udp \
  -p 8444:8443 \
  -v $(pwd):/app \
  blitz-quic
```

### 3. Test

```bash
# From macOS
curl --http3-only -k https://localhost:8443/hello
```

## Advantages

- ✅ Works on ARM Macs
- ✅ No VM overhead
- ✅ Faster startup
- ✅ Easier to share/reproduce

## Disadvantages

- ⚠️ Docker networking can be tricky with UDP
- ⚠️ io_uring may have limitations in containers
- ⚠️ Performance may differ from bare metal

