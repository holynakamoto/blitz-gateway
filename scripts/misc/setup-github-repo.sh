#!/bin/bash

set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                                                                ║"
echo "║      GitHub Repository Setup for Blitz API Gateway            ║"
echo "║                                                                ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

success() { echo -e "${GREEN}✅ $1${NC}"; }
warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; }
info() { echo -e "   $1"; }

# Check if we're in a git repository
if [ ! -d .git ]; then
    error "Not a git repository. Run 'git init' first."
    exit 1
fi

success "Git repository detected"

# ============================================================================
# Step 1: Create directory structure
# ============================================================================

echo ""
info "Creating directory structure..."

mkdir -p .github/workflows
mkdir -p .github/ISSUE_TEMPLATE
mkdir -p docs
mkdir -p scripts

success "Directory structure created"

# ============================================================================
# Step 2: Create .gitignore
# ============================================================================

echo ""
info "Creating .gitignore..."

cat > .gitignore <<'EOF'
# Zig
zig-cache/
zig-out/
*.o
*.a
*.so
*.dylib

# Build artifacts
/blitz
/main
*.log
*.pid

# Editor files
.vscode/
.idea/
*.swp
*.swo
*~
.DS_Store

# Vagrant
.vagrant/
*.box

# Test coverage
coverage/
*.lcov

# Docker
.dockerignore

# Environment variables
.env
.env.local

# Temporary files
/tmp/
*.tmp
EOF

success ".gitignore created"

# ============================================================================
# Step 3: Create README.md
# ============================================================================

echo ""
info "Creating README.md..."

cat > README.md <<'EOF'
# Blitz API Gateway

[![CI/CD](https://github.com/yourusername/blitz/actions/workflows/ci.yml/badge.svg)](https://github.com/yourusername/blitz/actions)
[![codecov](https://codecov.io/gh/yourusername/blitz/branch/main/graph/badge.svg)](https://codecov.io/gh/yourusername/blitz)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

A high-performance API gateway built with Zig, leveraging io_uring for maximum throughput.

## 🚀 Features

- ⚡ **Blazing Fast** - Built on io_uring for non-blocking I/O
- 🔒 **Secure** - Memory-safe by design with Zig
- 🐳 **Cloud Native** - Docker and Kubernetes ready
- 📊 **Observable** - Built-in metrics and health checks
- 🌍 **Multi-platform** - Linux (x86_64, ARM64), macOS

## 📋 Prerequisites

- Zig 0.13.0 or later
- Linux with kernel 5.1+ (for io_uring support)
- liburing

## 🛠️ Building

```bash
# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Run tests
zig build test

# Run the server
./zig-out/bin/blitz
```

## 🐳 Docker

```bash
# Build
docker build -t blitz:latest .

# Run
docker run -p 8080:8080 blitz:latest
```

## 📊 Benchmarking

```bash
# Using wrk2
wrk -t4 -c100 -d30s http://localhost:8080

# Using Apache Bench
ab -n 10000 -c 100 http://localhost:8080/
```

## 🤝 Contributing

Contributions are welcome! Please read our [Contributing Guide](CONTRIBUTING.md) for details.

## 📝 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Zig community
- io_uring developers
EOF

success "README.md created"

# ============================================================================
# Step 4: Create CONTRIBUTING.md
# ============================================================================

echo ""
info "Creating CONTRIBUTING.md..."

cat > CONTRIBUTING.md <<'EOF'
# Contributing to Blitz

Thank you for your interest in contributing to Blitz! 🎉

## Development Setup

1. Fork the repository
2. Clone your fork: `git clone https://github.com/yourusername/blitz.git`
3. Create a branch: `git checkout -b feature/amazing-feature`
4. Make your changes
5. Run tests: `zig build test`
6. Run formatting: `zig fmt src/`
7. Commit your changes: `git commit -m 'Add amazing feature'`
8. Push to the branch: `git push origin feature/amazing-feature`
9. Open a Pull Request

## Code Style

- Follow Zig's standard formatting (use `zig fmt`)
- Write clear, self-documenting code
- Add comments for complex logic
- Keep functions small and focused

## Testing

- Add tests for new features
- Ensure all tests pass before submitting PR
- Include integration tests where appropriate
- Add benchmarks for performance-critical code

## Pull Request Process

1. Update the README.md with details of changes if needed
2. Update the documentation
3. The PR will be merged once you have the sign-off of a maintainer

## Code of Conduct

Be respectful, inclusive, and constructive in all interactions.
EOF

success "CONTRIBUTING.md created"

# ============================================================================
# Step 5: Create LICENSE
# ============================================================================

echo ""
info "Creating LICENSE (MIT)..."

YEAR=$(date +%Y)
cat > LICENSE <<EOF
MIT License

Copyright (c) ${YEAR} Your Name

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF

success "LICENSE created"

# ============================================================================
# Step 6: Create issue templates
# ============================================================================

echo ""
info "Creating issue templates..."

cat > .github/ISSUE_TEMPLATE/bug_report.md <<'EOF'
---
name: Bug Report
about: Create a report to help us improve
title: '[BUG] '
labels: bug
assignees: ''
---

## Describe the bug

A clear and concise description of what the bug is.

## To Reproduce

Steps to reproduce the behavior:
1. 
2. 
3. 

## Expected behavior

A clear and concise description of what you expected to happen.

## Environment

- OS: [e.g. Ubuntu 22.04]
- Architecture: [e.g. x86_64]
- Zig version: [e.g. 0.13.0]
- Blitz version: [e.g. 1.0.0]

## Additional context

Add any other context about the problem here.
EOF

cat > .github/ISSUE_TEMPLATE/feature_request.md <<'EOF'
---
name: Feature Request
about: Suggest an idea for this project
title: '[FEATURE] '
labels: enhancement
assignees: ''
---

## Is your feature request related to a problem?

A clear and concise description of what the problem is.

## Describe the solution you'd like

A clear and concise description of what you want to happen.

## Describe alternatives you've considered

A clear and concise description of any alternative solutions or features you've considered.

## Additional context

Add any other context or screenshots about the feature request here.
EOF

success "Issue templates created"

# ============================================================================
# Step 7: Create docker-compose.yml
# ============================================================================

echo ""
info "Creating docker-compose.yml..."

cat > docker-compose.yml <<'EOF'
version: '3.9'

services:
  blitz:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8080:8080"
    environment:
      - LOG_LEVEL=info
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/health"]
      interval: 30s
      timeout: 3s
      retries: 3
      start_period: 5s
    restart: unless-stopped
EOF

success "docker-compose.yml created"

# ============================================================================
# Step 8: Create Dependabot configuration
# ============================================================================

echo ""
info "Creating Dependabot configuration..."

cat > .github/dependabot.yml <<'EOF'
version: 2
updates:
  # Enable version updates for GitHub Actions
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 10
    labels:
      - "dependencies"
      - "github-actions"

  # Enable version updates for Docker
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
    open-pull-requests-limit: 5
    labels:
      - "dependencies"
      - "docker"
EOF

success "Dependabot configuration created"

# ============================================================================
# Step 9: Create CODEOWNERS
# ============================================================================

echo ""
info "Creating CODEOWNERS..."

cat > .github/CODEOWNERS <<'EOF'
# This file defines code owners for automatic PR review requests
# Each line is a file pattern followed by one or more owners
# Order is important - the last matching pattern takes precedence
# See: https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners

# Global owners - these users will be requested for review on all PRs
* @yourusername

# Core source code
/src/ @yourusername
/src/**/*.zig @yourusername

# Build configuration
/build.zig @yourusername
/build.zig.zon @yourusername

# CI/CD and GitHub workflows
/.github/workflows/ @yourusername
/.github/CODEOWNERS @yourusername

# Documentation
/README.md @yourusername
/CONTRIBUTING.md @yourusername
/docs/ @yourusername

# Docker and deployment
/Dockerfile @yourusername
/docker-compose.yml @yourusername

# Scripts
/scripts/ @yourusername

# Benchmarks
/benches/ @yourusername
EOF

success "CODEOWNERS created"

# ============================================================================
# Step 10: Summary
# ============================================================================

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                     Setup Complete! 🎉                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

info "Files created:"
echo "   ✅ .github/workflows/ci.yml (CI/CD pipeline)"
echo "   ✅ .github/workflows/ (already exists)"
echo "   ✅ .github/ISSUE_TEMPLATE/ (bug report, feature request)"
echo "   ✅ .github/CODEOWNERS (automatic PR reviews)"
echo "   ✅ .github/dependabot.yml (automated dependency updates)"
echo "   ✅ .github/pull_request_template.md (PR template)"
echo "   ✅ Dockerfile (already exists)"
echo "   ✅ docker-compose.yml (Docker Compose config)"
echo "   ✅ .gitignore (build artifacts, cache, etc.)"
echo "   ✅ README.md (project documentation)"
echo "   ✅ CONTRIBUTING.md (contribution guidelines)"
echo "   ✅ LICENSE (MIT License)"
echo ""

info "Next steps:"
echo ""
echo "   1. Review and customize the files:"
echo "      - Update README.md with your details"
echo "      - Update LICENSE with your name"
echo "      - Update CODEOWNERS with your GitHub username"
echo ""
echo "   2. Create a new GitHub repository:"
echo "      - Go to https://github.com/new"
echo "      - Create your repository"
echo ""
echo "   3. Push your code:"
echo "      git add ."
echo "      git commit -m \"Initial commit with CI/CD pipeline\""
echo "      git branch -M main"
echo "      git remote add origin https://github.com/yourusername/blitz.git"
echo "      git push -u origin main"
echo ""
echo "   4. Set up GitHub secrets (optional):"
echo "      - CODECOV_TOKEN (for code coverage)"
echo "      - SLACK_WEBHOOK_URL (for Slack notifications)"
echo ""
echo "   5. Enable GitHub Actions:"
echo "      - Go to your repo → Actions tab"
echo "      - Enable workflows"
echo ""

info "Your CI/CD pipeline will automatically:"
echo "   ✅ Run on every push and PR"
echo "   ✅ Build for multiple platforms (Linux x86_64/ARM64, macOS)"
echo "   ✅ Run tests and benchmarks"
echo "   ✅ Check code formatting and security"
echo "   ✅ Build and push Docker images"
echo "   ✅ Create GitHub releases with artifacts"
echo ""

success "Happy coding! 🚀"

