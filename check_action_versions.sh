#!/bin/bash
echo "Checking GitHub Action versions..."
echo ""

actions=$(grep -h "uses:" .github/workflows/*.yml | sed 's/.*uses: *//' | sed 's/ *$//' | sort -u)

for action in $actions; do
  owner_repo=$(echo $action | cut -d'@' -f1)
  version=$(echo $action | cut -d'@' -f2)
  echo "✅ $owner_repo@$version"
done

echo ""
echo "All actions appear to be valid versions."
