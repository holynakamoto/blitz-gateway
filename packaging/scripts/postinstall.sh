#!/bin/bash
# Post-installation script for Blitz Gateway

set -euo pipefail

echo "Configuring Blitz Gateway..."

# Reload systemd to pick up new service file
systemctl daemon-reload

# Enable but don't start (let user configure first)
systemctl enable blitz-gateway.service || true

echo ""
echo "✅ Blitz Gateway installed successfully!"
echo ""
echo "Next steps:"
echo "  1. Edit configuration: sudo nano /etc/blitz-gateway/config.toml"
echo "  2. (Optional) Add TLS certificates"
echo "  3. Start service: sudo systemctl start blitz-gateway"
echo "  4. Check status: sudo systemctl status blitz-gateway"
echo ""
echo "Documentation: https://github.com/holynakamoto/blitz-gateway"

