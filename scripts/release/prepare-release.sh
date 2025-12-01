#!/bin/bash
# scripts/release/prepare-release.sh
# Prepare a new release

set -euo pipefail

VERSION=$1

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-z]+\.[0-9]+)?$ ]]; then
    echo "Error: Invalid version format. Use vX.Y.Z or vX.Y.Z-rc.N"
    exit 1
fi

echo "Preparing release $VERSION"

# Update version in packaging/nfpm.yaml
if [ -f "packaging/nfpm.yaml" ]; then
    echo "Updating version in packaging/nfpm.yaml..."
    sed -i.bak "s/version: \".*\"/version: \"${VERSION#v}\"/" packaging/nfpm.yaml
    rm -f packaging/nfpm.yaml.bak
fi

# Update CHANGELOG.md if it exists
if [ -f "CHANGELOG.md" ]; then
    echo "Updating CHANGELOG.md..."
    DATE=$(date +%Y-%m-%d)
    cat > CHANGELOG.tmp << EOF
# Changelog

## [$VERSION] - $DATE

### Added
- 

### Changed
- 

### Fixed
- 

### Security
- 

$(tail -n +3 CHANGELOG.md 2>/dev/null || echo "")
EOF
    mv CHANGELOG.tmp CHANGELOG.md
else
    echo "CHANGELOG.md not found, skipping..."
fi

# Generate release notes
echo "Generating release notes..."
cat > RELEASE_NOTES.md << EOF
# Release $VERSION

## Highlights

## Breaking Changes

## Migration Guide

## Full Changelog

See [CHANGELOG.md](CHANGELOG.md) for complete details.
EOF

echo "✅ Release preparation complete"
echo ""
echo "Next steps:"
echo "1. Edit CHANGELOG.md and RELEASE_NOTES.md"
echo "2. Commit changes: git commit -am 'chore: prepare release $VERSION'"
echo "3. Create PR to main"
echo "4. After merge, tag will be created automatically"

