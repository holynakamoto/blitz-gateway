#!/bin/bash
# Blitz Gateway Local Benchmark Script
# Comprehensive performance testing for development and CI

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
BENCH_DIR="$PROJECT_ROOT/benches"
RESULTS_DIR="$BENCH_DIR/results/$(date +%Y%m%d_%H%M%S)"
CONFIG_FILE="$BENCH_DIR/config.toml"

# Default values
DURATION="${DURATION:-30}"
CONNECTIONS="${CONNECTIONS:-100}"
THREADS="${THREADS:-$(nproc)}"
HOST="${HOST:-localhost}"
PORT="${PORT:-8080}"
PROTOCOL="${PROTOCOL:-http}"
TLS="${TLS:-false}"
RATE_LIMIT="${RATE_LIMIT:-0}"
QUIC="${QUIC:-false}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Ensure required tools are installed
check_dependencies() {
    local missing_tools=()

    # Check for load testing tools
    if ! command -v wrk &> /dev/null && ! command -v hey &> /dev/null && ! command -v bombardier &> /dev/null; then
        missing_tools+=("wrk or hey or bombardier")
    fi

    # Check for HTTP clients
    if ! command -v curl &> /dev/null; then
        missing_tools+=("curl")
    fi

    # Check for system monitoring
    if ! command -v htop &> /dev/null && ! command -v top &> /dev/null; then
        missing_tools+=("htop or top")
    fi

    # Check for performance monitoring
    if ! command -v perf &> /dev/null; then
        log_warning "perf not found - some profiling features will be limited"
    fi

    if [ ${#missing_tools[@]} -ne 0 ]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_info "Install with: sudo apt-get install wrk curl htop linux-tools-common"
        exit 1
    fi

    log_success "All dependencies satisfied"
}

# Setup benchmark environment
setup_environment() {
    log_info "Setting up benchmark environment..."

    # Create results directory
    mkdir -p "$RESULTS_DIR"

    # Create config file if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        log_warning "Creating default benchmark config: $CONFIG_FILE"
        cat > "$CONFIG_FILE" << EOF
# Blitz Gateway Benchmark Configuration

[benchmark]
name = "local-development"
description = "Local development benchmark suite"
duration_seconds = $DURATION
warmup_seconds = 10
cooldown_seconds = 5

[server]
host = "$HOST"
port = $PORT
protocol = "$PROTOCOL"
tls_enabled = $TLS
quic_enabled = $QUIC

[load_test]
connections = $CONNECTIONS
threads = $THREADS
rate_limit = $RATE_LIMIT

[scenarios.http_basic]
name = "HTTP Basic Load Test"
method = "GET"
path = "/"
headers = ["Accept: application/json", "User-Agent: Blitz-Benchmark/1.0"]
body = ""

[scenarios.http_post]
name = "HTTP POST Load Test"
method = "POST"
path = "/api/test"
headers = ["Content-Type: application/json", "Accept: application/json"]
body = '{"test": "data", "timestamp": "2024-01-01T00:00:00Z"}'

[scenarios.websocket]
name = "WebSocket Load Test"
enabled = false
path = "/ws"
messages = 1000
message_size = 1024

[metrics]
collect_system_metrics = true
collect_server_metrics = true
export_prometheus = false
prometheus_gateway = "http://localhost:9091"
EOF
    fi

    # Setup system monitoring
    if command -v htop &> /dev/null; then
        log_info "Starting system monitoring..."
        htop --version > /dev/null 2>&1 || true
    fi

    log_success "Environment setup complete"
}

# Start Blitz Gateway server
start_server() {
    log_info "Starting Blitz Gateway server..."

    cd "$PROJECT_ROOT"

    # Build optimized binary
    if [ ! -f "zig-out/bin/blitz" ]; then
        log_info "Building optimized binary..."
        zig build -Doptimize=ReleaseFast
    fi

    # Check if server is already running
    if pgrep -f "blitz" > /dev/null; then
        log_warning "Server already running, stopping it first..."
        pkill -f "blitz" || true
        sleep 2
    fi

    # Start server
    log_info "Starting server on $HOST:$PORT..."
    export QUIC_LOG=error
    export METRICS_ENABLED=true
    export METRICS_PORT=9090

    if [ "$TLS" = "true" ]; then
        # Generate test certificates if they don't exist
        if [ ! -f "certs/server.crt" ]; then
            log_info "Generating test certificates..."
            mkdir -p certs
            openssl req -x509 -newkey rsa:2048 \
                -keyout certs/server.key -out certs/server.crt \
                -days 1 -nodes \
                -subj "/C=US/ST=Test/L=Test/O=Blitz/CN=localhost"
        fi
        export TLS_CERT_PATH="$PROJECT_ROOT/certs/server.crt"
        export TLS_KEY_PATH="$PROJECT_ROOT/certs/server.key"
    fi

    # Start server in background
    ./zig-out/bin/blitz > "$RESULTS_DIR/server.log" 2>&1 &
    SERVER_PID=$!

    # Wait for server to start
    local retries=0
    while ! curl -f -s "http://$HOST:$PORT/health" > /dev/null 2>&1; do
        if [ $retries -ge 30 ]; then
            log_error "Server failed to start within 30 seconds"
            cat "$RESULTS_DIR/server.log"
            exit 1
        fi
        sleep 1
        retries=$((retries + 1))
    done

    log_success "Server started successfully (PID: $SERVER_PID)"
    echo "$SERVER_PID" > "$RESULTS_DIR/server.pid"
}

# Run load tests
run_load_tests() {
    log_info "Running load tests..."

    local results_file="$RESULTS_DIR/load_test_results.json"
    local summary_file="$RESULTS_DIR/summary.txt"

    # Initialize results
    echo "{}" > "$results_file"

    # Test basic endpoints
    log_info "Testing basic endpoints..."
    test_endpoint "/" "GET" "" "Basic homepage test"
    test_endpoint "/health" "GET" "" "Health check test"

    # Run load tests with different tools
    if command -v wrk &> /dev/null; then
        log_info "Running WRK load test..."
        run_wrk_test
    elif command -v hey &> /dev/null; then
        log_info "Running hey load test..."
        run_hey_test
    elif command -v bombardier &> /dev/null; then
        log_info "Running bombardier load test..."
        run_bombardier_test
    else
        log_warning "No load testing tool available, skipping load tests"
    fi

    # Generate summary
    generate_summary
}

# Test individual endpoint
test_endpoint() {
    local path="$1"
    local method="$2"
    local data="$3"
    local description="$4"

    local url
    if [ "$TLS" = "true" ]; then
        url="https://$HOST:$PORT$path"
    else
        url="http://$HOST:$PORT$path"
    fi

    log_info "Testing $description: $method $url"

    local response
    local status

    if [ "$method" = "POST" ] && [ -n "$data" ]; then
        response=$(curl -s -w "HTTPSTATUS:%{http_code};" -X POST -H "Content-Type: application/json" -d "$data" "$url")
    else
        response=$(curl -s -w "HTTPSTATUS:%{http_code};" "$url")
    fi

    status=$(echo "$response" | tr -d '\n' | sed -e 's/.*HTTPSTATUS://')
    body=$(echo "$response" | sed -e 's/HTTPSTATUS:.*//g')

    if [ "$status" = "200" ] || [ "$status" = "404" ]; then
        log_success "✓ $description passed (Status: $status)"
    else
        log_error "✗ $description failed (Status: $status)"
        echo "Response: $body" >> "$RESULTS_DIR/errors.log"
    fi
}

# Run WRK load test
run_wrk_test() {
    local wrk_results="$RESULTS_DIR/wrk_results.txt"
    local url

    if [ "$TLS" = "true" ]; then
        url="https://$HOST:$PORT/"
    else
        url="http://$HOST:$PORT/"
    fi

    log_info "Running WRK test: $DURATION seconds, $CONNECTIONS connections"

    wrk -t"$THREADS" -c"$CONNECTIONS" -d"$DURATION"s --latency "$url" > "$wrk_results"

    if [ $? -eq 0 ]; then
        log_success "WRK test completed successfully"
        cat "$wrk_results"
    else
        log_error "WRK test failed"
        cat "$wrk_results"
    fi
}

# Run hey load test
run_hey_test() {
    local hey_results="$RESULTS_DIR/hey_results.txt"
    local url

    if [ "$TLS" = "true" ]; then
        url="https://$HOST:$PORT/"
    else
        url="http://$HOST:$PORT/"
    fi

    log_info "Running hey test: $DURATION seconds, $CONNECTIONS connections"

    hey -n 10000 -c "$CONNECTIONS" -q 10 -t 10 "$url" > "$hey_results"

    if [ $? -eq 0 ]; then
        log_success "hey test completed successfully"
        cat "$hey_results"
    else
        log_error "hey test failed"
        cat "$hey_results"
    fi
}

# Run bombardier load test
run_bombardier_test() {
    local bombardier_results="$RESULTS_DIR/bombardier_results.txt"
    local url

    if [ "$TLS" = "true" ]; then
        url="https://$HOST:$PORT/"
    else
        url="http://$HOST:$PORT/"
    fi

    log_info "Running bombardier test: $DURATION seconds, $CONNECTIONS connections"

    bombardier -c "$CONNECTIONS" -n 10000 -t 10s "$url" > "$bombardier_results"

    if [ $? -eq 0 ]; then
        log_success "bombardier test completed successfully"
        cat "$bombardier_results"
    else
        log_error "bombardier test failed"
        cat "$bombardier_results"
    fi
}

# Collect system metrics
collect_system_metrics() {
    log_info "Collecting system metrics..."

    local metrics_file="$RESULTS_DIR/system_metrics.txt"

    {
        echo "=== System Information ==="
        uname -a
        echo ""

        echo "=== CPU Information ==="
        lscpu | head -10
        echo ""

        echo "=== Memory Information ==="
        free -h
        echo ""

        echo "=== Network Information ==="
        ip addr show | grep -E "(inet|inet6)" | head -5
        echo ""

        echo "=== Disk Information ==="
        df -h
        echo ""

        echo "=== Process Information ==="
        ps aux --sort=-%cpu | head -10
        echo ""

    } > "$metrics_file"

    log_success "System metrics collected"
}

# Generate benchmark summary
generate_summary() {
    local summary_file="$RESULTS_DIR/summary.txt"

    {
        echo "========================================"
        echo "Blitz Gateway Benchmark Summary"
        echo "========================================"
        echo "Date: $(date)"
        echo "Duration: ${DURATION}s"
        echo "Connections: $CONNECTIONS"
        echo "Threads: $THREADS"
        echo "Host: $HOST:$PORT"
        echo "Protocol: $PROTOCOL"
        echo "TLS: $TLS"
        echo "========================================"
        echo ""

        if [ -f "$RESULTS_DIR/wrk_results.txt" ]; then
            echo "WRK Results:"
            grep -E "(Latency|Req/Sec|Requests/sec)" "$RESULTS_DIR/wrk_results.txt" || echo "No WRK results found"
            echo ""
        fi

        if [ -f "$RESULTS_DIR/hey_results.txt" ]; then
            echo "hey Results:"
            grep -E "(response time|Requests/sec|Status code)" "$RESULTS_DIR/hey_results.txt" || echo "No hey results found"
            echo ""
        fi

        if [ -f "$RESULTS_DIR/bombardier_results.txt" ]; then
            echo "bombardier Results:"
            grep -E "(Requests/sec|Latency|Throughput)" "$RESULTS_DIR/bombardier_results.txt" || echo "No bombardier results found"
            echo ""
        fi

        echo "========================================"
        echo "Raw results saved to: $RESULTS_DIR"
        echo "========================================"

    } > "$summary_file"

    log_success "Summary generated: $summary_file"
    cat "$summary_file"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up..."

    # Stop server if it's running
    if [ -f "$RESULTS_DIR/server.pid" ]; then
        local server_pid=$(cat "$RESULTS_DIR/server.pid")
        if kill -0 "$server_pid" 2>/dev/null; then
            log_info "Stopping server (PID: $server_pid)"
            kill "$server_pid"
            sleep 2
            if kill -0 "$server_pid" 2>/dev/null; then
                kill -9 "$server_pid" 2>/dev/null || true
            fi
        fi
    fi

    # Kill any remaining benchmark processes
    pkill -f "wrk|hey|bombardier" || true

    log_success "Cleanup complete"
}

# Main function
main() {
    log_info "Starting Blitz Gateway Benchmark Suite"
    log_info "Results will be saved to: $RESULTS_DIR"

    # Set up signal handlers
    trap cleanup EXIT INT TERM

    # Run benchmark suite
    check_dependencies
    setup_environment
    start_server
    collect_system_metrics
    run_load_tests

    log_success "Benchmark suite completed successfully!"
    log_info "Results: $RESULTS_DIR"
    log_info "Summary: $RESULTS_DIR/summary.txt"
}

# Run main function with all arguments
main "$@"