#!/bin/bash
# Pre-removal script for Blitz Gateway

set -euo pipefail

# Stop service if running
if systemctl is-active --quiet blitz-gateway; then
    echo "Stopping Blitz Gateway service..."
    systemctl stop blitz-gateway || true
fi

# Disable service
if systemctl is-enabled --quiet blitz-gateway; then
    echo "Disabling Blitz Gateway service..."
    systemctl disable blitz-gateway || true
fi

