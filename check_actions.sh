#!/bin/bash
echo "Checking GitHub Actions..."
actions=$(grep -r "uses:" .github/workflows/*.yml | grep -oP 'uses:\s*\K[^@]+@[^" ]+' | sort | uniq)
echo "Actions found:"
echo "$actions"
echo ""
echo "Checking for common deprecated actions..."
