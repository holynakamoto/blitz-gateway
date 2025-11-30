#!/bin/bash
# Pre-installation script for Blitz Gateway

set -euo pipefail

# Create blitz-gateway user if it doesn't exist
if ! id -u blitz-gateway >/dev/null 2>&1; then
    echo "Creating blitz-gateway user..."
    useradd --system --no-create-home --shell /usr/sbin/nologin blitz-gateway
fi

# Create directories
mkdir -p /var/lib/blitz-gateway
mkdir -p /var/log/blitz-gateway
chown blitz-gateway:blitz-gateway /var/lib/blitz-gateway
chown blitz-gateway:blitz-gateway /var/log/blitz-gateway

echo "Pre-installation complete"

