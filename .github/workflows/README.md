# GitHub Actions CI/CD Workflows

This directory contains GitHub Actions workflows for automated testing, building, and deployment of the Blitz QUIC/HTTP3 server.

## Workflows Overview

### 🚀 [`ci.yml`](ci.yml) - Main CI Pipeline
**Triggers**: Push/PR to main/develop branches
- **Multi-platform testing**: Ubuntu, macOS (Intel + Apple Silicon)
- **Unit tests**: All Zig test suites (foundation, QUIC, load balancer, etc.)
- **Code quality**: Formatting checks, warning validation
- **Security checks**: Basic security pattern analysis
- **QUIC server validation**: Build verification for io_uring components

### 🐳 [`docker.yml`](docker.yml) - Docker CI Pipeline
**Triggers**: Changes to Docker files, source code, or dependencies
- **Multi-image builds**: Main server and QUIC-specific images
- **Container testing**: docker-compose validation, health checks
- **Integration testing**: HTTP/3 connectivity tests (when curl supports it)
- **Script validation**: Docker management scripts

### 📦 [`release.yml`](release.yml) - Release Pipeline
**Triggers**: Version tags (v*.*.*) or manual dispatch
- **Docker publishing**: Push images to GitHub Container Registry
- **GitHub releases**: Automated release notes and changelogs
- **Binary artifacts**: Cross-platform release binaries
- **Semantic versioning**: Automatic pre-release detection

### 📊 [`benchmark.yml`](benchmark.yml) - Performance Testing
**Triggers**: Push to benchmark branch, changes to bench code, or manual
- **Docker benchmarks**: Containerized performance testing
- **Regression detection**: Performance baseline comparisons
- **Resource monitoring**: Memory usage, compilation speed analysis
- **Documentation validation**: Benchmark script and guide verification

### 🔄 [`dependencies.yml`](dependencies.yml) - Dependency Management
**Triggers**: Daily schedule (2 AM UTC) or manual dispatch
- **Version checking**: Zig and PicoTLS update detection
- **Security auditing**: Vulnerability scanning for dependencies
- **Automated updates**: PR creation for dependency updates
- **Compatibility testing**: Build validation after updates

### 🧹 [`code-quality.yml`](code-quality.yml) - Code Quality Assurance
**Triggers**: Push/PR to main/develop branches
- **Zig formatting**: `zig fmt` compliance checking
- **C code quality**: clang-format validation and compilation checks
- **Documentation**: Link validation and structure checks
- **Dependency analysis**: Import usage and complexity analysis
- **License compliance**: Header and compatibility checking

## Workflow Badges

Add these badges to your README.md:

```markdown
[![CI](https://github.com/yourusername/blitz-gateway/workflows/CI/badge.svg)](https://github.com/yourusername/blitz-gateway/actions)
[![Docker](https://github.com/yourusername/blitz-gateway/workflows/Docker/badge.svg)](https://github.com/yourusername/blitz-gateway/actions)
[![Release](https://github.com/yourusername/blitz-gateway/workflows/Release/badge.svg)](https://github.com/yourusername/blitz-gateway/actions)
[![Code Quality](https://github.com/yourusername/blitz-gateway/workflows/Code%20Quality/badge.svg)](https://github.com/yourusername/blitz-gateway/actions)
```

## Key Features

### 🔧 **Automated Testing**
- Multi-platform Zig builds (Linux x64, macOS Intel/ARM)
- Comprehensive test suite coverage
- Docker container validation
- HTTP/3 protocol testing

### 📈 **Performance Monitoring**
- Benchmark regression detection
- Resource usage tracking
- Compilation performance analysis
- Memory leak detection (where possible)

### 🔒 **Security & Quality**
- Dependency vulnerability scanning
- Code formatting enforcement
- License compliance checking
- Security pattern analysis

### 🚀 **Release Automation**
- Semantic versioning support
- Docker image publishing
- Cross-platform binary distribution
- Automated changelog generation

## Manual Triggers

Several workflows support manual execution:

- **Release**: `workflow_dispatch` for manual releases
- **Benchmark**: `workflow_dispatch` with custom parameters
- **Dependencies**: `workflow_dispatch` for dependency updates

## Environment Requirements

### GitHub Secrets
- `GITHUB_TOKEN`: Automatically provided for repository access

### External Dependencies
- **Docker Hub**: For base images
- **GitHub Container Registry**: For publishing images (ghcr.io)

### Runner Requirements
- **Ubuntu**: Full Linux testing with io_uring support
- **macOS**: Cross-platform compatibility testing
- **Docker**: Container build and testing capabilities

## Contributing

When adding new workflows:

1. **Name consistently**: Use descriptive, action-oriented names
2. **Trigger appropriately**: Balance coverage with resource usage
3. **Document thoroughly**: Update this README with new workflows
4. **Test manually**: Use `workflow_dispatch` for validation
5. **Optimize performance**: Use caching and conditional execution

## Troubleshooting

### Common Issues

**Workflow doesn't trigger**: Check branch protection rules and path filters

**Docker builds fail**: Ensure Dockerfile syntax and base images are valid

**Test failures**: Check Zig version compatibility and system dependencies

**Release failures**: Verify tagging format and GitHub token permissions

### Debug Mode

Enable debug logging by setting repository secret `ACTIONS_RUNNER_DEBUG=true`

### Performance Optimization

- Use caching for dependencies and build artifacts
- Run expensive jobs only on relevant changes
- Use matrix builds for parallel execution
- Implement early exits for failed prerequisite jobs
