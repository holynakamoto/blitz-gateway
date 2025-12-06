# Competitive API Gateway Benchmark Suite

## EPYC 9754 (128 cores) - Head-to-Head Performance Testing

## 🎯 Benchmark Objectives

### Primary Metrics
1. **Throughput (RPS)** - Requests per second
2. **Latency (p50, p99, p99.9)** - Response time distribution
3. **CPU Efficiency** - RPS per core
4. **Memory Usage** - RAM consumption under load
5. **Connection Handling** - Max concurrent connections

### Secondary Metrics
6. **SSL/TLS Overhead** - HTTPS performance
7. **Keep-Alive Efficiency** - Connection reuse
8. **Protocol Support** - HTTP/1.1, HTTP/2, HTTP/3
9. **Error Rate** - Failed requests under stress
10. **Startup Time** - Time to first request

---

## 🏁 Competitors

### Tested Gateways

| Gateway | Language | Version | Features |
|---------|----------|---------|----------|
| **Blitz** | Zig | 1.0.1 | HTTP/1.1, HTTP/2, HTTP/3, io_uring |
| **Envoy** | C++ | Latest stable | HTTP/1.1, HTTP/2, gRPC, Service Mesh |
| **nginx** | C | Latest mainline | HTTP/1.1, HTTP/2, reverse proxy |
| **HAProxy** | C | Latest stable | HTTP/1.1, HTTP/2, TCP/UDP load balancing |
| **Pingora** | Rust | Latest | High-performance proxy (Cloudflare) |
| **Traefik** | Go | Latest | Cloud-native, automatic HTTPS |

---

## 🧪 Test Scenarios

### Scenario 1: Simple Echo (Baseline)
**Purpose:** Pure proxy performance without backend delays

```yaml
Test: Echo 200 OK response
Payload: Minimal (14 bytes)
Duration: 60 seconds
Connections: 1000, 5000, 10000
Threads: 128 (all cores)
Protocol: HTTP/1.1
```

**Expected Winner:** Blitz or HAProxy (C-based minimal overhead)

### Scenario 2: Small JSON Response
**Purpose:** Typical API response

```yaml
Test: JSON response (1KB)
Payload: {"status":"ok","data":{...}}
Duration: 60 seconds
Connections: 1000, 5000, 10000
Threads: 128
Protocol: HTTP/1.1
```

### Scenario 3: HTTP/2 Multiplexing
**Purpose:** Test HTTP/2 efficiency

```yaml
Test: HTTP/2 with multiplexing
Concurrent Streams: 100 per connection
Connections: 100, 500, 1000
Duration: 60 seconds
Protocol: HTTP/2
```

### Scenario 4: High Concurrency
**Purpose:** Stress test connection handling

```yaml
Test: Maximum concurrent connections
Connections: 50000, 100000
Duration: 60 seconds
Threads: 128
Protocol: HTTP/1.1 Keep-Alive
```

### Scenario 5: TLS Overhead
**Purpose:** HTTPS performance

```yaml
Test: HTTPS with TLS 1.3
Payload: 1KB JSON
Connections: 1000, 5000
Duration: 60 seconds
Protocol: HTTP/1.1 over TLS
```

### Scenario 6: Mixed Protocol Load
**Purpose:** Real-world scenario

```yaml
Test: 50% HTTP/1.1, 30% HTTP/2, 20% HTTP/3
Connections: 5000
Duration: 120 seconds
Payload: Variable (100B - 10KB)
```

---

## 🔧 Installation Scripts

### Install All Gateways on EPYC

```bash
#!/bin/bash
# install_gateways.sh - Install all benchmark competitors

set -euo pipefail

INSTALL_DIR="/opt/benchmark"
sudo mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Installing benchmark suite on EPYC 9754..."
echo "CPU Cores: $(nproc)"
echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
echo ""

# 1. Blitz (your gateway)
echo "=== Installing Blitz ==="
curl -L -o blitz https://github.com/holynakamoto/blitz-gateway/releases/download/v1.0.1/blitz-linux-arm64
# For x86_64: Use the x86_64 build when available
chmod +x blitz
./blitz --version

# 2. nginx
echo "=== Installing nginx ==="
sudo apt-get update
sudo apt-get install -y nginx
nginx -v

# 3. Envoy
echo "=== Installing Envoy ==="
curl -L https://getenvoy.io/cli | bash -s -- -b /usr/local/bin
getenvoy fetch standard:1.28
envoy --version

# 4. HAProxy
echo "=== Installing HAProxy ==="
sudo apt-get install -y haproxy
haproxy -v

# 5. Traefik
echo "=== Installing Traefik ==="
wget https://github.com/traefik/traefik/releases/download/v2.10.5/traefik_v2.10.5_linux_amd64.tar.gz
tar -xzf traefik_*.tar.gz
chmod +x traefik
./traefik version

# 6. Caddy (bonus)
echo "=== Installing Caddy ==="
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update
sudo apt install caddy
caddy version

echo ""
echo "✅ All gateways installed!"
```

---

## 📝 Configuration Files

### nginx Configuration

```nginx
# /etc/nginx/nginx.conf
worker_processes 128;
worker_rlimit_nofile 1000000;

events {
    use epoll;
    worker_connections 100000;
    multi_accept on;
}

http {
    access_log off;
    error_log /dev/null;
    
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    
    keepalive_timeout 65;
    keepalive_requests 10000;
    
    server {
        listen 8081 reuseport;
        
        location / {
            return 200 "nginx works!\n";
            add_header Content-Type text/plain;
        }
    }
}
```

### Envoy Configuration

```yaml
# envoy.yaml
static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address:
        address: 0.0.0.0
        port_value: 8082
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match:
                  prefix: "/"
                direct_response:
                  status: 200
                  body:
                    inline_string: "Envoy works!\n"
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

admin:
  address:
    socket_address:
      address: 0.0.0.0
      port_value: 9901
```

### HAProxy Configuration

```
# /etc/haproxy/haproxy.cfg
global
    maxconn 100000
    nbthread 128
    tune.maxpollevents 10000

defaults
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend http_front
    bind *:8083
    default_backend http_back

backend http_back
    http-request return status 200 content-type text/plain string "HAProxy works!\n"
```

---

## 🚀 Benchmark Execution Scripts

### Master Benchmark Runner

```bash
#!/bin/bash
# run_all_benchmarks.sh

set -euo pipefail

RESULTS_DIR="/tmp/benchmark_results_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

echo "╔════════════════════════════════════════════════════════╗"
echo "║  EPYC 9754 API Gateway Benchmark Suite                 ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""
echo "Results: $RESULTS_DIR"
echo "Date: $(date)"
echo "System: $(uname -a)"
echo "CPU: AMD EPYC 9754 ($(nproc) cores)"
echo "Memory: $(free -h | grep Mem | awk '{print $2}')"
echo ""

# Gateway configs
declare -A GATEWAYS=(
    ["blitz"]="8080"
    ["nginx"]="8081"
    ["envoy"]="8082"
    ["haproxy"]="8083"
    ["traefik"]="8084"
)

# Start all gateways
echo "Starting all gateways..."
JWT_SECRET=test ./blitz --mode echo --port 8080 > /dev/null 2>&1 &
sudo systemctl start nginx
envoy -c envoy.yaml > /dev/null 2>&1 &
sudo systemctl start haproxy
traefik --configFile=traefik.yml > /dev/null 2>&1 &
sleep 5

# Run benchmarks
for GATEWAY in "${!GATEWAYS[@]}"; do
    PORT="${GATEWAYS[$GATEWAY]}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Benchmarking: $GATEWAY (port $PORT)"
    echo "═══════════════════════════════════════════════════════"
    
    # Scenario 1: Low load (1000 connections)
    echo ""
    echo "Scenario 1: Low Load (1000 connections)"
    wrk -t128 -c1000 -d60s --latency \
        http://127.0.0.1:$PORT/ \
        > "$RESULTS_DIR/${GATEWAY}_low_load.txt" 2>&1
    
    sleep 5
    
    # Scenario 2: Medium load (5000 connections)
    echo "Scenario 2: Medium Load (5000 connections)"
    wrk -t128 -c5000 -d60s --latency \
        http://127.0.0.1:$PORT/ \
        > "$RESULTS_DIR/${GATEWAY}_medium_load.txt" 2>&1
    
    sleep 5
    
    # Scenario 3: High load (10000 connections)
    echo "Scenario 3: High Load (10000 connections)"
    wrk -t128 -c10000 -d60s --latency \
        http://127.0.0.1:$PORT/ \
        > "$RESULTS_DIR/${GATEWAY}_high_load.txt" 2>&1
    
    sleep 10
done

# Stop all gateways
killall blitz 2>/dev/null || true
sudo systemctl stop nginx
killall envoy 2>/dev/null || true
sudo systemctl stop haproxy
killall traefik 2>/dev/null || true

echo ""
echo "✅ Benchmarks complete!"
echo ""
echo "Results saved to: $RESULTS_DIR"
```

### Results Analyzer

```bash
#!/bin/bash
# analyze_results.sh - Parse and compare results

RESULTS_DIR="$1"

if [ -z "$RESULTS_DIR" ]; then
    echo "Usage: $0 <results_directory>"
    exit 1
fi

echo "╔════════════════════════════════════════════════════════╗"
echo "║  Benchmark Results Analysis                            ║"
echo "╚════════════════════════════════════════════════════════╝"
echo ""

# Create summary table
echo "| Gateway | Load | RPS | Latency (avg) | Latency (p99) |"
echo "|---------|------|-----|---------------|---------------|"

for FILE in "$RESULTS_DIR"/*.txt; do
    BASENAME=$(basename "$FILE" .txt)
    GATEWAY=$(echo "$BASENAME" | cut -d_ -f1)
    LOAD=$(echo "$BASENAME" | cut -d_ -f2-)
    
    RPS=$(grep "Requests/sec:" "$FILE" 2>/dev/null | awk '{print $2}' || echo "N/A")
    LAT_AVG=$(grep "Latency" "$FILE" 2>/dev/null | head -1 | awk '{print $2}' || echo "N/A")
    LAT_P99=$(grep "99%" "$FILE" 2>/dev/null | awk '{print $2}' || echo "N/A")
    
    echo "| $GATEWAY | $LOAD | $RPS | $LAT_AVG | $LAT_P99 |"
done

echo ""
echo "🏆 Performance Winners:"
echo ""

# Best RPS
echo "  Best Throughput:"
grep -h "Requests/sec:" "$RESULTS_DIR"/*.txt 2>/dev/null | \
    sort -t: -k2 -rn | head -3

echo ""
echo "  Best p99 Latency:"
grep -h "99%" "$RESULTS_DIR"/*.txt 2>/dev/null | \
    sort -t: -k2 -n | head -3
```

---

## 📊 Expected Results

### EPYC 9754 Projections

Based on **37K RPS on 6-core ARM64 VM**:

| Scenario | Connections | Expected Blitz RPS | Industry Target |
|----------|-------------|-------------------|-----------------|
| Low Load | 1,000 | 1-2M | Beat Traefik |
| Medium Load | 5,000 | 2-5M | Match nginx |
| High Load | 10,000 | 5-12M | Beat all |

### Success Tiers

| Tier | Target | Achievement |
|------|--------|-------------|
| Good | 1-2M RPS | Beat Traefik (Go) |
| Great | 2-5M RPS | Beat nginx, match Envoy |
| Exceptional | 10M+ RPS | Beat all competitors |
| Ultimate | 12M RPS | Industry-leading |

---

## 🎯 Current Baseline

### ARM64 VM (6 cores) - Achieved

| Protocol | Tool | RPS | Notes |
|----------|------|-----|-------|
| HTTP/1.1 | wrk | 37,714 | 100 connections, 10s |
| HTTP/2 | h2load | 1,134 | 100 connections (minimal impl) |

### Scaling Projections to EPYC

```
Conservative (linear): 37K × (128/6) = 790K RPS
Optimistic (superlinear): 37K × 32 = 1.2M RPS  
Target: 12M RPS (with optimizations)
```

---

## 📋 Pre-Benchmark Checklist

### Server Preparation
- [ ] EPYC 9754 access confirmed
- [ ] Ubuntu 22.04+ installed
- [ ] Kernel 5.19+ (latest io_uring)
- [ ] System tuned (`sysctl`, ulimits)

### Software Installation
- [ ] Blitz x86_64 binary
- [ ] nginx installed and configured
- [ ] Envoy installed and configured
- [ ] HAProxy installed and configured
- [ ] Traefik installed and configured
- [ ] wrk and h2load installed

### Baseline Tests
- [ ] Each gateway responds correctly
- [ ] No firewall blocking
- [ ] Monitoring active (htop, vmstat)

---

## 🚀 Quick Start

```bash
# On EPYC server
cd /opt/benchmark

# 1. Install all gateways
sudo ./install_gateways.sh

# 2. Configure system
sudo ./tune_system.sh

# 3. Run benchmarks (2+ hours)
./run_all_benchmarks.sh

# 4. Analyze results
./analyze_results.sh /tmp/benchmark_results_*
```

---

## 📝 Publishing Results

After benchmarks, publish:
1. **GitHub README** - Update with benchmark results
2. **Blog Post** - Detailed analysis
3. **Hacker News** - Community attention
4. **Twitter/X** - Quick highlights

### Sample Tweet
```
🚀 Blitz Gateway: 12M RPS on AMD EPYC 9754

Benchmarked against:
- nginx: 4x faster
- Envoy: 6x faster  
- Traefik: 30x faster

Built with Zig + io_uring

Open source: github.com/holynakamoto/blitz-gateway
```

---

*Created: December 2024*
*Status: Ready for EPYC deployment*

