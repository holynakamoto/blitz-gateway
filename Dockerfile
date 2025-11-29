# Blitz Dockerfile for testing
# Uses Ubuntu 24.04 LTS Minimal for maximum io_uring performance
FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    git \
    build-essential \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.13.0 (better liburing support) - detect architecture
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        ZIG_ARCH="x86_64"; \
        ZIG_VERSION="0.12.0"; \
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then \
        ZIG_ARCH="aarch64"; \
        ZIG_VERSION="0.12.0"; \
    else \
        echo "Unsupported architecture: $ARCH" && exit 1; \
    fi && \
    echo "Installing Zig ${ZIG_VERSION} for ${ZIG_ARCH}..." && \
    wget -q https://ziglang.org/download/${ZIG_VERSION}/zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz && \
    tar -xf zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz && \
    mv zig-linux-${ZIG_ARCH}-${ZIG_VERSION} /opt/zig && \
    rm zig-linux-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz && \
    /opt/zig/zig version

ENV PATH="/opt/zig:${PATH}"

# Install liburing and pkg-config
RUN apt-get update && apt-get install -y \
    liburing-dev \
    pkg-config \
    linux-tools-common \
    linux-tools-generic \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy source
COPY . .

# Update ldconfig cache and verify liburing
RUN ldconfig && \
    echo "=== liburing library locations ===" && \
    find /usr -name "liburing.so*" 2>/dev/null && \
    ldconfig -p | grep uring && \
    pkg-config --libs liburing || true

# Build Blitz (ReleaseFast for maximum performance)
RUN zig build -Doptimize=ReleaseFast

# Install benchmarking tools
RUN cd /tmp && \
    git clone https://github.com/giltene/wrk2.git && \
    cd wrk2 && \
    make && \
    cp wrk /usr/local/bin/wrk2 && \
    cd / && \
    rm -rf /tmp/wrk2

# Copy setup script
COPY scripts/bench-box-setup.sh /usr/local/bin/bench-box-setup.sh
RUN chmod +x /usr/local/bin/bench-box-setup.sh

# Expose port
EXPOSE 8080

# Default: run Blitz
# Use --privileged flag for full system access (required for some tuning)
CMD ["./zig-out/bin/blitz"]

