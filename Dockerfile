# --------------------------
# Stage 1: Build Stage
# --------------------------
FROM ubuntu:22.04 AS builder

# --------------------------
# Install build dependencies
# --------------------------
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    pkg-config \
    git \
    curl \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# --------------------------
# Install Zig (0.15.2 - latest stable)
# --------------------------
RUN curl -L https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
    -o /tmp/zig.tar.xz && \
    tar -xf /tmp/zig.tar.xz -C /opt && \
    ln -s /opt/zig-x86_64-linux-0.15.2/zig /usr/local/bin/zig

# --------------------------
# Build PicoTLS (with OpenSSL for cert loading)
# --------------------------
RUN git clone --recursive https://github.com/h2o/picotls /tmp/picotls && \
    cd /tmp/picotls && \
    cmake -B build \
        -DWITH_OPENSSL=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DBUILD_TESTING=OFF \
        . && \
    cmake --build build --config Release && \
    find build/ -name "*.a" -exec cp {} /usr/local/lib/ \; && \
    cp -r include/* /usr/local/include/

# --------------------------
# Stage 2: Application build
# --------------------------
FROM builder AS app-build

# Ensure OpenSSL headers are available
RUN apt-get update && apt-get install -y libssl-dev && \
    mkdir -p /usr/include/openssl && \
    ln -sf /usr/include/aarch64-linux-gnu/openssl/opensslconf.h /usr/include/openssl/opensslconf.h 2>/dev/null || true && \
    ln -sf /usr/include/aarch64-linux-gnu/openssl/configuration.h /usr/include/openssl/configuration.h 2>/dev/null || true && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy your QUIC project
COPY . .

# Create certs directory and generate certificates
RUN mkdir -p certs && \
    openssl req -x509 -newkey rsa:2048 \
        -keyout certs/server.key -out certs/server.crt \
        -days 365 -nodes \
        -subj "/C=US/ST=Test/L=Test/O=Blitz/CN=localhost"

# Build the QUIC handshake server
RUN cd /app && \
    echo "=== Building QUIC handshake server ===" && \
    zig build run-quic-handshake && \
    ls -la zig-out/bin/blitz-quic-handshake

# --------------------------
# Stage 3: Runtime Stage (minimal)
# --------------------------
FROM ubuntu:22.04 AS runtime

# Minimal runtime dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Copy PicoTLS library
COPY --from=builder /usr/local/lib /usr/local/lib
COPY --from=builder /usr/local/include /usr/local/include

# Copy compiled binary
COPY --from=app-build /app/zig-out/bin/blitz-quic-handshake /app/blitz-quic-handshake

# Set library path
ENV LD_LIBRARY_PATH=/usr/local/lib

# Expose QUIC/HTTP3 port
EXPOSE 8443/udp

CMD ["/app/blitz-quic-handshake"]
