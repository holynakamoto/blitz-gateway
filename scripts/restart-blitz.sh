#!/bin/bash

set -e

echo "🔄 Restarting Blitz Server..."
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Function to check if port is in use
check_port() {
    if sudo lsof -ti:$1 > /dev/null 2>&1 || sudo ss -tlnp 2>/dev/null | grep -q ":$1 " || sudo netstat -tlnp 2>/dev/null | grep -q ":$1 "; then
        return 0  # Port is in use
    else
        return 1  # Port is free
    fi
}

# Kill old processes
echo "1. Checking for existing processes..."
if check_port 8080; then
    echo -e "${YELLOW}⚠️  Port 8080 is in use${NC}"
    echo "   Processes using port 8080:"
    sudo lsof -i :8080 2>/dev/null || sudo ss -tlnp 2>/dev/null | grep 8080 || echo "   (could not list processes)"
    echo ""
    echo "   Killing processes..."
    # Try multiple methods to free the port
    sudo fuser -k 8080/tcp 2>/dev/null || true
    sudo lsof -ti:8080 2>/dev/null | xargs sudo kill -9 2>/dev/null || true
    BLITZ_PIDS=$(pgrep -x blitz 2>/dev/null || true)
    if [ -n "$BLITZ_PIDS" ]; then
        kill -9 $BLITZ_PIDS 2>/dev/null || true
    fi
    sleep 2
    
    if check_port 8080; then
        echo -e "${RED}❌ Failed to free port 8080${NC}"
        echo "   Trying one more time..."
        sudo fuser -k 8080/tcp 2>/dev/null || true
        sleep 1
        if check_port 8080; then
            echo -e "${RED}❌ Still in use - please manually kill processes${NC}"
            exit 1
        fi
    fi
    echo -e "${GREEN}✅ Port 8080 freed${NC}"
else
    echo -e "${GREEN}✅ Port 8080 is free${NC}"
fi
echo ""

# Kill any blitz processes by name (but not this script)
echo "2. Checking for Blitz processes..."
BLITZ_PIDS=$(pgrep -x blitz 2>/dev/null || true)
if [ -n "$BLITZ_PIDS" ]; then
    echo "   Found Blitz processes: $BLITZ_PIDS"
    echo "   Killing..."
    kill -9 $BLITZ_PIDS 2>/dev/null || true
    sleep 1
    # Double-check
    REMAINING=$(pgrep -x blitz 2>/dev/null || true)
    if [ -n "$REMAINING" ]; then
        kill -9 $REMAINING 2>/dev/null || true
        sleep 1
    fi
fi
echo -e "${GREEN}✅ No Blitz processes running${NC}"
echo ""

# Clean PID file
echo "3. Cleaning PID file..."
rm -f /tmp/blitz.pid
echo -e "${GREEN}✅ PID file removed${NC}"
echo ""

# Build
echo "4. Building Blitz..."
cd /vagrant
if [ -f Makefile ]; then
    make clean
    make
else
    rm -rf zig-cache zig-out
    zig build -Doptimize=ReleaseFast
fi
echo -e "${GREEN}✅ Build complete${NC}"
echo ""

# Check binary exists
echo "5. Checking binary..."
if [ -f zig-out/bin/blitz ]; then
    echo -e "${GREEN}✅ Binary found: $(ls -lh zig-out/bin/blitz | awk '{print $5}')${NC}"
elif [ -f blitz ]; then
    echo -e "${GREEN}✅ Binary found: $(ls -lh blitz | awk '{print $5}')${NC}"
    mkdir -p zig-out/bin
    mv blitz zig-out/bin/
else
    echo -e "${RED}❌ Binary not found${NC}"
    exit 1
fi
echo ""

# Start server
echo "6. Starting Blitz server..."
# Use unbuffered output and ensure log file is created
rm -f /tmp/blitz.log
touch /tmp/blitz.log
# Use stdbuf to disable buffering so we see logs immediately
stdbuf -oL -eL ./zig-out/bin/blitz > /tmp/blitz.log 2>&1 &
BLITZ_PID=$!
echo $BLITZ_PID > /tmp/blitz.pid
echo "   Started with PID: $BLITZ_PID"
sleep 0.5  # Give it a moment to start
# Check if process died immediately
if ! kill -0 $BLITZ_PID 2>/dev/null; then
    echo -e "${RED}❌ Server process died immediately after starting!${NC}"
    echo ""
    echo "Server log:"
    cat /tmp/blitz.log 2>/dev/null || echo "(log file not found)"
    echo ""
    echo "Checking for crash signals..."
    dmesg | tail -20 | grep -i "blitz\|segfault\|killed" || echo "(no crash messages found)"
    exit 1
fi
echo ""

# Wait for server to start
echo "7. Waiting for server to start..."
RETRIES=10
for i in $(seq 1 $RETRIES); do
    sleep 1
    
    # Debug: Check if process is still running
    if ! kill -0 $BLITZ_PID 2>/dev/null; then
        echo -e "${RED}❌ Server process (PID $BLITZ_PID) has died!${NC}"
        echo ""
        echo "Server log:"
        cat /tmp/blitz.log 2>/dev/null || echo "(log file not found)"
        echo ""
        echo "Process status:"
        ps aux | grep -E "blitz|$BLITZ_PID" | grep -v grep || echo "(no matching processes)"
        exit 1
    fi
    
    if check_port 8080; then
        echo -e "${GREEN}✅ Server is listening on port 8080${NC}"
        break
    fi
    
    if [ $i -eq $RETRIES ]; then
        echo -e "${RED}❌ Server failed to start${NC}"
        echo ""
        echo "Debug info:"
        echo "  PID: $BLITZ_PID"
        echo "  Process running: $(kill -0 $BLITZ_PID 2>/dev/null && echo 'yes' || echo 'no')"
        echo "  Port 8080 in use: $(check_port 8080 && echo 'yes' || echo 'no')"
        echo ""
        echo "Server log:"
        cat /tmp/blitz.log 2>/dev/null || echo "(log file not found or empty)"
        echo ""
        echo "Process status:"
        ps aux | grep -E "blitz|$BLITZ_PID" | grep -v grep || echo "(no matching processes)"
        exit 1
    fi
    
    echo -n "."
done
echo ""

# Debug: Verify process is still running
echo "7.5. Verifying server process..."
if ! kill -0 $BLITZ_PID 2>/dev/null; then
    echo -e "${RED}❌ Server process died after starting!${NC}"
    echo ""
    echo "Server log:"
    cat /tmp/blitz.log 2>/dev/null || echo "(log file not found)"
    exit 1
fi
echo -e "${GREEN}✅ Process is running (PID: $BLITZ_PID)${NC}"

# Debug: Show initial log output
echo ""
echo "7.6. Initial server log output:"
sleep 2  # Give server time to write initial logs

# Check if process is still alive
if ! kill -0 $BLITZ_PID 2>/dev/null; then
    echo -e "${RED}❌ Server process died!${NC}"
    echo ""
    echo "Server log (last 50 lines):"
    tail -50 /tmp/blitz.log 2>/dev/null || cat /tmp/blitz.log 2>/dev/null || echo "(log file not found)"
    echo ""
    echo "Checking for crash signals..."
    dmesg | tail -20 | grep -i "blitz\|segfault\|killed" || echo "(no crash messages found)"
    exit 1
fi

if [ -f /tmp/blitz.log ]; then
    if [ -s /tmp/blitz.log ]; then
        echo "  Log file size: $(wc -l < /tmp/blitz.log) lines, $(wc -c < /tmp/blitz.log) bytes"
        cat /tmp/blitz.log
    else
        echo -e "${YELLOW}⚠️  Log file is empty - this is unusual${NC}"
        echo "  Process status: $(ps -p $BLITZ_PID -o stat= 2>/dev/null || echo 'dead')"
        echo "  Checking if server is stuck..."
        # Try to see what the process is doing
        if command -v strace >/dev/null 2>&1; then
            echo "  (Run 'strace -p $BLITZ_PID' to see what it's doing)"
        fi
    fi
else
    echo "  (log file does not exist)"
fi
echo ""

# Test server
echo "8. Testing server..."
sleep 1

# Debug: Try to connect and show detailed output
echo "8.1. Testing connection..."
echo "  (this may take a few seconds if server is not responding)..."
# Use timeout to prevent hanging forever
CURL_OUTPUT=$(timeout 5 curl -s -w "\nHTTP_CODE:%{http_code}\nTIME:%{time_total}\n" --connect-timeout 3 --max-time 5 http://localhost:8080 2>&1)
CURL_EXIT=$?

if [ $CURL_EXIT -eq 0 ]; then
    HTTP_CODE=$(echo "$CURL_OUTPUT" | grep "HTTP_CODE:" | cut -d: -f2)
    if [ "$HTTP_CODE" = "200" ] || [ -n "$(echo "$CURL_OUTPUT" | grep -i "hello\|blitz")" ]; then
        echo -e "${GREEN}✅ Server is responding!${NC}"
        echo ""
        echo "Response:"
        echo "$CURL_OUTPUT" | grep -v "HTTP_CODE:\|TIME:" | head -5
    else
        echo -e "${YELLOW}⚠️  Server responded but with unexpected status (HTTP $HTTP_CODE)${NC}"
        echo ""
        echo "Response:"
        echo "$CURL_OUTPUT" | grep -v "HTTP_CODE:\|TIME:" | head -10
    fi
else
    echo -e "${RED}❌ Server is not responding${NC}"
    echo ""
    echo "Curl exit code: $CURL_EXIT"
    echo "Curl output:"
    echo "$CURL_OUTPUT"
    echo ""
    echo "Debug info:"
    echo "  PID: $BLITZ_PID"
    echo "  Process running: $(kill -0 $BLITZ_PID 2>/dev/null && echo 'yes' || echo 'no')"
    echo "  Port 8080 in use: $(check_port 8080 && echo 'yes' || echo 'no')"
    echo ""
    echo "Server log:"
    cat /tmp/blitz.log 2>/dev/null || echo "(log file not found or empty)"
    echo ""
    echo "Process status:"
    ps aux | grep -E "blitz|$BLITZ_PID" | grep -v grep || echo "(no matching processes)"
    echo ""
    echo "Network connections:"
    sudo lsof -i :8080 2>/dev/null || sudo ss -tlnp 2>/dev/null | grep 8080 || echo "(could not list connections)"
    echo ""
    echo "🔍 Additional debugging:"
    echo "  To see what the server is doing, try running it in foreground:"
    echo "    kill $BLITZ_PID"
    echo "    ./zig-out/bin/blitz"
    echo ""
    echo "  Or check if the server is stuck in the event loop:"
    echo "    strace -p $BLITZ_PID 2>&1 | head -20"
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}🚀 Blitz is running successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📊 Server Info:"
echo "   PID: $BLITZ_PID"
echo "   Port: 8080"
echo "   Log: /tmp/blitz.log"
echo ""
echo "🧪 Test it:"
echo "   curl http://localhost:8080"
echo "   curl http://localhost:8080/hello"
echo ""
echo "📝 View logs:"
echo "   tail -f /tmp/blitz.log"
echo ""
echo "🛑 Stop server:"
echo "   kill $BLITZ_PID"
echo "   # or"
echo "   sudo fuser -k 8080/tcp"
echo ""

