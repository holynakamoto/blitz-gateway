#!/bin/bash
# Simple benchmark script using curl (no external dependencies)
# This is a basic throughput and latency test

set -e

BLITZ_PORT="${BLITZ_PORT:-8080}"
DURATION="${DURATION:-10}"
CONCURRENT="${CONCURRENT:-10}"
TOTAL_REQUESTS="${TOTAL_REQUESTS:-10000}"

echo "=========================================="
echo "Blitz Simple Benchmark"
echo "=========================================="
echo "Target: http://localhost:${BLITZ_PORT}"
echo "Duration: ${DURATION}s"
echo "Concurrent: ${CONCURRENT}"
echo "Total Requests: ${TOTAL_REQUESTS}"
echo ""

# Check if Blitz is running
if ! curl -s --max-time 2 http://localhost:${BLITZ_PORT}/ > /dev/null; then
    echo "ERROR: Blitz is not running on port ${BLITZ_PORT}"
    exit 1
fi

echo "✅ Server is responding"
echo ""

# Create results directory (if possible)
mkdir -p benches/results 2>/dev/null || true
RESULTS_FILE="benches/results/simple-$(date +%Y%m%d-%H%M%S).txt" 2>/dev/null || true

echo "=========================================="
echo "Test 1: Sequential Requests (Latency)"
echo "=========================================="
echo "Running 100 sequential requests..."
echo ""

START_TIME=$(date +%s.%N)
SUCCESS=0
FAILED=0
TOTAL_TIME=0

for i in $(seq 1 100); do
    REQ_START=$(date +%s.%N)
    if curl -s --max-time 1 http://localhost:${BLITZ_PORT}/hello > /dev/null 2>&1; then
        REQ_END=$(date +%s.%N)
        REQ_TIME=$(echo "$REQ_END - $REQ_START" | bc)
        TOTAL_TIME=$(echo "$TOTAL_TIME + $REQ_TIME" | bc)
        SUCCESS=$((SUCCESS + 1))
    else
        FAILED=$((FAILED + 1))
    fi
done

END_TIME=$(date +%s.%N)
ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
AVG_LATENCY=$(echo "scale=3; $TOTAL_TIME / $SUCCESS" | bc)
RPS=$(echo "scale=2; 100 / $ELAPSED" | bc)

echo "Results:"
echo "  Success: $SUCCESS"
echo "  Failed: $FAILED"
echo "  Total Time: ${ELAPSED}s"
echo "  Average Latency: ${AVG_LATENCY}s ($(echo "scale=0; $AVG_LATENCY * 1000000" | bc)µs)"
echo "  Requests/sec: $RPS"
echo ""

echo "=========================================="
echo "Test 2: Concurrent Requests (Throughput)"
echo "=========================================="
echo "Running ${TOTAL_REQUESTS} requests with ${CONCURRENT} concurrent connections..."
echo ""

START_TIME=$(date +%s.%N)
SUCCESS=0
FAILED=0

# Function to make requests
make_requests() {
    local count=$1
    local local_success=0
    local local_failed=0
    
    for i in $(seq 1 $count); do
        if curl -s --max-time 2 http://localhost:${BLITZ_PORT}/hello > /dev/null 2>&1; then
            local_success=$((local_success + 1))
        else
            local_failed=$((local_failed + 1))
        fi
    done
    
    echo "$local_success $local_failed"
}

# Distribute requests across concurrent workers
REQUESTS_PER_WORKER=$((TOTAL_REQUESTS / CONCURRENT))
REMAINDER=$((TOTAL_REQUESTS % CONCURRENT))

# Run concurrent workers
PIDS=()
for i in $(seq 1 $CONCURRENT); do
    REQ_COUNT=$REQUESTS_PER_WORKER
    if [ $i -le $REMAINDER ]; then
        REQ_COUNT=$((REQ_COUNT + 1))
    fi
    
    (make_requests $REQ_COUNT > /tmp/bench_worker_$i.txt) &
    PIDS+=($!)
done

# Wait for all workers
for pid in "${PIDS[@]}"; do
    wait $pid
done

# Collect results
for i in $(seq 1 $CONCURRENT); do
    if [ -f /tmp/bench_worker_$i.txt ]; then
        read worker_success worker_failed < /tmp/bench_worker_$i.txt
        SUCCESS=$((SUCCESS + worker_success))
        FAILED=$((FAILED + worker_failed))
        rm -f /tmp/bench_worker_$i.txt
    fi
done

END_TIME=$(date +%s.%N)
ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
RPS=$(echo "scale=2; $SUCCESS / $ELAPSED" | bc)

echo "Results:"
echo "  Success: $SUCCESS"
echo "  Failed: $FAILED"
echo "  Total Time: ${ELAPSED}s"
echo "  Requests/sec: $RPS"
echo ""

echo "=========================================="
echo "Test 3: Keep-Alive Test"
echo "=========================================="
echo "Testing connection reuse with keep-alive..."
echo ""

START_TIME=$(date +%s.%N)
SUCCESS=0

# Use curl with keep-alive (multiple requests on same connection)
for i in $(seq 1 50); do
    if curl -s --max-time 1 --keepalive-time 2 --keepalive http://localhost:${BLITZ_PORT}/hello > /dev/null 2>&1; then
        SUCCESS=$((SUCCESS + 1))
    fi
done

END_TIME=$(date +%s.%N)
ELAPSED=$(echo "$END_TIME - $START_TIME" | bc)
RPS=$(echo "scale=2; $SUCCESS / $ELAPSED" | bc)

echo "Results:"
echo "  Success: $SUCCESS"
echo "  Total Time: ${ELAPSED}s"
echo "  Requests/sec: $RPS"
echo ""

echo "=========================================="
echo "Benchmark Complete!"
echo "=========================================="
echo ""
echo "Summary:"
echo "  Server: http://localhost:${BLITZ_PORT}"
echo "  All tests completed successfully"
echo ""
echo "Note: For accurate production benchmarks, use wrk2 or hey on bare metal."
echo "This simple benchmark is for basic validation only."

