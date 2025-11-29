#!/bin/bash

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║          BLITZ SERVER COMPLETE DIAGNOSTIC REPORT               ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

section() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo -e "${BLUE}$1${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

success() { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
info() { echo -e "   $1"; }

# =============================================================================
section "1. SYSTEM INFORMATION"
# =============================================================================

info "Hostname: $(hostname)"
info "Architecture: $(uname -m)"
info "Kernel: $(uname -r)"
info "OS: $(lsb_release -d 2>/dev/null | cut -f2 || cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
info "Uptime: $(uptime -p 2>/dev/null || uptime)"
info "Memory: $(free -h | grep Mem | awk '{print $3 "/" $2}')"

# =============================================================================
section "2. ZIG INSTALLATION"
# =============================================================================

if command -v zig &> /dev/null; then
    success "Zig is installed"
    info "Version: $(zig version)"
    info "Location: $(which zig)"
    info "Full path: $(readlink -f $(which zig) 2>/dev/null || which zig)"
else
    error "Zig is NOT installed or not in PATH"
fi

# =============================================================================
section "3. PROJECT STRUCTURE"
# =============================================================================

cd /vagrant 2>/dev/null || cd ~

info "Current directory: $(pwd)"
echo ""
info "Directory contents:"
ls -lah | head -20

echo ""
if [ -f build.zig ]; then
    success "build.zig found"
    info "Size: $(stat -f%z build.zig 2>/dev/null || stat -c%s build.zig) bytes"
else
    error "build.zig NOT found"
fi

echo ""
if [ -d src ]; then
    success "src/ directory found"
    info "Contents:"
    ls -lah src/ | head -20
else
    error "src/ directory NOT found"
fi

echo ""
if [ -f src/main.zig ]; then
    success "src/main.zig found"
    info "Size: $(stat -f%z src/main.zig 2>/dev/null || stat -c%s src/main.zig) bytes"
    info "First 10 lines:"
    head -10 src/main.zig | sed 's/^/      /'
else
    error "src/main.zig NOT found"
fi

# =============================================================================
section "4. BUILD OUTPUT"
# =============================================================================

if [ -d zig-out ]; then
    success "zig-out/ directory exists"
    info "Contents:"
    find zig-out -type f -exec ls -lh {} \; 2>/dev/null | head -20
else
    error "zig-out/ directory does NOT exist"
fi

echo ""
if [ -f zig-out/bin/blitz ]; then
    success "Binary found: zig-out/bin/blitz"
    info "Size: $(ls -lh zig-out/bin/blitz | awk '{print $5}')"
    info "Permissions: $(ls -l zig-out/bin/blitz | awk '{print $1}')"
    info "Type: $(file zig-out/bin/blitz)"
    
    echo ""
    info "Dependencies (ldd):"
    ldd zig-out/bin/blitz 2>&1 | sed 's/^/      /'
    
    echo ""
    info "Checking for liburing:"
    if ldd zig-out/bin/blitz 2>&1 | grep -q liburing; then
        success "liburing linked"
        ldd zig-out/bin/blitz 2>&1 | grep liburing | sed 's/^/      /'
    else
        warning "liburing NOT linked"
    fi
else
    error "Binary NOT found at zig-out/bin/blitz"
    
    # Check for alternative locations
    echo ""
    info "Searching for blitz binary..."
    find . -name "blitz" -type f 2>/dev/null | sed 's/^/      /'
    find . -name "main" -type f 2>/dev/null | sed 's/^/      /'
fi

# =============================================================================
section "5. RUNNING PROCESSES"
# =============================================================================

if pgrep -f blitz > /dev/null; then
    success "Blitz process is RUNNING"
    info "Process details:"
    ps aux | grep blitz | grep -v grep | sed 's/^/      /'
    
    echo ""
    BLITZ_PID=$(pgrep -f "zig-out/bin/blitz" | head -1)
    if [ -n "$BLITZ_PID" ]; then
        info "Main PID: $BLITZ_PID"
        info "Status: $(cat /proc/$BLITZ_PID/status 2>/dev/null | grep State | sed 's/^/      /')"
        info "CPU/Memory: $(ps -p $BLITZ_PID -o %cpu,%mem,vsz,rss 2>/dev/null | tail -1 | sed 's/^/      /')"
    fi
else
    error "No Blitz process running"
fi

# =============================================================================
section "6. NETWORK STATUS"
# =============================================================================

info "Network interfaces:"
ip addr show | grep -E "^[0-9]|inet " | sed 's/^/   /'

echo ""
info "Listening ports:"
sudo netstat -tlnp 2>/dev/null | grep -E "Proto|LISTEN" | sed 's/^/   /' || \
sudo ss -tlnp 2>/dev/null | grep -E "State|LISTEN" | sed 's/^/   /'

echo ""
if sudo netstat -tlnp 2>/dev/null | grep -q ":8080" || sudo ss -tlnp 2>/dev/null | grep -q ":8080"; then
    success "Port 8080 is LISTENING"
    sudo netstat -tlnp 2>/dev/null | grep ":8080" | sed 's/^/   /' || \
    sudo ss -tlnp 2>/dev/null | grep ":8080" | sed 's/^/   /'
else
    error "Port 8080 is NOT listening"
fi

# =============================================================================
section "7. LOG FILES"
# =============================================================================

if [ -f /tmp/blitz.log ]; then
    info "Log file exists: /tmp/blitz.log"
    info "Size: $(ls -lh /tmp/blitz.log | awk '{print $5}')"
    info "Last modified: $(stat -c %y /tmp/blitz.log 2>/dev/null || stat -f %Sm /tmp/blitz.log)"
    
    if [ -s /tmp/blitz.log ]; then
        success "Log file has content"
        info "Last 20 lines:"
        tail -20 /tmp/blitz.log | sed 's/^/      /'
    else
        warning "Log file is EMPTY (0 bytes)"
    fi
else
    error "Log file does NOT exist: /tmp/blitz.log"
fi

# =============================================================================
section "8. CONNECTIVITY TEST"
# =============================================================================

info "Testing localhost:8080..."
if timeout 2 curl -s http://localhost:8080 > /dev/null 2>&1; then
    success "Server responds on localhost:8080"
    info "Response:"
    curl -s http://localhost:8080 2>&1 | head -5 | sed 's/^/      /'
else
    error "Server does NOT respond on localhost:8080"
    CURL_ERROR=$(curl -v http://localhost:8080 2>&1 | tail -5)
    info "Error details:"
    echo "$CURL_ERROR" | sed 's/^/      /'
fi

echo ""
info "Testing localhost:8080/hello..."
if timeout 2 curl -s http://localhost:8080/hello > /dev/null 2>&1; then
    success "Server responds on localhost:8080/hello"
    info "Response:"
    curl -s http://localhost:8080/hello 2>&1 | head -5 | sed 's/^/      /'
else
    error "Server does NOT respond on localhost:8080/hello"
fi

# =============================================================================
section "9. DEPENDENCIES"
# =============================================================================

info "Checking liburing..."
if pkg-config --exists liburing; then
    success "liburing is installed"
    info "Version: $(pkg-config --modversion liburing)"
    info "CFLAGS: $(pkg-config --cflags liburing)"
    info "LIBS: $(pkg-config --libs liburing)"
else
    error "liburing NOT found via pkg-config"
fi

echo ""
info "Searching for liburing files:"
find /usr -name "*liburing*" 2>/dev/null | head -10 | sed 's/^/   /'

# =============================================================================
section "10. BUILD TEST"
# =============================================================================

if [ -f /vagrant/build.zig ]; then
    info "Attempting to build (showing last 30 lines)..."
    cd /vagrant
    zig build 2>&1 | tail -30 | sed 's/^/   /'
    BUILD_EXIT=$?
    
    if [ $BUILD_EXIT -eq 0 ]; then
        success "Build successful"
    else
        error "Build FAILED (exit code: $BUILD_EXIT)"
    fi
else
    warning "No build.zig, skipping build test"
fi

# =============================================================================
section "11. RECOMMENDED ACTIONS"
# =============================================================================

echo ""
if ! pgrep -f blitz > /dev/null; then
    error "SERVER IS NOT RUNNING"
    echo ""
    info "To start the server:"
    info "  cd /vagrant"
    info "  ./zig-out/bin/blitz"
elif ! timeout 2 curl -s http://localhost:8080 > /dev/null 2>&1; then
    error "SERVER IS RUNNING BUT NOT RESPONDING"
    echo ""
    info "The server is running but crashes on connection."
    info "To debug:"
    info "  1. Kill server: pkill -f blitz"
    info "  2. Run directly: cd /vagrant && ./zig-out/bin/blitz"
    info "  3. Try connecting in another terminal: curl http://localhost:8080"
    info "  4. Watch for error messages"
else
    success "SERVER IS RUNNING AND RESPONDING!"
    echo ""
    info "Server is working correctly on port 8080"
    info "Test it with: curl http://localhost:8080"
fi

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     DIAGNOSTIC COMPLETE                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

