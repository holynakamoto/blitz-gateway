#!/bin/bash
# Blitz Gateway Install Script
# One-command install for Ubuntu 22.04 / 24.04

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REPO_URL="https://github.com/holynakamoto/blitz-gateway"
REPO_API="https://api.github.com/repos/holynakamoto/blitz-gateway"

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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root (use sudo)"
    exit 1
fi

# Detect OS
if [ ! -f /etc/os-release ]; then
    log_error "Cannot detect OS. This script supports Ubuntu 22.04/24.04 only."
    exit 1
fi

. /etc/os-release

if [ "$ID" != "ubuntu" ]; then
    log_error "This script supports Ubuntu only. Detected: $ID"
    exit 1
fi

OS_CODENAME="$VERSION_CODENAME"
log_info "Detected Ubuntu $OS_CODENAME"

# Get latest release version
log_info "Fetching latest release..."
API_RESPONSE=$(curl -s -w "\n%{http_code}" "${REPO_API}/releases/latest")
HTTP_CODE=$(echo "$API_RESPONSE" | tail -n1)
API_BODY=$(echo "$API_RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    if [ "$HTTP_CODE" == "404" ]; then
        log_error "No releases found in the repository"
        echo ""
        log_info "This repository doesn't have any published releases yet."
        echo "  To install Blitz Gateway, you can:"
        echo "  1. Build from source: See ${REPO_URL}#readme"
        echo "  2. Use Docker: docker pull ghcr.io/holynakamoto/blitz-gateway:latest"
        echo "  3. Wait for an official release to be published"
        echo ""
        log_info "Check for releases: ${REPO_URL}/releases"
    else
        log_error "Failed to fetch latest release version (HTTP $HTTP_CODE)"
        if echo "$API_BODY" | grep -q '"message"'; then
            ERROR_MSG=$(echo "$API_BODY" | grep '"message":' | sed -E 's/.*"message":\s*"([^"]+)".*/\1/')
            log_error "GitHub API error: $ERROR_MSG"
        fi
    fi
    exit 1
fi

LATEST_VERSION=$(echo "$API_BODY" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' || echo "")
if [ -z "$LATEST_VERSION" ]; then
    log_error "Failed to parse release version from API response"
    exit 1
fi

VERSION_NUMBER=${LATEST_VERSION#v}
log_info "Latest version: $LATEST_VERSION"

# Download .deb from GitHub Releases
DEB_URL="${REPO_URL}/releases/download/${LATEST_VERSION}/blitz-gateway_${VERSION_NUMBER}_amd64.deb"
TEMP_DEB=$(mktemp)

log_info "Downloading Blitz Gateway ${LATEST_VERSION}..."
curl -fsSL -o "$TEMP_DEB" "$DEB_URL" || {
    log_error "Failed to download .deb package"
    log_info "URL: $DEB_URL"
    rm -f "$TEMP_DEB"
    exit 1
}

# Install .deb package
log_info "Installing package..."
dpkg -i "$TEMP_DEB" || {
    log_info "Installing dependencies..."
    apt-get install -yf
    dpkg -i "$TEMP_DEB"
}

rm -f "$TEMP_DEB"

log_success "Blitz Gateway installed successfully!"

# Show next steps
echo ""
log_info "Next steps:"
echo "  1. Edit configuration: sudo nano /etc/blitz-gateway/config.toml"
echo "  2. (Optional) Add TLS certificates"
echo "  3. Start service: sudo systemctl start blitz-gateway"
echo "  4. Check status: sudo systemctl status blitz-gateway"
echo "  5. View logs: sudo journalctl -u blitz-gateway -f"
echo ""
log_info "Documentation: ${REPO_URL}"

