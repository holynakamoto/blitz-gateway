# syntax = docker.io/docker/dockerfile:1.7

# ─────────────────────────────────────────────────────────────
# Common build arguments
# ─────────────────────────────────────────────────────────────

ARG UBUNTU_VERSION=22.04
ARG ZIG_VERSION=0.15.2
ARG BUILD_TYPE=Release

# ─────────────────────────────────────────────────────────────
# 1. Base builder stage (common dependencies)
# ─────────────────────────────────────────────────────────────

FROM ubuntu:${UBUNTU_VERSION} AS base-builder

# Install common build dependencies
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    git \
    curl \
    libssl-dev \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
RUN curl -L https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz \
    -o /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-${ZIG_VERSION}/zig /usr/local/bin/zig && \
    zig version

# ─────────────────────────────────────────────────────────────
# 2. PicoTLS builder (builds picotls from source)
# ─────────────────────────────────────────────────────────────

FROM base-builder AS picotls-builder

# Build PicoTLS with OpenSSL support
RUN git clone --recursive --depth 1 https://github.com/h2o/picotls /tmp/picotls && \
    cd /tmp/picotls && \
    cmake -B build \
        -DWITH_OPENSSL=ON \
        -DCMAKE_BUILD_TYPE=${BUILD_TYPE} \
        -DBUILD_TESTING=OFF \
        . && \
    cmake --build build --config ${BUILD_TYPE} && \
    find build/ -name "*.a" -exec cp {} /usr/local/lib/ \; && \
    cp -r include/* /usr/local/include/ && \
    rm -rf /tmp/picotls

# ─────────────────────────────────────────────────────────────
# 3. Application builder (builds the Zig application)
# ─────────────────────────────────────────────────────────────

FROM picotls-builder AS app-builder

# Set up architecture-specific OpenSSL headers
RUN mkdir -p /usr/include/openssl && \
    ln -sf /usr/include/x86_64-linux-gnu/openssl/opensslconf.h /usr/include/openssl/opensslconf.h 2>/dev/null || \
    ln -sf /usr/include/aarch64-linux-gnu/openssl/opensslconf.h /usr/include/openssl/opensslconf.h 2>/dev/null || true && \
    ln -sf /usr/include/x86_64-linux-gnu/openssl/configuration.h /usr/include/openssl/configuration.h 2>/dev/null || \
    ln -sf /usr/include/aarch64-linux-gnu/openssl/configuration.h /usr/include/openssl/configuration.h 2>/dev/null || true

WORKDIR /app

# Copy source code
COPY . .

# Initialize and update git submodules
RUN git submodule update --init --recursive

# Generate self-signed certificates for testing
RUN mkdir -p certs && \
    openssl req -x509 -newkey rsa:2048 \
        -keyout certs/server.key -out certs/server.crt \
        -days 365 -nodes \
        -subj "/C=US/ST=Test/L=Test/O=Blitz/CN=localhost"

# Build the QUIC handshake server
RUN echo "=== Building QUIC handshake server ===" && \
    zig build run-quic-handshake && \
    ls -la zig-out/bin/blitz-quic-handshake

# ─────────────────────────────────────────────────────────────
# 4. Minimal runtime base
# ─────────────────────────────────────────────────────────────

FROM ubuntu:${UBUNTU_VERSION} AS runtime-base

# Install minimal runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy PicoTLS libraries from builder
COPY --from=picotls-builder /usr/local/lib /usr/local/lib
COPY --from=picotls-builder /usr/local/include /usr/local/include

# Set library path for dynamic linking
ENV LD_LIBRARY_PATH=/usr/local/lib

WORKDIR /app

# ─────────────────────────────────────────────────────────────
# 5. Production QUIC server (default target)
# ─────────────────────────────────────────────────────────────

FROM runtime-base AS prod

# Copy the compiled binary
COPY --from=app-builder /app/zig-out/bin/blitz-quic-handshake /app/blitz-quic-handshake

# Copy certificates
COPY --from=app-builder /app/certs /app/certs

# Expose QUIC port
EXPOSE 8443/udp

# Health check for QUIC connectivity
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD nc -zu localhost 8443 || exit 1

# Default command
CMD ["/app/blitz-quic-handshake"]

# ─────────────────────────────────────────────────────────────
# 6. Development/Testing QUIC server (with extra tools)
# ─────────────────────────────────────────────────────────────

FROM runtime-base AS dev

# Install additional development/testing tools
RUN apt-get update && apt-get install -y \
    libssl3 \
    liburing-dev \
    pkg-config \
    netcat-openbsd \
    net-tools \
    curl \
    && rm -rf /var/lib/apt/lists/* && \
    # Create symlinks for cross-architecture compatibility
    mkdir -p /usr/lib && \
    (ln -sf /usr/lib/x86_64-linux-gnu/libcrypto.so* /usr/lib/ 2>/dev/null || true) && \
    (ln -sf /usr/lib/x86_64-linux-gnu/libssl.so* /usr/lib/ 2>/dev/null || true) && \
    (ln -sf /usr/lib/x86_64-linux-gnu/liburing.so* /usr/lib/ 2>/dev/null || true) && \
    ldconfig

# Copy the compiled binary
COPY --from=app-builder /app/zig-out/bin/blitz-quic-handshake /app/blitz-quic-handshake

# Copy certificates
COPY --from=app-builder /app/certs /app/certs

# Copy source for development (optional)
COPY --from=app-builder /app/src /app/src
COPY --from=app-builder /app/build.zig /app/build.zig

# Expose multiple ports for testing
EXPOSE 8080/tcp 8443/udp 8444/tcp

# Health check that tests both UDP and TCP
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD nc -zu localhost 8443 && nc -z localhost 8444 || exit 1

# Default command (same as prod)
CMD ["/app/blitz-quic-handshake"]

# ─────────────────────────────────────────────────────────────
# 7. Minimal scratch variant (ultra-small)
# ─────────────────────────────────────────────────────────────

FROM scratch AS minimal

# Copy only the essential binary and certificates
COPY --from=app-builder /app/zig-out/bin/blitz-quic-handshake /blitz-quic-handshake
COPY --from=app-builder /app/certs /certs

# Expose QUIC port
EXPOSE 8443/udp

# Run directly (no shell)
ENTRYPOINT ["/blitz-quic-handshake"]

# ─────────────────────────────────────────────────────────────
# Default target is production
# ─────────────────────────────────────────────────────────────

FROM prod
