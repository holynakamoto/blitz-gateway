#!/bin/bash
# Post-removal script for Blitz Gateway

set -euo pipefail

# Reload systemd
systemctl daemon-reload

# Note: We don't remove the user or directories to preserve logs/config
# User can manually remove if desired:
# userdel blitz-gateway
# rm -rf /etc/blitz-gateway /var/lib/blitz-gateway /var/log/blitz-gateway

