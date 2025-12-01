#!/bin/bash
set -euo pipefail

# Verify workflows directory exists
if [[ ! -d .github/workflows ]]; then
  echo "Error: .github/workflows directory not found"
  exit 1
fi

echo "Checking GitHub Actions..."
actions=$(grep -r "uses:" .github/workflows/*.yml 2>/dev/null | grep -oP 'uses:\s*\K[^@]+@[^" ]+' | sort | uniq || true)
echo "Actions found:"
echo "$actions"
echo ""
echo "Checking for common deprecated actions..."

# Example: Flag deprecated actions
deprecated=("actions/setup-node@v1" "actions/setup-python@v1")
for action in "${deprecated[@]}"; do
  if echo "$actions" | grep -q "^${action}$"; then
    echo "⚠️  Deprecated action found: $action"
  fi
done
